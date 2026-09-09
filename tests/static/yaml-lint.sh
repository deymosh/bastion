#!/usr/bin/env bash
###############################################################################
# Bastion - YAML lint (compose files + GitHub workflows + test compose)
###############################################################################
set -u
cd "$(dirname "$0")/../.." || exit 1

mapfile -t files < <(git ls-files '*.yml' '*.yaml' 2>/dev/null | grep -v '^rust-teos/')
[ "${#files[@]}" -eq 0 ] && { echo "no yaml files"; exit 0; }

# Relaxed rules: docker-compose files use long lines and no doc start marker.
CONF='{extends: relaxed, rules: {line-length: {max: 200}, comments: {min-spaces-from-content: 1}, truthy: {check-keys: false}}}'

if command -v yamllint >/dev/null 2>&1; then
  yamllint -d "$CONF" "${files[@]}"
elif command -v docker >/dev/null 2>&1; then
  docker run --rm -v "$PWD:/d:ro" -w /d cytopia/yamllint -d "$CONF" "${files[@]}"
else
  echo "yamllint not available (no yamllint binary, no docker) - skipped"
  exit 0
fi
