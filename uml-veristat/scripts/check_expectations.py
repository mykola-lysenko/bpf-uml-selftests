#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import pathlib
import sys

from coverage_lib import MANIFEST_PATH, analyze_install, load_manifest


def compare_named_list(
    failures: list[str],
    *,
    title: str,
    actual: list[str],
    expected: list[str],
) -> None:
    actual_set = set(actual)
    expected_set = set(expected)
    missing = sorted(expected_set - actual_set)
    unexpected = sorted(actual_set - expected_set)

    if not missing and not unexpected:
        return

    failures.append(f"{title}:")
    for name in missing:
        failures.append(f"  missing expected `{name}`")
    for name in unexpected:
        failures.append(f"  unexpected `{name}`")


def compare_failure_bucket(
    failures: list[str],
    *,
    title: str,
    actual: list[tuple[str, int]],
    expected: dict[str, dict],
) -> None:
    actual_map = {name: err for name, err in actual}
    expected_map = {name: spec["errno"] for name, spec in expected.items()}

    missing = sorted(expected_map.keys() - actual_map.keys())
    unexpected = sorted(actual_map.keys() - expected_map.keys())
    mismatched = sorted(
        name for name in expected_map.keys() & actual_map.keys() if expected_map[name] != actual_map[name]
    )

    if not missing and not unexpected and not mismatched:
        return

    failures.append(f"{title}:")
    for name in missing:
        failures.append(f"  missing expected `{name}` (`{expected_map[name]}`)")
    for name in unexpected:
        failures.append(f"  unexpected `{name}` (`{actual_map[name]}`)")
    for name in mismatched:
        failures.append(
            f"  errno mismatch for `{name}`: expected `{expected_map[name]}`, got `{actual_map[name]}`"
        )


def compare_metrics(
    failures: list[str],
    *,
    result,
    expected_metrics: dict[str, int],
) -> None:
    mismatches: list[str] = []
    for metric, expected_value in expected_metrics.items():
        actual_value = getattr(result, metric)
        if actual_value != expected_value:
            mismatches.append(
                f"  `{metric}` expected `{expected_value}`, got `{actual_value}`"
            )

    if mismatches:
        failures.append("metrics:")
        failures.extend(mismatches)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check uml-veristat coverage against the expectation manifest")
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
        "--manifest",
        default=str(MANIFEST_PATH),
        help="Path to the corpus expectation manifest",
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
    version_file = pathlib.Path(os.path.expanduser(args.version_file)).resolve()
    manifest_path = pathlib.Path(os.path.expanduser(args.manifest)).resolve()

    if not wrapper.is_file():
        raise SystemExit(f"wrapper not found: {wrapper}")
    if not selftests_dir.is_dir():
        raise SystemExit(f"selftests dir not found: {selftests_dir}")

    manifest = load_manifest(manifest_path)
    corpus_expectations = manifest.get("corpora", {}).get(args.corpus)
    if corpus_expectations is None:
        raise SystemExit(f"no expectations defined for corpus: {args.corpus}")

    result = analyze_install(
        wrapper=wrapper,
        selftests_dir=selftests_dir,
        version_file=version_file,
        corpus=args.corpus,
        manifest_path=manifest_path,
    )

    failures: list[str] = []
    compare_named_list(
        failures,
        title="expected-negative classification",
        actual=result.excluded_expected_negative,
        expected=manifest.get("expected_negative_files", []),
    )
    compare_named_list(
        failures,
        title="fixture-only classification",
        actual=result.excluded_fixture_only,
        expected=manifest.get("fixture_only_files", []),
    )
    compare_failure_bucket(
        failures,
        title="failed-to-process bucket",
        actual=result.failed_process,
        expected=corpus_expectations.get("expected_failed_process", {}),
    )
    compare_failure_bucket(
        failures,
        title="failed-to-open bucket",
        actual=result.failed_open,
        expected=corpus_expectations.get("expected_failed_open", {}),
    )
    compare_metrics(
        failures,
        result=result,
        expected_metrics=corpus_expectations.get("expected_metrics", {}),
    )

    if failures:
        print(f"Expectation check failed for corpus `{args.corpus}`.")
        print("")
        for line in failures:
            print(line)
        return 1

    print(f"Expectation check passed for corpus `{args.corpus}`.")
    print(f"- Standalone input files: {result.standalone_input_files}")
    print(f"- Failed-to-process files: {len(result.failed_process)}")
    print(f"- Failed-to-open files: {len(result.failed_open)}")
    print(f"- Success rows: {result.success_rows}")
    print(f"- Failure rows: {result.failure_rows}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
