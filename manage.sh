#!/bin/bash

# --- CONFIGURATION ---
PROJECT_NAME="BASTION"
CONFIG_FILE="./bastion.conf"
# Deployment order is crucial: Network must be first.
STACKS=("stack-network" "stack-bitcoin" "stack-monitor")
# Path to the python audit script
AUDIT_SCRIPT="./stack-bitcoin/scripts/node-audit.py"

# --- STYLING ---
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# --- HEADER ---
HEADER_LINE="═══════════════════════════════════════════════════════"
echo -e "${CYAN}${HEADER_LINE}${NC}"
echo -e "${CYAN}${BOLD}                🏴‍☠️  $PROJECT_NAME CLI                  ${NC}"
echo -e "${CYAN}${BOLD}             Sovereign Node Infrastructure             ${NC}"
echo -e "${CYAN}${HEADER_LINE}${NC}"

# --- PRE-FLIGHT CHECKS ---
usage() {
    echo -e "${YELLOW}${BOLD}COMMANDS:${NC}"
    echo -e "  ${GREEN}up${NC}      -> Deploy all stacks in order"
    echo -e "  ${YELLOW}stop${NC}    -> Stop all containers"
    echo -e "  ${RED}down${NC}    -> Stop and remove all containers"
    echo -e "  ${CYAN}status${NC}  -> Show running containers and IPs"
    echo -e "  ${CYAN}audit${NC}   -> Run the Python Node Profitability Audit"
    echo -e "  ${BOLD}build${NC}   -> Build all stacks without starting"
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

check_docker() {
    if ! docker info > /dev/null 2>&1; then
        echo -e "${RED}${BOLD}[✘] Error: Docker daemon is not running or no permissions.${NC}"
        exit 1
    fi
}

load_secrets() {
    echo -e "${CYAN}${BOLD}--> Loading Configuration...${NC}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo -e "${YELLOW}[!] Created empty $CONFIG_FILE${NC}"
    fi

    # Load variables into environment
    set -a
    source <(sed 's/^export //g' "$CONFIG_FILE" | grep -v '^[[:space:]]*#')
    set +a

    # Critical Prompts
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

build_teos_if_missing() {
    local IMAGE_EXISTS=$(docker images -q teosd:latest 2> /dev/null)
    local FORCE_BUILD=$1

    # Si FORCE_BUILD es "force" o si la imagen NO existe, disparamos el build
    if [[ "$FORCE_BUILD" == "force" ]] || [[ -z "$IMAGE_EXISTS" ]]; then
        if [[ "$FORCE_BUILD" == "force" ]]; then
            echo -e "${YELLOW}${BOLD}[!] Force build triggered for TEOS...${NC}"
        else
            echo -e "${YELLOW}${BOLD}[!] Watchtower image (teosd:latest) not found.${NC}"
        fi

        echo -e "${CYAN}--> Building from submodule: ${BOLD}rust-teos${NC}"
        (
            cd rust-teos || { echo -e "${RED}✘ Error: rust-teos directory missing!${NC}"; exit 1; }
            docker build -f ./docker/Dockerfile -t teosd:latest .
        )
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[✔] TEOS image built successfully.${NC}\n"
        else
            echo -e "${RED}[✘] Error: Failed to build TEOS image.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}${BOLD}[✔] TEOS image is ready.${NC}\n"
    fi
}

# --- EXECUTION ---

check_docker
load_secrets

if [ -z "$1" ]; then
    usage
fi

case "$1" in
    up)
        build_teos_if_missing
        echo -e "${GREEN}${BOLD}[+] Booting Infrastructure...${NC}"
        for stack in "${STACKS[@]}"; do
            echo -e "${CYAN}--> Starting:${NC} ${BOLD}$stack${NC}"
            docker compose -f "./$stack/docker-compose.yml" up -d
        done
        echo -e "\n${GREEN}${BOLD}[✔] $PROJECT_NAME is now LIVE.${NC}"
        ;;
    stop)
        echo -e "${RED}${BOLD}[-] Stopping all stacks...${NC}"
        for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
            docker compose -f "./${STACKS[$i]}/docker-compose.yml" stop
        done
        echo -e "\n${RED}${BOLD}✘ $PROJECT_NAME is OFFLINE.${NC}"
        ;;
    down)
        echo -e "${RED}${BOLD}[-] Tearing down all stacks...${NC}"
        for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
            docker compose -f "./${STACKS[$i]}/docker-compose.yml" down
        done
        echo -e "\n${RED}${BOLD}✘ $PROJECT_NAME has been REMOVED.${NC}"
        ;;
    status)
        echo -e "${CYAN}${BOLD}[?] Current Environment Status:${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"
        ;;
    audit)
        if [ -f "$AUDIT_SCRIPT" ]; then
            python3 "$AUDIT_SCRIPT"
        else
            echo -e "${RED}[✘] Error: Audit script not found at $AUDIT_SCRIPT${NC}"
        fi
        ;;
    build)
        build_teos_if_missing "force"
        for stack in "${STACKS[@]}"; do
            docker compose -f "./$stack/docker-compose.yml" build
        done
        ;;
    logs)
        echo -e "${CYAN}${BOLD}[!] Attaching to Logs...${NC}"
        # Optimized log joining using printf
        docker compose $(printf -- "-f ./%s/docker-compose.yml " "${STACKS[@]}") logs -f --tail=50
        ;;
    *)
        usage
        ;;
esac