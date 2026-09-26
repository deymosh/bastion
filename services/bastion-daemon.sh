#!/bin/bash

################################################################################
# BASTION - Master Daemon
#
# This script serves as the main orchestrator for the BASTION stack.
# Managing the lifecycle of all services and performing critical maintenance tasks.
# It ensures the Lightning Node's emergency recovery file is safely backed up to a USB drive
# and maintains a historical archive of these backups.
# Additionally, it can perform optional SQLite compaction.
#
# Usage:
#   Use the provided bastion-daemon.service example to set up this script
#   as a systemd service for automatic startup and management.
#   Not intended to be run manually.
################################################################################

# --- 1. Configuration & Paths ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CLN_DATA_DIR="${CLN_DATA_DIR:-$SCRIPT_DIR/../stack-bitcoin/data/cln}"
BACKUP_DEST="${BACKUP_DEST:-/mnt/backup_cln}"
CLN_CONTAINER="lightningd"

SCB_SOURCE="$CLN_DATA_DIR/emergency.recover"
SCB_DEST_LIVE="$BACKUP_DEST/emergency.recover.live"
SCB_HISTORY_DIR="$BACKUP_DEST/history"

# Settings
BACKUP_PLUGIN_COMPACT=false # Set to true if using backup plugin and want to compact it daily
ENABLE_AMBOSS_HEARTBEAT=false # Set to true to post a signed heartbeat to Amboss
AMBOSS_INTERVAL=300  # seconds between Amboss heartbeats
CHECK_INTERVAL=3600  # 1 hour in seconds
LAST_MAINTENANCE_DATE=""

# --- 2. Function: Wait for Lightningd ---
wait_for_cln() {
    echo "[$(date)] Waiting for $CLN_CONTAINER to be ready..."
    until [ "$(docker inspect -f '{{.State.Running}}' $CLN_CONTAINER 2>/dev/null)" == "true" ]; do
        sleep 2
    done
    
    until docker exec $CLN_CONTAINER lightning-cli getinfo > /dev/null 2>&1; do
        echo "[$(date)] Container is up, waiting for Lightning Node to initialize..."
        sleep 3
    done

    echo "[$(date)] Lightning Node is officially ONLINE."
}

# The backup is only worth anything on a separate device. If the USB drive is
# not mounted, BACKUP_DEST is a plain directory on the node's own disk: writing
# there would look like success while protecting nothing. Refuse, loudly.
backup_target_ok() {
    if command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "$BACKUP_DEST"; then
        echo "[$(date)] ERROR: $BACKUP_DEST is not a mounted filesystem - is the backup drive plugged in? SCB NOT backed up."
        return 1
    fi
    return 0
}

# --- 3. Function: Daily Maintenance ---
run_daily_maintenance() {
    CURRENT_DATE=$(date +%Y-%m-%d)
    
    if [ "$LAST_MAINTENANCE_DATE" != "$CURRENT_DATE" ]; then
        echo "----------------------------------------------------------------"
        echo "[$(date)] STARTING DAILY MAINTENANCE..."
        
        # A. Historical SCB Snapshot
        if [ -f "$SCB_SOURCE" ] && backup_target_ok; then
            mkdir -p "$SCB_HISTORY_DIR"
            rm -f "$SCB_HISTORY_DIR/emergency.recover.$CURRENT_DATE" # Remove existing snapshot for today if exists (only happens if service restarted)
            cp -f "$SCB_SOURCE" "$SCB_HISTORY_DIR/emergency.recover.$CURRENT_DATE"
            echo "[SUCCESS] Historical snapshot created: $CURRENT_DATE"
            # Keep only last 30 days
            find "$SCB_HISTORY_DIR" -type f -mtime +30 -delete
        fi

        # B. SQLite Compaction (Conditional)
        if [ "$BACKUP_PLUGIN_COMPACT" = true ]; then
            echo "[Task] Compacting SQLite database..."
            JSON_OUT=$(docker exec $CLN_CONTAINER lightning-cli backup-compact 2>&1)
            
            if [ $? -eq 0 ]; then
                BEFORE=$(echo "$JSON_OUT" | jq -r '.before.backupsize // 0')
                AFTER=$(echo "$JSON_OUT" | jq -r '.after.backupsize // 0')
                echo "[SUCCESS] Compaction finished. Saved: $(( (BEFORE - AFTER) / 1024 / 1024 )) MB."
            else
                echo "[ERROR] Compaction failed: $JSON_OUT"
            fi
        else
            echo "[Info] SQLite compaction skipped (BACKUP_PLUGIN_COMPACT=false)."
        fi
        
        LAST_MAINTENANCE_DATE="$CURRENT_DATE"
        echo "[$(date)] Maintenance complete."
        echo "----------------------------------------------------------------"
    fi
}

start_amboss_heartbeat() {
    if [ "$ENABLE_AMBOSS_HEARTBEAT" = true ]; then
        echo "[$(date)] Starting Amboss heartbeat (every ${AMBOSS_INTERVAL}s)..."
        (
            cd "$SCRIPT_DIR/.." || exit 1
            while true; do
                ./stack-bitcoin/scripts/amboss-healthcheck.sh || true
                sleep "$AMBOSS_INTERVAL"
            done
        ) &
    else
        echo "[$(date)] Amboss heartbeat is disabled (ENABLE_AMBOSS_HEARTBEAT=false)."
    fi
}

# --- 4. Function: Live SCB sync ---
# Mirror emergency.recover to the backup drive when it changed. Returns 0 when
# the live copy matches the source afterwards (or already did), 1 otherwise.
sync_scb() {
    local h_src h_dst h_tmp tmp
    h_src=$(sha256sum "$SCB_SOURCE" | awk '{print $1}')
    h_dst=$(sha256sum "$SCB_DEST_LIVE" 2>/dev/null | awk '{print $1}')
    [ "$h_src" = "$h_dst" ] && return 0

    echo "[$(date)] Change detected in SCB. Syncing to USB..."
    backup_target_ok || return 1

    # Copy to a temp file on the same filesystem, verify it, flush it, and only
    # then rename it over the live copy. rename(2) is atomic, so the destination
    # always holds a complete backup - never a missing or half-written one, even
    # if the host dies mid-copy.
    tmp="$SCB_DEST_LIVE.tmp"
    cp -f "$SCB_SOURCE" "$tmp"
    h_tmp=$(sha256sum "$tmp" | awk '{print $1}')
    if [ "$h_src" != "$h_tmp" ]; then
        rm -f "$tmp"
        echo "[$(date)] ERROR: Integrity check failed after copy - live backup left untouched."
        return 1
    fi
    sync "$tmp" 2>/dev/null || sync            # flush the data to the device
    mv -f "$tmp" "$SCB_DEST_LIVE"
    sync "$BACKUP_DEST" 2>/dev/null || sync    # persist the rename
    echo "[$(date)] LIVE SYNC SUCCESS. Hash: ${h_src:0:8}..."
}

# --- 5. Main Execution Flow ---
daemon_main() {
    echo "[$(date)] BASTION Master Daemon started."

    # teosd (your own watchtower) is opt-in: export BASTION_PROFILES=watchtower
    # in this service's environment if you run one.
    echo "[$(date)] Launching BASTION stack..."
    ./bastion up

    wait_for_cln
    start_amboss_heartbeat

    # Ensure the SCB file exists before starting the loop
    while [ ! -f "$SCB_SOURCE" ]; do
        echo "[$(date)] Waiting for $SCB_SOURCE to be generated..."
        sleep 5
    done

    echo "[$(date)] Starting Polling Service (Interval: ${CHECK_INTERVAL}s)"
    while true; do
        run_daily_maintenance
        sync_scb || true
        sleep "$CHECK_INTERVAL"
    done
}

# Run only when executed; sourcing (the unit tests) just loads the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    daemon_main
fi
