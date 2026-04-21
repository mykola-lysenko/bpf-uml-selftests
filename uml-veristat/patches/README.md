# UML BPF Kernel Patches

These patches are applied to the bpf-next kernel tree after checkout to enable
BPF verification on User Mode Linux (UML). They are applied by `build.sh`
automatically using `git am` (idempotent: already-applied patches are skipped).

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

### 0002 — `bpf: add BPF_TRACING_STUBS for kernels without PERF_EVENTS (UML)`

**Problem:** `CONFIG_BPF_EVENTS` depends on `PERF_EVENTS` and
`KPROBE_EVENTS`/`UPROBE_EVENTS`. On UML these hardware-dependent subsystems are
unavailable, so `BPF_PROG_TYPE_KPROBE`, `TRACEPOINT`, `PERF_EVENT`,
`RAW_TRACEPOINT`, `RAW_TRACEPOINT_WRITABLE`, and `TRACING` are not registered.
`BPF_PROG_LOAD` returns `-EINVAL` for these types, causing veristat to report
failures for all tracing-type BPF programs.

**Fix:** Add a new Kconfig option `CONFIG_BPF_TRACING_STUBS` (default `y` when
`UML`) that provides minimal `bpf_verifier_ops` and `bpf_prog_ops` for all six
tracing program types. The stubs delegate to `bpf_base_func_proto()` for helper
access and `bpf_tracing_btf_ctx_access()` for context type checking — both
available without `BPF_EVENTS`. Programs using these stubs can be verified but
not attached or executed.

**Files changed:**
- `kernel/bpf/bpf_tracing_stubs.c` (new)
- `kernel/bpf/Kconfig` (add `CONFIG_BPF_TRACING_STUBS`)
- `kernel/bpf/Makefile` (add `bpf_tracing_stubs.o`)
- `include/linux/bpf_types.h` (add `#elif CONFIG_BPF_TRACING_STUBS` branch)

---

### 0003 — `um/x86: fix UML boot and enable BPF_JIT for struct_ops support`

**Problem 1 (UML boot):** The UML stub binary was built with `-Wl,-n` in
`STUB_EXE_LDFLAGS`, which creates a non-demand-paged ELF output. This causes
the stub's LOAD segments to have `Align=0x8` instead of the required
`Align=0x1000` (page size). UML's `map_stub_pages()` requires page-aligned
segments and fails to boot with `mmap stub_exe` errors when the alignment is
wrong.

**Problem 2 (struct_ops):** `CONFIG_BPF_JIT` cannot be enabled on UML x86-64
because `HAVE_EBPF_JIT` was not selected for the architecture. Without
`CONFIG_BPF_JIT=y`, `register_bpf_struct_ops()` returns `-EOPNOTSUPP`
immediately, so all struct_ops BPF programs (tcp congestion control, etc.) fail
to load. UML x86-64 can in fact use the x86-64 BPF JIT since it runs as a
regular Linux process on an x86-64 host.

**Fix:**
1. Remove `-Wl,-n` from `STUB_EXE_LDFLAGS` in `arch/um/kernel/skas/Makefile`
   so the stub binary has page-aligned LOAD segments.
2. Add `select HAVE_EBPF_JIT if 64BIT` to the `UML_X86` config block in
   `arch/x86/um/Kconfig` so that `CONFIG_BPF_JIT=y` can be selected and
   struct_ops programs can be verified.

**Files changed:**
- `arch/um/kernel/skas/Makefile` (remove `-Wl,-n` from `STUB_EXE_LDFLAGS`)
- `arch/x86/um/Kconfig` (add `select HAVE_EBPF_JIT if 64BIT`)

---

### 0004 — `selftests/bpf: fix bpf_testmod.c compilation on UML`

**Problem:** `bpf_testmod.c` fails to compile as a kernel module when `ARCH=um`
due to two architecture-guard issues:

1. **`VSYSCALL_ADDR` undeclared** (line ~408): The surrounding code is guarded
   by `#ifdef CONFIG_X86_64`, which is defined on UML x86-64. However, UML's
   `asm/` include path goes through `arch/um/` rather than `arch/x86/`, so
   `<asm/vsyscall.h>` is not available and `VSYSCALL_ADDR` is undefined.

2. **`struct pt_regs` missing named fields** (lines ~607–617): The uprobe
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

### 0005 — `bpf: extend BPF_TRACING_STUBS with STACK_TRACE map and callchain stubs`

**Problem:** Without `CONFIG_PERF_EVENTS`, `BPF_MAP_TYPE_STACK_TRACE` is not registered
and the `bpf_get_stackid()`/`bpf_get_stack()` helpers are unavailable. This caused
veristat to fail with `-EINVAL` when processing programs that use stack trace maps
(`pyperf*`, `strobemeta*`, `stacktrace_*` — 16 files). Additionally, `CONFIG_CGROUP_BPF`
and `CONFIG_XDP_SOCKETS` were not enabled, causing `-EINVAL` for cgroup storage maps
and XSK maps.

**Fix:**

1. `kernel/bpf/stackmap.c`: compile when `CONFIG_BPF_TRACING_STUBS` is set (in addition
   to `CONFIG_PERF_EVENTS`). Wrap the perf_event-specific `bpf_get_stackid_pe` and
   `bpf_get_stack_pe` functions in `#ifdef CONFIG_PERF_EVENTS` since they reference
   `struct perf_event` internals.

2. `kernel/bpf/bpf_tracing_stubs.c`: add stub implementations for the callchain buffer
   API (`get_callchain_buffers`, `put_callchain_buffers`, `get_callchain_entry`,
   `put_callchain_entry`, `get_perf_callchain`) and `sysctl_perf_event_max_stack`.
   These are `WARN_ON_ONCE` stubs since veristat never executes programs.

3. `include/linux/perf_event.h`: declare the stub symbols under
   `#ifdef CONFIG_BPF_TRACING_STUBS` inside the `!CONFIG_PERF_EVENTS` block.

4. `include/linux/bpf_types.h`: register `BPF_MAP_TYPE_STACK_TRACE` when
   `CONFIG_BPF_TRACING_STUBS` is set, mirroring the `CONFIG_PERF_EVENTS` guard.

Also enables `CONFIG_CGROUP_BPF=y` and `CONFIG_XDP_SOCKETS=y` in the UML defconfig to
fix `-EINVAL` failures for cgroup storage maps (`cg_storage_multi_shared`,
`cgroup_storage`, `lsm_cgroup`) and XSK maps (`xdp_hw_metadata`, `xdp_metadata`,
`xsk_xdp_progs`).

**Files changed:**
- `kernel/bpf/bpf_tracing_stubs.c` (add callchain stubs)
- `kernel/bpf/stackmap.c` (add `CONFIG_BPF_TRACING_STUBS` guard)
- `kernel/bpf/Makefile` (compile stackmap.c when `CONFIG_BPF_TRACING_STUBS`)
- `include/linux/perf_event.h` (add stub declarations)
- `include/linux/bpf_types.h` (register `STACK_TRACE` under stubs)

**Result:** veristat success rate improves from 1477 → 1597 programs (+120, +8.1%).
25 files that previously failed with `-EINVAL` now process successfully.
