#!/bin/bash

# Import configuration and utilities
if [ -f "./utils/config.sh" ]; then
    source ./utils/config.sh
else
    echo "Error: ./utils/config.sh not found."
    exit 1
fi

# --- HEADER ---
HEADER_LINE="═══════════════════════════════════════════════════════"
echo -e "${CYAN}${HEADER_LINE}${NC}"
echo -e "${CYAN}${BOLD}                 🏴‍☠️  $PROJECT_NAME CLI                  ${NC}"
echo -e "${CYAN}${BOLD}          Sovereign Node Infrastructure              ${NC}"
echo -e "${CYAN}${HEADER_LINE}${NC}"

# --- HELPER FUNCTIONS ---
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

# --- EXECUTION ---
check_docker
load_secrets

if [ -z "$1" ]; then
    usage
fi

case "$1" in
    up)
        bash "$TEOS_BUILD_UTIL"
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
        bash "$TEOS_BUILD_UTIL" "force"
        for stack in "${STACKS[@]}"; do
            docker compose -f "./$stack/docker-compose.yml" build
        done
        ;;
    logs)
        echo -e "${CYAN}${BOLD}[!] Attaching to Logs...${NC}"
        # shellcheck disable=SC2046
        docker compose $(printf -- "-f ./%s/docker-compose.yml " "${STACKS[@]}") logs -f --tail=50
        ;;
    *)
        usage
        ;;
esac