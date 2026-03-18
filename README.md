# BPF Selftests in User Mode Linux (UML)

A fully reproducible environment for building and running the Linux kernel BPF selftests (`test_progs`) inside [User Mode Linux (UML)](https://www.kernel.org/doc/html/latest/virt/uml/user_mode_linux_howto_v2.html) — no root, no QEMU, no hardware virtualization required.

## Background

User Mode Linux allows the Linux kernel to run as a normal user-space process on a host machine. This makes it an attractive, lightweight alternative to QEMU/KVM for testing kernel subsystems such as BPF. The entire test cycle — kernel boot, BPF program loading, map operations, cgroup attachment — runs as an unprivileged process on the host.

However, UML has architectural constraints that prevent a subset of the BPF selftests from compiling or running: there is no BPF JIT compiler, no kprobes/uprobes infrastructure, and no perf events subsystem. This repository contains a single self-contained script that applies all necessary patches to make the test suite compile and run gracefully within these limitations.

## Quick Start

```bash
# Ubuntu 22.04 recommended; requires ~10 GB free disk space and sudo for apt-get
chmod +x run_bpf_uml.sh
./run_bpf_uml.sh
```

The script is fully automated. It will install dependencies, download the kernel, apply patches, build everything, and run the tests. The full process takes approximately **15–20 minutes** on a 4-core machine.

## What the Script Does

| Step | Description |
|------|-------------|
| 1. Install dependencies | `clang-15`, `llvm-15`, `libelf-dev`, `busybox-static`, `pahole`, etc. |
| 2. Download kernel | Linux 6.12.20 from [cdn.kernel.org](https://cdn.kernel.org/pub/linux/kernel/v6.x/) |
| 3. Configure UML | `make ARCH=um defconfig` + BPF/Cgroup/Networking options |
| 4. Build UML kernel | Produces the `linux` binary (runs as a process) |
| 5. Apply patches | Adds `uml_vmlinux_stubs.h`; patches `Makefile` and `testing_helpers.c` |
| 6. Build `test_progs` | Compiles the BPF selftests using `clang-15` |
| 7. Build rootfs | Minimal `busybox` rootfs with all required shared libraries |
| 8. Run tests | Boots UML via `hostfs`, executes `test_progs -v -b btf,send_signal` |

## Patches Applied

Three sets of changes are applied to the upstream Linux 6.12.20 source before building:

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
- **Disk**: ~10 GB free space
- **Privileges**: `sudo` (only used to install packages via `apt-get`)
- **Network**: Internet access to download the kernel tarball

## Troubleshooting

**Build fails with clang errors**: Ensure `clang-15` and `llc-15` are installed. The script installs them automatically, but if they are missing from your package mirror, try `sudo apt-get install clang llvm` and edit the `CLANG=` and `LLC=` variables in the script.

**UML hangs on a test**: Add the test name to the `-b` deny-list in the `init` script section near the bottom of `run_bpf_uml.sh`. For example, to also skip `ringbuf`: change `-b btf,send_signal` to `-b btf,send_signal,ringbuf`.

**`patch` command fails**: This means the upstream `Makefile` has changed. The patch targets Linux 6.12.20 exactly. If you are using a different kernel version, the patch may need to be adjusted.

## License

The patches and scripts in this repository are provided under the [GPL-2.0 License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), consistent with the Linux kernel's own license.
