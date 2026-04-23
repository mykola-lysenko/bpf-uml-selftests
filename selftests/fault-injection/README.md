# Fault Injection

This directory preserves the `failslab`-based `-ENOMEM` validation work for the
UML BPF selftests environment.

## Contents

- [`bpf_failslab_test.sh`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection/bpf_failslab_test.sh)
  is the in-guest fault-injection harness.
- [`init_failslab`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection/init_failslab)
  is the UML init script that runs the harness.
- [`bpf_fault_injection_analysis.md`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection/bpf_fault_injection_analysis.md)
  contains the write-up.
- [`baseline_output.txt`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection/baseline_output.txt)
  contains the no-fault baseline run.
- [`failslab_results.txt`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection/failslab_results.txt)
  contains the summarized results of the injected runs.
