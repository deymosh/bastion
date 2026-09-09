#!/bin/bash
################################################################################
# BASTION - Interactive TUI
#
# A pure-bash full-screen dashboard for ./bastion. No gum/whiptail/dialog.
# Sourced by ./bastion; entered with `./bastion` (no args, on a TTY) or
# `./bastion tui`. Every action here also has a non-interactive CLI path, so the
# TUI is a convenience layer, never the only way in.
#
# Depends on: config.sh (already sourced) for STACKS, MANAGED_VARS,
# read_env_var, validate_env_value, config_var_is_secret, save_config,
# and the styling vars. Also uses the command runners defined in ./bastion
# (compose_action / wait_for_health).
################################################################################

# --- Theme -------------------------------------------------------------------
tui_setup_theme() {
    local c256=0
    case "${COLORTERM:-}" in truecolor|24bit) c256=1 ;; esac
    case "${TERM:-}" in *256color*) c256=1 ;; esac

    E=$'\033'
    T_RESET="${E}[0m"; T_BOLD="${E}[1m"
    if [ "$c256" = 1 ]; then
        T_TITLE="${E}[38;5;15m";     T_SUB="${E}[38;5;245m"
        T_ACCENT="${E}[38;5;214m";   T_MENU="${E}[38;5;252m"
        T_MENU_DIM="${E}[38;5;243m"; T_LINE="${E}[38;5;240m"
        T_OK="${E}[38;5;78m";        T_WARN="${E}[38;5;221m"
        T_ERR="${E}[38;5;203m";      T_SEL_BG="${E}[48;5;24m"
        T_BAR_BG="${E}[48;5;236m"
    else
        T_TITLE="${E}[97m";   T_SUB="${E}[37m"
        T_ACCENT="${E}[33m";  T_MENU="${E}[37m"
        T_MENU_DIM="${E}[90m"; T_LINE="${E}[90m"
        T_OK="${E}[32m";      T_WARN="${E}[33m"
        T_ERR="${E}[31m";     T_SEL_BG="${E}[44m"
        T_BAR_BG="${E}[100m"
    fi
}

# --- Terminal lifecycle ----------------------------------------------------
TUI_ACTIVE=0
_tui_saved_stty=""

tui_init() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "The TUI needs an interactive terminal. Use ./bastion <command> instead." >&2
        exit 1
    fi
    tui_setup_theme
    _tui_saved_stty=$(stty -g 2>/dev/null || true)
    stty -echo -icanon time 0 min 0 2>/dev/null || true
    printf '%s' "${E}[?1049h${E}[?25l"   # alt screen, hide cursor
    TUI_ACTIVE=1
    trap tui_cleanup EXIT
    trap 'TUI_RESIZED=1' WINCH
    trap 'tui_cleanup; exit 130' INT TERM
    tui_update_layout
}

tui_cleanup() {
    [ "$TUI_ACTIVE" = 1 ] || return 0
    TUI_ACTIVE=0
    printf '%s' "${E}[?25h${E}[?1049l"   # show cursor, leave alt screen
    [ -n "$_tui_saved_stty" ] && stty "$_tui_saved_stty" 2>/dev/null || stty sane 2>/dev/null || true
    trap - EXIT WINCH INT TERM
}

# Run something outside the alt screen (for streaming logs, interactive login).
tui_suspend() {
    printf '%s' "${E}[?25h${E}[?1049l"
    [ -n "$_tui_saved_stty" ] && stty "$_tui_saved_stty" 2>/dev/null || stty sane 2>/dev/null || true
    "$@"
    local rc=$?
    stty -echo -icanon time 0 min 0 2>/dev/null || true
    printf '%s' "${E}[?1049h${E}[?25l"
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
    return $rc
}

# --- Layout --------------------------------------------------------------
tui_update_layout() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    LINES=$(tput lines 2>/dev/null || echo 24)
    [ "$COLS" -lt 60 ] && COLS=60
    [ "$LINES" -lt 16 ] && LINES=16
    LEFT_W=$(( COLS * 38 / 100 )); [ "$LEFT_W" -lt 30 ] && LEFT_W=30
    _LW=$(( LEFT_W - 3 ))                 # writable width of the left column
    RIGHT_X=$(( LEFT_W + 2 ))
    RIGHT_W=$(( COLS - RIGHT_X - 1 ))
    CONTENT_TOP=4
    CONTENT_BOT=$(( LINES - 2 ))
    TUI_RESIZED=0
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

_at()  { printf '%s' "${E}[${1};${2}H"; }
# Erase exactly N cells from the cursor without moving it or touching the rest
# of the line (so pane borders and the other pane survive). ECH is vt100/xterm.
_erase() { printf '%s' "${E}[${1}X"; }
# Erase the left content column (from col 3 to the divider).
_clr_to() { printf '%s' "${E}[${_LW:-40}X"; }

# repeat a single-cell string N times
_rep() { local s=$1 n=$2 o=''; while [ "$n" -gt 0 ]; do o+=$s; n=$((n-1)); done; printf '%s' "$o"; }

# --- Input -------------------------------------------------------------
_KEY=""
# Discard any bytes already sitting in the terminal buffer (used before a
# text prompt so held/repeated navigation keys don't leak into the field).
# The generous per-read timeout lets an in-flight burst land before we stop.
tui_flush_input() { local _x; while IFS= read -rsn1 -t 0.1 _x; do :; done; }

tui_read_key() {
    _KEY=""
    local c=""
    IFS= read -rsn1 -t 0.4 c || { _KEY="_timeout"; return 0; }
    case "$c" in
        "$E")
            local c2="" c3=""
            IFS= read -rsn1 -t 0.06 c2 || { _KEY="esc"; return 0; }
            if [ "$c2" = "[" ] || [ "$c2" = "O" ]; then
                IFS= read -rsn1 -t 0.06 c3 || true
                case "$c3" in
                    A) _KEY="up" ;; B) _KEY="down" ;;
                    C) _KEY="right" ;; D) _KEY="left" ;;
                    *) _KEY="esc" ;;
                esac
            else _KEY="esc"; fi ;;
        "") _KEY="enter" ;;
        $'\n'|$'\r') _KEY="enter" ;;
        " ") _KEY="space" ;;
        $'\t') _KEY="tab" ;;
        $'\x7f'|$'\x08') _KEY="backspace" ;;
        q|Q) _KEY="q" ;;
        *) _KEY="char:$c" ;;
    esac
}

# --- Reusable widgets (drawn in the left pane) --------------------------
# tui_confirm "prompt" [default y|n]  -> returns 0 for Yes, 1 for No
tui_confirm() {
    local prompt="$1" def="${2:-y}" sel=0
    [ "$def" = n ] && sel=1
    tui_flush_input
    local row=$(( CONTENT_TOP + 3 )) _r
    for (( _r=CONTENT_TOP; _r<=row && _r<=CONTENT_BOT; _r++ )); do _at "$_r" 3; _clr_to; done
    local wrapped; wrapped=$(printf '%s' "$prompt" | fold -s -w "$_LW")
    while true; do
        _r=$CONTENT_TOP
        while IFS= read -r _pl; do _at "$_r" 3; _clr_to; printf '%b%s%b' "${T_BOLD}${T_ACCENT}" "$_pl" "$T_RESET"; _r=$((_r+1)); [ "$_r" -ge "$row" ] && break; done <<< "$wrapped"
        _at "$row" 3; _clr_to
        if [ "$sel" -eq 0 ]; then
            printf '%b  Yes  %b   %b  No  %b' "${T_BOLD}${T_SEL_BG}${T_TITLE}" "$T_RESET" "$T_MENU_DIM" "$T_RESET"
        else
            printf '%b  Yes  %b   %b  No  %b' "$T_MENU_DIM" "$T_RESET" "${T_BOLD}${T_SEL_BG}${T_TITLE}" "$T_RESET"
        fi
        tui_read_key
        case "$_KEY" in
            left|up|right|down|tab) sel=$(( sel ^ 1 )) ;;
            enter) TUI_NEED_MENU=1; return $sel ;;
            q|esc) TUI_NEED_MENU=1; return 1 ;;
        esac
    done
}

# tui_prompt "label" "default"  -> echoes the entered value (default if left blank).
# Uses canonical line mode for the duration: the terminal handles editing
# (backspace, ^U), one clean read, no fragile escape-sequence parsing.
tui_prompt() {
    local label="$1" def="$2" buf=""
    # All drawing goes to /dev/tty: the caller captures this function's stdout
    # ($(tui_prompt ...)), so only the final value may be written there.
    {
        sleep 0.08
        tui_flush_input </dev/tty
        stty icanon echo 2>/dev/null || true
        local _r
        for (( _r=CONTENT_TOP; _r<=CONTENT_TOP+4 && _r<=CONTENT_BOT; _r++ )); do _at "$_r" 3; _clr_to; done
        _at "$CONTENT_TOP" 3
        printf '%b%s%b' "${T_BOLD}${T_ACCENT}" "$label" "$T_RESET"
        _at $(( CONTENT_TOP + 1 )) 3; _clr_to
        [ -n "$def" ] && printf '%bEnter alone = keep "%s"%b' "$T_MENU_DIM" "$def" "$T_RESET"
        _at $(( CONTENT_TOP + 3 )) 3; _clr_to
        printf '%b> %b%s' "$T_ACCENT" "$T_RESET" "${E}[?25h"
    } >/dev/tty
    IFS= read -r buf </dev/tty || buf=""
    { stty -icanon -echo min 0 time 0 2>/dev/null || true
      printf '%s' "${E}[?25l"; } >/dev/tty
    buf="${buf//[$'\x00'-$'\x1f']/}"      # strip any stray control chars
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
    [ -z "$buf" ] && printf '%s' "$def" || printf '%s' "$buf"
}

# tui_message "title" "body..."   (body may contain newlines)
tui_message() {
    local title="$1" body="$2"
    TUI_NEED_FRAME=1; tui_draw_frame; tui_render_right
    _at "$CONTENT_TOP" 3; printf '%b%s%b' "${T_BOLD}${T_ACCENT}" "$title" "$T_RESET"
    _at $(( CONTENT_TOP + 1 )) 3; printf '%b%s%b' "$T_LINE" "$(_rep '─' "$_LW")" "$T_RESET"
    local r=$(( CONTENT_TOP + 2 ))
    local wrapped; wrapped=$(printf '%s\n' "$body" | fold -s -w "$_LW")
    while IFS= read -r line; do
        [ "$r" -gt $(( CONTENT_BOT - 1 )) ] && break
        _at "$r" 3; _clr_to; printf '%b%s%b' "$T_MENU" "$line" "$T_RESET"
        r=$((r+1))
    done <<< "$wrapped"
    _at "$CONTENT_BOT" 3; printf '%bPress any key to continue%b' "$T_MENU_DIM" "$T_RESET"
    tui_flush_input
    stty -icanon min 1 time 0 2>/dev/null || true
    IFS= read -rsn1    # any key; value goes to $REPLY, unused
    stty -icanon min 0 time 0 2>/dev/null || true
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

# Run a command with output captured; on failure show it in a message box.
tui_run() {
    local title="$1"; shift
    local out rc
    _at "$CONTENT_BOT" 3; _clr_to; printf '%b%s...%b' "$T_ACCENT" "$title" "$T_RESET"
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        tui_message "$title failed (exit $rc)" "$out"
    else
        TUI_NEED_RIGHT=1
    fi
    return $rc
}

# --- Status board (right pane) ---------------------------------------
declare -A STACK_OF_CONTAINER=(
    [pihole]=network [unbound]=network [wireguard]=network [tor]=network
    [bitcoind]=bitcoin [lightningd]=bitcoin [rtl]=bitcoin [teosd]=bitcoin
    [portainer]=monitor [grafana]=monitor [prometheus]=monitor [node-exporter]=monitor
    [hub]=web
    [ccr]=ai [codedeck-bridge]=ai
)
TUI_STATUS_LINES=()
TUI_STATUS_AT=-10

tui_refresh_status() {
    local now=$SECONDS
    # Throttle, but always run the first time (before we have any lines).
    if [ "${#TUI_STATUS_LINES[@]}" -gt 0 ] && [ $(( now - TUI_STATUS_AT )) -lt 2 ]; then
        return 0
    fi
    TUI_STATUS_AT=$now
    TUI_STATUS_LINES=()

    local dock="up"
    docker info >/dev/null 2>&1 || dock="down"
    TUI_STATUS_LINES+=("${T_SUB}docker:${T_RESET} $([ "$dock" = up ] && printf '%bup%b' "$T_OK" "$T_RESET" || printf '%bdown%b' "$T_ERR" "$T_RESET")")

    if [ "$dock" = down ]; then TUI_NEED_RIGHT=1; return 0; fi

    local raw; raw=$(docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null)
    local -A st=() ss=()
    while IFS='|' read -r n s status; do
        [ -n "$n" ] || continue
        st["$n"]="$s"; ss["$n"]="$status"
    done <<< "$raw"

    local grp
    for grp in network bitcoin monitor web ai; do
        TUI_STATUS_LINES+=("")
        TUI_STATUS_LINES+=("${T_BOLD}${T_ACCENT}stack-${grp}${T_RESET}")
        local c found=0
        for c in "${!STACK_OF_CONTAINER[@]}"; do
            [ "${STACK_OF_CONTAINER[$c]}" = "$grp" ] || continue
            found=1
            local s="${st[$c]:-}" mark col
            case "$s" in
                running)
                    if printf '%s' "${ss[$c]}" | grep -qi 'healthy'; then mark='●'; col="$T_OK"
                    elif printf '%s' "${ss[$c]}" | grep -qi 'unhealthy'; then mark='●'; col="$T_ERR"
                    else mark='●'; col="$T_OK"; fi ;;
                exited|dead) mark='○'; col="$T_MENU_DIM" ;;
                restarting|paused) mark='◐'; col="$T_WARN" ;;
                *) mark='·'; col="$T_MENU_DIM"; s="absent" ;;
            esac
            TUI_STATUS_LINES+=("  ${col}${mark}${T_RESET} ${T_MENU}$(printf '%-16s' "$c")${T_RESET}${T_MENU_DIM}${s}${T_RESET}")
        done
        [ "$found" = 0 ] && TUI_STATUS_LINES+=("  ${T_MENU_DIM}(no containers)${T_RESET}")
    done
    TUI_NEED_RIGHT=1
}

# --- Frame + panes ---------------------------------------------------
TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
TUI_VIEW="main"
TUI_STACK_BC=""   # breadcrumb tail

tui_draw_frame() {
    [ "$TUI_NEED_FRAME" = 1 ] || return 0
    TUI_NEED_FRAME=0
    printf '%s' "${E}[2J"
    # top / bottom borders
    _at 1 1; printf '%b┌%s┐%b' "$T_LINE" "$(_rep '─' $(( COLS - 2 )))" "$T_RESET"
    _at "$LINES" 1; printf '%b└%s┘%b' "$T_LINE" "$(_rep '─' $(( COLS - 2 )))" "$T_RESET"
    local r
    for (( r=2; r<LINES; r++ )); do
        _at "$r" 1; printf '%b│%b' "$T_LINE" "$T_RESET"
        _at "$r" "$COLS"; printf '%b│%b' "$T_LINE" "$T_RESET"
        _at "$r" "$(( LEFT_W + 1 ))"; printf '%b│%b' "$T_LINE" "$T_RESET"
    done
    # title bar (row 2) + separator (row 3). ASCII only so printf width == columns.
    local titletxt="  BASTION  //  ${TUI_STACK_BC:-Dashboard}"
    _at 2 2; printf '%b%b%-*s%b' "$T_BAR_BG" "${T_BOLD}${T_TITLE}" "$LEFT_W" "${titletxt:0:LEFT_W}" "$T_RESET"
    _at 3 2; printf '%b%s%b' "$T_LINE" "$(_rep '─' "$_LW")" "$T_RESET"
    _at 3 "$RIGHT_X"; printf '%b%s%b' "$T_LINE" "$(_rep '─' "$RIGHT_W")" "$T_RESET"
    # hint bar
    _at "$LINES" 3
    printf '%b %b↑↓%b move  %b⏎%b select  %b␣%b toggle  %b←/esc%b back  %bq%b quit %b' \
        "$T_BAR_BG" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" \
        "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_RESET"
    TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

tui_render_right() {
    [ "$TUI_NEED_RIGHT" = 1 ] || return 0
    TUI_NEED_RIGHT=0
    _at 2 "$RIGHT_X"
    printf '%b%b%-*s%b' "$T_BAR_BG" "${T_BOLD}${T_TITLE}" "$RIGHT_W" "  Status" "$T_RESET"
    local r=$CONTENT_TOP i=0
    for (( i=0; i<${#TUI_STATUS_LINES[@]} && r<=CONTENT_BOT; i++, r++ )); do
        _at "$r" "$RIGHT_X"; _erase "$RIGHT_W"
        _at "$r" "$RIGHT_X"; printf '%b' "${TUI_STATUS_LINES[$i]}"
    done
    for (( ; r<=CONTENT_BOT; r++ )); do _at "$r" "$RIGHT_X"; _erase "$RIGHT_W"; done
}

# --- Menu model ----------------------------------------------------
MENU_IDS=(); MENU_LABELS=(); MENU_SEL=0; MENU_TITLE=""
declare -A STACK_PICK=()

# Config rows are expensive to build (one file read per key), so cache them and
# only rebuild when the view is (re-)entered or a value is saved.
CONFIG_IDS=(); CONFIG_LABELS=(); CONFIG_CACHE_DIRTY=1
tui_build_config_cache() {
    [ "$CONFIG_CACHE_DIRTY" = 1 ] || return 0
    CONFIG_CACHE_DIRTY=0
    CONFIG_IDS=(); CONFIG_LABELS=()
    local k v shown kw vw
    kw=22; [ "$_LW" -lt 40 ] && kw=$(( _LW / 2 ))
    vw=$(( _LW - kw - 1 )); [ "$vw" -lt 6 ] && vw=6
    for k in "${MANAGED_VARS[@]}"; do
        v=$(read_env_var "$k")
        if config_var_is_secret "$k"; then
            [ -n "$v" ] && shown="********" || shown="(unset)"
        else
            shown="${v:-(unset)}"
            [ "${#shown}" -gt "$vw" ] && shown="${shown:0:vw-1}~"
        fi
        CONFIG_IDS+=("$k")
        CONFIG_LABELS+=("$(printf '%-*.*s %s' "$kw" "$kw" "$k" "$shown")")
    done
}

tui_build_menu() {
    MENU_IDS=(); MENU_LABELS=()
    case "$TUI_VIEW" in
        main)
            TUI_STACK_BC="Dashboard"
            MENU_TITLE="Main menu"
            MENU_IDS=(deploy stop down build logs config status audit quit)
            MENU_LABELS=("▸ Deploy stacks" "■ Stop stacks" "⨯ Down (remove)" "⚒ Build images" \
                         "☰ Logs" "≡ Configuration" "● Status" "∑ Profitability audit" "× Quit")
            ;;
        stacks)
            TUI_STACK_BC="Select stacks // ${STACK_ACTION}"
            MENU_TITLE="[space] toggle  [a] all  [enter] run ${STACK_ACTION}"
            local s
            for s in "${STACKS[@]}"; do
                MENU_IDS+=("$s")
                local box="[ ]"; [ "${STACK_PICK[$s]:-0}" = 1 ] && box="[x]"
                MENU_LABELS+=("$box  $s")
            done
            MENU_IDS+=("__run"); MENU_LABELS+=("→ Run ${STACK_ACTION} on selected")
            ;;
        config)
            TUI_STACK_BC="Configuration"
            MENU_TITLE="[enter] edit a value"
            tui_build_config_cache            # cheap after the first call
            MENU_IDS=("${CONFIG_IDS[@]}")
            MENU_LABELS=("${CONFIG_LABELS[@]}")
            ;;
        logs)
            TUI_STACK_BC="Logs"
            MENU_TITLE="[enter] follow logs  (Ctrl-C to return)"
            local s
            for s in "${STACKS[@]}"; do MENU_IDS+=("$s"); MENU_LABELS+=("  $s"); done
            MENU_IDS+=("__all"); MENU_LABELS+=("  all stacks")
            ;;
    esac
    [ "$MENU_SEL" -ge "${#MENU_IDS[@]}" ] && MENU_SEL=$(( ${#MENU_IDS[@]} - 1 ))
    [ "$MENU_SEL" -lt 0 ] && MENU_SEL=0
}

tui_render_menu() {
    [ "$TUI_NEED_MENU" = 1 ] || return 0
    TUI_NEED_MENU=0
    _at "$CONTENT_TOP" 3; _clr_to
    printf '%b%s%b' "$T_SUB" "${MENU_TITLE:0:_LW}" "$T_RESET"
    local r=$(( CONTENT_TOP + 2 )) i
    for (( i=0; i<${#MENU_IDS[@]} && r<=CONTENT_BOT; i++, r++ )); do
        _at "$r" 3; _clr_to
        local label="${MENU_LABELS[$i]:0:_LW}"
        if [ "$i" -eq "$MENU_SEL" ]; then
            # paint a full-width highlight, then overprint the text on top
            _at "$r" 3; printf '%b%*s%b' "$T_SEL_BG" "$_LW" "" "$T_RESET"
            _at "$r" 4; printf '%b%b%s%b' "$T_SEL_BG" "${T_BOLD}${T_TITLE}" "$label" "$T_RESET"
        else
            _at "$r" 4; printf '%b%s%b' "$T_MENU" "$label" "$T_RESET"
        fi
    done
    for (( ; r<=CONTENT_BOT; r++ )); do _at "$r" 3; _clr_to; done
}

# --- Actions ------------------------------------------------------
tui_do_config_edit() {
    local key="$1"
    local cur; cur=$(read_env_var "$key")
    local newval prompt_default start_buf
    if config_var_is_secret "$key"; then
        prompt_default=""           # empty entry -> keep current secret
        start_buf=""
    else
        prompt_default="$cur"
        start_buf="$cur"
    fi
    newval=$(tui_prompt "Set $key" "$prompt_default" "$start_buf")

    if config_var_is_secret "$key" && [ -z "$newval" ]; then
        TUI_NEED_MENU=1; return 0     # unchanged
    fi
    [ "$newval" = "$cur" ] && { TUI_NEED_MENU=1; return 0; }

    local err
    if ! err=$(validate_env_value "$key" "$newval"); then
        tui_message "Invalid value for $key" "$err"
        return 0
    fi
    # Persist: source current config, override the one var, rewrite + relink.
    if ( set -a
         source <(sed 's/^export //g' "$CONFIG_FILE" | grep -v '^[[:space:]]*#')
         set +a
         export "$key=$newval"
         save_config ); then
        CONFIG_CACHE_DIRTY=1
        tui_message "Saved" "$key updated. bastion.conf and every stack .env are refreshed (previous file kept as bastion.conf.bak)."
    else
        tui_message "Save failed" "Could not write bastion.conf."
    fi
    TUI_NEED_MENU=1
}

tui_dispatch() {
    local id="${MENU_IDS[$MENU_SEL]}"
    case "$TUI_VIEW" in
        main)
            case "$id" in
                deploy|stop|down|build)
                    STACK_ACTION="$id"
                    local s; for s in "${STACKS[@]}"; do STACK_PICK[$s]=1; done
                    MENU_SEL=0; TUI_VIEW="stacks" ;;
                logs)   MENU_SEL=0; TUI_VIEW="logs" ;;
                config) MENU_SEL=0; TUI_VIEW="config"; CONFIG_CACHE_DIRTY=1 ;;
                status)
                    TUI_STATUS_AT=0; tui_refresh_status
                    tui_message "Status" "$(docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}' 2>&1)" ;;
                audit)
                    tui_suspend bash -c 'python3 ./stack-bitcoin/scripts/node-audit.py 2>&1 | less -R || python3 ./stack-bitcoin/scripts/node-audit.py' ;;
                quit) return 1 ;;
            esac ;;
        stacks)
            case "$id" in
                __run)
                    local picked=() s
                    for s in "${STACKS[@]}"; do [ "${STACK_PICK[$s]:-0}" = 1 ] && picked+=("$s"); done
                    [ "${#picked[@]}" -eq 0 ] && { tui_message "Nothing selected" "Toggle at least one stack with Space."; return 0; }
                    if tui_confirm "${STACK_ACTION} ${#picked[@]} stack(s): ${picked[*]} ?" y; then
                        tui_suspend bastion_stack_action "$STACK_ACTION" "${picked[@]}"
                        tui_message "Done" "'${STACK_ACTION}' finished for: ${picked[*]}"
                    fi
                    TUI_STATUS_AT=0 ;;
                *) STACK_PICK[$id]=$(( 1 - ${STACK_PICK[$id]:-0} )); TUI_NEED_MENU=1 ;;
            esac ;;
        config)
            tui_do_config_edit "$id" ;;
        logs)
            local target=("$id"); [ "$id" = "__all" ] && target=("${STACKS[@]}")
            tui_suspend bastion_stack_logs "${target[@]}" ;;
    esac
    return 0
}

tui_back() {
    case "$TUI_VIEW" in
        main) return 1 ;;
        *) TUI_VIEW="main"; MENU_SEL=0; TUI_NEED_MENU=1; return 0 ;;
    esac
}

# --- Main loop ---------------------------------------------------
tui_main() {
    tui_init
    tui_refresh_status
    while true; do
        [ "$TUI_RESIZED" = 1 ] && tui_update_layout
        tui_build_menu
        tui_draw_frame
        tui_render_menu
        tui_render_right
        tui_read_key
        case "$_KEY" in
            _timeout) tui_refresh_status ;;
            up)   MENU_SEL=$(( MENU_SEL - 1 )); [ "$MENU_SEL" -lt 0 ] && MENU_SEL=$(( ${#MENU_IDS[@]} - 1 )); TUI_NEED_MENU=1 ;;
            down) MENU_SEL=$(( MENU_SEL + 1 )); [ "$MENU_SEL" -ge "${#MENU_IDS[@]}" ] && MENU_SEL=0; TUI_NEED_MENU=1 ;;
            enter) tui_dispatch || break ;;
            space)
                [ "$TUI_VIEW" = stacks ] && { local id="${MENU_IDS[$MENU_SEL]}"; [ "$id" != "__run" ] && STACK_PICK[$id]=$(( 1 - ${STACK_PICK[$id]:-0} )); TUI_NEED_MENU=1; } ;;
            char:a)
                [ "$TUI_VIEW" = stacks ] && { local s; for s in "${STACKS[@]}"; do STACK_PICK[$s]=1; done; TUI_NEED_MENU=1; } ;;
            left|esc) tui_back || break ;;
            q) break ;;
        esac
    done
    tui_cleanup
}
