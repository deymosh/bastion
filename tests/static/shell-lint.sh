#!/usr/bin/env bash
###############################################################################
# Bastion - shell script lint
#
# `bash -n` (parse) every tracked shell script, then `shellcheck` if available.
###############################################################################
set -u
cd "$(dirname "$0")/.." || exit 1

mapfile -t scripts < <(git ls-files '*.sh' bastion 2>/dev/null || find . -name '*.sh' -not -path './rust-teos/*')

fail=0
echo "== bash -n =="
for f in "${scripts[@]}"; do
  if bash -n "$f" 2>/tmp/_sh_$$; then printf '  ok   %s\n' "$f"
  else printf '  FAIL %s\n' "$f"; sed 's/^/       /' /tmp/_sh_$$; fail=1; fi
done
rm -f /tmp/_sh_$$

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck (warnings) =="
  # SC1090/SC1091: sourced paths are dynamic (process substitution, generated
  # config) by design. SC2317: TUI trap handlers look unreachable to the linter.
  shellcheck -S warning -e SC1090,SC1091,SC2317 "${scripts[@]}" || fail=1
else
  echo "== shellcheck not installed - skipped =="
fi

exit $fail
