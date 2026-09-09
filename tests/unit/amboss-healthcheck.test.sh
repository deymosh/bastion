#!/usr/bin/env bash
###############################################################################
# stack-bitcoin/scripts/amboss-healthcheck.sh - every step must go through
# `docker exec lightningd` (no host jq / curl / Tor port), build a valid
# GraphQL body, and POST it via the transit Tor proxy.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

SCRIPT=stack-bitcoin/scripts/amboss-healthcheck.sh
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# a docker stub that logs every call and answers signmessage / curl
cat > "$WORK/docker" <<'EOF'
#!/usr/bin/env bash
{ printf 'docker'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$MOCK_LOG"
for a in "$@"; do
  case "$a" in
    signmessage) printf '%s\n' "${MOCK_SIG-zbase=ybndrfg8ejkmcpqxot1uwisza345h769}"; exit 0 ;;
    curl)        BODY=$(cat); printf '%s' "$BODY" > "$MOCK_BODY"
                 printf '%s\n' "${MOCK_RESP-{\"data\":{\"healthCheck\":true}}}"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$WORK/docker"
export PATH="$WORK:$PATH" MOCK_LOG="$WORK/log" MOCK_BODY="$WORK/body"

run() { : > "$MOCK_LOG"; : > "$MOCK_BODY"; env "$@" bash "$SCRIPT" 2>&1; }

echo "== the script carries no host jq / curl dependency =="
assert_ok test -z "$(grep -nE '(^|[^a-z])jq ' "$SCRIPT")"
grep -q 'docker exec -i "\$CLN_CONTAINER" \\' "$SCRIPT" && _t_ok "curl runs inside the container (docker exec -i)" \
  || _t_bad "curl is not run via docker exec -i"

echo "== happy path =="
out=$(run); rc=$?
assert_eq "$rc" 0 "exits 0 when Amboss accepts the heartbeat"
assert_contains "$out" "SUCCESS" "reports success"
assert_contains "$(cat "$MOCK_LOG")" "signmessage" "signs the timestamp via lightning-cli"
assert_contains "$(cat "$MOCK_LOG")" "[--proxy] [socks5h://10.254.0.2:9050]" "POSTs through the transit Tor proxy"
assert_contains "$(cat "$MOCK_LOG")" "[https://api.amboss.space/graphql]" "targets the Amboss GraphQL endpoint"
body=$(cat "$MOCK_BODY")
assert_contains "$body" 'healthCheck(signature: $signature, timestamp: $timestamp)' "sends the HealthCheck mutation"
assert_contains "$body" '"signature":"ybndrfg8ejkmcpqxot1uwisza345h769"' "inlines the zbase= -stripped signature"
# the body is valid JSON (skip where python is unavailable)
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
  printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    && _t_ok "GraphQL body is valid JSON" || _t_bad "GraphQL body is not valid JSON"
fi

echo "== failure paths =="
out=$(MOCK_SIG="" run); rc=$?
assert_eq "$rc" 1 "exits 1 when CLN cannot sign"
assert_contains "$out" "Could not sign" "explains the signing failure"
out=$(MOCK_RESP='{"errors":[{"message":"nope"}]}' run); rc=$?
assert_eq "$rc" 1 "exits 1 on an unexpected Amboss response"
assert_contains "$out" "FAILED" "reports the failure"

echo "== TOR_PROXY / endpoint stay overridable =="
run TOR_PROXY=socks5h://tor:9050 >/dev/null
assert_contains "$(cat "$MOCK_LOG")" "[socks5h://tor:9050]" "honours a TOR_PROXY override"

finish
