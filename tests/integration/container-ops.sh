#!/usr/bin/env bash
###############################################################################
# Bastion - per-container operations against a REAL container.
#
# Registers one throwaway container (tests/integration/copstest, project
# "bastion-copstest", own subnet, no ports, own container name) via the
# BASTION_EXTRA_CONTAINER_STACK hook and drives the real `./bastion` verbs
# against it - so the Docker-facing half of the container-ops layer is
# CI-verified. Nothing here can touch a running Bastion. ~30s. Self-cleaning.
###############################################################################
# chk() runs its argument through eval, so shellcheck can't see the vars it uses.
# shellcheck disable=SC2034
set -u
cd "$(dirname "$0")/../.." || exit 1

CF=tests/integration/copstest/docker-compose.yml
SVC=copstest-hub
CTR=bastion-copstest-hub
SCRATCH=$(mktemp -d)

export BASTION_EXTRA_CONTAINER_STACK="${SVC}=tests/integration/copstest"
export BASTION_SKIP_ENV_LINKS=1
export CONFIG_FILE="$SCRATCH/bastion.conf"
B() { ./bastion "$@" </dev/null; }

cleanup() {
  docker compose -f "$CF" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1  <<$2>>"; fi; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = true ]; }
wait_running() { local i; for i in $(seq 1 20); do running && return 0; sleep 1; done; return 1; }

echo "== bring up the isolated test container =="
if ! docker compose -f "$CF" up -d 2>&1; then echo "FAIL: could not start the test stack"; exit 1; fi
wait_running || { echo "FAIL: test container never came up"; exit 1; }

echo "== ./bastion ps still works (lists the real stacks) =="
out=$(B ps 2>&1); rc=$?
chk "ps exits 0"                       '[ "$rc" -eq 0 ]'
chk "ps prints the header + a real service" '[[ "$out" == *CONTAINER* && "$out" == *lightningd* ]]'

echo "== ./bastion exec =="
out=$(B exec "$SVC" -- nginx -v 2>&1)
chk "exec runs a command inside the container"  '[[ "$out" == *"nginx version"* ]]'
out=$(B exec "$SVC" sh -c "echo from-\$(hostname)" 2>&1)
chk "exec works without the -- separator"       '[[ "$out" == *"from-"* ]]'

echo "== ./bastion shell (non-interactive stdin) =="
out=$(printf 'echo shell-ok; exit\n' | ./bastion shell "$SVC" 2>&1)
chk "shell drops into a working shell"          '[[ "$out" == *shell-ok* ]]'

echo "== ./bastion logs (bounded) =="
out=$(timeout 6 bash -c "./bastion logs $SVC </dev/null" 2>&1 || true)
chk "logs streams the container log"            '[ -n "$out" ]'

echo "== restart / stop / start =="
id1=$(docker inspect -f '{{.Id}}' "$CTR")
B restart "$SVC" >/dev/null 2>&1; wait_running
chk "restart leaves the container running"      'running'
chk "restart keeps the same container id"       '[ "$(docker inspect -f "{{.Id}}" "$CTR")" = "$id1" ]'
B stop "$SVC" >/dev/null 2>&1
chk "stop stops the container"                  '! running'
B start "$SVC" >/dev/null 2>&1; wait_running
chk "start starts it again"                     'running'

echo "== unknown container is rejected =="
out=$(B restart definitely-not-a-container 2>&1); rc=$?
chk "restart <unknown> errors, exits non-zero"  '[ "$rc" -ne 0 ] && [[ "$out" == *usage:* ]]'

echo
[ "$fail" -eq 0 ] && { echo -e "\033[32mcontainer ops verified against a real container\033[0m"; exit 0; }
echo -e "\033[31m$fail check(s) failed\033[0m"; exit 1
