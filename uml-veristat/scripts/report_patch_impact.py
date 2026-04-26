#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
from dataclasses import asdict

from coverage_lib import CoverageResult, analyze_install


def parse_case(spec: str) -> tuple[str, pathlib.Path]:
    if "=" not in spec:
        raise argparse.ArgumentTypeError(f"invalid case '{spec}', expected LABEL=INSTALL_DIR")
    label, install_dir = spec.split("=", 1)
    label = label.strip()
    install_path = pathlib.Path(os.path.expanduser(install_dir.strip())).resolve()
    if not label:
        raise argparse.ArgumentTypeError("case label cannot be empty")
    return label, install_path


def case_env(install_dir: pathlib.Path) -> dict[str, str]:
    env = {
        "UML_KERNEL": str(install_dir / "linux"),
        "VERISTAT": str(install_dir / "veristat"),
    }
    module = install_dir / "bpf_testmod.ko"
    env["UML_MODULES"] = str(module) if module.is_file() else ""
    return env


def case_result(label: str, install_dir: pathlib.Path, wrapper: pathlib.Path, corpus: str) -> CoverageResult:
    return analyze_install(
        wrapper=wrapper,
        selftests_dir=(install_dir / "selftests").resolve(),
        version_file=(install_dir / "version.txt").resolve(),
        corpus=corpus,
        extra_env=case_env(install_dir),
    )


def delta(current: int, baseline: int) -> str:
    diff = current - baseline
    return f"{diff:+d}"


def file_names(entries: list[tuple[str, int]]) -> set[str]:
    return {name for name, _ in entries}


def render_markdown(results: dict[str, CoverageResult], baseline_label: str) -> str:
    baseline = results[baseline_label]
    lines: list[str] = []
    lines.append("# Patch Impact Report")
    lines.append("")
    lines.append("This report compares installed `uml-veristat` variants using the same coverage logic as `scripts/report_coverage.py`.")
    lines.append("")
    lines.append(f"- Baseline: `{baseline_label}`")
    lines.append(f"- Corpus: `{baseline.corpus}`")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Case | Standalone files | Processed files | Processed programs | Success rows | Failure rows | Failed-to-process | Failed-to-open |")
    lines.append("|------|------------------|-----------------|--------------------|--------------|--------------|-------------------|----------------|")
    for label, result in results.items():
        lines.append(
            f"| `{label}` | `{result.standalone_input_files}` | `{result.processed_files}` | "
            f"`{result.processed_programs}` | `{result.success_rows}` | `{result.failure_rows}` | "
            f"`{len(result.failed_process)}` | `{len(result.failed_open)}` |"
        )
    lines.append("")
    lines.append("## Delta Vs Baseline")
    lines.append("")
    lines.append("| Case | Standalone files | Processed files | Processed programs | Success rows | Failure rows | Failed-to-process | Failed-to-open |")
    lines.append("|------|------------------|-----------------|--------------------|--------------|--------------|-------------------|----------------|")
    for label, result in results.items():
        lines.append(
            f"| `{label}` | `{delta(result.standalone_input_files, baseline.standalone_input_files)}` | "
            f"`{delta(result.processed_files, baseline.processed_files)}` | "
            f"`{delta(result.processed_programs, baseline.processed_programs)}` | "
            f"`{delta(result.success_rows, baseline.success_rows)}` | "
            f"`{delta(result.failure_rows, baseline.failure_rows)}` | "
            f"`{delta(len(result.failed_process), len(baseline.failed_process))}` | "
            f"`{delta(len(result.failed_open), len(baseline.failed_open))}` |"
        )
    lines.append("")

    for label, result in results.items():
        lines.append(f"## {label}")
        lines.append("")
        if result.version_info:
            built = result.version_info.get("Built")
            mode = result.version_info.get("mode")
            bpf_next = result.version_info.get("bpf-next")
            llvm = result.version_info.get("LLVM")
            pahole = result.version_info.get("pahole")
            if built:
                lines.append(f"- Built: `{built}`")
            if mode:
                lines.append(f"- Mode: `{mode}`")
            if bpf_next:
                lines.append(f"- bpf-next: `{bpf_next}`")
            if llvm:
                lines.append(f"- LLVM: `{llvm}`")
            if pahole:
                lines.append(f"- pahole: `{pahole}`")
            lines.append("")
        if label != baseline_label:
            fixed_process = sorted(file_names(baseline.failed_process) - file_names(result.failed_process))
            new_process_failures = sorted(file_names(result.failed_process) - file_names(baseline.failed_process))
            fixed_open = sorted(file_names(baseline.failed_open) - file_names(result.failed_open))
            new_open_failures = sorted(file_names(result.failed_open) - file_names(baseline.failed_open))

            if fixed_process:
                lines.append("### Newly Processable Files")
                lines.append("")
                lines.extend(f"- `{name}`" for name in fixed_process)
                lines.append("")
            if new_process_failures:
                lines.append("### Newly Failed-To-Process Files")
                lines.append("")
                lines.extend(f"- `{name}`" for name in new_process_failures)
                lines.append("")
            if fixed_open:
                lines.append("### Newly Openable Files")
                lines.append("")
                lines.extend(f"- `{name}`" for name in fixed_open)
                lines.append("")
            if new_open_failures:
                lines.append("### Newly Failed-To-Open Files")
                lines.append("")
                lines.extend(f"- `{name}`" for name in new_open_failures)
                lines.append("")

        if result.failed_process:
            lines.append("### Failed To Process")
            lines.append("")
            lines.extend(f"- `{name}` (`{err}`)" for name, err in result.failed_process)
            lines.append("")
        if result.failed_open:
            lines.append("### Failed To Open")
            lines.append("")
            lines.extend(f"- `{name}` (`{err}`)" for name, err in result.failed_open)
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate patch-impact reports from installed uml-veristat variants")
    parser.add_argument(
        "--case",
        action="append",
        required=True,
        metavar="LABEL=INSTALL_DIR",
        help="Installed variant to analyze, for example patched=~/.local/share/uml-veristat",
    )
    parser.add_argument(
        "--baseline",
        help="Case label to use as the baseline. Defaults to the first --case.",
    )
    parser.add_argument(
        "--wrapper",
        default=str(pathlib.Path(__file__).resolve().parents[1] / "uml-veristat"),
        help="Path to the uml-veristat wrapper",
    )
    parser.add_argument(
        "--corpus",
        choices=["top-level", "all"],
        default="top-level",
        help="Use only the top-level .bpf.o corpus or every generated variant",
    )
    parser.add_argument(
        "--output-dir",
        default=str(pathlib.Path(__file__).resolve().parents[1] / "reports" / "patch-impact"),
        help="Directory for generated JSON outputs",
    )
    parser.add_argument(
        "--markdown-output",
        default=str(pathlib.Path(__file__).resolve().parents[2] / "docs" / "patch-impact.md"),
        help="Path for the generated Markdown summary",
    )
    args = parser.parse_args()

    wrapper = pathlib.Path(args.wrapper).resolve()
    output_dir = pathlib.Path(os.path.expanduser(args.output_dir)).resolve()
    markdown_output = pathlib.Path(os.path.expanduser(args.markdown_output)).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown_output.parent.mkdir(parents=True, exist_ok=True)

    parsed_cases = [parse_case(spec) for spec in args.case]
    baseline_label = args.baseline or parsed_cases[0][0]
    case_map = dict(parsed_cases)
    if baseline_label not in case_map:
        raise SystemExit(f"unknown baseline label: {baseline_label}")

    results: dict[str, CoverageResult] = {}
    for label, install_dir in parsed_cases:
        if not install_dir.is_dir():
            raise SystemExit(f"install dir not found for case '{label}': {install_dir}")
        results[label] = case_result(label, install_dir, wrapper, args.corpus)
        with (output_dir / f"{label}.json").open("w") as fp:
            json.dump(results[label].to_dict(), fp, indent=2, sort_keys=True)
            fp.write("\n")

    summary = {
        "baseline": baseline_label,
        "corpus": args.corpus,
        "cases": {label: asdict(result) for label, result in results.items()},
    }
    with (output_dir / "summary.json").open("w") as fp:
        json.dump(summary, fp, indent=2, sort_keys=True)
        fp.write("\n")

    markdown_output.write_text(render_markdown(results, baseline_label))
    print(f"Wrote JSON reports to {output_dir}")
    print(f"Wrote Markdown summary to {markdown_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
