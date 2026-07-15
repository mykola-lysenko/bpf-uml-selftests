#!/usr/bin/env python3
"""JIT expansion measurement harness (host side).

Boots N sharded UML guests that load every corpus *.bpf.o and dump each
program's xlated + jited text (scripts/jit_expansion_guest.py), then analyzes
the dumps into a per-program table and an aggregate attribution report:

  - BPF (xlated) insn count vs native (jited) insn count and the ratio
  - opcode-class histogram from the xlated dump
  - PROBE_MEM guard sites counted directly from the jited disassembly
    (xlated dumps mask BPF_PROBE_MEM back to BPF_MEM, so the guard is only
    visible on the native side: movq/movl span -> mov r11 -> [add] -> sub ->
    mov limit -> cmpq %r10,%r11 -> jb/ja -> xor -> jmp)
  - fixed per-program overhead (entry nops, prologue/epilogue)

Usage:
  scripts/jit_expansion.py                     # full corpus, 4 shards
  scripts/jit_expansion.py --limit 10          # smoke: 10 objects per shard
  scripts/jit_expansion.py --analyze-only DIR  # re-analyze an existing run
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]

XLATED_RE = re.compile(r"^\s*\d+: \(([0-9a-f]{2})\) (.*)")
JITED_RE = re.compile(r"^\s*([0-9a-f]+):\t(\S+)(?:\t(.*))?$")
NOP_MNEMONICS = {"nop", "nopl", "nopw"}

# ---------------------------------------------------------------------------
# UML run
# ---------------------------------------------------------------------------

INIT_TEMPLATE = """#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mkdir -p /sys/fs/bpf 2>/dev/null || true
mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
{insmods}
python3 {guest_script} --objects {objects} --bpftool {bpftool} \\
    --out {out} --shard {shard} {extra} > {log} 2>&1
echo $? > {rc_file}
sync
halt -f 2>/dev/null || poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
"""

# kfunc-importing objects (bpf_testmod kfuncs) fail loadall unless the test
# kmods are present in the guest.
KMOD_NAMES = ("bpf_testmod.ko", "bpf_test_modorder_x.ko", "bpf_test_modorder_y.ko")


def find_insmods() -> str:
    kmod_dir = ROOT / ".build/bpf-next/tools/testing/selftests/bpf/test_kmods"
    return "\n".join(
        f"insmod {kmod_dir / name} 2>/dev/null || true"
        for name in KMOD_NAMES
        if (kmod_dir / name).is_file()
    )


def run_guests(args, out_dir: pathlib.Path) -> None:
    tmp = out_dir / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    extra = f"--limit {args.limit}" if args.limit else ""
    insmods = find_insmods()

    procs = []
    for k in range(args.shards):
        init = tmp / f"init-{k}"
        init.write_text(INIT_TEMPLATE.format(
            insmods=insmods,
            guest_script=ROOT / "scripts/jit_expansion_guest.py",
            objects=args.objects,
            bpftool=args.bpftool,
            out=out_dir,
            shard=f"{k}/{args.shards}",
            extra=extra,
            log=out_dir / f"guest-{k}.log",
            rc_file=tmp / f"rc-{k}",
        ))
        init.chmod(0o755)
        proc = subprocess.Popen(
            [args.uml_kernel, f"mem={args.mem}", "rootfstype=hostfs",
             "hostfs=/", "rw", f"init={init}",
             "quiet", "loglevel=0", "con=null", "con0=null"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        procs.append(proc)

    deadline = time.time() + args.timeout
    for k, proc in enumerate(procs):
        try:
            proc.wait(timeout=max(1, deadline - time.time()))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            print(f"shard {k}: TIMEOUT after {args.timeout}s", file=sys.stderr)
    subprocess.run(["pkill", "-9", "-f", "/linux mem="], check=False)

    for k in range(args.shards):
        rc_file = tmp / f"rc-{k}"
        done = out_dir / f"done-{k}"
        state = rc_file.read_text().strip() if rc_file.exists() else "no-rc"
        stats = done.read_text() if done.exists() else "INCOMPLETE"
        print(f"shard {k}: rc={state} {stats}")


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def classify_xlated(op: int, text: str) -> str:
    if op == 0x18:
        return "ld_imm64"
    if op == 0x85:
        # tail calls and subprog calls have very different native costs
        # than helper/kfunc calls; the dump text distinguishes them
        if "call bpf_tail_call" in text:
            return "call_tail"
        if "call pc+" in text or "call pc-" in text:
            return "call_sub"
        return "call_helper"
    if op == 0x95:
        return "exit"
    if op == 0x05:
        return "jmp_ja"  # unconditional
    if op == 0xE5:
        return "may_goto"
    cls = op & 0x07
    mode = op & 0xE0
    if cls == 0x03 and mode == 0xC0:
        return "atomic"
    if cls == 0x01:
        return "ldx_memsx" if mode == 0x80 else "ldx"
    return {0x00: "ld_other", 0x02: "st", 0x03: "stx",
            0x04: "alu32", 0x05: "jmp_cond", 0x06: "jmp32", 0x07: "alu64"}[cls]


# A guard prefix is a run of these immediately before the cmp, in either the
# stock form (span movabsq, src mov, [add off], sub, limit mov) or the
# 0009c-folded form (src mov, add fold_off, limit mov).
GUARD_PREFIX = re.compile(
    r"^(?:(?:movabsq|movl|movq)\t\$.*, %r10d?"
    r"|subq\t%r10, %r11"
    r"|addq\t\$.*, %r11"
    r"|movq\t%\w+, %r11)$"
)


def scan_jited(text: str) -> dict:
    """Count native insns, entry/alignment nops, and PROBE_MEM guard sites."""
    insns = []  # (mnemonic, operands)
    for line in text.splitlines():
        m = JITED_RE.match(line)
        if m:
            insns.append((m.group(2), m.group(3) or ""))

    nops = sum(1 for mn, _ in insns if mn in NOP_MNEMONICS)

    # UML-only overhead from the uml-veristat JIT patches (params register
    # plumbing + far helper targets); absent on native x86, so it must be
    # separated before comparing ratios with real hosts:
    #   pushq/popq %r9 around every helper call, the %gs params frame at
    #   entry (movabsq+addq pair), and movabsq $helper,%r11 before an
    #   indirect callq where native x86 emits one direct call rel32.
    uml_overhead = 0
    for i, (mn, ops) in enumerate(insns):
        if (mn, ops) in (("pushq", "%r9"), ("popq", "%r9")):
            uml_overhead += 1
        elif mn == "addq" and ops.startswith("%gs:"):
            uml_overhead += 2  # movabsq $off,%r9 + addq %gs:...,%r9
        elif (mn == "callq" and ops == "*%r11"
              and i > 0 and insns[i - 1][0] == "movabsq"):
            uml_overhead += 1  # movabsq+indirect vs one direct call

    sites = 0
    guard_insns = 0
    for i, (mn, ops) in enumerate(insns):
        if mn != "cmpq" or ops != "%r10, %r11":
            continue
        if (i + 3 >= len(insns)
                or insns[i + 1][0] not in ("jb", "ja")
                or not insns[i + 2][0].startswith("xor")
                or insns[i + 3][0] != "jmp"):
            continue
        # walk backward through the guard prefix (stock: up to 5 insns,
        # folded: 3)
        back = 0
        j = i - 1
        while j >= 0 and back < 5 and GUARD_PREFIX.match(
                f"{insns[j][0]}\t{insns[j][1]}"):
            back += 1
            j -= 1
        if back < 3:
            continue  # not a guard; some unrelated cmp
        sites += 1
        guard_insns += back + 4  # prefix + cmp + jcc + xor + jmp

    return {
        "jited_insns": len(insns),
        "nop_insns": nops,
        "guard_sites": sites,
        "guard_insns": guard_insns,
        "uml_overhead_insns": uml_overhead,
    }


def scan_xlated(text: str) -> dict[str, int]:
    hist: dict[str, int] = {}
    for line in text.splitlines():
        m = XLATED_RE.match(line)
        if m:
            key = classify_xlated(int(m.group(1), 16), m.group(2))
            hist[key] = hist.get(key, 0) + 1
    return hist


def analyze(out_dir: pathlib.Path) -> None:
    dumps = out_dir / "dumps"
    rows = []
    load_failures = []
    for results in sorted(out_dir.glob("results-*.jsonl")):
        for line in results.read_text().splitlines():
            row = json.loads(line)
            (load_failures if "load_error" in row else rows).append(row)

    table = []
    for row in rows:
        stem = row["file"].removesuffix(".bpf.o")
        base = dumps / f"{stem}__{row['prog']}"
        entry = {
            "file": row["file"], "prog": row["prog"], "type": row.get("type"),
            "xlated_insns": (row.get("bytes_xlated") or 0) // 8,
            "jited_bytes": row.get("bytes_jited"),
        }
        xp, jp = (base.parent / (base.name + s) for s in
                  (".xlated.txt.gz", ".jited.txt.gz"))
        if xp.exists():
            entry["hist"] = scan_xlated(gzip.open(xp, "rt").read())
        if jp.exists():
            entry.update(scan_jited(gzip.open(jp, "rt").read()))
        if entry.get("xlated_insns") and entry.get("jited_insns"):
            entry["ratio"] = round(entry["jited_insns"] / entry["xlated_insns"], 3)
        table.append(entry)

    measured = [e for e in table if "ratio" in e]
    tx = sum(e["xlated_insns"] for e in measured)
    tj = sum(e["jited_insns"] for e in measured)
    tn = sum(e["nop_insns"] for e in measured)
    tg = sum(e["guard_insns"] for e in measured)
    sites = sum(e["guard_sites"] for e in measured)
    tu = sum(e.get("uml_overhead_insns", 0) for e in measured)
    hist_total: dict[str, int] = {}
    for e in measured:
        for k, v in e.get("hist", {}).items():
            hist_total[k] = hist_total.get(k, 0) + v

    summary = {
        "programs": len(measured),
        "load_failures": len(load_failures),
        "xlated_insns": tx,
        "jited_insns": tj,
        "ratio": round(tj / tx, 4) if tx else None,
        "nop_insns": tn,
        "guard_sites": sites,
        "guard_insns": tg,
        "guard_share_of_jited": round(tg / tj, 4) if tj else None,
        "nop_share_of_jited": round(tn / tj, 4) if tj else None,
        "uml_overhead_insns": tu,
        "uml_overhead_share_of_jited": round(tu / tj, 4) if tj else None,
        # what the corpus ratio would be without the uml-veristat JIT
        # patches' call/params plumbing — the fleet-comparable number
        "ratio_native_equivalent": round((tj - tu) / tx, 4) if tx else None,
        # opt#1 folds movabsq+sub away: 2 insns per site (1 when off==0
        # collapses add+sub+mov into add), use 2 as the upper bound
        "opt1_saved_insns_max": 2 * sites,
        "ratio_after_opt1_max": round((tj - 2 * sites) / tx, 4) if tx else None,
        "xlated_hist": dict(sorted(hist_total.items(), key=lambda kv: -kv[1])),
    }

    (out_dir / "report.json").write_text(json.dumps(
        {"summary": summary, "programs": table,
         "load_failures": load_failures}, indent=1))

    top = sorted(measured, key=lambda e: -e["ratio"])[:25]
    biggest = sorted(measured, key=lambda e: -e["jited_insns"])[:25]
    with open(out_dir / "report.md", "w") as f:
        f.write("# JIT expansion report\n\n```json\n")
        f.write(json.dumps(summary, indent=1))
        f.write("\n```\n\n## Top 25 by expansion ratio\n\n")
        f.write("| prog | xlated | jited | ratio | guards | guard insns | nops |\n")
        f.write("|---|---|---|---|---|---|---|\n")
        for e in top:
            f.write(f"| {e['file']}:{e['prog']} | {e['xlated_insns']} "
                    f"| {e['jited_insns']} | {e['ratio']} | {e['guard_sites']} "
                    f"| {e['guard_insns']} | {e['nop_insns']} |\n")
        f.write("\n## Top 25 by native size\n\n")
        f.write("| prog | xlated | jited | ratio | guards | guard insns | nops |\n")
        f.write("|---|---|---|---|---|---|---|\n")
        for e in biggest:
            f.write(f"| {e['file']}:{e['prog']} | {e['xlated_insns']} "
                    f"| {e['jited_insns']} | {e['ratio']} | {e['guard_sites']} "
                    f"| {e['guard_insns']} | {e['nop_insns']} |\n")

    print(json.dumps(summary, indent=1))
    print(f"\nwrote {out_dir}/report.json and report.md")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--objects", default=str(ROOT / ".build/selftests-output"))
    ap.add_argument("--bpftool", default=str(ROOT / ".build/bpftool-output/bpftool"))
    ap.add_argument("--uml-kernel", default=str(ROOT / ".build/bpf-next/linux"))
    ap.add_argument("--mem", default="1792M")
    ap.add_argument("--shards", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=5400, help="per-run wall clock")
    ap.add_argument("--limit", type=int, default=0, help="objects per shard (smoke)")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--analyze-only", metavar="DIR",
                    help="skip the UML run, re-analyze an existing output dir")
    args = ap.parse_args()

    if args.analyze_only:
        analyze(pathlib.Path(args.analyze_only))
        return 0

    # Everything lands in a guest init= line — absolute paths only.
    for name in ("objects", "bpftool", "uml_kernel"):
        setattr(args, name, str(pathlib.Path(getattr(args, name)).resolve()))
    out_dir = pathlib.Path(
        args.out_dir
        or ROOT / ".build" / "jit-expansion" / time.strftime("%Y%m%d-%H%M%S")
    ).resolve()
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    run_guests(args, out_dir)
    analyze(out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
