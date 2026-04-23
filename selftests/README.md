# UML BPF Selftests

This directory preserves the original repository purpose: building and running
Linux BPF selftests inside User-Mode Linux.

It is no longer the primary surface of the repository. The main product is now
[`uml-veristat/`](/home/mykolal/bpf-uml-selftests/uml-veristat/README.md).
Selftests remain here as reference infrastructure, regression context, and
supporting research material.

## Contents

- [`run_bpf_uml.sh`](/home/mykolal/bpf-uml-selftests/selftests/run_bpf_uml.sh)
  is the original reproducible selftests build-and-run script.
- [`patches/`](/home/mykolal/bpf-uml-selftests/selftests/patches) contains the
  fault-injection handling patches for graceful `-ENOMEM` behavior.
- [`artifacts/reference/`](/home/mykolal/bpf-uml-selftests/selftests/artifacts/reference)
  contains preserved reference outputs and result summaries.
- [`fault-injection/`](/home/mykolal/bpf-uml-selftests/selftests/fault-injection)
  contains the failslab harness, init script, and analysis outputs.

## Compatibility

The root-level `./run_bpf_uml.sh`, `./bpf_failslab_test.sh`, and
`./init_failslab` paths still work and forward here.
