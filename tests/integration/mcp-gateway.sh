#!/usr/bin/env bash
###############################################################################
# Bastion - MCP gateway end-to-end.
#
# Drives the stack-ai MCP gateway exactly the way a remote agent would: an
# official MCP SDK client (independent of fastmcp) connects to the
# Streamable HTTP endpoint and exercises auth (missing / wrong / query-param
# / correct token), healthz, tool namespacing, and a real call on every
# namespace (SearXNG, Context7, memory, time).
#
# Isolated throwaway project (bastion-mcptest): distinct container names, its
# own network + volume, NO published host ports, `down -v` cleanup. Builds
# the real stack-ai gateway image and binds the real SearXNG settings
# template, so the shipped wiring is what gets tested. Needs Docker +
# internet (npm/pip pulls + the context7 API). ~3-4 min when uncached.
###############################################################################
set -u
cd "$(dirname "$0")/mcptest" || exit 1

CF=docker-compose.yml
GW=bastion-mcptest-gateway
CL=bastion-mcptest-client

cleanup() {
  docker compose -f "$CF" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f test_mcp_gateway_token
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
dex() { MSYS_NO_PATHCONV=1 docker exec "$@"; }   # keep /container/paths intact on Git Bash

echo "== build the gateway image from stack-ai =="
if ! docker compose -f "$CF" build mcp-gateway >/dev/null 2>&1; then
  echo "FAIL: gateway image build"; exit 1
fi
ok "gateway image builds"

echo "== bring up the throwaway project (no host ports) =="
# The token file must be host-world-readable: compose file-secrets are plain
# bind mounts (uid/gid/mode are ignored outside swarm), so the source file's
# host permissions carry into the container verbatim. The gateway's uid 1000
# has to read it. Throwaway random value, lifetime of this test only.
printf '%s' "e2e-$(date +%s)-$RANDOM-token" > test_mcp_gateway_token
chmod 644 test_mcp_gateway_token
if ! docker compose -f "$CF" up -d 2>&1; then echo "FAIL: compose up"; exit 1; fi
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$GW" 2>/dev/null)" = healthy ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$GW" 2>/dev/null)" = healthy ] \
  && ok "gateway reaches healthy (its own healthcheck, token-authenticated)" \
  || { echo "FAIL: gateway never became healthy"; docker logs "$GW" | tail -5; exit 1; }

echo "== the gateway read its bearer token from the secret file =="
case "$(docker inspect -f '{{json .Config.Env}}' "$GW")" in
  *e2e-*token*) bad "token value leaked into docker inspect env" ;;
  *)            ok "token value absent from docker inspect env" ;;
esac

echo "== install the official MCP SDK in the client (independent of fastmcp) =="
if ! dex "$CL" pip install -q "mcp>=2" httpx 2>/dev/null; then
  echo "FAIL: client SDK install"; exit 1
fi

echo "== run the e2e suite =="
if dex "$CL" python /e2e.py "$(cat test_mcp_gateway_token)"; then
  ok "official SDK client: auth, healthz, namespacing, and all four namespaces"
else
  bad "official SDK client e2e (see output above)"
fi

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mall %d checks passed\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
