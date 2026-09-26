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
    [ccr]=stack-ai [codedeck-bridge]=stack-ai [agent-docker]=stack-ai [searxng]=stack-ai [mcp-gateway]=stack-ai
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
# Path to the Sysbox installer (runtime required by the agent-docker sidecar)
SYSBOX_INSTALL_UTIL="${SYSBOX_INSTALL_UTIL:-./utils/install-sysbox.sh}"

# --- STYLING ---
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' 

# --- SETTINGS REGISTRY --------------------------------------------------------
# The ONE place a bastion.conf setting is declared. Everything else is derived
# from this table: the bastion.conf layout and comments, MANAGED_VARS (the TUI
# editor's list), which values are secrets (projected into secrets/ and masked
# in the UI), generated defaults, validation, and the first-run prompts.
# Adding a setting = adding one line here.
#
#   KEY | section | default | type | flags | description
#
# default: a literal, empty, or a generator - @tz (host timezone), @uid / @gid
#          (the invoking user), @hex16 (16 hex chars), @token (43 URL-safe
#          chars). Generators run only when the key is empty.
# type:    host port int posint bool alias tz socks http email relays text
#          (see validate_env_value). An empty value is always accepted unless
#          the key is flagged required; a key with a default is refilled on
#          the next load.
# flags:   comma list of: required (prompted on `up` when empty), secret
#          (written to secrets/<lower_key>, mounted at /run/secrets/...).
BASTION_SETTINGS='
WIREGUARD_SERVERURL|Network||host|required|Public IP or DNS name WireGuard clients connect to.
WIREGUARD_SERVERPORT|Network||port|required|Public UDP port of the WireGuard server.
WIREGUARD_PEERS|Network|1|int||Number of WireGuard peer profiles to generate.
NODE_ALIAS|Bitcoin and Core Lightning||alias|required|Alias announced by the Core Lightning node (max 32 characters).
TIMEZONE|Host and access|@tz|tz||Container and host timezone, e.g. Europe/Madrid.
USER_ID|Host and access|@uid|int||Host UID for services that run unprivileged.
GROUP_ID|Host and access|@gid|int||Host GID for services that run unprivileged.
PIHOLE_PASSWORD|Host and access|@hex16|text|secret|Pi-hole web administration password.
CODEDECK_RELAYS|CodeDeck+||relays||Comma-separated trusted Nostr relay URLs (ws:// or wss://).
CODEDECK_TOR_PROXY_URL|CodeDeck+|socks5h://tor:9050|socks||SOCKS5 proxy for CodeDeck relay connections.
GIT_REPO|CodeDeck+||text||Comma-separated Git repositories cloned into CodeDeck workspaces.
GIT_USER|CodeDeck+||text||Git author name used by CodeDeck.
GIT_EMAIL|CodeDeck+||email||Git author email used by CodeDeck.
CODEDECK_OPENCODE_SERVER_URL|CodeDeck+||http||OpenCode session backend URL (empty = Claude Code only).
CODEDECK_OPENCODE_AUTO_START|CodeDeck+||bool||1 starts an OpenCode server with the bridge (empty = off).
CODEDECK_OPENCODE_PORT|CodeDeck+||port||Port of the auto-started OpenCode server.
CODEDECK_GSD_AUTO_INSTALL|CodeDeck+||bool||1 installs the GSD planning workflow on boot (empty = off).
CLAUDE_CODE_OAUTH_TOKEN|CodeDeck+||text|secret|Claude Code OAuth token used by CodeDeck+.
GITHUB_TOKEN|CodeDeck+||text|secret|GitHub token for CodeDeck repository operations.
CCR_WEB_AUTH_TOKEN|Claude Code Router|@token|text|secret|Token for the CCR web UI.
CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY|Claude Code Router|1|bool||1 lets Claude Code list models from the gateway (/v1/models).
CCR_TOKEN_REFRESH|Claude Code Router|1|bool||1 keeps the CCR OAuth credentials refreshed in-container.
CCR_REFRESH_INTERVAL|Claude Code Router|300|posint||Seconds between refresher checks.
CCR_REFRESH_SKEW_MS|Claude Code Router|1800000|posint||Refresh the access token this many milliseconds before it expires.
MCP_GATEWAY_TOKEN|MCP gateway|@token|text|secret|Bearer token remote MCP clients send to the gateway (:8811).
CONTEXT7_API_KEY|MCP gateway||text|secret|Optional Context7 API key for higher rate limits (empty = keyless).
'

declare -A SETTING_SECTION=() SETTING_DEFAULT=() SETTING_TYPE=() SETTING_FLAGS=() SETTING_DESC=()
MANAGED_VARS=()                # every managed key, in registry (display) order
BASTION_REQUIRED_VARS=()       # the no-default essentials require_essentials asks for
_load_settings_registry() {
    local k s d t f desc
    while IFS='|' read -r k s d t f desc; do
        [ -n "$k" ] || continue
        MANAGED_VARS+=("$k")
        SETTING_SECTION[$k]=$s; SETTING_DEFAULT[$k]=$d; SETTING_TYPE[$k]=$t
        SETTING_FLAGS[$k]=$f;   SETTING_DESC[$k]=$desc
        case ",$f," in *,required,*) BASTION_REQUIRED_VARS+=("$k") ;; esac
    done <<< "$BASTION_SETTINGS"
}
_load_settings_registry

config_is_managed()     { [ -n "${SETTING_TYPE[$1]+set}" ]; }
_setting_has_flag()     { case ",${SETTING_FLAGS[$1]:-}," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
# Keys whose value should be masked in any UI (and projected into secrets/).
config_var_is_secret()  { _setting_has_flag "$1" secret; }

# Resolve a key's default, running its generator if it has one.
_setting_default() {
    case "${SETTING_DEFAULT[$1]:-}" in
        @tz)    cat /etc/timezone 2>/dev/null || echo UTC ;;
        @uid)   id -u ;;
        @gid)   id -g ;;
        @hex16) openssl rand -hex 8 ;;
        # 48 bytes -> 64 base64 chars, so stripping +/= still leaves >= 43.
        # (32 bytes gave 44 chars, and every stripped +/ shortened the token.)
        @token) openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-43 ;;
        *)      printf '%s' "${SETTING_DEFAULT[$1]:-}" ;;
    esac
}

# --- bastion.conf format ----------------------------------------------------------
# Written as KEY='value' - single-quoted, so the file is inert even if something
# does source it: "a b; rm -rf ~" or "$(...)" stay data. Bastion itself never
# sources it; config_parse_file reads it line by line.

# Emit "KEY='value'", escaping embedded single quotes as '\''.
_wc_kv() {
    local v=${2//\'/\'\\\'\'}
    printf "%s='%s'\n" "$1" "$v"
}

# Decode the value half of a KEY=... line: 'single' (with '\'' un-escaping),
# "double" (quotes stripped), or a legacy bare value taken literally.
_config_decode() {
    local val=$1
    if [[ $val == \'*\' ]]; then
        val=${val:1:${#val}-2}
        val=${val//\'\\\'\'/\'}
    elif [[ $val == \"*\" ]]; then
        val=${val:1:${#val}-2}
    fi
    printf '%s' "$val"
}

# Parse CONFIG_FILE into CONFIG_VALUES (key -> decoded value) and CONFIG_KEYS
# (keys in order of first appearance). A key assigned twice takes its LAST
# value - the semantics the file had when it was sourced, so an operator who
# appends an override still gets it. Comments, blanks and anything that is not
# KEY=value are ignored; a leading `export ` is tolerated. Nothing in the file
# is ever executed.
declare -A CONFIG_VALUES=()
CONFIG_KEYS=()
config_parse_file() {
    CONFIG_VALUES=(); CONFIG_KEYS=()
    [ -f "$CONFIG_FILE" ] || return 0
    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key=${BASH_REMATCH[2]}
        [ -n "${CONFIG_VALUES[$key]+set}" ] || CONFIG_KEYS+=("$key")
        CONFIG_VALUES[$key]=$(_config_decode "${BASH_REMATCH[3]}")
    done < "$CONFIG_FILE"
}

# Read one value straight from the config file.
read_env_var() {
    config_parse_file
    printf '%s' "${CONFIG_VALUES[$1]:-}"
}

# Render the whole file from the current environment (managed keys, grouped by
# registry section, each with its description) plus every non-managed key found
# in the existing file, verbatim-decoded, under "Additional custom variables".
_render_config() {
    local k section="" extras=()
    config_parse_file
    for k in "${CONFIG_KEYS[@]}"; do config_is_managed "$k" || extras+=("$k"); done
    echo "# BASTION configuration"
    echo "# Generated and maintained by ./bastion. Edit values, not section headers."
    for k in "${MANAGED_VARS[@]}"; do
        if [ "${SETTING_SECTION[$k]}" != "$section" ]; then
            section=${SETTING_SECTION[$k]}
            echo; echo "# $section"
        fi
        echo "# ${SETTING_DESC[$k]}"
        _wc_kv "$k" "${!k-}"
    done
    if [ "${#extras[@]}" -gt 0 ]; then
        echo; echo "# Additional custom variables"
        for k in "${extras[@]}"; do _wc_kv "$k" "${CONFIG_VALUES[$k]}"; done
    fi
}

# Write CONFIG_FILE (mode 600) - but only when the content actually changes, so
# read-only commands (status, logs, the TUI) leave the file untouched.
write_config() {
    local tmp
    tmp=$(umask 077; mktemp "${CONFIG_FILE}.XXXXXX") || return 1
    _render_config > "$tmp"
    if [ -f "$CONFIG_FILE" ] && cmp -s "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$CONFIG_FILE"
    fi
}

# Validate a proposed value for a managed key. Prints an error and returns 1 on
# failure; returns 0 (silent) when acceptable.
validate_env_value() {
    local key="$1" val="$2"
    if [ -z "$val" ]; then
        _setting_has_flag "$key" required && { echo "required"; return 1; }
        return 0
    fi
    case "${SETTING_TYPE[$key]:-text}" in
        host)   [[ "$val" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "not a valid host/IP"; return 1; } ;;
        port)   [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ] \
                    || { echo "must be a port number 1-65535"; return 1; } ;;
        int)    [[ "$val" =~ ^[0-9]+$ ]] || { echo "must be a non-negative integer"; return 1; } ;;
        posint) [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] || { echo "must be a positive integer"; return 1; } ;;
        bool)   [[ "$val" =~ ^[01]$ ]] || { echo "must be 0 or 1"; return 1; } ;;
        alias)  [ "${#val}" -le 32 ] || { echo "max 32 characters"; return 1; } ;;
        tz)     [[ "$val" =~ ^[A-Za-z0-9+_/-]+$ ]] || { echo "not a valid tz name (e.g. Europe/Madrid)"; return 1; } ;;
        socks)  [[ "$val" =~ ^socks5h?:// ]] || { echo "must start with socks5:// or socks5h://"; return 1; } ;;
        http)   [[ "$val" =~ ^https?:// ]] || { echo "must start with http:// or https://"; return 1; } ;;
        email)  [[ "$val" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || { echo "not a valid email"; return 1; } ;;
        relays)
            local _r _old_ifs="$IFS"; IFS=','
            for _r in $val; do
                _r="${_r#"${_r%%[![:space:]]*}"}"   # ltrim
                [[ "$_r" =~ ^wss?:// ]] || { IFS="$_old_ifs"; echo "comma-separated ws:// or wss:// URLs"; return 1; }
            done
            IFS="$_old_ifs" ;;
        *) : ;;  # text: free-form
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
    local var f val cur
    for var in "${MANAGED_VARS[@]}"; do
        config_var_is_secret "$var" || continue
        f="$SECRETS_DIR/${var,,}"
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
# and the derived secret files.
save_config() {
    cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    write_config
    link_stack_envs
    write_secret_files
}

# Change one managed setting: validate it, persist it (keeping every other value
# exactly as it is in the file), and refresh the derived files. Prints the
# validation error and returns 1 when the value is rejected.
config_set() {
    local key="$1" val="$2" err k
    config_is_managed "$key" || { echo "unknown setting: $key"; return 1; }
    err=$(validate_env_value "$key" "$val") || { echo "$err"; return 1; }
    config_parse_file
    (
        for k in "${CONFIG_KEYS[@]}"; do export "$k=${CONFIG_VALUES[$k]}"; done
        export "$key=$val"
        save_config
    ) || return 1
    export "$key=$val"
}

# Load bastion.conf into the environment and fill in the defaults. No prompts
# and no output on the happy path - safe to call for every command (status,
# logs, the TUI, ...), not just "up". Values in the file win over the caller's
# environment. The file is normalised (and derived files refreshed) only when
# something actually changed.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        ( umask 077; touch "$CONFIG_FILE" )
        echo -e "${YELLOW}[!] Created $CONFIG_FILE${NC}"
    fi

    local k
    config_parse_file
    for k in "${CONFIG_KEYS[@]}"; do export "$k=${CONFIG_VALUES[$k]}"; done
    for k in "${MANAGED_VARS[@]}"; do
        [ -n "${!k-}" ] || export "$k=$(_setting_default "$k")"
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
        [ -z "${!var-}" ] && missing_vars+=("$var")
    done
    [ "${#missing_vars[@]}" -eq 0 ] && return 0

    if [ ! -t 0 ]; then
        echo -e "${RED}${BOLD}[✘] Required configuration not set: ${missing_vars[*]}${NC}" >&2
        echo -e "    Add them to ${BOLD}$CONFIG_FILE${NC}, or run ${BOLD}./bastion${NC} and open" >&2
        echo -e "    the Configuration view, then retry." >&2
        return 1
    fi

    echo -e "${YELLOW}${BOLD}[!] A few required values are not set yet.${NC}"
    local val err
    for var in "${missing_vars[@]}"; do
        while :; do
            echo -en "${CYAN}${BOLD}${SETTING_DESC[$var]} ${NC}${BOLD}[$var]: ${NC}"
            read -r val
            if err=$(validate_env_value "$var" "$val"); then
                export "$var"="$val"
                break
            fi
            echo -e "${RED}  ${err}${NC}"
        done
    done

    save_config
    echo -e "${GREEN}[✔] Saved to $CONFIG_FILE.${NC}\n"
}

# --- First-run seeding (idempotent, never touches an existing install) ------

# Copy $1 -> $2, but ONLY when $2 does not exist yet - a populated data/ dir is
# left exactly as it is. Missing source is a silent no-op. Never returns
# non-zero: seeding must never abort a boot.
_seed_file() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    [ -e "$dst" ] && return 0
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst" && echo -e "${YELLOW}--> Seeded ${dst} from template${NC}"
    return 0
}

# "template:target" pairs, relative to the repo root, seeded on every
# `./bastion up` that includes stack-bitcoin.
SEED_TEMPLATES=(
    "stack-bitcoin/config/RTL-Config.json:stack-bitcoin/data/rtl/RTL-Config.json"
)
seed_runtime_config() {
    local pair
    for pair in "${SEED_TEMPLATES[@]}"; do
        _seed_file "${pair%%:*}" "${pair##*:}"
    done
}

# teosd reads teos.toml from its data dir (mounted at /home/teos/.teos); with no
# file rust-teos silently falls back to compiled-in defaults - api_bind
# 127.0.0.1, no Tor, bitcoind on localhost - and comes up unreachable at its
# pinned transit address. Seed the Bastion template (which carries api_bind
# 10.254.0.11 / tor_control_host 10.254.0.2) when teosd is about to start and
# the operator has no teos.toml of their own yet. Overridable for tests.
TEOS_SEED_SRC="${TEOS_SEED_SRC:-stack-bitcoin/config/teos.toml}"
TEOS_SEED_DST="${TEOS_SEED_DST:-stack-bitcoin/data/teos/teos.toml}"
seed_teos_config() {
    _seed_file "$TEOS_SEED_SRC" "$TEOS_SEED_DST"
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
    # Tolerate a JSON response too (if a CLN build ignores -F for createrune).
    [ -n "$rune" ] || rune=$(printf '%s' "$out" \
        | sed -n 's/.*"rune"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$rune" ]; then
        echo -e "${YELLOW}[!] Could not parse a rune from CLN output - skipped.${NC}"
        return 0
    fi
    mkdir -p "$(dirname "$RTL_RUNE_FILE")"
    ( umask 077; printf 'LIGHTNING_RUNE="%s"\n' "$rune" > "$RTL_RUNE_FILE" )
    chmod 600 "$RTL_RUNE_FILE" 2>/dev/null || true
    echo -e "${GREEN}[✔] Wrote ${RTL_RUNE_FILE}${NC}"
}
