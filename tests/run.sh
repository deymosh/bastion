#!/usr/bin/env bash
###############################################################################
# Bastion test runner.
#
#   ./tests/run.sh                 # static + unit (no Docker daemon needed)
#   ./tests/run.sh --all           # + integration (needs Docker + network)
#   ./tests/run.sh static|unit|integration|weekly
#
# The static and unit tiers run their steps concurrently (each step uses its
# own scratch dirs and mocks) and print every step's output in order once the
# tier finishes. TESTS_SERIAL=1 runs them one by one with live output.
# Integration and weekly steps share Docker state and always run serially.
#
# weekly = image builds + a real-config CLN boot; slow, run by the weekly
# workflow (or on demand), not on every push. See tests/README.md.
###############################################################################
set -u
cd "$(dirname "$0")/.." || exit 1

want="${1:-default}"
rc=0

# Serial step: live output, then its duration.
step() {
  local name=$1 t0=$SECONDS; shift
  echo; echo "=== $name ==="
  "$@" || { rc=1; echo "  ^ FAILED"; }
  echo "  ($((SECONDS - t0))s)"
}

# Concurrent steps: queue with `pstep name cmd...`, then `pflush` runs the
# queue in parallel and replays each step's captured output in queue order.
P_NAMES=(); P_CMDS=()
pstep() {
  if [ "${TESTS_SERIAL:-0}" = 1 ]; then step "$@"; return; fi
  P_NAMES+=("$1"); shift
  P_CMDS+=("$(printf '%q ' "$@")")
}
pflush() {
  [ "${#P_NAMES[@]}" -gt 0 ] || return 0
  local dir i t0
  dir=$(mktemp -d)
  for i in "${!P_NAMES[@]}"; do
    ( t0=$SECONDS
      eval "${P_CMDS[$i]}" > "$dir/$i.out" 2>&1
      echo "$? $((SECONDS - t0))" > "$dir/$i.rc" ) &
  done
  wait
  for i in "${!P_NAMES[@]}"; do
    local code secs
    read -r code secs < "$dir/$i.rc"
    echo; echo "=== ${P_NAMES[$i]} ==="
    cat "$dir/$i.out"
    [ "$code" -eq 0 ] || { rc=1; echo "  ^ FAILED"; }
    echo "  (${secs}s)"
  done
  rm -rf "$dir"
  P_NAMES=(); P_CMDS=()
}

node_test() {
  if command -v node >/dev/null 2>&1; then node --test "$@"
  else MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/r" -w /r node:22-slim node --test "$@"; fi
}

run_static() {
  pstep "shell lint"        bash tests/static/shell-lint.sh
  pstep "yaml lint"         bash tests/static/yaml-lint.sh
  pstep "config invariants" bash tests/static/validate-config.sh
  pstep "compose lint"      bash tests/static/compose-lint.sh
}

run_unit() {
  pstep "config.sh"               bash tests/unit/config-sh.test.sh
  pstep "bastion CLI"             bash tests/unit/bastion-cli.test.sh
  pstep "tui.sh (headless)"       bash tests/unit/tui.test.sh
  pstep "amboss healthcheck"      bash tests/unit/amboss-healthcheck.test.sh
  pstep "ccr entrypoint wrapper"  bash tests/unit/ccr-wrapper.test.sh
  pstep "sysbox installer checks" bash tests/unit/install-sysbox.test.sh
  pstep "daemon SCB backup"       bash tests/unit/bastion-daemon.test.sh
  pstep "ccr token refresher"     node_test tests/unit/ccr-refresher.test.mjs
}

run_integration() {
  step "hidden-service reachability" bash tests/integration/hidden-service-reachability.sh
  step "per-container operations"    bash tests/integration/container-ops.sh
  step "secrets are mounted files"   bash tests/integration/secrets.sh
  step "MCP gateway end-to-end"      bash tests/integration/mcp-gateway.sh
  step "agent-docker end-to-end"     bash tests/integration/agent-docker.sh
}

run_weekly() {
  step "image builds"          bash tests/weekly/build-images.sh
  step "CLN real-config boot"  bash tests/weekly/cln-real-config.sh
}

# node_test is called from a subshell by pflush.
export -f node_test

t_start=$SECONDS
case "$want" in
  static)      run_static; pflush ;;
  unit)        run_unit; pflush ;;
  integration) run_integration ;;
  weekly)      run_weekly ;;
  --all|all)   run_static; run_unit; pflush; run_integration ;;
  default)     run_static; run_unit; pflush
               echo; echo "(integration tier skipped - pass --all; weekly tier: run.sh weekly)" ;;
  *) echo "usage: $0 [static|unit|integration|weekly|--all]"; exit 2 ;;
esac

echo
echo "(total $((SECONDS - t_start))s)"
[ "$rc" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit $rc
