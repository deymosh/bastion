#!/bin/bash

################################################################################
# BASTION - TEOS Build Utility
#
# This script handles building the TEOS Docker image from the rust-teos submodule.
# It checks if the image already exists and only rebuilds if necessary or if a force flag is provided.
#
# Usage:
#   Used internally by the main script bastion. Not meant to be run directly.
################################################################################

# --- STYLING (Shared with main script) ---
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' 

FORCE_BUILD=$1
IMAGE_EXISTS=$(docker images -q teosd:latest 2> /dev/null)

if [[ "$FORCE_BUILD" == "force" ]] || [[ -z "$IMAGE_EXISTS" ]]; then
    if [[ "$FORCE_BUILD" == "force" ]]; then
        echo -e "${YELLOW}${BOLD}[!] Force build triggered for TEOS...${NC}"
    else
        echo -e "${YELLOW}${BOLD}[!] Watchtower image (teosd:latest) not found.${NC}"
    fi

    echo -e "${CYAN}--> Building from submodule: ${BOLD}rust-teos${NC}"
    
    # Attempt to enter the directory and build
    if [ -d "rust-teos" ]; then
        (
            cd rust-teos || exit 1
            docker build -f ./docker/Dockerfile -t teosd:latest .
        )
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[✔] TEOS image built successfully.${NC}\n"
        else
            echo -e "${RED}[✘] Error: Failed to build TEOS image.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}[✘] Error: rust-teos directory missing!${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}${BOLD}[✔] TEOS image is ready.${NC}\n"
fi