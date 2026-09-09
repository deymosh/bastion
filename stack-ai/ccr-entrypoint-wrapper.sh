#!/bin/sh
# Bastion wrapper around the upstream CCR entrypoint.
#
# It does exactly one thing: optionally start the OAuth token refresher in the
# background, then hand off to the real entrypoint via exec. CCR always starts,
# regardless of whether any credentials exist yet - the refresher is a helper,
# never a gate. Set CCR_TOKEN_REFRESH=0 to skip it entirely.
set -eu

# The refresher ships next to this wrapper (both land in /usr/local/bin).
REFRESHER="$(dirname "$0")/ccr-token-refresher.mjs"

# CCR_WEB_AUTH_TOKEN is delivered as a mounted secret, not an env var, so it
# never shows up in `docker inspect`. Prefer the file; keep the env as a
# fallback so a half-applied upgrade (old compose, new image) still works.
if [ -r /run/secrets/ccr_web_auth_token ]; then
    CCR_WEB_AUTH_TOKEN="$(cat /run/secrets/ccr_web_auth_token)"
    export CCR_WEB_AUTH_TOKEN
fi

if [ "${CCR_TOKEN_REFRESH:-1}" = "1" ] && [ -f "$REFRESHER" ]; then
    echo "[ccr-entrypoint-wrapper] starting OAuth token refresher (idle until an OAuth credentials file appears)"
    node "$REFRESHER" &
else
    echo "[ccr-entrypoint-wrapper] OAuth token refresher disabled (CCR_TOKEN_REFRESH=${CCR_TOKEN_REFRESH:-1})"
fi

exec ccr-entrypoint "$@"
