# `uml-veristat`

`uml-veristat` is a drop-in CLI replacement for `veristat` that runs BPF verification inside a User-Mode Linux (UML) guest running the bleeding-edge `bpf-next` kernel.

It allows you to test BPF programs against the latest upstream verifier without needing root privileges, QEMU, KVM, or a dedicated VM.

## How it works

When you run `uml-veristat prog.bpf.o`:
1. It boots a pre-compiled UML kernel (`linux`) in the background.
2. The UML guest mounts your host filesystem via `hostfs` so it can see your `.bpf.o` files.
3. It runs the real `veristat` binary *inside* the UML guest.
4. It streams the verifier output back to your terminal and exits with `veristat`'s exact exit code.

Boot overhead is typically under 1 second.

## Setup

Before you can use `uml-veristat`, you need to build the UML kernel and the `veristat` binary. A one-time setup script is provided.

```bash
cd uml-veristat
./build.sh
```

### What `build.sh` does
1. Installs host build dependencies (`apt`, `dnf`, `zypper`, or `pacman`).
2. Downloads a pre-built LLVM/Clang release from GitHub (or builds from source with `--llvm-source`).
3. Builds `pahole` (v1.31) from source.
4. Clones the latest `bpf-next` kernel tree.
5. Applies 6 patches to enable full BPF verification on UML (see `patches/`).
6. Builds the UML kernel (`linux`) with BPF and BTF enabled.
7. Builds the `veristat` binary.
8. Installs the artifacts to `~/.local/share/uml-veristat/`.

*Note: The initial build takes about 15–20 minutes depending on your CPU and network speed. Subsequent builds (e.g. `./build.sh --update`) are incremental and much faster.*

## Usage

Simply use `uml-veristat` exactly as you would use `veristat`:

```bash
# Basic verification
./uml-veristat my_prog.bpf.o

# Show detailed verifier log on failure
./uml-veristat -l 1 my_prog.bpf.o

# Compare two programs
./uml-veristat -C old.bpf.o new.bpf.o
```

### Environment Variables

You can override the paths to the kernel and veristat binaries using environment variables:

- `UML_KERNEL`: Path to the UML kernel binary (default: `~/.local/share/uml-veristat/linux`)
- `VERISTAT`: Path to the veristat binary (default: `~/.local/share/uml-veristat/veristat`)
- `UML_MEM`: Memory to allocate to the UML guest (default: `512M`)
- `UML_VERBOSE`: Set to `1` to see the full UML kernel boot log (useful for debugging kernel panics)
- `UML_MODULES`: Path to a kernel module (`.ko`) to load before running veristat (e.g. `bpf_testmod.ko`)

## Kernel Patches

The `patches/` directory contains 8 patches applied to the `bpf-next` kernel tree to enable full BPF verification on UML:

| Patch | Description | Programs fixed |
|-------|-------------|----------------|
| 0001 | Add `__x64_sys_*` wrappers for BPF selftest compatibility | fentry/kprobe attach targets |
| 0002 | Add `BPF_TRACING_STUBS` with stack trace support | tracing types + stack trace maps |
| 0003 | Fix UML boot and enable `BPF_JIT` for struct_ops support | struct_ops programs |
| 0004 | Fix `bpf_testmod.c` compilation on UML | bpf_testmod module |
| 0005 | Fix `btf_relocate` multiple-candidates error for module BTF | +72 programs |
| 0006 | Fix `relo_core` TYPE_ID_TARGET ambiguity on duplicate types | CO-RE relocation fixes |
| 0007 | Fix veristat map fixup for zero key_size/value_size | bench program maps |
| 0008 | Add `BPF_LSM_STUBS` for LSM program type + inode storage | LSM programs + FS kfuncs |

**Cumulative veristat coverage** (run against 876 BPF selftest `.bpf.o` files, bpf-next @ `4b9b6f90e`, 2026-04-22):

| Round | Patches applied | Success | Failed-to-process files |
|-------|----------------|---------|------------------------|
| Baseline (unpatched) | none | ~1,200 | ~150 |
| After 0001–0002 | syscall wrappers + tracing stubs + stack trace | 1,597 | 89 |
| After 0003–0004 | UML boot fix + bpf_testmod fix | 1,597 | 89 |
| After 0005 | btf_relocate fix | 1,769 | 54 |
| After 0006* | relo_core TYPE_ID_TARGET fix | 1,664 | 32 |
| After 0007 + configs | veristat map fixup + NR_CPUS + NETFILTER | 1,816 | 23 |
| After 0008 + SECURITY | BPF_LSM_STUBS + CONFIG_SECURITY | **1,837** | **18** |

*Rows up to 0005 were measured on bpf-next `9012cf249` (860 files). Rows 0006+ were measured on `4b9b6f90e` (876 files after SECURITY/NETFILTER rebuild); success count changes between rows reflect both patches and the newer kernel tree.

See `patches/README.md` for detailed descriptions of each patch.

## Limitations

- The tool currently boots a fresh UML instance for every invocation. If you are running `veristat` in a tight loop (e.g., hundreds of times in a CI pipeline), the ~1s boot overhead per invocation will add up.
- Because the UML guest runs as your user, it cannot verify programs that require `CAP_SYS_ADMIN` unless your host user also has those privileges (though BPF verification itself usually does not require root in modern kernels).
