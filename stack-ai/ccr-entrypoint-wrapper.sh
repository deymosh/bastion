#!/bin/sh
# Bastion wrapper around the upstream CCR entrypoint.
#
# The container starts as root only for this script. It:
#   1. aligns ownership of the writable paths + the data volume to uid/gid 1000,
#   2. reads the mounted CCR_WEB_AUTH_TOKEN secret,
#   3. optionally starts the OAuth token refresher (as uid 1000),
#   4. drops to the unprivileged "node" user (gosu) and exec's the real
#      entrypoint. CCR always starts - the refresher is a helper, never a gate.
# Set CCR_TOKEN_REFRESH=0 to skip the refresher.
set -eu

REFRESHER="$(dirname "$0")/ccr-token-refresher.mjs"
# Run as the host user (Bastion's USER_ID/GROUP_ID, passed as PUID/PGID by the
# compose file) so the ./data/ccr bind mount ownership lines up. Falls back to
# the image's uid/gid 1000 "node" user.
RUN_UID="${PUID:-1000}"
RUN_GID="${PGID:-1000}"

# 1. Make the paths the upstream entrypoint / nginx / pm2 write to owned by the
#    run user. Harmless (and fast) when they are already correct; `|| true` so a
#    read-only bind or a missing path never blocks startup.
if [ "$(id -u)" = "0" ]; then
    for p in /data /app /etc/nginx/conf.d /var/lib/nginx /var/log/nginx /run/nginx; do
        [ -e "$p" ] && chown -R "${RUN_UID}:${RUN_GID}" "$p" 2>/dev/null || true
    done
    [ -r /run/secrets/ccr_web_auth_token ] && chown "${RUN_UID}:${RUN_GID}" /run/secrets/ccr_web_auth_token 2>/dev/null || true
fi

# 2. CCR_WEB_AUTH_TOKEN from the mounted secret (env fallback for a partial
#    upgrade: old compose, new image).
if [ -r /run/secrets/ccr_web_auth_token ]; then
    CCR_WEB_AUTH_TOKEN="$(cat /run/secrets/ccr_web_auth_token)"
    export CCR_WEB_AUTH_TOKEN
fi

# helper: run "$@" as the run user if we are root, else just run it
as_run_user() {
    if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
        exec gosu "${RUN_UID}:${RUN_GID}" "$@"
    fi
    exec "$@"
}

# 3. refresher (backgrounded, as the run user)
if [ "${CCR_TOKEN_REFRESH:-1}" = "1" ] && [ -f "$REFRESHER" ]; then
    echo "[ccr-entrypoint-wrapper] starting OAuth token refresher (idle until an OAuth credentials file appears)"
    if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1; then
        gosu "${RUN_UID}:${RUN_GID}" node "$REFRESHER" &
    else
        node "$REFRESHER" &
    fi
else
    echo "[ccr-entrypoint-wrapper] OAuth token refresher disabled (CCR_TOKEN_REFRESH=${CCR_TOKEN_REFRESH:-1})"
fi

# 4. hand off to the upstream entrypoint, unprivileged
as_run_user ccr-entrypoint "$@"
