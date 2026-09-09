#!/usr/bin/env bash
###############################################################################
# Bastion - per-container operations against a REAL container.
#
# Brings up stack-web (just the nginx `hub`, no Tor, no secrets, port not
# published) and drives ./bastion ps / exec / logs / restart / stop / start /
# shell against it, so the Docker-facing half of the container-ops layer is
# CI-verified, not only operator-verified. ~30s. Self-cleaning.
###############################################################################
# chk() runs its argument through eval, so shellcheck can't see the vars it uses.
# shellcheck disable=SC2034
set -u
cd "$(dirname "$0")/../.." || exit 1

OVERRIDE=tests/integration/web-noport.override.yml
cat > "$OVERRIDE" <<'EOF'
services:
  hub:
    ports: !reset []
EOF

B() { BASTION_SKIP_ENV_LINKS=1 ./bastion "$@" </dev/null; }
cleanup() {
  docker compose -f stack-web/docker-compose.yml -f "$OVERRIDE" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$OVERRIDE"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1  <<$2>>"; fi; }

echo "== bring up the real hub container (no published port) =="
if ! docker compose -f stack-web/docker-compose.yml -f "$OVERRIDE" up -d 2>&1; then
  echo "FAIL: could not start stack-web"; exit 1
fi
for _ in $(seq 1 20); do
  [ "$(docker inspect -f '{{.State.Running}}' hub 2>/dev/null)" = true ] && break; sleep 1
done

echo "== ./bastion ps =="
out=$(B ps 2>&1)
chk "ps lists hub under stack-web running" '[[ "$out" == *"hub"*"running"*"stack-web"* ]]'

echo "== ./bastion exec =="
out=$(B exec hub -- nginx -v 2>&1)
chk "exec runs a command inside the container" '[[ "$out" == *"nginx version"* ]]'
out=$(B exec hub -- sh -c "echo from-\$(hostname)" 2>&1)
chk "exec without -- also works"              '[[ "$out" == *"from-"* ]]'

echo "== ./bastion shell (non-interactive stdin) =="
out=$(printf 'echo shell-ok; exit\n' | BASTION_SKIP_ENV_LINKS=1 ./bastion shell hub 2>&1)
chk "shell drops into a working shell"        '[[ "$out" == *"shell-ok"* ]]'

echo "== ./bastion logs (bounded) =="
out=$(timeout 6 bash -c 'BASTION_SKIP_ENV_LINKS=1 ./bastion logs hub </dev/null' 2>&1 || true)
chk "logs streams the container's log"        '[[ -n "$out" ]]'

echo "== restart / stop / start =="
id1=$(docker inspect -f '{{.Id}}' hub)
B restart hub >/dev/null 2>&1
for _ in $(seq 1 15); do [ "$(docker inspect -f '{{.State.Running}}' hub 2>/dev/null)" = true ] && break; sleep 1; done
chk "restart leaves hub running"              '[ "$(docker inspect -f "{{.State.Running}}" hub)" = true ]'
chk "restart is the same container (not recreated)" '[ "$(docker inspect -f "{{.Id}}" hub)" = "$id1" ]'
B stop hub >/dev/null 2>&1
chk "stop stops hub"                          '[ "$(docker inspect -f "{{.State.Running}}" hub)" = false ]'
B start hub >/dev/null 2>&1
for _ in $(seq 1 15); do [ "$(docker inspect -f '{{.State.Running}}' hub 2>/dev/null)" = true ] && break; sleep 1; done
chk "start starts hub again"                  '[ "$(docker inspect -f "{{.State.Running}}" hub)" = true ]'

echo "== unknown container is rejected =="
out=$(B restart no-such-ctr 2>&1); rc=$?
chk "restart <unknown> errors and exits non-zero" '[ "$rc" -ne 0 ] && [[ "$out" == *usage:* ]]'

echo
[ "$fail" -eq 0 ] && { echo -e "\033[32mcontainer ops verified against a real container\033[0m"; exit 0; }
echo -e "\033[31m$fail check(s) failed\033[0m"; exit 1
