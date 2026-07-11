# UML Veristat Upstreaming Cleanup

This is the current cleanup list to work through before shaping the local
`uml-veristat` patch stack for upstream submission.

1. Normalize patch metadata. (done)
   - Stale hand-written series markers such as `[PATCH 1/6]` and
     `[PATCH 4/6]` have been removed.
   - Final upstream numbering should come from `git format-patch`.
   - Commit messages have been tightened to read as upstream kernel commits,
     with local `uml-veristat` framing removed from patch metadata.

2. Split upstream submissions by review surface. (done)
   - The proposed split is documented in
     [`docs/upstreaming-series.md`](/home/mykolal/bpf-uml-selftests/docs/upstreaming-series.md).
   - Keep the local patch order for CI, but post smaller upstream series by
     subsystem and review risk.

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
   - (done 2026-07-10) Arena range-tree preallocation (0006/0006b) was
     dropped from the stack entirely: the failures were caused by
     kmalloc_nolock() being disabled on UML for lack of host CPU feature
     probing, fixed at the root by patch 0017.

6. (done 2026-07-11) Consolidate the stack into upstream-shaped units.
   - 25 patch files reduced to 18 with byte-identical kernel tree output
     (plus two style blank lines): 0001+0012+0014 (syscall wrappers),
     0002+0002b+0015 (verification stubs), 0003b+0003c+0003d (JIT
     backend), 0016+0016b (extable fixups).
   - Audited all generic selftest/libbpf/veristat patches against the
     bpf-next tip: none are obsolete; upstream has not independently
     fixed any of them.
   - 0009b cannot be dropped (it fixes PROBE_MEM zeroing of valid UML
     kernel addresses). It was rewritten (2026-07-11) from a ~60-insn
     hand-rolled emitted check into the native single-compare guard
     structure with UML span constants; holes inside the span rely on
     the 0016 extable fixups.

7. Investigate tolerated top-level corpus drift.
   - `getpeername_unix_prog.bpf.o`, `getsockname_unix_prog.bpf.o`, and
     `sendmsg_unix_prog.bpf.o` were traced to duplicate
     `BPF_CORE_TYPE_ID_TARGET` candidates for `struct sockaddr_un`; keep these
     covered by the generic libbpf CO-RE duplicate-target patch.
   - `xfrm_info.bpf.o` passed on the refreshed `7e033543a` `bpf-next`
     package, so the earlier `-EINVAL` was a moving-base issue rather than a
     currently reproducible UML gap.
   - `arena_spin_lock.bpf.o` regressed on the refreshed base because the arena
     spin-lock helper moved under `libarena/include/` and still had
     `bpf_printk()` in `cond_break` fallback paths. The root cause is not TC
     program-type policy: UML verification stubs do not compile
     `kernel/trace/bpf_trace.c`, so the weak trace-printk helper prototype
     provider returns `NULL`. Keep this covered by the UML verification-stub
     patch's trace-printk/vprintk helper prototypes, not by modifying the
     selftest helper.

7. Generate maintainer data per final patch.
   - Run `scripts/get_maintainer.pl` from a fresh `bpf-next` tree for each
     final patch.
   - Use the result to decide whether to send one coordinated series or
     several smaller series by subsystem.
