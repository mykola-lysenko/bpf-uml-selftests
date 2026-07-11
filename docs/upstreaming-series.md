# Upstreaming Series Split

This document splits the local `uml-veristat` patch stack by upstream review
surface. The current patch order should stay as-is for CI because it represents
the tested end-to-end UML verification environment. Upstream submissions should
be smaller and routed by subsystem.

## Recommended Order

1. Low-risk standalone fixes.
   - Send patches that fix clear build or correctness issues and do not depend
     on the controversial UML verification model.
   - Goal: reduce the local stack before discussing larger UML/BPF design.

2. Generic BPF/libbpf fixes with native validation.
   - Add or confirm native-side tests first, then post these as normal BPF
     fixes, not as UML infrastructure.

3. UML BPF capability RFCs.
   - Post verification stubs and native x86 JIT wiring only after the smaller
     fixes are out of the way.
   - These need stronger cover-letter framing because they provide
     static-analysis support without full runtime feature support.

## Series A: UML And Selftest Build Fixes

Status: mostly ready to post as small standalone patches.

Patches:

- `0003-um-fix-stub-binary-page-alignment-by-removing-Wl-n.patch`
  - Audience: UML maintainers.
  - Rationale: fixes UML boot by restoring page-aligned stub LOAD segments.
  - Dependency: none.

- `0004-selftests-bpf-fix-bpf_testmod.c-compilation-on-UML.patch`
  - Audience: BPF selftests maintainers, UML maintainers on Cc.
  - Rationale: avoids native x86-only guards when compiling `bpf_testmod` for
    UML.
  - Dependency: none.

- `0001-um-x86-add-__x64_sys_-wrappers-for-BPF-selftest-comp.patch`
  - Audience: UML and BPF maintainers.
  - Rationale: exposes expected x86-64 syscall wrapper BTF attach targets on
    UML.
  - Dependency: none, but expect review on whether adding wrapper symbols for
    BTF attach compatibility is the preferred UML interface.

Suggested posting shape:

- Send `0003` alone if we want the easiest early merge.
- Send `0004` alone or with a tiny cover note explaining it is selftest-only.
- Hold or RFC `0001` if reviewers prefer a broader syscall-wrapper story for
  UML BTF attach targets.

## Series B: Generic libbpf And BPF Fixes

Status: valuable to upstream, but should be backed by native-side tests before
posting.

Patches:

- `0005-libbpf-handle-duplicate-BTF-types-in-relocations.patch`
  - Audience: libbpf maintainers.
  - Rationale: split-BTF relocation should tolerate duplicate compatible base
    BTF candidates when the distilled representation cannot distinguish them.
  - Dependency: none.
  - Validation needed: focused libbpf selftests for duplicate compatible base
    candidates.

- `0005b-libbpf-tolerate-duplicate-target-type-ids-in-core-relos.patch`
  - Audience: libbpf maintainers.
  - Rationale: `BPF_CORE_TYPE_ID_TARGET` can tolerate duplicate compatible
    target candidates because either target BTF ID is acceptable for
    type-identity helpers.
  - Dependency: conceptually pairs with `0005`, but should be reviewable as a
    separate libbpf fix.
  - Validation needed: CO-RE relocation selftest for duplicate compatible
    target-type IDs.

- `0006`/`0006b` (arena preallocation): REMOVED from the stack (2026-07-10).
  They worked around `kmalloc_nolock()` returning NULL on UML, which was a
  missing-host-CPU-feature-probing problem fixed at the root by `0017`.
  Nothing to upstream from them; the underlying UML gap is covered by the
  `0017` RFC in Series A/C territory.

Suggested posting shape:

- Post `0005` and `0005b` as a two-patch libbpf series after adding focused
  tests.

## Series C: selftests/bpf veristat Fixes

Status: mostly ready, but should be framed as generic veristat robustness.

Patches:

- `0007-selftests-bpf-make-benchmark-map-definitions-standal.patch`
  - Audience: BPF selftests maintainers.
  - Rationale: benchmark BPF objects should carry small valid default map
    dimensions even when the benchmark harness overrides them before load.
  - Dependency: none.

- `0007b-selftests-bpf-veristat-preserve-zero-max_entries-for.patch`
  - Audience: BPF selftests maintainers.
  - Rationale: veristat should not rewrite `max_entries` for percpu cgroup
    storage maps, which require `max_entries == 0` just like cgroup storage.
  - Dependency: none.

- `0008-selftests-bpf-veristat-cap-auto-log-size-to-avoid-o.patch`
  - Audience: BPF selftests maintainers.
  - Rationale: the automatic verbose log-size probe can choose an impractical
    default for constrained runners; explicit larger sizes remain available.
  - Dependency: none.

Suggested posting shape:

- Send `0007` as a standalone selftests cleanup; it is about making benchmark
  objects self-describing, not changing veristat policy.
- Send `0007b` as a tiny veristat correctness fix with before/after examples
  from percpu cgroup storage objects.
- Hold `0008` unless we can show a generic constrained-runner failure mode
  outside UML.

## Series D: UML BPF Verification RFC

Status: not ready as a normal merge series; should be RFC until framing and
review concerns are resolved.

Patches:

- `0002-bpf-add-verification-stubs-for-UML-kernels-without-P.patch`
  - Audience: BPF, UML, tracing, and LSM reviewers.
  - Rationale: hidden UML-only configs let static-analysis loads reach the
    verifier for program types and helpers that UML cannot execute.
  - Dependency: none for build, but it is easier to justify after smaller
    generic fixes have landed.
  - Review risk: stubs must not imply runtime support for tracing, LSM,
    stack-trace, or trace-printk execution paths.

Suggested posting shape:

- Send as RFC with measured `veristat` impact and explicit non-goals.
- Cover letter must state that accepted programs are for static analysis only
  and are not attached or executed.

## Series E: UML x86 BPF JIT RFC

Status: needs patch splitting before posting.

Patches:

- `0003b-um-x86-select-HAVE_EBPF_JIT-for-UML-on-64-bit.patch`
  - Audience: UML and BPF maintainers.
  - Rationale: 64-bit UML runs on an x86-64 host and can use the native x86 BPF
    JIT for load-time capability checks.
  - Dependency: should not land by itself unless the real backend wiring is
    accepted.

- `0003c-um-x86-wire-up-native-bpf-jit-backend-for-UML.patch`
  - Audience: UML, x86, and BPF maintainers.
  - Rationale: links the native x86 BPF JIT backend into UML and provides the
    minimal compatibility shims needed for verification and JIT analysis.
  - Dependency: requires `0003b`.
  - Review risk: currently too broad; it mixes build wiring, register layout,
    header compatibility, runtime shims, and final backend enablement.

Suggested posting shape:

- Split `0003c` into buildable pieces before sending:
  - UML/x86 register and header compatibility.
  - UML-local NOP, CFI, BHB, per-cpu, and text-copy shims.
  - `arch/x86/net/` build wiring for UML.
  - final `HAVE_EBPF_JIT` and default-JIT enablement.
- Post as RFC after the verification-stub RFC or together with it if the cover
  letter explains their interaction.

## Current Priority

The next concrete cleanup item is to rework `0003c` into smaller buildable
patches. That is the largest reviewability risk in the current stack and is
already called out separately in `docs/upstreaming-cleanup.md`.
