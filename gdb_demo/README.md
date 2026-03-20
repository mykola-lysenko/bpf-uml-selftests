# Interactive BPF Verifier Debugging with GDB and UML

This directory contains a complete, self-contained demonstration of how to interactively debug the Linux eBPF verifier using GDB and User-Mode Linux (UML).

Debugging the eBPF verifier interactively is challenging because the verifier runs in kernel space. By compiling the Linux kernel as a UML executable (`linux-uml-debug`), we can run the entire kernel as a normal user-space process and attach GDB to it just like any other program.

## Architecture

This demo solves the complex synchronization problem of attaching GDB *before* the BPF program is loaded:

1. **UML Kernel**: The Linux kernel compiled for the `um` (User-Mode Linux) architecture with debug symbols (`-g`) and no optimization (`-O0` where possible).
2. **bpf_loader_demo**: A minimal C program that runs *inside* the UML guest as the `init` process. It uses a file-polling mechanism to wait for a trigger before calling the `bpf()` syscall.
3. **GDB**: Runs on the host, attached to the UML kernel process.

The synchronization flow:
1. `bpf_loader_demo` starts inside UML and creates a `/tmp/uml_ready` file.
2. It then polls for a `/tmp/uml_go` file (using non-blocking `nanosleep`).
3. You attach GDB to the UML process on the host and set a breakpoint on `bpf_check`.
4. You trigger the load by creating the `uml_go` file.
5. The loader calls `bpf(BPF_PROG_LOAD)`.
6. GDB intercepts the kernel execution exactly at `bpf_check()`!

> **Note on UML ptrace architecture**: We use a file-polling mechanism instead of a FIFO or signals because UML itself uses `ptrace` to intercept guest system calls. Using blocking system calls (like reading a FIFO) causes deadlocks when GDB is attached to the UML kernel.

## Prerequisites

All prerequisites are already set up in this environment:
- `linux-uml-debug`: The UML kernel binary (located at `/home/ubuntu/linux-uml-debug`)
- `uml-rootfs`: The root filesystem directory (located at `/home/ubuntu/uml-rootfs`)
- GDB installed on the host

## Running the Demo

We have provided a convenient script to run the entire demo automatically, or you can run it manually to understand the steps.

### Option 1: Automated Demo (Recommended)

Simply run the automated Python controller which orchestrates the UML boot, GDB attachment, breakpoint setting, and triggering:

```bash
cd /home/ubuntu/bpf_gdb_demo
python3 run_automated_demo.py
```

This script will:
1. Start the UML kernel under GDB
2. Configure GDB to ignore UML's internal signals (`SIGCHLD`, `SIGVTALRM`, etc.)
3. Set a breakpoint on `bpf_check`
4. Wait for the loader to be ready
5. Trigger the BPF load
6. Stop at the breakpoint and print the backtrace

### Option 2: Manual Step-by-Step

If you want to experience the interactive debugging yourself, follow these steps using three terminal windows.

#### Terminal 1: Start the UML Kernel
Start the UML kernel using our wrapper script:
```bash
cd /home/ubuntu/bpf_gdb_demo
./run_demo.sh
```
The UML kernel will boot and the `bpf_loader_demo` will print instructions and wait for the trigger. Leave this terminal running.

#### Terminal 2: Attach GDB
Find the UML main process PID (the one with `Ss` state, or look at the output from Terminal 1):
```bash
ps aux | grep linux-uml-debug | grep -v grep
```

Start GDB and attach to that PID:
```bash
gdb /home/ubuntu/linux-uml-debug
(gdb) attach <UML_PID>
```

Configure GDB to ignore UML's internal signals (critical!):
```gdb
(gdb) handle SIGCHLD nostop noprint pass
(gdb) handle SIGVTALRM nostop noprint pass
(gdb) handle SIGIO nostop noprint pass
(gdb) handle SIGUSR1 nostop noprint pass
(gdb) handle SIGUSR2 nostop noprint pass
```

Set your breakpoint and continue:
```gdb
(gdb) break bpf_check
(gdb) continue
```

#### Terminal 3: Trigger the BPF Load
Now that GDB is waiting, trigger the loader to call the `bpf()` syscall:
```bash
touch /home/ubuntu/uml-rootfs/tmp/uml_go
```

#### Back in Terminal 2: Debug!
GDB will immediately hit the breakpoint:
```gdb
Thread 1 "linux-uml-debug" hit Breakpoint 1, bpf_check (prog=prog@entry=0x70ac7cd0, attr=attr@entry=0x70ac7dd8, uattr=..., uattr_size=uattr_size@entry=128) at kernel/bpf/verifier.c:22338
(gdb) backtrace 5
#0  bpf_check (prog=prog@entry=0x70ac7cd0, attr=attr@entry=0x70ac7dd8, uattr=..., uattr_size=uattr_size@entry=128) at kernel/bpf/verifier.c:22338
#1  0x00000000600bd05d in bpf_prog_load (attr=attr@entry=0x70ac7dd8, uattr=..., uattr_size=uattr_size@entry=128) at kernel/bpf/syscall.c:2847
#2  0x00000000600bec46 in __sys_bpf (cmd=BPF_PROG_LOAD, uattr=..., size=128) at kernel/bpf/syscall.c:5668
...
```

You can now use standard GDB commands (`step`, `next`, `print`, `info locals`) to step through the verifier logic!

## Files in this Directory

- `bpf_loader_demo.c`: The source code for the loader program.
- `bpf_loader_demo`: The compiled static binary (also copied to `/home/ubuntu/uml-rootfs/bpf/`).
- `run_demo.sh`: Script to start the UML kernel with the correct arguments.
- `verifier.gdb`: A collection of helpful GDB macros specifically for inspecting BPF verifier state (e.g., `print_bpf_insn`, `print_verifier_state`).
- `demo_session_output.txt`: A captured log of a successful automated GDB session.

## Using the Custom GDB Macros

We have provided a set of custom GDB macros in `verifier.gdb` to make inspecting the verifier state easier. To use them, load the file in your GDB session:

```gdb
(gdb) source /home/ubuntu/bpf_gdb_demo/verifier.gdb
```

Available commands:
- `print_bpf_insn <insn_ptr>`: Pretty-prints a BPF instruction
- `print_bpf_reg_state <reg_state_ptr>`: Prints the state of a verifier register
- `print_verifier_state <env_ptr>`: Prints the current state of all registers
- `print_bpf_func_id <id>`: Translates a BPF helper function ID to its name

## Troubleshooting

- **GDB stops constantly with "Program received signal SIGCHLD"**: You forgot to run the `handle SIGCHLD nostop noprint pass` commands. UML uses these signals internally to manage guest processes.
- **The loader is stuck and GDB never hits the breakpoint**: Ensure you are attaching to the *main* UML process (the session leader), not one of its child threads. The main process usually has the `Ss` or `Ssl` state in `ps`.
- **"Cannot access memory at address"**: This happens if you try to inspect user-space memory pointers (`uattr`) directly from the kernel context. Inspect the kernel-space copies instead (e.g., `attr` instead of `uattr`).
