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

echo "== as root: chowns then gosu-drops to PUID/PGID =="
# stub id/chown/gosu so we can watch the root path without actually being root.
# The chown loop only fires for paths that exist, so make one.
mkdir -p "$SECRET_ROOT/data"
CHOWNABLE="$SECRET_ROOT/data"
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$BIN/id"; chmod +x "$BIN/id"
printf '#!/bin/sh\necho "chown $*" >> "%s"\n'                        "$BIN/calls" > "$BIN/chown"; chmod +x "$BIN/chown"
printf '#!/bin/sh\necho "gosu $1" >> "%s"; shift; exec "$@"\n'       "$BIN/calls" > "$BIN/gosu";  chmod +x "$BIN/gosu"
: > "$BIN/calls"
# point one chown target at our fixture dir so we can prove the loop runs
sed "s#/data /app#$CHOWNABLE /app#" "$WRAP" > "$BIN/wrap3"
out=$(timeout 5 env PATH="$BIN:$PATH" PUID=1234 PGID=5678 CCR_TOKEN_REFRESH=0 sh "$BIN/wrap3" 2>&1)
calls=$(cat "$BIN/calls")
assert_contains "$calls" "chown -R 1234:5678 $CHOWNABLE" "chowns an existing writable path to PUID:PGID"
assert_contains "$calls" "gosu 1234:5678"                "drops to PUID:PGID via gosu"
assert_contains "$out"   "CCR-STARTED"                   "still hands off to the upstream entrypoint"
rm -f "$BIN/id" "$BIN/chown" "$BIN/gosu"

finish
