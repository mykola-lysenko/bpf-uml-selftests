#!/usr/bin/env python3

import argparse
import os
import pathlib
import sys
from coverage_lib import analyze_install


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
    if not wrapper.is_file():
        raise SystemExit(f"wrapper not found: {wrapper}")
    if not selftests_dir.is_dir():
        raise SystemExit(f"selftests dir not found: {selftests_dir}")

    result = analyze_install(
        wrapper=wrapper,
        selftests_dir=selftests_dir,
        version_file=pathlib.Path(os.path.expanduser(args.version_file)).resolve(),
        corpus=args.corpus,
    )

    print("## Coverage Report")
    print("")
    print(f"- Corpus: `{args.corpus}`")
    print(f"- Input `.bpf.o` files: `{result.input_files}`")
    print(f"- Standalone positive corpus: `{result.standalone_input_files}`")
    print(f"- Excluded expected-negative tests: `{len(result.excluded_expected_negative)}`")
    print(f"- Excluded fixture-only objects: `{len(result.excluded_fixture_only)}`")
    if result.version_info:
        built = result.version_info.get("Built")
        bpf_next = result.version_info.get("bpf-next")
        llvm = result.version_info.get("LLVM")
        pahole = result.version_info.get("pahole")
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
    print(f"| Standalone input files | `{result.standalone_input_files}` |")
    print(f"| Processed files | `{result.processed_files}` |")
    print(f"| Skipped files | `{result.skipped_files}` |")
    print(f"| Processed programs | `{result.processed_programs}` |")
    print(f"| Skipped programs | `{result.skipped_programs}` |")
    print(f"| Successful CSV rows | `{result.success_rows}` |")
    print(f"| Failing CSV rows | `{result.failure_rows}` |")
    print(f"| Remaining failed-to-process files | `{len(result.failed_process)}` |")
    print(f"| Remaining failed-to-open files | `{len(result.failed_open)}` |")
    print("")
    print_file_list("Excluded Expected-Negative Tests", result.excluded_expected_negative)
    print_file_list("Excluded Fixture-Only Objects", result.excluded_fixture_only)
    print_failure_list("Remaining Failed To Process", result.failed_process)
    print_failure_list("Remaining Failed To Open", result.failed_open)

    return 0


if __name__ == "__main__":
    sys.exit(main())
