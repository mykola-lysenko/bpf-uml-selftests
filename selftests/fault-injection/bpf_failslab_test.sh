#!/bin/sh
# BPF Verifier Fault Injection Test Harness
# Uses per-task failslab injection by writing to /proc/<pid>/make-it-fail
# from the PARENT process AFTER the child test_progs has already started.

DEBUGFS=/sys/kernel/debug
FAILSLAB=$DEBUGFS/failslab
TEST_PROGS=/bpf/test_progs
LOG=/bpf/failslab_results.txt

VERIFIER_TESTS="align,async_stack_depth,btf,btf_dedup_split,btf_distill,btf_dump,btf_endian,btf_field_iter,btf_map_in_map,btf_split,btf_tag,btf_write,verif_stats,verifier_kfunc_prog_types,verifier_log"

echo "=== BPF Verifier Failslab Test Harness ===" | tee $LOG
echo "Date: $(date)" | tee -a $LOG
echo "" | tee -a $LOG

if [ ! -d "$FAILSLAB" ]; then
    echo "[FATAL] failslab debugfs not found" | tee -a $LOG
    exit 1
fi
echo "[OK] failslab debugfs available" | tee -a $LOG

# ---- PHASE 1: Baseline ----
echo "" | tee -a $LOG
echo "=== PHASE 1: Baseline (no fault injection) ===" | tee -a $LOG
$TEST_PROGS -t "$VERIFIER_TESTS" > /bpf/baseline_output.txt 2>&1
BASELINE_PASS=$(grep -c "^#.*:OK" /bpf/baseline_output.txt 2>/dev/null || echo 0)
BASELINE_FAIL=$(grep -c "^#.*:FAIL" /bpf/baseline_output.txt 2>/dev/null || echo 0)
BASELINE_SKIP=$(grep -c "^#.*:SKIP" /bpf/baseline_output.txt 2>/dev/null || echo 0)
echo "[BASELINE] Pass=$BASELINE_PASS Fail=$BASELINE_FAIL Skip=$BASELINE_SKIP" | tee -a $LOG
grep "^Summary:" /bpf/baseline_output.txt | tee -a $LOG

# ---- Configure failslab ----
echo "" | tee -a $LOG
echo "=== Configuring failslab ===" | tee -a $LOG
echo 1   > $FAILSLAB/task-filter
echo 10  > $FAILSLAB/probability
echo -1  > $FAILSLAB/times
echo 0   > $FAILSLAB/verbose
echo "[*] task-filter: $(cat $FAILSLAB/task-filter)" | tee -a $LOG
echo "[*] probability: $(cat $FAILSLAB/probability)%" | tee -a $LOG
echo "[OK] failslab configured" | tee -a $LOG

TOTAL_CRASHES=0

# Helper: run test_progs with fault injection enabled
# Uses a C helper to set make-it-fail AFTER exec to avoid failing the exec itself
run_with_injection() {
    ITER_LOG=$1
    # Start test_progs in background, then immediately set make-it-fail on it
    $TEST_PROGS -t "$VERIFIER_TESTS" > $ITER_LOG 2>&1 &
    CHILD_PID=$!
    # Give the process a moment to start (it's already exec'd by now)
    sleep 0
    # Set make-it-fail on the running test_progs process
    echo 1 > /proc/$CHILD_PID/make-it-fail 2>/dev/null
    # Wait for it to finish
    wait $CHILD_PID
    return $?
}

# ---- PHASE 2: 5 iterations at 10% ----
echo "" | tee -a $LOG
echo "=== PHASE 2: Fault injection (5 iterations at 10%) ===" | tee -a $LOG
for i in 1 2 3 4 5; do
    echo "--- Iteration $i ---" | tee -a $LOG
    ITER_LOG=/bpf/failslab_iter_${i}.txt
    run_with_injection $ITER_LOG
    ITER_EXIT=$?
    ITER_PASS=$(grep -c "^#.*:OK" $ITER_LOG 2>/dev/null || echo 0)
    ITER_FAIL=$(grep -c "^#.*:FAIL" $ITER_LOG 2>/dev/null || echo 0)
    ITER_SKIP=$(grep -c "^#.*:SKIP" $ITER_LOG 2>/dev/null || echo 0)
    echo "[iter $i] Pass=$ITER_PASS Fail=$ITER_FAIL Skip=$ITER_SKIP Exit=$ITER_EXIT" | tee -a $LOG
    grep "^Summary:" $ITER_LOG 2>/dev/null | tee -a $LOG
    if [ $ITER_EXIT -eq 139 ]; then
        echo "[CRASH] SEGFAULT in iteration $i!" | tee -a $LOG
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
    fi
    # Find newly failed tests (passed in baseline, failed now)
    grep "^#.*:OK" /bpf/baseline_output.txt | sed 's/#[0-9][0-9]*//' | sort > /tmp/base_ok.txt
    grep "^#.*:FAIL" $ITER_LOG | sed 's/#[0-9][0-9]*//' | sort > /tmp/iter_fail.txt
    NEWLY_FAILED=$(comm -13 /tmp/base_ok.txt /tmp/iter_fail.txt 2>/dev/null | wc -l)
    if [ "$NEWLY_FAILED" -gt 0 ]; then
        echo "[NEW FAILURES: $NEWLY_FAILED]" | tee -a $LOG
        comm -13 /tmp/base_ok.txt /tmp/iter_fail.txt 2>/dev/null | tee -a $LOG
    fi
    KERNEL_ISSUES=$(dmesg | grep -cE "BUG:|Oops:|kernel BUG|KASAN" 2>/dev/null || echo 0)
    [ "$KERNEL_ISSUES" -gt 0 ] && echo "[KERNEL ISSUE] $KERNEL_ISSUES" | tee -a $LOG
done

# ---- PHASE 3: 50% stress ----
echo "" | tee -a $LOG
echo "=== PHASE 3: 50% stress ===" | tee -a $LOG
echo 50 > $FAILSLAB/probability
run_with_injection /bpf/failslab_stress.txt
STRESS_EXIT=$?
STRESS_PASS=$(grep -c "^#.*:OK" /bpf/failslab_stress.txt 2>/dev/null || echo 0)
STRESS_FAIL=$(grep -c "^#.*:FAIL" /bpf/failslab_stress.txt 2>/dev/null || echo 0)
echo "[stress 50%] Pass=$STRESS_PASS Fail=$STRESS_FAIL Exit=$STRESS_EXIT" | tee -a $LOG
grep "^Summary:" /bpf/failslab_stress.txt | tee -a $LOG
[ $STRESS_EXIT -eq 139 ] && echo "[CRASH] SEGFAULT!" | tee -a $LOG && TOTAL_CRASHES=$((TOTAL_CRASHES + 1))

# ---- PHASE 4: 100% ----
echo "" | tee -a $LOG
echo "=== PHASE 4: 100% failure rate ===" | tee -a $LOG
echo 100 > $FAILSLAB/probability
run_with_injection /bpf/failslab_100pct.txt
PCT100_EXIT=$?
PCT100_PASS=$(grep -c "^#.*:OK" /bpf/failslab_100pct.txt 2>/dev/null || echo 0)
PCT100_FAIL=$(grep -c "^#.*:FAIL" /bpf/failslab_100pct.txt 2>/dev/null || echo 0)
echo "[100%] Pass=$PCT100_PASS Fail=$PCT100_FAIL Exit=$PCT100_EXIT" | tee -a $LOG
grep "^Summary:" /bpf/failslab_100pct.txt | tee -a $LOG
[ $PCT100_EXIT -eq 139 ] && echo "[CRASH] SEGFAULT!" | tee -a $LOG && TOTAL_CRASHES=$((TOTAL_CRASHES + 1))

# ---- Collect dmesg ----
dmesg > /bpf/dmesg_failslab.txt

# Disable failslab
echo 0 > $FAILSLAB/probability
echo 0 > $FAILSLAB/task-filter

# ---- Summary ----
echo "" | tee -a $LOG
echo "=== FINAL SUMMARY ===" | tee -a $LOG
echo "Baseline:     Pass=$BASELINE_PASS Fail=$BASELINE_FAIL Skip=$BASELINE_SKIP" | tee -a $LOG
echo "50% stress:   Pass=$STRESS_PASS Fail=$STRESS_FAIL Exit=$STRESS_EXIT" | tee -a $LOG
echo "100% rate:    Pass=$PCT100_PASS Fail=$PCT100_FAIL Exit=$PCT100_EXIT" | tee -a $LOG
echo "Total crashes: $TOTAL_CRASHES" | tee -a $LOG
echo "=== Test complete ===" | tee -a $LOG
