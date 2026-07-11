#!/usr/bin/env bash
# Check the local kernel patch stack with the kernel tree's checkpatch.pl.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UML_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

PATCHES_DIR="${PATCHES_DIR:-${UML_DIR}/patches}"
BPF_NEXT_DIR="${BPF_NEXT_DIR:-${UML_DIR}/.build/bpf-next}"
KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-master}"
CHECKPATCH="${CHECKPATCH:-}"
PATCH_STACK_DIRS=(
	"${PATCHES_DIR}/uml-veristat"
	"${PATCHES_DIR}/bpf-selftests-uml"
)

if [ ! -d "${PATCHES_DIR}" ]; then
	echo "Patch directory not found: ${PATCHES_DIR}" >&2
	exit 1
fi

if [ -z "${CHECKPATCH}" ]; then
	CHECKPATCH="${BPF_NEXT_DIR}/scripts/checkpatch.pl"
	if [ ! -x "${CHECKPATCH}" ]; then
		if [ -e "${BPF_NEXT_DIR}" ]; then
			echo "checkpatch.pl not found in existing kernel tree: ${CHECKPATCH}" >&2
			exit 1
		fi

		mkdir -p "$(dirname "${BPF_NEXT_DIR}")"
		git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${BPF_NEXT_DIR}"
	fi
fi

if [ ! -x "${CHECKPATCH}" ]; then
	echo "checkpatch.pl is not executable: ${CHECKPATCH}" >&2
	exit 1
fi

collect_patch_files() {
	local dir patch

	patches=()
	if [ -d "${PATCHES_DIR}/uml-veristat" ] || [ -d "${PATCHES_DIR}/bpf-selftests-uml" ]; then
		for dir in "${PATCH_STACK_DIRS[@]}"; do
			[ -d "${dir}" ] || continue
			for patch in "${dir}"/*.patch; do
				[ -f "${patch}" ] || continue
				patches+=("${patch}")
			done
		done
	else
		mapfile -t patches < <(find "${PATCHES_DIR}" -maxdepth 1 -type f -name '*.patch' | sort)
	fi
}

patches=()
collect_patch_files
if [ "${#patches[@]}" -eq 0 ]; then
	echo "No patch files found in ${PATCHES_DIR}" >&2
	exit 1
fi

abs_patches=()
for patch in "${patches[@]}"; do
	abs_patches+=("$(realpath "${patch}")")
done

# Run outside the repository and pass absolute patch paths. Otherwise
# checkpatch.pl can treat stored patches as regular files and report false
# whitespace errors on patch context lines.
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

(
	cd "${tmpdir}"
	"${CHECKPATCH}" --strict --ignore FILE_PATH_CHANGES --no-tree "${abs_patches[@]}"
)
