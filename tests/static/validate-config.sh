#!/usr/bin/env bash
###############################################################################
# Bastion - static configuration invariants
#
# Fast checks that need no Docker daemon: they grep the committed compose files
# and service configs and assert the cross-references that keep the stacks
# wired together. Run from the repo root: ./tests/validate-config.sh
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1

pass=0 fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
have() { grep -qE "$1" "$2" 2>/dev/null; }

BC="stack-bitcoin/docker-compose.yml"
NET="stack-network/docker-compose.yml"
CLN="stack-bitcoin/config/cln_config"
TEOS="stack-bitcoin/config/teos.toml"
TORRC="stack-network/config/torrc"

echo "== Tor transit address (10.254.0.2) consistency =="
# These service configs address the Tor container by literal IP.
for f in "$TORRC" "$CLN" "$TEOS"; do
  have '10\.254\.0\.2' "$f" && ok "$f references 10.254.0.2" || bad "$f is missing 10.254.0.2"
done
# bitcoind reaches Tor by DNS name, not IP - assert that, not a literal.
have '\-proxy=tor:9050' "$BC" && ok "bitcoind -proxy uses the tor DNS name" \
  || bad "bitcoind -proxy is not 'tor:9050'"
# No config anywhere may still point at a host on the pre-migration flat
# network. Match 10.0.0.<host> (host 1-255) but not the 10.0.0.0/N CIDR, and
# grep content (grep -n), not just filenames.
stale=$(grep -RnE '10\.0\.0\.[1-9][0-9]*([^0-9/]|$)' \
          stack-*/config stack-*/docker-compose.yml stack-bitcoin/scripts 2>/dev/null || true)
[ -z "$stale" ] && ok "no stale 10.0.0.x host addresses" \
  || bad "stale 10.0.0.x: $(printf '%s' "$stale" | head -3 | paste -sd'; ' -)"

echo "== Hidden-service forward targets are on bastion-transit =="
# CLN advertises cln_config's bind-addr to Tor; it must be the pinned transit IP.
cln_bind=$(grep -oE '^bind-addr=[0-9.]+:[0-9]+' "$CLN" | cut -d= -f2)
[ "$cln_bind" = "10.254.0.10:9735" ] && ok "cln_config bind-addr = 10.254.0.10:9735" \
  || bad "cln_config bind-addr is '$cln_bind' (expected 10.254.0.10:9735, never 0.0.0.0)"
have 'ipv4_address:\s*10\.254\.0\.10' "$BC" && ok "lightningd pinned to 10.254.0.10 on transit" \
  || bad "lightningd is not pinned to 10.254.0.10 on bastion-transit"

teos_bind=$(grep -oE '^api_bind\s*=\s*"[0-9.]+"' "$TEOS" | grep -oE '[0-9.]+')
[ "$teos_bind" = "10.254.0.11" ] && ok "teos.toml api_bind = 10.254.0.11" \
  || bad "teos.toml api_bind is '$teos_bind' (expected 10.254.0.11, not a bastion-bitcoin addr)"
have 'ipv4_address:\s*10\.254\.0\.11' "$BC" && ok "teosd pinned to 10.254.0.11 on transit" \
  || bad "teosd is not pinned to 10.254.0.11 on bastion-transit"
have '^tor_control_host\s*=\s*"10\.254\.0\.2"' "$TEOS" && ok "teos.toml tor_control_host = 10.254.0.2" \
  || bad "teos.toml tor_control_host is not 10.254.0.2"
# teosd is opt-in: the service must carry the 'watchtower' compose profile so a
# plain `./bastion up` does not start it.
awk '/^  teosd:/{t=1} t&&/^  [a-z]/&&!/^  teosd:/{t=0} t&&/profiles:.*watchtower/{f=1} END{exit f?0:1}' "$BC" \
  && ok "teosd carries the 'watchtower' compose profile (opt-in)" \
  || bad "teosd is missing 'profiles: [watchtower]' - it would start by default"

echo "== CLN <-> bitcoind wiring =="
have '^bitcoin-rpcconnect=10\.20\.0\.3' "$CLN" && ok "cln_config bitcoin-rpcconnect = 10.20.0.3 (bitcoind)" \
  || bad "cln_config bitcoin-rpcconnect != 10.20.0.3"

echo "== Per-stack networks =="
declare -A want=( [stack-network]=10.10 [stack-bitcoin]=10.20 [stack-monitor]=10.30 [stack-web]=10.40 [stack-ai]=10.50 )
for s in "${!want[@]}"; do
  f="$s/docker-compose.yml"
  have "subnet:\s*${want[$s]}\.0\.0/24" "$f" && ok "$s owns ${want[$s]}.0.0/24" || bad "$s subnet is not ${want[$s]}.0.0/24"
done
# bastion-transit must be external everywhere except stack-network (its owner)
for s in stack-bitcoin stack-ai; do
  f="$s/docker-compose.yml"
  awk '/^  transit:/{t=1} t&&/name: bastion-transit/{n=1} t&&/external: true/{e=1} END{exit !(n&&e)}' "$f" \
    && ok "$s consumes bastion-transit as external" || bad "$s does not declare bastion-transit external"
done
awk '/^  transit:/{t=1} t&&/external:/{bad=1} END{exit bad?1:0}' "$NET" \
  && ok "stack-network declares (does not import) bastion-transit" || bad "stack-network marks bastion-transit external"

echo "== Tor image / torrc =="
have '^CookieAuthFile ' "$TORRC" && ok "torrc sets an explicit CookieAuthFile" \
  || bad "torrc missing CookieAuthFile (CookieAuthFileGroupReadable has no effect without it)"
have 'chmod 0750 /data/.tor' stack-network/Dockerfile.tor && ok "Dockerfile.tor pre-creates /data/.tor 0750" \
  || bad "Dockerfile.tor does not pre-create /data/.tor with mode 0750"

echo "== Image pinning / no stray Tor publish =="
# Tor SOCKS/control are bound to 10.254.0.2 in torrc; nothing should publish them.
pub=$(grep -REn '^\s*-\s*"[^"]*(:| )905[01]([:/"]|$)' stack-*/docker-compose.yml 2>/dev/null || true)
[ -z "$pub" ] && ok "no compose file publishes host ports 9050/9051" \
  || bad "a compose file still publishes 9050/9051: $(printf '%s' "$pub" | head -1)"
# Every pulled image (has a '/', i.e. not a locally-built bare name) is digest-pinned.
unpinned=$(grep -REn '^\s*image:\s*[^#]*/[^#]*$' stack-*/docker-compose.yml 2>/dev/null | grep -v '@sha256:' || true)
[ -z "$unpinned" ] && ok "every pulled image is pinned by @sha256 digest" \
  || bad "unpinned pulled image(s): $(printf '%s' "$unpinned" | head -2 | paste -sd'; ' -)"
# CCR is built from a commit, not a moving branch.
ccr_ref=$(grep -oE 'CCR_REF:\s*\S+' stack-ai/docker-compose.yml | awk '{print $2}')
[[ "$ccr_ref" =~ ^[0-9a-f]{40}$ ]] && ok "CCR_REF is a 40-hex commit ($ccr_ref)" \
  || bad "CCR_REF is not a commit SHA: '$ccr_ref'"

echo "== CONTAINER_STACK matches the compose files exactly =="
# One source of truth: utils/config.sh CONTAINER_STACK. Assert it is neither
# missing a compose service nor listing one that no longer exists, and that the
# owning stack is right. utils/tui.sh derives STACK_OF_CONTAINER from this map.
(
  export CONFIG_FILE=/dev/null BASTION_SKIP_ENV_LINKS=1
  STACKS=("stack-network" "stack-bitcoin" "stack-monitor" "stack-web" "stack-ai")
  # shellcheck disable=SC1091
  source utils/config.sh
  drift=0
  declare -A seen=()
  for s in "${STACKS[@]}"; do
    while read -r svc; do
      [ -n "$svc" ] || continue
      seen["$svc"]=1
      case "${CONTAINER_STACK[$svc]:-}" in
        "$s") : ;;
        "")   echo "  CONTAINER_STACK is missing '$svc' (in $s/docker-compose.yml)"; drift=1 ;;
        *)    echo "  CONTAINER_STACK maps '$svc' to ${CONTAINER_STACK[$svc]}, but it is defined in $s"; drift=1 ;;
      esac
    done < <(awk '/^  [A-Za-z0-9_-]+:[[:space:]]*$/{s=$1;sub(/:$/,"",s);next} /^    image:[[:space:]]/&&s{print s;s=""}' "$s/docker-compose.yml")
  done
  for c in "${!CONTAINER_STACK[@]}"; do
    [ -n "${seen[$c]:-}" ] || { echo "  CONTAINER_STACK lists '$c' but no compose file defines it"; drift=1; }
  done
  exit $drift
) && ok "CONTAINER_STACK is in exact sync with the compose service list" \
   || bad "CONTAINER_STACK has drifted from the compose files (see above)"

echo "== Submodule tracking =="
have 'branch = bastion-integration' .gitmodules && ok ".gitmodules tracks rust-teos bastion-integration" \
  || bad ".gitmodules does not pin rust-teos to bastion-integration"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mall %d checks passed\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
