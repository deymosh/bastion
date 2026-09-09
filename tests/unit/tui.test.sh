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
assert_eq "${#MENU_IDS[@]}" 15 "15 containers listed"
assert_eq "${MENU_IDS[0]}" "pihole" "first is pihole (stack-network, compose order)"
assert_eq "${MENU_IDS[-1]}" "codedeck-bridge" "last is codedeck-bridge (stack-ai)"
case "${MENU_LABELS[3]}" in *"running (healthy)"*) _t_ok "tor row shows its probed state" ;; *) _t_bad "tor row missing state: ${MENU_LABELS[3]}" ;; esac

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

rm -f "$CONFIG_FILE"
finish
