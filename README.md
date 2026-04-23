# `uml-veristat`

This repository is now organized around `uml-veristat`: a User-Mode Linux
(UML) development environment for running `veristat` against the latest
`bpf-next` kernel without requiring root, QEMU, or hardware virtualization.

The original UML BPF selftests work remains in this repo as supporting
infrastructure, reference artifacts, and validation material. It has been moved
under [`selftests/`](/home/mykolal/bpf-uml-selftests/selftests/README.md) so the
primary `uml-veristat` workflow is the default surface.

## Quick Start

Build the UML kernel, `veristat`, and supporting artifacts:

```bash
cd uml-veristat
./build.sh
```

Run `uml-veristat` against a BPF object:

```bash
./uml-veristat my_prog.bpf.o
```

See [`uml-veristat/README.md`](/home/mykolal/bpf-uml-selftests/uml-veristat/README.md)
for setup details, environment variables, packaging, and patch coverage.

## Repository Layout

- [`uml-veristat/`](/home/mykolal/bpf-uml-selftests/uml-veristat) contains the
  primary tool, build pipeline, and UML-specific kernel patch stack.
- [`selftests/`](/home/mykolal/bpf-uml-selftests/selftests/README.md) contains
  the original UML BPF selftests runner, fault-injection work, and preserved
  reference outputs.
- [`gdb_demo/`](/home/mykolal/bpf-uml-selftests/gdb_demo/README.md) contains
  the verifier debugging workflow for stopping in `bpf_check()` under GDB.
- [`docs/repo-map.md`](/home/mykolal/bpf-uml-selftests/docs/repo-map.md)
  documents the repo reorganization and compatibility paths.

## Compatibility Paths

Legacy entry points are still available at the repository root and forward to
their new locations:

- `./run_bpf_uml.sh` -> `selftests/run_bpf_uml.sh`
- `./bpf_failslab_test.sh` -> `selftests/fault-injection/bpf_failslab_test.sh`
- `./init_failslab` -> `selftests/fault-injection/init_failslab`

These wrappers keep existing commands working while the new layout settles.

## Recommended Workflows

- For `uml-veristat` development, start in
  [`uml-veristat/`](/home/mykolal/bpf-uml-selftests/uml-veristat).
- For historical selftests reproduction and analysis, start in
  [`selftests/`](/home/mykolal/bpf-uml-selftests/selftests/README.md).
- For verifier debugging, start in
  [`gdb_demo/`](/home/mykolal/bpf-uml-selftests/gdb_demo/README.md).

## Notes

- The repository is currently dirty due to local build output under
  `uml-veristat/.build/`. Those paths are now ignored.
- The installed runtime contract for `uml-veristat` is unchanged:
  `~/.local/share/uml-veristat/` remains the default artifact location.
