#!/bin/bash

# ==============================================================================
# BASTION Node - Amboss Health Check
# ==============================================================================
# Description: Sends a signed heartbeat to Amboss.space via Tor proxy.
# Requirements: jq, docker, tor-proxy (10.0.0.11)
# ==============================================================================

# --- Configuration ---
AMBOSS_URL="https://api.amboss.space/graphql"
TOR_PROXY="socks5h://10.0.0.11:9050"

# Replace 'clightning' with your actual container name if different
CLN_CONTAINER="clightning"

# --- 1. Generate ISO 8601 UTC Timestamp ---
NOW=$(date -u +%Y-%m-%dT%H:%M:%S%z)

# --- 2. Sign the Timestamp using CLN (inside Docker) ---
# We extract the 'zbase' field which is the standard for CLN signatures
SIGNATURE=$(docker exec $CLN_CONTAINER lightning-cli signmessage "$NOW" | jq -r .zbase)

# Check if signature was generated successfully
if [ -z "$SIGNATURE" ] || [ "$SIGNATURE" == "null" ]; then
    echo "[ERROR] Failed to sign message with CLN. Check if container is running."
    exit 1
fi

# --- 3. Construct GraphQL Mutation ---
JSON_PAYLOAD=$(jq -n \
  --arg sig "$SIGNATURE" \
  --arg ts "$NOW" \
  '{query: "mutation HealthCheck($signature: String!, $timestamp: String!) { healthCheck(signature: $signature, timestamp: $timestamp) }", variables: {signature: $sig, timestamp: $ts}}')

# --- 4. Send Request to Amboss via Tor Proxy ---
RESPONSE=$(echo "$JSON_PAYLOAD" | curl -s \
  --proxy "$TOR_PROXY" \
  --data-binary @- \
  -H "Content-Type: application/json" \
  -X POST \
  "$AMBOSS_URL")

# --- 5. Verify Response ---
if [[ "$RESPONSE" == *"healthCheck\":true"* ]]; then
    echo "[SUCCESS] Heartbeat accepted by Amboss ($NOW)"
else
    echo "[FAILED] Amboss returned an error or unexpected response."
    echo "Response: $RESPONSE"
    exit 1
fi