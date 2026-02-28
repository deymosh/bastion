#!/bin/bash

# ==============================================================================
# BASTION Node - Maintenance & Backup Script
# ==============================================================================

# 1. Environment & Paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_DIR="$SCRIPT_DIR/../data/cln"
BACKUP_DEST="/mnt/backup_cln"
CLN_CONTAINER="lightningd"

# Files
SCB_SOURCE="$DATA_DIR/emergency.recover"
SCB_DEST="$BACKUP_DEST/emergency.recover.bak"

# Start Timing
START_TIME=$(date +%s)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting BASTION Node Maintenance..."

# --- 2. Step 1: SCB Backup (Static Channel Backup) ---
echo "Task 1: Backing up Static Channel Backup (SCB)..."
if [ -f "$SCB_SOURCE" ]; then
    # Delete and force copy (to handle read-only issues)
    rm -f "$SCB_DEST"
    cp -f "$SCB_SOURCE" "$SCB_DEST"

    # --- Hash Verification ---
    HASH_SRC=$(sha256sum "$SCB_SOURCE" | awk '{print $1}')
    HASH_DST=$(sha256sum "$SCB_DEST" | awk '{print $1}')

    if [ "$HASH_SRC" == "$HASH_DST" ]; then
        echo "[SUCCESS] SCB copied and verified (Hash: ${HASH_SRC:0:8}...)"
    else
        echo "[ERROR] Hash mismatch! Integrity check failed."
        exit 1
    fi
else
    echo "[ERROR] SCB source not found at $SCB_SOURCE"
fi

# --- 3. Step 2: SQLite Backup Compaction ---
echo "Task 2: Compacting SQLite backup via Docker..."
JSON_OUT=$(docker exec $CLN_CONTAINER lightning-cli backup-compact 2>&1)
EXIT_CODE=$?

# --- 4. Process Results ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ $EXIT_CODE -eq 0 ]; then
    # Parse JSON output using jq
    BEFORE=$(echo "$JSON_OUT" | jq -r '.before.backupsize')
    AFTER=$(echo "$JSON_OUT" | jq -r '.after.backupsize')
    
    # Calculate savings
    SAVED_BYTES=$((BEFORE - AFTER))
    SAVED_MB=$((SAVED_BYTES / 1024 / 1024))
    FINAL_SIZE_MB=$((AFTER / 1024 / 1024))

    echo "[SUCCESS] Compaction finished in ${DURATION} seconds."
    echo "  - Size Before: $((BEFORE / 1024 / 1024)) MB"
    echo "  - Size After:  ${FINAL_SIZE_MB} MB"
    echo "  - Cleaned:     ${SAVED_MB} MB"
else
    echo "[ERROR] Compaction failed after ${DURATION} seconds!"
    echo "Details: $JSON_OUT"
    # We don't exit here to allow the script to finish the log block
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Maintenance complete."
echo "----------------------------------------------------------------"