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
# Honour a pre-set CONFIG_FILE (the test suite points this at a scratch file);
# default to the repo-root config otherwise.
CONFIG_FILE="${CONFIG_FILE:-./bastion.conf}"
# Deployment order is crucial: Network must be first.
STACKS=("stack-network" "stack-bitcoin" "stack-monitor" "stack-web" "stack-ai")
# The foundation stack: it creates the bastion-transit network and the
# bastion-tor-data volume and runs Tor. Every "up" brings it up first; it
# cannot be brought down while any other stack is running.
NETWORK_STACK="stack-network"

# Which stack each container belongs to (used to tell which stacks are up).
# This is the single source of truth: tests/static/validate-config.sh asserts it
# stays in exact sync with the compose service list, and utils/tui.sh derives its
# STACK_OF_CONTAINER from it.
declare -A CONTAINER_STACK=(
    [pihole]=stack-network [unbound]=stack-network [wireguard]=stack-network [tor]=stack-network
    [bitcoind]=stack-bitcoin [lightningd]=stack-bitcoin [rtl]=stack-bitcoin [teosd]=stack-bitcoin
    [portainer]=stack-monitor [grafana]=stack-monitor [prometheus]=stack-monitor [node-exporter]=stack-monitor
    [hub]=stack-web
    [ccr]=stack-ai [codedeck-bridge]=stack-ai
)

# Test hook: BASTION_EXTRA_CONTAINER_STACK="name=dir[,name2=dir2]" registers extra
# container -> compose-dir entries so an integration test can drive the
# per-container verbs against an isolated compose project without going near a
# real stack. Not used in normal operation.
if [ -n "${BASTION_EXTRA_CONTAINER_STACK:-}" ]; then
    _ecs_ifs=$IFS; IFS=','
    for _ecs in $BASTION_EXTRA_CONTAINER_STACK; do
        [ -n "$_ecs" ] && CONTAINER_STACK["${_ecs%%=*}"]="${_ecs#*=}"
    done
    IFS=$_ecs_ifs; unset _ecs _ecs_ifs
fi

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

# Derive one file per secret under secrets/ (git-ignored, mode 600, dir 700),
# from the values in bastion.conf. bastion.conf stays the single file the
# operator edits; this just projects the secrets into the shape Docker Compose
# `secrets:` mounts, so a consuming container gets its secret as a file at
# /run/secrets/<name> instead of a plaintext env var visible in `docker inspect`.
# Rewrites a file only when its value changed. File name = lower-cased var name.
# Lives next to CONFIG_FILE (so ./secrets in prod, and a scratch dir under a
# test's CONFIG_FILE), which is exactly what the compose `file: ../secrets/<x>`
# entries expect.
SECRETS_DIR="${SECRETS_DIR:-$(dirname "${CONFIG_FILE:-./bastion.conf}")/secrets}"
write_secret_files() {
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR" 2>/dev/null || true
    local var name f val cur
    for var in "${MANAGED_VARS[@]}"; do
        config_var_is_secret "$var" || continue
        name=$(printf '%s' "$var" | tr 'A-Z' 'a-z')
        f="$SECRETS_DIR/$name"
        val="${!var-}"
        cur=""; [ -f "$f" ] && cur=$(cat "$f")
        # Always materialise the file (Compose `file:` needs it to exist even
        # when the value is empty), but only rewrite when the value changed.
        if [ ! -f "$f" ] || [ "$val" != "$cur" ]; then
            ( umask 177; printf '%s' "$val" > "$f" )
            chmod 600 "$f" 2>/dev/null || true
        fi
    done
}

# Persist the current environment to the config file and refresh the .env links
# and the derived secret files. Used by the interactive editor after a change.
save_config() {
    cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    write_config
    link_stack_envs
    write_secret_files
}

# Values that have no sensible default and that only matter when starting
# containers. require_essentials() (below) is the only thing that asks for them,
# and only for commands that boot a stack.
BASTION_REQUIRED_VARS=(WIREGUARD_SERVERURL WIREGUARD_SERVERPORT NODE_ALIAS)

# Load bastion.conf into the environment and fill in the generated defaults.
# No prompts and no output on the happy path - safe to call for every command
# (status, logs, the TUI, ...), not just "up". Re-writes the normalised file and
# refreshes the per-stack .env links.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo -e "${YELLOW}[!] Created $CONFIG_FILE${NC}"
    fi

    set -a
    # shellcheck disable=SC1090
    source <(sed 's/^export //g' "$CONFIG_FILE" | grep -v '^[[:space:]]*#')
    set +a

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

    local var
    for var in "${!DEFAULTS[@]}"; do
        [ -z "${!var}" ] && export "$var"="${DEFAULTS[$var]}"
    done

    write_config
    link_stack_envs
    write_secret_files
}

# Ensure the no-default essentials are set. On a terminal, prompt for whatever is
# missing (validated) and persist it; with no terminal, fail with instructions.
# Call this only for commands that actually start containers.
require_essentials() {
    local var missing_vars=()
    for var in "${BASTION_REQUIRED_VARS[@]}"; do
        [ -z "${!var}" ] && missing_vars+=("$var")
    done
    [ "${#missing_vars[@]}" -eq 0 ] && return 0

    if [ ! -t 0 ]; then
        echo -e "${RED}${BOLD}[✘] Required configuration not set: ${missing_vars[*]}${NC}" >&2
        echo -e "    Add them to ${BOLD}$CONFIG_FILE${NC}, or run ${BOLD}./bastion${NC} and open" >&2
        echo -e "    the Configuration view, then retry." >&2
        return 1
    fi

    echo -e "${YELLOW}${BOLD}[!] A few required values are not set yet.${NC}"
    local val err prompt
    for var in "${missing_vars[@]}"; do
        case "$var" in
            WIREGUARD_SERVERURL)  prompt="Public IP or domain for WireGuard" ;;
            WIREGUARD_SERVERPORT) prompt="Public UDP port for WireGuard" ;;
            NODE_ALIAS)           prompt="Core Lightning node alias" ;;
            *)                    prompt="$var" ;;
        esac
        while :; do
            echo -en "${CYAN}${BOLD}${prompt}: ${NC}"
            read -r val
            if [ -n "$val" ] && err=$(validate_env_value "$var" "$val"); then
                export "$var"="$val"
                break
            fi
            echo -e "${RED}  ${err:-a value is required}${NC}"
        done
    done

    write_config
    link_stack_envs
    write_secret_files
    echo -e "${GREEN}[✔] Saved to $CONFIG_FILE.${NC}\n"
}

# --- First-run seeding (idempotent, never touches an existing install) ------

# template:target pairs, relative to the repo root. A target is seeded from its
# template ONLY when the target does not exist yet - a populated data/ dir is
# left exactly as it is.
SEED_TEMPLATES=(
    "stack-bitcoin/config/RTL-Config.json:stack-bitcoin/data/rtl/RTL-Config.json"
)
seed_runtime_config() {
    local pair src dst
    for pair in "${SEED_TEMPLATES[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        [ -f "$src" ] || continue
        [ -e "$dst" ] && continue
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo -e "${YELLOW}--> Seeded ${dst} from template${NC}"
    done
}

# Mint an RTL access rune from CLN when there isn't one yet. RTL reads
# stack-bitcoin/data/rtl/access.rune as LIGHTNING_RUNE="<rune>" (runePath in
# RTL-Config.json). Needs lightningd running; if it is not ready this warns and
# returns 0 (RTL retries; `./bastion up` can be re-run). Never aborts the boot.
RTL_RUNE_FILE="${RTL_RUNE_FILE:-stack-bitcoin/data/rtl/access.rune}"
ensure_rtl_rune() {
    [ -e "$RTL_RUNE_FILE" ] && return 0            # respect an existing install

    echo -e "${CYAN}--> RTL: no access.rune yet - minting one from CLN...${NC}"
    local i out rune
    local tries="${RTL_RUNE_RETRIES:-20}" wait="${RTL_RUNE_WAIT:-2}"
    for (( i=0; i<tries; i++ )); do
        out=$(docker exec lightningd lightning-cli -F createrune 2>/dev/null) && [ -n "$out" ] && break
        out=""; [ "$wait" -gt 0 ] && sleep "$wait"
    done
    if [ -z "$out" ]; then
        echo -e "${YELLOW}[!] CLN not reachable yet - skipped. Re-run './bastion up' once it is,${NC}"
        echo -e "${YELLOW}    or write ${RTL_RUNE_FILE} yourself as LIGHTNING_RUNE=\"<rune>\".${NC}"
        return 0
    fi
    rune=$(printf '%s\n' "$out" | sed -n 's/^rune=//p' | head -1)
    if [ -z "$rune" ]; then
        echo -e "${YELLOW}[!] Could not parse a rune from CLN output - skipped.${NC}"
        return 0
    fi
    mkdir -p "$(dirname "$RTL_RUNE_FILE")"
    ( umask 077; printf 'LIGHTNING_RUNE="%s"\n' "$rune" > "$RTL_RUNE_FILE" )
    chmod 600 "$RTL_RUNE_FILE" 2>/dev/null || true
    echo -e "${GREEN}[✔] Wrote ${RTL_RUNE_FILE}${NC}"
}
