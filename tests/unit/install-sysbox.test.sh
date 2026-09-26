#!/usr/bin/env bash
###############################################################################
# Unit tests for utils/install-sysbox.sh --check: every host precondition is
# enforced before anything is downloaded or installed. Host detection is
# driven through the script's SYSBOX_* test hooks; nothing touches the system.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$WORK/ubuntu"
printf 'ID=debian\n' > "$WORK/debian"
printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' > "$WORK/mint"
printf 'ID=fedora\n' > "$WORK/fedora"

chk() {
  env SYSBOX_UNAME_S=Linux SYSBOX_OS_RELEASE="$WORK/ubuntu" SYSBOX_HAS_SYSTEMD=1 \
      SYSBOX_KERNEL=6.8.0-45-generic SYSBOX_ARCH=amd64 SYSBOX_DOCKER_PATH=/usr/bin/docker \
      "$@" bash utils/install-sysbox.sh --check 2>&1
}

echo "== supported hosts pass =="
out=$(chk); rc=$?
assert_eq "$rc" 0 "Ubuntu 24.04 / kernel 6.8 / amd64 passes"
assert_contains "$out" "Host can run Sysbox" "reports the host as ready"
out=$(chk SYSBOX_ARCH=arm64); assert_contains "$out" "(arm64)" "arm64 has a pinned package"
out=$(chk SYSBOX_OS_RELEASE="$WORK/debian"); rc=$?; assert_eq "$rc" 0 "Debian passes"
out=$(chk SYSBOX_OS_RELEASE="$WORK/mint"); rc=$?; assert_eq "$rc" 0 "an Ubuntu derivative (ID_LIKE) passes"
out=$(chk SYSBOX_KERNEL=5.12.0); rc=$?; assert_eq "$rc" 0 "kernel 5.12 (ID-mapped mounts) is the floor"

echo "== unsupported hosts are refused, with the reason =="
out=$(chk SYSBOX_UNAME_S=Darwin); rc=$?
assert_eq "$rc" 1 "non-Linux refused"; assert_contains "$out" "Linux only" "says why"
out=$(chk SYSBOX_OS_RELEASE="$WORK/fedora"); rc=$?
assert_eq "$rc" 1 "non-Debian-family distro refused"; assert_contains "$out" "Ubuntu/Debian only" "points at the source build"
out=$(chk SYSBOX_HAS_SYSTEMD=0); rc=$?
assert_eq "$rc" 1 "no systemd refused"; assert_contains "$out" "systemd" "says why"
out=$(chk SYSBOX_KERNEL=5.11.4); rc=$?
assert_eq "$rc" 1 "kernel < 5.12 refused"; assert_contains "$out" "shiftfs" "explains the shiftfs requirement"
out=$(chk SYSBOX_KERNEL=4.19.0); rc=$?; assert_eq "$rc" 1 "kernel 4.x refused"
out=$(chk SYSBOX_ARCH=armhf); rc=$?
assert_eq "$rc" 1 "unpackaged architecture refused"; assert_contains "$out" "armhf" "names the architecture"
out=$(chk SYSBOX_DOCKER_PATH=/snap/bin/docker); rc=$?
assert_eq "$rc" 1 "snap Docker refused"; assert_contains "$out" "snap" "says why"
out=$(chk SYSBOX_DOCKER_PATH=); rc=$?
assert_eq "$rc" 1 "missing Docker refused"

echo "== the package is pinned =="
grep -qE '^SYSBOX_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' utils/install-sysbox.sh \
  && _t_ok "SYSBOX_VERSION is an exact release" || _t_bad "SYSBOX_VERSION is not an exact release"
[ "$(grep -cE '^\s+\[(amd64|arm64)\]=[0-9a-f]{64}$' utils/install-sysbox.sh)" = 2 ] \
  && _t_ok "amd64 + arm64 packages carry a SHA-256" || _t_bad "a package checksum is missing"
grep -q 'sha256sum -c' utils/install-sysbox.sh \
  && _t_ok "the checksum is verified before apt sees the package" || _t_bad "no checksum verification"

finish
