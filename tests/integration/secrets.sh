#!/usr/bin/env bash
###############################################################################
# Bastion - secrets are delivered as a mounted file, never as an env var.
#
# Proves the Phase-5 mechanism end to end against a real container: a random
# value written to a `file:` secret shows up at /run/secrets/<name> inside the
# container but is absent from `docker inspect`'s environment. Isolated
# throwaway project (bastion-sectest). ~15s. Self-cleaning.
###############################################################################
set -u
cd "$(dirname "$0")/sectest" || exit 1

CF=docker-compose.yml
CTR=bastion-sectest-probe
SECRET_VALUE="sekret-$(date +%s)-$RANDOM"

cleanup() {
  docker compose -f "$CF" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f test_secret
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
dex() { MSYS_NO_PATHCONV=1 docker exec "$@"; }   # keep /container/paths intact on Git Bash

umask 177; printf '%s' "$SECRET_VALUE" > test_secret; chmod 600 test_secret

echo "== bring up the probe with a file: secret =="
if ! docker compose -f "$CF" up -d 2>&1; then echo "FAIL: compose up"; exit 1; fi
for _ in $(seq 1 20); do
  [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = true ] && break; sleep 1
done

echo "== the secret is readable inside the container =="
got=$(dex "$CTR" cat /run/secrets/test_secret 2>/dev/null)
[ "$got" = "$SECRET_VALUE" ] && ok "/run/secrets/test_secret holds the value" \
  || bad "/run/secrets/test_secret = [$got], expected [$SECRET_VALUE]"

echo "== the secret is NOT in the container environment =="
env_json=$(docker inspect -f '{{json .Config.Env}}' "$CTR")
case "$env_json" in
  *"$SECRET_VALUE"*) bad "the secret value leaked into .Config.Env" ;;
  *)                 ok "docker inspect .Config.Env does not contain the secret" ;;
esac
# sanity: a real env var IS visible, so the negative check above means something
case "$env_json" in
  *"HARMLESS_ENV"*) ok "a normal env var is visible in .Config.Env (control)" ;;
  *)               bad "control env var missing - the inspection is not working" ;;
esac
# and it is not in the running process environment either
if dex "$CTR" cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep -q "$SECRET_VALUE"; then
  bad "the secret value is present in /proc/1/environ"
else
  ok "the secret value is not in /proc/1/environ"
fi

echo
[ "$fail" -eq 0 ] && { echo -e "\033[32msecret delivered as a file, absent from the environment\033[0m"; exit 0; }
echo -e "\033[31m$fail check(s) failed\033[0m"; exit 1
