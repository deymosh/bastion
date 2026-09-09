#!/usr/bin/env bash
###############################################################################
# Bastion test runner
#
#   ./tests/run.sh            # fast tier: no Docker daemon needed
#   ./tests/run.sh --all      # also the Docker/compose and integration tiers
#
# Tiers:
#   fast         shell-lint, validate-config, ccr-refresher (node)
#   docker       compose-lint                       (needs docker CLI)
#   integration  hidden-service-reachability        (needs docker daemon, ~1m)
###############################################################################
set -u
cd "$(dirname "$0")/.."

ALL=0; [ "${1:-}" = "--all" ] && ALL=1
rc=0
run() { echo; echo "### $1"; shift; "$@" || rc=1; }

run "shell lint"        bash tests/shell-lint.sh
run "config invariants" bash tests/validate-config.sh

if command -v node >/dev/null 2>&1; then
  run "ccr refresher (node --test)" node --test tests/ccr-refresher.test.mjs
else
  echo; echo "### ccr refresher - skipped (no node); run: docker run --rm -v \"\$PWD:/r\" -w /r node:22-slim node --test tests/ccr-refresher.test.mjs"
fi

if [ "$ALL" -eq 1 ]; then
  run "compose lint"                 bash tests/compose-lint.sh
  run "hidden-service reachability"  bash tests/hidden-service-reachability.sh
else
  echo; echo "### docker + integration tiers skipped (pass --all)"
fi

echo
[ "$rc" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit $rc
