# verifier.gdb - GDB command script for interactive BPF verifier debugging
#
# Usage (after UML is running and has printed the loader PID):
#
#   gdb -x verifier.gdb /home/ubuntu/linux-uml-jit
#   (gdb) attach <PID>
#   (gdb) cont          <- runs until bpf_check breakpoint fires
#
# Or non-interactively:
#   gdb -x verifier.gdb -ex "attach <PID>" -ex cont /home/ubuntu/linux-uml-jit

# ── Source directory so GDB can find kernel source files ──────────────────────
directory /home/ubuntu/linux-6.12.20

# ── Pretty-printing helpers ───────────────────────────────────────────────────
set print pretty on
set print array on
set pagination off

# ── Breakpoints inside the BPF verifier ──────────────────────────────────────

# Top-level entry: called for every BPF_PROG_LOAD syscall
break bpf_check
commands
  silent
  printf "\n>>> bpf_check() entered\n"
  printf "    prog type  : %d\n", env->prog->type
  printf "    insn count : %d\n", env->prog->len
  continue
end

# Main instruction-by-instruction verification loop
break do_check_main
commands
  silent
  printf "\n>>> do_check_main() entered - verifier is about to walk all instructions\n"
  # Do NOT auto-continue here - let the user step manually
end

# Per-instruction check (called for every BPF instruction)
break do_check
commands
  silent
  printf "\n>>> do_check() insn_idx=%d  opcode=0x%02x\n", \
      env->insn_idx, env->prog->insnsi[env->insn_idx].code
  # Auto-continue so we don't stop at every single instruction by default.
  # Comment out the next line to stop at each instruction.
  continue
end

# Helper resolution - fires when a BPF call instruction is resolved
break check_helper_call
commands
  silent
  printf "\n>>> check_helper_call() func_id=%d\n", func_id
  continue
end

# JIT compilation entry
break bpf_prog_select_runtime
commands
  silent
  printf "\n>>> bpf_prog_select_runtime() - JIT compilation starting\n"
  continue
end

# ── Convenience commands ──────────────────────────────────────────────────────

# Print the current BPF register state
define bpf_regs
  set $i = 0
  while $i < 11
    printf "  r%d: type=%d  value=0x%llx\n", $i, \
        env->cur_state->frame[0]->regs[$i].type, \
        env->cur_state->frame[0]->regs[$i].imm
    set $i = $i + 1
  end
end
document bpf_regs
  Print the current BPF verifier register state (types and values).
  Only valid when stopped inside do_check() or do_check_main().
end

# Print the current BPF instruction
define bpf_insn
  printf "  insn[%d]: code=0x%02x dst=%d src=%d off=%d imm=%d\n", \
      env->insn_idx, \
      env->prog->insnsi[env->insn_idx].code, \
      env->prog->insnsi[env->insn_idx].dst_reg, \
      env->prog->insnsi[env->insn_idx].src_reg, \
      env->prog->insnsi[env->insn_idx].off, \
      env->prog->insnsi[env->insn_idx].imm
end
document bpf_insn
  Print the BPF instruction currently being verified.
  Only valid when stopped inside do_check().
end

# Print the verifier log buffer so far
define bpf_log
  printf "%s\n", env->log.data
end
document bpf_log
  Print the BPF verifier log buffer accumulated so far.
  Only valid when stopped inside bpf_check() or its callees.
end

echo \n[verifier.gdb loaded]\n
echo Breakpoints set on: bpf_check, do_check_main, do_check, check_helper_call, bpf_prog_select_runtime\n
echo \nNow run:  attach <PID from UML output>\n
echo Then:     cont\n\n
