# Repository Map

This repository was originally created around running BPF selftests inside UML.
It is now organized around `uml-veristat`, with the selftests work preserved as
supporting infrastructure and reference material.

## Primary Areas

- `uml-veristat/`
  Primary product and development surface. Contains:
  - `build.sh`
  - `uml-veristat`
  - `patches/`

- `selftests/`
  Legacy UML selftests work, preserved and still runnable. Contains:
  - `run_bpf_uml.sh`
  - `patches/`
  - `artifacts/reference/`
  - `fault-injection/`

- `gdb_demo/`
  UML + GDB verifier debugging workflow.

## Compatibility

Root-level compatibility wrappers are intentionally retained for the legacy
selftests commands:

- `run_bpf_uml.sh`
- `bpf_failslab_test.sh`
- `init_failslab`

These wrappers delegate to the new files under `selftests/`.

## Moved Paths

- `run_bpf_uml.sh` -> `selftests/run_bpf_uml.sh`
- `patches/` -> `selftests/patches/`
- `uml_bpf_selftests_report.md` -> `selftests/artifacts/reference/uml_bpf_selftests_report.md`
- `passing_tests.txt` -> `selftests/artifacts/reference/passing_tests.txt`
- `failing_tests.txt` -> `selftests/artifacts/reference/failing_tests.txt`
- `skipped_tests.txt` -> `selftests/artifacts/reference/skipped_tests.txt`
- `uml_test_output.txt` -> `selftests/artifacts/reference/uml_test_output.txt`
- `bpf_failslab_test.sh` -> `selftests/fault-injection/bpf_failslab_test.sh`
- `init_failslab` -> `selftests/fault-injection/init_failslab`
- `bpf_fault_injection_analysis.md` -> `selftests/fault-injection/bpf_fault_injection_analysis.md`
- `baseline_output.txt` -> `selftests/fault-injection/baseline_output.txt`
- `failslab_results.txt` -> `selftests/fault-injection/failslab_results.txt`
