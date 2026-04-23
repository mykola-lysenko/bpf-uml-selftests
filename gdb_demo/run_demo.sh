#!/bin/bash
# run_demo.sh - Launch the UML kernel for the BPF verifier GDB demo.
#
# This script starts the UML kernel with the gdb_demo init script.
# The loader inside UML will print its PID and then stop (SIGSTOP).
# Follow the on-screen instructions to attach GDB.

set -e

KERNEL="${UML_GDB_KERNEL:-${HOME}/linux-uml-debug}"
ROOTFS="${UML_GDB_ROOTFS:-${HOME}/uml-rootfs}"
DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: UML kernel not found at $KERNEL"
    echo "Set UML_GDB_KERNEL to the debug UML kernel path."
    exit 1
fi

if [ ! -d "$ROOTFS" ]; then
    echo "ERROR: UML rootfs not found at $ROOTFS"
    echo "Set UML_GDB_ROOTFS to the UML rootfs path."
    exit 1
fi

echo "========================================================"
echo "  BPF Verifier GDB Demo"
echo "========================================================"
echo ""
echo "Starting UML kernel..."
echo "Watch for the line:  [bpf_loader_demo] PID = <N>"
echo "Kernel: $KERNEL"
echo "Rootfs: $ROOTFS"
echo ""
echo "Then in a SECOND terminal, run:"
echo ""
echo "  cd $DEMO_DIR"
echo "  gdb -x verifier.gdb $KERNEL"
echo "  (gdb) attach <N>"
echo "  (gdb) cont"
echo ""
echo "The loader will stop at bpf_check() inside the UML kernel."
echo "Use 'next', 'step', 'bpf_regs', 'bpf_insn', 'bpf_log' to explore."
echo ""
echo "========================================================"
echo ""

exec "$KERNEL" \
    rootfstype=hostfs \
    rootflags="$ROOTFS" \
    rw \
    init=/init_gdb_demo \
    mem=512M \
    con=fd:0,fd:1 \
    con0=fd:0,fd:1
