#!/bin/bash
###############################################################################
# Install the Sysbox runtime (sysbox-runc) that the opt-in agent-docker
# sidecar requires. Called by ./bastion (`install-sysbox`, or the offer made
# when `up --with-agent-docker` finds no Sysbox); ./bastion stops the running
# stacks first, because this install restarts Docker (see below).
#
#   utils/install-sysbox.sh --check   # host preconditions only, no changes
#   utils/install-sysbox.sh           # check, download, verify, install
#
# The package is pinned: version + per-arch SHA-256, verified before apt ever
# sees it. Bump SYSBOX_VERSION and both checksums together.
#
# Why Docker restarts: the Sysbox installer registers the runtime in
# /etc/docker/daemon.json and, unless `bip` + `default-address-pools` are
# already set there, adds those too - which only a daemon restart applies.
# Docker's own shutdown gives containers ~15s, far less than bitcoind's 5m
# stop_grace_period, hence the graceful ./bastion stop beforehand.
#
# Test hooks (unit tests only): SYSBOX_UNAME_S, SYSBOX_OS_RELEASE,
# SYSBOX_HAS_SYSTEMD, SYSBOX_KERNEL, SYSBOX_ARCH, SYSBOX_DOCKER_PATH override
# host detection.
###############################################################################
set -euo pipefail

SYSBOX_VERSION="0.7.1"
declare -A SYSBOX_SHA256=(
    [amd64]=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
    [arm64]=04ca894ae0b53f0fa54eaacc173ce40363c9a95ea5450f773716a84ef650a69b
)

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
die()  { echo -e "${RED}${BOLD}[✘] $*${NC}" >&2; exit 1; }
note() { echo -e "${CYAN}--> $*${NC}"; }

# --- Preconditions (no side effects) -----------------------------------------
check_host() {
    local os kernel major minor arch docker_path id id_like
    os="${SYSBOX_UNAME_S:-$(uname -s)}"
    [ "$os" = Linux ] || die "Sysbox runs on Linux only (this host: $os). On Docker Desktop, the agent-docker sidecar cannot be used."

    local os_release="${SYSBOX_OS_RELEASE:-/etc/os-release}"
    id=$(. "$os_release" 2>/dev/null && echo "${ID:-}")
    id_like=$(. "$os_release" 2>/dev/null && echo "${ID_LIKE:-}")
    case " $id $id_like " in
        *" ubuntu "*|*" debian "*) : ;;
        *) die "Sysbox ships packages for Ubuntu/Debian only (this host: ${id:-unknown}). Build it from source: https://github.com/nestybox/sysbox/blob/master/docs/developers-guide/build.md" ;;
    esac
    local systemd="${SYSBOX_HAS_SYSTEMD:-}"
    [ -n "$systemd" ] || { [ -d /run/systemd/system ] && systemd=1 || systemd=0; }
    [ "$systemd" = 1 ] || die "Sysbox needs systemd as the host's process manager."

    # Kernel >= 5.12 gives ID-mapped mounts, so no shiftfs module is needed.
    kernel="${SYSBOX_KERNEL:-$(uname -r)}"
    major=${kernel%%.*}; minor=${kernel#*.}; minor=${minor%%[!0-9]*}
    if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "${minor:-0}" -lt 12 ]; }; then
        die "Kernel $kernel is older than 5.12: Sysbox would need the shiftfs module. Upgrade the kernel (HWE) first."
    fi

    arch="${SYSBOX_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo unknown)}"
    [ -n "${SYSBOX_SHA256[$arch]:-}" ] || die "No Sysbox package for architecture '$arch' (amd64/arm64 only)."

    # The snap build of Docker is confined and cannot use extra runtimes.
    docker_path="${SYSBOX_DOCKER_PATH-$(command -v docker 2>/dev/null || true)}"
    [ -n "$docker_path" ] || die "Docker is not installed."
    case "$(readlink -f "$docker_path" 2>/dev/null || echo "$docker_path")" in
        /snap/*) die "Docker is installed as a snap, which Sysbox does not support. Install Docker from docker.com's apt repo." ;;
    esac

    SYSBOX_ARCH_RESOLVED="$arch"
}

# --- Install ------------------------------------------------------------------
install_sysbox() {
    local arch="$SYSBOX_ARCH_RESOLVED" deb url dir sudo=""
    [ "$(id -u)" -eq 0 ] || sudo="sudo"
    deb="sysbox-ce_${SYSBOX_VERSION}.linux_${arch}.deb"
    url="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/${deb}"
    dir=$(mktemp -d)
    # Expanded now, not at exit: `dir` is local and gone by the time the EXIT
    # trap fires, which under `set -u` would fail a successful install.
    # shellcheck disable=SC2064
    trap "rm -rf '$dir'" EXIT

    note "Downloading Sysbox ${SYSBOX_VERSION} (${arch})"
    curl -fsSL -o "$dir/$deb" "$url" || die "Download failed: $url"
    echo "${SYSBOX_SHA256[$arch]}  $dir/$deb" | sha256sum -c --quiet - \
        || die "Checksum mismatch for $deb - refusing to install it."
    echo -e "${GREEN}[✔] Checksum verified${NC}"

    note "Installing (sudo; Docker will be restarted by the Sysbox installer)"
    $sudo apt-get update -qq
    # jq is required by the Sysbox package's own install script.
    $sudo apt-get install -y jq "$dir/$deb"

    note "Verifying Docker sees the sysbox-runc runtime"
    local _
    for _ in $(seq 1 30); do
        case "$(docker info --format '{{json .Runtimes}}' 2>/dev/null)" in
            *'"sysbox-runc"'*) echo -e "${GREEN}${BOLD}[✔] Sysbox ${SYSBOX_VERSION} installed; Docker lists sysbox-runc.${NC}"; return 0 ;;
        esac
        sleep 2
    done
    die "Sysbox installed but Docker does not list sysbox-runc. Check: systemctl status sysbox; docker info | grep -i runtime"
}

check_host
if [ "${1:-}" = "--check" ]; then
    echo -e "${GREEN}[✔] Host can run Sysbox ${SYSBOX_VERSION} (${SYSBOX_ARCH_RESOLVED}).${NC}"
    exit 0
fi
install_sysbox
