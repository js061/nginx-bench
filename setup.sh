#!/usr/bin/env bash
set -euo pipefail

# Packages needed before running install.sh:
#   gcc/g++, make   — compile nginx and wrk
#   openssl/libssl  — nginx --with-http_ssl_module, wrk TLS, cert generation
#   zlib            — nginx zlib support
#   curl            — download source tarballs
#   perl            — required by openssl build bundled inside wrk

PKGS_DEBIAN="build-essential libssl-dev zlib1g-dev curl perl"
PKGS_RPM="gcc gcc-c++ make openssl-devel zlib-devel curl perl"
PKGS_ARCH="base-devel openssl zlib curl perl"
PKGS_BREW="openssl zlib curl"

info()  { echo "==> $*"; }
ok()    { echo "  [OK]  $*"; }
fail()  { echo "  [MISSING] $*"; }

# -- Distro detection
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
        return
    fi
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop)      echo "debian" ;;
            rhel|centos|rocky|almalinux|ol)   echo "rhel"   ;;
            fedora)                            echo "fedora" ;;
            arch|manjaro|endeavouros)          echo "arch"   ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*)  echo "debian" ;;
                    *rhel*|*fedora*) echo "rhel" ;;
                    *arch*)    echo "arch"   ;;
                    *)         echo "unknown" ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

# -- Install
OS="$(detect_os)"
info "Detected OS: $OS"

case "$OS" in
    debian)
        info "Installing packages via apt-get..."
        sudo apt-get update -qq
        # shellcheck disable=SC2086
        sudo apt-get install -y $PKGS_DEBIAN
        ;;
    rhel)
        info "Installing packages via dnf/yum..."
        if command -v dnf &>/dev/null; then
            # shellcheck disable=SC2086
            sudo dnf install -y $PKGS_RPM
        else
            # shellcheck disable=SC2086
            sudo yum install -y $PKGS_RPM
        fi
        ;;
    fedora)
        info "Installing packages via dnf..."
        # shellcheck disable=SC2086
        sudo dnf install -y $PKGS_RPM
        ;;
    arch)
        info "Installing packages via pacman..."
        # shellcheck disable=SC2086
        sudo pacman -S --noconfirm $PKGS_ARCH
        ;;
    macos)
        info "Installing packages via Homebrew..."
        if ! command -v brew &>/dev/null; then
            echo "ERROR: Homebrew not found. Install it from https://brew.sh, then re-run." >&2
            echo "       Also ensure Xcode Command Line Tools are installed:" >&2
            echo "         xcode-select --install" >&2
            exit 1
        fi
        # shellcheck disable=SC2086
        brew install $PKGS_BREW
        ;;
    *)
        echo "ERROR: Unrecognised OS. Install these packages manually:" >&2
        echo "" >&2
        echo "  gcc, g++, make, openssl (dev headers), zlib (dev headers), curl, perl" >&2
        echo "" >&2
        echo "  Debian/Ubuntu : sudo apt-get install $PKGS_DEBIAN" >&2
        echo "  RHEL/CentOS   : sudo dnf install $PKGS_RPM" >&2
        echo "  Arch          : sudo pacman -S $PKGS_ARCH" >&2
        exit 1
        ;;
esac

# -- Verify
echo ""
info "Verifying required tools..."
ALL_OK=1
for cmd in gcc make openssl curl perl; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd  ($(command -v "$cmd"))"
    else
        fail "$cmd"
        ALL_OK=0
    fi
done

echo ""
if [[ "$ALL_OK" -eq 1 ]]; then
    info "All prerequisites satisfied. Run ./install.sh to build nginx and wrk."
else
    echo "ERROR: Some tools are still missing — check your package manager output above." >&2
    exit 1
fi
