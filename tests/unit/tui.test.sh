#!/usr/bin/env bash
###############################################################################
# Headless smoke for utils/tui.sh - it can't be driven interactively in CI, so
# this sources it and exercises the pure-logic helpers: menu building for each
# view, the scroll math, the pane-focus model, and the Containers view.
###############################################################################
# This test seeds many globals that utils/tui.sh (sourced below) reads back.
# shellcheck disable=SC2034
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

export CONFIG_FILE; CONFIG_FILE=$(mktemp)
export BASTION_SKIP_ENV_LINKS=1
STACKS=("stack-network" "stack-bitcoin" "stack-monitor" "stack-web" "stack-ai")
# shellcheck disable=SC1091
source utils/config.sh
# ./bastion defines _compose_service_images; pull just that function in.
eval "$(sed -n '/^_compose_service_images()/,/^}/p' bastion)"
# shellcheck disable=SC1091
source utils/tui.sh
tui_setup_theme

# a plausible layout so the render/scroll math has real numbers
COLS=140; LINES=32; LEFT_W=84; _LW=81; RIGHT_X=86; RIGHT_W=53
CONTENT_TOP=4; CONTENT_BOT=30
TUI_RULE_L=""; TUI_RULE_R=""; TUI_RULE_TOP=""

echo "== every view builds a non-empty, consistent menu =="
for v in main config logs; do
  TUI_VIEW=$v; MENU_IDS=(); MENU_LABELS=(); tui_build_menu
  [ "${#MENU_IDS[@]}" -gt 0 ] && _t_ok "view '$v' has menu items" || _t_bad "view '$v' menu is empty"
  assert_eq "${#MENU_IDS[@]}" "${#MENU_LABELS[@]}" "view '$v' ids and labels line up"
done
TUI_VIEW=main; MENU_IDS=(); tui_build_menu
case " ${MENU_IDS[*]} " in *" containers "*) _t_ok "main menu has a Containers entry" ;; *) _t_bad "main menu missing Containers" ;; esac

echo "== Containers view lists every service in compose order =="
TUI_CSTATE=([tor]="running (healthy)" [rtl]=exited)
TUI_VIEW=containers; MENU_IDS=(); MENU_LABELS=(); tui_build_menu
assert_eq "${#MENU_IDS[@]}" 18 "18 containers listed"
assert_eq "${MENU_IDS[0]}" "pihole" "first is pihole (stack-network, compose order)"
assert_eq "${MENU_IDS[-1]}" "mcp-gateway" "last is mcp-gateway (stack-ai)"
case "${MENU_LABELS[3]}" in *"running (healthy)"*) _t_ok "tor row shows its probed state" ;; *) _t_bad "tor row missing state: ${MENU_LABELS[3]}" ;; esac

echo "== compose files are read once, not on every tick =="
_awk_log=$(mktemp)
eval "_real_csi() $(declare -f _compose_service_images | tail -n +2)"
_compose_service_images() { echo x >> "$_awk_log"; _real_csi "$@"; }   # runs in a subshell: count via a file
TUI_STACK_SERVICES=()
for _i in 1 2 3; do TUI_VIEW=containers; MENU_IDS=(); MENU_LABELS=(); tui_build_menu; done
assert_eq "$(wc -l < "$_awk_log" | tr -d " ")" "${#STACKS[@]}" "three rebuilds parse each compose file once"; rm -f "$_awk_log"

echo "== status pane follows compose order =="
TUI_STATUS_TMP=$(mktemp)
printf 'mcp-gateway|running|Up\npihole|running|Up (healthy)\ntor|exited|Exited\n' > "$TUI_STATUS_TMP"
TUI_DOCKER_OK=1; _tui_status_parse
plain=$(printf '%s\n' "${TUI_STATUS_LINES[@]}" | sed $'s/\033\\[[0-9;]*m//g')
assert_eq "$(printf '%s\n' "$plain" | grep -m1 -oE 'pihole|unbound|wireguard|tor')" "pihole" "stack-network rows start with pihole, as in the compose file"
first_ai=$(printf '%s\n' "$plain" | sed -n '/stack-ai/,$p' | grep -m1 -oE '(ccr|codedeck-bridge|agent-docker|searxng|mcp-gateway) ')
assert_eq "$first_ai" "ccr " "stack-ai rows start with ccr"
assert_contains "$plain" "pihole          healthy" "a probed state is shown on its row"
rm -f "$TUI_STATUS_TMP"; TUI_STATUS_TMP=""

echo "== deploy picker: opt-in profiles =="
COMPOSE_PROFILES=watchtower
TUI_VIEW=main; MENU_IDS=(deploy); MENU_SEL=0; tui_dispatch
assert_eq "$TUI_VIEW" "stacks" "Deploy opens the stack picker"
tui_build_menu
case " ${MENU_IDS[*]} " in *" profile:watchtower profile:agent-docker "*) _t_ok "picker lists both opt-in profiles" ;; *) _t_bad "profiles missing: ${MENU_IDS[*]}" ;; esac
assert_eq "$(tui_picked_profiles)" "watchtower" "pre-set from the active profiles (ENABLED_PROFILES / flags)"
tui_pick_toggle profile:agent-docker; tui_pick_toggle profile:watchtower
assert_eq "$(tui_picked_profiles)" "agent-docker" "space toggles a profile"
tui_pick_toggle stack-network
assert_eq "${STACK_PICK[stack-network]}" 1 "the foundation stack still cannot be unticked when deploying"
bastion_stack_action() { echo "action=$1 stacks=${*:2} profiles=$COMPOSE_PROFILES"; }
assert_eq "$(tui_deploy agent-docker stack-ai)" "action=deploy stacks=stack-ai profiles=agent-docker" "deploy runs with exactly the ticked profiles"
assert_eq "$COMPOSE_PROFILES" "watchtower" "and does not leak them into the TUI's later actions"
STACK_ACTION=stop; tui_build_menu
case " ${MENU_IDS[*]} " in *profile:*) _t_bad "stop picker shows profile rows" ;; *) _t_ok "stop/down pickers have no profile rows" ;; esac
unset COMPOSE_PROFILES

echo "== config view =="
printf "CCR_TOKEN_REFRESH='1'\nNODE_ALIAS='n'\n" > "$CONFIG_FILE"
TUI_VIEW=config; CONFIG_CACHE_DIRTY=1; MENU_SEL=0; tui_build_menu
assert_eq "${MENU_IDS[0]}" "__hdr:${SETTING_SECTION[${MANAGED_VARS[0]}]}" "the list opens with the first section's header"
assert_eq "$MENU_SEL" 1 "entering the view lands on the first setting, not the header"
assert_contains "$MENU_TITLE" "${SETTING_DESC[${MENU_IDS[$MENU_SEL]}]}" "the title describes the selected setting"
# One header per distinct section, every managed key exactly once, in order.
_hdrs=0; _keys=(); for _id in "${MENU_IDS[@]}"; do
  case "$_id" in __hdr:*) _hdrs=$((_hdrs + 1)) ;; *) _keys+=("$_id") ;; esac; done
assert_eq "$_hdrs" "$(printf '%s\n' "${SETTING_SECTION[@]}" | sort -u | wc -l | tr -d ' ')" "one header per registry section"
assert_eq "${_keys[*]}" "${MANAGED_VARS[*]}" "every setting listed once, in registry order"
_all_under=1; _cur=""; for _id in "${MENU_IDS[@]}"; do
  case "$_id" in __hdr:*) _cur=${_id#__hdr:} ;; *) [ "${SETTING_SECTION[$_id]}" = "$_cur" ] || _all_under=0 ;; esac; done
assert_eq "$_all_under" 1 "each setting sits under its own section's header"

echo "== grouped navigation skips headers =="
MENU_SEL=1; tui_menu_nav up
_tui_is_hdr "$MENU_SEL" && _t_bad "up from the first setting stopped on a header" || _t_ok "up never stops on a header"
assert_eq "$MENU_SEL" "$(( ${#MENU_IDS[@]} - 1 ))" "up from the first setting wraps to the last"
tui_menu_nav down; assert_eq "$MENU_SEL" 1 "down from the last wraps past the header to the first setting"
tui_menu_nav pgdn
_tui_is_hdr $(( MENU_SEL - 1 )) && _t_ok "pgdn jumps to the first setting of the next section" || _t_bad "pgdn landed mid-section at $MENU_SEL"
tui_menu_nav pgup; assert_eq "$MENU_SEL" 1 "pgup jumps back to the first section"
tui_menu_nav end; _tui_is_hdr "$MENU_SEL" && _t_bad "end on a header" || _t_ok "end lands on the last setting"
tui_menu_nav home; assert_eq "$MENU_SEL" 1 "home lands on the first setting"
# Scrolling up onto a section's first row brings its header into view.
CONTENT_BOT=12; MENU_OFF=$(( ${#MENU_IDS[@]} - 3 )); tui_menu_nav home
MENU_OFF=5; tui_menu_nav pgdn; _sel=$MENU_SEL; MENU_OFF=$_sel; TUI_NEED_MENU=1; tui_render_menu >/dev/null
assert_eq "$MENU_OFF" "$(( _sel - 1 ))" "the header above a section's first row is scrolled into view"
CONTENT_BOT=30; MENU_OFF=0
MENU_SEL=0; tui_dispatch; _t_ok "Enter on a header is a no-op"

MENU_SEL=0; tui_build_menu
for _i in "${!MENU_IDS[@]}"; do [ "${MENU_IDS[$_i]}" = CCR_TOKEN_REFRESH ] && MENU_SEL=$_i; done
tui_build_menu
assert_contains "$MENU_TITLE" "toggle" "a 0/1 setting advertises Enter-to-toggle"
tui_do_config_edit CCR_TOKEN_REFRESH
assert_eq "$(read_env_var CCR_TOKEN_REFRESH)" "0" "Enter flips a bool setting without a prompt"
tui_do_config_edit CCR_TOKEN_REFRESH
assert_eq "$(read_env_var CCR_TOKEN_REFRESH)" "1" "and back"
assert_eq "$(read_env_var NODE_ALIAS)" "n" "other settings untouched"

echo "== container_actions view =="
CONTAINER_SEL=tor; TUI_VIEW=container_actions; MENU_IDS=(); MENU_LABELS=(); tui_build_menu
assert_eq "${MENU_IDS[*]}" "restart stop start logs shell" "the five container actions"
case "$MENU_TITLE" in *tor*) _t_ok "title names the selected container" ;; *) _t_bad "title: $MENU_TITLE" ;; esac

echo "== back navigation =="
TUI_VIEW=container_actions; tui_back; assert_eq "$TUI_VIEW" "containers" "back from actions -> containers"
TUI_VIEW=containers; tui_back;        assert_eq "$TUI_VIEW" "main"       "back from containers -> main"
TUI_VIEW=main; tui_back;              assert_eq "$TUI_VIEW" "main"       "back on main is a no-op (only q quits)"

echo "== menu scroll math =="
CONTENT_BOT=15                        # small viewport so an 18-row list overflows
mapfile -t MENU_IDS < <(seq 1 18)
MENU_LABELS=("${MENU_IDS[@]}"); MENU_TITLE=x
MENU_SEL=17; MENU_OFF=0; TUI_NEED_MENU=1; tui_render_menu >/dev/null
[ "$MENU_OFF" -gt 0 ] && _t_ok "selecting the last of an overflowing list scrolls the viewport" || _t_bad "MENU_OFF stayed 0"
MENU_SEL=0; TUI_NEED_MENU=1; tui_render_menu >/dev/null
assert_eq "$MENU_OFF" 0 "returning to the top resets the offset"
CONTENT_BOT=30

echo "== focus model =="
TUI_FOCUS=menu; tui_toggle_focus; assert_eq "$TUI_FOCUS" status "s/Tab moves focus to the status pane"
tui_toggle_focus;                assert_eq "$TUI_FOCUS" menu   "toggles back to the menu"

echo "== status pane scroll reaches the last row (footer-row off-by-one) =="
# a short pane: CONTENT_TOP..CONTENT_BOT = 4..18 -> avail 15, content viewport 14
CONTENT_TOP=4; CONTENT_BOT=18
TUI_FOCUS=status; TUI_STATUS_OFF=0
TUI_STATUS_LINES=(); for _i in $(seq 1 26); do TUI_STATUS_LINES+=("row$_i"); done
TUI_NEED_RIGHT=1; tui_render_right >/dev/null
assert_eq "$TUI_STATUS_MAXOFF" 12 "maxoff = total(26) - viewport(14), not total - avail(15)"
tui_status_scroll end
assert_eq "$TUI_STATUS_OFF" 12 "End lands on maxoff"
TUI_NEED_RIGHT=1; drawn=$(tui_render_right | sed $'s/\033\\[[0-9;]*m//g')
case "$drawn" in *row26*) _t_ok "the last row is on screen after End" ;; *) _t_bad "last row still unreachable: $drawn" ;; esac
TUI_STATUS_OFF=0; TUI_NEED_RIGHT=1; tui_render_right >/dev/null
tui_status_scroll home; assert_eq "$TUI_STATUS_OFF" 0 "Home returns the status pane to the top"
CONTENT_TOP=4; CONTENT_BOT=30
TUI_STATUS_LINES=()

echo "== tui_sanitize_input strips control chars, keeps hyphens =="
assert_eq "$(tui_sanitize_input 'sk-ant-oat01-ABC-123')" "sk-ant-oat01-ABC-123" \
    "a hyphenated token survives sanitizing"
assert_eq "$(tui_sanitize_input $'foo\x07bar')" "foobar" "a stray control char is still stripped"
assert_eq "$(tui_sanitize_input '--flag-like---value--')" "--flag-like---value--" \
    "runs of hyphens are untouched"

rm -f "$CONFIG_FILE"
finish
