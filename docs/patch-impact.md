# Patch Impact Report

This report compares installed `uml-veristat` variants using the same coverage logic as `scripts/report_coverage.py`.

- Baseline: `clean`
- Corpus: `top-level`

## Summary

| Case | Standalone files | Processed files | Processed programs | Success rows | Failure rows | Failed-to-process | Failed-to-open |
|------|------------------|-----------------|--------------------|--------------|--------------|-------------------|----------------|
| `patched` | `873` | `871` | `4378` | `2202` | `2176` | `11` | `1` |
| `clean` | `862` | `860` | `4323` | `1336` | `2987` | `104` | `2` |

## Delta Vs Baseline

| Case | Standalone files | Processed files | Processed programs | Success rows | Failure rows | Failed-to-process | Failed-to-open |
|------|------------------|-----------------|--------------------|--------------|--------------|-------------------|----------------|
| `patched` | `+11` | `+11` | `+55` | `+866` | `-811` | `-93` | `-1` |
| `clean` | `+0` | `+0` | `+0` | `+0` | `+0` | `+0` | `+0` |

## patched

- Built: `2026-04-26 03:38 UTC`
- Mode: `patched`
- bpf-next: `9012cf249 (7.0.0)`
- LLVM: `nightly-23.0.0`
- pahole: `v1.31`

### Newly Processable Files

- `bloom_filter_bench.bpf.o`
- `bpf_cc_cubic.bpf.o`
- `bpf_cubic.bpf.o`
- `bpf_dctcp.bpf.o`
- `bpf_dctcp_release.bpf.o`
- `bpf_hashmap_lookup.bpf.o`
- `bpf_tcp_nogpl.bpf.o`
- `epilogue_exit.bpf.o`
- `epilogue_tailcall.bpf.o`
- `getpeername_unix_prog.bpf.o`
- `getsockname_unix_prog.bpf.o`
- `htab_mem_bench.bpf.o`
- `iters_testmod_seq.bpf.o`
- `jit_probe_mem.bpf.o`
- `kfunc_call_destructive.bpf.o`
- `kfunc_call_fail.bpf.o`
- `kfunc_call_race.bpf.o`
- `kfunc_call_test.bpf.o`
- `kfunc_call_test_subprog.bpf.o`
- `kfunc_module_order.bpf.o`
- `kprobe_multi.bpf.o`
- `ksym_race.bpf.o`
- `map_kptr.bpf.o`
- `map_kptr_fail.bpf.o`
- `map_kptr_race.bpf.o`
- `map_ptr_kern.bpf.o`
- `mem_rdonly_untrusted.bpf.o`
- `missed_kprobe.bpf.o`
- `missed_kprobe_recursion.bpf.o`
- `nested_trust_failure.bpf.o`
- `nested_trust_success.bpf.o`
- `netcnt_prog.bpf.o`
- `netif_receive_skb.bpf.o`
- `percpu_alloc_array.bpf.o`
- `pro_epilogue.bpf.o`
- `pro_epilogue_goto_start.bpf.o`
- `pro_epilogue_with_kfunc.bpf.o`
- `pyperf100.bpf.o`
- `pyperf180.bpf.o`
- `pyperf600.bpf.o`
- `pyperf600_bpf_loop.bpf.o`
- `pyperf600_iter.bpf.o`
- `pyperf600_nounroll.bpf.o`
- `pyperf_global.bpf.o`
- `pyperf_subprogs.bpf.o`
- `rcu_tasks_trace_gp.bpf.o`
- `recvmsg_unix_prog.bpf.o`
- `sock_addr_kern.bpf.o`
- `stacktrace_ips.bpf.o`
- `stacktrace_map.bpf.o`
- `strobemeta_bpf_loop.bpf.o`
- `strobemeta_nounroll1.bpf.o`
- `strobemeta_nounroll2.bpf.o`
- `strobemeta_subprogs.bpf.o`
- `struct_ops_assoc.bpf.o`
- `struct_ops_assoc_in_timer.bpf.o`
- `struct_ops_assoc_reuse.bpf.o`
- `struct_ops_autocreate2.bpf.o`
- `struct_ops_detach.bpf.o`
- `struct_ops_forgotten_cb.bpf.o`
- `struct_ops_id_ops_mapping1.bpf.o`
- `struct_ops_id_ops_mapping2.bpf.o`
- `struct_ops_kptr_return.bpf.o`
- `struct_ops_kptr_return_fail__invalid_scalar.bpf.o`
- `struct_ops_kptr_return_fail__local_kptr.bpf.o`
- `struct_ops_kptr_return_fail__nonzero_offset.bpf.o`
- `struct_ops_maybe_null.bpf.o`
- `struct_ops_maybe_null_fail.bpf.o`
- `struct_ops_module.bpf.o`
- `struct_ops_multi_args.bpf.o`
- `struct_ops_multi_pages.bpf.o`
- `struct_ops_nulled_out_cb.bpf.o`
- `struct_ops_private_stack.bpf.o`
- `struct_ops_private_stack_fail.bpf.o`
- `struct_ops_private_stack_recur.bpf.o`
- `struct_ops_refcounted.bpf.o`
- `struct_ops_refcounted_fail__global_subprog.bpf.o`
- `struct_ops_refcounted_fail__ref_leak.bpf.o`
- `struct_ops_refcounted_fail__tail_call.bpf.o`
- `tcp_ca_kfunc.bpf.o`
- `tcp_ca_unsupp_cong_op.bpf.o`
- `tcp_ca_update.bpf.o`
- `tcp_ca_write_sk_pacing.bpf.o`
- `test_get_xattr.bpf.o`
- `test_kfunc_param_nullable.bpf.o`
- `test_ksyms_module.bpf.o`
- `test_send_signal_kern.bpf.o`
- `test_sig_in_xattr.bpf.o`
- `verifier_ctx.bpf.o`
- `verifier_default_trusted_ptr.bpf.o`
- `verifier_prevent_map_lookup.bpf.o`
- `verifier_vfs_reject.bpf.o`
- `wq.bpf.o`

### Newly Openable Files

- `test_subskeleton.bpf.o`

### Failed To Process

- `arena_atomics.bpf.o` (`-22`)
- `arena_htab.bpf.o` (`-22`)
- `arena_htab_asm.bpf.o` (`-22`)
- `arena_list.bpf.o` (`-22`)
- `arena_spin_lock.bpf.o` (`-22`)
- `arena_strsearch.bpf.o` (`-22`)
- `stream.bpf.o` (`-22`)
- `verifier_arena.bpf.o` (`-22`)
- `verifier_arena_globals1.bpf.o` (`-22`)
- `verifier_arena_globals2.bpf.o` (`-22`)
- `verifier_arena_large.bpf.o` (`-22`)

### Failed To Open

- `test_sk_assign.bpf.o` (`-95`)

## clean

- Built: `2026-04-26 02:27 UTC`
- Mode: `clean`
- bpf-next: `9012cf249 (7.0.0)`
- LLVM: `nightly-23.0.0`
- pahole: `v1.31`

### Failed To Process

- `arena_atomics.bpf.o` (`-95`)
- `arena_htab.bpf.o` (`-95`)
- `arena_htab_asm.bpf.o` (`-95`)
- `arena_list.bpf.o` (`-95`)
- `arena_spin_lock.bpf.o` (`-95`)
- `arena_strsearch.bpf.o` (`-95`)
- `bloom_filter_bench.bpf.o` (`-22`)
- `bpf_cc_cubic.bpf.o` (`-3`)
- `bpf_cubic.bpf.o` (`-3`)
- `bpf_dctcp.bpf.o` (`-3`)
- `bpf_dctcp_release.bpf.o` (`-3`)
- `bpf_hashmap_lookup.bpf.o` (`-22`)
- `bpf_tcp_nogpl.bpf.o` (`-3`)
- `epilogue_exit.bpf.o` (`-22`)
- `epilogue_tailcall.bpf.o` (`-22`)
- `getpeername_unix_prog.bpf.o` (`-22`)
- `getsockname_unix_prog.bpf.o` (`-22`)
- `htab_mem_bench.bpf.o` (`-22`)
- `iters_testmod_seq.bpf.o` (`-22`)
- `jit_probe_mem.bpf.o` (`-22`)
- `kfunc_call_destructive.bpf.o` (`-22`)
- `kfunc_call_fail.bpf.o` (`-22`)
- `kfunc_call_race.bpf.o` (`-22`)
- `kfunc_call_test.bpf.o` (`-22`)
- `kfunc_call_test_subprog.bpf.o` (`-22`)
- `kfunc_module_order.bpf.o` (`-22`)
- `kprobe_multi.bpf.o` (`-3`)
- `ksym_race.bpf.o` (`-22`)
- `map_kptr.bpf.o` (`-22`)
- `map_kptr_fail.bpf.o` (`-22`)
- `map_kptr_race.bpf.o` (`-22`)
- `map_ptr_kern.bpf.o` (`-22`)
- `mem_rdonly_untrusted.bpf.o` (`-22`)
- `missed_kprobe.bpf.o` (`-22`)
- `missed_kprobe_recursion.bpf.o` (`-22`)
- `nested_trust_failure.bpf.o` (`-22`)
- `nested_trust_success.bpf.o` (`-22`)
- `netcnt_prog.bpf.o` (`-22`)
- `netif_receive_skb.bpf.o` (`-22`)
- `percpu_alloc_array.bpf.o` (`-22`)
- `pro_epilogue.bpf.o` (`-22`)
- `pro_epilogue_goto_start.bpf.o` (`-22`)
- `pro_epilogue_with_kfunc.bpf.o` (`-22`)
- `pyperf100.bpf.o` (`-22`)
- `pyperf180.bpf.o` (`-22`)
- `pyperf600.bpf.o` (`-22`)
- `pyperf600_bpf_loop.bpf.o` (`-22`)
- `pyperf600_iter.bpf.o` (`-22`)
- `pyperf600_nounroll.bpf.o` (`-22`)
- `pyperf_global.bpf.o` (`-22`)
- `pyperf_subprogs.bpf.o` (`-22`)
- `rcu_tasks_trace_gp.bpf.o` (`-22`)
- `recvmsg_unix_prog.bpf.o` (`-22`)
- `sock_addr_kern.bpf.o` (`-22`)
- `stacktrace_ips.bpf.o` (`-22`)
- `stacktrace_map.bpf.o` (`-22`)
- `stream.bpf.o` (`-95`)
- `strobemeta_bpf_loop.bpf.o` (`-22`)
- `strobemeta_nounroll1.bpf.o` (`-22`)
- `strobemeta_nounroll2.bpf.o` (`-22`)
- `strobemeta_subprogs.bpf.o` (`-22`)
- `struct_ops_assoc.bpf.o` (`-3`)
- `struct_ops_assoc_in_timer.bpf.o` (`-3`)
- `struct_ops_assoc_reuse.bpf.o` (`-3`)
- `struct_ops_autocreate2.bpf.o` (`-3`)
- `struct_ops_detach.bpf.o` (`-3`)
- `struct_ops_forgotten_cb.bpf.o` (`-3`)
- `struct_ops_id_ops_mapping1.bpf.o` (`-3`)
- `struct_ops_id_ops_mapping2.bpf.o` (`-3`)
- `struct_ops_kptr_return.bpf.o` (`-3`)
- `struct_ops_kptr_return_fail__invalid_scalar.bpf.o` (`-3`)
- `struct_ops_kptr_return_fail__local_kptr.bpf.o` (`-3`)
- `struct_ops_kptr_return_fail__nonzero_offset.bpf.o` (`-3`)
- `struct_ops_maybe_null.bpf.o` (`-3`)
- `struct_ops_maybe_null_fail.bpf.o` (`-3`)
- `struct_ops_module.bpf.o` (`-3`)
- `struct_ops_multi_args.bpf.o` (`-3`)
- `struct_ops_multi_pages.bpf.o` (`-3`)
- `struct_ops_nulled_out_cb.bpf.o` (`-3`)
- `struct_ops_private_stack.bpf.o` (`-22`)
- `struct_ops_private_stack_fail.bpf.o` (`-22`)
- `struct_ops_private_stack_recur.bpf.o` (`-22`)
- `struct_ops_refcounted.bpf.o` (`-3`)
- `struct_ops_refcounted_fail__global_subprog.bpf.o` (`-3`)
- `struct_ops_refcounted_fail__ref_leak.bpf.o` (`-3`)
- `struct_ops_refcounted_fail__tail_call.bpf.o` (`-3`)
- `tcp_ca_kfunc.bpf.o` (`-22`)
- `tcp_ca_unsupp_cong_op.bpf.o` (`-3`)
- `tcp_ca_update.bpf.o` (`-3`)
- `tcp_ca_write_sk_pacing.bpf.o` (`-3`)
- `test_get_xattr.bpf.o` (`-22`)
- `test_kfunc_param_nullable.bpf.o` (`-22`)
- `test_ksyms_module.bpf.o` (`-22`)
- `test_send_signal_kern.bpf.o` (`-22`)
- `test_sig_in_xattr.bpf.o` (`-22`)
- `verifier_arena.bpf.o` (`-95`)
- `verifier_arena_globals1.bpf.o` (`-95`)
- `verifier_arena_globals2.bpf.o` (`-95`)
- `verifier_arena_large.bpf.o` (`-95`)
- `verifier_ctx.bpf.o` (`-22`)
- `verifier_default_trusted_ptr.bpf.o` (`-22`)
- `verifier_prevent_map_lookup.bpf.o` (`-22`)
- `verifier_vfs_reject.bpf.o` (`-22`)
- `wq.bpf.o` (`-22`)

### Failed To Open

- `test_sk_assign.bpf.o` (`-95`)
- `test_subskeleton.bpf.o` (`-2`)
