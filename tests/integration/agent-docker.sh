#!/usr/bin/env bash
###############################################################################
# Bastion - agent-docker end-to-end.
#
# Brings up the agent-docker sidecar next to the real codedeck-bridge image
# (as its uid 1000, the way the agent runs) and proves the wiring the agent
# relies on:
#   - the sidecar publishes a working docker CLI + buildx/compose plugins
#   - the bridge reaches the daemon over mutual TLS, verified against the
#     certificate hostname; plaintext and cert-less clients are refused
#   - a project build container runs against the shared workspaces path and
#     its output lands back in the bridge's checkout
#   - nothing the agent builds or runs appears in the host's Docker
#   - on Sysbox: the sidecar is NOT privileged
#
# Runs on sysbox-runc when the daemon has it. Without Sysbox it falls back to
# a privileged sidecar for THIS throwaway test only, and says so - the
# wiring is still exercised, the isolation boundary is not. CI sets
# REQUIRE_SYSBOX=1, which turns that fallback into a failure.
#
# Isolated project (bastion-agentdockertest): no host ports, `down -v`
# cleanup. Needs Docker + internet (image pulls). ~1-2 min when uncached.
###############################################################################
set -u
cd "$(dirname "$0")/agentdocker" || exit 1

CF=docker-compose.yml
DAEMON=bastion-agentdockertest-daemon
BRIDGE=bastion-agentdockertest-bridge
PROBE=bastion-agentdocker-probe

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
dex() { MSYS_NO_PATHCONV=1 docker exec "$@"; }   # keep /container/paths intact on Git Bash

cleanup() {
  # Build output is owned by the bridge's uid 1000; remove it from inside so
  # the host user (any uid) can delete the directory afterwards.
  dex "$BRIDGE" sh -c 'rm -rf /data/workspaces/* 2>/dev/null' >/dev/null 2>&1 || true
  docker compose -f "$CF" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf workspaces 2>/dev/null || true
}
trap cleanup EXIT

# Pull the image pins out of stack-ai so the test runs exactly what ships.
svc_image() {
  awk -v s="$1" '$0 ~ ("^  " s ":") {c=1; next} c && /^  [a-z]/ {c=0} c && /^    image:/ {print $2; exit}' \
    ../../../stack-ai/docker-compose.yml
}
export AGENT_DOCKER_IMAGE BRIDGE_IMAGE
AGENT_DOCKER_IMAGE=$(svc_image agent-docker)
BRIDGE_IMAGE=$(svc_image codedeck-bridge)
[ -n "$AGENT_DOCKER_IMAGE" ] && [ -n "$BRIDGE_IMAGE" ] || { echo "FAIL: could not read image pins from stack-ai"; exit 1; }
want_version=${AGENT_DOCKER_IMAGE#docker:}; want_version=${want_version%%-dind*}

echo "== runtime =="
SYSBOX=0
case "$(docker info --format '{{json .Runtimes}}' 2>/dev/null)" in *'"sysbox-runc"'*) SYSBOX=1 ;; esac
if [ "$SYSBOX" = 1 ]; then
  export AGENT_DOCKER_TEST_RUNTIME=sysbox-runc AGENT_DOCKER_TEST_PRIVILEGED=false
  ok "sysbox-runc available - testing the real isolation boundary"
elif [ "${REQUIRE_SYSBOX:-0}" = 1 ]; then
  echo "FAIL: REQUIRE_SYSBOX=1 but this daemon has no sysbox-runc runtime"; exit 1
else
  export AGENT_DOCKER_TEST_RUNTIME=runc AGENT_DOCKER_TEST_PRIVILEGED=true
  printf '  \033[33mWARN\033[0m no sysbox-runc here: wiring only, sidecar runs PRIVILEGED for this test (never in Bastion)\n'
fi

echo "== bring up the throwaway project (no host ports) =="
mkdir -p workspaces && chmod 0777 workspaces   # the bridge's uid 1000 must write here
if ! docker compose -f "$CF" up -d >/dev/null 2>&1; then
  echo "FAIL: compose up"; docker compose -f "$CF" up -d; exit 1
fi
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$DAEMON" 2>/dev/null)" = healthy ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DAEMON" 2>/dev/null)" = healthy ] \
  && ok "sidecar daemon reaches healthy" \
  || { echo "FAIL: sidecar never became healthy"; docker logs "$DAEMON" 2>&1 | tail -15; exit 1; }

if [ "$SYSBOX" = 1 ]; then
  [ "$(docker inspect -f '{{.HostConfig.Runtime}} {{.HostConfig.Privileged}}' "$DAEMON")" = "sysbox-runc false" ] \
    && ok "sidecar runs on sysbox-runc and is NOT privileged" \
    || bad "sidecar runtime/privilege: $(docker inspect -f '{{.HostConfig.Runtime}} privileged={{.HostConfig.Privileged}}' "$DAEMON")"
fi

echo "== the agent's CLI (bridge image, uid 1000) =="
[ "$(dex "$BRIDGE" id -u)" = 1000 ] && ok "bridge runs as uid 1000" || bad "bridge uid is $(dex "$BRIDGE" id -u)"
# Client may be published a moment after the daemon starts answering.
for _ in $(seq 1 20); do dex "$BRIDGE" sh -c 'command -v docker' >/dev/null 2>&1 && break; sleep 1; done
got=$(dex "$BRIDGE" docker version --format '{{.Client.Version}} {{.Server.Version}}' 2>&1)
[ "$got" = "$want_version $want_version" ] \
  && ok "bridge CLI $want_version talks to daemon $want_version over verified TLS" \
  || bad "docker version from the bridge: $got"
dex "$BRIDGE" docker buildx version >/dev/null 2>&1 && ok "buildx plugin is available" || bad "docker buildx missing in the bridge"
dex "$BRIDGE" docker compose version >/dev/null 2>&1 && ok "compose plugin is available" || bad "docker compose missing in the bridge"

echo "== the daemon only accepts CA-signed clients =="
dex "$BRIDGE" curl -sf --max-time 5 http://agent-docker:2375/version >/dev/null 2>&1 \
  && bad "plaintext API on 2375 answers" || ok "no plaintext API (2375)"
dex "$BRIDGE" curl -sfk --max-time 5 https://agent-docker:2376/version >/dev/null 2>&1 \
  && bad "TLS API answers a client without a certificate" || ok "a client without the client cert is refused (2376)"

echo "== build and run a project toolchain container on the shared workspace =="
dex "$BRIDGE" sh -c 'mkdir -p /data/workspaces/proj && printf "FROM alpine:3.22\nRUN echo toolchain-ok > /opt/toolchain\n" > /data/workspaces/proj/Dockerfile'
if dex "$BRIDGE" docker build -q -t "$PROBE" /data/workspaces/proj >/dev/null 2>&1; then
  ok "docker build from the bridge's checkout"
else
  bad "docker build failed: $(dex "$BRIDGE" docker build -t "$PROBE" /data/workspaces/proj 2>&1 | tail -3)"
fi
dex "$BRIDGE" docker run --rm --user 1000:1000 -v /data/workspaces/proj:/src "$PROBE" \
  sh -c 'cat /opt/toolchain > /src/out.txt' >/dev/null 2>&1
[ "$(dex "$BRIDGE" cat /data/workspaces/proj/out.txt 2>/dev/null)" = toolchain-ok ] \
  && ok "build output written via -v /data/workspaces/... lands in the bridge's checkout" \
  || bad "bind-mounted build output did not reach the bridge"

echo "== nothing leaks into the host daemon =="
docker image inspect "$PROBE" >/dev/null 2>&1 \
  && bad "the agent's image is visible to the host daemon" || ok "the agent's image exists only in the sidecar"
[ -z "$(docker ps -aq --filter "ancestor=$PROBE")" ] \
  && ok "no agent container on the host daemon" || bad "agent containers visible on the host"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mall %d checks passed\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1; fi
