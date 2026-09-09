#!/usr/bin/env bash
###############################################################################
# Unit-ish tests for the ./bastion CLI: stack resolution, flag stripping,
# command dispatch, and the network preflight - driven with a stubbed docker
# so no daemon is touched.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh
source tests/lib/mock-bin.sh
mock_bin_init

WORK=$(mktemp -d); trap 'rm -rf "$WORK"; mock_bin_cleanup' EXIT
cat > "$WORK/bastion.conf" <<'EOF'
WIREGUARD_SERVERURL=example.com
WIREGUARD_SERVERPORT=51820
NODE_ALIAS=ci
EOF

b() { BASTION_SKIP_ENV_LINKS=1 CONFIG_FILE="$WORK/bastion.conf" ./bastion "$@" </dev/null 2>&1; }

echo "== command dispatch =="
out=$(b);          rc=$?; assert_contains "$out" "COMMANDS:" "no args (non-TTY) prints usage"; assert_eq "$rc" 1 "usage exits 1"
out=$(b boguscmd); rc=$?; assert_contains "$out" "COMMANDS:" "unknown command prints usage"

echo "== per-stack resolution =="
out=$(b up);                 assert_contains "$out" "Booting: stack-network stack-bitcoin stack-monitor stack-web stack-ai" "no list = all, canonical order"
out=$(b up web ai);          assert_contains "$out" "Booting: stack-web stack-ai"  "shorthand names resolve"
out=$(b up stack-ai stack-web); assert_contains "$out" "Booting: stack-web stack-ai" "explicit names reordered to canonical"
out=$(b up nope); rc=$?;     assert_contains "$out" "Unknown stack: stack-nope"    "unknown stack rejected"; assert_eq "$rc" 1 "unknown stack exits 1"

echo "== flag stripping =="
out=$(b up --recreate-networks web); assert_contains "$out" "Booting: stack-web" "--recreate-networks stripped, command still parsed"

echo "== network preflight =="
out=$(MOCK_NETWORK_SUBNET=10.0.0.0/24 b up web); rc=$?
assert_contains "$out" "Stale 'bastion-network'" "blocks on the old flat subnet"
assert_eq "$rc" 1 "preflight refusal exits 1"
out=$(MOCK_NETWORK_SUBNET=10.10.0.0/24 b up web); assert_contains "$out" "Booting: stack-web" "passes on the migrated subnet"
out=$(MOCK_NETWORK_SUBNET='' b up web);           assert_contains "$out" "Booting: stack-web" "passes when the network does not exist yet"

echo "== stop lists the set =="
out=$(b stop); assert_contains "$out" "Stopping: stack-network stack-bitcoin stack-monitor stack-web stack-ai" "stop covers all stacks"

finish
