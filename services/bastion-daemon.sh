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
CLN_DATA_DIR="$SCRIPT_DIR/../stack-bitcoin/data/cln"
BACKUP_DEST="/mnt/backup_cln"
CLN_CONTAINER="lightningd"

SCB_SOURCE="$CLN_DATA_DIR/emergency.recover"
SCB_DEST_LIVE="$BACKUP_DEST/emergency.recover.live"
SCB_HISTORY_DIR="$BACKUP_DEST/history"

# Settings
BACKUP_PLUGIN_COMPACT=false # Set to true if using backup plugin and want to compact it daily
ENABLE_LXMF_BRIDGE=false # Set to true to enable the LXMF bridge (experimental)
CHECK_INTERVAL=3600  # 1 hour in seconds
LAST_MAINTENANCE_DATE=""

echo "[$(date)] BASTION Master Daemon started."

# Start BASTION services
echo "[$(date)] Launching BASTION stack..."
./bastion up -d

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

# --- 3. Function: Daily Maintenance ---
run_daily_maintenance() {
    CURRENT_DATE=$(date +%Y-%m-%d)
    
    if [ "$LAST_MAINTENANCE_DATE" != "$CURRENT_DATE" ]; then
        echo "----------------------------------------------------------------"
        echo "[$(date)] STARTING DAILY MAINTENANCE..."
        
        # A. Historical SCB Snapshot
        mkdir -p "$SCB_HISTORY_DIR"
        if [ -f "$SCB_SOURCE" ]; then
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

start_LXMF_bridge() {
    if [ "$ENABLE_LXMF_BRIDGE" = true ]; then
        echo "[$(date)] Starting LXMF Bridge (experimental)..."
        
        # Create a python virtual environment for the bridge
        if [ ! -d "venv" ]; then
            python3 -m venv venv
        fi

        source venv/bin/activate

        # Install dependencies (if any)
        pip install --upgrade pip
        pip install RNS LXMF

        # Start the bridge in the background
        python services/lxmf-bridge.py &
        echo "[$(date)] LXMF Bridge started."
    else
        echo "[$(date)] LXMF Bridge is disabled (ENABLE_LXMF_BRIDGE=false)."
    fi
}

# --- 4. Main Execution Flow ---

wait_for_cln
start_LXMF_bridge

# Ensure the SCB file exists before starting the loop
while [ ! -f "$SCB_SOURCE" ]; do
    echo "[$(date)] Waiting for $SCB_SOURCE to be generated..."
    sleep 5
done

echo "[$(date)] Starting Polling Service (Interval: ${CHECK_INTERVAL}s)"

# --- 5. The Infinite Polling Loop ---
while true; do
    # Run maintenance check
    run_daily_maintenance

    # Compare current SCB with the one in the USB
    H_SRC=$(sha256sum "$SCB_SOURCE" | awk '{print $1}')
    H_DST=$(sha256sum "$SCB_DEST_LIVE" 2>/dev/null | awk '{print $1}')

    if [ "$H_SRC" != "$H_DST" ]; then
        echo "[$(date)] Change detected in SCB. Syncing to USB..."
        
        # Perform atomic-like copy
        rm -f "$SCB_DEST_LIVE"
        cp -f "$SCB_SOURCE" "$SCB_DEST_LIVE"
        sync # Flush filesystem buffers to the USB hardware
        
        # Final Verification
        H_VERIFY=$(sha256sum "$SCB_DEST_LIVE" | awk '{print $1}')
        if [ "$H_SRC" == "$H_VERIFY" ]; then
            echo "[$(date)] LIVE SYNC SUCCESS. Hash: ${H_SRC:0:8}..."
        else
            echo "[$(date)] ERROR: Integrity check failed after copy!"
        fi
    fi

    # Wait for the next check
    sleep "$CHECK_INTERVAL"
done