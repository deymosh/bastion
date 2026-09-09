# shellcheck shell=bash
# Tiny assertion helpers for the plain-bash unit tests. Source this.
#
#   source "$(dirname "$0")/../lib/assert.sh"
#   assert_eq "$got" "expected" "label"
#   assert_ok  some_command ...
#   assert_fail some_command ...
#   assert_contains "$haystack" "needle" "label"
#   finish   # prints the summary and exits non-zero if anything failed

_T_PASS=0
_T_FAIL=0

_t_ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; _T_PASS=$((_T_PASS+1)); }
_t_bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; _T_FAIL=$((_T_FAIL+1)); }

assert_eq() {   # got want [label]
  local label="${3:-expected [$2]}"
  if [ "$1" = "$2" ]; then _t_ok "$label"
  else _t_bad "$label -- got [$1] want [$2]"; fi
}

assert_contains() {  # haystack needle [label]
  local label="${3:-output contains [$2]}"
  case "$1" in *"$2"*) _t_ok "$label" ;; *) _t_bad "$label -- [$1] has no [$2]" ;; esac
}

assert_ok() {   # command...
  if "$@" >/dev/null 2>&1; then _t_ok "ok: $*"; else _t_bad "expected success: $*"; fi
}

assert_fail() { # command...
  if "$@" >/dev/null 2>&1; then _t_bad "expected failure: $*"; else _t_ok "fails as expected: $*"; fi
}

finish() {
  echo
  if [ "$_T_FAIL" -eq 0 ]; then
    printf '\033[32m%d passed\033[0m\n' "$_T_PASS"; exit 0
  else
    printf '\033[31m%d passed, %d FAILED\033[0m\n' "$_T_PASS" "$_T_FAIL"; exit 1
  fi
}
