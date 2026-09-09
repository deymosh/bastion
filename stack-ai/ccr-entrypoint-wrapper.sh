#!/bin/sh
# Bastion wrapper around the upstream CCR entrypoint.
#
# Starts the OAuth token refresher in the background (unless disabled), then
# hands off to the real entrypoint via exec so CCR stays PID 1's child and
# signal handling is unchanged.
set -eu

REFRESHER="/usr/local/bin/ccr-token-refresher.mjs"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/data/.claude}"

if [ "${CCR_TOKEN_REFRESH:-1}" = "1" ] && [ -f "$REFRESHER" ]; then
    if [ -f "${CONFIG_DIR}/.credentials.json" ]; then
        echo "[ccr-entrypoint-wrapper] starting token refresher"
        node "$REFRESHER" &
    else
        # No credentials yet (no interactive login has happened). Poll for the
        # file to appear, then start the refresher; don't block startup.
        echo "[ccr-entrypoint-wrapper] no credentials file yet; refresher will start once ${CONFIG_DIR}/.credentials.json exists"
        (
            while [ ! -f "${CONFIG_DIR}/.credentials.json" ]; do sleep 30; done
            echo "[ccr-entrypoint-wrapper] credentials file appeared; starting token refresher"
            exec node "$REFRESHER"
        ) &
    fi
else
    echo "[ccr-entrypoint-wrapper] token refresher disabled (CCR_TOKEN_REFRESH=${CCR_TOKEN_REFRESH:-1})"
fi

exec ccr-entrypoint "$@"
