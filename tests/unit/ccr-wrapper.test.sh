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
# The stub exits at once - a long-lived background child would hold the
# command-substitution pipe open and hang the assertions.
printf '#!/bin/sh\necho "refresher-ran"\n'                 > "$BIN/node";           chmod +x "$BIN/node"
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

echo "== CCR_WEB_AUTH_TOKEN comes from the mounted secret =="
# ccr-entrypoint prints its env so we can inspect what the wrapper exported.
printf '#!/bin/sh\necho "CCR-STARTED token=[${CCR_WEB_AUTH_TOKEN:-<unset>}]"\n' > "$BIN/ccr-entrypoint"
chmod +x "$BIN/ccr-entrypoint"
SECRET_ROOT=$(mktemp -d); trap 'rm -rf "$BIN" "$SECRET_ROOT"' EXIT
mkdir -p "$SECRET_ROOT/run/secrets"
printf 'from-the-file' > "$SECRET_ROOT/run/secrets/ccr_web_auth_token"
# run the wrapper with / rebased so /run/secrets/... resolves into our fixture
if command -v fakechroot >/dev/null 2>&1; then :; fi
# simplest portable check: copy the wrapper, point the path at the fixture
sed "s#/run/secrets/ccr_web_auth_token#$SECRET_ROOT/run/secrets/ccr_web_auth_token#g" "$WRAP" > "$BIN/wrap2"
out=$(timeout 5 env CCR_TOKEN_REFRESH=0 CCR_WEB_AUTH_TOKEN=from-the-env sh "$BIN/wrap2" 2>&1)
assert_contains "$out" "token=[from-the-file]" "the mounted secret file wins over the env var"
case "$out" in *from-the-env*) _t_bad "the env-var value leaked into the log" ;; *) _t_ok "the secret value is not echoed" ;; esac
rm -f "$SECRET_ROOT/run/secrets/ccr_web_auth_token"
out=$(timeout 5 env CCR_TOKEN_REFRESH=0 CCR_WEB_AUTH_TOKEN=from-the-env sh "$BIN/wrap2" 2>&1)
assert_contains "$out" "token=[from-the-env]" "falls back to the env var when the secret file is absent"

finish
