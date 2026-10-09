#!/usr/bin/env bash
###############################################################################
# Bastion - CCR bundled plugins, end-to-end: on-demand OAuth refresh and the
# tool-schema sanitizer.
#
# Runs the real stack-ai CCR image (wrapper, bundled plugins, claude CLI)
# against a fake Anthropic that answers for both api.anthropic.com and
# platform.claude.com, behind a throwaway CA. The seeded login's access token
# is rejected with 401, as an expired one would be; its refresh token is
# accepted. A 200 at the client therefore proves the whole chain: upstream
# 401 -> core-gateway retry -> plugin -> official claude CLI refresh -> retry
# carries the new token. Then: the next request reuses the new token without
# another refresh, streaming works, the token survives a CCR restart, and a
# revoked login fails open (the client gets the original 401) and logs
# LOGIN NEEDED. The tool-schema sanitizer is checked at the same upstream:
# an unportable pattern and keyword are gone, a portable pattern stays, a
# CCR_DROP_TOOLS tool is dropped, and CCR serves from its single gateway
# runtime (no compatibility server in front).
#
# Isolated throwaway project (bastion-ccrtest): distinct container names, its
# own network + volume, NO published host ports, `down -v` cleanup. Needs
# Docker; building the CCR image (clones the pinned CCR commit) needs
# internet, ~5 min when uncached. No real credentials anywhere.
###############################################################################
set -u
cd "$(dirname "$0")/ccrtest" || exit 1

CF=docker-compose.yml
CCR=bastion-ccrtest-ccr
FAKE=bastion-ccrtest-fake-anthropic
# Pinned like the stage it comes from in Dockerfile.ccr; only used for openssl.
OPENSSL_IMAGE=node:26.10.0-bookworm@sha256:2aaae6d91f99fee84cfc92da9b52c22a185752d247746052bbc3f961e44478c6

cleanup() {
  docker compose -f "$CF" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf certs
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
dex() { MSYS_NO_PATHCONV=1 docker exec "$@"; }   # keep /container/paths intact on Git Bash
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

request() { dex "$CCR" node /test/request.mjs "$@"; }
stat_of() { dex "$FAKE" node -e "fetch('http://127.0.0.1:8080/stats').then(r=>r.json()).then(s=>console.log(JSON.stringify(s.$1)))"; }
wait_healthy() {
  local s=""
  for _ in $(seq 1 60); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$CCR" 2>/dev/null)
    [ "$s" = healthy ] && return 0
    sleep 2
  done
  echo "    ccr health: ${s:-missing}"; docker logs "$CCR" 2>&1 | tail -8
  return 1
}

echo "== throwaway CA + a certificate for both Anthropic hostnames =="
rm -rf certs && mkdir certs
if ! MSYS_NO_PATHCONV=1 docker run --rm -v "$(host_path "$PWD/certs"):/out" "$OPENSSL_IMAGE" sh -c '
    set -e; cd /out
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 1 -subj "/CN=bastion-ccrtest-ca" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=bastion-ccrtest" 2>/dev/null
    printf "subjectAltName=DNS:api.anthropic.com,DNS:platform.claude.com\nextendedKeyUsage=serverAuth\n" > ext
    openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 1 -extfile ext 2>/dev/null
    rm -f srv.csr ext ca.srl ca.key; chmod 644 *'; then
  echo "FAIL: certificate generation"; exit 1
fi
ok "certificates generated"

echo "== build the CCR image from stack-ai =="
if ! docker compose -f "$CF" build ccr >/dev/null 2>&1; then echo "FAIL: ccr image build"; exit 1; fi
ok "ccr image builds"

echo "== first start: CCR writes its configuration =="
docker compose -f "$CF" up -d >/dev/null 2>&1 || { echo "FAIL: compose up"; exit 1; }
for _ in $(seq 1 60); do
  dex "$CCR" test -f /data/.claude-code-router/config.sqlite 2>/dev/null && break
  sleep 2
done
# CCR writes the file at startup; give it a moment to finish the first save.
sleep 3

echo "== seed a Claude Code provider + a login whose access token is stale =="
dex -u 1000 "$CCR" node /test/seed.mjs >/dev/null || { echo "FAIL: seed"; exit 1; }
docker restart "$CCR" >/dev/null
wait_healthy && ok "ccr healthy with the seeded provider" || { echo "FAIL: ccr never became healthy"; exit 1; }
logs=$(docker logs "$CCR" 2>&1)
case "$logs" in *"enabled OAuth refresh plugin"*) ok "startup step registered the OAuth refresh plugin" ;;
  *) bad "startup step did not register the OAuth refresh plugin" ;; esac
case "$logs" in *"refresh registered with the core gateway"*) ok "CCR loaded the plugin and handed it to the core gateway" ;;
  *) bad "the plugin was not loaded" ;; esac

echo "== a request with the stale token is refreshed and succeeds =="
out=$(request)
case "$out" in "200 "*bastion-refresh-ok*) ok "client gets 200 after the upstream 401" ;; *) bad "first request: $out" ;; esac
[ "$(stat_of oauthPosts)" = 1 ] && ok "exactly one refresh, done by the claude CLI" || bad "refresh count: $(stat_of oauthPosts)"
[ "$(stat_of cliProbes)" -ge 1 ] 2>/dev/null   && ok "the CLI talked to Anthropic directly, ignoring CCR's settings.json routing"   || bad "the CLI's call never reached Anthropic (cliProbes=$(stat_of cliProbes))"
[ "$(stat_of bearers)" = '["fake-0","fake-1"]' ] \
  && ok "the retry carried the refreshed token" || bad "bearers seen: $(stat_of bearers)"
stored=$(dex "$CCR" node -e 'const c=require("/data/.claude/.credentials.json");console.log(c.claudeAiOauth.accessToken, c.claudeAiOauth.refreshToken, c.claudeAiOauth.rateLimitTier, c.organizationUuid)')
[ "$stored" = "sk-ant-oat01-fake-1 sk-ant-ort01-fake-1 default_claude_ai 11111111-1111-1111-1111-111111111111" ] \
  && ok "the credentials file holds the rotated pair, other keys intact" || bad "stored credentials: $stored"
case "$(docker logs "$CCR" 2>&1)" in *"[bastion-claude-oauth-refresh] refreshed"*) ok "the refresh is logged" ;; *) bad "no refresh log line" ;; esac

echo "== the tool-schema sanitizer runs in the core gateway =="
out=$(request tools)
case "$out" in "200 "*) ok "request with tools 200" ;; *) bad "tools request: $out" ;; esac
# Read the schema fields the provider received, not their JSON text.
seen() {
  dex "$FAKE" node -e "fetch('http://127.0.0.1:8080/stats').then(r=>r.json()).then(s=>{
    const tools = s.lastTools || [], art = tools.find(t => t.name === 'Artifact');
    const p = art ? art.input_schema.properties : {};
    console.log(JSON.stringify({ names: tools.map(t => t.name), unportable: p.file_paths?.items?.pattern ?? null,
      propertyNames: 'propertyNames' in (p.files ?? {}), portable: p.asset_ids?.items?.pattern ?? null }));
  })"
}
want='{"names":["Artifact","Read"],"unportable":null,"propertyNames":false,"portable":"^[0-9a-f]{32}$"}'
got=$(seen)
[ "$got" = "$want" ] \
  && ok "upstream got the cleaned tools: unportable pattern + keyword gone, portable pattern kept, CCR_DROP_TOOLS tool dropped" \
  || bad "tools seen upstream: $got"
case "$(docker logs "$CCR" 2>&1)" in
  *"compatibility gateway server"*) bad "CCR still puts its compatibility server in front of the core gateway" ;;
  *) ok "CCR serves from its single gateway runtime" ;; esac

echo "== later requests reuse the new token =="
out=$(request)
case "$out" in "200 "*bastion-refresh-ok*) ok "second request 200" ;; *) bad "second request: $out" ;; esac
out=$(request stream)
case "$out" in "200 "*message_stop*) ok "streaming request 200" ;; *) bad "streaming request: $out" ;; esac
[ "$(stat_of oauthPosts)" = 1 ] && ok "no further refresh" || bad "refresh count: $(stat_of oauthPosts)"

echo "== the refreshed login survives a CCR restart =="
docker restart "$CCR" >/dev/null
wait_healthy || bad "ccr unhealthy after restart"
out=$(request)
case "$out" in "200 "*bastion-refresh-ok*) ok "200 after restart, still no refresh" ;; *) bad "after restart: $out" ;; esac

echo "== a revoked login fails open =="
# A 401 within 30s of a refresh (recorded next to the credentials, so it
# spans processes and restarts) reuses the fresh token instead of running the
# CLI again; step outside that window so this 401 really reaches the CLI.
sleep 30
dex "$FAKE" node -e "fetch('http://127.0.0.1:8080/control/revoke')" >/dev/null
out=$(request)
case "$out" in "401 "*) ok "the client gets the original 401" ;; *) bad "revoked: $out" ;; esac
line=$(docker logs "$CCR" 2>&1 | grep "bastion-claude-oauth-refresh\] refresh failed" | tail -1)
case "$line" in *"refresh token was rejected"*"LOGIN NEEDED"*) ok "the log says a login is needed" ;;
  *) bad "failure log line: ${line:-none}" ;; esac
echo "    $line"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mall %d checks passed\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
