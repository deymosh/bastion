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
# CONTAINER_STACK, read_env_var, validate_env_value, config_var_is_secret,
# save_config, and the styling vars. Also uses runners defined in ./bastion:
# bastion_stack_action, bastion_stack_logs, bastion_container_action,
# do_versions, and _compose_service_images.
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
    set +m 2>/dev/null || true            # no "[1]+ Done" noise from the status probe
    TUI_STATUS_TMP=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/bastion-tui.$$")
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
    [ "$TUI_STATUS_JOB" != 0 ] && kill "$TUI_STATUS_JOB" 2>/dev/null
    [ -n "$TUI_STATUS_TMP" ] && rm -f "$TUI_STATUS_TMP" "${TUI_STATUS_TMP}.ok" "${TUI_STATUS_TMP}.done"
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
    # The left pane carries the wide content (long config-var names + values);
    # the status pane is short lines. Give the menu the larger share, but cap
    # the status pane so it stays useful on a very wide terminal.
    LEFT_W=$(( COLS * 60 / 100 )); [ "$LEFT_W" -lt 30 ] && LEFT_W=30
    [ $(( COLS - LEFT_W )) -gt 46 ] && LEFT_W=$(( COLS - 46 ))
    _LW=$(( LEFT_W - 3 ))                 # writable width of the left column
    RIGHT_X=$(( LEFT_W + 2 ))
    RIGHT_W=$(( COLS - RIGHT_X - 1 ))
    CONTENT_TOP=4
    CONTENT_BOT=$(( LINES - 2 ))
    # Pre-render the horizontal rules once per layout change - drawing them with
    # $(_rep ...) on every frame forks a subshell each time, which is the bulk of
    # the redraw cost on Git Bash / Docker Desktop.
    TUI_RULE_L=$(_rep '─' "$_LW")
    TUI_RULE_R=$(_rep '─' "$RIGHT_W")
    TUI_RULE_TOP=$(_rep '─' $(( COLS - 2 )))
    TUI_RESIZED=0
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

_at()  { printf '%s' "${E}[${1};${2}H"; }
# Erase exactly N cells from the cursor without moving it or touching the rest
# of the line (so pane borders and the other pane survive). ECH is vt100/xterm.
_erase() { printf '%s' "${E}[${1}X"; }
# Erase the left content column (from col 3 to the divider).
_clr_to() { printf '%s' "${E}[${_LW:-40}X"; }

# repeat a single-cell string N times (printf-pad + replace, no per-char loop)
_rep() {
    local s=$1 n=$2 pad
    [ "$n" -le 0 ] && return 0
    printf -v pad '%*s' "$n" ''
    printf '%s' "${pad// /$s}"
}

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
                    H) _KEY="home" ;; F) _KEY="end" ;;
                    5) IFS= read -rsn1 -t 0.06 _ || true; _KEY="pgup" ;;
                    6) IFS= read -rsn1 -t 0.06 _ || true; _KEY="pgdn" ;;
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

# tui_message "title" "body..."   scrollable pager; up/down/pgup/pgdn scroll,
# any other key closes. Body may contain newlines.
tui_message() {
    local title="$1" body="$2"
    TUI_NEED_FRAME=1; tui_draw_frame; tui_render_right

    local mlines=() line
    while IFS= read -r line; do mlines+=("$line"); done < <(printf '%s\n' "$body" | fold -s -w "$_LW")
    local total=${#mlines[@]}
    local top=$(( CONTENT_TOP + 2 ))
    local avail=$(( CONTENT_BOT - top )); [ "$avail" -lt 1 ] && avail=1
    local off=0 maxoff=$(( total - avail )); [ "$maxoff" -lt 0 ] && maxoff=0

    tui_flush_input
    stty -icanon min 1 time 0 2>/dev/null || true
    local k a b r i
    while :; do
        [ "$off" -gt "$maxoff" ] && off=$maxoff
        [ "$off" -lt 0 ] && off=0
        _at "$CONTENT_TOP" 3; _clr_to; printf '%b%s%b' "${T_BOLD}${T_ACCENT}" "${title:0:_LW}" "$T_RESET"
        _at $(( CONTENT_TOP + 1 )) 3; _clr_to; printf '%b%s%b' "$T_LINE" "$TUI_RULE_L" "$T_RESET"
        r=$top
        for (( i=off; i<total && r<=CONTENT_BOT-1; i++, r++ )); do
            _at "$r" 3; _clr_to; printf '%b%s%b' "$T_MENU" "${mlines[$i]}" "$T_RESET"
        done
        for (( ; r<=CONTENT_BOT-1; r++ )); do _at "$r" 3; _clr_to; done
        _at "$CONTENT_BOT" 3; _clr_to
        if [ "$total" -gt "$avail" ]; then
            printf '%b%d/%d  up/down scroll - any other key closes%b' "$T_MENU_DIM" \
                "$(( off + avail < total ? off + avail : total ))" "$total" "$T_RESET"
        else
            printf '%bPress any key to continue%b' "$T_MENU_DIM" "$T_RESET"
        fi

        IFS= read -rsn1 k || break
        case "$k" in
            $'\x1b')
                IFS= read -rsn1 -t 0.05 a || { break; }
                [ "$a" = "[" ] || [ "$a" = "O" ] || break     # bare ESC closes
                IFS= read -rsn1 -t 0.05 b || true
                case "$b" in
                    A) off=$(( off - 1 )) ;;
                    B) off=$(( off + 1 )) ;;
                    5) IFS= read -rsn1 -t 0.05 _ || true; off=$(( off - avail + 1 )) ;;
                    6) IFS= read -rsn1 -t 0.05 _ || true; off=$(( off + avail - 1 )) ;;
                    H) off=0 ;;
                    F) off=$maxoff ;;
                    *) break ;;
                esac ;;
            *) break ;;
        esac
    done
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
# Derived from CONTAINER_STACK (utils/config.sh) - the single source of truth -
# so there is only one place to keep in sync with the compose files. Values here
# are the short group name (network/bitcoin/...) this file groups by.
declare -A STACK_OF_CONTAINER=()
for _c in "${!CONTAINER_STACK[@]}"; do
    STACK_OF_CONTAINER["$_c"]="${CONTAINER_STACK[$_c]#stack-}"
done
unset _c
TUI_STATUS_LINES=()
TUI_STATUS_AT=-999
TUI_STATUS_EVERY=4          # seconds between container probes
TUI_STATUS_TMP=""           # set by tui_init
TUI_STATUS_JOB=0            # pid of an in-flight probe, 0 if none
TUI_DOCKER_OK=1
declare -A TUI_CSTATE=()    # container -> "running(healthy)" / "exited" / "absent"

# Turn the probe output file into TUI_STATUS_LINES. Pure bash - no subshell per
# container (the old grep/printf-per-row was most of the redraw cost).
_tui_status_parse() {
    local n s status pad grp c
    local -A st=() ss=()
    if [ -s "$TUI_STATUS_TMP" ]; then
        while IFS='|' read -r n s status; do
            [ -n "$n" ] || continue
            st["$n"]="$s"; ss["$n"]="$status"
        done < "$TUI_STATUS_TMP"
    fi
    # A compact per-container state string for the Containers view.
    TUI_CSTATE=()
    for c in "${!STACK_OF_CONTAINER[@]}"; do
        if [ -n "${st[$c]:-}" ]; then
            TUI_CSTATE["$c"]="${st[$c]}"
            [[ "${ss[$c]:-}" == *"(healthy)"* ]] && TUI_CSTATE["$c"]="running (healthy)"
            [[ "${ss[$c]:-}" == *unhealthy* ]]   && TUI_CSTATE["$c"]="running (unhealthy)"
        else
            TUI_CSTATE["$c"]="absent"
        fi
    done

    TUI_STATUS_LINES=()
    if [ "$TUI_DOCKER_OK" = 1 ]; then
        TUI_STATUS_LINES+=("${T_SUB}docker:${T_RESET} ${T_OK}up${T_RESET}")
    else
        TUI_STATUS_LINES+=("${T_SUB}docker:${T_RESET} ${T_ERR}down${T_RESET}")
        TUI_NEED_RIGHT=1
        return 0
    fi

    for grp in network bitcoin monitor web ai; do
        TUI_STATUS_LINES+=("" "${T_BOLD}${T_ACCENT}stack-${grp}${T_RESET}")
        local found=0
        for c in "${!STACK_OF_CONTAINER[@]}"; do
            [ "${STACK_OF_CONTAINER[$c]}" = "$grp" ] || continue
            found=1
            local cs="${st[$c]:-}" cstat="${ss[$c]:-}" mark col label
            case "$cs" in
                running)
                    if [[ ${cstat,,} == *unhealthy* ]]; then mark='●'; col="$T_ERR"; label="unhealthy"
                    elif [[ ${cstat,,} == *"(healthy)"* ]]; then mark='●'; col="$T_OK"; label="healthy"
                    else mark='●'; col="$T_OK"; label="running"; fi ;;
                exited|dead)       mark='○'; col="$T_MENU_DIM"; label="$cs" ;;
                restarting|paused) mark='◐'; col="$T_WARN";     label="$cs" ;;
                *)                 mark='·'; col="$T_MENU_DIM"; label="absent" ;;
            esac
            printf -v pad '%-16s' "$c"
            TUI_STATUS_LINES+=("  ${col}${mark}${T_RESET} ${T_MENU}${pad}${T_RESET}${T_MENU_DIM}${label}${T_RESET}")
        done
        [ "$found" = 0 ] && TUI_STATUS_LINES+=("  ${T_MENU_DIM}(none)${T_RESET}")
    done
    TUI_NEED_RIGHT=1
}

# Non-blocking: a background `docker ps` writes to a temp file; we adopt the
# result on a later tick. The main loop never stalls on Docker.
tui_refresh_status() {
    local now=$SECONDS

    if [ "$TUI_STATUS_JOB" != 0 ] && [ -f "${TUI_STATUS_TMP}.done" ]; then
        wait "$TUI_STATUS_JOB" 2>/dev/null || true
        TUI_STATUS_JOB=0
        [ -f "${TUI_STATUS_TMP}.ok" ] && TUI_DOCKER_OK=1 || TUI_DOCKER_OK=0
        rm -f "${TUI_STATUS_TMP}.done"
        _tui_status_parse
    elif [ "$TUI_STATUS_JOB" != 0 ] && ! kill -0 "$TUI_STATUS_JOB" 2>/dev/null \
         && [ $(( now - TUI_STATUS_AT )) -ge $(( TUI_STATUS_EVERY * 3 )) ]; then
        TUI_STATUS_JOB=0        # probe vanished without a marker - let a new one start
    fi

    if [ "$TUI_STATUS_JOB" = 0 ] && [ $(( now - TUI_STATUS_AT )) -ge "$TUI_STATUS_EVERY" ]; then
        TUI_STATUS_AT=$now
        rm -f "${TUI_STATUS_TMP}.ok" "${TUI_STATUS_TMP}.done"
        { docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' > "$TUI_STATUS_TMP" 2>/dev/null \
            && : > "${TUI_STATUS_TMP}.ok"
          : > "${TUI_STATUS_TMP}.done"; } &
        TUI_STATUS_JOB=$!
    fi

    if [ "${#TUI_STATUS_LINES[@]}" -eq 0 ]; then
        TUI_STATUS_LINES=("${T_MENU_DIM}scanning containers...${T_RESET}")
        TUI_NEED_RIGHT=1
    fi
}

# --- Frame + panes ---------------------------------------------------
TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
TUI_VIEW="main"
TUI_STACK_BC=""       # breadcrumb tail
TUI_FOCUS="menu"      # menu | status  - which pane the arrow keys drive
TUI_STATUS_OFF=0      # scroll offset of the status pane when focused
TUI_STATUS_MAXOFF=0   # highest valid scroll offset for the last layout drawn
                      # (published by tui_render_right, read by tui_status_scroll)

# Switch views. Always resets the selection, returns focus to the menu, and
# forces a full repaint so the breadcrumb and menu never show stale content.
_tui_goto() {
    TUI_VIEW="$1"
    MENU_SEL=0; MENU_OFF=0
    TUI_FOCUS="menu"
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

# Scroll the status pane (only meaningful while TUI_FOCUS=status). The clamp uses
# TUI_STATUS_MAXOFF, published by tui_render_right from the layout it actually
# drew - recomputing it here drifted by the footer row, so `end` / scrolling down
# could never reach the last line.
tui_status_scroll() {
    local view=$(( CONTENT_BOT - CONTENT_TOP )); [ "$view" -lt 1 ] && view=1
    local step=1
    case "$1" in pgup|pgdn) step=$(( view > 2 ? view - 1 : 1 )) ;; esac
    case "$1" in
        up|pgup)   TUI_STATUS_OFF=$(( TUI_STATUS_OFF - step )) ;;
        down|pgdn) TUI_STATUS_OFF=$(( TUI_STATUS_OFF + step )) ;;
        home)      TUI_STATUS_OFF=0 ;;
        end)       TUI_STATUS_OFF=$TUI_STATUS_MAXOFF ;;
    esac
    [ "$TUI_STATUS_OFF" -gt "$TUI_STATUS_MAXOFF" ] && TUI_STATUS_OFF=$TUI_STATUS_MAXOFF
    [ "$TUI_STATUS_OFF" -lt 0 ] && TUI_STATUS_OFF=0
    TUI_NEED_RIGHT=1
}

tui_draw_frame() {
    [ "$TUI_NEED_FRAME" = 1 ] || return 0
    TUI_NEED_FRAME=0
    printf '%s' "${E}[2J"
    # top / bottom borders
    _at 1 1; printf '%b┌%s┐%b' "$T_LINE" "$TUI_RULE_TOP" "$T_RESET"
    _at "$LINES" 1; printf '%b└%s┘%b' "$T_LINE" "$TUI_RULE_TOP" "$T_RESET"
    local r
    for (( r=2; r<LINES; r++ )); do
        _at "$r" 1; printf '%b│%b' "$T_LINE" "$T_RESET"
        _at "$r" "$COLS"; printf '%b│%b' "$T_LINE" "$T_RESET"
        _at "$r" "$(( LEFT_W + 1 ))"; printf '%b│%b' "$T_LINE" "$T_RESET"
    done
    # title bar (row 2) + separator (row 3). ASCII only so printf width == columns.
    local titletxt="  BASTION  //  ${TUI_STACK_BC:-Dashboard}"
    _at 2 2; printf '%b%b%-*s%b' "$T_BAR_BG" "${T_BOLD}${T_TITLE}" "$LEFT_W" "${titletxt:0:LEFT_W}" "$T_RESET"
    _at 3 2; printf '%b%s%b' "$T_LINE" "$TUI_RULE_L" "$T_RESET"
    _at 3 "$RIGHT_X"; printf '%b%s%b' "$T_LINE" "$TUI_RULE_R" "$T_RESET"
    # hint bar
    _at "$LINES" 3
    if [ "$TUI_FOCUS" = status ]; then
        printf '%b %b↑↓%b scroll status  %bs/esc%b back to menu  %bq%b quit %b' \
            "$T_BAR_BG" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_RESET"
    else
        printf '%b %b↑↓%b move  %b⏎%b select  %b␣%b toggle  %bs%b status  %besc%b back  %bq%b quit %b' \
            "$T_BAR_BG" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" \
            "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_ACCENT" "$T_SUB" "$T_RESET"
    fi
    TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
}

tui_render_right() {
    [ "$TUI_NEED_RIGHT" = 1 ] || return 0
    TUI_NEED_RIGHT=0

    local focused=0; [ "$TUI_FOCUS" = status ] && focused=1
    _at 2 "$RIGHT_X"
    if [ "$focused" = 1 ]; then
        printf '%b%b%-*s%b' "$T_SEL_BG" "${T_BOLD}${T_TITLE}" "$RIGHT_W" "  Status  (scrolling)" "$T_RESET"
    else
        printf '%b%b%-*s%b' "$T_BAR_BG" "${T_BOLD}${T_TITLE}" "$RIGHT_W" "  Status  -  press s" "$T_RESET"
    fi

    local avail=$(( CONTENT_BOT - CONTENT_TOP + 1 ))
    local lines=("${TUI_STATUS_LINES[@]}")
    # Doesn't fit? drop the blank spacer rows first so more content survives.
    if [ "${#lines[@]}" -gt "$avail" ]; then
        local compact=() ln
        for ln in "${lines[@]}"; do [ -n "$ln" ] && compact+=("$ln"); done
        lines=("${compact[@]}")
    fi
    local total=${#lines[@]}

    # Row CONTENT_BOT is always the footer/indicator line, so the content
    # viewport is avail-1 rows - never avail. maxoff must use the same figure or
    # the last line stays one row out of reach however far you scroll.
    local body_rows=$(( avail - 1 )); [ "$body_rows" -lt 1 ] && body_rows=1
    local maxoff=$(( total - body_rows )); [ "$maxoff" -lt 0 ] && maxoff=0
    TUI_STATUS_MAXOFF=$maxoff

    # clamp the scroll offset (a probe rebuild can shrink the list under us)
    [ "$TUI_STATUS_OFF" -gt "$maxoff" ] && TUI_STATUS_OFF=$maxoff
    [ "$TUI_STATUS_OFF" -lt 0 ] && TUI_STATUS_OFF=0
    [ "$focused" = 0 ] && TUI_STATUS_OFF=0        # only scroll while focused

    local overflow=0; [ "$total" -gt $(( TUI_STATUS_OFF + body_rows )) ] && overflow=1

    local r=$CONTENT_TOP i=$TUI_STATUS_OFF n=0
    for (( ; i<total && n<body_rows; i++, n++, r++ )); do
        _at "$r" "$RIGHT_X"; _erase "$RIGHT_W"
        _at "$r" "$RIGHT_X"; printf '%b' "${lines[$i]}"
    done
    for (( ; r<CONTENT_BOT; r++ )); do _at "$r" "$RIGHT_X"; _erase "$RIGHT_W"; done

    _at "$CONTENT_BOT" "$RIGHT_X"; _erase "$RIGHT_W"; _at "$CONTENT_BOT" "$RIGHT_X"
    if [ "$overflow" = 1 ] && [ "$focused" = 1 ]; then
        printf '%bv  more below - down to scroll%b' "$T_MENU_DIM" "$T_RESET"
    elif [ "$overflow" = 1 ]; then
        printf '%b... +%d more - press s to scroll%b' "$T_MENU_DIM" "$(( total - TUI_STATUS_OFF - body_rows ))" "$T_RESET"
    elif [ "$TUI_STATUS_OFF" -gt 0 ]; then
        printf '%b^  top with Home%b' "$T_MENU_DIM" "$T_RESET"
    fi
    [ "$TUI_STATUS_OFF" -gt 0 ] && { _at "$CONTENT_TOP" $(( COLS - 2 )); printf '%b^%b' "$T_MENU_DIM" "$T_RESET"; }
}

# --- Menu model ----------------------------------------------------
MENU_IDS=(); MENU_LABELS=(); MENU_SEL=0; MENU_OFF=0; MENU_TITLE=""
CONTAINER_SEL=""                       # container chosen in the Containers view
declare -A STACK_PICK=()

# Container names of a stack, in compose-file order (reuses ./bastion's helper).
_tui_stack_containers() {
    local svc _rest
    while IFS=$'\t' read -r svc _rest; do
        [ -n "$svc" ] && printf '%s\n' "$svc"
    done < <(_compose_service_images "./$1/docker-compose.yml")
}

# Config rows are expensive to build (one file read per key), so cache them and
# only rebuild when the view is (re-)entered or a value is saved.
CONFIG_IDS=(); CONFIG_LABELS=(); CONFIG_CACHE_DIRTY=1
tui_build_config_cache() {
    [ "$CONFIG_CACHE_DIRTY" = 1 ] || return 0
    CONFIG_CACHE_DIRTY=0
    CONFIG_IDS=(); CONFIG_LABELS=()
    local k v shown kw vw
    # Key column = the longest managed name, capped so values keep room.
    kw=0; for k in "${MANAGED_VARS[@]}"; do [ "${#k}" -gt "$kw" ] && kw=${#k}; done
    local cap=$(( _LW - 14 )); [ "$cap" -lt 12 ] && cap=12
    [ "$kw" -gt "$cap" ] && kw=$cap
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
            MENU_IDS=(deploy stop down build containers logs config status versions audit quit)
            MENU_LABELS=("▸ Deploy stacks" "■ Stop stacks" "⨯ Down (remove)" "⚒ Build images" \
                         "▦ Containers" "☰ Logs" "≡ Configuration" "● Status" "⛭ Image versions" \
                         "∑ Profitability audit" "× Quit")
            ;;
        stacks)
            TUI_STACK_BC="Select stacks // ${STACK_ACTION}"
            MENU_TITLE="[space] toggle  [a] all  [enter] run ${STACK_ACTION}"
            local s
            for s in "${STACKS[@]}"; do
                MENU_IDS+=("$s")
                local box="[ ]"; [ "${STACK_PICK[$s]:-0}" = 1 ] && box="[x]"
                local tag=""
                if [ "$s" = "$NETWORK_STACK" ]; then
                    [ "$STACK_ACTION" = deploy ] && tag="   (foundation - always on)" \
                                                || tag="   (foundation)"
                fi
                MENU_LABELS+=("$box  $s$tag")
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
        containers)
            TUI_STACK_BC="Containers"
            MENU_TITLE="[enter] act on a container"
            local st cpad
            for s in "${STACKS[@]}"; do
                local c
                for c in $(_tui_stack_containers "$s"); do
                    MENU_IDS+=("$c")
                    st="${TUI_CSTATE[$c]:-?}"
                    printf -v cpad '%-16s' "$c"
                    MENU_LABELS+=("  ${cpad}${st}")
                done
            done
            ;;
        container_actions)
            TUI_STACK_BC="Containers // ${CONTAINER_SEL}"
            MENU_TITLE="${CONTAINER_SEL} - ${TUI_CSTATE[$CONTAINER_SEL]:-?}"
            MENU_IDS=(restart stop start logs shell)
            MENU_LABELS=("↻ Restart" "■ Stop" "▶ Start" "☰ Logs (Ctrl-C to return)" "❯ Shell")
            ;;
    esac
    [ "$MENU_SEL" -ge "${#MENU_IDS[@]}" ] && MENU_SEL=$(( ${#MENU_IDS[@]} - 1 ))
    [ "$MENU_SEL" -lt 0 ] && MENU_SEL=0
}

tui_render_menu() {
    [ "$TUI_NEED_MENU" = 1 ] || return 0
    TUI_NEED_MENU=0

    local count=${#MENU_IDS[@]}
    local top=$(( CONTENT_TOP + 2 ))
    local vis=$(( CONTENT_BOT - top + 1 )); [ "$vis" -lt 1 ] && vis=1

    # Scroll the window so MENU_SEL stays visible; clamp the offset.
    [ "$MENU_SEL" -lt "$MENU_OFF" ] && MENU_OFF=$MENU_SEL
    [ "$MENU_SEL" -ge $(( MENU_OFF + vis )) ] && MENU_OFF=$(( MENU_SEL - vis + 1 ))
    local maxoff=$(( count - vis )); [ "$maxoff" -lt 0 ] && maxoff=0
    [ "$MENU_OFF" -gt "$maxoff" ] && MENU_OFF=$maxoff
    [ "$MENU_OFF" -lt 0 ] && MENU_OFF=0

    _at "$CONTENT_TOP" 3; _clr_to
    local title="$MENU_TITLE"
    [ "$count" -gt "$vis" ] && title="$title  ($(( MENU_SEL + 1 ))/$count)"
    printf '%b%s%b' "$T_SUB" "${title:0:_LW}" "$T_RESET"

    local r=$top i
    for (( i=MENU_OFF; i<count && r<=CONTENT_BOT; i++, r++ )); do
        _at "$r" 3; _clr_to
        local label="${MENU_LABELS[$i]:0:_LW}"
        if [ "$i" -eq "$MENU_SEL" ]; then
            _at "$r" 3; printf '%b%*s%b' "$T_SEL_BG" "$_LW" "" "$T_RESET"
            _at "$r" 4; printf '%b%b%s%b' "$T_SEL_BG" "${T_BOLD}${T_TITLE}" "$label" "$T_RESET"
        else
            _at "$r" 4; printf '%b%s%b' "$T_MENU" "$label" "$T_RESET"
        fi
    done
    for (( ; r<=CONTENT_BOT; r++ )); do _at "$r" 3; _clr_to; done

    # more-above / more-below markers at the right edge of the menu column
    [ "$MENU_OFF" -gt 0 ] && { _at "$top" $(( LEFT_W - 1 )); printf '%b^%b' "$T_MENU_DIM" "$T_RESET"; }
    [ $(( MENU_OFF + vis )) -lt "$count" ] && { _at "$CONTENT_BOT" $(( LEFT_W - 1 )); printf '%bv%b' "$T_MENU_DIM" "$T_RESET"; }
}

# --- Actions ------------------------------------------------------

# In the deploy picker, stack-network is the foundation and cannot be toggled
# off. Every other picker/action is free to toggle it - the stop/down guard runs
# at __run time instead.
tui_stack_toggle_ok() {
    [ "$STACK_ACTION" = deploy ] && [ "$1" = "$NETWORK_STACK" ] && return 1
    return 0
}

# Echo the running stacks that would be orphaned if `picked` (which is assumed to
# include stack-network) were stopped/removed - i.e. running stacks not in the
# selection. Empty output means the teardown is safe.
tui_network_teardown_orphans() {
    local picked=("$@") r out=""
    _contains "$NETWORK_STACK" "${picked[@]}" || return 0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        _contains "$r" "${picked[@]}" || out+=" $r"
    done < <(running_stacks)
    printf '%s' "${out# }"
}

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
                    _tui_goto stacks ;;
                containers) _tui_goto containers ;;
                logs)   _tui_goto logs ;;
                config) _tui_goto config; CONFIG_CACHE_DIRTY=1 ;;
                status)
                    TUI_STATUS_AT=0; tui_refresh_status
                    tui_message "Status" "$(docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}' 2>&1)" ;;
                versions)
                    tui_message "Image versions" "$(do_versions 2>&1)" ;;
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
                    if [ "$STACK_ACTION" = stop ] || [ "$STACK_ACTION" = down ]; then
                        local orphans; orphans=$(tui_network_teardown_orphans "${picked[@]}")
                        if [ -n "$orphans" ]; then
                            tui_message "Cannot ${STACK_ACTION} ${NETWORK_STACK}" \
"${NETWORK_STACK} owns the bastion-transit network and Tor. These stacks are still running and rely on it:

  ${orphans}

Bring those down first, or clear ${NETWORK_STACK} from the selection. (The CLI has --force for the rare case you really mean it.)"
                            return 0
                        fi
                    fi
                    if tui_confirm "${STACK_ACTION} ${#picked[@]} stack(s): ${picked[*]} ?" y; then
                        tui_suspend bastion_stack_action "$STACK_ACTION" "${picked[@]}"
                        tui_message "Done" "'${STACK_ACTION}' finished for: ${picked[*]}"
                    fi
                    TUI_STATUS_AT=0 ;;
                *) tui_stack_toggle_ok "$id" && { STACK_PICK[$id]=$(( 1 - ${STACK_PICK[$id]:-0} )); TUI_NEED_MENU=1; } ;;
            esac ;;
        config)
            tui_do_config_edit "$id" ;;
        logs)
            local target=("$id"); [ "$id" = "__all" ] && target=("${STACKS[@]}")
            tui_suspend bastion_stack_logs "${target[@]}" ;;
        containers)
            CONTAINER_SEL="$id"
            _tui_goto container_actions ;;
        container_actions)
            case "$id" in
                logs|shell)
                    tui_suspend bastion_container_action "$id" "$CONTAINER_SEL" ;;
                restart|stop|start)
                    if tui_confirm "${id} container ${CONTAINER_SEL} ?" y; then
                        tui_suspend bastion_container_action "$id" "$CONTAINER_SEL"
                        tui_message "Done" "'${id}' finished for ${CONTAINER_SEL}."
                        TUI_STATUS_AT=0
                    fi ;;
            esac ;;
    esac
    return 0
}

# esc / left move one level up. On the main view they do nothing - only `q`
# (or the Quit item) leaves the TUI.
tui_back() {
    case "$TUI_VIEW" in
        main)              : ;;
        container_actions) _tui_goto containers ;;
        *)                 _tui_goto main ;;
    esac
}

# Toggle which pane the arrow keys drive. The hint bar lives in the frame, so a
# focus change forces a frame repaint.
tui_toggle_focus() {
    if [ "$TUI_FOCUS" = status ]; then TUI_FOCUS=menu
    else TUI_FOCUS=status; TUI_STATUS_OFF=0; fi
    TUI_NEED_FRAME=1; TUI_NEED_MENU=1; TUI_NEED_RIGHT=1
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

        # Status pane has focus: arrows scroll it, s/esc/left return to the menu.
        if [ "$TUI_FOCUS" = status ]; then
            case "$_KEY" in
                _timeout)               tui_refresh_status ;;
                up|down|pgup|pgdn|home|end) tui_status_scroll "$_KEY" ;;
                char:s|tab|left|esc)    tui_toggle_focus ;;
                q)                      break ;;
            esac
            continue
        fi

        case "$_KEY" in
            _timeout) tui_refresh_status ;;
            up)   MENU_SEL=$(( MENU_SEL - 1 )); [ "$MENU_SEL" -lt 0 ] && MENU_SEL=$(( ${#MENU_IDS[@]} - 1 )); TUI_NEED_MENU=1 ;;
            down) MENU_SEL=$(( MENU_SEL + 1 )); [ "$MENU_SEL" -ge "${#MENU_IDS[@]}" ] && MENU_SEL=0; TUI_NEED_MENU=1 ;;
            pgup) MENU_SEL=$(( MENU_SEL - 5 )); [ "$MENU_SEL" -lt 0 ] && MENU_SEL=0; TUI_NEED_MENU=1 ;;
            pgdn) MENU_SEL=$(( MENU_SEL + 5 )); [ "$MENU_SEL" -ge "${#MENU_IDS[@]}" ] && MENU_SEL=$(( ${#MENU_IDS[@]} - 1 )); TUI_NEED_MENU=1 ;;
            home) MENU_SEL=0; TUI_NEED_MENU=1 ;;
            end)  MENU_SEL=$(( ${#MENU_IDS[@]} - 1 )); TUI_NEED_MENU=1 ;;
            enter) tui_dispatch || break ;;
            space)
                [ "$TUI_VIEW" = stacks ] && { local id="${MENU_IDS[$MENU_SEL]}"; [ "$id" != "__run" ] && tui_stack_toggle_ok "$id" && STACK_PICK[$id]=$(( 1 - ${STACK_PICK[$id]:-0} )); TUI_NEED_MENU=1; } ;;
            char:a)
                [ "$TUI_VIEW" = stacks ] && { local s; for s in "${STACKS[@]}"; do STACK_PICK[$s]=1; done; TUI_NEED_MENU=1; } ;;
            char:s|tab) tui_toggle_focus ;;
            left|esc) tui_back ;;
            q) break ;;
        esac
    done
    tui_cleanup
}
