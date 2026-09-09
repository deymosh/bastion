#!/usr/bin/env bash
###############################################################################
# Bastion - Core Lightning onion forward-target (integration)
#
# Boots a real CLN (the lightningd-custom image) against a throwaway regtest
# bitcoind and the real Dockerfile.tor, using a config whose Tor block matches
# stack-bitcoin/config/cln_config. Asserts:
#   - CLN parses the config and comes up (getinfo returns)
#   - the static Tor service it registers forwards to CLN's own pinned address
#     (bind-addr), never 0.0.0.0 - the exact regression this guards
#   - getinfo advertises a .onion address
#
# Fully hermetic (regtest, no external network); uses the stock CLN image, so
# only Docker + compose are needed. ~30-60s.
###############################################################################
set -u
cd "$(dirname "$0")" || exit 1

COMPOSE=(docker compose -f cln-onion.compose.yml)
BIND_ADDR=10.252.0.10          # cln_config.regtest bind-addr
cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== bringing up tor + regtest bitcoind + CLN =="
if ! "${COMPOSE[@]}" up -d --build 2>&1; then
  echo "FAIL: could not start the environment"; exit 1
fi

echo "== priming regtest (wallet + 101 blocks) =="
bcli() { "${COMPOSE[@]}" exec -T bitcoind bitcoin-cli -regtest -rpcuser=test -rpcpassword=test "$@"; }
for _ in $(seq 1 30); do bcli getblockchaininfo >/dev/null 2>&1 && break; sleep 2; done
bcli createwallet w >/dev/null 2>&1 || bcli loadwallet w >/dev/null 2>&1 || true
addr=$(bcli getnewaddress) && bcli generatetoaddress 101 "$addr" >/dev/null
echo "  regtest height: $(bcli getblockcount)"

echo "== waiting for CLN =="
gi=""
for _ in $(seq 1 40); do
  gi=$("${COMPOSE[@]}" exec -T cln lightning-cli --regtest getinfo 2>/dev/null)
  printf '%s' "$gi" | grep -q '"id"' && break
  sleep 3
done

fail=0
check() { if eval "$2"; then printf '  \033[32mok\033[0m   %s\n' "$1"; else printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; fi; }

check "CLN came up (getinfo returned an id)" 'printf "%s" "$gi" | grep -q "\"id\""'

# connectd logs:  Static Tor service onion address: "<onion>:<port>,<forward>" bound from extern port <n>
line=$("${COMPOSE[@]}" logs cln 2>&1 | grep -oE 'Static Tor service onion address: "[^"]+"' | tail -1)
echo "  $line"
# shellcheck disable=SC2034  # used inside check()'s eval
target=$(printf '%s' "$line" | sed -E 's/.*onion:[0-9]+,([0-9.]+):[0-9]+.*/\1/')
check "onion forward target is CLN's pinned address ($BIND_ADDR)" '[ "$target" = "$BIND_ADDR" ]'
check "onion forward target is not 0.0.0.0"                       '[ "$target" != "0.0.0.0" ]'
check "getinfo advertises a .onion address" 'printf "%s" "$gi" | grep -q "\.onion"'

echo
[ "$fail" -eq 0 ] && echo -e "\033[32mCLN advertises a routable onion forward target\033[0m" \
                  || { echo -e "\033[31mCLN onion forward-target regression\033[0m"; "${COMPOSE[@]}" logs cln | tail -40; }
exit $fail
