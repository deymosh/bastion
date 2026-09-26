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
# ...and the opt-in path must seed teos.toml, or teosd would start on rust-teos's
# compiled-in defaults (127.0.0.1 / no Tor) instead of the pinned transit config.
grep -q 'TEOS_SEED_DST.*data/teos/teos.toml' utils/config.sh \
  && grep -q 'stack-bitcoin/config/teos.toml' utils/config.sh \
  && ok "utils/config.sh seeds data/teos/teos.toml from config/teos.toml" \
  || bad "utils/config.sh no longer seeds teos.toml for the opt-in watchtower path"

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

echo "== Secrets are mounted files, not env vars =="
# The secrets must never appear as ${...} interpolations in a compose file
# (comments excluded). `docker compose config` in compose-lint already checks
# that every service `secrets:` entry resolves to a top-level declaration.
# The secret list comes from the settings registry, so a new secret is covered
# the moment it is declared.
secret_re=$(CONFIG_FILE=/dev/null bash -c 'source utils/config.sh >/dev/null 2>&1
  for k in "${MANAGED_VARS[@]}"; do config_var_is_secret "$k" && printf "%s|" "$k"; done')
secret_re=${secret_re%|}
[ -n "$secret_re" ] || bad "could not read the secret list from the settings registry"
sleak=$(grep -RhE -v '^[[:space:]]*#' stack-*/docker-compose.yml 2>/dev/null \
        | grep -oE "\\\$\{($secret_re)(:[-?+][^}]*)?\}" || true)
[ -z "$sleak" ] && ok "no secret is interpolated as an env var in a compose file" \
  || bad "secret still passed as env: $sleak"
# Each of them is wired to its file-based delivery mechanism.
have 'file: \.\./secrets/pihole_password'         "$NET" && ok "pihole_password declared from ../secrets/"       || bad "pihole_password not a file: secret"
have 'WEBPASSWORD_FILE=pihole_password'           "$NET" && ok "pihole reads its password from /run/secrets"     || bad "pihole not wired to WEBPASSWORD_FILE"
have 'file: \.\./secrets/ccr_web_auth_token'      stack-ai/docker-compose.yml && ok "ccr_web_auth_token declared from ../secrets/" || bad "ccr_web_auth_token not a file: secret"
have 'run/secrets/ccr_web_auth_token'            stack-ai/ccr/ccr-entrypoint-wrapper.sh && ok "ccr wrapper reads the mounted CCR_WEB_AUTH_TOKEN" || bad "ccr wrapper does not read the mounted secret"
have 'file: \.\./secrets/claude_code_oauth_token' stack-ai/docker-compose.yml && ok "claude_code_oauth_token declared from ../secrets/" || bad "claude_code_oauth_token not a file: secret"
have 'file: \.\./secrets/github_token'            stack-ai/docker-compose.yml && ok "github_token declared from ../secrets/" || bad "github_token not a file: secret"
have 'file: \.\./secrets/mcp_gateway_token'       stack-ai/docker-compose.yml && ok "mcp_gateway_token declared from ../secrets/" || bad "mcp_gateway_token not a file: secret"
have 'run/secrets/mcp_gateway_token'             stack-ai/mcp-gateway/gateway.py && ok "mcp-gateway reads the mounted bearer token" || bad "mcp-gateway does not read the mounted token"
have 'file: \.\./secrets/context7_api_key'        stack-ai/docker-compose.yml && ok "context7_api_key declared from ../secrets/" || bad "context7_api_key not a file: secret"

echo "== docs/configuration.md matches the settings registry =="
bash utils/gen-config-docs.sh --check >/dev/null 2>&1 \
  && ok "the generated settings table is up to date" \
  || bad "docs/configuration.md is stale - run utils/gen-config-docs.sh"

echo "== CCR runs unprivileged =="
AI="stack-ai/docker-compose.yml"
awk '/^  ccr:/{c=1} c&&/^  [a-z]/&&!/^  ccr:/{c=0} c&&/cap_drop:/{d=1} c&&d&&/- ALL/{ok=1} END{exit ok?0:1}' "$AI" \
  && ok "ccr drops all capabilities" || bad "ccr does not cap_drop ALL"
awk '/^  ccr:/{c=1} c&&/^  [a-z]/&&!/^  ccr:/{c=0} c&&/no-new-privileges:true/{ok=1} END{exit ok?0:1}' "$AI" \
  && ok "ccr sets no-new-privileges" || bad "ccr is missing no-new-privileges:true"
have 'PUID: \$\{USER_ID' "$AI" && ok "ccr is told the host uid via PUID" || bad "ccr PUID is not wired to USER_ID"
have 'exec gosu' stack-ai/ccr/ccr-entrypoint-wrapper.sh && ok "ccr wrapper gosu-drops to the run user" || bad "ccr wrapper does not drop privileges"
have 'gosu' stack-ai/ccr/Dockerfile.ccr && ok "Dockerfile.ccr installs gosu" || bad "Dockerfile.ccr does not install gosu"
have '^USER root' stack-ai/ccr/Dockerfile.ccr && bad "Dockerfile.ccr pins USER root" \
  || ok "Dockerfile.ccr does not pin the runtime to root"

echo "== MCP services stay unprivileged and internal =="
# searxng + mcp-gateway are new network surface: hold them to the same bar as
# ccr (no capabilities, no privilege escalation) and keep them off
# bastion-transit - nothing in the MCP layer talks cross-stack.
for svc in searxng mcp-gateway; do
  awk -v s="$svc" '$0 ~ ("^  " s ":") {c=1; next} c && /^  [a-z]/ {c=0} c && /cap_drop:/ {d=1} c && d && /- ALL/ {ok=1} END {exit ok?0:1}' "$AI" \
    && ok "$svc drops all capabilities" || bad "$svc does not cap_drop ALL"
  awk -v s="$svc" '$0 ~ ("^  " s ":") {c=1; next} c && /^  [a-z]/ {c=0} c && /no-new-privileges:true/ {ok=1} END {exit ok?0:1}' "$AI" \
    && ok "$svc sets no-new-privileges" || bad "$svc is missing no-new-privileges:true"
  awk -v s="$svc" '$0 ~ ("^  " s ":") {c=1; next} c && /^  [a-z]/ {c=0} c && /^      transit:/ {t=1} END {exit t?1:0}' "$AI" \
    && ok "$svc stays off bastion-transit" || bad "$svc joins bastion-transit (MCP layer is internal-only)"
done
# Host exposure: only CCR's UI (3458) and the MCP gateway (8811) may be
# published in stack-ai; searxng in particular has no host port at all.
extra=$(grep -E '^[[:space:]]+- "[0-9]+:' "$AI" | grep -vE '"(3458|8811):' || true)
[ -z "$extra" ] && ok "stack-ai publishes only 3458 (CCR) and 8811 (MCP gateway)" \
  || bad "unexpected published port(s) in stack-ai: $(printf '%s' "$extra" | head -2 | paste -sd'; ' -)"
# mcp-searxng dies on a 403 unless the instance serves the JSON format.
# SearXNG compares short format names (`json`), not MIME types.
have '^\s*-\s*json\s*$' stack-ai/config/searxng/settings.yml \
  && ok "searxng settings enable JSON output" || bad "searxng settings do not enable json output"
# The SearXNG image declares a VOLUME over /etc/searxng: a single-file bind
# under it is shadowed and the settings silently never load - the directory
# itself must be bind-mounted.
have '\./config/searxng:/etc/searxng:ro' "$AI" \
  && ok "searxng settings are bind-mounted as a directory" || bad "searxng settings not directory-mounted (image VOLUME would shadow a file bind)"
# Both MCP services run with a read-only rootfs (plus tmpfs /tmp) and a
# pinned unprivileged user.
for svc in searxng mcp-gateway; do
  awk -v s="$svc" '$0 ~ ("^  " s ":") {c=1; next} c && /^  [a-z]/ {c=0} c && /^    read_only: true/ {ok=1} END {exit ok?0:1}' "$AI" \
    && ok "$svc runs with a read-only rootfs" || bad "$svc is missing read_only: true"
done
have '^\s*user: "977:977"' "$AI" \
  && ok "searxng runs as the image's unprivileged 977 user" || bad "searxng has no pinned unprivileged user"
have '^USER 1000:1000' stack-ai/mcp-gateway/Dockerfile.mcp-gateway \
  && ok "mcp-gateway image pins USER 1000:1000" || bad "mcp-gateway image does not pin an unprivileged USER"

echo "== agent-docker is opt-in, Sysbox-isolated and internal =="
# Everything in the agent-docker service block, one line per entry.
ad=$(awk '/^  agent-docker:/{c=1; next} c && /^  [a-z]/{c=0} c' "$AI")
grep -qE '^\s*profiles: \["agent-docker"\]' <<<"$ad" \
  && ok "agent-docker carries the 'agent-docker' compose profile (opt-in)" \
  || bad "agent-docker is missing profiles: [\"agent-docker\"] - it would start by default"
grep -qE '^\s*runtime: sysbox-runc\s*$' <<<"$ad" \
  && ok "agent-docker runs on the sysbox-runc runtime" || bad "agent-docker is not on runtime: sysbox-runc"
# A privileged dind is root on the host: the whole design rests on never
# needing it.
grep -qE '^\s*privileged:' <<<"$ad" \
  && bad "agent-docker sets privileged: - Sysbox exists precisely so it never has to" \
  || ok "agent-docker is not privileged"
grep -qE '^\s*ports:' <<<"$ad" \
  && bad "agent-docker publishes a host port (its daemon is bastion-ai internal)" \
  || ok "agent-docker publishes no host port"
grep -qE '^      transit:' <<<"$ad" \
  && bad "agent-docker joins bastion-transit" || ok "agent-docker stays off bastion-transit"
grep -qE '^\s*DOCKER_TLS_CERTDIR: /certs\s*$' <<<"$ad" \
  && ok "agent-docker serves its API over mutual TLS" || bad "agent-docker has no DOCKER_TLS_CERTDIR (API would be plaintext 2375)"
# The server cert SAN comes from the hostname; it must match DOCKER_HOST.
grep -qE '^\s*hostname: agent-docker\s*$' <<<"$ad" \
  && have 'DOCKER_HOST: tcp://agent-docker:2376' "$AI" \
  && have 'DOCKER_TLS_VERIFY: "1"' "$AI" \
  && ok "bridge verifies TLS against the sidecar's certificate hostname" \
  || bad "agent-docker hostname / bridge DOCKER_HOST / DOCKER_TLS_VERIFY out of sync"
# Only the repos are shared with builds, at the bridge's own path - never the
# bridge's whole /data (agent config + auth live there).
grep -qE '^\s*source: \./data/codedeck/workspaces\s*$' <<<"$ad" \
  && grep -qE '^\s*target: /data/workspaces\s*$' <<<"$ad" \
  && ok "agent-docker shares only data/codedeck/workspaces, at the bridge's path" \
  || bad "agent-docker workspace bind is not ./data/codedeck/workspaces -> /data/workspaces"
grep -qE '^\s*- \./data/codedeck:' <<<"$ad" \
  && bad "agent-docker mounts the bridge's whole data dir" || ok "agent-docker cannot see the bridge's credentials"
grep -qE '^\s*image: docker:[0-9.]+-dind@sha256:[0-9a-f]{64}\s*$' <<<"$ad" \
  && ok "agent-docker image is a digest-pinned docker:<version>-dind" || bad "agent-docker image is not a digest-pinned dind"
# The CLI gate: ./bastion must refuse to start the sidecar without Sysbox.
grep -q '"sysbox-runc"' bastion && grep -q 'preflight_agent_docker || return 1' bastion \
  && ok "./bastion refuses --with-agent-docker without sysbox-runc" || bad "./bastion has no Sysbox preflight for agent-docker"

echo "== MCP gateway builds are reproducible =="
# npm children install from a committed lockfile (hash-verified by npm ci),
# never from a floating `npm install`.
have 'npm ci' stack-ai/mcp-gateway/Dockerfile.mcp-gateway \
  && ok "mcp-gateway npm layer installs via npm ci" || bad "mcp-gateway npm layer does not use npm ci"
[ -f stack-ai/mcp-gateway/package-lock.json ] \
  && grep -q '"lockfileVersion"' stack-ai/mcp-gateway/package-lock.json \
  && ok "npm children have a committed lockfile" || bad "stack-ai/mcp-gateway/package-lock.json is missing"
# Both base images are digest-pinned: a re-pushed tag cannot drift a rebuild.
have '^FROM node:.*@sha256:[0-9a-f]{64}' stack-ai/mcp-gateway/Dockerfile.mcp-gateway \
  && ok "mcp-gateway node base is digest-pinned" || bad "mcp-gateway node base is not digest-pinned"
have '^FROM python:.*@sha256:[0-9a-f]{64}' stack-ai/mcp-gateway/Dockerfile.mcp-gateway \
  && ok "mcp-gateway python base is digest-pinned" || bad "mcp-gateway python base is not digest-pinned"
# The Python layer installs under the committed constraints snapshot.
have 'pip install.*-c /tmp/constraints.txt' stack-ai/mcp-gateway/Dockerfile.mcp-gateway \
  && ok "mcp-gateway Python layer uses the constraints snapshot" || bad "mcp-gateway Python layer ignores constraints.txt"

echo "== Every service has the production defaults =="
# Prints "<stack> <service> <key>" for each service that lacks the line
# matching <regex> inside its own block (4-space-indented keys).
_missing_in_service() {
  local regex="$1" f
  for f in stack-*/docker-compose.yml; do
    awk -v re="$regex" -v st="${f%%/*}" '
      /^[a-z]/ { in_s = ($0 ~ /^services:/); next }
      in_s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (svc != "" && !hit) print st, svc; svc=$1; sub(/:$/,"",svc); hit=0; next }
      in_s && $0 ~ re { hit=1 }
      END { if (svc != "" && !hit) print st, svc }
    ' "$f"
  done
}
m=$(_missing_in_service '^    logging: [*]logging')
[ -z "$m" ] && ok "every service rotates its logs (logging: *logging)" \
  || bad "no log rotation on: $(printf '%s' "$m" | paste -sd, -)"
m=$(_missing_in_service '^    restart: unless-stopped')
[ -z "$m" ] && ok "every service restarts unless-stopped (so ./bastion stop sticks)" \
  || bad "restart policy is not unless-stopped on: $(printf '%s' "$m" | paste -sd, -)"

echo "== Submodule tracking =="
have 'branch = bastion-integration' .gitmodules && ok ".gitmodules tracks rust-teos bastion-integration" \
  || bad ".gitmodules does not pin rust-teos to bastion-integration"

echo "== Line endings (LF only, per .gitattributes) =="
# A file committed with CRLF stays CRLF until renormalised - eol=lf only governs
# checkout. Config files in particular ship into Linux containers. Check the
# index bytes of every tracked text file outside the submodule.
crlf=""
while IFS= read -r f; do
  case "$f" in rust-teos/*) continue ;; esac
  git show ":$f" 2>/dev/null | grep -qU $'\r' && crlf="$crlf $f"
done < <(git ls-files ':!:*.png' ':!:*.ico')
[ -z "$crlf" ] && ok "no tracked file has CRLF line endings" \
  || bad "CRLF line endings in the index:$crlf (run: git add --renormalize .)"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mall %d checks passed\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
