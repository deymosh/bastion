#!/usr/bin/env bash
###############################################################################
# Bastion test runner.
#
#   ./tests/run.sh                 # static + unit (no Docker daemon needed)
#   ./tests/run.sh --all           # + integration (needs Docker + network)
#   ./tests/run.sh static|unit|integration
#
# See tests/README.md for the strategy and what each tier covers.
###############################################################################
set -u
cd "$(dirname "$0")/.." || exit 1

want="${1:-default}"
rc=0
step() { echo; echo "=== $1 ==="; shift; "$@" || { rc=1; echo "  ^ FAILED"; }; }

node_test() {
  if command -v node >/dev/null 2>&1; then node --test "$@"
  else docker run --rm -v "$PWD:/r" -w /r node:22-slim node --test "$@"; fi
}

run_static() {
  step "shell lint"        bash tests/static/shell-lint.sh
  step "yaml lint"         bash tests/static/yaml-lint.sh
  step "config invariants" bash tests/static/validate-config.sh
  step "compose lint"      bash tests/static/compose-lint.sh
}

run_unit() {
  step "config.sh"          bash tests/unit/config-sh.test.sh
  step "bastion CLI"        bash tests/unit/bastion-cli.test.sh
  step "ccr entrypoint wrapper" bash tests/unit/ccr-wrapper.test.sh
  step "ccr token refresher" node_test tests/unit/ccr-refresher.test.mjs
}

run_integration() {
  step "hidden-service reachability" bash tests/integration/hidden-service-reachability.sh
}

case "$want" in
  static)      run_static ;;
  unit)        run_unit ;;
  integration) run_integration ;;
  --all|all)   run_static; run_unit; run_integration ;;
  default)     run_static; run_unit
               echo; echo "(integration tier skipped - pass --all)" ;;
  *) echo "usage: $0 [static|unit|integration|--all]"; exit 2 ;;
esac

echo
[ "$rc" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit $rc
