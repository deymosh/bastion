#!/bin/bash

# --- CONFIGURATION ---
PROJECT_NAME="BASTION"
# Config file
CONFIG_FILE="./bastion.conf"

# Deployment order is crucial: Network must be first.
STACKS=("stack-network" "stack-bitcoin" "stack-monitor")

# --- STYLING ---
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# --- HEADER ---
echo -e "${CYAN}${BOLD}====================================================${NC}"
echo -e "${CYAN}${BOLD}             🏴‍☠️  $PROJECT_NAME CLI               ${NC}"
echo -e "${CYAN}${BOLD}            Sovereign Node Infrastructure        ${NC}"
echo -e "${CYAN}${BOLD}====================================================${NC}"

usage() {
    echo -e "${YELLOW}${BOLD}COMMANDS:${NC}"
    echo -e "  ${GREEN}up${NC}      -> Deploy all stacks in order"
    echo -e "  ${YELLOW}stop${NC}    -> Stop all containers"
    echo -e "  ${RED}down${NC}    -> Stop and remove all containers"
    echo -e "  ${CYAN}status${NC}  -> Show running containers and IPs"
    echo -e "  ${BOLD}logs${NC}    -> Tail logs from all stacks"
    echo -e ""
    echo -e "${YELLOW}${BOLD}STACKS MANAGED:${NC}"
    for i in "${!STACKS[@]}"; do
        echo -e "  $((i+1)). ${STACKS[$i]}"
    done
    echo -e ""
    echo -e "${BOLD}Example:${NC} $0 up"
    exit 1
}

load_secrets() {
    echo -e "${CYAN}${BOLD}--> Loading Configuration...${NC}"
    
    # 1. Load config if exists
    if [ -f "$CONFIG_FILE" ]; then
        set -a
        source <(sed 's/^export //g' "$CONFIG_FILE")
        set +a
    fi

    # 2. Critical Prompts
    if [ -z "$WIREGUARD_SERVERURL" ]; then
        echo -e "${YELLOW}${BOLD}[!] Essential network configuration missing.${NC}"
        echo -en "${CYAN}${BOLD}📝 Enter Public IP or Domain for Wireguard: ${NC}"
        read WIREGUARD_SERVERURL
        echo "WIREGUARD_SERVERURL=$WIREGUARD_SERVERURL" >> "$CONFIG_FILE"
    fi

    if [ -z "$WIREGUARD_SERVERPORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] Essential network configuration missing.${NC}"
        echo -en "${CYAN}${BOLD}📝 Enter Public Port for Wireguard: ${NC}"
        read WIREGUARD_SERVERPORT
        echo "WIREGUARD_SERVERPORT=$WIREGUARD_SERVERPORT" >> "$CONFIG_FILE"
    fi

    if [ -z "$NODE_ALIAS" ]; then
        echo -en "${CYAN}${BOLD}📝 Enter CLN Node Alias: ${NC}"
        read NODE_ALIAS
        echo "NODE_ALIAS=$NODE_ALIAS" >> "$CONFIG_FILE"
    fi

    # 3. Auto-generation for the rest
    local CHANGED=false
    declare -A DEFAULTS=(
        ["TIMEZONE"]=$(cat /etc/timezone 2>/dev/null)
        ["PIHOLE_PASSWORD"]=$(openssl rand -hex 8)
        ["WIREGUARD_PEERS"]="1"
        ["USER_ID"]=$(id -u)
        ["GROUP_ID"]=$(id -g)
    )

    for var in "${!DEFAULTS[@]}"; do
        if [ -z "${!var}" ]; then
            printf -v "$var" "%s" "${DEFAULTS[$var]}"
            echo "$var=${DEFAULTS[$var]}" >> "$CONFIG_FILE"
            echo -e "${YELLOW}--> Generated default for $var${NC}"
            CHANGED=true
        fi
    done
    
    for stack in "${STACKS[@]}"; do
        if [ -d "./$stack" ]; then
            # Force symbolic link: bastion.conf -> stack-folder/.env
            ln -sf "../$CONFIG_FILE" "./$stack/.env"
        fi
    done

    # Export everything one last time
    export $(cut -d= -f1 "$CONFIG_FILE" | grep -v '^#')
    echo -e "${GREEN}${BOLD}[✔] Environment variables loaded.${NC}\n"
}

build_teos_if_missing() {
    echo -e "${CYAN}${BOLD}--> Looking for TEOS image...${NC}"

    local IMAGE_EXISTS=$(docker images -q teosd:latest 2> /dev/null)

    if [ -z "$IMAGE_EXISTS" ]; then
        echo -e "${YELLOW}${BOLD}[!] Watchtower image (teosd:latest) not found.${NC}"
        echo -e "${CYAN}--> Building from submodule: ${BOLD}rust-teos${NC}"
        
        # Build the TEOS image from the rust-teos submodule in a subshell to avoid changing the main script's directory
        (
            cd rust-teos || { echo -e "${RED}✘ Error: Directory rust-teos not found!${NC}"; exit 1; }
            docker build -f ./docker/Dockerfile -t teosd:latest .
        )

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✔ TEOS image built successfully.${NC}\n"
        else
            echo -e "${RED}✘ Error: Failed to build TEOS image.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}${BOLD}[✔] TEOS image is ready.${NC}"
        echo -e
    fi
}

load_secrets
build_teos_if_missing

if [ -z "$1" ]; then
    usage
fi

case "$1" in
    up)
        echo -e "${GREEN}${BOLD}[+] Booting Infrastructure...${NC}"
        for stack in "${STACKS[@]}"; do
            echo -e "${CYAN}--> Starting:${NC} ${BOLD}$stack${NC}"
            docker compose -f ./$stack/docker-compose.yml up -d
        done
        echo -e "\n${GREEN}${BOLD}✔ $PROJECT_NAME is now LIVE.${NC}"
        ;;
    stop)
        echo -e "${RED}${BOLD}[-] Stopping all stacks...${NC}"
        # Reverse order to safely disconnect from the network
        for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
            echo -e "${YELLOW}--> Stopping:${NC} ${BOLD}${STACKS[$i]}${NC}"
            docker compose -f ./${STACKS[$i]}/docker-compose.yml stop
        done
        echo -e "\n${RED}${BOLD}✘ $PROJECT_NAME is OFFLINE.${NC}"
        ;;
    down)
        echo -e "${RED}${BOLD}[-] Tearing down all stacks...${NC}"
        for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
            echo -e "${YELLOW}--> Removing:${NC} ${BOLD}${STACKS[$i]}${NC}"
            docker compose -f ./${STACKS[$i]}/docker-compose.yml down
        done
        echo -e "\n${RED}${BOLD}✘ $PROJECT_NAME has been REMOVED.${NC}"
        ;;
    status)
        echo -e "${CYAN}${BOLD}[?] Current Environment Status:${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"
        ;;
    logs)
        echo -e "${CYAN}${BOLD}[!] Attaching to Logs...${NC}"
        # Dynamically build the log command for all stacks
        COMPOSE_FILES=""
        for stack in "${STACKS[@]}"; do
            COMPOSE_FILES="$COMPOSE_FILES -f ./$stack/docker-compose.yml"
        done
        docker compose $COMPOSE_FILES logs -f --tail=50
        ;;
    *)
        usage
        ;;
esac