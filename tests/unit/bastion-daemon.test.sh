#!/usr/bin/env bash
###############################################################################
# Unit tests for services/bastion-daemon.sh's channel-backup (SCB) handling:
# the live copy on the backup drive is replaced atomically and only with a
# verified copy, and nothing is written when the drive is not mounted.
# The daemon is sourced (its main flow only runs when executed) against
# scratch dirs, with `mountpoint` stubbed on PATH.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cln" "$WORK/usb" "$WORK/bin"
cat > "$WORK/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_MOUNTED_RC:-0}"
EOF
chmod +x "$WORK/bin/mountpoint"
export PATH="$WORK/bin:$PATH"

CLN_DATA_DIR="$WORK/cln"; BACKUP_DEST="$WORK/usb"
source services/bastion-daemon.sh
SRC="$WORK/cln/emergency.recover"
LIVE="$WORK/usb/emergency.recover.live"

echo "== sourcing does not start the daemon =="
_t_ok "sourced without running ./bastion up or the polling loop"

echo "== first sync, then no-op, then update =="
printf 'scb-v1' > "$SRC"
out=$(sync_scb); rc=$?
assert_eq "$rc" 0 "first sync succeeds"
assert_eq "$(cat "$LIVE")" "scb-v1" "live copy written"
assert_ok test '!' -e "$LIVE.tmp"
out=$(sync_scb); rc=$?
assert_eq "$rc" 0 "unchanged source is a no-op"
assert_not_contains "$out" "Change detected" "no copy when hashes match"
printf 'scb-v2' > "$SRC"
out=$(sync_scb)
assert_eq "$(cat "$LIVE")" "scb-v2" "changed source replaces the live copy"

echo "== backup drive not mounted: nothing written =="
printf 'scb-v3' > "$SRC"
out=$(MOCK_MOUNTED_RC=1 sync_scb); rc=$?
assert_eq "$rc" 1 "sync refuses when the drive is not mounted"
assert_contains "$out" "not a mounted filesystem" "says why"
assert_eq "$(cat "$LIVE")" "scb-v2" "previous live copy left intact"
LAST_MAINTENANCE_DATE=""
out=$(MOCK_MOUNTED_RC=1 run_daily_maintenance)
assert_ok test '!' -e "$WORK/usb/history"

echo "== a copy that fails verification never replaces the live file =="
out=$(cp() { printf 'corrupt' > "${@: -1}"; }; sync_scb); rc=$?
assert_eq "$rc" 1 "integrity failure is reported"
assert_contains "$out" "Integrity check failed" "says so"
assert_eq "$(cat "$LIVE")" "scb-v2" "live copy untouched by a bad copy"
assert_ok test '!' -e "$LIVE.tmp"

echo "== daily history snapshot on a mounted drive =="
LAST_MAINTENANCE_DATE=""
out=$(run_daily_maintenance)
assert_eq "$(cat "$WORK/usb/history/emergency.recover.$(date +%Y-%m-%d)")" "scb-v3" "today's snapshot written"

echo "== systemd unit runs the daemon from its real path =="
exec_path=$(sed -n 's#^ExecStart=/bin/bash ##p' services/bastion-daemon.service)
assert_ok test -f "$exec_path"

finish
