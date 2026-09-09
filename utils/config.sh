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

# This file is a sourced library: many names below are consumed by ./bastion and
# utils/tui.sh, not here, so shellcheck's "appears unused" is expected.
# shellcheck disable=SC2034

# --- CONFIGURATION ---
PROJECT_NAME="BASTION"
CONFIG_FILE="./bastion.conf"
# Deployment order is crucial: Network must be first.
STACKS=("stack-network" "stack-bitcoin" "stack-monitor" "stack-web" "stack-ai")
# The foundation stack: it creates the bastion-transit network and the
# bastion-tor-data volume and runs Tor. Every "up" brings it up first; it
# cannot be brought down while any other stack is running.
NETWORK_STACK="stack-network"

# Which stack each container belongs to (used to tell which stacks are up).
declare -A CONTAINER_STACK=(
    [pihole]=stack-network [unbound]=stack-network [wireguard]=stack-network [tor]=stack-network
    [bitcoind]=stack-bitcoin [lightningd]=stack-bitcoin [rtl]=stack-bitcoin [teosd]=stack-bitcoin
    [portainer]=stack-monitor [grafana]=stack-monitor [prometheus]=stack-monitor [node-exporter]=stack-monitor
    [hub]=stack-web
    [ccr]=stack-ai [codedeck-bridge]=stack-ai
)

# Print the stacks that currently have at least one running container, one per
# line. Single `docker ps` call.
running_stacks() {
    local name out=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        local s="${CONTAINER_STACK[$name]:-}"
        [ -n "$s" ] || continue
        case " $out " in *" $s "*) : ;; *) out="$out $s" ;; esac
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
    for name in $out; do echo "$name"; done
}
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

# Emit "KEY='value'" with the value single-quoted so the file stays safe to
# source: a value like "a b; rm -rf ~" or "$(...)" is data, not code. Empty
# values become KEY='' . read_env_var() strips the surrounding quotes on read.
_wc_kv() {
    local v=${2//\'/\'\\\'\'}
    printf "%s='%s'\n" "$1" "$v"
}

write_config() {
    local temp_file extra_file
    temp_file=$(mktemp "${CONFIG_FILE}.XXXXXX")
    extra_file=$(mktemp "${CONFIG_FILE}.extra.XXXXXX")

    if [ -f "$CONFIG_FILE" ]; then
        awk '
            BEGIN {
                split("WIREGUARD_SERVERURL WIREGUARD_SERVERPORT WIREGUARD_PEERS NODE_ALIAS TIMEZONE USER_ID GROUP_ID PIHOLE_PASSWORD LXMF_ALLOWED_IDENTITY CODEDECK_RELAYS CODEDECK_TOR_PROXY_URL GIT_REPO GIT_USER GIT_EMAIL CCR_WEB_AUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN", managed)
                for (position in managed) {
                    known[managed[position]] = 1
                }
            }
            {
                line = $0
                sub(/^[[:space:]]*export[[:space:]]+/, "", line)
                if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                    next
                }
                name = line
                sub(/=.*/, "", name)
                if (!known[name] && !seen[name]++) {
                    print line
                }
            }
        ' "$CONFIG_FILE" > "$extra_file"
    fi

    umask 077
    {
        echo "# BASTION configuration"
        echo "# Generated and maintained by ./bastion. Edit values, not section headers."
        echo
        echo "# Network"
        echo "# Public address or DNS name used by WireGuard clients."
        _wc_kv WIREGUARD_SERVERURL "$WIREGUARD_SERVERURL"
        echo "# UDP port exposed by the WireGuard server."
        _wc_kv WIREGUARD_SERVERPORT "$WIREGUARD_SERVERPORT"
        echo "# Number of WireGuard peer profiles to generate."
        _wc_kv WIREGUARD_PEERS "$WIREGUARD_PEERS"
        echo
        echo "# Bitcoin and Core Lightning"
        echo "# Alias announced by the Core Lightning node."
        _wc_kv NODE_ALIAS "$NODE_ALIAS"
        echo
        echo "# Host and access defaults"
        echo "# Container and host timezone."
        _wc_kv TIMEZONE "$TIMEZONE"
        echo "# Host UID/GID used by services that support non-root execution."
        _wc_kv USER_ID "$USER_ID"
        _wc_kv GROUP_ID "$GROUP_ID"
        echo "# Pi-hole web administration password."
        _wc_kv PIHOLE_PASSWORD "$PIHOLE_PASSWORD"
        echo
        echo "# Optional Bastion services"
        echo "# LXMF identity allowed to access the bridge."
        _wc_kv LXMF_ALLOWED_IDENTITY "$LXMF_ALLOWED_IDENTITY"
        echo
        echo "# CodeDeck+"
        echo "# Comma-separated trusted Nostr relay URLs."
        _wc_kv CODEDECK_RELAYS "$CODEDECK_RELAYS"
        echo "# SOCKS5 proxy used for CodeDeck relay connections."
        _wc_kv CODEDECK_TOR_PROXY_URL "$CODEDECK_TOR_PROXY_URL"
        echo "# Optional comma-separated Git repositories cloned into CodeDeck workspaces."
        _wc_kv GIT_REPO "$GIT_REPO"
        echo "# Optional Git identity used by CodeDeck."
        _wc_kv GIT_USER "$GIT_USER"
        _wc_kv GIT_EMAIL "$GIT_EMAIL"
        echo
        echo "# Claude Code Router"
        echo "# Authentication token for the CCR web UI."
        _wc_kv CCR_WEB_AUTH_TOKEN "$CCR_WEB_AUTH_TOKEN"
        echo "# 1 lets Claude Code populate its model picker from the gateway's /v1/models."
        _wc_kv CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "$CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"
        echo
        echo "# CodeDeck Claude authentication"
        echo "# Required by CodeDeck+; keep this file private."
        _wc_kv CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN"
        echo "# Optional GitHub token for CodeDeck repository operations."
        _wc_kv GITHUB_TOKEN "$GITHUB_TOKEN"
        if [ -s "$extra_file" ]; then
            echo
            echo "# Additional custom variables"
            cat "$extra_file"
        fi
    } > "$temp_file"

    mv "$temp_file" "$CONFIG_FILE"
    rm -f "$extra_file"
}

# Managed configuration keys, in display order. Kept in sync with write_config's
# section layout and the awk allowlist above. The interactive editor (utils/tui.sh)
# iterates this.
MANAGED_VARS=(
    WIREGUARD_SERVERURL WIREGUARD_SERVERPORT WIREGUARD_PEERS
    NODE_ALIAS
    TIMEZONE USER_ID GROUP_ID PIHOLE_PASSWORD
    LXMF_ALLOWED_IDENTITY
    CODEDECK_RELAYS CODEDECK_TOR_PROXY_URL GIT_REPO GIT_USER GIT_EMAIL
    CCR_WEB_AUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY
    CLAUDE_CODE_OAUTH_TOKEN GITHUB_TOKEN
)

# Keys whose value should be masked in any UI.
config_var_is_secret() {
    case "$1" in
        PIHOLE_PASSWORD|CCR_WEB_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|GITHUB_TOKEN) return 0 ;;
        *) return 1 ;;
    esac
}

# Read one managed value straight from the config file (no sourcing). Decodes
# the KEY='...' form write_config produces (including '\'' -> ' un-escaping),
# and tolerates a legacy unquoted or double-quoted value.
read_env_var() {
    [ -f "$CONFIG_FILE" ] || return 0
    local line val
    line=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$CONFIG_FILE" 2>/dev/null) || return 0
    val=${line#*=}
    if [[ $val == \'*\' ]]; then
        val=${val:1:${#val}-2}
        val=${val//\'\\\'\'/\'}
    elif [[ $val == \"*\" ]]; then
        val=${val:1:${#val}-2}
    fi
    printf '%s' "$val"
}

# Validate a proposed value for a managed key. Prints an error and returns 1 on
# failure; returns 0 (silent) when acceptable. Empty is allowed for optional keys.
validate_env_value() {
    local key="$1" val="$2"
    case "$key" in
        WIREGUARD_SERVERPORT)
            [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ] \
                || { echo "must be a port number 1-65535"; return 1; } ;;
        WIREGUARD_PEERS|USER_ID|GROUP_ID)
            [[ "$val" =~ ^[0-9]+$ ]] || { echo "must be a non-negative integer"; return 1; } ;;
        WIREGUARD_SERVERURL)
            [ -n "$val" ] || { echo "required (public IP or hostname)"; return 1; }
            [[ "$val" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "not a valid host/IP"; return 1; } ;;
        NODE_ALIAS)
            [ "${#val}" -le 32 ] || { echo "max 32 characters"; return 1; } ;;
        TIMEZONE)
            [[ "$val" =~ ^[A-Za-z0-9+_/-]+$ ]] || { echo "not a valid tz name (e.g. Europe/Madrid)"; return 1; } ;;
        CODEDECK_TOR_PROXY_URL)
            [ -z "$val" ] || [[ "$val" =~ ^socks5h?:// ]] \
                || { echo "must start with socks5:// or socks5h://"; return 1; } ;;
        CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY)
            [[ "$val" =~ ^[01]$ ]] || { echo "must be 0 or 1"; return 1; } ;;
        GIT_EMAIL)
            [ -z "$val" ] || [[ "$val" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] \
                || { echo "not a valid email"; return 1; } ;;
        CODEDECK_RELAYS)
            if [ -n "$val" ]; then
                local _r _old_ifs="$IFS"; IFS=','
                for _r in $val; do
                    _r="${_r#"${_r%%[![:space:]]*}"}"   # ltrim
                    [[ "$_r" =~ ^wss?:// ]] || { IFS="$_old_ifs"; echo "comma-separated ws:// or wss:// URLs"; return 1; }
                done
                IFS="$_old_ifs"
            fi ;;
        *) : ;;  # free-form / optional
    esac
    return 0
}

# Symlink each stack's .env to the root config file.
# BASTION_SKIP_ENV_LINKS=1 skips this (used by the test suite).
link_stack_envs() {
    [ "${BASTION_SKIP_ENV_LINKS:-0}" = 1 ] && return 0
    local stack
    for stack in "${STACKS[@]}"; do
        [ -d "./$stack" ] && ln -sf "../$CONFIG_FILE" "./$stack/.env"
    done
}

# Persist the current environment to the config file and refresh the .env links.
# Used by the interactive editor after changing a value.
save_config() {
    cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    write_config
    link_stack_envs
}

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
    fi

    if [ -z "$WIREGUARD_SERVERPORT" ]; then
        echo -e "${YELLOW}${BOLD}[!] Essential network configuration missing.${NC}"
        echo -en "${CYAN}${BOLD}📝 Enter Public Port for Wireguard: ${NC}"
        read -r WIREGUARD_SERVERPORT
    fi

    if [ -z "$NODE_ALIAS" ]; then
        echo -en "${CYAN}${BOLD}📝 Enter CLN Node Alias: ${NC}"
        read -r NODE_ALIAS
    fi

    # Defaults and Auto-generation
    declare -A DEFAULTS=(
        ["TIMEZONE"]=$(cat /etc/timezone 2>/dev/null || echo "UTC")
        ["PIHOLE_PASSWORD"]=$(openssl rand -hex 8)
        ["WIREGUARD_PEERS"]="1"
        ["USER_ID"]=$(id -u)
        ["GROUP_ID"]=$(id -g)
        ["LXMF_ALLOWED_IDENTITY"]=""
        ["CODEDECK_RELAYS"]=""
        ["CODEDECK_TOR_PROXY_URL"]="socks5h://tor:9050"
        ["GIT_REPO"]=""
        ["GIT_USER"]=""
        ["GIT_EMAIL"]=""
        ["CCR_WEB_AUTH_TOKEN"]=$(openssl rand -base64 32 | tr -d '=+/\n' | cut -c1-43)
        ["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"]="1"
        ["CLAUDE_CODE_OAUTH_TOKEN"]=""
        ["GITHUB_TOKEN"]=""
    )

    for var in "${!DEFAULTS[@]}"; do
        if [ -z "${!var}" ]; then
            export "$var"="${DEFAULTS[$var]}"
            echo -e "${YELLOW}--> Generated default for $var${NC}"
        fi
    done

    write_config
    link_stack_envs

    echo -e "${GREEN}${BOLD}[✔] Environment variables loaded.${NC}\n"
}
