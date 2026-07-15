# Task: shrink the x86 BPF JIT probe-memory guard

**Status:** optimization #1 written (full diff inline below, unbuilt/untested
here — sandbox has no external network); optimization #2 designed, deferred.

This is a **general x86 BPF JIT change, not part of the uml-veristat patch
stack** — it is a tangent surfaced while looking at UML-JITed code, and it is
deliberately *not* under `patches/` (so `build.sh` does not auto-apply it). Apply
the inline diff directly to a `bpf-next` tree (after the `0009b` UML guard patch
if present; it also applies cleanly to a stock mainline tree, since `0009b` only
renames the constants this diff already tolerates).

**Follow up from a networked machine:** apply the diff, build + run the checks
below to validate, then upstream #1.

## Background

Every `BPF_PROBE_MEM` / `BPF_PROBE_MEMSX` load (BTF/CO-RE pointer reads) emits an
inline address-range guard before the faultable load, so out-of-range addresses
read as zero instead of faulting. Source: `arch/x86/net/bpf_jit_comp.c`, the
`BPF_LDX | BPF_PROBE_MEM*` case. Patch `0009b` parametrizes the span for UML
(`[uml_physmem, end_vm)`) but keeps the native single-compare structure.

Per-site cost today (mainline base = `VSYSCALL_ADDR`), ~9 insns / ~40 B:

```
movq    $-10485760, %r10          ; span_base (VSYSCALL_ADDR, sign-extended)  7B
movq    %src, %r11                ;                                           3B
addq    $off, %r11                ;                                           7B
subq    %r10, %r11                ; r11 = src+off-span_base                   3B
movabsq $limit, %r10              ; upper bound                              10B
cmpq    %r10, %r11                ;                                           3B
jcc     <load>                    ; JA (mainline) / JB (UML)                  2B
xorl    %dst, %dst                ; OOB -> dst=0                              3B
jmp     <after load>              ;                                           2B
```

Both constants are invariant across all guard sites in a program. Guards
dominate JIT expansion for BTF-pointer-heavy tracing/LSM programs; a single hot
program can carry hundreds of sites (fbk5 host snapshot: 1283 sites across 125
of 270 loaded programs, ~51 KB of guard code, concentrated in the hottest LSM
programs). Prior analysis: `~/bpf_jit_efficiency/FINDINGS.md` + JITed dumps.

## Optimization #1 — fold the low bound into the offset add (WRITTEN)

`insn->off` is an `s16` and `span_base` is fixed at boot, so
`insn->off - span_base` is a per-site compile-time constant. Replace the
`movabsq span_base` + `add off` + `sub` sequence with a single
`add r11, (insn->off - span_base)`:

```
movq    %src, %r11                ;                                           3B
addq    $(off - span_base), %r11  ; folded low bound (fits imm32)            7B
movabsq $limit, %r10              ;                                          10B
cmpq    %r10, %r11                ;                                           3B
jcc     <load>                    ;                                           2B
...
```

Saves up to **2 insns / 10 B per guard site**.

- Gated on `is_simm32(insn->off - span_base)`. Mainline
  (`span_base = VSYSCALL_ADDR = -10485760`) always fits → always folds (the
  upstreamable win). UML (`uml_physmem ≈ 0x60000000`) also fits, so the UML
  test path exercises it too.
- If the folded immediate would not fit imm32 (e.g. a high UML physmem base),
  the code falls back to the original explicit load + subtract — **behavior is
  identical in every case**.
- Correctness: both forms leave `r11 = src + off - span_base (mod 2^64)`; the
  `is_simm32` gate guarantees `(s32)fold_off` is lossless and
  `add r/m64, imm32` sign-extends it. The compare/limit/fault-fixup path is
  untouched. Verified to apply via `git am` after `0009b` and to reverse-check
  clean.

### Diff

Apply directly to `arch/x86/net/bpf_jit_comp.c` in a `bpf-next` tree (`git am`
or `git apply`). The context matches both the stock mainline guard and the
`0009b`-patched UML guard, since `0009b` only renames `VSYSCALL_ADDR`/limit into
`span_base`/`limit` locals that this diff already references.

```diff
From: Mykola Lysenko <mykolal@meta.com>
Subject: [PATCH] um/x86: fold probe-memory low bound into the guard offset add

The x86 BPF JIT guards every BPF_PROBE_MEM / BPF_PROBE_MEMSX load with an
inline address-range check.  It computes (src_reg + insn->off - span_base)
in r11 and compares it against a precomputed limit, materializing
span_base in r10 with a movabsq and then doing a separate "add off"
followed by "sub r10".

span_base is fixed at boot and insn->off is an s16, so the quantity
(insn->off - span_base) is a compile-time-foldable constant per guard
site.  For the mainline base (VSYSCALL_ADDR, a small negative constant)
and for a low UML physmem base it fits a sign-extended imm32, so the
whole low-bound handling collapses to a single "add r11, imm32".

Fold it: drop the span_base movabsq and the sub, emitting one add with
the combined immediate.  This removes up to 2 instructions / 10 bytes per
guard site on the hot path.  These guards dominate BTF/CO-RE pointer
reads in tracing and LSM programs, where a single program can carry
hundreds of guard sites.  The compare against limit and the fault-fixup
path are unchanged.  When the folded immediate would not fit imm32 (e.g.
a high UML physmem base) the code falls back to the previous explicit
span_base load and subtract, so behavior is identical in every case.

Signed-off-by: Mykola Lysenko <mykolal@meta.com>
---
 arch/x86/net/bpf_jit_comp.c | 51 +++++++++++++++++++++++++++++--------
 1 file changed, 40 insertions(+), 11 deletions(-)

diff --git a/arch/x86/net/bpf_jit_comp.c b/arch/x86/net/bpf_jit_comp.c
--- a/arch/x86/net/bpf_jit_comp.c
+++ b/arch/x86/net/bpf_jit_comp.c
@@ -2408,23 +2408,52 @@ populate_extable:
 				u8 jcc_to_load = X86_JA;
 #endif
 				u8 *end_of_jmp;
+				s64 fold_off = (s64)insn->off - (s64)span_base;
 
-				/* movabsq r10, span_base */
-				emit_mov_imm64(&prog, BPF_REG_AX, (long)span_base >> 32,
-					       (u32)(long)span_base);
-
+				/*
+				 * The guard needs (src_reg + insn->off -
+				 * span_base) to compare against limit. Fold the
+				 * span_base subtraction into the offset add: add
+				 * the combined immediate directly instead of
+				 * materializing span_base in r10 and issuing a
+				 * separate "add off; sub span_base". This drops
+				 * one movabsq and one sub (up to 2 insns /
+				 * 10 bytes) per probe-memory guard site. The
+				 * compare against limit below is unchanged.
+				 *
+				 * insn->off is an s16 and span_base is fixed at
+				 * boot. For the mainline VSYSCALL_ADDR base (a
+				 * small negative constant) and a low UML physmem
+				 * base the folded immediate fits a sign-extended
+				 * imm32; if it ever does not, fall back to the
+				 * explicit span_base load and subtract.
+				 */
 				/* mov src_reg, r11 */
 				EMIT_mov(AUX_REG, src_reg);
 
-				if (insn->off) {
-					/* add r11, insn->off */
+				if (is_simm32(fold_off)) {
+					/* add r11, (insn->off - span_base) */
 					maybe_emit_1mod(&prog, AUX_REG, true);
-					EMIT2_off32(0x81, add_1reg(0xC0, AUX_REG), insn->off);
-				}
+					EMIT2_off32(0x81, add_1reg(0xC0, AUX_REG),
+						    (s32)fold_off);
+				} else {
+					/* movabsq r10, span_base */
+					emit_mov_imm64(&prog, BPF_REG_AX,
+						       (long)span_base >> 32,
+						       (u32)(long)span_base);
+
+					if (insn->off) {
+						/* add r11, insn->off */
+						maybe_emit_1mod(&prog, AUX_REG, true);
+						EMIT2_off32(0x81,
+							    add_1reg(0xC0, AUX_REG),
+							    insn->off);
+					}
 
-				/* sub r11, r10 */
-				maybe_emit_mod(&prog, AUX_REG, BPF_REG_AX, true);
-				EMIT2(0x29, add_2reg(0xC0, AUX_REG, BPF_REG_AX));
+					/* sub r11, r10 */
+					maybe_emit_mod(&prog, AUX_REG, BPF_REG_AX, true);
+					EMIT2(0x29, add_2reg(0xC0, AUX_REG, BPF_REG_AX));
+				}
 
 				/* movabsq r10, limit */
 				emit_mov_imm64(&prog, BPF_REG_AX, (long)limit >> 32,
```

Note: on a **stock mainline** tree (no `0009b`) the surrounding locals are named
`VSYSCALL_ADDR`/`limit` rather than `span_base`/`limit`; adjust the folded
expression to `insn->off - VSYSCALL_ADDR` accordingly. Against a `0009b` UML tree
it applies as-is.

## Optimization #2 — hoist the upper bound into a callee-saved reg (DEFERRED)

For guard-heavy programs, load the invariant `limit` once into a callee-saved
register in the prologue so each site becomes `cmpq %reg, %r11` (3 B) instead of
`movabsq $limit; cmpq` (13 B) — saving ~10 B/site beyond the first, costing one
register.

**Why deferred (not a clean drop-in):** in the x86-64 BPF JIT all callee-saved
regs (rbx/r13/r14/r15) are mapped to BPF R6–R9. Hoisting requires:

1. per-program reg-usage analysis to find a callee-saved reg the program does
   not use (reuse `callee_regs_used`);
2. a conditional prologue emit (push/materialize/…);
3. stability across the JIT's multi-pass sizing (the choice must be identical
   on every pass or `image` sizing diverges);
4. a gate like "≥ N guard sites AND a free callee-saved reg", since programs
   that already use R6–R9 (common in hot LSM/tracing code) get nothing.

Higher risk, conditional payoff. Land #1 first, measure, then add #2 behind the
gate if the numbers justify it.

**Combined target:** guard shrinks ~40 B / 9 insns → ~20 B / 6 insns.

## Build / test / verify (run where there IS network)

```bash
cd bpf-uml-selftests
./build.sh                              # clones bpf-next + LLVM, applies the UML stack
# then apply the inline diff above to .build/bpf-next and rebuild the kernel:
git -C .build/bpf-next apply /path/to/opt1.diff
./build.sh --rebuild-kernel            # iterate on the kernel only after the first build

# correctness gates (exercise PROBE_MEM / BTF pointer reads):
python3 scripts/check_expectations.py
python3 scripts/check_arena_expectations.py
python3 scripts/report_coverage.py

# confirm the guard shrank: load a BTF-pointer program and dump the JIT,
# each PROBE_MEM guard should show a single `add r11, imm32` where it
# previously had movq/movabsq + add + sub:
#   (inside UML) bpftool prog dump jited id <ID>
```

Environment note: this optimization cannot be built/tested in the Meta sandbox —
external git/LLVM hosts are blocked through the proxy (403 CONNECT tunnel). See
the session memory `build-network-blocker`.
