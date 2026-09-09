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
: > "$WORK/rune"   # a pre-existing access.rune so ensure_rtl_rune no-ops in `b`

b() {
  BASTION_SKIP_ENV_LINKS=1 CONFIG_FILE="$WORK/bastion.conf" \
  RTL_RUNE_FILE="$WORK/rune" RTL_RUNE_RETRIES=1 RTL_RUNE_WAIT=0 \
  ./bastion "$@" </dev/null 2>&1
}

# a config file that is missing the no-default essentials
cat > "$WORK/bare.conf" <<'EOF'
TIMEZONE=UTC
EOF
bare() { BASTION_SKIP_ENV_LINKS=1 CONFIG_FILE="$WORK/bare.conf" ./bastion "$@" </dev/null 2>&1; }

echo "== command dispatch =="
out=$(b);          rc=$?; assert_contains "$out" "COMMANDS:" "no args (non-TTY) prints usage"; assert_eq "$rc" 1 "usage exits 1"
out=$(b boguscmd); rc=$?; assert_contains "$out" "COMMANDS:" "unknown command prints usage"

echo "== config is only demanded when it is actually needed =="
out=$(bare help);   rc=$?; assert_contains "$out" "COMMANDS:" "help works without config"; assert_not_contains "$out" "Required configuration" "help never asks for config"
out=$(MOCK_DOCKER_INFO_RC=1 bare help); assert_not_contains "$out" "Docker daemon is not running" "help does not even check Docker"
out=$(bare status); rc=$?; assert_not_contains "$out" "Required configuration" "status does not demand the essentials"
out=$(bare logs web); assert_not_contains "$out" "Required configuration" "logs does not demand the essentials"
out=$(bare up web);  rc=$?
assert_contains "$out" "Required configuration not set" "up refuses when essentials are unset"
assert_contains "$out" "WIREGUARD_SERVERURL" "names the missing keys"
assert_eq "$rc" 1 "up with missing config exits 1"
out=$(bare up web); assert_not_contains "$out" "Booting:" "up does not proceed without the essentials"

echo "== per-stack resolution =="
out=$(b up);                 assert_contains "$out" "Booting: stack-network stack-bitcoin stack-monitor stack-web stack-ai" "no list = all, canonical order"
out=$(b up web ai);          assert_contains "$out" "Booting: stack-network stack-web stack-ai"  "shorthand names resolve"
out=$(b up stack-ai stack-web); assert_contains "$out" "Booting: stack-network stack-web stack-ai" "explicit names reordered to canonical"
out=$(b up nope); rc=$?;     assert_contains "$out" "Unknown stack: stack-nope"    "unknown stack rejected"; assert_eq "$rc" 1 "unknown stack exits 1"

echo "== mandatory stack-network =="
out=$(b up web ai);  assert_contains "$out" "Adding stack-network" "stack-network auto-added when omitted"
out=$(b up web);     assert_contains "$out" "Booting: stack-network stack-web" "auto-add lands first, canonical order"
out=$(b up network); assert_not_contains "$out" "Adding stack-network" "no note when stack-network was named"
out=$(b up);         assert_not_contains "$out" "Adding stack-network" "no note when deploying everything"

echo "== flag stripping =="
out=$(b up --recreate-networks web); assert_contains "$out" "Booting: stack-network stack-web" "--recreate-networks stripped, command still parsed"

echo "== network preflight =="
out=$(MOCK_NETWORK_SUBNET=10.0.0.0/24 b up web); rc=$?
assert_contains "$out" "Stale 'bastion-network'" "blocks on the old flat subnet"
assert_eq "$rc" 1 "preflight refusal exits 1"
out=$(MOCK_NETWORK_SUBNET=10.10.0.0/24 b up web); assert_contains "$out" "Booting: stack-network stack-web" "passes on the migrated subnet"
out=$(MOCK_NETWORK_SUBNET='' b up web);           assert_contains "$out" "Booting: stack-network stack-web" "passes when the network does not exist yet"

echo "== stop lists the set =="
out=$(b stop); assert_contains "$out" "Stopping: stack-network stack-bitcoin stack-monitor stack-web stack-ai" "stop covers all stacks"

echo "== stack-network teardown guard =="
# nothing running -> a targeted network down is allowed
out=$(MOCK_PS_NAMES='' b down network); rc=$?
assert_contains "$out" "Removing: stack-network" "down stack-network allowed when nothing else runs"
assert_eq "$rc" 0 "allowed teardown exits 0"
# lightningd (stack-bitcoin) up -> refuse to take network down on its own
out=$(MOCK_PS_NAMES='lightningd tor' b down network); rc=$?
assert_contains "$out" "Refusing to down stack-network" "refuses while stack-bitcoin runs"
assert_contains "$out" "stack-bitcoin" "names the blocking stack"
assert_eq "$rc" 1 "blocked teardown exits 1"
# same, but --force overrides
out=$(MOCK_PS_NAMES='lightningd tor' b down network --force); rc=$?
assert_contains "$out" "force" "--force downgrades the refusal"
assert_contains "$out" "Removing: stack-network" "--force lets the teardown run"
# down of everything is never blocked (all running stacks are in the set)
out=$(MOCK_PS_NAMES='lightningd tor ccr' b down); rc=$?
assert_contains "$out" "Removing: stack-network stack-bitcoin stack-monitor stack-web stack-ai" "down (all) is never blocked"
# stop is guarded the same way
out=$(MOCK_PS_NAMES='ccr' b stop network); rc=$?
assert_contains "$out" "Refusing to stop stack-network" "stop stack-network refused while stack-ai runs"
# a targeted down that doesn't name stack-network is never a network teardown
out=$(MOCK_PS_NAMES='lightningd tor' b down web); rc=$?
assert_contains "$out" "Removing: stack-web" "down of another stack is untouched by the guard"
assert_not_contains "$out" "Refusing" "down stack-web is not refused while stack-bitcoin runs"
assert_eq "$rc" 0 "down stack-web exits 0"

echo "== teosd opt-in profile =="
out=$(b up); assert_not_contains "$out" "TEOS" "plain 'up' does not build/start teosd"
out=$(b up); assert_not_contains "$out" "COMPOSE_PROFILES=watchtower" "plain 'up' activates no profile"
out=$(b up --with-watchtower)
assert_contains "$out" "COMPOSE_PROFILES=watchtower" "--with-watchtower activates the profile for docker compose"
assert_contains "$out" "TEOS" "--with-watchtower builds teosd before starting"
out=$(BASTION_PROFILES=watchtower b up)
assert_contains "$out" "COMPOSE_PROFILES=watchtower" "BASTION_PROFILES env also activates the profile"
# stop/down activate the profile regardless so teosd is not orphaned
out=$(b down web); assert_contains "$out" "COMPOSE_PROFILES=watchtower" "down activates all profiles for teardown"
out=$(b stop web); assert_contains "$out" "COMPOSE_PROFILES=watchtower" "stop activates all profiles for teardown"
out=$(b build --with-watchtower stack-bitcoin); assert_contains "$out" "TEOS" "build --with-watchtower force-builds teosd"
out=$(b build stack-bitcoin); assert_not_contains "$out" "TEOS" "plain build skips teosd"

echo "== RTL rune bootstrap (via 'up') =="
rm -f "$WORK/rune"
out=$(MOCK_EXEC_OUT=$'rune=abc123XYZ\nunique_id=0' b up bitcoin)
assert_contains "$out" "Wrote $WORK/rune" "up mints the rune when absent"
grep -q 'LIGHTNING_RUNE="abc123XYZ"' "$WORK/rune" && _t_ok "rune file has LIGHTNING_RUNE format" || _t_bad "rune file format wrong: $(cat "$WORK/rune")"
[ "$(uname -s)" = Linux ] && { [ "$(stat -c '%a' "$WORK/rune")" = 600 ] && _t_ok "rune file is mode 600" || _t_bad "rune file not 600"; }
# second run: file present -> ensure_rtl_rune returns early, no rewrite
out=$(MOCK_EXEC_OUT=$'rune=SHOULDNOTUSE\nunique_id=0' b up bitcoin)
grep -q 'LIGHTNING_RUNE="abc123XYZ"' "$WORK/rune" && _t_ok "existing rune left untouched on re-run" || _t_bad "rune was overwritten"
# CLN not reachable -> warn, exit 0, no file
rm -f "$WORK/rune"
out=$(MOCK_EXEC_RC=1 MOCK_EXEC_OUT="" b up bitcoin); rc=$?
assert_contains "$out" "CLN not reachable" "up warns when CLN is not ready"
assert_eq "$rc" 0 "up still succeeds when the rune could not be minted"
assert_ok test '!' -e "$WORK/rune"
: > "$WORK/rune"   # restore the no-op sentinel for later tests

echo "== versions =="
out=$(b versions); rc=$?
assert_eq "$rc" 0 "versions exits 0"
for _s in stack-network stack-bitcoin stack-monitor stack-web stack-ai; do
  assert_contains "$out" "$_s" "versions groups by $_s"
done
assert_contains "$out" "pihole/pihole:" "versions shows the pihole image pin"
assert_contains "$out" "@sha256:"       "versions shows a digest pin"
assert_contains "$out" "ccr" "versions lists the ccr service"
# with a stubbed 'running' state the state column is populated, not 'absent'
out=$(MOCK_INSPECT=running b versions)
assert_contains "$out" "running" "versions reflects container state from docker inspect"

finish
