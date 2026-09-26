#!/bin/sh
###############################################################################
# agent-docker entrypoint: publish this image's docker CLI to codedeck-bridge,
# then run the stock dind entrypoint unchanged.
#
# The bridge image ships no Docker packages. It mounts the shared
# agent_docker_cli volume read-only at /usr/local/libexec/docker (bin/ is on its
# PATH, cli-plugins/ is a default plugin directory of the CLI), so the agent's
# `docker`, `docker buildx` and `docker compose` are always the exact release
# of the daemon they talk to.
#
# Always re-copied at start: an image bump must never leave the bridge with a
# stale CLI. The copy is staged and then swapped in, so the bridge never sees
# a half-written binary.
###############################################################################
set -eu

cli=/cli
stage="$cli/.staging"

rm -rf "$stage"
mkdir -p "$stage/bin"
cp /usr/local/bin/docker "$stage/bin/docker"
cp -R /usr/local/libexec/docker/cli-plugins "$stage/cli-plugins"
rm -rf "${cli:?}/bin" "${cli:?}/cli-plugins"
mv "$stage/bin" "$stage/cli-plugins" "$cli/"
rmdir "$stage"

exec dockerd-entrypoint.sh "$@"
