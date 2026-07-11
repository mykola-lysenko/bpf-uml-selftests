# UML BPF Kernel Patches

These patches are applied to the bpf-next kernel tree after checkout to enable
BPF verification on User Mode Linux (UML). They are applied by `build.sh`
automatically using `git am` (idempotent: already-applied patches are skipped).

The stack is split by purpose:

- `uml-veristat/`: base stack for building and running `uml-veristat` on UML.
  This includes shared UML verifier/JIT support and generic kernel-side BPF
  fixes.
- `bpf-selftests-uml/`: BPF selftests patches and extra runtime `test_progs`
  support applied after the base stack. Put new patches here when they touch
  `tools/testing/selftests/bpf` or are only needed for runtime BPF selftests
  on UML.

`build.sh` applies both folders by default, in that order. The split is
organizational; the full package and CI path still uses both folders unless
`--clean` or `--skip-patches` is requested.

## Patches

### 0001 — `um/x86: add __x64_sys_* wrappers for BPF selftest compatibility`

**Problem:** BPF selftests compiled for x86-64 use the `__x64_` syscall prefix
when attaching `fentry`/`kprobe`/`raw_tp` programs (controlled by `SYS_PREFIX`
in `bpf_misc.h`). On native x86-64 kernels, `ARCH_HAS_SYSCALL_WRAPPER`
generates a real `asmlinkage long __x64_sys_<name>(const struct pt_regs *regs)`
function for every syscall. These functions appear in the kernel BTF as
`BTF_KIND_FUNC` entries, which libbpf resolves at BPF object open time.

UML does not use syscall wrappers, so these BTF entries are absent and libbpf
fails with `-ESRCH` when trying to resolve the attach target.

**Fix:** Add minimal `__x64_sys_*` wrapper functions for the five syscalls that
BPF selftests reference via `SYS_PREFIX`: `getpgid`, `nanosleep`, `prctl`,
`prlimit64`, and `setdomainname`. Each wrapper has the canonical x86-64 syscall
wrapper signature so pahole emits the correct `BTF_KIND_FUNC` entry. Arguments
are extracted using `UPT_SYSCALL_ARGn()` macros.

**Files changed:**
- `arch/x86/um/x64_syscall_wrappers.c` (new)
- `arch/x86/um/Makefile` (add `x64_syscall_wrappers.o`)

---

### 0002 — `bpf: add UML verification stubs for kernels without perf events`

**Problem:** `CONFIG_BPF_EVENTS` depends on `PERF_EVENTS` and
`KPROBE_EVENTS`/`UPROBE_EVENTS`. On UML these hardware-dependent subsystems are
unavailable, so `BPF_PROG_TYPE_KPROBE`, `TRACEPOINT`, `PERF_EVENT`,
`RAW_TRACEPOINT`, `RAW_TRACEPOINT_WRITABLE`, and `TRACING` are not registered.
`BPF_PROG_LOAD` returns `-EINVAL` for these types, causing veristat to report
failures for all tracing-type BPF programs.

Similarly, `BPF_MAP_TYPE_STACK_TRACE` is not registered and the
`bpf_get_stackid()`/`bpf_get_stack()` helpers are unavailable, causing veristat
to fail on programs that use stack trace maps (`pyperf*`, `strobemeta*`,
`stacktrace_*`).

Also, `bpf_trace_printk()` and `bpf_trace_vprintk()` are normally provided by
`kernel/trace/bpf_trace.c`, which is compiled under `CONFIG_BPF_EVENTS`. UML's
verification-only config intentionally has no `BPF_EVENTS`, so the weak
`bpf_get_trace_printk_proto()`/`bpf_get_trace_vprintk_proto()` fallbacks return
`NULL`. That makes otherwise valid `bpf_printk()` users fail during verification
with `program of this type cannot use helper bpf_trace_printk#6`.

**Fix:** Add hidden UML-only verification stub configs:

- `CONFIG_BPF_VERIFICATION_STUBS`, available only for UML kernels with
  `BPF_SYSCALL`, `BPF_JIT`, and no `PERF_EVENTS`/`BPF_EVENTS`
- `CONFIG_BPF_LSM_VERIFICATION_STUBS`, additionally gated on `CONFIG_SECURITY`
  so LSM program/map types are only advertised when the matching stub symbols
  are compiled

Together these configs:

1. Provides minimal `bpf_verifier_ops` and `bpf_prog_ops` for all six tracing
   program types, using a `DEFINE_STUB_OPS()` macro to eliminate boilerplate.
   The stubs delegate to `bpf_base_func_proto()` for helper access and
   `bpf_tracing_btf_ctx_access()` for context type checking.

2. Compiles `stackmap.c` and provides stub callchain buffer functions so
   `BPF_MAP_TYPE_STACK_TRACE` maps can be created. The execution-time stubs
   use `WARN_ON_ONCE` since veristat never runs programs.

3. Registers `BPF_MAP_TYPE_STACK_TRACE` in `bpf_types.h` under
   `CONFIG_BPF_VERIFICATION_STUBS`, mirroring the existing
   `CONFIG_PERF_EVENTS` guard.

4. Provides verification-only `bpf_trace_printk()` and `bpf_trace_vprintk()`
   helper prototypes. The stubs return `-EOPNOTSUPP` if ever executed; they
   exist only so veristat can validate programs that call `bpf_printk()`.

5. Registers `BPF_PROG_TYPE_LSM`, `BPF_MAP_TYPE_INODE_STORAGE`, BPF LSM attach
   target symbols, and selected LSM kfunc BTF entries only when
   `CONFIG_BPF_LSM_VERIFICATION_STUBS` is enabled.

**Files changed:**
- `kernel/bpf/bpf_verification_stubs.c` (new — stub ops + callchain/LSM stubs)
- `kernel/bpf/Kconfig` (add hidden verification stub configs)
- `kernel/bpf/Makefile` (add `bpf_verification_stubs.o`, compile `stackmap.o`)
- `kernel/bpf/stackmap.c` (guard perf_event-specific functions)
- `include/linux/bpf_types.h` (register tracing/stack/LSM types under the stub
  configs)
- `include/linux/perf_event.h` (declare callchain stub symbols)

**Result:** veristat can verify tracing program types, stack-trace users, and
`bpf_printk()` users on UML kernels that deliberately do not enable
`CONFIG_BPF_EVENTS`. This also keeps arena spin-lock diagnostics intact while
allowing `arena_spin_lock.bpf.o` to pass under `uml-veristat`.

---

### 0003 — `um: fix stub binary page alignment by removing -Wl,-n`

**Problem:** The UML stub binary was built with `-Wl,-n` in
`STUB_EXE_LDFLAGS`, which creates a non-demand-paged (OMAGIC) ELF output.
This causes the stub's LOAD segments to have `Align=0x8` instead of the
required `Align=0x1000` (page size). UML's `map_stub_pages()` requires
page-aligned LOAD segments and fails to boot with `mmap stub_exe` errors
when the alignment is wrong.

**Fix:** Remove `-Wl,-n` from `STUB_EXE_LDFLAGS` so the stub binary gets
page-aligned LOAD segments.

**Files changed:**
- `arch/um/kernel/skas/Makefile` (remove `-Wl,-n` from `STUB_EXE_LDFLAGS`)

---

### 0003b — `um/x86: enable eBPF JIT support and default-on JIT for UML`

**Problem:** `CONFIG_BPF_JIT` cannot be enabled on UML x86-64 because
`HAVE_EBPF_JIT` was not selected for the architecture. Without
`CONFIG_BPF_JIT=y`, `register_bpf_struct_ops()` returns `-EOPNOTSUPP`
immediately, so all struct_ops BPF programs (tcp congestion control, etc.)
fail to load. UML x86-64 can in fact use the x86-64 BPF JIT since it runs
as a regular Linux process on an x86-64 host.

**Fix:** Add:
- `select HAVE_EBPF_JIT if 64BIT` so `CONFIG_BPF_JIT=y` can be enabled
- `select ARCH_WANT_DEFAULT_BPF_JIT if 64BIT` so 64-bit UML boots with
  `net.core.bpf_jit_enable=1` by default, matching native x86-64

**Files changed:**
- `arch/x86/um/Kconfig`

---

### 0003c — `um/x86: wire up native x86 BPF JIT backend for UML`

**Problem:** After enabling `CONFIG_BPF_JIT` for UML x86-64, the kernel still
uses the weak generic BPF JIT stubs from `kernel/bpf/core.c`. UML's build path
does not link `arch/x86/net/`, where the real x86 BPF JIT backend lives, so
helpers like `bpf_jit_supports_kfunc_call()` keep returning `false`. This makes
kfunc-using programs fail with `JIT does not support calling kernel function`
even though JIT is enabled.

`arch/x86/net/bpf_jit_comp.c` also assumes native x86 support headers, ptregs
layout, text patching, mitigation, NOP, and per-cpu runtime symbols that UML
does not provide. The original `uml-veristat` path only needed load-time
verifier and JIT analysis. Runtime `test_progs` coverage adds stricter text
patching and syscall-dispatch requirements, which are handled later by patches
0012, 0013, and 0014.

UML's `text_poke()` implementation is also a warning stub. Without a UML-local
copy path, final JIT image installation emits noisy stack traces during
otherwise successful verbose-mode verification runs.

1. Export native x86 NOP and vsyscall definitions through UML `asm/` wrappers.
2. Provide the selector constants used by x86 speculation helpers.
3. Teach the JIT's `pt_regs` fixup table to use UML's `regs.gp[]` layout.
4. Provide the missing cpufeature mask fallbacks.
5. Provide UML-local verification-only shims for NOP tables, CFI mode,
   `text_poke_set()`, `smp_text_poke_single()`, `clear_bhb_loop()`, and
   `this_cpu_off`.
6. Route UML around native retpoline/BHB machinery that requires native x86
   thunk symbols.
7. Use a direct `memcpy()` for final JIT image copies on UML instead of routing
   through UML's warning-only `text_poke()` stub.

**Fix:** Link `arch/x86/net/` into `arch/x86/Makefile.um` and add the minimal
UML/x86 compatibility glue needed for `bpf_jit_comp.c` to build and link under
`ARCH=um`. Keeping the wiring and runtime shims together avoids an intermediate
patch that enables the native backend but leaves the UML kernel unbuildable.

**Result:** The full UML kernel links, and `bpf_jit_supports_kfunc_call()`
returns true in the final `linux` binary. Kfunc-using objects like
`test_send_signal_kern.bpf.o` and `xfrm_info.bpf.o` get past the old
`JIT does not support calling kernel function` failure and now fail later in
normal verifier/codegen paths. Verbose-mode runs no longer print spurious
`WARNING: arch/um/kernel/um_arch.c` / `text_poke+...` stack traces for normal
successful BPF verification.

**Files changed:**
- `arch/um/include/asm/cpufeature.h`
- `arch/x86/Makefile.um`
- `arch/x86/net/bpf_jit_comp.c`
- `arch/x86/um/asm/nops.h` (new)
- `arch/x86/um/asm/segment.h`
- `arch/x86/um/asm/vsyscall.h` (new)

---

### 0004 — `selftests/bpf: fix bpf_testmod.c compilation on UML`

**Problem:** `bpf_testmod.c` fails to compile as a kernel module when `ARCH=um`
due to two architecture-guard issues:

1. **`VSYSCALL_ADDR` undeclared** (line ~408): The surrounding code is guarded
   by `#ifdef CONFIG_X86_64`, which is defined on UML x86-64. However, UML's
   `asm/` include path goes through `arch/um/` rather than `arch/x86/`, so
   `<asm/vsyscall.h>` is not available and `VSYSCALL_ADDR` is undefined.

2. **`struct pt_regs` missing named fields** (lines ~607-617): The uprobe
   handler is guarded by `#ifdef __x86_64__` (a compiler macro). Since UML
   compiles as x86-64 userspace, `__x86_64__` is defined by GCC. But UML's
   `struct pt_regs` wraps a `uml_pt_regs` with a `gp[]` array, not the named
   fields `.cx`, `.ax`, `.r11` that the uprobe handler accesses.

**Fix:** Change the two guards to also exclude UML:
- `#if defined(CONFIG_X86_64) && !defined(CONFIG_UML)` for the vsyscall block
- `#if defined(__x86_64__) && !defined(CONFIG_UML)` for the uprobe handler block

The excluded code paths are non-functional on UML anyway (no vsyscall page, no
uprobe hardware support), so excluding them has no effect on verification
coverage.

**Files changed:**
- `tools/testing/selftests/bpf/test_kmods/bpf_testmod.c` (two guard changes)

---

### 0005 — `libbpf: tolerate duplicate base BTF candidates in relocation`

**Problem:** `btf__relocate()` maps distilled base BTF type IDs to the real
base BTF type IDs. Distilled base BTF intentionally keeps only name and size
for named composite types, because that is enough to rewrite split BTF
references back to the target base BTF.

Some base BTFs can still contain duplicate compatible named types. When one
distilled base type matches more than one compatible base candidate, the current
code treats the second candidate as fatal and rejects the whole relocation,
even though the distilled representation cannot observe a difference between
those candidates.

On UML this shows up while loading `bpf_testmod.ko`: duplicate vmlinux BTF
candidates prevent `bpf_testmod.ko`'s BTF from being registered in
`/sys/kernel/btf/bpf_testmod`.

Without `/sys/kernel/btf/bpf_testmod`, libbpf cannot find the module BTF when loading
any BPF program that references types from `bpf_testmod` (struct_ops, kfuncs, etc.),
and veristat fails with `-3 ESRCH` at the file level for all such programs.

**Fix:** Keep the first compatible base candidate for a distilled type and
ignore later compatible duplicates. Preserve the existing ambiguity check in
the other direction: if one base candidate matches multiple distilled base
types, the distilled base itself is ambiguous and relocation still fails.

This patch deliberately does not relax CO-RE relocation ambiguity. For
`BPF_CORE_TYPE_ID_TARGET`, the selected BTF ID is the relocated value, so
different target IDs remain observable and are handled separately in `0005b`.

**Files changed:**
- `tools/lib/bpf/btf_relocate.c` (keep first compatible duplicate base candidate)
- `tools/testing/selftests/bpf/prog_tests/btf_distill.c` (duplicate base-candidate
  coverage for primitive and struct cases)

**Result:** `bpf_testmod.ko` can register module BTF on UML despite duplicate
compatible base candidates, unblocking the module-backed selftests that
previously failed at object-open time with `-3 ESRCH`.

### 0005b — `libbpf: tolerate duplicate target type IDs in CO-RE relocation`

**Problem:** CO-RE `BPF_CORE_TYPE_ID_TARGET` relocations can see multiple
compatible target candidates in kernel BTF. For example, UML vmlinux BTF can
contain duplicate compatible `struct sockaddr_un` definitions. Field-offset
relocations can still verify that all candidates produce the same offset, but
`TYPE_ID_TARGET` returns a raw BTF ID, so otherwise compatible candidates appear
as an ambiguity even when either ID would be valid for `bpf_rdonly_cast()`.

**Fix:** In `relo_core.c`, keep the first non-poisoned candidate for
`BPF_CORE_TYPE_ID_TARGET` and skip later compatible candidates that only differ
by target type ID. Other relocation kinds keep the existing ambiguity checks.

**Files changed:**
- `tools/lib/bpf/relo_core.c`

## Patches 0006/0006b — REMOVED (superseded by 0017)

The former `0006` (preallocate arena range-tree nodes in sleepable paths) and
`0006b` (use sleepable allocation for arena page arrays) worked around
`kmalloc_nolock()` returning NULL on UML. That was a symptom, not a UML
limitation: UML never populated `boot_cpu_data.x86_capability`, so slab
freelist ABA protection (`__CMPXCHG_DOUBLE`, gated on `X86_FEATURE_CX16`)
was never enabled and `kmalloc_nolock()` failed by design. Patch `0017`
fixes the root cause by probing host CPU features, after which the arena
allocation, fault, and free paths work unmodified: the full verifier_arena
suite and the veristat arena corpus pass without these patches.

---

## Patch 0007 — selftests/bpf: make benchmark map definitions standalone-loadable

**Files:**
- `tools/testing/selftests/bpf/progs/bloom_filter_bench.c`
- `tools/testing/selftests/bpf/progs/bpf_hashmap_lookup.c`
- `tools/testing/selftests/bpf/progs/htab_mem_bench.c`

**Problem:** Benchmark programs (`bloom_filter_bench`, `bpf_hashmap_lookup`,
`htab_mem_bench`) intentionally let their userspace benchmark harnesses resize
and retune maps before loading. As raw `.bpf.o` inputs, though, those maps can
have zero `key_size`, `value_size`, or `max_entries`, so standalone loaders such
as `veristat` fail in `BPF_MAP_CREATE` before the verifier sees any program.

**Fix:** Give the benchmark maps small valid defaults:
- `bloom_filter_bench`: default `value_size` and `max_entries` for the array
  and bloom filter maps, and default `key_size`, `value_size`, and
  `max_entries` for the hash map.
- `bpf_hashmap_lookup`: default hash map key size, value size, and entry count.
- `htab_mem_bench`: default hash map value size and entry count.

The benchmark harnesses still call `bpf_map__set_*()` before load, so runtime
benchmark behavior remains configurable.

**Impact:** Fixes `bloom_filter_bench.bpf.o`, `bpf_hashmap_lookup.bpf.o`, and
`htab_mem_bench.bpf.o` (3 files, `-EINVAL`) without requiring veristat to guess
map dimensions.

---

## Patch 0007b — selftests/bpf: veristat: preserve zero max_entries for percpu cgroup storage

**File:** `tools/testing/selftests/bpf/veristat.c`

**Problem:** Veristat's `fixup_obj_maps()` sets `max_entries = 1` for most maps
whose object metadata leaves `max_entries` at zero. It already excludes cgroup
storage maps because they require `max_entries == 0`, but it missed
`BPF_MAP_TYPE_PERCPU_CGROUP_STORAGE`, which has the same requirement. Rewriting
that field produces false `BPF_MAP_CREATE -EINVAL` file-level failures.

**Fix:** Add `BPF_MAP_TYPE_PERCPU_CGROUP_STORAGE` to the max-entries fixup
exclusion list.

**Impact:** Fixes percpu cgroup storage users such as `map_ptr_kern.bpf.o`,
`netcnt_prog.bpf.o`, `percpu_alloc_array.bpf.o`,
`tailcall_cgrp_storage*.bpf.o`, and `verifier_cgroup_storage.bpf.o`.

---

## Patch 0008 — selftests/bpf: veristat: cap auto log size to avoid OOM

**File:** `tools/testing/selftests/bpf/veristat.c`

**Problem:** Veristat probes whether the kernel accepts "big" verifier log
buffers and, if it does, defaults to `UINT_MAX >> 2` for verbose mode. On UML
this is roughly 1 GiB, which exceeds the guest's default memory size and can
make `veristat -vl2` crash before it prints any verifier log output.

**Fix:** Keep the existing probe, but cap the automatically chosen default log
size to 64 MiB. Users can still request a larger buffer explicitly with
`--log-size`.

**Impact:** Prevents verbose-mode crashes in UML while preserving explicit
large-log opt-in behavior.

---

## Patch 0012 — um/x86: make synthetic BPF syscall wrappers patchable

**File:** `arch/x86/um/x64_syscall_wrappers.c`

**Problem:** The synthetic `__x64_sys_*` wrappers provide BTF attach targets,
but they did not reserve the 5-byte entry slot that BPF trampoline attachment
expects to patch. Once the trampoline address is in range, attaching fentry
programs to these wrappers fails because the first five bytes are normal
function instructions instead of an expected NOP sequence.

**Fix:** Annotate the synthetic wrappers with
`patchable_function_entry(5, 0)` and keep prototypes so
`-Wmissing-prototypes` remains clean.

**Impact:** Makes fentry/fexit attachment to UML-provided syscall wrapper
targets structurally possible. A focused `bloom_filter_map` runtime probe uses
`fentry/__x64_sys_getpgid` and depends on this.

---

## Patch 0013 — um/x86: make BPF text pokes writable under UML

**File:** `arch/x86/net/bpf_jit_comp.c`

**Problem:** UML's BPF JIT compatibility glue had a memcpy-based
`smp_text_poke_single()` shim. That is enough for some generated BPF text, but
it panics when BPF trampoline attach tries to patch protected UML kernel text
for fentry/fexit links.

GCC emits five single-byte NOPs for `patchable_function_entry(5, 0)`, while the
local UML NOP table used the optimized x86 5-byte NOP. BPF text-poke compares
the bytes exactly, so the mismatch produced `-EBUSY` before the writable-text
problem was fixed.

**Fix:** Make the UML-local 5-byte NOP match the wrapper compiler output and
temporarily make the target host mapping writable before copying text-poke
bytes. UML cannot safely restore RX immediately in this path, so the mapping is
left writable after the poke.

**Impact:** Allows runtime BPF trampoline attachment to synthetic syscall
wrapper targets. Together with the lower `uml-test-progs` default memory, this
turns the focused `bloom_filter_map` probe from `-ERANGE`/`-EBUSY`/panic into a
passing test.

---

## Patch 0014 — um/x86: route selected syscalls through BPF wrappers

**File:** `arch/um/kernel/skas/syscall.c`

**Problem:** The synthetic `__x64_sys_*` wrappers are BTF-visible and
patchable after patches 0001 and 0012, but the UML syscall path still called
the underlying `sys_*` table entries directly. fentry/fexit programs could
attach to the wrappers successfully and still never execute.

**Fix:** Route the five syscall numbers covered by the synthetic wrapper set
through those wrappers before falling back to the normal UML syscall table
path. The wrappers delegate to the same `sys_*` implementations, so syscall
behavior remains unchanged while BPF trampoline attachments observe the wrapper
entry.

**Impact:** Makes runtime fentry/fexit tests that require the attached program
to actually fire pass. Focused probes show `map_btf` and `user_ringbuf` pass
after this change.

---

## Patch 0015 — bpf: add probe read helpers to UML verification stubs

**File:** `kernel/bpf/bpf_verification_stubs.c`

**Problem:** UML verification kernels intentionally build without
`CONFIG_BPF_EVENTS`, so they do not link `kernel/trace/bpf_trace.o`. That
leaves the weak `bpf_probe_read_kernel*` helper prototypes in
`kernel/bpf/helpers.c` without function pointers.

`BPF_PROG_TYPE_SYSCALL` delegates these helpers to the tracing helper
prototype path. Generated light-skeleton loader programs use
`bpf_probe_read_kernel()` to read their loader context before they create and
load the real BPF object. Without the helper implementation, the loader program
itself is rejected with:

```text
program of this type cannot use helper bpf_probe_read_kernel#113
```

**Fix:** Provide `bpf_probe_read_kernel()` and
`bpf_probe_read_kernel_str()` implementations from the UML verification-stub
object, mirroring the helper prototypes normally supplied by
`kernel/trace/bpf_trace.c`.

**Impact:** Allows light-skeleton syscall loader programs to execute in the
no-`BPF_EVENTS` UML configuration. Focused runtime probes show all five
`ringbuf` subtests pass after this change. `map_ptr` also gets past lskel load
and test-run setup; its remaining failure is a separate CO-RE relocation issue
for direct `struct bpf_ringbuf` field-offset access.

---

## Patch 0013b — um/x86: build with -fcf-protection=none

**File:** `arch/x86/Makefile.um`

**Problem:** Native x86 kernel builds pass `-fcf-protection=none` unless
`CONFIG_X86_KERNEL_IBT` re-enables branch protection, but the UML makefiles
never set the flag. Toolchains defaulting to `-fcf-protection=full` (Ubuntu,
Fedora) prepend a 4-byte `endbr64` to every kernel function, displacing the
synthetic wrappers' `patchable_function_entry(5, 0)` slot. BPF text-poke then
finds `endbr64` where it expects NOPs and trampoline attach fails with
`-EBUSY` — but only on hosts whose compiler enables CET by default.

**Fix:** Pass `-fcf-protection=none` for UML builds, matching native x86.
UML cannot use CET, so the markers were dead weight.

**Impact:** `map_btf`, `user_ringbuf`, and `map_in_map` `fentry.s` attach
work regardless of the build distro's compiler defaults.

---

## Patch 0016 — um: dispatch BPF extable fixups in kernel-mode faults

**Files:** `arch/um/kernel/trap.c`, `arch/x86/um/os-Linux/mcontext.c`,
`arch/um/include/shared/arch.h`

**Problem:** JIT'ed BPF programs rely on exception fixups for deliberately
faulting loads (`BPF_PROBE_MEM`, arena accesses): the fault should zero the
destination register and skip the access. UML's `segv()` panicked on
kernel-mode user-range faults before attempting any fixup
(`verifier_arena/basic_alloc1` panicked the guest), and the legacy
`arch_fixup()` misparses modern typed extable entries. Fixups also edit a
`uml_pt_regs` copy while the faulting context resumes from the mcontext, so
without a write-back the same instruction faults forever.

**Fix:** Add `bpf_extable_fixup()`, dispatching to `ex_handler_bpf()`, tried
both before the user-range panic and before `arch_fixup()`; add
`mc_set_regs()` (inverse of `get_regs_from_mc()`) to write the fixed
registers back to the mcontext.

**Impact:** verifier_arena runs to completion; deliberate use-after-free
arena reads return zero as expected.

---

## Patch 0016b — um: run BPF extable fixups for unresolvable vmalloc-range faults

**File:** `arch/um/kernel/trap.c`

**Problem:** `segv()` treats any kernel-mode fault in `[start_vm, end_vm)`
as a lazy TLB flush: sync and retry, unconditionally. A deliberately
faulting BPF load on an unmapped arena page whose kernel address lands in
the vmalloc window therefore re-faults through that branch forever — the
0016 fixup paths never run. This hung the guest on verifier_arena_large
(4GB arena), while the smaller verifier_arena arena happened to place its
pages outside the window and took the panic path 0016 fixed.

**Fix:** After a successful `um_tlb_sync()`, check whether the faulting
address has a present PTE. If not, attempt the BPF extable fixup; the
legacy retry is preserved for non-BPF faults.

**Impact:** All six verifier_arena_large subtests pass; the chunk no longer
needs a denylist entry.

---

## Patch 0017 — um: probe host CPU features to enable cmpxchg128 and kmalloc_nolock

**Files:** `arch/x86/um/host_cpu_features.c` (new), `arch/x86/um/Makefile`,
`arch/um/kernel/um_arch.c`, `arch/um/include/shared/arch.h`,
`arch/um/Kconfig`

**Problem:** UML initializes `boot_cpu_data.x86_capability` to all-zero and
never probes the host CPU, so every `boot_cpu_has()` check fails. The slab
allocator enables freelist ABA protection (`__CMPXCHG_DOUBLE`) only when
`system_has_cmpxchg128()` reports `X86_FEATURE_CX16`, and UML also lacked
`HAVE_ALIGNED_STRUCT_PAGE`, which compiles the ABA support out. Without the
flag, `kmalloc_nolock()` returns NULL unconditionally, breaking BPF arena
range-tree updates, non-sleepable arena allocation, and the arena free path.

**Fix:** Probe CPUID leaf 1 during `setup_arch()` (before slab init) and set
`X86_FEATURE_CX16` when the host supports `cmpxchg16b`; select
`HAVE_ALIGNED_STRUCT_PAGE`. The cmpxchg128 primitives come from the shared
x86 headers UML already uses.

**Impact:** All 20 verifier_arena subtests pass, including `*_nosleep`
variants and re-allocation after free. Supersedes the former 0006/0006b
preallocation workarounds.

---

## Verification Notes

`uml-veristat` is validating two things at once:

1. generic verifier correctness
2. UML/x86 backend support for lowering the verified program

The kernel does not separate those into two visible phases. Instead, the
verifier directly consults JIT/backend capability hooks such as:

- `bpf_jit_supports_kfunc_call()`
- `bpf_jit_supports_far_kfunc_call()`
- `bpf_jit_supports_arena()`
- `bpf_jit_supports_insn(..., true)`
- `bpf_jit_supports_percpu_insn()`
- `bpf_jit_supports_subprog_tailcalls()`
- `bpf_jit_supports_private_stack()`
- `bpf_jit_supports_exceptions()`
- `bpf_jit_supports_fsession()`
- `bpf_jit_supports_ptr_xchg()`
- `bpf_jit_supports_timed_may_goto()`

Arena is the most important example for this patch stack. Upstream verifier code
rejects `BPF_MAP_TYPE_ARENA` unless JIT is requested and the backend reports
arena support. That is because arena accesses are not plain generic memory
operations; they rely on JIT-specific lowering of arena pointers and
`BPF_PROBE_MEM32`/`BPF_PROBE_MEM32SX` fixups.

For `uml-veristat`, this means some failures are best read as:

- the program is semantically valid BPF, but
- current UML/x86 JIT support is incomplete for that feature

That distinction matters when evaluating remaining failures and deciding
whether a fix belongs in:

- generic verifier logic
- UML/JIT backend support
- selftest harness assumptions
