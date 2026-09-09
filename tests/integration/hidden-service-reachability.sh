#!/usr/bin/env bash
###############################################################################
# Bastion - hidden-service last-hop reachability (integration)
#
# Regression guard for the class of bug where CLN / TEOS advertise an onion
# forward target the Tor daemon cannot route to. The `tor` container lives on
# bastion-transit only; a service reachable *through* Tor must sit on that
# network at the address it advertises (never 0.0.0.0 - Tor cannot connect to
# that at all).
#
# Uses tests/integration/tor.compose.yml (hermetic: own project, own private
# subnets, the real Dockerfile.tor and a torrc derived from the real one).
# Needs Docker + compose + outbound network. ~1-2 minutes. Self-cleaning.
###############################################################################
set -u
cd "$(dirname "$0")" || exit 1

COMPOSE=(docker compose -f tor.compose.yml)
GEN_TORRC=torrc.generated

cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$GEN_TORRC"
}
trap cleanup EXIT

# Real torrc, but on the collision-safe 10.253.x range this test uses.
sed 's/10\.254\.0\./10.253.0./g' ../../stack-network/config/torrc > "$GEN_TORRC"

echo "== bringing up the hermetic Tor environment =="
if ! "${COMPOSE[@]}" up -d --build 2>&1; then
  echo "FAIL: could not start the test environment"
  exit 1
fi

echo "== waiting for tor to be healthy =="
s=""
for _ in $(seq 1 40); do
  s=$("${COMPOSE[@]}" ps tor --format '{{.Health}}' 2>/dev/null)
  [ "$s" = healthy ] && break
  sleep 3
done
if [ "$s" != healthy ]; then
  echo "FAIL: tor did not become healthy"
  "${COMPOSE[@]}" logs tor | tail -30
  exit 1
fi
sleep 5   # the alpine mocks apk-add socat on start

probe() { # ip port -> REACHABLE | unreachable
  "${COMPOSE[@]}" exec -T tor timeout 5 bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null \
    && echo REACHABLE || echo unreachable
}

fail=0
expect() { # label ip port want
  local got; got=$(probe "$2" "$3")
  if [ "$got" = "$4" ]; then printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "$got"
  else printf '  \033[31mFAIL\033[0m %-46s got %s, want %s\n' "$1" "$got" "$4"; fail=1; fi
}

echo "== last-hop reachability from the tor container =="
expect "CLN forward target  (transit .10:9735)"    10.253.0.10 9735 REACHABLE
expect "TEOS forward target (transit .11:9814)"     10.253.0.11 9814 REACHABLE
expect "a per-stack subnet addr (10.19.0.5:9814)"   10.19.0.5   9814 unreachable
expect "0.0.0.0:9735  (the old CLN bind-addr)"      0.0.0.0     9735 unreachable
expect "tor's own loopback 127.0.0.1:9735"          127.0.0.1   9735 unreachable

echo
[ "$fail" -eq 0 ] && echo -e "\033[32mgood forward targets are routable from Tor, bad ones are not\033[0m" \
                  || echo -e "\033[31mregression in Tor forward-target reachability\033[0m"
exit $fail
