#!/usr/bin/env bash
###############################################################################
# Bastion weekly tier - do the container images still build?
#
# Plain `docker build` (no --push, no registry, no cache export): catches a
# Dockerfile that broke because a pinned base moved, a build dep vanished, or a
# submodule / fork branch went bad. Nothing is kept - the images are local to
# the run.
#
# Dockerfile.lightningd builds five CLN plugins from source (~15 min); that is
# why this is weekly, not per-push. rust-teos needs the submodule checked out.
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1

rc=0
build() { # label  docker-build-args...
  local label="$1"; shift
  echo; echo "=== build: $label ==="
  if docker build "$@"; then echo "  ok: $label"; else echo "  FAILED: $label"; rc=1; fi
}

build "stack-network/Dockerfile.tor" \
  -f stack-network/Dockerfile.tor -t bastion-weekly/tor:ci stack-network

build "stack-bitcoin/Dockerfile.lightningd" \
  -f stack-bitcoin/Dockerfile.lightningd -t lightningd-custom:latest stack-bitcoin

build "stack-ai/Dockerfile.ccr" \
  -f stack-ai/Dockerfile.ccr -t bastion-weekly/ccr:ci stack-ai

if [ -e rust-teos/docker/Dockerfile ]; then
  build "rust-teos/docker/Dockerfile (teosd)" \
    -f rust-teos/docker/Dockerfile -t bastion-weekly/teosd:ci rust-teos
else
  echo; echo "=== build: teosd - SKIP (rust-teos submodule not checked out) ==="
fi

echo
[ "$rc" -eq 0 ] && echo "all images built" || echo "one or more image builds FAILED"
exit $rc
