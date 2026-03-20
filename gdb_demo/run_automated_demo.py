#!/usr/bin/env python3
"""
GDB Controller for UML BPF Verifier Debugging
Uses pexpect to control GDB running UML kernel
Trigger: touch /home/ubuntu/uml-rootfs/tmp/uml_go
"""

import pexpect
import threading
import time
import os
import sys

READY_FILE = "/home/ubuntu/uml-rootfs/tmp/uml_ready"
GO_FILE = "/home/ubuntu/uml-rootfs/tmp/uml_go"
GDB_TIMEOUT = 120

def trigger_thread():
    """Wait for ready file, then create go file"""
    print("[TRIGGER] Waiting for ready file...")
    # Remove stale go file
    if os.path.exists(GO_FILE):
        os.unlink(GO_FILE)
    
    while not os.path.exists(READY_FILE):
        time.sleep(0.1)
    
    print("[TRIGGER] Ready file found! Waiting 1 second before triggering...")
    time.sleep(1)
    
    # Create go file (touch)
    with open(GO_FILE, 'w') as f:
        f.write("go\n")
    print("[TRIGGER] Go file created! BPF load will be triggered.")

def main():
    # Clean up stale files
    for f in [READY_FILE, GO_FILE]:
        if os.path.exists(f):
            os.unlink(f)
    
    # Start trigger thread
    t = threading.Thread(target=trigger_thread, daemon=True)
    t.start()
    
    # Start GDB
    print("[GDB] Starting GDB with UML kernel...")
    gdb = pexpect.spawn(
        'gdb /home/ubuntu/linux-uml-debug',
        timeout=GDB_TIMEOUT,
        encoding='utf-8'
    )
    gdb.logfile = sys.stdout
    
    # Wait for GDB prompt
    gdb.expect(r'\(gdb\)')
    
    # Setup
    gdb.sendline('set pagination off')
    gdb.expect(r'\(gdb\)')
    gdb.sendline('set print pretty on')
    gdb.expect(r'\(gdb\)')
    gdb.sendline('directory /home/ubuntu/linux-6.12.20')
    gdb.expect(r'\(gdb\)')
    
    # Handle signals that UML generates internally
    for sig in ['SIGCHLD', 'SIGVTALRM', 'SIGIO', 'SIGUSR1', 'SIGUSR2']:
        gdb.sendline(f'handle {sig} nostop noprint pass')
        gdb.expect(r'\(gdb\)')
    
    # Set breakpoint on BPF verifier
    gdb.sendline('break bpf_check')
    gdb.expect(r'Breakpoint 1')
    print("\n[OK] bpf_check breakpoint set!")
    gdb.expect(r'\(gdb\)')
    
    # Set UML arguments
    gdb.sendline('set args rootfstype=hostfs rootflags=/home/ubuntu/uml-rootfs rw init=/init_gdb_demo mem=256M con=fd:0,fd:1 con0=fd:0,fd:1')
    gdb.expect(r'\(gdb\)')
    gdb.sendline('set follow-fork-mode parent')
    gdb.expect(r'\(gdb\)')
    gdb.sendline('set detach-on-fork on')
    gdb.expect(r'\(gdb\)')
    
    print("\n[INFO] Running UML under GDB...")
    print("[INFO] Waiting for bpf_check() breakpoint...\n")
    
    # Run UML
    gdb.sendline('run')
    
    # Loop: handle GDB stops until breakpoint fires
    continue_count = 0
    max_continues = 1000
    
    while continue_count < max_continues:
        try:
            idx = gdb.expect([
                r'Breakpoint 1.*bpf_check',
                r'\(gdb\)',
                r'Program received signal',
                pexpect.TIMEOUT,
                pexpect.EOF
            ], timeout=GDB_TIMEOUT)
            
            if idx == 0:
                # Breakpoint hit!
                print(f"\n[SUCCESS] === BREAKPOINT HIT: bpf_check() ===")
                gdb.expect(r'\(gdb\)')
                gdb.sendline('backtrace 5')
                gdb.expect(r'\(gdb\)')
                gdb.sendline('info args')
                gdb.expect(r'\(gdb\)')
                print("\n[SUCCESS] BPF verifier breakpoint verified!")
                gdb.sendline('detach')
                gdb.expect([r'\(gdb\)', pexpect.TIMEOUT], timeout=5)
                gdb.sendline('quit')
                gdb.expect([pexpect.EOF, 'Quit anyway?'], timeout=5)
                if gdb.match and 'Quit anyway?' in str(gdb.match):
                    gdb.sendline('y')
                    gdb.expect(pexpect.EOF, timeout=5)
                return 0
                
            elif idx == 1:
                # GDB prompt - send continue
                continue_count += 1
                if continue_count % 20 == 0:
                    print(f"\n[INFO] Continue #{continue_count}...")
                gdb.sendline('continue')
                
            elif idx == 2:
                # Signal received - continue
                gdb.expect(r'\(gdb\)')
                gdb.sendline('continue')
                continue_count += 1
                
            elif idx == 3:
                print(f"\n[TIMEOUT] Waiting for breakpoint (after {continue_count} continues)")
                break
                
            elif idx == 4:
                print(f"\n[EOF] GDB exited after {continue_count} continues")
                break
                
        except pexpect.EOF:
            print(f"\n[EOF] GDB exited unexpectedly after {continue_count} continues")
            break
        except pexpect.TIMEOUT:
            print(f"\n[TIMEOUT] GDB timed out after {continue_count} continues")
            break
    
    print(f"\n[FAIL] Did not hit breakpoint after {continue_count} continues")
    return 1

if __name__ == '__main__':
    sys.exit(main())
