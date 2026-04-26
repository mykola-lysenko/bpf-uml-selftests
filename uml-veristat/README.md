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

### Environment Variables

You can override the paths to the kernel and veristat binaries using environment variables:

- `UML_KERNEL`: Path to the UML kernel binary (default: `~/.local/share/uml-veristat/linux`)
- `VERISTAT`: Path to the veristat binary (default: `~/.local/share/uml-veristat/veristat`)
- `UML_MEM`: Memory to allocate to the UML guest (default: `512M`)
- `UML_VERBOSE`: Set to `1` to see the full UML kernel boot log (useful for debugging kernel panics)
- `UML_MODULES`: Path to a kernel module (`.ko`) to load before running veristat (e.g. `bpf_testmod.ko`)

## Kernel Patches

The `patches/` directory contains 10 patches applied to the `bpf-next` kernel tree to enable full BPF verification on UML:

| Patch | Description | Programs fixed |
|-------|-------------|----------------|
| 0001 | Add `__x64_sys_*` wrappers for BPF selftest compatibility | fentry/kprobe attach targets |
| 0002 | Add `BPF_VERIFICATION_STUBS` (tracing + LSM + stack trace) | tracing/LSM types + maps |
| 0003 | Fix UML stub page alignment (`-Wl,-n` removal) | UML boot fix |
| 0003b | Enable eBPF JIT support and default-on JIT for UML x86-64 | struct_ops + default guest JIT |
| 0003c | Wire the native x86 BPF JIT backend into UML | real JIT capability hooks |
| 0003d | Add UML-only JIT runtime shims for verification | kfunc-capable JIT in UML |
| 0004 | Fix `bpf_testmod.c` compilation on UML | bpf_testmod module |
| 0005 | Handle duplicate BTF types in CO-RE relocations | btf_relocate + relo_core |
| 0007 | Fix veristat map fixup for zero key_size/value_size | bench + cgroup maps |
| 0008 | Cap veristat auto log size to avoid UML OOM | verbose log stability |

### Patch-to-Selftest Correspondence

The patch stack is not strictly one-patch-per-selftest. Some patches are pure
infrastructure prerequisites, while others unlock whole classes of selftests.
The table below shows the current practical correspondence.

| Patch | Main area | Representative selftests or classes unlocked |
|-------|-----------|----------------------------------------------|
| 0001 | x86-64 syscall wrapper BTF attach targets on UML | Syscall attach-target tests using `SYS_PREFIX`, such as `bpf_syscall_macro.c` and other `__x64_sys_*` kprobe/fentry/raw_tp cases |
| 0002 | verification-only tracing/LSM/stack-trace support without `PERF_EVENTS` | Tracing-type and stack-trace users such as `pyperf*`, `strobemeta*`, `stacktrace_*`, plus LSM/storage-style cases like `local_storage`, `map_kptr`, `map_ptr_kern`, `test_get_xattr`, `test_map_in_map`, `verifier_vfs_reject` |
| 0003 | UML boot fix | Global prerequisite: all `uml-veristat` selftests depend on the UML guest booting at all |
| 0003b | JIT enablement and default-on JIT | Struct-ops and JIT-gated program classes, including `struct_ops_*`, `tcp_ca_*`, and early kfunc-capable loads |
| 0003c | Real x86 JIT capability hooks in UML | Kfunc-using objects that used to fail with `JIT does not support calling kernel function`, such as `test_send_signal_kern.bpf.o`, `xfrm_info.bpf.o`, and parts of `test_tunnel_kern.bpf.o` |
| 0003d | UML runtime shims needed to actually link the native x86 BPF JIT | Same class as `0003c`; this is the link/runtime half that makes the JIT backend usable in the final UML kernel |
| 0004 | `bpf_testmod.ko` buildability on UML | Global prerequisite for `bpf_testmod`-backed selftests, including `struct_ops_module*`, `kfunc_call_*`, `iters_testmod*`, `kprobe_multi*`, and related module-BTF tests |
| 0005 | Duplicate-BTF relocation handling | Large `bpf_testmod`/CO-RE bucket: `struct_ops_*`, `kfunc_call_*`, `iters_testmod*`, `kprobe_multi*`, `epilogue_*`, plus CO-RE cases like `getsockname_unix_prog.bpf.o`, `netif_receive_skb.bpf.o`, `htab_mem_bench.bpf.o`, and `stream.bpf.o` |
| 0007 | `veristat` map fixups for harness-shaped benchmark objects | `bloom_filter_bench.bpf.o`, `bpf_hashmap_lookup.bpf.o`, `htab_mem_bench.bpf.o` |
| 0008 | Stable verbose verifier logging under UML memory limits | Diagnostic coverage for failing objects in `-vl2` mode, especially `test_send_signal_kern.bpf.o`, `xfrm_info.bpf.o`, and `test_tunnel_kern.bpf.o` |

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

Current reproducible output for the top-level corpus (`884` `.bpf.o` files) is:

| Metric | Value |
|--------|-------|
| Standalone input files | `873` |
| Excluded expected-negative tests | `3` |
| Excluded fixture-only objects | `8` |
| Processed files | `871` |
| Skipped files | `2` |
| Processed programs | `4378` |
| Successful CSV rows | `2202` |
| Failing CSV rows | `2176` |
| Remaining failed-to-process files | `11` |
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

The real difference shows up in the verification results:

| Metric | Patched UML | Clean upstream UML |
|--------|-------------|--------------------|
| Standalone input files | `873` | `862` |
| Processed files | `871` | `860` |
| Processed programs | `4378` | `4323` |
| Successful CSV rows | `2202` | `1336` |
| Failing CSV rows | `2176` | `2987` |
| Remaining failed-to-process files | `11` | `104` |
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

Excluded fixture-only objects:

- `linked_funcs1.bpf.o`
- `linked_funcs2.bpf.o`
- `linked_maps1.bpf.o`
- `linked_maps2.bpf.o`
- `linked_vars1.bpf.o`
- `linked_vars2.bpf.o`
- `test_subskeleton_lib.bpf.o`
- `test_subskeleton_lib2.bpf.o`

Remaining standalone items:

- `arena_atomics.bpf.o`
- `arena_htab.bpf.o`
- `arena_htab_asm.bpf.o`
- `arena_list.bpf.o`
- `arena_spin_lock.bpf.o`
- `arena_strsearch.bpf.o`
- `stream.bpf.o`
- `verifier_arena.bpf.o`
- `verifier_arena_globals1.bpf.o`
- `verifier_arena_globals2.bpf.o`
- `verifier_arena_large.bpf.o`
- `test_sk_assign.bpf.o`

See `patches/README.md` for detailed descriptions of each patch.

## Limitations

- The tool currently boots a fresh UML instance for every invocation. If you are running `veristat` in a tight loop (e.g., hundreds of times in a CI pipeline), the ~1s boot overhead per invocation will add up.
- Because the UML guest runs as your user, it cannot verify programs that require `CAP_SYS_ADMIN` unless your host user also has those privileges (though BPF verification itself usually does not require root in modern kernels).

## Next Improvements

The current prioritized improvement list for `uml-veristat` is:

1. Add expectation-aware regression checks.
   - Keep the standalone coverage sweep, but also assert that known failing
     files stay in the expected bucket with stable failure reasons.
2. Add backend capability reporting.
   - Expose the current UML/x86 JIT capability set in a machine-readable and
     user-friendly way, for example `kfunc_call`, `arena`, `percpu_insn`,
     `exceptions`, `private_stack`, and `subprog_tailcalls`.
3. Continue arena-focused support work.
   - The arena family remains the biggest real functionality gap in the
     standalone selftest corpus.
4. Clarify harness-dependent selftests.
   - Keep non-standalone or harness-shaped objects out of the default product
     metric unless `uml-veristat` grows explicit setup emulation for them.
5. Expand CI beyond package builds.
   - Add post-build smoke checks, package validation, and cached build inputs
     once the first CI iteration settles.
6. Add a machine-readable corpus manifest.
   - Track expected-negative tests, fixture-only objects, standalone-positive
     files, known UML gaps, and harness-dependent cases in one place.
7. Document the failure taxonomy more explicitly.
   - Distinguish invalid BPF, missing kernel features, missing UML backend
     capability, and selftest harness assumptions.
