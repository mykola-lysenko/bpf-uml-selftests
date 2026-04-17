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
#   ./build.sh [--update] [--package]
#
#   --update   Re-fetch bpf-next and LLVM to latest tip and rebuild.
#              Without this flag, existing builds are reused (idempotent).
#
#   --package  After building, assemble a self-contained distributable
#              package tarball: uml-veristat-<kernel-commit>-<arch>.tar.gz
#              Contains: uml-veristat wrapper, linux binary, veristat binary,
#              kernel .config, version.txt (full provenance), sha256sums, README.
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
DO_PACKAGE=0
REBUILD_LLVM=0
REBUILD_PAHOLE=0
REBUILD_KERNEL=0
REBUILD_BPFTOOL=0
REBUILD_SELFTESTS=0

for arg in "$@"; do
    case "${arg}" in
        --update)  DO_UPDATE=1 ;;
        --package) DO_PACKAGE=1 ;;
        --rebuild-llvm)      REBUILD_LLVM=1 ;;
        --rebuild-pahole)    REBUILD_PAHOLE=1 ;;
        --rebuild-kernel)    REBUILD_KERNEL=1 ;;
        --rebuild-bpftool)   REBUILD_BPFTOOL=1 ;;
        --rebuild-selftests) REBUILD_SELFTESTS=1 ;;
        -h|--help)
            echo "Usage: ./build.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --update             Pull latest bpf-next and LLVM, then rebuild."
            echo "  --package            After building, create a distributable tarball."
            echo ""
            echo "Per-stage rebuild options (skips checking if already built):"
            echo "  --rebuild-llvm       Rebuild LLVM/Clang"
            echo "  --rebuild-pahole     Rebuild pahole"
            echo "  --rebuild-kernel     Rebuild UML kernel"
            echo "  --rebuild-bpftool    Rebuild bpftool"
            echo "  --rebuild-selftests  Rebuild veristat and BPF selftests"
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

if [ ! -f "${CLANG}" ] || [ "${REBUILD_LLVM}" = "1" ] || [ "${DO_UPDATE}" = "1" ]; then
    mkdir -p "${LLVM_BUILD}"
    cmake -S "${LLVM_SRC}/llvm" -B "${LLVM_BUILD}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}" \
        -DLLVM_TARGETS_TO_BUILD="BPF;X86" \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
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
    ninja -C "${LLVM_BUILD}" -j"$(nproc)" clang llc lld llvm-strip llvm-objcopy
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
if [ "${DO_UPDATE}" = "1" ] || [ "${REBUILD_PAHOLE}" = "1" ]; then
    # On --update or rebuild, clear the old install so the new build is picked up.
    rm -rf "${PAHOLE_BUILD}" "${PAHOLE_INSTALL}"
fi
if [ ! -f "${PAHOLE_BIN}" ]; then
    mkdir -p "${PAHOLE_BUILD}"
    cmake -S "${PAHOLE_SRC}" -B "${PAHOLE_BUILD}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PAHOLE_INSTALL}" \
        -DCMAKE_INSTALL_RPATH="${PAHOLE_INSTALL}/lib" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DLIB_INSTALL_DIR=lib \
        -DLIBBPF_EMBEDDED=ON \
        2>&1 | tail -5
    make -C "${PAHOLE_BUILD}" -j"$(nproc)"
    make -C "${PAHOLE_BUILD}" install
    info "pahole: $(${PAHOLE_BIN} --version)"
else
    info "pahole already built — skipping."
fi

# Verify pahole works before proceeding — a broken pahole causes silent
# kernel build failures (BTF disabled, PAHOLE_VERSION=0 warnings).
if ! "${PAHOLE_BIN}" --version >/dev/null 2>&1; then
    echo "ERROR: ${PAHOLE_BIN} failed to run. Shared library issue?"
    echo "       Try removing ${PAHOLE_BUILD} and ${PAHOLE_INSTALL} and re-running."
    exit 1
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

# Enable BPF, cgroups, and networking options required for veristat.
# Use scripts/config to set options idempotently — this avoids the
# "override: reassigning to symbol" warnings that occur when appending
# to .config after defconfig has already set the same symbols.
# Note: no olddefconfig here — we run it once after scripts/config below.
scripts/config \
    --enable  BPF \
    --enable  BPF_SYSCALL \
    --enable  BPF_JIT \
    --disable BPF_JIT_ALWAYS_ON \
    --enable  CGROUPS \
    --enable  CGROUP_BPF \
    --enable  NET \
    --enable  INET \
    --disable IPV6 \
    --disable NETFILTER \
    --enable  DEBUG_INFO \
    --enable  DEBUG_INFO_BTF \
    --enable  PAHOLE_HAS_SPLIT_BTF

# Re-run olddefconfig to resolve any new dependencies introduced above.
make ARCH=um PAHOLE="${PAHOLE_BIN}" olddefconfig
info "Kernel configured: $(grep "^CONFIG_BPF_SYSCALL=y" .config && echo BPF_SYSCALL enabled)"

# ------------------------------------------------------------------------------
# Build the UML kernel
# ------------------------------------------------------------------------------
step "6/7  Building UML kernel"

# Check if UML binary already exists, unless rebuilding or updating
UML_BINARY=""
for candidate in linux vmlinux; do
    if [ -x "${LINUX_DIR}/${candidate}" ]; then
        UML_BINARY="${LINUX_DIR}/${candidate}"
        break
    fi
done

if [ -z "${UML_BINARY}" ] || [ "${REBUILD_KERNEL}" = "1" ] || [ "${DO_UPDATE}" = "1" ]; then
    info "Building UML kernel..."
    make ARCH=um PAHOLE="${PAHOLE_BIN}" -j"$(nproc)"
    
    # Re-detect UML binary after build
    UML_BINARY=""
    for candidate in linux vmlinux; do
        if [ -x "${LINUX_DIR}/${candidate}" ]; then
            UML_BINARY="${LINUX_DIR}/${candidate}"
            break
        fi
    done
else
    info "UML kernel already built — skipping. (Use --rebuild-kernel to rebuild.)"
fi

[ -n "${UML_BINARY}" ] || { echo "UML kernel binary not found after build"; exit 1; }
info "UML kernel: ${UML_BINARY} ($(ls -lh "${UML_BINARY}" | awk '{print $5}'))"

# ------------------------------------------------------------------------------
# Build veristat and BPF selftests from the bpf-next tree.
#
# The selftests Makefile requires three things we must provide explicitly:
#   CLANG       — our freshly built clang (for compiling .bpf.o files)
#   BPFTOOL     — bpftool binary (used to generate vmlinux.h and skeletons)
#   VMLINUX_BTF — the UML kernel binary (contains BTF, used by bpftool)
#
# bpftool is built first from tools/bpf/bpftool/ in the same tree.
# ARCH=x86_64 is required because selftests are host userspace binaries,
# not UML guest code.
# ------------------------------------------------------------------------------
step "7/7  Building bpftool, veristat and BPF selftests"

mkdir -p "${SELFTESTS_OUTPUT}"

# Export CLANG, LLC, and LLVM_CONFIG so that all sub-makes (including the
# feature-detection sub-make invoked by Makefile.feature) inherit them.
# Passing them only on the top-level make command line is not sufficient
# because Makefile.feature spawns a separate $(MAKE) subprocess for each
# feature test, and command-line overrides are not propagated to sub-makes
# unless they are also in the environment.
export CLANG="${CLANG}"
export LLC="${LLC}"
export LLVM_CONFIG="${LLVM_INSTALL}/bin/llvm-config"
export LD="${LLVM_INSTALL}/bin/ld.lld"

# --- 7a: build bpftool from the same tree ---
BPFTOOL_OUTPUT="${WORKDIR}/bpftool-output"
BPFTOOL_BIN="${BPFTOOL_OUTPUT}/bpftool"
mkdir -p "${BPFTOOL_OUTPUT}"

if [ ! -x "${BPFTOOL_BIN}" ] || [ "${DO_UPDATE}" = "1" ] || [ "${REBUILD_BPFTOOL}" = "1" ]; then
    info "Building bpftool from ${LINUX_DIR}/tools/bpf/bpftool/..."
    # The bpftool Makefile's default target is 'all', which produces
    # $(OUTPUT)bpftool.  We pass:
    #   OUTPUT      — directory where the binary (and intermediate objects) land
    #   CLANG       — our freshly built clang (for clang-bpf-co-re feature test)
    #   LLVM_CONFIG — our freshly built llvm-config (enables LLVM JIT disasm)
    make -C "${LINUX_DIR}/tools/bpf/bpftool" \
        OUTPUT="${BPFTOOL_OUTPUT}/" \
        CLANG="${CLANG}" \
        LLVM_CONFIG="${LLVM_INSTALL}/bin/llvm-config" \
        -j"$(nproc)" \
        all
else
    info "bpftool already built — skipping. (Use --update to rebuild.)"
fi

[ -x "${BPFTOOL_BIN}" ] || { echo "bpftool build failed"; exit 1; }
info "bpftool: ${BPFTOOL_BIN}"

# --- 7b: build everything in the selftests directory ---
# Running plain 'make' (no explicit target) builds all test binaries,
# all BPF programs under progs/ (.bpf.o files), and all skeletons.
# We pass:
#   BPFTOOL      — our freshly built bpftool (for vmlinux.h + skeleton gen)
#   VMLINUX_BTF  — the UML kernel binary (contains BTF for vmlinux.h)
#   CLANG / LLC  — our freshly built clang/llc
VERISTAT_BIN="${SELFTESTS_OUTPUT}/veristat"

if [ ! -x "${VERISTAT_BIN}" ] || [ "${DO_UPDATE}" = "1" ] || [ "${REBUILD_SELFTESTS}" = "1" ]; then
    info "Building all BPF selftests (veristat, test_progs, .bpf.o progs)..."
    # -k: keep going on errors so that the handful of UML-incompatible progs
    # (e.g. bpf_iter_ipv6_route which needs CONFIG_IPV6, bpf_iter_tasks which
    # uses x86 pt_regs->ip absent in UML, bpf_iter_task_stack / bpf_iter_task_btf
    # which need CONFIG_PERF_EVENTS unavailable on UML) do not abort the entire
    # build.  All other 200+ progs build successfully.
    make -C "${SELFTESTS_DIR}" \
        OUTPUT="${SELFTESTS_OUTPUT}/" \
        CLANG="${CLANG}" \
        LLC="${LLC}" \
        LD="${LLVM_INSTALL}/bin/ld.lld" \
        BPFTOOL="${BPFTOOL_BIN}" \
        VMLINUX_BTF="${UML_BINARY}" \
        ARCH=x86_64 \
        -j"$(nproc)" \
        -k 2>&1 || true
else
    info "Selftests already built — skipping. (Use --update to rebuild.)"
fi

[ -x "${VERISTAT_BIN}" ] || { echo "veristat build failed"; exit 1; }
info "veristat: ${VERISTAT_BIN}"

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
# Pick a representative .bpf.o to show in the example
EXAMPLE_BPF=$(find "${SELFTESTS_OUTPUT}" -maxdepth 1 -name "verifier_*.bpf.o" 2>/dev/null | head -1)
[ -z "${EXAMPLE_BPF}" ] && EXAMPLE_BPF=$(find "${SELFTESTS_OUTPUT}" -maxdepth 1 -name "*.bpf.o" 2>/dev/null | head -1)
[ -z "${EXAMPLE_BPF}" ] && EXAMPLE_BPF="${SELFTESTS_OUTPUT}/<prog>.bpf.o"

info "Run uml-veristat to verify BPF programs:"
info "  # Verify a single selftest program:"
info "  uml-veristat ${EXAMPLE_BPF}"
info ""
info "  # Verify all selftest .bpf.o files at once:"
info "  uml-veristat ${SELFTESTS_OUTPUT}/*.bpf.o"
info ""
info "  # Show verifier log on failure (log level 1 or 2):"
info "  uml-veristat -l 1 ${EXAMPLE_BPF}"
info ""
info "  # Compare two versions of a program:"
info "  uml-veristat -C old.bpf.o new.bpf.o"

# ------------------------------------------------------------------------------
# Optional: assemble distributable package (--package)
# ------------------------------------------------------------------------------
if [ "${DO_PACKAGE}" = "1" ]; then
    step "Packaging uml-veristat"

    HOST_ARCH="$(uname -m)"
    PKG_NAME="uml-veristat-${KERNEL_COMMIT}-${HOST_ARCH}"
    PKG_DIR="${WORKDIR}/${PKG_NAME}"
    PKG_TARBALL="${SCRIPT_DIR}/${PKG_NAME}.tar.gz"

    info "Assembling package: ${PKG_NAME}"
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}"

    # --- Core binaries ---
    cp "${UML_BINARY}"         "${PKG_DIR}/linux"
    cp "${VERISTAT_BIN}"       "${PKG_DIR}/veristat"
    chmod +x "${PKG_DIR}/linux" "${PKG_DIR}/veristat"

    # --- Wrapper script ---
    cp "${SCRIPT_DIR}/uml-veristat" "${PKG_DIR}/uml-veristat"
    chmod +x "${PKG_DIR}/uml-veristat"

    # --- Kernel config used for this build ---
    cp "${LINUX_DIR}/.config" "${PKG_DIR}/kernel.config"

    # --- Full provenance record ---
    KERNEL_COMMIT_FULL=$(git -C "${LINUX_DIR}" rev-parse HEAD)
    LLVM_COMMIT_FULL=$(git -C "${LLVM_SRC}" rev-parse HEAD)
    cat > "${PKG_DIR}/version.txt" <<VEOF
Built:        $(date -u +"%Y-%m-%d %H:%M UTC")
Host arch:    ${HOST_ARCH}
bpf-next:     ${KERNEL_COMMIT_FULL}
bpf-next tag: ${KERNEL_VERSION}
LLVM:         ${LLVM_COMMIT_FULL}
pahole:       ${PAHOLE_TAG}
VEOF

    # --- Package README ---
    cat > "${PKG_DIR}/README" <<'REOF'
uml-veristat — portable BPF verifier tool
==========================================

This package contains a self-contained uml-veristat installation.
It runs the BPF verifier from a specific bpf-next kernel commit
inside User-Mode Linux (UML), with no host kernel dependency.

Contents
--------
  uml-veristat   Wrapper script — the only file you need to run
  linux          UML kernel binary (bpf-next, BPF enabled)
  veristat       veristat binary (built from the same bpf-next tree)
  kernel.config  Exact kernel config used for this build
  version.txt    Full provenance: git hashes, build date, host arch
  sha256sums     Integrity manifest for all included files

Usage
-----
  # Verify a BPF object file:
  ./uml-veristat prog.bpf.o

  # Pass any veristat flags verbatim:
  ./uml-veristat -l 2 prog.bpf.o
  ./uml-veristat -C old.bpf.o new.bpf.o

  # Use a custom kernel or veristat binary:
  UML_KERNEL=/path/to/linux ./uml-veristat prog.bpf.o
  VERISTAT=/path/to/veristat ./uml-veristat prog.bpf.o

The wrapper script looks for linux and veristat in the same directory
as itself first, then falls back to ~/.local/share/uml-veristat/.

See version.txt for the exact bpf-next commit this was built from.
To rebuild from source: https://github.com/mykola-lysenko/bpf-uml-selftests
REOF

    # --- SHA-256 integrity manifest ---
    (cd "${PKG_DIR}" && sha256sum linux veristat uml-veristat kernel.config > sha256sums)

    # --- Create tarball ---
    tar -czf "${PKG_TARBALL}" -C "${WORKDIR}" "${PKG_NAME}"
    PKG_SIZE=$(ls -lh "${PKG_TARBALL}" | awk '{print $5}')

    info ""
    info "Package created: ${PKG_TARBALL} (${PKG_SIZE})"
    info "Contents:"
    tar -tzf "${PKG_TARBALL}" | sed 's/^/  /'
fi
