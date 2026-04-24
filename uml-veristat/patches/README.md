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

### 0002 — `bpf: add BPF_TRACING_STUBS with stack trace support for UML`

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

**Fix:** Add a new Kconfig option `CONFIG_BPF_TRACING_STUBS` (default `y` when
`UML`) that:

1. Provides minimal `bpf_verifier_ops` and `bpf_prog_ops` for all six tracing
   program types, using a `DEFINE_STUB_OPS()` macro to eliminate boilerplate.
   The stubs delegate to `bpf_base_func_proto()` for helper access and
   `bpf_tracing_btf_ctx_access()` for context type checking.

2. Compiles `stackmap.c` and provides stub callchain buffer functions so
   `BPF_MAP_TYPE_STACK_TRACE` maps can be created. The execution-time stubs
   use `WARN_ON_ONCE` since veristat never runs programs.

3. Registers `BPF_MAP_TYPE_STACK_TRACE` in `bpf_types.h` under the stubs
   config, mirroring the existing `CONFIG_PERF_EVENTS` guard.

**Files changed:**
- `kernel/bpf/bpf_tracing_stubs.c` (new — stub ops + callchain stubs)
- `kernel/bpf/Kconfig` (add `CONFIG_BPF_TRACING_STUBS`)
- `kernel/bpf/Makefile` (add `bpf_tracing_stubs.o`, compile `stackmap.o`)
- `kernel/bpf/stackmap.c` (guard perf_event-specific functions)
- `include/linux/bpf_types.h` (add `#elif CONFIG_BPF_TRACING_STUBS` branch,
  register `STACK_TRACE` map type)
- `include/linux/perf_event.h` (declare callchain stub symbols)

**Result:** veristat success rate improves from ~1,200 to 1,597 programs.

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

`arch/x86/net/bpf_jit_comp.c` also assumes native x86 support headers and ptregs
layout. UML needs a few small compatibility shims:

1. Export native x86 NOP and vsyscall definitions through UML `asm/` wrappers.
2. Provide the selector constants used by x86 speculation helpers.
3. Teach the JIT's `pt_regs` fixup table to use UML's `regs.gp[]` layout.
4. Provide the missing cpufeature mask fallbacks and declare `this_cpu_off`.

**Fix:** Link `arch/x86/net/` into `arch/x86/Makefile.um` and add the minimal
UML/x86 compatibility glue needed for `bpf_jit_comp.c` to build under
`ARCH=um`.

**Files changed:**
- `arch/um/include/asm/cpufeature.h`
- `arch/x86/Makefile.um`
- `arch/x86/net/bpf_jit_comp.c`
- `arch/x86/um/asm/nops.h` (new)
- `arch/x86/um/asm/segment.h`
- `arch/x86/um/asm/vsyscall.h` (new)

---

### 0003d — `um/x86: add verification-only runtime shims for BPF JIT`

**Problem:** After linking `arch/x86/net/` into UML, the native x86 BPF JIT
backend builds but the full UML kernel still fails to link. The backend pulls
in a larger slice of native x86 runtime support that UML does not provide:
`x86_nops`, `cfi_mode`, `text_poke_set()`, `smp_text_poke_single()`,
`clear_bhb_loop()`, `this_cpu_off`, and retpoline thunk machinery.

For `uml-veristat`, we do not need full native text-patching or mitigation
semantics. We only need the JIT to compile programs far enough for load-time
analysis. The generated code is never executed inside UML.

**Fix:** Add UML-only runtime shims directly in `arch/x86/net/bpf_jit_comp.c`
and bypass the native mitigation paths that require retpoline thunk arrays:

1. Provide local x86 NOP tables.
2. Force `cfi_mode = CFI_OFF`.
3. Stub `text_poke_set()` and `smp_text_poke_single()` with `memset`/`memcpy`.
4. Provide a zero `this_cpu_off` symbol and empty `clear_bhb_loop()`.
5. Use the simple indirect-jump path on UML instead of retpoline thunk targets.
6. Skip BHB barrier emission on UML.

**Result:** The full UML kernel links, and `bpf_jit_supports_kfunc_call()`
returns true in the final `linux` binary. Kfunc-using objects like
`test_send_signal_kern.bpf.o` and `xfrm_info.bpf.o` get past the old
`JIT does not support calling kernel function` failure and now fail later in
normal verifier/codegen paths.

**Files changed:**
- `arch/x86/net/bpf_jit_comp.c`

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

### 0005 — `bpf: btf_relocate: keep first match on multiple same-size candidates`

**Problem:** On UML, glibc headers included by UML driver files (`arch/um/drivers/`)
produce duplicate BTF types in vmlinux with structurally equivalent but differently-named
members (e.g. `struct in6_addr` with `in6_u` vs `__in6_u`). When `bpf_testmod.ko` is
loaded, `btf_relocate()` validates the module BTF against vmlinux BTF and encounters
these duplicate candidates. The existing code treats multiple candidates as an error
(`-EINVAL`), which prevents `bpf_testmod.ko`'s BTF from being registered in
`/sys/kernel/btf/bpf_testmod`.

Without `/sys/kernel/btf/bpf_testmod`, libbpf cannot find the module BTF when loading
any BPF program that references types from `bpf_testmod` (struct_ops, kfuncs, etc.),
and veristat fails with `-3 ESRCH` at the file level for all such programs.

**Fix:** Change the multiple-candidates error path to a `pr_debug` message and keep the
first match. Both candidates are structurally equivalent (same size, same layout), so
either is a valid relocation target. The first match is the one from the canonical kernel
type, which is the correct choice.

**Files changed:**
- `tools/lib/bpf/btf_relocate.c` (change error to debug+continue for multiple candidates)

**Result:** veristat success rate improves from 1597 to 1669 programs (+72, +4.5%).
52 files that previously failed with `-3 ESRCH` (module BTF not found) now process
successfully, including all `struct_ops_*`, `kfunc_call_*`, `iters_testmod*`,
`kprobe_multi*`, and `epilogue_*` files.

## Patch 0006 — libbpf: relo_core: keep first TYPE_ID_TARGET candidate on duplicate types

**File:** `tools/lib/bpf/relo_core.c`

**Problem:** On UML, vmlinux BTF contains structurally-equivalent duplicate types
(e.g. `struct sockaddr_un` appears twice — once from the kernel, once from glibc
headers included during the build). When libbpf performs a `BPF_CORE_TYPE_ID_TARGET`
CO-RE relocation, it finds two matching candidates with different BTF type IDs.
The existing ambiguity check treats this as a fatal error (`-EINVAL`), causing
`getsockname_unix_prog.bpf.o`, `netif_receive_skb.bpf.o`, and similar programs
to fail with "relocation decision ambiguity".

**Fix:** When two candidates both succeed for a `BPF_CORE_TYPE_ID_TARGET`
relocation but produce different `new_val` (different BTF type IDs), keep the
first (lower) BTF ID and skip the duplicate. This mirrors the approach in
`btf_relocate.c` (patch 0005).

**Impact:** Fixes `getsockname_unix_prog.bpf.o`, `netif_receive_skb.bpf.o`,
`htab_mem_bench.bpf.o`, `stream.bpf.o` (4 files, -22 EINVAL).

---

## Patch 0007 — selftests/bpf: veristat: fix up zero key_size and value_size in maps

**File:** `tools/testing/selftests/bpf/veristat.c`

**Problem:** Benchmark programs (`bloom_filter_bench`, `bpf_hashmap_lookup`,
`htab_mem_bench`) define maps with zero `key_size` and/or `value_size`, expecting
the benchmark harness to fill these at runtime. Veristat's `fixup_obj_maps()`
already handles `max_entries == 0` but does not fix up zero `key_size` or
`value_size`, causing `bpf_object__prepare()` to fail with `-EINVAL` from the
kernel's `map_create` path.

**Fix:** Extend `fixup_obj_maps()` to set `value_size = 1` and `key_size = 4`
when they are zero.  Map types that require zero by design are excluded:
- Bloom filters, queues, and stacks: `key_size == 0` is valid
- Ringbuf and user_ringbuf: both `key_size == 0` and `value_size == 0` are
  required; these maps get a separate `max_entries = 4096` fixup (page-aligned
  power-of-2) instead

**Impact:** Fixes `bloom_filter_bench.bpf.o`, `bpf_hashmap_lookup.bpf.o`,
`htab_mem_bench.bpf.o` (3 files, -22 EINVAL).

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

## Patch 0009 — bpf: add BPF_LSM_STUBS for kernels without BPF_EVENTS

**Files:** `kernel/bpf/bpf_lsm_stubs.c` (new), `kernel/bpf/Kconfig`,
`kernel/bpf/Makefile`, `include/linux/bpf_types.h`, `include/linux/bpf_lsm.h`,
`fs/Makefile`

**Problem:** `CONFIG_BPF_LSM` depends on `BPF_EVENTS` which requires
`PERF_EVENTS`, making it impossible to enable on UML. Without `BPF_LSM`,
`BPF_PROG_TYPE_LSM` is not registered so LSM programs (`SEC("lsm/...")`)
fail to load. `BPF_MAP_TYPE_INODE_STORAGE` is also unavailable, and the
FS kfuncs (`bpf_get_file_xattr`, `bpf_get_dentry_xattr`) are not compiled.

**Fix:** Add `CONFIG_BPF_LSM_STUBS` (default `y` on UML) that depends on
`BPF_SYSCALL`, `BPF_JIT`, and `SECURITY` but not `BPF_EVENTS`. The stub
provides:
- Weak noinline `bpf_lsm_*` nop functions (BTF attach targets via `LSM_HOOK`)
- BTF ID sets for hook validation (`bpf_lsm_hooks`, `sleepable_lsm_hooks`, etc.)
- `bpf_lsm_verify_prog()`, `bpf_lsm_is_sleepable_hook()`, `bpf_lsm_is_trusted()`,
  `bpf_lsm_get_retval_range()`
- Minimal `lsm_verifier_ops` using `btf_ctx_access`

`bpf_inode_storage.c` and `fs/bpf_fs_kfuncs.c` are compiled under either
`CONFIG_BPF_LSM` or `CONFIG_BPF_LSM_STUBS`.

**Impact:** Fixes `local_storage`, `map_kptr`, `map_ptr_kern`, `test_get_xattr`,
`test_map_in_map`, `verifier_vfs_reject`, `xfrm_info` (7 files). Total
failed-to-process files drops from 23 to 18.

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
