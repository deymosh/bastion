#!/usr/bin/env bash
###############################################################################
# Bastion weekly tier - real Core Lightning config + real image boot
#
# Boots lightningd-custom (the actual Bastion CLN image) with a config
# MECHANICALLY DERIVED from stack-bitcoin/config/cln_config - the derivation
# only swaps the chain backend to a throwaway regtest bitcoind and remaps the
# 10.254.x transit octet to a collision-safe 10.252.x. The Tor block
# (proxy / addr=statictor / always-use-proxy / bind-addr) passes through
# untouched except that octet, so a break in those real lines breaks this test.
#
# Asserts CLN parses the real config with the real image and comes up, and that
# the static Tor service it registers forwards to CLN's own address, never
# 0.0.0.0. Fully offline (regtest). ~1-2 min. Needs lightningd-custom:latest.
###############################################################################
set -u
cd "$(dirname "$0")" || exit 1

# Generate the derived config files inside the repo (a bind mount from the
# system temp dir is unreliable on Docker Desktop). .work/ is git-ignored.
WORK=.work
export CLN_WEEKLY_DIR="$WORK"
mkdir -p "$WORK"
COMPOSE=(docker compose -f cln.compose.yml)
cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

if ! docker image inspect lightningd-custom:latest >/dev/null 2>&1; then
  echo "SKIP: lightningd-custom:latest not built (./bastion build stack-bitcoin)"
  exit 0
fi

REAL_CLN=../../stack-bitcoin/config/cln_config
REAL_TORRC=../../stack-network/config/torrc

# --- derive the test torrc: real file, transit octet remapped ---------------
sed 's/10\.254\.0\./10.252.0./g' "$REAL_TORRC" > "$WORK/torrc"

# --- derive the test cln_config -------------------------------------------
# Only the chain backend and the workspace-specific plugins are changed; the
# Tor lines are carried through with just the octet swap.
sed -E '
  s/10\.254\.0\./10.252.0./g;                              # transit octet
  s/^bitcoin-rpcconnect=.*/bitcoin-rpcconnect=10.252.0.3/;  # -> test bitcoind
  /^disable-plugin=bcli/d;                                  # regtest uses bcli
  \#^important-plugin=.*/trustedcoin#d;                     # backend is bcli
  \#^important-plugin=.*/watchtower-client#d;               # needs a tower
  \#^plugin=.*/(darknet\.py|clboss|peerswap)#d;            # workspace plugins
  \#^wallet=sqlite3://#d;                                   # /backup_usb path
' "$REAL_CLN" > "$WORK/cln_config"
printf '\nbitcoin-rpcport=18443\n' >> "$WORK/cln_config"    # regtest RPC port

echo "== derived cln_config Tor block (must match the real file, octet aside) =="
grep -E '^(proxy|addr|always-use-proxy|bind-addr)=' "$WORK/cln_config" | sed 's/^/   /'

fail=0
ck() { if eval "$2"; then printf '  \033[32mok\033[0m   %s\n' "$1"; else printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; fi; }

# the transform must have preserved the statictor wiring
ck "derived config keeps addr=statictor on the tor address" \
   'grep -q "^addr=statictor:10.252.0.2:9051" "$WORK/cln_config"'
ck "derived config keeps bind-addr = the pinned CLN address" \
   'grep -q "^bind-addr=10.252.0.10:9735" "$WORK/cln_config"'
ck "derived config keeps always-use-proxy=true" \
   'grep -q "^always-use-proxy=true" "$WORK/cln_config"'

echo "== bringing up tor + regtest bitcoind + CLN (real image + config) =="
"${COMPOSE[@]}" up -d --build 2>&1 | grep -E "Built|Error|error" || true
s=""
for _ in $(seq 1 40); do
  s=$("${COMPOSE[@]}" ps tor --format '{{.Health}}' 2>/dev/null)
  [ "$s" = healthy ] && break
  sleep 3
done
[ "$s" = healthy ] || { echo "FAIL: tor unhealthy"; "${COMPOSE[@]}" logs tor | tail -20; exit 1; }

bcli() { "${COMPOSE[@]}" exec -T bitcoind bitcoin-cli -regtest -rpcuser=bitcoind.user -rpcpassword=bitcoind.pass "$@"; }
for _ in $(seq 1 30); do bcli getblockchaininfo >/dev/null 2>&1 && break; sleep 2; done
bcli createwallet w >/dev/null 2>&1 || bcli loadwallet w >/dev/null 2>&1 || true
bcli generatetoaddress 101 "$(bcli getnewaddress)" >/dev/null
echo "  regtest height: $(bcli getblockcount)"

gi=""
for _ in $(seq 1 45); do
  gi=$("${COMPOSE[@]}" exec -T cln lightning-cli --regtest getinfo 2>/dev/null)
  printf '%s' "$gi" | grep -q '"id"' && break
  sleep 3
done

ck "CLN parsed the real config + real image and came up" 'printf "%s" "$gi" | grep -q "\"id\""'

line=$("${COMPOSE[@]}" logs cln 2>&1 | grep -oE 'Static Tor service onion address: "[^"]+"' | tail -1)
echo "  $line"
# shellcheck disable=SC2034  # used in ck's eval
target=$(printf '%s' "$line" | sed -E 's/.*onion:[0-9]+,([0-9.]+):[0-9]+.*/\1/')
ck "onion forward target is CLN's own pinned address (10.252.0.10)" '[ "$target" = "10.252.0.10" ]'
ck "onion forward target is not 0.0.0.0"                             '[ "$target" != "0.0.0.0" ]'
ck "getinfo advertises a .onion address" 'printf "%s" "$gi" | grep -q "\.onion"'

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mreal CLN config + image boot cleanly; onion target is routable\033[0m"
else echo -e "\033[31mCLN real-config regression\033[0m"; "${COMPOSE[@]}" logs cln | tail -50; fi
exit $fail
