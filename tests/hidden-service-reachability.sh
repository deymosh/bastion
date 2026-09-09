#!/usr/bin/env bash
###############################################################################
# Bastion - hidden-service last-hop reachability (integration)
#
# Regression guard for the class of bug where CLN / TEOS advertise an onion
# forward target the Tor daemon cannot route to. The `tor` container lives on
# bastion-transit only; anything reachable *through* Tor must sit on
# bastion-transit at the address it advertises.
#
# This test brings up the real Tor service, puts throwaway listeners at the
# pinned CLN/TEOS transit addresses and at a bastion-bitcoin address, and
# asserts from inside the tor container which ones it can open a TCP connection
# to (that connection is the exact last hop Tor makes for an inbound onion).
#
# Needs Docker + compose. Cleans up after itself. ~1 minute.
###############################################################################
set -u
cd "$(dirname "$0")/.."

CREATED_NET=()
cleanup() {
  docker rm -f hs_cln hs_teos hs_btc >/dev/null 2>&1
  docker compose -f stack-network/docker-compose.yml rm -sf tor >/dev/null 2>&1
  for n in "${CREATED_NET[@]}"; do docker network rm "$n" >/dev/null 2>&1; done
}
trap cleanup EXIT

need_net() {
  docker network inspect "$1" >/dev/null 2>&1 && return 0
  docker network create --subnet "$2" "$1" >/dev/null && CREATED_NET+=("$1")
}
need_net bastion-transit 10.254.0.0/24
need_net bastion-bitcoin 10.20.0.0/24

echo "== bringing up tor =="
docker compose -f stack-network/docker-compose.yml up -d --build tor >/dev/null 2>&1 || { echo "could not start tor"; exit 1; }
for i in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' tor 2>/dev/null)" = healthy ] && break
  sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' tor 2>/dev/null)" = healthy ] || { echo "tor did not become healthy"; exit 1; }

listener() { # name  network  ip  port
  docker run -d --name "$1" --network "$2" --ip "$3" alpine \
    sh -c "apk add -q socat && socat TCP-LISTEN:$4,fork,reuseaddr SYSTEM:'printf ok'" >/dev/null
}
listener hs_cln  bastion-transit 10.254.0.10 9735
listener hs_teos bastion-transit 10.254.0.11 9814
listener hs_btc  bastion-bitcoin 10.20.0.5   9814
sleep 4

probe() { # ip  port   -> prints REACHABLE / unreachable
  docker exec tor timeout 5 bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null \
    && echo REACHABLE || echo unreachable
}

fail=0
expect() { # label  ip  port  want
  local got; got=$(probe "$2" "$3")
  if [ "$got" = "$4" ]; then printf '  \033[32mok\033[0m   %-42s %s\n' "$1" "$got"
  else printf '  \033[31mFAIL\033[0m %-42s got %s, want %s\n' "$1" "$got" "$4"; fail=1; fi
}

echo "== last-hop reachability from the tor container =="
expect "CLN forward target 10.254.0.10:9735"   10.254.0.10 9735 REACHABLE
expect "TEOS forward target 10.254.0.11:9814"   10.254.0.11 9814 REACHABLE
expect "a bastion-bitcoin addr 10.20.0.5:9814"  10.20.0.5   9814 unreachable

echo
[ "$fail" -eq 0 ] && echo -e "\033[32mhidden-service forward targets are routable from Tor\033[0m" \
                  || echo -e "\033[31mregression: a forward target Tor cannot reach\033[0m"
exit $fail
