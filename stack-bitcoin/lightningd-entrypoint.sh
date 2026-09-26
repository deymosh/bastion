#!/usr/bin/env bash
# Bastion entrypoint for lightningd - replaces the upstream /entrypoint.sh.
#
# The upstream script runs as bash PID 1 and starts lightningd as a background
# job. PID 1 ignores SIGTERM unless it installs a handler, and that script does
# not, so `docker stop` never reached lightningd: every stop/restart/upgrade
# waited out the grace period and ended in SIGKILL, mid-write to the wallet DB
# and its backup-drive replica.
#
# Here SIGTERM/SIGINT trigger CLN's own clean shutdown (`lightning-cli stop`:
# plugins are told to stop, the DB is closed), falling back to signalling the
# process if the RPC is not up yet (still starting). Upstream's optional extras
# (EXPOSE_TCP socat, lightning-poststart.d) are not used by Bastion.
set -u

lightningd --network="${LIGHTNINGD_NETWORK:-bitcoin}" "$@" &
pid=$!

shutdown() {
    echo "lightningd-entrypoint: stop requested, shutting down Core Lightning cleanly"
    lightning-cli stop >/dev/null 2>&1 || kill -TERM "$pid" 2>/dev/null
}
trap shutdown TERM INT

# `wait` returns early when a trapped signal arrives; keep waiting until
# lightningd has actually exited, then pass its exit status on.
while kill -0 "$pid" 2>/dev/null; do
    wait "$pid"
    rc=$?
done
exit "${rc:-0}"
