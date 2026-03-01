#!/bin/bash

################################################################################
# BASTION - Configuration Loader
#
# This script handles loading and managing configuration variables 
# for the BASTION project. It ensures that essential variables are set,
# generates defaults where necessary, and provides a centralized way to
# manage configuration across all stacks.
#
# Usage:
#   Used internally by the main script bastion. Not meant to be run directly.
################################################################################

# --- CONFIGURATION ---
PROJECT_NAME="BASTION"
CONFIG_FILE="./bastion.conf"
# Deployment order is crucial: Network must be first.
STACKS=("stack-network" "stack-bitcoin" "stack-monitor")
# Path to the python audit script
AUDIT_SCRIPT="./stack-bitcoin/scripts/node-audit.py"
# Path to the TEOS build utility
TEOS_BUILD_UTIL="./utils/build_teos.sh"

# --- STYLING ---
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# --- LOGIC ---
load_secrets() {
    echo -e "${CYAN}${BOLD}--> Loading Configuration...${NC}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo -e "${YELLOW}[!] Created empty $CONFIG_FILE${NC}"
    fi

    # Load variables into environment
    set -a
    # shellcheck disable=SC1090
    source <(sed 's/^export //g' "$CONFIG_FILE" | grep -v '^[[:space:]]*#')
    set +a

    # Critical Prompts
    if [ -z "$WIREGUARD_SERVERURL" ]; then
        echo -e "${YELLOW}${BOLD}[!] Essential network configuration missing.${NC}"
        echo -en "${CYAN}${BOLD}📝 Enter Public IP or Domain for Wireguard: ${NC}"
        read -r WIREGUARD_SERVERURL
        echo "WIREGUARD_SERVERURL=$WIREGUARD_SERVERURL" >> "$CONFIG_FILE"
    fi

    if [ -z "$WIREGUARD_SERVERPORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] Essential network configuration missing.${NC}"
        echo -en "${CYAN}${BOLD}📝 Enter Public Port for Wireguard: ${NC}"
        read -r WIREGUARD_SERVERPORT
        echo "WIREGUARD_SERVERPORT=$WIREGUARD_SERVERPORT" >> "$CONFIG_FILE"
    fi

    if [ -z "$NODE_ALIAS" ]; then
        echo -en "${CYAN}${BOLD}📝 Enter CLN Node Alias: ${NC}"
        read -r NODE_ALIAS
        echo "NODE_ALIAS=$NODE_ALIAS" >> "$CONFIG_FILE"
    fi

    # Defaults and Auto-generation
    declare -A DEFAULTS=(
        ["TIMEZONE"]=$(cat /etc/timezone 2>/dev/null || echo "UTC")
        ["PIHOLE_PASSWORD"]=$(openssl rand -hex 8)
        ["WIREGUARD_PEERS"]="1"
        ["USER_ID"]=$(id -u)
        ["GROUP_ID"]=$(id -g)
    )

    for var in "${!DEFAULTS[@]}"; do
        if [ -z "${!var}" ]; then
            echo "$var=${DEFAULTS[$var]}" >> "$CONFIG_FILE"
            export "$var"="${DEFAULTS[$var]}"
            echo -e "${YELLOW}--> Generated default for $var${NC}"
        fi
    done
    
    # Symlink .env files to stacks
    for stack in "${STACKS[@]}"; do
        if [ -d "./$stack" ]; then
            ln -sf "../$CONFIG_FILE" "./$stack/.env"
        fi
    done

    echo -e "${GREEN}${BOLD}[✔] Environment variables loaded.${NC}\n"
}