#!/bin/bash
###############################################################################
# Regenerate the settings reference in docs/configuration.md from
# utils/settings.registry, so the documentation can never drift from what
# ./bastion actually accepts.
#
#   utils/gen-config-docs.sh           # rewrite the generated block in place
#   utils/gen-config-docs.sh --check   # exit 1 if the doc is out of date (tests)
#
# Only the text between the BEGIN/END GENERATED markers is replaced; the
# handwritten prose around it is kept.
###############################################################################
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

DOC=docs/configuration.md
BEGIN='<!-- BEGIN GENERATED: settings (utils/gen-config-docs.sh) -->'
END='<!-- END GENERATED: settings -->'

export CONFIG_FILE=/dev/null   # config.sh needs a path; nothing is read or written
# shellcheck source=config.sh
source utils/config.sh

# Markdown-safe cell: escape pipes, show an empty value as a dash.
_cell() { local v="${1//|/\\|}"; printf '%s' "${v:--}"; }

_default_label() {
    case "${SETTING_DEFAULT[$1]}" in
        @tz)    echo "host timezone" ;;
        @uid)   echo "your uid" ;;
        @gid)   echo "your gid" ;;
        @hex16) echo "random (16 hex)" ;;
        @token) echo "random (43 chars)" ;;
        "")     echo "" ;;
        *)      printf '`%s`' "${SETTING_DEFAULT[$1]}" ;;
    esac
}

render() {
    local k section="" notes
    echo "$BEGIN"
    for k in "${MANAGED_VARS[@]}"; do
        if [ "${SETTING_SECTION[$k]}" != "$section" ]; then
            section=${SETTING_SECTION[$k]}
            printf '\n### %s\n\n' "$section"
            echo "| Setting | Default | Type | Description |"
            echo "|---|---|---|---|"
        fi
        notes=${SETTING_TYPE[$k]}
        _setting_has_flag "$k" required && notes+=", **required**"
        config_var_is_secret "$k" && notes+=", secret"
        printf '| `%s` | %s | %s | %s |\n' "$k" "$(_cell "$(_default_label "$k")")" "$notes" "$(_cell "${SETTING_DESC[$k]}")"
    done
    echo
    echo "$END"
}

[ -f "$DOC" ] || { echo "$DOC not found" >&2; exit 1; }
grep -qF "$BEGIN" "$DOC" && grep -qF "$END" "$DOC" \
    || { echo "$DOC is missing the generated-block markers" >&2; exit 1; }

new=$(awk -v begin="$BEGIN" -v end="$END" -v block="$(render)" '
    $0 == begin { print block; skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
' "$DOC")

if [ "${1:-}" = "--check" ]; then
    [ "$new" = "$(cat "$DOC")" ] && exit 0
    echo "$DOC is out of date - run utils/gen-config-docs.sh" >&2
    exit 1
fi
printf '%s\n' "$new" > "$DOC"
echo "Updated $DOC"
