#!/bin/bash
# ==============================================================================
# build.sh — one-time setup for uml-veristat
# ==============================================================================
#
# Builds three artifacts from source and installs them to
# ~/.local/share/uml-veristat/:
#
#   linux      — UML kernel binary (bpf-next master, with BPF enabled)
#   veristat   — veristat binary (built from the same bpf-next tree)
#   selftests/ — BPF selftest .bpf.o files (ready inputs for uml-veristat)
#
# Also builds LLVM/Clang from source (main branch, BPF+X86 backends only)
# and pahole from source, since they are needed to build the kernel and
# the BPF selftests tools.
#
# Usage:
#   ./build.sh [--update]
#
#   --update   Re-fetch bpf-next and LLVM to latest tip and rebuild.
#              Without this flag, existing builds are reused (idempotent).
#
# Requirements:
#   ~35 GB free disk space, 8+ CPU cores recommended, sudo for package install.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurable source versions
# ------------------------------------------------------------------------------
LLVM_REPO="https://github.com/llvm/llvm-project.git"
LLVM_BRANCH="main"                   # LLVM 23 development tip

PAHOLE_REPO="https://github.com/acmel/dwarves.git"
PAHOLE_TAG="v1.31"

KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git"
KERNEL_BRANCH="master"

# ------------------------------------------------------------------------------
# Directory layout
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/.build"
INSTALL_DIR="${HOME}/.local/share/uml-veristat"

LLVM_SRC="${WORKDIR}/llvm-project"
LLVM_BUILD="${WORKDIR}/llvm-build"
LLVM_INSTALL="${WORKDIR}/llvm-install"
PAHOLE_SRC="${WORKDIR}/dwarves"
PAHOLE_BUILD="${WORKDIR}/pahole-build"
PAHOLE_INSTALL="${WORKDIR}/pahole-install"
LINUX_DIR="${WORKDIR}/bpf-next"
SELFTESTS_DIR="${LINUX_DIR}/tools/testing/selftests/bpf"
SELFTESTS_OUTPUT="${WORKDIR}/selftests-output"

CLANG="${LLVM_INSTALL}/bin/clang"
LLC="${LLVM_INSTALL}/bin/llc"
PAHOLE_BIN="${PAHOLE_INSTALL}/bin/pahole"

# ------------------------------------------------------------------------------
# Colour helpers
# ------------------------------------------------------------------------------
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[build]${NC}  $*"; }
step() { echo -e "${CYAN}[build]${NC}  === $* ==="; }
warn() { echo -e "${YELLOW}[build]${NC}  $*"; }

# ------------------------------------------------------------------------------
# Parse flags
# ------------------------------------------------------------------------------
DO_UPDATE=0
for arg in "$@"; do
    case "${arg}" in
        --update) DO_UPDATE=1 ;;
        -h|--help)
            echo "Usage: ./build.sh [--update]"
            echo "  --update   Pull latest bpf-next and LLVM, then rebuild."
            exit 0 ;;
        *) echo "Unknown argument: ${arg}"; exit 1 ;;
    esac
done

mkdir -p "${WORKDIR}" "${INSTALL_DIR}"

# ------------------------------------------------------------------------------
# Detect host OS and install build dependencies
# ------------------------------------------------------------------------------
step "1/7  Installing host build dependencies"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
else
    OS_ID="unknown"; OS_ID_LIKE=""
fi

_is_like() { echo "${OS_ID} ${OS_ID_LIKE}" | grep -qwi "$1"; }

if _is_like debian || _is_like ubuntu; then       DISTRO_FAMILY="debian"
elif _is_like fedora || _is_like rhel || _is_like centos; then DISTRO_FAMILY="fedora"
elif _is_like suse || _is_like opensuse; then     DISTRO_FAMILY="suse"
elif _is_like arch || [ "${OS_ID}" = "arch" ] || [ "${OS_ID}" = "manjaro" ]; then
                                                   DISTRO_FAMILY="arch"
else
    warn "Unrecognised distro '${OS_ID}'; trying Debian package names."
    DISTRO_FAMILY="debian"
fi

info "Distro family: ${DISTRO_FAMILY} (ID=${OS_ID})"

case "${DISTRO_FAMILY}" in
  debian)
    sudo apt-get update -qq
    sudo apt-get install -y \
        build-essential git bc flex bison \
        libelf-dev libssl-dev libdw-dev libdwarf-dev \
        pkg-config cmake ninja-build python3 \
        libcap-dev curl wget rsync zlib1g-dev ;;
  fedora)
    PKG_MGR="dnf"; command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
    sudo "${PKG_MGR}" install -y \
        gcc gcc-c++ make git bc flex bison \
        elfutils-libelf-devel openssl-devel elfutils-devel libdwarf-devel \
        pkgconf-pkg-config cmake ninja-build python3 \
        libcap-devel curl wget rsync zlib-devel ;;
  suse)
    sudo zypper install -y \
        gcc gcc-c++ make git bc flex bison \
        libelf-devel libopenssl-devel libdw-devel libdwarf-devel \
        pkg-config cmake ninja python3 \
        libcap-devel curl wget rsync zlib-devel ;;
  arch)
    sudo pacman -Sy --noconfirm \
        base-devel git bc flex bison \
        libelf openssl elfutils libdwarf \
        pkgconf cmake ninja python \
        libcap curl wget rsync zlib ;;
esac

# ------------------------------------------------------------------------------
# Build LLVM/Clang from source (BPF + X86 backends only)
# ------------------------------------------------------------------------------
step "2/7  Building LLVM/Clang (${LLVM_BRANCH} branch, BPF+X86 only)"
info "This is the longest step — ~25 min on 8 cores, ~45 min on 4 cores."

if [ ! -d "${LLVM_SRC}/.git" ]; then
    info "Cloning LLVM (shallow)..."
    git clone --depth=1 --branch "${LLVM_BRANCH}" "${LLVM_REPO}" "${LLVM_SRC}"
elif [ "${DO_UPDATE}" = "1" ]; then
    info "Updating LLVM to latest ${LLVM_BRANCH}..."
    git -C "${LLVM_SRC}" fetch --depth=1 origin "${LLVM_BRANCH}"
    git -C "${LLVM_SRC}" reset --hard "origin/${LLVM_BRANCH}"
    rm -rf "${LLVM_BUILD}" "${LLVM_INSTALL}"
fi

LLVM_COMMIT=$(git -C "${LLVM_SRC}" rev-parse --short HEAD)
info "LLVM HEAD: ${LLVM_COMMIT}"

if [ ! -f "${CLANG}" ]; then
    mkdir -p "${LLVM_BUILD}"
    cmake -S "${LLVM_SRC}/llvm" -B "${LLVM_BUILD}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}" \
        -DLLVM_TARGETS_TO_BUILD="BPF;X86" \
        -DLLVM_ENABLE_PROJECTS="clang" \
        -DLLVM_ENABLE_RUNTIMES="" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_DOCS=OFF \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_ENABLE_ZLIB=ON \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        2>&1 | tail -5
    ninja -C "${LLVM_BUILD}" -j"$(nproc)" clang llc llvm-strip llvm-objcopy
    ninja -C "${LLVM_BUILD}" install
    info "Clang: $(${CLANG} --version | head -1)"
else
    info "Clang already built — skipping. (Use --update to rebuild.)"
fi

# ------------------------------------------------------------------------------
# Build pahole from source
# ------------------------------------------------------------------------------
step "3/7  Building pahole ${PAHOLE_TAG}"

if [ ! -d "${PAHOLE_SRC}/.git" ]; then
    git clone --depth=1 --branch "${PAHOLE_TAG}" "${PAHOLE_REPO}" "${PAHOLE_SRC}"
fi

if [ ! -f "${PAHOLE_BIN}" ]; then
    mkdir -p "${PAHOLE_BUILD}"
    cmake -S "${PAHOLE_SRC}" -B "${PAHOLE_BUILD}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PAHOLE_INSTALL}" \
        -DCMAKE_INSTALL_RPATH="${PAHOLE_INSTALL}/lib" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -D__LIB=lib \
        -DLIBBPF_EMBEDDED=ON \
        2>&1 | tail -5
    make -C "${PAHOLE_BUILD}" -j"$(nproc)"
    make -C "${PAHOLE_BUILD}" install
    info "pahole: $(${PAHOLE_BIN} --version)"
else
    info "pahole already built — skipping."
fi

# ------------------------------------------------------------------------------
# Clone / update bpf-next
# ------------------------------------------------------------------------------
step "4/7  Fetching bpf-next kernel (${KERNEL_BRANCH})"

if [ ! -d "${LINUX_DIR}/.git" ]; then
    info "Cloning bpf-next (shallow)..."
    git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${LINUX_DIR}"
elif [ "${DO_UPDATE}" = "1" ]; then
    info "Updating bpf-next to latest ${KERNEL_BRANCH}..."
    git -C "${LINUX_DIR}" fetch --depth=1 origin "${KERNEL_BRANCH}"
    git -C "${LINUX_DIR}" reset --hard "origin/${KERNEL_BRANCH}"
fi

KERNEL_COMMIT=$(git -C "${LINUX_DIR}" rev-parse --short HEAD)
KERNEL_VERSION=$(make -C "${LINUX_DIR}" -s kernelversion 2>/dev/null || echo "unknown")
info "bpf-next: ${KERNEL_COMMIT}  (${KERNEL_VERSION})"

# ------------------------------------------------------------------------------
# Configure the UML kernel
# ------------------------------------------------------------------------------
step "5/7  Configuring UML kernel"

cd "${LINUX_DIR}"
make ARCH=um defconfig

# Enable BPF, cgroups, and networking options required for veristat
cat >> .config << 'KCONFIG'
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=n
CONFIG_CGROUPS=y
CONFIG_CGROUP_BPF=y
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=n
CONFIG_NETFILTER=n
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_PAHOLE_HAS_SPLIT_BTF=y
KCONFIG

make ARCH=um PAHOLE="${PAHOLE_BIN}" olddefconfig
info "Kernel configured: $(grep "^CONFIG_BPF_SYSCALL=y" .config && echo BPF_SYSCALL enabled)"

# ------------------------------------------------------------------------------
# Build the UML kernel
# ------------------------------------------------------------------------------
step "6/7  Building UML kernel"

make ARCH=um PAHOLE="${PAHOLE_BIN}" -j"$(nproc)"

# The UML binary is named after the host architecture (e.g. linux, vmlinux)
UML_BINARY=""
for candidate in linux vmlinux; do
    if [ -x "${LINUX_DIR}/${candidate}" ]; then
        UML_BINARY="${LINUX_DIR}/${candidate}"
        break
    fi
done
[ -n "${UML_BINARY}" ] || { echo "UML kernel binary not found after build"; exit 1; }
info "UML kernel: ${UML_BINARY} ($(ls -lh "${UML_BINARY}" | awk '{print $5}'))"

# ------------------------------------------------------------------------------
# Build veristat and BPF selftests from the bpf-next tree
#
# veristat lives at tools/testing/selftests/bpf/veristat.c and is built
# as part of the BPF selftests.  Building the selftests also produces all
# the .bpf.o object files that are the natural inputs for uml-veristat.
#
# The selftests Makefile inherits CLANG and LLC from
# tools/scripts/Makefile.include (CLANG ?= clang, LLC ?= llc), so we
# override them on the command line to point at our freshly built clang.
# ARCH=x86_64 is required because the selftests must be built for the
# host x86_64 ABI even when the kernel was configured with ARCH=um.
# ------------------------------------------------------------------------------
step "7/7  Building veristat and BPF selftests"

mkdir -p "${SELFTESTS_OUTPUT}"

VERISTAT_BIN="${SELFTESTS_OUTPUT}/veristat"

if [ ! -x "${VERISTAT_BIN}" ] || [ "${DO_UPDATE}" = "1" ]; then
    info "Building veristat from ${SELFTESTS_DIR}..."
    make -C "${SELFTESTS_DIR}" \
        OUTPUT="${SELFTESTS_OUTPUT}/" \
        CLANG="${CLANG}" \
        LLC="${LLC}" \
        ARCH=x86_64 \
        -j"$(nproc)" \
        veristat
else
    info "veristat already built — skipping. (Use --update to rebuild.)"
fi

[ -x "${VERISTAT_BIN}" ] || { echo "veristat build failed"; exit 1; }
info "veristat: ${VERISTAT_BIN}"

# Build the BPF selftest .bpf.o files so they are available as ready-made
# inputs for uml-veristat.  This step is optional but highly recommended.
info "Building BPF selftest object files..."
make -C "${SELFTESTS_DIR}" \
    OUTPUT="${SELFTESTS_OUTPUT}/" \
    CLANG="${CLANG}" \
    LLC="${LLC}" \
    ARCH=x86_64 \
    -j"$(nproc)" \
    bpf_obj_files 2>/dev/null \
  || make -C "${SELFTESTS_DIR}" \
        OUTPUT="${SELFTESTS_OUTPUT}/" \
        CLANG="${CLANG}" \
        LLC="${LLC}" \
        ARCH=x86_64 \
        -j"$(nproc)" \
        $(ls "${SELFTESTS_DIR}"/*.bpf.c 2>/dev/null | \
          sed 's|.*/||; s|\.bpf\.c|.bpf.o|' | \
          sed "s|^|${SELFTESTS_OUTPUT}/|" | tr '\n' ' ') 2>/dev/null \
  || info "Note: individual .bpf.o files can be built on demand with: make -C ${SELFTESTS_DIR} OUTPUT=... CLANG=... <name>.bpf.o"

BPF_OBJ_COUNT=$(find "${SELFTESTS_OUTPUT}" -name "*.bpf.o" 2>/dev/null | wc -l)
info "BPF object files built: ${BPF_OBJ_COUNT} files in ${SELFTESTS_OUTPUT}/"

# ------------------------------------------------------------------------------
# Install artifacts
# ------------------------------------------------------------------------------
info "Installing to ${INSTALL_DIR}/"
cp "${UML_BINARY}"    "${INSTALL_DIR}/linux"
cp "${VERISTAT_BIN}"  "${INSTALL_DIR}/veristat"
chmod +x "${INSTALL_DIR}/linux" "${INSTALL_DIR}/veristat"

# Symlink the selftests output directory so uml-veristat can find .bpf.o files
ln -sfn "${SELFTESTS_OUTPUT}" "${INSTALL_DIR}/selftests"

# Write a version manifest for diagnostics
cat > "${INSTALL_DIR}/version.txt" <<EOF
Built: $(date -u +"%Y-%m-%d %H:%M UTC")
bpf-next: ${KERNEL_COMMIT} (${KERNEL_VERSION})
LLVM: ${LLVM_COMMIT}
pahole: ${PAHOLE_TAG}
EOF

echo ""
info "Build complete!"
info ""
info "  UML kernel : ${INSTALL_DIR}/linux"
info "  veristat   : ${INSTALL_DIR}/veristat"
info "  Selftests  : ${INSTALL_DIR}/selftests/ (${BPF_OBJ_COUNT} .bpf.o files)"
info "  Versions   : ${INSTALL_DIR}/version.txt"
info ""
info "Run uml-veristat to verify BPF programs:"
info "  uml-veristat prog.bpf.o"
info "  uml-veristat ~/.local/share/uml-veristat/selftests/test_progs.bpf.o"
info "  uml-veristat -l 2 prog.bpf.o"
