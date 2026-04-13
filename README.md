# BPF Selftests in User Mode Linux (UML)

A fully reproducible environment for building and running the Linux kernel BPF selftests (`test_progs`) inside [User Mode Linux (UML)](https://www.kernel.org/doc/html/latest/virt/uml/user_mode_linux_howto_v2.html) — no root, no QEMU, no hardware virtualization required.

The entire toolchain is built from source: **LLVM/Clang** (main branch, BPF + X86 backends only), **pahole** (latest release), and the **Linux kernel** from the [bpf-next](https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git/) development tree.

## Background

User Mode Linux allows the Linux kernel to run as a normal user-space process on a host machine. This makes it an attractive, lightweight alternative to QEMU/KVM for testing kernel subsystems such as BPF. The entire test cycle — kernel boot, BPF program loading, map operations, cgroup attachment — runs as an unprivileged process on the host.

However, UML has architectural constraints that prevent a subset of the BPF selftests from compiling or running: there is no BPF JIT compiler, no kprobes/uprobes infrastructure, and no perf events subsystem. This repository contains a single self-contained script that applies all necessary patches to make the test suite compile and run gracefully within these limitations.

## Quick Start

```bash
# Ubuntu 22.04 recommended; requires ~30 GB free disk space and sudo for apt-get
chmod +x run_bpf_uml.sh
./run_bpf_uml.sh
```

The script is fully automated. It will install host dependencies, build LLVM and pahole from source, clone the bpf-next kernel, apply UML compatibility patches, build everything, and run the tests. The full process takes approximately **45 minutes** on an 8-core machine (dominated by the LLVM build).

## What the Script Does

| Step | Description |
|------|-------------|
| 1. Install host deps | `cmake`, `ninja-build`, `libelf-dev`, `busybox-static`, etc. (no pre-built clang/llvm) |
| 2. Build LLVM/Clang | Shallow-clones `llvm-project` `main` branch; builds with `-DLLVM_TARGETS_TO_BUILD="BPF;X86"` |
| 3. Build pahole | Clones `dwarves` at `v1.31`; builds with embedded libbpf |
| 4. Clone bpf-next | Shallow-clones the `bpf-next` kernel tree from kernel.org |
| 5. Configure + build UML | `make ARCH=um defconfig` + BPF/Cgroup/Networking options; builds the `linux` binary |
| 6. Apply patches | Adds `uml_vmlinux_stubs.h`; patches `Makefile` and `testing_helpers.c` |
| 7. Build `test_progs` | Compiles the BPF selftests using the freshly built `clang` and `pahole` |
| 8. Build rootfs | Minimal `busybox` rootfs with all required shared libraries |
| 9. Run tests | Boots UML via `hostfs`, executes `test_progs -v -b btf,send_signal` |

## Patches Applied

Three sets of changes are applied to the bpf-next kernel source before building:

**`tools/testing/selftests/bpf/tools/include/uml_vmlinux_stubs.h`** (new file)
Provides stub type definitions for kernel types absent from UML's BTF output: `perf_branch_entry`, `bpf_perf_event_data`, `nf_conn`, `sched_domain`, `mptcp_sock`, and others. These stubs are appended to `vmlinux.h` at build time.

**`tools/testing/selftests/bpf/Makefile`** (patched)
- Adds `ARCH=x86_64` to kernel module sub-builds (which cannot use `ARCH=um`) and makes module build failures non-fatal.
- Appends `-D__ARCH_UM__` to `BPF_CFLAGS` so BPF programs can conditionally compile around UML-incompatible features.
- Defines `TRUNNER_TESTS_BLACKLIST` to exclude ~26 test runner programs that depend on kprobes, perf events, JIT, MPTCP, or netfilter.
- Extends `SKEL_BLACKLIST` to exclude the corresponding BPF object files from compilation.
- Removes `bpf_testmod.ko` and related kernel modules from the required test files list.

**`tools/testing/selftests/bpf/testing_helpers.c`** (patched)
Adds a `__weak` stub for `stack_mprotect()`, which is normally defined in `test_lsm.c` (excluded because LSM requires JIT).

## Expected Results

```
Summary: 132/545 PASSED, 51 SKIPPED, 303 FAILED
```

*(The summary counts individual subtests. At the test-suite level: ~91 suites pass, ~302 fail, ~40 are skipped.)*

### What Works

| Category | Passing Examples |
|----------|-----------------|
| Core BPF infrastructure | `bpf_obj_pinning`, `metadata`, `obj_name`, `global_data` |
| Cgroup BPF | `cgroup_attach_multi`, `cgroup_link`, `cgroup_tcp_skb` |
| Traffic Control (TC) | `tc_opts_basic`, `tc_links_prepend`, `tc_opts_query` |
| XDP (basic) | `xdp_link`, `xdp_adjust_tail`, `xdp_info` |
| Socket filters | `sockopt`, `sockopt_multi`, `skb_ctx`, `pkt_md_access` |
| Verifier scaling | `verif_scale_loop4`, `verif_scale_sysctl_loop1` |

### What Fails and Why

| Root Cause | Symptom | Affected Tests |
|------------|---------|----------------|
| **No BPF JIT** (`HAVE_EBPF_JIT` not available for UML) | `EINVAL` (-22) on program load | `fentry`, `fexit`, `lsm`, `struct_ops`, trampolines |
| **No kprobes/uprobes** | `ENOSYS` or `EINVAL` on perf event creation | `kprobe_multi`, `uprobe_multi`, `trace_ext`, `perf_buffer` |
| **No network namespaces** | `ip netns add` fails with errno 95 | `xfrm_info`, `xdp_veth_redirect`, routing tests |
| **Memory constraints** | `mmap arena: -12` (ENOMEM) | `arena_htab`, `arena_list` |

Two tests are excluded at **runtime** (via `-b btf,send_signal`) because they cause the UML kernel to crash or hang rather than returning a clean failure:
- `btf` — crashes when loading a tracepoint program
- `send_signal` — hangs due to perf-event-based signal delivery

## Repository Contents

| File | Description |
|------|-------------|
| `run_bpf_uml.sh` | The main reproducible build-and-run script |
| `uml_bpf_selftests_report.md` | Detailed analysis report of the test results |
| `passing_tests.txt` | List of all passing test suites |
| `failing_tests.txt` | List of all failing test suites |
| `skipped_tests.txt` | List of all skipped test suites |
| `uml_test_output.txt` | Full raw output from the reference test run |

## Requirements

- **OS**: Ubuntu 22.04 LTS (or compatible Debian-based distribution)
- **Disk**: ~30 GB free space (LLVM source ~3 GB, build artifacts ~15 GB, kernel ~2 GB)
- **CPU**: 8+ cores strongly recommended; LLVM build is CPU-bound
- **Privileges**: `sudo` (only used to install packages via `apt-get`)
- **Network**: Internet access (git clones LLVM, dwarves, and bpf-next)

### Incremental Re-runs

All three source-build steps are **idempotent**: if `${WORKDIR}/llvm-install/bin/clang`, `${WORKDIR}/pahole-install/bin/pahole`, or `${WORKDIR}/bpf-next/` already exist, the script skips the corresponding build and only re-runs the kernel configure, patch, and test steps. This makes iterative development fast after the first full build.

## Troubleshooting

**LLVM build fails or runs out of disk**: The LLVM build requires ~15 GB of disk space for build artifacts. If space is tight, set `LLVM_BUILD` to a path on a larger partition. If the build fails mid-way, simply re-run the script — it will resume from where it left off (the `cmake` configure step is skipped if the build directory already exists).

**UML hangs on a test**: Add the test name to the `-b` deny-list in the `init` script section near the bottom of `run_bpf_uml.sh`. For example, to also skip `ringbuf`: change `-b btf,send_signal` to `-b btf,send_signal,ringbuf`.

**`patch` command fails**: This means the bpf-next `Makefile` has changed since the patches were written. Because bpf-next is a fast-moving development tree, the patch context lines may drift. Inspect the `.rej` files produced by `patch` and apply the changes manually.

## Fault Injection Testing (ENOMEM Handling)

This repository also includes a second set of patches and a test harness for validating **graceful `-ENOMEM` handling** in the BPF test infrastructure under `failslab` fault injection.

### Motivation

Under memory pressure (e.g., during CI stress runs or on memory-constrained systems), `kmalloc`-backed allocations can fail with `-ENOMEM`. Without proper handling, such failures cause test crashes or false failures that obscure real bugs. The patches in `patches/` fix four files in the test infrastructure to convert `-ENOMEM` into graceful test skips.

### Patches

| Patch | File | Change |
|-------|------|--------|
| `0001` | `prog_tests/align.c` | After `bpf_prog_load()`, check `errno == ENOMEM` and call `test__skip()` |
| `0002` | `prog_tests/btf.c` | In `btf_raw_create()`, return `-ENOMEM` when allocation fails; callers skip |
| `0003` | `prog_tests/verifier_log.c` | Propagate `-ENOMEM` from `check_prog_load()`; top-level calls `test__skip()` |
| `0004` | `test_loader.c` | After `bpf_object__load()`, check `err == -ENOMEM` and skip before cleanup |

### Fault Injection Test Results

The harness (`bpf_failslab_test.sh`) runs 8 phases using `failslab` with `task-filter` mode:

| Phase | Fault Rate | Sub-tests Passed | Sub-tests Skipped | Crashes |
|-------|-----------|-----------------|-------------------|--------|
| Baseline | 0% | 256 | 25 | 0 |
| Iterations 1–5 | 10% | 240–247 | 34–41 | 0 |
| Stress | 50% | 210 | 69 | 0 |
| Extreme | 100% | 176 | 37 | 0 |

**Total crashes: 0.** The `align` test is the clearest demonstration — at 100% failure rate, 11/12 sub-tests gracefully skip and the top-level result remains `OK`.

See `bpf_fault_injection_analysis.md` for the full analysis and `failslab_results.txt` for the raw output.

## License

The patches and scripts in this repository are provided under the [GPL-2.0 License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), consistent with the Linux kernel's own license.
