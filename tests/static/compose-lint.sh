#!/usr/bin/env bash
###############################################################################
# Bastion - Compose file lint
#
# `docker compose config` fully parses and validates each stack's compose file
# (schema, interpolation, network/volume references). Needs a Docker CLI with
# the compose plugin; does not start anything.
###############################################################################
set -u
cd "$(dirname "$0")/.." || exit 1

# Provide values for the ${VARS} the compose files interpolate so `config`
# doesn't warn about unset ones. Real values come from bastion.conf at runtime.
export TIMEZONE=UTC PIHOLE_PASSWORD=x WIREGUARD_SERVERURL=example WIREGUARD_SERVERPORT=51820 \
       WIREGUARD_PEERS=1 USER_ID=1000 GROUP_ID=1000 NODE_ALIAS=ci \
       CCR_WEB_AUTH_TOKEN=x CLAUDE_CODE_OAUTH_TOKEN=x GITHUB_TOKEN=x \
       CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 \
       CODEDECK_TOR_PROXY_URL=socks5h://tor:9050 \
       CCR_TOKEN_REFRESH=1 CCR_REFRESH_INTERVAL=300 CCR_REFRESH_SKEW_MS=1800000
export CODEDECK_RELAYS='' GIT_REPO='' GIT_USER='' GIT_EMAIL='' LXMF_ALLOWED_IDENTITY=''

fail=0
for s in stack-network stack-bitcoin stack-monitor stack-web stack-ai; do
  printf '  %-16s ' "$s"
  if err=$(docker compose -f "$s/docker-compose.yml" config -q 2>&1); then
    echo "ok"
  else
    echo "FAIL"; echo "$err" | sed 's/^/      /'; fail=1
  fi
done
exit $fail
