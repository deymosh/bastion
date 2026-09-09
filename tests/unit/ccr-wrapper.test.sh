#!/usr/bin/env bash
###############################################################################
# stack-ai/ccr-entrypoint-wrapper.sh must ALWAYS hand off to the upstream
# entrypoint (CCR runs with an OAuth login, a plain API key, or nothing);
# CCR_TOKEN_REFRESH only gates the background refresher.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

WRAP="$PWD/stack-ai/ccr-entrypoint-wrapper.sh"
BIN=$(mktemp -d); trap 'rm -rf "$BIN"' EXIT
printf '#!/bin/sh\necho "CCR-STARTED args=[$*]"\n'          > "$BIN/ccr-entrypoint"; chmod +x "$BIN/ccr-entrypoint"
printf '#!/bin/sh\necho "refresher-ran"; sleep 100\n'      > "$BIN/node";           chmod +x "$BIN/node"
export PATH="$BIN:$PATH"
cp stack-ai/ccr-token-refresher.mjs "$BIN/ccr-token-refresher.mjs" 2>/dev/null || true

echo "== default: refresher on, no credentials file =="
out=$(timeout 5 sh "$WRAP" --some-flag 2>&1)
assert_contains "$out" "CCR-STARTED args=[--some-flag]" "CCR starts and args pass through with no token"
assert_contains "$out" "starting OAuth token refresher"  "the refresher is started"

echo "== CCR_TOKEN_REFRESH=0 =="
out=$(timeout 5 env CCR_TOKEN_REFRESH=0 sh "$WRAP" 2>&1)
assert_contains "$out" "CCR-STARTED"                 "CCR still starts with the refresher disabled"
assert_contains "$out" "refresher disabled"          "the wrapper reports the refresher is off"
case "$out" in *"refresher-ran"*) _t_bad "refresher must NOT run when disabled" ;; *) _t_ok "refresher did not run" ;; esac

finish
