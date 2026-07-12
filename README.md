# `uml-veristat`

`uml-veristat` is a drop-in CLI replacement for `veristat` that runs BPF verification inside a User-Mode Linux (UML) guest running the bleeding-edge `bpf-next` kernel.

It allows you to test BPF programs against the latest upstream verifier without needing root privileges, QEMU, KVM, or a dedicated VM.

## How it works

When you run `uml-veristat prog.bpf.o`:
1. It boots a pre-compiled UML kernel (`linux`) in the background.
2. The UML guest mounts your host filesystem via `hostfs` so it can see your `.bpf.o` files.
3. It runs the real `veristat` binary *inside* the UML guest.
4. It streams the verifier output back to your terminal and exits with `veristat`'s exact exit code.

Boot overhead is typically under 1 second.

## Setup

Before you can use `uml-veristat`, you need to build the UML kernel and the `veristat` binary. A one-time setup script is provided.

```bash
cd uml-veristat
./build.sh
```

### What `build.sh` does
1. Installs host build dependencies (`apt`, `dnf`, `zypper`, or `pacman`).
2. Downloads a pre-built LLVM/Clang release from GitHub (or builds from source with `--llvm-source`).
3. Builds `pahole` (v1.31) from source.
4. Clones the latest `bpf-next` kernel tree.
5. Applies the UML patch stack to enable full BPF verification on UML (see `patches/`).
6. Builds the UML kernel (`linux`) with BPF and BTF enabled.
7. Builds the `veristat` binary.
8. Installs the artifacts to `~/.local/share/uml-veristat/`.

The selftests build runs in keep-going mode. A small set of UML-incompatible or
upstream-drifting selftests can fail to compile without aborting the overall
install. The supported standalone corpus is tracked by
`scripts/report_coverage.py`.

*Note: The initial build takes about 15–20 minutes depending on your CPU and network speed. Subsequent builds (e.g. `./build.sh --update`) are incremental and much faster.*

## Usage

Simply use `uml-veristat` exactly as you would use `veristat`:

```bash
# Basic verification
./uml-veristat my_prog.bpf.o

# Show detailed verifier log on failure
./uml-veristat -l 1 my_prog.bpf.o

# Compare two programs
./uml-veristat -C old.bpf.o new.bpf.o
```

### GDB Debugging

To stop the UML guest before `veristat` runs and attach host `gdb` to the UML
kernel process, use:

```bash
./uml-veristat --gdb-wait my_prog.bpf.o
```

The wrapper will:

1. Boot UML and pause before `veristat` runs
2. Print the UML host PID and example `gdb` commands
3. Wait until you resume the guest by creating the trigger file it prints

This reuses the same host-attach model documented in
[`gdb_demo/`](gdb_demo), but against the real
installed `uml-veristat` kernel and binaries. The recommended
[`verifier.gdb`](gdb_demo/verifier.gdb) script
now includes the usual UML signal handling and default verifier breakpoints.

### Environment Variables

You can override the paths to the kernel and veristat binaries using environment variables:

- `UML_KERNEL`: Path to the UML kernel binary (default: `~/.local/share/uml-veristat/linux`)
- `VERISTAT`: Path to the veristat binary (default: `~/.local/share/uml-veristat/veristat`)
- `UML_MEM`: Memory to allocate to the UML guest (default: `512M`)
- `UML_VERBOSE`: Set to `1` to see the full UML kernel boot log (useful for debugging kernel panics)
- `UML_MODULES`: Space-separated kernel modules (`.ko`) to load before running veristat (defaults to the installed BPF selftest modules; set to `""` to disable)

### Running `test_progs` in UML

`uml-test-progs` runs the linked BPF selftests harness inside the same UML
kernel. It is intended for runtime triage and baseline collection, while
`uml-veristat` remains the standalone verifier tool.

```bash
./uml-test-progs --list
./uml-test-progs --count
./uml-test-progs -j1 --watchdog-timeout=60 -t arena
```

The runner mounts bpffs, cgroup2, and debugfs when available, brings loopback
up, and exposes the BPF selftest modules from the selftests output directory so
`test_progs` can load them through its normal helper path.

## Kernel Patches

The `patches/` directory is split into two ordered folders:

- `patches/uml-veristat/`: the base UML veristat stack.
- `patches/bpf-selftests-uml/`: BPF selftests patches and extra runtime
  `test_progs` support applied after the base stack.

The current full stack contains 23 patches applied to the `bpf-next` kernel
tree to enable full BPF verification on UML:

| Patch | Description | Programs fixed |
|-------|-------------|----------------|
| 0001 | Add `__x64_sys_*` wrappers for BPF selftest compatibility | fentry/kprobe attach targets |
| 0002 | Add hidden UML verification stubs for tracing, trace-printk helpers, stack trace, and gated LSM support | tracing/LSM types + maps, `bpf_printk()` users |
| 0002b | Add `test_run` support to tracing and raw tracepoint verification stubs | runtime `test_progs` coverage for tracing/raw_tp stubs |
| 0003 | Fix UML stub page alignment (`-Wl,-n` removal) | UML boot fix |
| 0003b | Enable eBPF JIT support and default-on JIT for UML x86-64 | struct_ops + default guest JIT |
| 0003c | Wire the native x86 BPF JIT backend into UML with runtime shims | real JIT capability hooks + clean verbose diagnostics |
| 0003d | Support far BPF calls in the UML x86 JIT | kfunc/helper calls outside direct-call range |
| 0004 | Fix `bpf_testmod.c` compilation on UML | bpf_testmod module |
| 0005 | Tolerate duplicate base BTF candidates during split-BTF relocation | btf_relocate |
| 0005b | Tolerate duplicate target type IDs during CO-RE relocation | `bpf_core_cast()` / `bpf_rdonly_cast()` users |
| 0006 | Preallocate arena range-tree nodes in sleepable paths | arena map creation + arena globals copied through mmap |
| 0006b | Use sleepable allocation for temporary arena page arrays | sleepable `bpf_arena_alloc_pages()` users |
| 0007 | Add standalone defaults to benchmark map definitions | benchmark objects with harness-resized maps |
| 0007b | Preserve zero `max_entries` for percpu cgroup storage in veristat | percpu cgroup storage maps |
| 0008 | Cap veristat auto log size to avoid UML OOM | verbose log stability |
| 0009 | Include `btf_ptr.h` in `bpf_iter_task_btf` | permissive `test_progs` build coverage |
| 0009b | Validate BPF probe-read memory against UML ranges | runtime probe-read safety for UML verification stubs |
| 0010 | Keep `test_progs` running when the verification key cannot be registered | UML runtime selftest harness |
| 0011 | Fix arena allocator globals for the ASM fallback path | `arena_htab_asm` |
| 0012 | Make synthetic syscall wrappers patchable | fentry/fexit attachment to `__x64_sys_*` wrappers |
| 0013 | Make BPF text pokes writable under UML | runtime BPF trampoline attach/detach |
| 0014 | Route selected syscalls through synthetic wrappers | runtime fentry/fexit execution on `__x64_sys_*` wrappers |
| 0015 | Add probe-read helpers to UML verification stubs | light-skeleton BPF syscall loader programs |

### Patch-to-Selftest Correspondence

The patch stack is not strictly one-patch-per-selftest. Some patches are pure
infrastructure prerequisites, while others unlock whole classes of selftests.
The table below shows the current practical correspondence.

| Patch | Main area | Representative selftests or classes unlocked |
|-------|-----------|----------------------------------------------|
| 0001 | x86-64 syscall wrapper BTF attach targets on UML | Syscall attach-target tests using `SYS_PREFIX`, such as `bpf_syscall_macro.c` and other `__x64_sys_*` kprobe/fentry/raw_tp cases |
| 0002 | verification-only tracing/LSM/stack-trace support without `PERF_EVENTS`, plus `bpf_trace_printk()`/`bpf_trace_vprintk()` helper prototypes without `BPF_EVENTS` | Tracing-type and stack-trace users such as `pyperf*`, `strobemeta*`, `stacktrace_*`; `bpf_printk()` users such as `trace_printk.bpf.o`, `test_tunnel_kern.bpf.o`, and `arena_spin_lock.bpf.o`; plus LSM/storage-style cases like `local_storage`, `map_kptr`, `map_ptr_kern`, `test_get_xattr`, `test_map_in_map`, `verifier_vfs_reject` |
| 0002b | `test_run` hooks for verification stubs | Runtime tests whose programs load through stubbed tracing/raw_tp program types, including `arena_atomics` |
| 0003 | UML boot fix | Global prerequisite: all `uml-veristat` selftests depend on the UML guest booting at all |
| 0003b | JIT enablement and default-on JIT | Struct-ops and JIT-gated program classes, including `struct_ops_*`, `tcp_ca_*`, and early kfunc-capable loads |
| 0003c | Real x86 JIT capability hooks in UML, plus the UML runtime shims needed to link and use the backend for verification | Kfunc-using objects that used to fail with `JIT does not support calling kernel function`, such as `test_send_signal_kern.bpf.o`, `xfrm_info.bpf.o`, and parts of `test_tunnel_kern.bpf.o`; also suppresses `text_poke()` WARN noise in verbose-mode diagnostics |
| 0003d | Indirect far-call lowering in the UML x86 JIT | Kfunc/helper calls whose host addresses are outside the x86 direct-call immediate range, including arena kfunc paths under UML |
| 0004 | `bpf_testmod.ko` buildability on UML | Global prerequisite for `bpf_testmod`-backed selftests, including `struct_ops_module*`, `kfunc_call_*`, `iters_testmod*`, `kprobe_multi*`, and related module-BTF tests |
| 0005 | Duplicate base-BTF candidate handling for split-BTF relocation | `bpf_testmod` module-BTF registration, which unblocks module-backed classes such as `struct_ops_*`, `kfunc_call_*`, `iters_testmod*`, `kprobe_multi*`, and `epilogue_*` |
| 0005b | Duplicate target-type handling for CO-RE `BPF_CORE_TYPE_ID_TARGET` relocations | `bpf_rdonly_cast()` users such as `getpeername_unix_prog.bpf.o`, `getsockname_unix_prog.bpf.o`, and `sendmsg_unix_prog.bpf.o` when vmlinux BTF contains duplicate compatible `struct sockaddr_un` candidates |
| 0006 | Sleepable arena range-tree bootstrap and user-fault split preallocation | Arena map creation for `arena_*`, `stream.bpf.o`, and `verifier_arena*` objects that previously failed at the first full-range insertion; arena globals copied through libbpf mmap, including `arena_htab.bpf.o`, `arena_spin_lock.bpf.o`, and `verifier_arena_globals1.bpf.o` |
| 0006b | Sleepable temporary page-array allocation in `bpf_arena_alloc_pages()` | `arena_htab_llvm` and `arena_list` runtime paths that allocate arena pages from sleepable syscall tests |
| 0007 | Standalone-loadable defaults for benchmark maps that are resized by their userspace harnesses | `bloom_filter_bench.bpf.o`, `bpf_hashmap_lookup.bpf.o`, and `htab_mem_bench.bpf.o` no longer require veristat-specific key/value-size guessing |
| 0007b | `veristat` max-entries fixup exclusion for percpu cgroup storage | `map_ptr_kern.bpf.o`, `netcnt_prog.bpf.o`, `percpu_alloc_array.bpf.o`, `tailcall_cgrp_storage*.bpf.o`, and `verifier_cgroup_storage.bpf.o` avoid false `BPF_MAP_CREATE -EINVAL` failures |
| 0008 | Stable verbose verifier logging under UML memory limits | Diagnostic coverage for failing objects in `-vl2` mode, especially `test_send_signal_kern.bpf.o`, `xfrm_info.bpf.o`, and `test_tunnel_kern.bpf.o` |
| 0009 | Missing selftest header include | `bpf_iter_task_btf` host-side object build under UML-generated `vmlinux.h` |
| 0009b | UML-aware probe-read memory validation | Runtime tests whose light-skeleton loader programs probe guest memory ranges before creating/loading the real object |
| 0010 | Non-fatal startup verification-key registration | `test_progs --list`, `--count`, and selected runtime subsets when asymmetric key instantiation is unavailable in UML |
| 0011 | Arena globals and explicit casts for `BPF_ARENA_FORCE_ASM` | `arena_htab_asm` runtime load and execution |
| 0012 | Patchable 5-byte entries for synthetic syscall wrappers | fentry/fexit programs targeting UML-provided `__x64_sys_*` symbols, including `bloom_filter_map` |
| 0013 | Writable UML BPF text-poke shim | BPF trampoline attachment to synthetic wrapper targets; removes `-EBUSY`/panic after the trampoline is within direct-call range |
| 0014 | Runtime dispatch through selected synthetic syscall wrappers | fentry/fexit programs that must actually execute on syscall entry, including `map_btf` and `user_ringbuf` |
| 0015 | Kernel probe-read helpers in the no-`BPF_EVENTS` UML verification-stub config | Generated light-skeleton loader programs for runtime tests such as `ringbuf`; these loader programs use `BPF_PROG_TYPE_SYSCALL` and call `bpf_probe_read_kernel()` before creating/loading the real object |

For upstreaming work, use the generated comparison report in
[`docs/patch-impact.md`](docs/patch-impact.md)
and the machine-readable snapshots under
[`reports/patch-impact/`](reports/patch-impact)
instead of hand-maintaining patch impact notes.

## Verification Model

`uml-veristat` exposes an upstream kernel reality that is easy to miss: BPF
"verification" is not a single platform-independent pass.

In practice there are two layers:

1. Generic verifier checks
   - CFG validity, register typing, pointer provenance, bounds, lifetimes,
     reference tracking, helper/kfunc signatures, etc.
2. Backend-dependent compatibility checks
   - whether the selected execution target can actually lower the verified
     program: interpreter vs JIT, architecture-specific code generation, and
     feature-specific backend support.

The current kernel mixes those layers together in the verifier instead of
reporting them as two separate phases. For `uml-veristat`, that means some
failures are not "your program is invalid BPF", but "this UML/x86 JIT backend
does not support lowering this valid construct yet".

### Why arena requires JIT

Arena is the clearest example. In
`kernel/bpf/verifier.c`, `BPF_MAP_TYPE_ARENA` is rejected unless:

- `prog->jit_requested` is true
- `bpf_jit_supports_arena()` is true
- the arena has a user VM base address

This is not just a generic kfunc restriction. Arena pointers rely on
architecture-specific JIT lowering. As explained in `kernel/bpf/arena.c`,
arena pointers use the lower 32 bits of the user-space address as an offset
into a kernel VM area, and the JIT emits special addressing sequences for arena
loads/stores. `kernel/bpf/fixups.c` and `kernel/bpf/core.c` also contain
arena-specific instruction rewrites (`BPF_PROBE_MEM32`/`MEM32SX`) that are only
meaningful if the JIT backend knows how to lower them.

So arena currently means:

- generically valid verifier state is necessary but not sufficient
- the selected JIT backend must explicitly claim arena support

### Current backend-dependent gates

The upstream verifier currently folds several backend-dependent checks into
program load/verification:

- kfunc calls: `bpf_jit_supports_kfunc_call()`
- far kfunc calls: `bpf_jit_supports_far_kfunc_call()`
- arena programs: `bpf_jit_supports_arena()`
- arena-specific instruction forms: `bpf_jit_supports_insn(..., true)`
- percpu map instructions: `bpf_jit_supports_percpu_insn()`
- subprog tailcalls: `bpf_jit_supports_subprog_tailcalls()`
- private stack: `bpf_jit_supports_private_stack()`
- exceptions / throwing kfuncs: `bpf_jit_supports_exceptions()`
- fsession support: `bpf_jit_supports_fsession()`
- pointer exchange lowering: `bpf_jit_supports_ptr_xchg()`
- timed `may_goto`: `bpf_jit_supports_timed_may_goto()`

This is why `uml-veristat` should be interpreted as testing both:

- verifier semantics on current `bpf-next`
- backend support of the current UML/x86 execution target

## Reproducible Coverage

Coverage numbers should be generated from the installed artifacts, not edited by
hand. Use:

```bash
cd uml-veristat
python3 scripts/report_coverage.py
```

The script runs two sweeps over the top-level installed selftest corpus:

- default `uml-veristat` output for file-level counts
- `uml-veristat -o csv` for per-program verdict counts

The default report now separates the top-level corpus into:

- standalone positive files that should load under `uml-veristat`
- expected-negative tests that are supposed to fail
- fixture-only linked/subskeleton objects that are not standalone load targets

The corpus classification and expected regression baseline live in the
machine-readable manifest
[`corpus_manifest.json`](corpus_manifest.json).
To assert that the current installed build still matches the expected file
bucket and errno baseline, run:

```bash
cd uml-veristat
python3 scripts/check_expectations.py
```

For arena-specific work, run the focused arena regression:

```bash
cd uml-veristat
python3 scripts/check_arena_expectations.py
```

That check covers the 11 top-level arena-family objects and asserts that none
fail at file-processing time. The current expected arena result is 60 processed
programs: 58 success rows and 2 verifier-failure rows.

The top-level CI expectation check uses exact failure-bucket checks plus
minimum aggregate thresholds from `corpus_manifest.json`. It intentionally does
not pin every top-level count exactly because CI builds against moving
`bpf-next/master`. The focused arena expectation check remains exact.

Reference output from the `e4287bf34` `bpf-next` snapshot (`919` `.bpf.o`
files) was:

| Metric | Value |
|--------|-------|
| Standalone input files | `902` |
| Excluded expected-negative tests | `5` |
| Excluded fixture-only objects | `12` |
| Processed files | `901` |
| Skipped files | `1` |
| Processed programs | `4514` |
| Successful CSV rows | `2413` |
| Failing CSV rows | `2101` |
| Remaining failed-to-process files | `6` |
| Remaining failed-to-open files | `1` |

### Clean Upstream Baseline

It is also possible to build a clean upstream UML variant with no local patch
stack:

```bash
cd uml-veristat
./build.sh --clean --rebuild-kernel --rebuild-bpftool --rebuild-selftests --rebuild-testmod
```

This installs to `~/.local/share/uml-veristat-clean` and leaves the normal
patched install untouched.

The important point is that the clean upstream build is still usable. The
headline corpus size is only slightly smaller, because `standalone input files`
is just the filename-based input corpus after excluding expected-negative and
fixture-only objects. It is not a success count.

A historical comparison from the `9012cf249` snapshot shows the real
difference in the verification results:

| Metric | Patched UML | Clean upstream UML |
|--------|-------------|--------------------|
| Standalone input files | `873` | `862` |
| Processed files | `871` | `860` |
| Processed programs | `4378` | `4323` |
| Successful CSV rows | `2282` | `1336` |
| Failing CSV rows | `2096` | `2987` |
| Remaining failed-to-process files | `0` | `104` |
| Remaining failed-to-open files | `1` | `2` |

So the local patch stack does not merely increase the input corpus a little. It
substantially improves effective coverage by:

- turning many hard file-level failures into processable objects
- converting a large number of per-program failures into successes
- restoring whole feature classes such as tracing/session-style programs,
  `bpf_testmod`/module-BTF-dependent objects, struct_ops-heavy cases, and more
  stable diagnostic runs

Excluded expected-negative tests:

- `bad_struct_ops.bpf.o`
- `struct_ops_autocreate.bpf.o`
- `test_pinning_invalid.bpf.o`
- `uptr_map_failure.bpf.o`
- `wakeup_source_fail.bpf.o`

Excluded fixture-only objects:

- `linked_funcs1.bpf.o`
- `linked_funcs2.bpf.o`
- `linked_maps1.bpf.o`
- `linked_maps2.bpf.o`
- `linked_vars1.bpf.o`
- `linked_vars2.bpf.o`
- `test_subskeleton.bpf.o`
- `test_subskeleton_lib.bpf.o`
- `test_subskeleton_lib2.bpf.o`
- `tracing_multi_attach.bpf.o`
- `tracing_multi_attach_module.bpf.o`
- `tracing_multi_intersect_attach.bpf.o`

Remaining standalone file-level items:

- `bpf_smc.bpf.o` (`-3`): SMC struct_ops and fentry targets are absent from
  the current UML kernel BTF.
- `struct_ops_module.bpf.o` (`-95`): the raw object contains intentionally
  incompatible struct_ops state that the selftest harness disables or mutates
  before load.
- `tcp_ca_kfunc.bpf.o` (`-22`): TCP congestion-control kfunc BTF, for example
  `bbr_cwnd_event_tx_start`, is absent from the current UML kernel/module BTF.
- `test_map_in_map.bpf.o` (`-22`): the legacy object relies on the harness
  calling `bpf_map__set_inner_map_fd()` before load.
- `test_select_reuseport_kern.bpf.o` (`-22`): the selftest relies on a
  harness-created reuseport array and `bpf_map__reuse_fd()` before load.
- `test_wakeup_source.bpf.o` (`-22`): `bpf_wakeup_sources_get_head` is absent
  from the current UML kernel BTF, matching the selftest's skip condition.
- `test_sk_assign.bpf.o` (`-95`): the old iproute2 object uses a legacy
  `SEC("maps")` map definition that libbpf v1 refuses; the standalone libbpf
  variant is `test_sk_assign_libbpf.bpf.o`.

After the arena range-tree fixes in `0006`, the arena family no longer fails at
file-processing time. Arena objects now produce normal per-program verifier
rows under `uml-veristat`; only `verifier_arena.bpf.o` contains
expected-negative rows,
`iter_maps2` and `iter_maps3`, which intentionally pass invalid arena kfunc
arguments to the verifier.

See `patches/README.md` for detailed descriptions of each patch.

## Limitations

- The tool currently boots a fresh UML instance for every invocation. If you are running `veristat` in a tight loop (e.g., hundreds of times in a CI pipeline), the ~1s boot overhead per invocation will add up.
- Because the UML guest runs as your user, it cannot verify programs that require `CAP_SYS_ADMIN` unless your host user also has those privileges (though BPF verification itself usually does not require root in modern kernels).

## Next Improvements

The current prioritized improvement list for `uml-veristat` is:

1. Add backend capability reporting.
   - Expose the current UML/x86 JIT capability set in a machine-readable and
     user-friendly way, for example `kfunc_call`, `arena`, `percpu_insn`,
     `exceptions`, `private_stack`, and `subprog_tailcalls`.
2. Clarify remaining backend-dependent verifier failures.
   - Arena now reaches normal per-program verifier rows with only the
     intentionally negative `verifier_arena.bpf.o` cases left in the focused
     arena corpus.
3. Clarify harness-dependent selftests.
   - Keep non-standalone or harness-shaped objects out of the default product
     metric unless `uml-veristat` grows explicit setup emulation for them.
4. Expand CI beyond package builds.
   - Add package validation and cached build inputs now that the first
     regression and smoke checks are in place.
5. Expand expectation-aware regressions to program-level behavior.
   - Today the baseline checks file bucket and errno stability. The next step
     is to pin selected per-program verdicts and failure modes where that adds
     real signal.
6. Grow the corpus manifest.
   - Extend it with known-UML-gap and harness-dependent annotations so the
     manifest becomes the default source of truth for corpus policy.
7. Document the failure taxonomy more explicitly.
   - Distinguish invalid BPF, missing kernel features, missing UML backend
     capability, and selftest harness assumptions.

## Repository layout

The project lives at the repository root (flattened from the former
`uml-veristat/` subdirectory in 2026-07): `build.sh`, the `uml-veristat`
wrapper, the `uml-test-progs` runner, `patches/`, `scripts/`,
`corpus_manifest.json`, and the `bpf-next-commit` pin. Build output goes
to `.build/` (override with `UML_VERISTAT_WORKDIR`). Also at the root:

- [`docs/`](docs/) — follow-ups, upstreaming plans, and design notes.
- [`gdb_demo/`](gdb_demo/) — verifier debugging walkthrough used by
  `--gdb-wait`.
- [`selftests/`](selftests/) — historical selftests reproduction scripts
  and reference artifacts; the legacy root wrappers `run_bpf_uml.sh`,
  `bpf_failslab_test.sh`, and `init_failslab` forward there.

If you have an existing checkout with build state under
`uml-veristat/.build/`, move it once with `mv uml-veristat/.build .build`
to keep the cached bpf-next and LLVM trees, then remove
`.build/pahole-build` and `.build/pahole-install` (pahole bakes absolute
library paths) and run `./build.sh` once — it rebuilds pahole and
refreshes the installed `selftests` symlink, which points into `.build`.
