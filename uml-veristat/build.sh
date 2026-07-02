#!/bin/bash
# ==============================================================================
# build.sh — one-time setup for uml-veristat
# ==============================================================================
#
# Builds four artifacts from source and installs them to
# ~/.local/share/uml-veristat/:
#
#   linux           — UML kernel binary (bpf-next master, with BPF enabled)
#   veristat        — veristat binary (built from the same bpf-next tree)
#   bpf_test*.ko    — BPF selftest modules (auto-loaded by uml-veristat via UML_MODULES)
#   selftests/      — BPF selftest .bpf.o files (ready inputs for uml-veristat)
#
# Also builds LLVM/Clang (either from source or as a pre-built nightly
# download) and pahole from source, since they are needed to build the
# kernel and the BPF selftests tools.
#
# Usage:
#   ./build.sh [--update] [--package]
#
#   --update        Re-fetch bpf-next and LLVM to latest tip and rebuild.
#                  Without this flag, existing builds are reused (idempotent).
#
#   --llvm-source   Build LLVM/Clang from source instead of downloading a
#                  pre-built release.  Requires GCC 12+ or a previous clang
#                  install for self-hosting.  Takes ~25-45 min vs ~5 min.
#
#   --package  After building, assemble a self-contained distributable
#              package tarball: uml-veristat-<kernel-commit>-<arch>.tar.gz
#              Contains: uml-veristat wrapper, linux binary, veristat binary,
#              kernel .config, version.txt (full provenance), sha256sums, README.
#
# Requirements:
#   ~5 GB free disk space (~35 GB with --llvm-source),
#   8+ CPU cores recommended, sudo for package install unless running as root.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configurable source versions
# ------------------------------------------------------------------------------
LLVM_REPO="${LLVM_REPO:-https://github.com/llvm/llvm-project.git}"
LLVM_BRANCH="${LLVM_BRANCH:-main}"                   # LLVM 23 development tip

PAHOLE_REPO="${PAHOLE_REPO:-https://github.com/acmel/dwarves.git}"
PAHOLE_TAG="${PAHOLE_TAG:-v1.31}"

KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-master}"

# ------------------------------------------------------------------------------
# Directory layout
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${UML_VERISTAT_WORKDIR:-${SCRIPT_DIR}/.build}"

LLVM_SRC="${WORKDIR}/llvm-project"
LLVM_BUILD="${WORKDIR}/llvm-build"
LLVM_INSTALL="${LLVM_INSTALL:-${WORKDIR}/llvm-install}"
PAHOLE_SRC="${WORKDIR}/dwarves"
PAHOLE_BUILD="${WORKDIR}/pahole-build"
PAHOLE_INSTALL="${WORKDIR}/pahole-install"
LINUX_DIR="${WORKDIR}/bpf-next"
SELFTESTS_DIR="${LINUX_DIR}/tools/testing/selftests/bpf"

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

clang_works() {
    [ -x "${CLANG}" ] && "${CLANG}" --version >/dev/null 2>&1
}

clang_version_line() {
    "${CLANG}" --version | head -1
}

print_clang_failure() {
    if [ -e "${CLANG}" ]; then
        "${CLANG}" --version 2>&1 | sed 's/^/  /' | head -5 >&2 || true
    else
        echo "  ${CLANG}: not found" >&2
    fi
}

version_ge() {
    python3 - "$1" "$2" <<'PY'
import sys

def parts(v):
    out = []
    for p in v.split("."):
        if not p.isdigit():
            break
        out.append(int(p))
    return out

print(int(parts(sys.argv[1]) >= parts(sys.argv[2])))
PY
}

github_api_get() {
    local url="$1"
    local -a curl_args=(
        -fsSL
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        -H "User-Agent: uml-veristat-build"
    )

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    elif [ -n "${GH_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${GH_TOKEN}")
    fi

    curl "${curl_args[@]}" "${url}"
}

# ------------------------------------------------------------------------------
# Parse flags
# ------------------------------------------------------------------------------
DO_UPDATE=0
DO_PACKAGE=0
LLVM_NIGHTLY=1
APPLY_PATCHES=1
SKIP_PATCHES_RAW=""
INSTALL_SUFFIX=""
REBUILD_LLVM=0
REBUILD_PAHOLE=0
REBUILD_KERNEL=0
REBUILD_BPFTOOL=0
REBUILD_SELFTESTS=0
REBUILD_TESTMOD=0
REUSE_LLVM=0

for arg in "$@"; do
    case "${arg}" in
        --update)       DO_UPDATE=1 ;;
        --package)      DO_PACKAGE=1 ;;
        --clean)        APPLY_PATCHES=0 ;;
        --skip-patches=*) SKIP_PATCHES_RAW="${arg#*=}" ;;
        --install-suffix=*) INSTALL_SUFFIX="${arg#*=}" ;;
        --llvm-source)  LLVM_NIGHTLY=0 ;;
        --reuse-llvm)   REUSE_LLVM=1 ;;
        --rebuild-llvm)      REBUILD_LLVM=1 ;;
        --rebuild-pahole)    REBUILD_PAHOLE=1 ;;
        --rebuild-kernel)    REBUILD_KERNEL=1 ;;
        --rebuild-bpftool)   REBUILD_BPFTOOL=1 ;;
        --rebuild-selftests) REBUILD_SELFTESTS=1 ;;
        --rebuild-testmod)   REBUILD_TESTMOD=1 ;;
        -h|--help)
            echo "Usage: ./build.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --update             Pull latest bpf-next and LLVM, then rebuild."
            echo "  --clean              Build against clean upstream bpf-next with no local patch stack."
            echo "  --skip-patches=LIST  Comma-separated patch prefixes to skip (e.g. 0005,0008)."
            echo "  --install-suffix=SFX Install into ~/.local/share/uml-veristat-SFX."
            echo "  --llvm-source        Build LLVM from source instead of downloading pre-built release."
            echo "  --reuse-llvm         Keep existing LLVM/Clang even when --update is used."
            echo "  --package            After building, create a distributable tarball."
            echo ""
            echo "Per-stage rebuild options (skips checking if already built):"
            echo "  --rebuild-llvm       Rebuild LLVM/Clang"
            echo "  --rebuild-pahole     Rebuild pahole"
            echo "  --rebuild-kernel     Rebuild UML kernel"
            echo "  --rebuild-bpftool    Rebuild bpftool"
            echo "  --rebuild-selftests  Rebuild veristat and BPF selftests"
            echo "  --rebuild-testmod    Rebuild BPF selftest modules"
            echo ""
            echo "Environment:"
            echo "  LLVM_INSTALL=PATH   Use an existing LLVM install prefix (default: .build/llvm-install)."
            exit 0 ;;
        *) echo "Unknown argument: ${arg}"; exit 1 ;;
    esac
done
if [ "${REUSE_LLVM}" = "1" ] && [ "${REBUILD_LLVM}" = "1" ]; then
    echo "ERROR: --reuse-llvm and --rebuild-llvm cannot be combined."
    exit 1
fi

BUILD_FLAVOR="patched"
MODE_SUFFIX=""
if [ "${APPLY_PATCHES}" = "0" ]; then
    BUILD_FLAVOR="clean"
    MODE_SUFFIX="-clean"
fi

IFS=',' read -r -a SKIP_PATCHES <<< "${SKIP_PATCHES_RAW}"
if [ "${#SKIP_PATCHES[@]}" -gt 0 ] && [ -n "${SKIP_PATCHES_RAW}" ]; then
    APPLY_PATCHES=1
    BUILD_FLAVOR="patched-minus"
    if [ -z "${MODE_SUFFIX}" ]; then
        MODE_SUFFIX="-skip-$(printf '%s_' "${SKIP_PATCHES[@]}" | sed 's/_$//')"
    fi
fi
if [ -n "${INSTALL_SUFFIX}" ]; then
    MODE_SUFFIX="-${INSTALL_SUFFIX}"
fi

INSTALL_DIR="${HOME}/.local/share/uml-veristat${MODE_SUFFIX}"
SELFTESTS_OUTPUT="${WORKDIR}/selftests-output${MODE_SUFFIX}"
BPFTOOL_OUTPUT="${WORKDIR}/bpftool-output${MODE_SUFFIX}"
KERNEL_BUILT_THIS_RUN=0
KERNEL_TREE_CHANGED=0
AUTOLOAD_TEST_KMODS=(
    bpf_testmod
    bpf_test_modorder_x
    bpf_test_modorder_y
)
TESTMOD_PACKAGE_SRCS=()

mkdir -p "${WORKDIR}" "${INSTALL_DIR}"
info "Build flavor: ${BUILD_FLAVOR}"
if [ "${#SKIP_PATCHES[@]}" -gt 0 ] && [ -n "${SKIP_PATCHES_RAW}" ]; then
    info "Skipping patches: ${SKIP_PATCHES_RAW}"
fi

write_version_manifest() {
    local testmod_status="${1:-unknown}"
    cat > "${INSTALL_DIR}/version.txt" <<EOF
Built: $(date -u +"%Y-%m-%d %H:%M UTC")
mode: ${BUILD_FLAVOR}
skipped_patches: ${SKIP_PATCHES_RAW}
build_distro: ${PRETTY_NAME:-${OS_ID:-unknown}}
bpf-next: ${KERNEL_COMMIT} (${KERNEL_VERSION})
LLVM: ${LLVM_COMMIT}
pahole: ${PAHOLE_TAG}
bpf_test_modules: ${testmod_status}
EOF
}

install_core_artifacts() {
    info "Installing core artifacts to ${INSTALL_DIR}/"
    cp "${UML_BINARY}"       "${INSTALL_DIR}/linux"
    cp "${VERISTAT_BIN}"     "${INSTALL_DIR}/veristat"
    chmod +x "${INSTALL_DIR}/linux" "${INSTALL_DIR}/veristat"
    ln -sfn "${SELFTESTS_OUTPUT}" "${INSTALL_DIR}/selftests"
    write_version_manifest "${1:-pending}"
}

autoload_test_kmod_files() {
    local module
    local files=()

    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        files+=("${module}.ko")
    done
    echo "${files[*]}"
}

all_test_kmods_in_tree() {
    local module

    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        [ -f "${SELFTESTS_DIR}/test_kmods/${module}.ko" ] || return 1
    done
    return 0
}

all_test_kmods_installed() {
    local module

    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        [ -f "${INSTALL_DIR}/${module}.ko" ] || return 1
    done
    return 0
}

remove_test_kmods_from_tree() {
    local module

    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        rm -f "${SELFTESTS_DIR}/test_kmods/${module}.ko"
    done
}

remove_installed_test_kmods() {
    local module

    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        rm -f "${INSTALL_DIR}/${module}.ko"
    done
}

finalize_testmod_install() {
    local testmod_status
    local module src installed

    if [ "${TESTMOD_AVAILABLE}" = "1" ]; then
        TESTMOD_PACKAGE_SRCS=()
        for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
            src="${SELFTESTS_DIR}/test_kmods/${module}.ko"
            cp "${src}" "${INSTALL_DIR}/${module}.ko"
            TESTMOD_PACKAGE_SRCS+=("${src}")
        done
        testmod_status="available: $(autoload_test_kmod_files)"
    elif [ "${KEEP_INSTALLED_TESTMOD}" = "1" ] && all_test_kmods_installed; then
        TESTMOD_PACKAGE_SRCS=()
        for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
            installed="${INSTALL_DIR}/${module}.ko"
            TESTMOD_PACKAGE_SRCS+=("${installed}")
        done
        testmod_status="reused-installed: $(autoload_test_kmod_files)"
    else
        remove_installed_test_kmods
        TESTMOD_PACKAGE_SRCS=()
        testmod_status="unavailable"
    fi

    write_version_manifest "${testmod_status}"
}

# ------------------------------------------------------------------------------
# Honor an outbound HTTP(S) proxy for every network step
# ------------------------------------------------------------------------------
# All fetches in this script (git clone/fetch, curl, wget, cmake downloads) run
# through the standard proxy environment variables. libcurl ignores the
# uppercase HTTP_PROXY by design and some tools only read the lowercase names,
# so mirror whatever the caller exported (either case) into both cases. This
# lets `HTTP_PROXY=... HTTPS_PROXY=... ./build.sh` just work, e.g. behind
# fwdproxy.
normalize_proxy_var() {
    local lower="$1" upper="$2" val=""
    val="${!lower:-${!upper:-}}"
    [ -n "${val}" ] || return 0
    export "${lower}=${val}" "${upper}=${val}"
}
normalize_proxy_var http_proxy  HTTP_PROXY
normalize_proxy_var https_proxy HTTPS_PROXY
normalize_proxy_var all_proxy   ALL_PROXY
normalize_proxy_var no_proxy    NO_PROXY

# On managed hosts the curl proxy environment (e.g. HTTPS_PROXY=fwdproxy:8082)
# can point at a different port than git's configured proxy (fwdproxy:8080), so
# curl downloads fail with "Proxy CONNECT aborted" even though `git fetch`
# succeeds. git's configured proxy is the authoritative egress path here, so
# adopt it for curl/wget too. Override with FORCE_ENV_PROXY=1 to keep the env.
if [ "${FORCE_ENV_PROXY:-0}" != "1" ]; then
    git_proxy="$(git config --get https.proxy 2>/dev/null || true)"
    [ -n "${git_proxy}" ] || git_proxy="$(git config --get http.proxy 2>/dev/null || true)"
    if [ -n "${git_proxy}" ] && [ "${git_proxy}" != "${https_proxy:-}" ]; then
        info "Aligning curl/wget proxy with git's configured proxy (${git_proxy})."
        export https_proxy="${git_proxy}" HTTPS_PROXY="${git_proxy}"
        export http_proxy="${git_proxy}"  HTTP_PROXY="${git_proxy}"
    fi
fi

if [ -n "${https_proxy:-}" ] || [ -n "${http_proxy:-}" ]; then
    info "Using proxy: https_proxy=${https_proxy:-<unset>} http_proxy=${http_proxy:-<unset>}"
fi

# Run a command under sudo while forwarding the proxy variables. Plain `sudo`
# resets the environment, which would otherwise break first-run package installs
# behind a proxy. Passing the values to `env` works regardless of the sudoers
# env_keep policy.
sudo_env() {
    local -a proxy_env=()

    [ -n "${http_proxy:-}" ] && proxy_env+=(http_proxy="${http_proxy}" HTTP_PROXY="${http_proxy}")
    [ -n "${https_proxy:-}" ] && proxy_env+=(https_proxy="${https_proxy}" HTTPS_PROXY="${https_proxy}")
    [ -n "${all_proxy:-}" ] && proxy_env+=(all_proxy="${all_proxy}" ALL_PROXY="${all_proxy}")
    [ -n "${no_proxy:-}" ] && proxy_env+=(no_proxy="${no_proxy}" NO_PROXY="${no_proxy}")

    if [ "$(id -u)" -eq 0 ]; then
        env "${proxy_env[@]}" "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is required to install build dependencies when not running as root." >&2
        exit 1
    fi

    sudo env "${proxy_env[@]}" "$@"
}

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
elif _is_like fedora || _is_like rhel || _is_like centos ||
     _is_like rocky || _is_like almalinux; then   DISTRO_FAMILY="fedora"
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
    sudo_env apt-get update -qq
    sudo_env apt-get install -y \
        build-essential git bc flex bison kmod openssl \
        libelf-dev libssl-dev libdw-dev \
        pkg-config cmake ninja-build python3 \
        libcap-dev curl wget rsync zlib1g-dev ;;
  fedora)
    PKG_MGR="dnf"; command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
    if [ "${PKG_MGR}" = "dnf" ] &&
       (_is_like rhel || _is_like centos || _is_like rocky || _is_like almalinux); then
        sudo_env "${PKG_MGR}" install -y dnf-plugins-core || true
        sudo_env "${PKG_MGR}" config-manager --set-enabled crb >/dev/null 2>&1 ||
            sudo_env "${PKG_MGR}" config-manager --set-enabled powertools >/dev/null 2>&1 ||
            true
    fi
    # EL9+ containers preinstall curl-minimal, which conflicts with the full
    # curl package; --allowerasing lets dnf swap it out (yum lacks the flag).
    DNF_FLAGS=""
    [ "${PKG_MGR}" = "dnf" ] && DNF_FLAGS="--allowerasing"
    sudo_env "${PKG_MGR}" install -y ${DNF_FLAGS} \
        gcc gcc-c++ make git bc flex bison diffutils kmod openssl xz \
        elfutils-libelf-devel openssl-devel elfutils-devel \
        pkgconf-pkg-config cmake ninja-build python3 \
        libcap-devel curl wget rsync zlib-devel ;;
  suse)
    sudo_env zypper install -y \
        gcc gcc-c++ make git bc flex bison diffutils kmod openssl xz \
        libelf-devel libopenssl-devel libdw-devel \
        pkg-config cmake ninja python3 \
        libcap-devel curl wget rsync zlib-devel ;;
  arch)
    sudo_env pacman -Sy --noconfirm archlinux-keyring || true
    sudo_env pacman -Sy --noconfirm \
        base-devel git bc flex bison kmod \
        libelf openssl elfutils \
        pkgconf cmake ninja python \
        libcap curl wget rsync zlib ;;
esac

# ------------------------------------------------------------------------------
# Build or download LLVM/Clang
# ------------------------------------------------------------------------------
if [ "${LLVM_NIGHTLY}" = "1" ]; then
    step "2/7  Downloading pre-built LLVM release"

    if [ "${REUSE_LLVM}" = "1" ]; then
        if ! clang_works; then
            echo "ERROR: --reuse-llvm was requested, but the installed LLVM/Clang is not usable:" >&2
            print_clang_failure
            echo "Recovery options:" >&2
            echo "  - remove ${LLVM_INSTALL} and re-run without --reuse-llvm to download a compatible prebuilt" >&2
            echo "  - pin a compatible release: LLVM_RELEASE_TAG=llvmorg-<ver> ./build.sh --update --rebuild-llvm" >&2
            echo "  - build LLVM from source: ./build.sh --llvm-source --rebuild-llvm" >&2
            exit 1
        fi
        info "Reusing existing LLVM/Clang due to --reuse-llvm."
        info "Clang: $(clang_version_line)"
        LLVM_COMMIT="reused-$(clang_version_line)"
    elif clang_works && [ "${REBUILD_LLVM}" != "1" ] && [ "${DO_UPDATE}" != "1" ]; then
        info "LLVM already installed — skipping. (Use --rebuild-llvm to re-download.)"
        LLVM_COMMIT="nightly-$(clang_version_line | grep -oP '\d+\.\d+\.\d+' | head -1)"
    else
        # Fetch the latest release tag and tarball URL from the GitHub API.
        # In CI, use GITHUB_TOKEN when available to avoid anonymous API limits.
        LLVM_RELEASE_JSON=""
        # LLVM_RELEASE_TAG pins a specific release (e.g. llvmorg-18.1.8) instead
        # of the latest. Useful when the newest prebuilt needs a newer
        # libstdc++/glibc than this host has.
        if [ -n "${LLVM_RELEASE_TAG:-}" ]; then
            LLVM_RELEASE_API="https://api.github.com/repos/llvm/llvm-project/releases/tags/${LLVM_RELEASE_TAG}"
        else
            LLVM_RELEASE_API="https://api.github.com/repos/llvm/llvm-project/releases/latest"
        fi
        if ! LLVM_RELEASE_JSON=$(github_api_get "${LLVM_RELEASE_API}"); then
            warn "Could not fetch LLVM release info from ${LLVM_RELEASE_API}; retrying with /releases?per_page=1"
            LLVM_RELEASE_LIST_JSON=""
            if LLVM_RELEASE_LIST_JSON=$(github_api_get "https://api.github.com/repos/llvm/llvm-project/releases?per_page=1"); then
                LLVM_RELEASE_JSON=$(printf '%s' "${LLVM_RELEASE_LIST_JSON}" | python3 -c \
                    "import sys,json; releases=json.load(sys.stdin); print(json.dumps(releases[0]))")
            fi
        fi
        if [ -z "${LLVM_RELEASE_JSON}" ]; then
            if clang_works && [ "${REBUILD_LLVM}" != "1" ]; then
                warn "Could not fetch LLVM release info; reusing installed LLVM/Clang."
                warn "Use --rebuild-llvm to make LLVM refresh failure fatal."
                info "Clang: $(clang_version_line)"
                LLVM_COMMIT="reused-$(clang_version_line)"
            else
                echo "ERROR: Could not fetch LLVM release info from GitHub API"
                echo "Hint: set GITHUB_TOKEN or GH_TOKEN to avoid GitHub API rate limits"
                exit 1
            fi
        fi
        if [ -n "${LLVM_RELEASE_JSON}" ]; then
            LLVM_TAG=$(echo "${LLVM_RELEASE_JSON}" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['tag_name'])")
            LLVM_VERSION=$(echo "${LLVM_TAG}" | sed 's/llvmorg-//')
            # Accept both the new 'LLVM-<ver>-Linux-X64.tar.xz' naming and the
            # older official 'clang+llvm-<ver>-x86_64-linux-gnu-ubuntu-<os>'
            # naming. When a release ships several, prefer the oldest ubuntu
            # build: it links against the oldest libstdc++/glibc and therefore
            # runs on the widest range of hosts (newer 'Linux-X64'-only builds
            # require GLIBCXX_3.4.30 / GCC 12+).
            LLVM_TARBALL_URL=$(echo "${LLVM_RELEASE_JSON}" | python3 -c '
import sys, json, re
r = json.load(sys.stdin)
assets = [a for a in r.get("assets", [])
          if a["name"].endswith(".tar.xz")
          and ("Linux-X64" in a["name"] or "x86_64-linux-gnu" in a["name"])]
def osver(a):
    m = re.search(r"ubuntu-(\d+)\.(\d+)", a["name"])
    return (int(m.group(1)), int(m.group(2))) if m else (999, 0)
assets.sort(key=osver)
print(assets[0]["browser_download_url"] if assets else "")')

            if [ -z "${LLVM_TARBALL_URL}" ]; then
                if clang_works && [ "${REBUILD_LLVM}" != "1" ]; then
                    warn "Could not find Linux-X64 tarball in LLVM release ${LLVM_TAG}; reusing installed LLVM/Clang."
                    warn "Use --rebuild-llvm to make LLVM refresh failure fatal."
                    info "Clang: $(clang_version_line)"
                    LLVM_COMMIT="reused-$(clang_version_line)"
                else
                    echo "ERROR: Could not find Linux-X64 tarball in LLVM release ${LLVM_TAG}"
                    exit 1
                fi
            fi

            if [ -n "${LLVM_TARBALL_URL}" ]; then
                LLVM_TARBALL="${WORKDIR}/$(basename "${LLVM_TARBALL_URL}")"
                info "Latest LLVM release: ${LLVM_TAG} (${LLVM_VERSION})"
                info "Tarball URL: ${LLVM_TARBALL_URL}"

                LLVM_TARBALL_READY=1
                if [ ! -f "${LLVM_TARBALL}" ]; then
                    info "Downloading LLVM tarball (~700 MB)..."
                    if ! curl -L --progress-bar -o "${LLVM_TARBALL}" "${LLVM_TARBALL_URL}"; then
                        rm -f "${LLVM_TARBALL}"
                        if clang_works && [ "${REBUILD_LLVM}" != "1" ]; then
                            LLVM_TARBALL_READY=0
                            warn "Could not download LLVM tarball; reusing installed LLVM/Clang."
                            warn "Use --rebuild-llvm to make LLVM refresh failure fatal."
                            info "Clang: $(clang_version_line)"
                            LLVM_COMMIT="reused-$(clang_version_line)"
                        else
                            echo "ERROR: Could not download LLVM tarball"
                            exit 1
                        fi
                    fi
                else
                    info "Tarball already downloaded: ${LLVM_TARBALL}"
                fi

                if [ "${LLVM_TARBALL_READY}" = "1" ]; then
                    info "Extracting LLVM tarball..."
                    # Extract to a staging dir and verify the new clang actually
                    # runs on this host BEFORE replacing the current install.
                    # Recent LLVM release binaries are built against a newer
                    # libstdc++/glibc (e.g. GLIBCXX_3.4.30 / GCC 12) than older
                    # hosts provide; replacing first would leave no working
                    # compiler at all.
                    LLVM_STAGING="${LLVM_INSTALL}.new"
                    rm -rf "${LLVM_STAGING}"
                    mkdir -p "${LLVM_STAGING}"
                    tar -xf "${LLVM_TARBALL}" -C "${LLVM_STAGING}" --strip-components=1
                    if "${LLVM_STAGING}/bin/clang" --version >/dev/null 2>&1; then
                        rm -rf "${LLVM_INSTALL}"
                        mv "${LLVM_STAGING}" "${LLVM_INSTALL}"
                        info "Clang: $(${CLANG} --version | head -1)"
                        LLVM_COMMIT="nightly-${LLVM_VERSION}"
                    else
                        llvm_run_err="$("${LLVM_STAGING}/bin/clang" --version 2>&1 | head -1)"
                        rm -rf "${LLVM_STAGING}"
                        warn "Downloaded LLVM ${LLVM_VERSION} cannot run on this host:"
                        warn "  ${llvm_run_err}"
                        warn "The prebuilt needs a newer libstdc++/glibc than this host provides."
                        if clang_works && [ "${REBUILD_LLVM}" != "1" ]; then
                            warn "Keeping the existing working LLVM/Clang install."
                            info "Clang: $(clang_version_line)"
                            LLVM_COMMIT="reused-$(clang_version_line)"
                            LLVM_TARBALL_READY=0
                        else
                            echo "ERROR: No usable LLVM/Clang for this host." >&2
                            echo "  Host max GLIBCXX: $(strings /lib64/libstdc++.so.6 2>/dev/null | grep -oE 'GLIBCXX_3\.4\.[0-9]+' | sort -V | tail -1)" >&2
                            echo "  Recovery options:" >&2
                            echo "    - pin an older, compatible release: LLVM_RELEASE_TAG=llvmorg-<ver> ./build.sh --update --rebuild-llvm" >&2
                            echo "    - build LLVM from source on this host: ./build.sh --llvm-source --rebuild-llvm" >&2
                            echo "    - install a newer toolchain (GCC 12+ / libstdc++)." >&2
                            exit 1
                        fi
                    fi
                fi
            fi
        fi
    fi
else
    step "2/7  Building LLVM/Clang (${LLVM_BRANCH} branch, BPF+X86 only)"
    info "This is the longest step — ~25 min on 8 cores, ~45 min on 4 cores."

    if [ ! -d "${LLVM_SRC}/.git" ]; then
        info "Cloning LLVM (shallow)..."
        git clone --depth=1 --branch "${LLVM_BRANCH}" "${LLVM_REPO}" "${LLVM_SRC}"
    elif [ "${DO_UPDATE}" = "1" ]; then
        info "Updating LLVM to latest ${LLVM_BRANCH}..."
        git -C "${LLVM_SRC}" fetch --depth=1 origin "${LLVM_BRANCH}"
        git -C "${LLVM_SRC}" reset --hard "origin/${LLVM_BRANCH}"
    fi

    LLVM_COMMIT=$(git -C "${LLVM_SRC}" rev-parse --short HEAD)
    info "LLVM HEAD: ${LLVM_COMMIT}"

    if ! clang_works || [ "${REBUILD_LLVM}" = "1" ] || [ "${DO_UPDATE}" = "1" ]; then
        # Use the previously built clang as the host compiler if available.
        # LLVM main requires GCC 12+; self-hosting avoids that dependency.
        LLVM_HOST_CC=()
        if clang_works; then
            info "Using previously built clang for self-hosted rebuild"
            LLVM_HOST_CC=(
                -DCMAKE_C_COMPILER="${CLANG}"
                -DCMAKE_CXX_COMPILER="${LLVM_INSTALL}/bin/clang++"
            )
            # Wipe build dir if the cached compiler differs (GCC → clang switch)
            if [ -f "${LLVM_BUILD}/CMakeCache.txt" ]; then
                CACHED_CC=$(grep "^CMAKE_C_COMPILER:" "${LLVM_BUILD}/CMakeCache.txt" | cut -d= -f2)
                if [ -n "${CACHED_CC}" ] && [ "${CACHED_CC}" != "${CLANG}" ]; then
                    info "Host compiler changed (${CACHED_CC} -> clang), wiping build dir..."
                    rm -rf "${LLVM_BUILD}"
                fi
            fi
        else
            host_cxx="${CXX:-c++}"
            host_cxx_version="$("${host_cxx}" -dumpfullversion -dumpversion 2>/dev/null | head -1 || true)"
            if "${host_cxx}" --version 2>/dev/null | head -1 | grep -Eq '(^| )g\+\+|GCC' &&
               [ "$(version_ge "${host_cxx_version:-0}" 12)" != "1" ]; then
                echo "ERROR: LLVM source build needs a working clang or GCC 12+." >&2
                echo "  Host C++ compiler: $("${host_cxx}" --version 2>/dev/null | head -1)" >&2
                echo "  Existing LLVM/Clang is not usable:" >&2
                print_clang_failure
                echo "Recovery options:" >&2
                echo "  - install GCC 12+ / newer libstdc++ and rerun with --llvm-source --rebuild-llvm" >&2
                echo "  - make a compatible clang available in ${LLVM_INSTALL}" >&2
                echo "  - pin/download a compatible LLVM prebuilt with LLVM_RELEASE_TAG=llvmorg-<ver> --rebuild-llvm" >&2
                exit 1
            fi
        fi

        if [ "${REBUILD_LLVM}" = "1" ]; then
            rm -rf "${LLVM_BUILD}"
        fi

        mkdir -p "${LLVM_BUILD}"

        cmake -S "${LLVM_SRC}/llvm" -B "${LLVM_BUILD}" \
            -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${LLVM_INSTALL}" \
            "${LLVM_HOST_CC[@]}" \
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
        info "Clang: $(clang_version_line)"
    else
        info "Clang already built — skipping. (Use --update to rebuild.)"
    fi
fi

# ------------------------------------------------------------------------------
# Build pahole from source
# ------------------------------------------------------------------------------
step "3/7  Building pahole ${PAHOLE_TAG}"
if [ ! -d "${PAHOLE_SRC}/.git" ]; then
    git clone --depth=1 --branch "${PAHOLE_TAG}" "${PAHOLE_REPO}" "${PAHOLE_SRC}"
fi
if [ "${REBUILD_PAHOLE}" = "1" ]; then
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
# Apply UML BPF compatibility patches
# ------------------------------------------------------------------------------
# Patches are stored in patches/ next to this script, in git format-patch
# format. They are applied with 'git am' after kernel checkout.
#
# We intentionally detect "already applied" by checking whether the patch
# reverses cleanly against the current tree, not by matching commit subjects.
# Patch subjects changed over time as patches were merged/squashed, and subject
# matching causes stale build trees to mis-detect partially updated patch sets.
PATCHES_DIR="${SCRIPT_DIR}/patches"
should_skip_patch() {
    local patch_name="$1"
    local skip
    for skip in "${SKIP_PATCHES[@]}"; do
        [ -n "${skip}" ] || continue
        if [[ "${patch_name}" == "${skip}"* ]]; then
            return 0
        fi
    done
    return 1
}
if [ -d "${PATCHES_DIR}" ]; then
    UPSTREAM_REF="origin/${KERNEL_BRANCH}"
    if ! git -C "${LINUX_DIR}" rev-parse --verify "${UPSTREAM_REF}" >/dev/null 2>&1; then
        UPSTREAM_REF="HEAD"
    fi

    CURRENT_HEAD=$(git -C "${LINUX_DIR}" rev-parse HEAD)
    UPSTREAM_HEAD=$(git -C "${LINUX_DIR}" rev-parse "${UPSTREAM_REF}")
    if [ "${CURRENT_HEAD}" != "${UPSTREAM_HEAD}" ] || \
       [ -n "$(git -C "${LINUX_DIR}" status --porcelain)" ]; then
        info "Resetting kernel tree to clean upstream state before applying patches..."
        git -C "${LINUX_DIR}" am --abort >/dev/null 2>&1 || true
        git -C "${LINUX_DIR}" reset --hard "${UPSTREAM_REF}"
        git -C "${LINUX_DIR}" clean -fd
        KERNEL_TREE_CHANGED=1
        KERNEL_COMMIT=$(git -C "${LINUX_DIR}" rev-parse --short HEAD)
        KERNEL_VERSION=$(make -C "${LINUX_DIR}" -s kernelversion 2>/dev/null || echo "unknown")
        info "Reset kernel tree to ${KERNEL_COMMIT}  (${KERNEL_VERSION})"
    fi

    if [ "${APPLY_PATCHES}" = "1" ]; then
        # Configure a git identity in the kernel tree if not already set
        git -C "${LINUX_DIR}" config user.email "uml-veristat@build" 2>/dev/null || true
        git -C "${LINUX_DIR}" config user.name  "uml-veristat build"  2>/dev/null || true

        for patch in "${PATCHES_DIR}"/*.patch; do
            [ -f "${patch}" ] || continue
            if should_skip_patch "${patch##*/}"; then
                info "Skipping patch by request: ${patch##*/}"
                continue
            fi
            if git -C "${LINUX_DIR}" apply --check --reverse "${patch}" >/dev/null 2>&1; then
                info "Patch already applied — skipping: ${patch##*/}"
            else
                info "Applying patch: ${patch##*/}"
                if ! git -C "${LINUX_DIR}" am --whitespace=nowarn "${patch}"; then
                    warn "Plain git am failed for ${patch##*/}; retrying with --3way"
                    git -C "${LINUX_DIR}" am --abort >/dev/null 2>&1 || true
                    git -C "${LINUX_DIR}" am --3way --whitespace=nowarn "${patch}"
                fi
                KERNEL_TREE_CHANGED=1
            fi
        done
    else
        info "Clean mode: leaving kernel tree at upstream state and skipping local patch stack."
    fi
fi

# ------------------------------------------------------------------------------
# Configure the UML kernel
# ------------------------------------------------------------------------------
step "5/7  Configuring UML kernel"

cd "${LINUX_DIR}"

if [ ! -f .config ]; then
    make ARCH=um defconfig
fi

CONFIG_ARGS=(
    --enable  BPF
    --enable  BPF_SYSCALL
    --enable  BPF_JIT
    --disable BPF_JIT_ALWAYS_ON
    --enable  CGROUPS
    --enable  CGROUP_BPF
    --enable  NET
    --enable  INET
    --enable  IPV6
    --enable  NETFILTER
    --enable  NETFILTER_INGRESS
    --enable  NET_FOU
    --enable  NF_CONNTRACK
    --enable  NF_TABLES
    --enable  NF_FLOW_TABLE
    --enable  DEBUG_INFO
    --enable  DEBUG_INFO_BTF
    --enable  PAHOLE_HAS_SPLIT_BTF
    --enable  SECURITY
    --enable  KEYS
    --enable  CRYPTO
    --enable  XFRM_INTERFACE
    --enable  FS_VERITY
    --enable  TCP_CONG_ADVANCED
    --enable  TCP_CONG_CUBIC
    --enable  TCP_CONG_DCTCP
    --enable  SMP
    --set-val NR_CPUS 8
    --enable  KALLSYMS_ALL
    --enable  XDP_SOCKETS
)
if [ "${APPLY_PATCHES}" = "1" ]; then
    CONFIG_ARGS+=(
        --enable BPF_VERIFICATION_STUBS
        --enable BPF_LSM_VERIFICATION_STUBS
    )
fi
scripts/config "${CONFIG_ARGS[@]}"

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

if [ -z "${UML_BINARY}" ] || [ "${REBUILD_KERNEL}" = "1" ] || [ "${DO_UPDATE}" = "1" ] || [ "${KERNEL_TREE_CHANGED}" = "1" ]; then
    info "Building UML kernel..."
    make ARCH=um PAHOLE="${PAHOLE_BIN}" -j"$(nproc)"
    KERNEL_BUILT_THIS_RUN=1
    
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
export LLVM_STRIP="${LLVM_INSTALL}/bin/llvm-strip"

# Prebuilt LLVM releases dynamically link ld.lld against host libraries
# (e.g. libxml2.so.2) that newer distros no longer ship, even when clang
# itself runs fine. Fall back to a system linker when the prebuilt ld.lld
# cannot execute on this host.
BUILD_LD="${LLVM_INSTALL}/bin/ld.lld"
if ! "${BUILD_LD}" --version >/dev/null 2>&1; then
    if command -v ld.lld >/dev/null 2>&1 && ld.lld --version >/dev/null 2>&1; then
        BUILD_LD="$(command -v ld.lld)"
    else
        BUILD_LD="$(command -v ld)"
    fi
    warn "Prebuilt ld.lld cannot run on this host; using system linker: ${BUILD_LD}"
fi
export LD="${BUILD_LD}"

# --- 7a: build bpftool from the same tree ---
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
        LLVM_STRIP="${LLVM_INSTALL}/bin/llvm-strip" \
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
#   TEST_KMODS=   — keep the host-arch selftests build from trying to build
#                  kernel modules; bpf_testmod.ko is built separately for UML.
VERISTAT_BIN="${SELFTESTS_OUTPUT}/veristat"

if [ ! -x "${VERISTAT_BIN}" ] || [ "${DO_UPDATE}" = "1" ] || [ "${REBUILD_SELFTESTS}" = "1" ]; then
    info "Building all BPF selftests (veristat, test_progs, .bpf.o progs)..."
    # -k: keep going on errors so that UML-incompatible or upstream-drifting
    # selftests do not abort the whole build. We still install the successfully
    # built corpus and validate it with scripts/report_coverage.py.
    SELFTESTS_MAKE_STATUS=0
    make -C "${SELFTESTS_DIR}" \
        OUTPUT="${SELFTESTS_OUTPUT}/" \
        CLANG="${CLANG}" \
        LLC="${LLC}" \
        LD="${BUILD_LD}" \
        BPFTOOL="${BPFTOOL_BIN}" \
        VMLINUX_BTF="${UML_BINARY}" \
        ARCH=x86_64 \
        TEST_KMODS= \
        -j"$(nproc)" \
        -k 2>&1 || SELFTESTS_MAKE_STATUS=$?
    if [ "${SELFTESTS_MAKE_STATUS}" -ne 0 ]; then
        warn "Selftests build completed with partial failures; continuing with the successfully built corpus."
        warn "Use scripts/report_coverage.py to validate the installed standalone corpus."
    fi
else
    info "Selftests already built — skipping. (Use --update to rebuild.)"
fi

[ -x "${VERISTAT_BIN}" ] || { echo "veristat build failed"; exit 1; }
info "veristat: ${VERISTAT_BIN}"

BPF_OBJ_COUNT=$(find "${SELFTESTS_OUTPUT}" -name "*.bpf.o" 2>/dev/null | wc -l)
info "BPF object files built: ${BPF_OBJ_COUNT} files in ${SELFTESTS_OUTPUT}/"

# --- 7c: build BPF selftest modules for the UML kernel ---
# bpf_testmod.ko provides struct_ops types and kfuncs that many BPF selftest
# programs depend on. bpf_test_modorder_x/y.ko provide module-kfunc BTF for
# kfunc_module_order.bpf.o. These are built as external modules against the UML
# kernel tree (ARCH=um) so they run inside the UML guest.
#
# Keep this list narrow: other test_kmods such as bpf_test_rqspinlock.ko require
# CONFIG_PERF_EVENTS, which is not available on UML.
TESTMOD_AVAILABLE=0
KEEP_INSTALLED_TESTMOD=0
TESTMOD_BUILD_FAILED=0

install_core_artifacts "pending"

TESTMOD_BUILD_NEEDED=0
if [ "${REBUILD_TESTMOD}" = "1" ] || \
   [ "${REBUILD_KERNEL}" = "1" ] || \
   [ "${DO_UPDATE}" = "1" ] || \
   [ "${KERNEL_BUILT_THIS_RUN}" = "1" ]; then
    TESTMOD_BUILD_NEEDED=1
elif ! all_test_kmods_in_tree; then
    if all_test_kmods_installed; then
        KEEP_INSTALLED_TESTMOD=1
        info "BPF selftest modules are missing from the build tree; keeping the installed copies."
    else
        TESTMOD_BUILD_NEEDED=1
    fi
fi

if [ "${TESTMOD_BUILD_NEEDED}" = "1" ]; then
    info "Building BPF selftest modules for UML: $(autoload_test_kmod_files)"
    remove_test_kmods_from_tree
    # Ensure Module.symvers is up to date before building the module.
    # A quick incremental 'make ARCH=um' (no sources changed) regenerates
    # Module.symvers in ~30 seconds without recompiling anything.
    make -C "${LINUX_DIR}" ARCH=um PAHOLE="${PAHOLE_BIN}" -j"$(nproc)"
    # Build only the module-backed veristat prerequisites, not the full
    # test_kmods set.
    TESTMOD_BUILD_STATUS=0
    TESTMOD_TARGETS=()
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        TESTMOD_TARGETS+=("${module}.ko")
    done
    make -C "${LINUX_DIR}" ARCH=um PAHOLE="${PAHOLE_BIN}" \
        M="${SELFTESTS_DIR}/test_kmods" "${TESTMOD_TARGETS[@]}" 2>&1 || TESTMOD_BUILD_STATUS=$?
    if [ "${TESTMOD_BUILD_STATUS}" -ne 0 ]; then
        TESTMOD_BUILD_FAILED=1
        remove_test_kmods_from_tree
        if [ "${APPLY_PATCHES}" = "0" ]; then
            warn "BPF selftest modules did not build in clean mode; continuing without module-backed selftests."
        elif [ "${REBUILD_TESTMOD}" = "0" ] && [ "${KERNEL_BUILT_THIS_RUN}" = "0" ] && all_test_kmods_installed; then
            KEEP_INSTALLED_TESTMOD=1
            warn "BPF selftest module rebuild failed, but the UML kernel was not rebuilt; keeping installed modules."
        else
            warn "BPF selftest module build failed after core artifacts were installed."
        fi
    fi
else
    info "BPF selftest modules already available — skipping rebuild. (Use --rebuild-testmod to rebuild.)"
fi

if all_test_kmods_in_tree; then
    TESTMOD_AVAILABLE=1
    KEEP_INSTALLED_TESTMOD=0
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        module_path="${SELFTESTS_DIR}/test_kmods/${module}.ko"
        info "${module}.ko: ${module_path} ($(ls -lh "${module_path}" | awk '{print $5}'))"
    done
elif [ "${KEEP_INSTALLED_TESTMOD}" = "1" ] && all_test_kmods_installed; then
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        info "${module}.ko: reusing installed copy at ${INSTALL_DIR}/${module}.ko"
    done
else
    warn "BPF selftest modules are not available for the ${BUILD_FLAVOR} build."
fi

# ------------------------------------------------------------------------------
# Install artifacts
# ------------------------------------------------------------------------------
finalize_testmod_install

if [ "${TESTMOD_BUILD_FAILED}" = "1" ] && [ "${APPLY_PATCHES}" = "1" ] && [ "${KEEP_INSTALLED_TESTMOD}" = "0" ]; then
    echo "BPF selftest module build failed"
    exit 1
fi

echo ""
info "Build complete!"
info ""
info "  UML kernel     : ${INSTALL_DIR}/linux"
info "  veristat       : ${INSTALL_DIR}/veristat"
if [ "${TESTMOD_AVAILABLE}" = "1" ]; then
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        info "  ${module}.ko : ${INSTALL_DIR}/${module}.ko"
    done
elif [ "${KEEP_INSTALLED_TESTMOD}" = "1" ] && all_test_kmods_installed; then
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        info "  ${module}.ko : ${INSTALL_DIR}/${module}.ko (reused)"
    done
else
    info "  BPF modules    : not available in ${BUILD_FLAVOR} build"
fi
info "  Selftests      : ${INSTALL_DIR}/selftests/ (${BPF_OBJ_COUNT} .bpf.o files)"
info "  Versions       : ${INSTALL_DIR}/version.txt"
info ""
# Pick a representative .bpf.o to show in the example
EXAMPLE_BPF=$(find "${SELFTESTS_OUTPUT}" -maxdepth 1 -name "verifier_*.bpf.o" 2>/dev/null | head -1 || true)
if [ -z "${EXAMPLE_BPF}" ]; then
    EXAMPLE_BPF=$(find "${SELFTESTS_OUTPUT}" -maxdepth 1 -name "*.bpf.o" 2>/dev/null | head -1 || true)
fi
if [ -z "${EXAMPLE_BPF}" ]; then
    EXAMPLE_BPF="${SELFTESTS_OUTPUT}/<prog>.bpf.o"
fi

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
info ""
info "  # Load BPF selftest modules before veristat (auto-detected from install dir):"
info "  uml-veristat ${SELFTESTS_OUTPUT}/*.bpf.o"
info ""
info "  # Override module paths explicitly:"
info "  UML_MODULES=\"/path/to/bpf_testmod.ko /path/to/bpf_test_modorder_x.ko /path/to/bpf_test_modorder_y.ko\" uml-veristat ${SELFTESTS_OUTPUT}/*.bpf.o"
info ""
info "  # Disable module loading:"
info "  UML_MODULES=\"\" uml-veristat ${SELFTESTS_OUTPUT}/*.bpf.o"

# ------------------------------------------------------------------------------
# Optional: assemble distributable package (--package)
# ------------------------------------------------------------------------------
if [ "${DO_PACKAGE}" = "1" ]; then
    step "Packaging uml-veristat"

    HOST_ARCH="$(uname -m)"
    PKG_NAME="uml-veristat${MODE_SUFFIX}-${KERNEL_COMMIT}-${HOST_ARCH}"
    PKG_DIR="${WORKDIR}/${PKG_NAME}"
    PKG_TARBALL="${SCRIPT_DIR}/${PKG_NAME}.tar.gz"

    info "Assembling package: ${PKG_NAME}"
    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}"

    # --- Core binaries ---
    cp "${UML_BINARY}"         "${PKG_DIR}/linux"
    cp "${VERISTAT_BIN}"       "${PKG_DIR}/veristat"
    chmod +x "${PKG_DIR}/linux" "${PKG_DIR}/veristat"
    for module_src in "${TESTMOD_PACKAGE_SRCS[@]}"; do
        [ -f "${module_src}" ] && cp "${module_src}" "${PKG_DIR}/"
    done

    # --- Wrapper script ---
    cp "${SCRIPT_DIR}/uml-veristat" "${PKG_DIR}/uml-veristat"
    chmod +x "${PKG_DIR}/uml-veristat"

    # --- Kernel config used for this build ---
    cp "${LINUX_DIR}/.config" "${PKG_DIR}/kernel.config"

    # --- Full provenance record ---
    KERNEL_COMMIT_FULL=$(git -C "${LINUX_DIR}" rev-parse HEAD)
    if [ -d "${LLVM_SRC}/.git" ]; then
        LLVM_COMMIT_FULL=$(git -C "${LLVM_SRC}" rev-parse HEAD)
    else
        LLVM_COMMIT_FULL="${LLVM_COMMIT}"  # nightly: already set to nightly-<version>
    fi
    cat > "${PKG_DIR}/version.txt" <<VEOF
Built:        $(date -u +"%Y-%m-%d %H:%M UTC")
Mode:         ${BUILD_FLAVOR}
Skipped:      ${SKIP_PATCHES_RAW}
Host arch:    ${HOST_ARCH}
Build distro: ${PRETTY_NAME:-${OS_ID:-unknown}}
bpf-next:     ${KERNEL_COMMIT_FULL}
bpf-next tag: ${KERNEL_VERSION}
LLVM:         ${LLVM_COMMIT_FULL}
pahole:       ${PAHOLE_TAG}
bpf_test_modules: $(if [ "${#TESTMOD_PACKAGE_SRCS[@]}" -gt 0 ]; then autoload_test_kmod_files; else echo unavailable; fi)
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
  uml-veristat    Wrapper script — the only file you need to run
  linux           UML kernel binary (bpf-next, BPF enabled)
  veristat        veristat binary (built from the same bpf-next tree)
  bpf_test*.ko    Optional BPF selftest modules (included when they build)
  kernel.config   Exact kernel config used for this build
  version.txt     Full provenance: git hashes, build date, host arch
  sha256sums      Integrity manifest for all included files

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
    SHA256_INPUTS=(linux veristat uml-veristat kernel.config)
    for module in "${AUTOLOAD_TEST_KMODS[@]}"; do
        if [ -f "${PKG_DIR}/${module}.ko" ]; then
            SHA256_INPUTS+=("${module}.ko")
        fi
    done
    (cd "${PKG_DIR}" && sha256sum "${SHA256_INPUTS[@]}" > sha256sums)

    # --- Create tarball ---
    tar -czf "${PKG_TARBALL}" -C "${WORKDIR}" "${PKG_NAME}"
    PKG_SIZE=$(ls -lh "${PKG_TARBALL}" | awk '{print $5}')

    info ""
    info "Package created: ${PKG_TARBALL} (${PKG_SIZE})"
    info "Contents:"
    tar -tzf "${PKG_TARBALL}" | sed 's/^/  /'
fi
