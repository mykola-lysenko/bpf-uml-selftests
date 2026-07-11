# Upstreaming Series Split

This document splits the local `uml-veristat` patch stack by upstream review
surface. The current patch order should stay as-is for CI because it represents
the tested end-to-end UML verification environment. Upstream submissions should
be smaller and routed by subsystem.

## Recommended Order

1. Low-risk standalone fixes.
   - Send patches that fix clear build or correctness issues and do not depend
     on the controversial UML verification model.
   - Goal: reduce the local stack before discussing larger UML/BPF design.

2. Generic BPF/libbpf fixes with native validation.
   - Add or confirm native-side tests first, then post these as normal BPF
     fixes, not as UML infrastructure.

3. UML BPF capability RFCs.
   - Post verification stubs and native x86 JIT wiring only after the smaller
     fixes are out of the way.
   - These need stronger cover-letter framing because they provide
     static-analysis support without full runtime feature support.

## Series A: UML And Selftest Build Fixes

Status: mostly ready to post as small standalone patches.

Patches:

- `0003-um-fix-stub-binary-page-alignment-by-removing-Wl-n.patch`
  - Audience: UML maintainers.
  - Rationale: fixes UML boot by restoring page-aligned stub LOAD segments.
  - Dependency: none.

- `0004-selftests-bpf-fix-bpf_testmod.c-compilation-on-UML.patch`
  - Audience: BPF selftests maintainers, UML maintainers on Cc.
  - Rationale: avoids native x86-only guards when compiling `bpf_testmod` for
    UML.
  - Dependency: none.

- `0001-um-x86-add-BPF-attachable-__x64_sys_-syscall-wrappers.patch`
  - Audience: UML and BPF maintainers.
  - Rationale: exposes expected x86-64 syscall wrapper BTF attach targets on
    UML, with patchable entries and syscall dispatch so fentry/fexit
    programs actually execute (consolidated from the former 0001 + 0012 +
    0014 on 2026-07-11).
  - Dependency: none, but expect review on whether adding wrapper symbols for
    BTF attach compatibility is the preferred UML interface.

Suggested posting shape:

- Send `0003` alone if we want the easiest early merge.
- Send `0004` alone or with a tiny cover note explaining it is selftest-only.
- Hold or RFC `0001` if reviewers prefer a broader syscall-wrapper story for
  UML BTF attach targets.

## Series B: Generic libbpf And BPF Fixes

Status: valuable to upstream, but should be backed by native-side tests before
posting.

Patches:

- `0005-libbpf-handle-duplicate-BTF-types-in-relocations.patch`
  - Audience: libbpf maintainers.
  - Rationale: split-BTF relocation should tolerate duplicate compatible base
    BTF candidates when the distilled representation cannot distinguish them.
  - Dependency: none.
  - Validation needed: focused libbpf selftests for duplicate compatible base
    candidates.

- `0005b-libbpf-tolerate-duplicate-target-type-ids-in-core-relos.patch`
  - Audience: libbpf maintainers.
  - Rationale: `BPF_CORE_TYPE_ID_TARGET` can tolerate duplicate compatible
    target candidates because either target BTF ID is acceptable for
    type-identity helpers.
  - Dependency: conceptually pairs with `0005`, but should be reviewable as a
    separate libbpf fix.
  - Validation needed: CO-RE relocation selftest for duplicate compatible
    target-type IDs.

- `0006`/`0006b` (arena preallocation): REMOVED from the stack (2026-07-10).
  They worked around `kmalloc_nolock()` returning NULL on UML, which was a
  missing-host-CPU-feature-probing problem fixed at the root by `0017`.
  Nothing to upstream from them; the underlying UML gap is covered by the
  `0017` RFC in Series A/C territory.

Suggested posting shape:

- Post `0005` and `0005b` as a two-patch libbpf series after adding focused
  tests.

## Series C: selftests/bpf veristat Fixes

Status: mostly ready, but should be framed as generic veristat robustness.

Patches:

- `0007-selftests-bpf-make-benchmark-map-definitions-standal.patch`
  - Audience: BPF selftests maintainers.
  - Rationale: benchmark BPF objects should carry small valid default map
    dimensions even when the benchmark harness overrides them before load.
  - Dependency: none.

- `0007b-selftests-bpf-veristat-preserve-zero-max_entries-for.patch`
  - Audience: BPF selftests maintainers.
  - Rationale: veristat should not rewrite `max_entries` for percpu cgroup
    storage maps, which require `max_entries == 0` just like cgroup storage.
  - Dependency: none.

- `0008` (veristat auto log-size cap): REMOVED from the stack (2026-07-11).
  The 1 GiB auto default is mostly virtual memory on native hosts; the
  failure it prevented was UML's fixed guest memory. The uml-veristat
  wrapper now injects an environment-sized --log-size (UML_MEM/8, capped
  at 256 MiB) unless the caller passes one, which is the right layer for
  environment policy. Nothing to upstream unless native RSS measurements
  ever show real multi-hundred-MB logs.

Suggested posting shape:

- Send `0007` as a standalone selftests cleanup; it is about making benchmark
  objects self-describing, not changing veristat policy.
- Send `0007b` as a tiny veristat correctness fix with before/after examples
  from percpu cgroup storage objects.

## Series D: UML software perf events + BPF_EVENTS Kconfig fix

Status: replaced the verification-stubs RFC entirely (2026-07-11). The
former `0002` (hidden UML-only verification stubs, our largest and
hardest-to-defend patch) was REMOVED from the stack: with real perf and
BPF_EVENTS available, its Kconfig self-disabled and every stubbed surface
is now served by the real implementations (bpf_trace.c, real stackmap,
real BPF_LSM), with ~270 additional corpus programs verifying and
core_reloc passing at runtime.

Patches:

- `0018-um-add-software-perf-events-support.patch`
  - Audience: UML maintainers.
  - Rationale: UML is one of only five architectures without
    HAVE_PERF_EVENTS (with m68k, microblaze, nios2, openrisc); the perf
    software core needs no PMU and UML has working hrtimers. One Kconfig
    select plus a 12-line asm/perf_event.h (the native header's
    perf_arch_fetch_caller_regs uses named pt_regs fields UML lacks).
  - Value beyond BPF: perf tooling in UML guests, tracefs event id files.

- `0019-bpf-allow-BPF_EVENTS-without-kprobe-or-uprobe-events.patch`
  - Audience: BPF and tracing maintainers.
  - Rationale: BPF_EVENTS requires (KPROBE_EVENTS || UPROBE_EVENTS), but
    bpf_trace.c's kprobe/uprobe sections are already conditionally
    compiled; the dependency locks tracepoint/raw_tp BPF out of kernels
    with perf + tracepoints but no probe support. Drop the leg and select
    TRACING directly (precedent: GENERIC_TRACER), which the probe-event
    configs used to provide transitively.
  - Review risk: tracing maintainers may prefer a different Kconfig
    shape; the technical content is two lines.

Suggested posting shape:

- Post 0018 to linux-um and 0019 to bpf-next (cross-Cc), together or
  0018 first. Lead with measured results: real raw_tp/tp_btf attach on
  UML, core_reloc 145/145 subtests, +267 corpus programs verified.

## Series E: UML x86 BPF JIT RFC

Status: needs patch splitting before posting.

Patches:

- `0003b-um-x86-wire-up-native-x86-BPF-JIT-backend-for-UML.patch`
  - Audience: UML, x86, and BPF maintainers.
  - Rationale: links the native x86 BPF JIT backend into UML with the
    minimal compatibility shims, the HAVE_EBPF_JIT Kconfig enablement, and
    far-call support (consolidated from the former 0003b + 0003c + 0003d on
    2026-07-11; they were never independently useful).
  - Review risk: broad; it mixes build wiring, register layout, header
    compatibility, runtime shims, and final backend enablement.

Suggested posting shape:

- For upstream, split back into buildable pieces along review-surface lines
  (the local stack intentionally keeps them as one tested unit):
  - UML/x86 register and header compatibility.
  - UML-local NOP, CFI, BHB, per-cpu, and text-copy shims.
  - `arch/x86/net/` build wiring for UML.
  - final `HAVE_EBPF_JIT` and default-JIT enablement.
- Post as RFC after the verification-stub RFC or together with it if the cover
  letter explains their interaction.

## Current Priority

The next concrete cleanup item is to rework the merged `0003b` JIT patch
into smaller buildable patches for posting. That is the largest
reviewability risk in the current stack and is already called out
separately in `docs/upstreaming-cleanup.md`.

Done (2026-07-11): `0009b` was rewritten from a hand-rolled ~60-insn
emitted range check into the native guard structure with UML span
constants ([uml_physmem, end_vm) as JIT-time immediates, inverted jump
sense). Unmapped holes inside the span fault and are resolved by the 0016
extable fixups. Net -59 lines in bpf_jit_comp.c; the patch is now a small,
reviewable delta to the native check rather than parallel infrastructure.
