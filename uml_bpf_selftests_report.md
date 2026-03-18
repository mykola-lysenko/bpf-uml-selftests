# BPF Selftests in User Mode Linux (UML) Environment
**Author**: Manus AI
**Date**: March 18, 2026

## Executive Summary

This report presents the findings of building and running the Linux kernel BPF selftests (`test_progs`) inside a User Mode Linux (UML) environment. The goal was to evaluate the feasibility of testing BPF functionality in a lightweight virtualized environment without requiring hardware virtualization.

The investigation demonstrates that **UML is a viable but limited environment for BPF testing**. Out of 434 tests that were successfully compiled and executed, **91 tests (21%) passed**, **302 tests (70%) failed**, and **40 tests (9%) were skipped**. The passing tests confirm that core BPF infrastructure—including the verifier, maps, cgroup attachments, and socket filters—functions correctly in UML. The failures are primarily attributable to architectural limitations of UML, specifically the lack of BPF JIT compilation, kprobes support, and network namespace isolation capabilities.

## Methodology

The testing environment was constructed using the following components:
- **Kernel**: Linux 6.12.20 compiled with `ARCH=um`
- **Host Architecture**: x86_64
- **BPF Configuration**: `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_CGROUP_BPF=y`, `CONFIG_DEBUG_INFO_BTF=y`
- **Test Suite**: `tools/testing/selftests/bpf/test_progs`

Significant modifications were required to build the test suite for UML:
1. Approximately 27 tests were excluded from compilation due to dependencies on features unavailable in UML (e.g., `bpf_dummy_ops`).
2. `vmlinux.h` and `bpf_tracing.h` were patched to accommodate UML's unique `pt_regs` layout, which uses a `gp[]` array rather than named registers.
3. The tests were executed inside a minimal busybox rootfs, booted via UML's `hostfs` capability.

Two specific tests (`btf` and `send_signal`) were excluded at runtime as they caused the UML kernel to crash or hang due to tracepoint and perf event handling issues.

## Test Results Analysis

The test suite executed 434 distinct test suites (comprising thousands of individual subtests). The results are categorized below.

### Passing Categories (What Works in UML)

The 91 passing tests validate that the fundamental BPF subsystem operates correctly in UML. The successful areas include:

| Category | Description | Examples of Passing Tests |
|----------|-------------|---------------------------|
| **Core Infrastructure** | Basic BPF object loading, pinning, and metadata | `bpf_obj_pinning`, `metadata`, `obj_name`, `global_data` |
| **Cgroup BPF** | Attaching BPF programs to cgroups | `cgroup_attach_multi`, `cgroup_link`, `cgroup_tcp_skb` |
| **Traffic Control (TC)** | TC hooks and options | `tc_opts_basic`, `tc_links_prepend`, `tc_opts_query` |
| **XDP (Basic)** | XDP link attachment and basic packet manipulation | `xdp_link`, `xdp_adjust_tail`, `xdp_info` |
| **Socket Filters** | Socket options and packet access | `sockopt`, `sockopt_multi`, `skb_ctx`, `pkt_md_access` |
| **Verifier (Scale)** | Verifier limits and complex loops | `verif_scale_loop4`, `verif_scale_sysctl_loop1` |

### Failing Categories (Limitations of UML)

The 302 failing tests can be grouped into several distinct architectural limitations of the UML environment.

#### 1. Lack of BPF JIT Compiler (1,508 subtest failures)
The most significant source of failures is the absence of a BPF Just-In-Time (JIT) compiler for UML (`CONFIG_BPF_JIT` cannot be enabled as UML lacks the `HAVE_EBPF_JIT` infrastructure). Many modern BPF features strictly require JIT compilation.
* **Symptom**: `BPF program load failed: Invalid argument` (Error -22)
* **Affected Areas**: BPF trampolines, `fentry`/`fexit` programs, BPF LSM, struct_ops, and extension programs.

#### 2. Tracing and Kprobes Incompatibility (142 subtest failures)
UML's process execution model and unique `pt_regs` structure make standard x86 kprobes and perf events incompatible.
* **Symptom**: `failed to load: -22` for kprobe/uprobe programs, or perf event creation failures (`ENOSYS`).
* **Affected Areas**: `kprobe_multi`, `uprobe_multi`, `trace_ext`, `perf_branches`, `perf_buffer`.

#### 3. Network Namespace Limitations (99 subtest failures)
Many networking tests attempt to create complex network topologies using `ip netns add`. The minimal UML environment or its networking driver implementation failed to support these operations.
* **Symptom**: `ip netns add unexpected error: 256 (errno 95)` (Operation not supported).
* **Affected Areas**: `xfrm_info`, `xdp_veth_redirect`, various routing and tunneling tests.

#### 4. Memory Allocator Restrictions (20 subtest failures)
UML's memory management, particularly the per-CPU allocator, is highly constrained compared to a bare-metal kernel.
* **Symptom**: `failed to mmap arena: -12` (ENOMEM).
* **Affected Areas**: BPF arenas (`arena_htab`, `arena_list`), large per-CPU hash maps.

#### 5. Missing Kernel Modules
Several tests rely on the `bpf_testmod.ko` kernel module, which could not be loaded in the UML environment due to missing symbol exports and struct_ops incompatibilities.

## Conclusion

User Mode Linux provides a functional, albeit restricted, environment for BPF testing. It is highly effective for testing the BPF verifier, core map operations, cgroup attachments, and basic networking hooks (TC/socket filters) without the overhead of hardware virtualization (QEMU/KVM).

However, UML is not suitable for testing modern tracing capabilities (kprobes, fentry/fexit), BPF LSM, or any feature requiring JIT compilation. For comprehensive BPF selftest coverage, a full virtual machine (such as QEMU with KVM) remains necessary.

Future work could explore implementing a minimal BPF JIT compiler for the UML architecture, which would significantly increase the percentage of passing tests.
