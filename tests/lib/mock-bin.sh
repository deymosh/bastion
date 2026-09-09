# shellcheck shell=bash
# Put a directory of stub executables at the front of PATH so a test can drive
# ./bastion (or utils/*.sh) without a real Docker daemon.
#
#   source tests/lib/mock-bin.sh
#   mock_bin_init                 # creates $MOCK_BIN, prepends to PATH
#   # $MOCK_BIN/docker logs every call to $MOCK_LOG and prints canned output
#   mock_bin_cleanup             # (also runs on EXIT)

mock_bin_init() {
  MOCK_BIN=$(mktemp -d)
  MOCK_LOG="$MOCK_BIN/calls.log"
  : > "$MOCK_LOG"

  cat > "$MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_LOG"
case "$1 $2" in
  "info "*)            exit "${MOCK_DOCKER_INFO_RC:-0}" ;;
  "network inspect")   printf '%s\n' "${MOCK_NETWORK_SUBNET:-}" ; exit "${MOCK_NETWORK_RC:-0}" ;;
  "images -q")         printf '%s\n' "${MOCK_IMAGE_ID:-}" ;;
  "image inspect")     printf '%s\n' "${MOCK_IMAGE_LABEL:-}" ;;
  "inspect --format")  printf '%s\n' "${MOCK_HEALTH:-healthy}" ;;   # wait_for_health
  "compose "*)         echo "  (compose no-op: ${*:2})" ; exit 0 ;;
  "ps "*|"ps")         printf '%s\n' ${MOCK_PS_NAMES:-} ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/docker"

  # a git that answers rev-parse for the teos stamp check
  cat > "$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ]; then echo "${MOCK_GIT_HEAD:-deadbeefdeadbeef}"; exit 0; fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$MOCK_BIN/git"

  export PATH="$MOCK_BIN:$PATH"
  export MOCK_LOG
}

mock_bin_cleanup() { [ -n "${MOCK_BIN:-}" ] && rm -rf "$MOCK_BIN"; }
trap mock_bin_cleanup EXIT
