#!/usr/bin/env python3

import argparse
import csv
import os
import pathlib
import re
import subprocess
import sys
import tempfile


def run(cmd, check=True, **kwargs):
    return subprocess.run(cmd, text=True, check=check, **kwargs)


EXPECTED_NEGATIVE_FILES = {
    "bad_struct_ops.bpf.o",
    "struct_ops_autocreate.bpf.o",
    "test_pinning_invalid.bpf.o",
}


FIXTURE_ONLY_FILES = {
    "linked_funcs1.bpf.o",
    "linked_funcs2.bpf.o",
    "linked_maps1.bpf.o",
    "linked_maps2.bpf.o",
    "linked_vars1.bpf.o",
    "linked_vars2.bpf.o",
    "test_subskeleton_lib.bpf.o",
    "test_subskeleton_lib2.bpf.o",
}


def load_version_info(version_path: pathlib.Path) -> dict[str, str]:
    info: dict[str, str] = {}
    if not version_path.is_file():
        return info
    for line in version_path.read_text().splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        info[key.strip()] = value.strip()
    return info


def parse_summary(table_output: str) -> tuple[int, int, int, int]:
    match = re.search(
        r"Done\. Processed (\d+) files, (\d+) programs\. Skipped (\d+) files, (\d+) programs\.",
        table_output,
    )
    if not match:
        raise RuntimeError("failed to parse veristat summary line")
    return tuple(int(group) for group in match.groups())


def parse_failures(output: str) -> tuple[list[tuple[str, int]], list[tuple[str, int]]]:
    failed_process: list[tuple[str, int]] = []
    failed_open: list[tuple[str, int]] = []
    for line in output.splitlines():
        match = re.match(r"Failed to (process|open) '(.+?)': (-?\d+)", line)
        if not match:
            continue
        entry = (pathlib.Path(match.group(2)).name, int(match.group(3)))
        if match.group(1) == "process":
            failed_process.append(entry)
        else:
            failed_open.append(entry)
    return failed_process, failed_open


def parse_csv_counts(csv_output: str) -> tuple[int, int]:
    lines = csv_output.splitlines()
    header_idx = next(i for i, line in enumerate(lines) if line.startswith("file_name,"))
    rows = list(csv.DictReader(lines[header_idx:]))
    success = sum(1 for row in rows if row["verdict"] == "success")
    failure = sum(1 for row in rows if row["verdict"] == "failure")
    return success, failure


def classify_files(
    file_list: list[pathlib.Path],
) -> tuple[list[pathlib.Path], list[pathlib.Path], list[pathlib.Path]]:
    positive = []
    expected_negative = []
    fixture_only = []

    for path in file_list:
        name = path.name
        if name in EXPECTED_NEGATIVE_FILES:
            expected_negative.append(path)
        elif name in FIXTURE_ONLY_FILES:
            fixture_only.append(path)
        else:
            positive.append(path)
    return positive, expected_negative, fixture_only


def run_corpus(wrapper: pathlib.Path, file_list: list[pathlib.Path]) -> tuple[str, str]:
    with tempfile.TemporaryDirectory(prefix="uml-veristat-coverage-") as tmpdir:
        tmpdir_path = pathlib.Path(tmpdir)
        filelist_path = tmpdir_path / "files.txt"
        filelist_path.write_text("\n".join(str(path) for path in file_list) + "\n")

        table_cmd = ["bash", "-lc", f'mapfile -t files < "{filelist_path}"; exec "{wrapper}" "${{files[@]}}"']
        table_output = run(table_cmd, capture_output=True, check=False).stdout
        csv_cmd = ["bash", "-lc", f'mapfile -t files < "{filelist_path}"; exec "{wrapper}" -o csv "${{files[@]}}"']
        csv_output = run(csv_cmd, capture_output=True, check=False).stdout
    return table_output, csv_output


def print_file_list(title: str, names: list[str]) -> None:
    if not names:
        return
    print(f"### {title}")
    print("")
    for name in names:
        print(f"- `{name}`")
    print("")


def print_failure_list(title: str, failures: list[tuple[str, int]]) -> None:
    if not failures:
        return
    print(f"### {title}")
    print("")
    for name, err in failures:
        print(f"- `{name}` (`{err}`)")
    print("")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run reproducible uml-veristat coverage report")
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
        "--version-file",
        default=os.path.expanduser("~/.local/share/uml-veristat/version.txt"),
        help="Path to installed version.txt",
    )
    parser.add_argument(
        "--corpus",
        choices=["top-level", "all"],
        default="top-level",
        help="Use only the top-level .bpf.o corpus or every generated variant",
    )
    args = parser.parse_args()

    wrapper = pathlib.Path(args.wrapper).resolve()
    selftests_dir = pathlib.Path(os.path.expanduser(args.selftests_dir)).resolve()
    version_info = load_version_info(pathlib.Path(os.path.expanduser(args.version_file)))

    if not wrapper.is_file():
        raise SystemExit(f"wrapper not found: {wrapper}")
    if not selftests_dir.is_dir():
        raise SystemExit(f"selftests dir not found: {selftests_dir}")

    find_cmd = ["find", "-L", str(selftests_dir)]
    if args.corpus == "top-level":
        find_cmd.extend(["-maxdepth", "1"])
    find_cmd.extend(["-name", "*.bpf.o", "-print"])
    file_list = sorted(pathlib.Path(line) for line in run(find_cmd, capture_output=True).stdout.splitlines() if line)
    if not file_list:
        raise SystemExit("no .bpf.o files found")
    positive_files, expected_negative_files, fixture_only_files = classify_files(file_list)
    if not positive_files:
        raise SystemExit("no standalone positive files found")

    table_output, csv_output = run_corpus(wrapper, positive_files)

    processed_files, processed_programs, skipped_files, skipped_programs = parse_summary(table_output)
    failed_process, failed_open = parse_failures(table_output)
    success_rows, failure_rows = parse_csv_counts(csv_output)

    print("## Coverage Report")
    print("")
    print(f"- Corpus: `{args.corpus}`")
    print(f"- Input `.bpf.o` files: `{len(file_list)}`")
    print(f"- Standalone positive corpus: `{len(positive_files)}`")
    print(f"- Excluded expected-negative tests: `{len(expected_negative_files)}`")
    print(f"- Excluded fixture-only objects: `{len(fixture_only_files)}`")
    if version_info:
        built = version_info.get("Built")
        bpf_next = version_info.get("bpf-next")
        llvm = version_info.get("LLVM")
        pahole = version_info.get("pahole")
        if built:
            print(f"- Built: `{built}`")
        if bpf_next:
            print(f"- bpf-next: `{bpf_next}`")
        if llvm:
            print(f"- LLVM: `{llvm}`")
        if pahole:
            print(f"- pahole: `{pahole}`")
    print("")
    print("| Metric | Value |")
    print("|--------|-------|")
    print(f"| Standalone input files | `{len(positive_files)}` |")
    print(f"| Processed files | `{processed_files}` |")
    print(f"| Skipped files | `{skipped_files}` |")
    print(f"| Processed programs | `{processed_programs}` |")
    print(f"| Skipped programs | `{skipped_programs}` |")
    print(f"| Successful CSV rows | `{success_rows}` |")
    print(f"| Failing CSV rows | `{failure_rows}` |")
    print(f"| Remaining failed-to-process files | `{len(failed_process)}` |")
    print(f"| Remaining failed-to-open files | `{len(failed_open)}` |")
    print("")
    print_file_list("Excluded Expected-Negative Tests", [path.name for path in expected_negative_files])
    print_file_list("Excluded Fixture-Only Objects", [path.name for path in fixture_only_files])
    print_failure_list("Remaining Failed To Process", failed_process)
    print_failure_list("Remaining Failed To Open", failed_open)

    return 0


if __name__ == "__main__":
    sys.exit(main())
