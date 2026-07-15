#!/usr/bin/env python3
"""Diff two jit_expansion reports (baseline vs patched kernel).

Joins per-program rows on (file, prog) and reports jited insn/byte deltas,
guard-site deltas, and whether the measured savings match the prediction for
the probe-mem guard fold (opt #1: -2 insns / -10 bytes per guard site whose
folded immediate fits imm32; guard sites themselves must not change).

Usage:  scripts/jit_expansion_diff.py <baseline>/report.json <patched>/report.json
"""

from __future__ import annotations

import json
import sys


def load(path: str) -> dict[tuple[str, str], dict]:
    rows = json.load(open(path))["programs"]
    return {(p["file"], p["prog"]): p for p in rows if "ratio" in p}


def main() -> int:
    base = load(sys.argv[1])
    new = load(sys.argv[2])
    common = sorted(set(base) & set(new))
    print(f"programs: baseline {len(base)}, patched {len(new)}, joined {len(common)}\n")

    tot = {"xl": 0, "ji_b": 0, "ji_n": 0, "by_b": 0, "by_n": 0,
           "sites_b": 0, "sites_n": 0, "gi_b": 0, "gi_n": 0}
    mismatched_sites = []
    off_prediction = []
    for key in common:
        b, n = base[key], new[key]
        tot["xl"] += b["xlated_insns"]
        tot["ji_b"] += b["jited_insns"]
        tot["ji_n"] += n["jited_insns"]
        tot["by_b"] += b.get("jited_bytes") or 0
        tot["by_n"] += n.get("jited_bytes") or 0
        tot["sites_b"] += b["guard_sites"]
        tot["sites_n"] += n["guard_sites"]
        tot["gi_b"] += b["guard_insns"]
        tot["gi_n"] += n["guard_insns"]
        if b["guard_sites"] != n["guard_sites"]:
            mismatched_sites.append((key, b["guard_sites"], n["guard_sites"]))
        # the fold only changes guard prefixes, so the whole-program insn
        # delta must equal the guard-insn delta (-2/site, -1 for off==0)
        expect = n["guard_insns"] - b["guard_insns"]
        actual = n["jited_insns"] - b["jited_insns"]
        if actual != expect:
            off_prediction.append((key, b["guard_sites"], expect, actual))

    di = tot["ji_n"] - tot["ji_b"]
    db = tot["by_n"] - tot["by_b"]
    print(f"jited insns: {tot['ji_b']} -> {tot['ji_n']}  ({di:+})")
    print(f"jited bytes: {tot['by_b']} -> {tot['by_n']}  ({db:+})")
    print(f"guard sites: {tot['sites_b']} -> {tot['sites_n']}")
    print(f"guard insns: {tot['gi_b']} -> {tot['gi_n']}  ({tot['gi_n'] - tot['gi_b']:+})")
    print(f"ratio: {tot['ji_b']/tot['xl']:.4f} -> {tot['ji_n']/tot['xl']:.4f}")
    print(f"\nguard-insn delta: {tot['gi_n'] - tot['gi_b']:+}, "
          f"whole-program insn delta: {di:+} (must match)")
    if mismatched_sites:
        print(f"\nguard-site count changed for {len(mismatched_sites)} programs (unexpected):")
        for (f, p), sb, sn in mismatched_sites[:10]:
            print(f"  {f}:{p}  {sb} -> {sn}")
    if off_prediction:
        print(f"\nprograms where insn delta != guard-insn delta: {len(off_prediction)}")
        for (f, p), sites, exp, act in off_prediction[:15]:
            print(f"  {f}:{p}  sites={sites} expected {exp:+} got {act:+}")
    else:
        print("\nevery joined program's insn delta equals its guard-insn delta")
    return 0


if __name__ == "__main__":
    sys.exit(main())
