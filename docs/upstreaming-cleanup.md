# UML Veristat Upstreaming Cleanup

This is the current cleanup list to work through before shaping the local
`uml-veristat` patch stack for upstream submission.

1. Normalize patch metadata.
   - Remove stale hand-written series markers such as `[PATCH 1/6]` and
     `[PATCH 4/6]`.
   - Let `git format-patch` assign the final series numbering.
   - Make every commit message read as an upstream kernel commit, not as local
     `uml-veristat` infrastructure.

2. Split upstream submissions by review surface.
   - UML-only fixes: syscall wrappers, stub alignment, JIT Kconfig, and the
     UML/x86 JIT wiring pieces.
   - Generic BPF/libbpf fixes: duplicate BTF relocation handling and arena
     range-tree preallocation.
   - Selftests/veristat fixes: `bpf_testmod`, map fixups, and log-size
     handling.
   - RFC or controversial pieces: UML verification stubs and native x86 JIT
     backend enablement.

3. Rework the UML/x86 JIT backend patch for reviewer comfort.
   - Split supporting compatibility pieces from the final backend enablement
     where possible.
   - Keep every intermediate patch buildable.
   - Minimize `CONFIG_UML` conditionals inside native x86 BPF JIT code.

4. Re-evaluate the verification-stub framing.
   - Be explicit that the stubs are UML-only, hidden Kconfig,
     static-analysis-only support.
   - Avoid implying runtime support for tracing, LSM, or stack-trace execution
     paths that UML still does not implement.

5. Add native-side validation for generic BPF fixes.
   - Cover the libbpf duplicate-base-BTF relocation behavior with focused
     selftests.
   - Validate arena range-tree preallocation outside the UML-only workflow.

6. Investigate tolerated top-level corpus drift.
   - Current moving `bpf-next/master` can report `-EINVAL` file-processing
     failures for `getpeername_unix_prog.bpf.o`, `getsockname_unix_prog.bpf.o`,
     `sendmsg_unix_prog.bpf.o`, and `xfrm_info.bpf.o`.
   - Decide whether each object needs another UML/veristat fix, harness-aware
     setup, or permanent classification as non-standalone.

7. Generate maintainer data per final patch.
   - Run `scripts/get_maintainer.pl` from a fresh `bpf-next` tree for each
     final patch.
   - Use the result to decide whether to send one coordinated series or
     several smaller series by subsystem.
