#!/bin/bash

# ==============================================================================
# BASTION Node - Amboss Health Check  (opt-in)
# ==============================================================================
# Sends a CLN-signed heartbeat to Amboss.space over Tor. Every step runs INSIDE
# the already-running `lightningd` container, so the host needs only Docker -
# no `jq`, no `curl`, and no published Tor port (the proxied HTTPS call goes out
# through Tor on bastion-transit at 10.254.0.2:9050).
#
# This is opt-in and NOT wired into `./bastion up`. Schedule it yourself, e.g.
#   */5 * * * *  cd /path/to/bastion && ./stack-bitcoin/scripts/amboss-healthcheck.sh
# or set ENABLE_AMBOSS_HEARTBEAT=true for services/bastion-daemon.sh.
# ==============================================================================

set -u

AMBOSS_URL="${AMBOSS_URL:-https://api.amboss.space/graphql}"
CLN_CONTAINER="${CLN_CONTAINER:-lightningd}"
# In-container SOCKS proxy: the tor container's pinned bastion-transit address.
TOR_PROXY="${TOR_PROXY:-socks5h://10.254.0.2:9050}"

# --- 1. ISO 8601 UTC timestamp ---
NOW=$(date -u +%Y-%m-%dT%H:%M:%S%z)

# --- 2. Sign it with CLN (flat -F output; no jq) ---
SIGNATURE=$(MSYS_NO_PATHCONV=1 docker exec "$CLN_CONTAINER" \
    lightning-cli -F signmessage "$NOW" 2>/dev/null | sed -n 's/^zbase=//p')

if [ -z "$SIGNATURE" ]; then
    echo "[ERROR] Could not sign with CLN - is '$CLN_CONTAINER' running?"
    exit 1
fi

# --- 3. GraphQL body (zbase + ISO timestamp are safe to inline verbatim) ---
JSON_PAYLOAD=$(printf '{"query":"mutation HealthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }","variables":{"signature":"%s","timestamp":"%s"}}' "$SIGNATURE" "$NOW")

# --- 4. POST it, proxied through Tor, from inside the container ---
RESPONSE=$(printf '%s' "$JSON_PAYLOAD" | MSYS_NO_PATHCONV=1 docker exec -i "$CLN_CONTAINER" \
    curl -s --proxy "$TOR_PROXY" \
      -H "Content-Type: application/json" \
      --data-binary @- -X POST "$AMBOSS_URL")

# --- 5. Verify ---
case "$RESPONSE" in
    *'"healthCheck":true'*)
        echo "[SUCCESS] Heartbeat accepted by Amboss ($NOW)" ;;
    *)
        echo "[FAILED] Amboss returned an unexpected response:"
        echo "$RESPONSE"
        exit 1 ;;
esac
