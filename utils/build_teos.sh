#!/bin/bash

################################################################################
# BASTION - TEOS Build Utility
#
# Builds the TEOS Docker image (teosd:latest) from the rust-teos submodule.
# Rebuilds when: "force" is passed, the image is missing, or the image was
# built from a different rust-teos commit than the one currently checked out
# (tracked via the bastion.teos.commit image label). This last check matters
# because the submodule carries Bastion-specific patches - a stale image would
# silently keep running an old binary (e.g. the pre-transit hardcoded Tor
# control address).
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

# Commit currently checked out in the submodule, and the one the existing image
# was built from (empty if the image is missing or predates this label).
TEOS_COMMIT=$(git -C rust-teos rev-parse HEAD 2> /dev/null)
IMAGE_COMMIT=$(docker image inspect --format '{{ index .Config.Labels "bastion.teos.commit" }}' teosd:latest 2> /dev/null)

NEED_BUILD=0
REASON=""
if [[ "$FORCE_BUILD" == "force" ]]; then
    NEED_BUILD=1; REASON="force build triggered"
elif [[ -z "$IMAGE_EXISTS" ]]; then
    NEED_BUILD=1; REASON="image teosd:latest not found"
elif [[ -n "$TEOS_COMMIT" && "$TEOS_COMMIT" != "$IMAGE_COMMIT" ]]; then
    NEED_BUILD=1; REASON="rust-teos moved to ${TEOS_COMMIT:0:12} (image built from ${IMAGE_COMMIT:0:12})"
fi

if [[ "$NEED_BUILD" -eq 1 ]]; then
    echo -e "${YELLOW}${BOLD}[!] Rebuilding TEOS: ${REASON}.${NC}"
    echo -e "${CYAN}--> Building from submodule: ${BOLD}rust-teos${NC}"

    if [ -d "rust-teos" ]; then
        (
            cd rust-teos || exit 1
            docker build -f ./docker/Dockerfile \
                --label "bastion.teos.commit=${TEOS_COMMIT}" \
                -t teosd:latest .
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
    echo -e "${GREEN}${BOLD}[✔] TEOS image is ready (${TEOS_COMMIT:0:12}).${NC}\n"
fi
