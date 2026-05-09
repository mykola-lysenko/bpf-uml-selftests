#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import subprocess
import sys

from coverage_lib import MANIFEST_PATH, load_manifest, parse_failures, parse_summary


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False, env=env)


def csv_rows(output: str) -> list[dict[str, str]]:
    lines = output.splitlines()
    try:
        header_idx = next(i for i, line in enumerate(lines) if line.startswith("file_name,"))
    except StopIteration as exc:
        raise RuntimeError("failed to find veristat CSV header") from exc
    return list(csv.DictReader(lines[header_idx:]))


def expected_failure_set(manifest: dict) -> set[tuple[str, str]]:
    expected = manifest["arena_corpus"].get("expected_failed_programs", {})
    return {
        (file_name, prog_name)
        for file_name, programs in expected.items()
        for prog_name in programs.keys()
    }


def compare_metric(failures: list[str], name: str, actual: int, expected: int) -> None:
    if actual != expected:
        failures.append(f"`{name}` expected `{expected}`, got `{actual}`")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check arena-focused uml-veristat expectations")
    parser.add_argument(
        "--wrapper",
        default=str(pathlib.Path(__file__).resolve().parents[1] / "uml-veristat"),
        help="Path to the uml-veristat wrapper",
    )
    parser.add_argument(
        "--selftests-dir",
        default=os.path.expanduser("~/.local/share/uml-veristat/selftests"),
        help="Path to installed selftests output",
    )
    parser.add_argument(
        "--manifest",
        default=str(MANIFEST_PATH),
        help="Path to the corpus expectation manifest",
    )
    args = parser.parse_args()

    wrapper = pathlib.Path(args.wrapper).resolve()
    selftests_dir = pathlib.Path(os.path.expanduser(args.selftests_dir)).resolve()
    manifest_path = pathlib.Path(os.path.expanduser(args.manifest)).resolve()

    if not wrapper.is_file():
        raise SystemExit(f"wrapper not found: {wrapper}")
    if not selftests_dir.is_dir():
        raise SystemExit(f"selftests dir not found: {selftests_dir}")

    manifest = load_manifest(manifest_path)
    arena_manifest = manifest.get("arena_corpus")
    if not arena_manifest:
        raise SystemExit("arena_corpus expectations are missing from manifest")

    files = [selftests_dir / name for name in arena_manifest["files"]]
    missing = [str(path) for path in files if not path.is_file()]
    if missing:
        print("Arena expectation check failed.")
        for path in missing:
            print(f"missing input `{path}`")
        return 1

    env = os.environ.copy()
    table_cmd = [str(wrapper), *[str(path) for path in files]]
    csv_cmd = [str(wrapper), "-o", "csv", *[str(path) for path in files]]

    table = run(table_cmd, env=env)
    csv_result = run(csv_cmd, env=env)
    table_output = table.stdout + table.stderr
    csv_output = csv_result.stdout + csv_result.stderr

    rows = csv_rows(csv_output)
    processed_files, processed_programs, skipped_files, skipped_programs = parse_summary(table_output)
    failed_process, failed_open = parse_failures(table_output)
    success_rows = sum(1 for row in rows if row["verdict"] == "success")
    failure_rows = sum(1 for row in rows if row["verdict"] == "failure")

    actual_failed_programs = {
        (row["file_name"], row["prog_name"])
        for row in rows
        if row["verdict"] == "failure"
    }
    expected_failed_programs = expected_failure_set(manifest)

    failures: list[str] = []
    metrics = arena_manifest["expected_metrics"]
    compare_metric(failures, "input_files", len(files), metrics["input_files"])
    compare_metric(failures, "processed_files", processed_files, metrics["processed_files"])
    compare_metric(failures, "processed_programs", processed_programs, metrics["processed_programs"])
    compare_metric(failures, "skipped_files", skipped_files, metrics["skipped_files"])
    compare_metric(failures, "skipped_programs", skipped_programs, metrics["skipped_programs"])
    compare_metric(failures, "success_rows", success_rows, metrics["success_rows"])
    compare_metric(failures, "failure_rows", failure_rows, metrics["failure_rows"])

    if failed_process:
        failures.append(
            "unexpected failed-to-process files: "
            + ", ".join(f"`{name}` (`{errno}`)" for name, errno in failed_process)
        )
    if failed_open:
        failures.append(
            "unexpected failed-to-open files: "
            + ", ".join(f"`{name}` (`{errno}`)" for name, errno in failed_open)
        )

    missing_expected = sorted(expected_failed_programs - actual_failed_programs)
    unexpected_failed = sorted(actual_failed_programs - expected_failed_programs)
    for file_name, prog_name in missing_expected:
        failures.append(f"missing expected failure `{file_name}/{prog_name}`")
    for file_name, prog_name in unexpected_failed:
        failures.append(f"unexpected failure `{file_name}/{prog_name}`")

    if failures:
        print("Arena expectation check failed.")
        print("")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Arena expectation check passed.")
    print(f"- Input files: {len(files)}")
    print(f"- Processed programs: {processed_programs}")
    print(f"- Success rows: {success_rows}")
    print(f"- Expected failure rows: {failure_rows}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
