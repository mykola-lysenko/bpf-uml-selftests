#!/usr/bin/env python3

from __future__ import annotations

import csv
import os
import pathlib
import re
import subprocess
import tempfile
from dataclasses import asdict, dataclass


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


@dataclass
class CoverageResult:
    corpus: str
    input_files: int
    standalone_input_files: int
    excluded_expected_negative: list[str]
    excluded_fixture_only: list[str]
    processed_files: int
    processed_programs: int
    skipped_files: int
    skipped_programs: int
    success_rows: int
    failure_rows: int
    failed_process: list[tuple[str, int]]
    failed_open: list[tuple[str, int]]
    version_info: dict[str, str]

    def to_dict(self) -> dict:
        return asdict(self)


def run(cmd, check=True, **kwargs):
    return subprocess.run(cmd, text=True, check=check, **kwargs)


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


def collect_files(selftests_dir: pathlib.Path, corpus: str) -> list[pathlib.Path]:
    find_cmd = ["find", "-L", str(selftests_dir)]
    if corpus == "top-level":
        find_cmd.extend(["-maxdepth", "1"])
    find_cmd.extend(["-name", "*.bpf.o", "-print"])
    file_list = sorted(pathlib.Path(line) for line in run(find_cmd, capture_output=True).stdout.splitlines() if line)
    if not file_list:
        raise RuntimeError("no .bpf.o files found")
    return file_list


def run_corpus(
    wrapper: pathlib.Path,
    file_list: list[pathlib.Path],
    extra_env: dict[str, str] | None = None,
) -> tuple[str, str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    with tempfile.TemporaryDirectory(prefix="uml-veristat-coverage-") as tmpdir:
        tmpdir_path = pathlib.Path(tmpdir)
        filelist_path = tmpdir_path / "files.txt"
        filelist_path.write_text("\n".join(str(path) for path in file_list) + "\n")

        table_cmd = ["bash", "-lc", f'mapfile -t files < "{filelist_path}"; exec "{wrapper}" "${{files[@]}}"']
        table_output = run(table_cmd, capture_output=True, check=False, env=env).stdout
        csv_cmd = ["bash", "-lc", f'mapfile -t files < "{filelist_path}"; exec "{wrapper}" -o csv "${{files[@]}}"']
        csv_output = run(csv_cmd, capture_output=True, check=False, env=env).stdout
    return table_output, csv_output


def analyze_install(
    *,
    wrapper: pathlib.Path,
    selftests_dir: pathlib.Path,
    version_file: pathlib.Path,
    corpus: str = "top-level",
    extra_env: dict[str, str] | None = None,
) -> CoverageResult:
    version_info = load_version_info(version_file)
    file_list = collect_files(selftests_dir, corpus)
    positive_files, expected_negative_files, fixture_only_files = classify_files(file_list)
    if not positive_files:
        raise RuntimeError("no standalone positive files found")

    table_output, csv_output = run_corpus(wrapper, positive_files, extra_env=extra_env)
    processed_files, processed_programs, skipped_files, skipped_programs = parse_summary(table_output)
    failed_process, failed_open = parse_failures(table_output)
    success_rows, failure_rows = parse_csv_counts(csv_output)

    return CoverageResult(
        corpus=corpus,
        input_files=len(file_list),
        standalone_input_files=len(positive_files),
        excluded_expected_negative=[path.name for path in expected_negative_files],
        excluded_fixture_only=[path.name for path in fixture_only_files],
        processed_files=processed_files,
        processed_programs=processed_programs,
        skipped_files=skipped_files,
        skipped_programs=skipped_programs,
        success_rows=success_rows,
        failure_rows=failure_rows,
        failed_process=failed_process,
        failed_open=failed_open,
        version_info=version_info,
    )
