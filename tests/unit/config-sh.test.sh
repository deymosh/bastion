#!/usr/bin/env bash
###############################################################################
# Unit tests for utils/config.sh: read_env_var, validate_env_value,
# config_var_is_secret, write_config idempotency, MANAGED_VARS coverage,
# seed_runtime_config, ensure_rtl_rune, write_secret_files.
# Runs against a scratch CONFIG_FILE - never touches the real bastion.conf.
###############################################################################
# Many vars below are read indirectly by the sourced utils/config.sh functions.
# shellcheck disable=SC2034
set -u
cd "$(dirname "$0")/../.." || exit 1
source tests/lib/assert.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CONFIG_FILE="$WORK/bastion.conf"

# We only want config.sh's helper functions, not the prompts / legacy .env cleanup.
export BASTION_SKIP_ENV_LINKS=1
STACKS=()
# shellcheck disable=SC1091
source utils/config.sh

# Isolation guard: config.sh must honour the CONFIG_FILE we exported above, or
# every write_config below would scribble into the real ./bastion.conf.
echo "== test isolation =="
assert_eq "$CONFIG_FILE" "$WORK/bastion.conf" "config.sh keeps our scratch CONFIG_FILE"

echo "== config_var_is_secret =="
assert_ok   config_var_is_secret PIHOLE_PASSWORD
assert_ok   config_var_is_secret CLAUDE_CODE_OAUTH_TOKEN
assert_ok   config_var_is_secret MCP_GATEWAY_TOKEN
assert_ok   config_var_is_secret CONTEXT7_API_KEY
assert_fail config_var_is_secret NODE_ALIAS
assert_fail config_var_is_secret WIREGUARD_SERVERURL

echo "== read_env_var =="
cat > "$CONFIG_FILE" <<'EOF'
# a comment
NODE_ALIAS=my-node
export WIREGUARD_SERVERPORT=51821
CODEDECK_TOR_PROXY_URL=socks5h://tor:9050
QUOTED="with spaces"
EOF
assert_eq "$(read_env_var NODE_ALIAS)"            "my-node"                "reads a plain value"
assert_eq "$(read_env_var WIREGUARD_SERVERPORT)"  "51821"                  "strips a leading 'export '"
assert_eq "$(read_env_var CODEDECK_TOR_PROXY_URL)" "socks5h://tor:9050"    "keeps a URL intact"
assert_eq "$(read_env_var QUOTED)"                "with spaces"            "strips surrounding quotes"
assert_eq "$(read_env_var DOES_NOT_EXIST)"        ""                       "missing key -> empty"

echo "== validate_env_value =="
assert_ok   validate_env_value WIREGUARD_SERVERPORT 51820
assert_fail validate_env_value WIREGUARD_SERVERPORT 70000
assert_fail validate_env_value WIREGUARD_SERVERPORT abc
assert_ok   validate_env_value WIREGUARD_PEERS 3
assert_fail validate_env_value WIREGUARD_PEERS -1
assert_ok   validate_env_value CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY 0
assert_ok   validate_env_value CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY 1
assert_fail validate_env_value CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY 2
assert_ok   validate_env_value CCR_TOKEN_REFRESH 0
assert_fail validate_env_value CCR_TOKEN_REFRESH 2
assert_ok   validate_env_value CCR_REFRESH_INTERVAL 300
assert_fail validate_env_value CCR_REFRESH_INTERVAL 0
assert_fail validate_env_value CCR_REFRESH_INTERVAL abc
assert_ok   validate_env_value CCR_REFRESH_SKEW_MS 1800000
assert_fail validate_env_value CCR_REFRESH_SKEW_MS -5
assert_ok   validate_env_value CODEDECK_TOR_PROXY_URL socks5h://tor:9050
assert_ok   validate_env_value CODEDECK_TOR_PROXY_URL ""
assert_fail validate_env_value CODEDECK_TOR_PROXY_URL http://tor:9050
assert_ok   validate_env_value GIT_EMAIL a@b.co
assert_fail validate_env_value GIT_EMAIL not-an-email
assert_ok   validate_env_value CODEDECK_RELAYS "wss://a.example,wss://b.example"
assert_fail validate_env_value CODEDECK_RELAYS "http://a.example"
assert_ok   validate_env_value NODE_ALIAS "short"
assert_fail validate_env_value NODE_ALIAS "0123456789012345678901234567890123"   # 34 chars
assert_ok   validate_env_value TIMEZONE Europe/Madrid
assert_fail validate_env_value TIMEZONE "not a tz"

echo "== write_config idempotency + unknown-var preservation =="
# write_config is only ever called after load_secrets has populated every
# managed var; mirror that here, and seed the file with a user's custom var
# (write_config carries over non-managed lines from the existing file).
printf 'MY_CUSTOM=keepme\n' > "$CONFIG_FILE"
for _v in "${MANAGED_VARS[@]}"; do printf -v "$_v" '%s' "${!_v:-}"; export "${_v?}"; done
# shellcheck disable=SC2034
NODE_ALIAS=ci-node; WIREGUARD_SERVERPORT=51820; TIMEZONE=UTC
# shellcheck disable=SC2034
CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
write_config
first=$(cat "$CONFIG_FILE")
write_config
second=$(cat "$CONFIG_FILE")
assert_eq "$first" "$second" "write_config is idempotent"
assert_contains "$first" "NODE_ALIAS='ci-node'" "write_config emits a managed value, single-quoted"
assert_contains "$first" "MY_CUSTOM='keepme'"   "carries over a user's non-managed var (normalised to the quoted form)"
assert_contains "$first" "# Additional custom variables" "non-managed vars land under their section"

echo "== a value with shell metachars survives a write -> source round-trip =="
: > "$CONFIG_FILE"
for _v in "${MANAGED_VARS[@]}"; do printf -v "$_v" '%s' ''; done
# shellcheck disable=SC2034
GIT_USER="a b; touch $WORK/PWNED"; PIHOLE_PASSWORD="x'\"'\"'y"; NODE_ALIAS='n'
write_config
( set -a; source <(sed 's/^export //g' "$CONFIG_FILE" | grep -v '^[[:space:]]*#'); set +a
  assert_eq "$GIT_USER" "a b; touch $WORK/PWNED" "sourcing the written file keeps the value literal" )
assert_ok test '!' -e "$WORK/PWNED"            # the ; touch never ran
assert_eq "$(read_env_var GIT_USER)"        "a b; touch $WORK/PWNED" "read_env_var round-trips a metachar value"
assert_eq "$(read_env_var PIHOLE_PASSWORD)" "x'\"'\"'y"              "read_env_var round-trips an embedded quote"

echo "== the settings registry is the single source of truth =="
for _v in "${MANAGED_VARS[@]}"; do
  [ -n "${SETTING_SECTION[$_v]}" ] && [ -n "${SETTING_TYPE[$_v]}" ] && [ -n "${SETTING_DESC[$_v]}" ] \
    || _t_bad "$_v is missing a section, type or description"
  case "${SETTING_TYPE[$_v]}" in host|port|int|posint|bool|alias|tz|socks|http|email|relays|profiles|cpus|mem|path|text) : ;;
    *) _t_bad "$_v has unknown type '${SETTING_TYPE[$_v]}'" ;; esac
done
_t_ok "every registry row has a section, a known type and a description"
assert_eq "$(printf '%s\n' "${MANAGED_VARS[@]}" | sort | uniq -d)" "" "no key is declared twice"
assert_eq "${BASTION_REQUIRED_VARS[*]}" "WIREGUARD_SERVERURL WIREGUARD_SERVERPORT NODE_ALIAS" "required keys derive from the 'required' flag"
assert_ok   validate_env_value GIT_EMAIL ""           # an optional key may be empty...
assert_fail validate_env_value WIREGUARD_SERVERURL "" # ...a required one may not
assert_ok   validate_env_value CODEDECK_OPENCODE_PORT ""
assert_ok   validate_env_value ENABLED_PROFILES "watchtower,agent-docker"
assert_fail validate_env_value ENABLED_PROFILES "watchtower,nope"
assert_ok   validate_env_value AGENT_DOCKER_CPUS 1.5
assert_fail validate_env_value AGENT_DOCKER_CPUS 0
assert_fail validate_env_value AGENT_DOCKER_CPUS two
assert_ok   validate_env_value AGENT_DOCKER_MEMORY 512m
assert_fail validate_env_value AGENT_DOCKER_MEMORY 4gb
assert_ok   validate_env_value BACKUP_DEST /mnt/usb
assert_fail validate_env_value BACKUP_DEST relative/dir

echo "== a broken registry stops the load instead of dropping settings =="
reg_load() { SETTINGS_REGISTRY="$1" bash -c 'source utils/config.sh' 2>&1; }
printf '# header\n\nGOOD_KEY|Sec||text||A description.\n' > "$WORK/ok.registry"
out=$(reg_load "$WORK/ok.registry"); rc=$?
assert_eq "$rc" 0 "comments and blank lines are skipped"
printf 'GOOD_KEY|Sec||text||A description.\nGOOD_KEY|Sec||text||Again.\n' > "$WORK/dup.registry"
out=$(reg_load "$WORK/dup.registry"); rc=$?
assert_eq "$rc" 1 "a duplicate key is fatal"; assert_contains "$out" "row 2" "names the row"
printf 'lower_key|Sec||text||x\n' > "$WORK/bad.registry"
out=$(reg_load "$WORK/bad.registry"); rc=$?; assert_eq "$rc" 1 "a malformed key is fatal"
printf 'NO_DESC|Sec||text|\n' > "$WORK/bad2.registry"
out=$(reg_load "$WORK/bad2.registry"); rc=$?; assert_eq "$rc" 1 "a row without a description is fatal"
out=$(reg_load "$WORK/missing.registry"); rc=$?
assert_eq "$rc" 1 "a missing registry is fatal"; assert_contains "$out" "not found" "says so"

echo "== obsolete per-stack .env links / copies are cleaned up =="
( cd "$WORK" && mkdir -p envs/stack-a envs/stack-b envs/stack-c && cd envs || exit 1
  printf "NODE_ALIAS='x'\n" > bastion.conf
  CONFIG_FILE=./bastion.conf STACKS=(stack-a stack-b stack-c) BASTION_SKIP_ENV_LINKS=0
  ln -s ../bastion.conf stack-a/.env 2>/dev/null || cp bastion.conf stack-a/.env
  cp bastion.conf stack-b/.env                       # identical copy (Git Bash "symlink")
  printf 'OPERATOR=own\n' > stack-c/.env             # the operator's own file
  remove_legacy_stack_envs
  [ ! -e stack-a/.env ] && [ ! -e stack-b/.env ] && [ -f stack-c/.env ] )
assert_eq "$?" 0 "links and identical copies removed; a differing .env is kept"

echo "== bastion.conf is parsed, never executed =="
cat > "$CONFIG_FILE" <<EOF
NODE_ALIAS=\$(touch $WORK/EXECUTED)
GIT_USER=\`touch $WORK/EXECUTED2\`
export TIMEZONE='Europe/Madrid'
not a key line
EOF
( load_config >/dev/null 2>&1 )
assert_ok test '!' -e "$WORK/EXECUTED"
assert_ok test '!' -e "$WORK/EXECUTED2"
assert_eq "$(read_env_var NODE_ALIAS)" "\$(touch $WORK/EXECUTED)" "a command substitution is kept as literal data"
assert_eq "$(read_env_var TIMEZONE)" "Europe/Madrid" "export prefix + quotes decoded"

echo "== a key set twice takes its last value (as when the file was sourced) =="
printf "NODE_ALIAS='first'\nGIT_USER='u'\nNODE_ALIAS='appended-override'\n" > "$CONFIG_FILE"
assert_eq "$(read_env_var NODE_ALIAS)" "appended-override" "the appended line wins"
config_parse_file
assert_eq "${CONFIG_KEYS[*]}" "NODE_ALIAS GIT_USER" "each key listed once, in first-seen order"

echo "== a legacy bastion.conf loads with every value intact =="
cp tests/fixtures/legacy-config.conf "$CONFIG_FILE"
legacy_expect=(
  "WIREGUARD_SERVERURL=vpn.example.org" "WIREGUARD_SERVERPORT=51820" "WIREGUARD_PEERS=3"
  "NODE_ALIAS=legacy node" "TIMEZONE=Europe/Madrid" "PIHOLE_PASSWORD=p'w\$d"
  "CODEDECK_RELAYS=wss://relay.one.example,wss://relay.two.example"
  "CODEDECK_TOR_PROXY_URL=socks5h://tor:9050" "GIT_USER=Some Name"
  "CCR_WEB_AUTH_TOKEN=ccr-token-0123456789" "MCP_GATEWAY_TOKEN=mcp-token-abcdefghij"
  "CONTEXT7_API_KEY=" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fake"
  "CCR_REFRESH_INTERVAL=900"          # set twice: the later line wins
  "AGENT_DOCKER_CPUS=3"               # was a custom var, now a managed setting
  "LXMF_ALLOWED_IDENTITY=deadbeef" "MY_TOOL_FLAG=on"   # retired / unknown: kept
)
for pass in "first load" "reload of the rewritten file"; do
  got=$( unset "${MANAGED_VARS[@]}"; SECRETS_DIR="$WORK/legacy-secrets"; load_config >/dev/null 2>&1
         for e in "${legacy_expect[@]}"; do k=${e%%=*}; printf '%s=%s\n' "$k" "${!k-}"; done )
  assert_eq "$got" "$(printf '%s\n' "${legacy_expect[@]}")" "legacy values intact ($pass)"
done
assert_eq "$(cat "$WORK/legacy-secrets/pihole_password")" "p'w\$d" "a legacy secret projects to its file verbatim"
assert_eq "$(read_env_var AGENT_DOCKER_MEMORY)" "4g" "a newly managed setting gets its default"

echo "== load_config: defaults only fill empty keys; file untouched when unchanged =="
: > "$CONFIG_FILE"
( unset "${MANAGED_VARS[@]}"; NODE_ALIAS=keep; export NODE_ALIAS
  load_config >/dev/null 2>&1 )
tok1=$(read_env_var MCP_GATEWAY_TOKEN)
assert_eq "${#tok1}" 43 "a missing token is generated (43 URL-safe chars)"
assert_eq "$(read_env_var CCR_REFRESH_INTERVAL)" "300" "a literal default is written"
m1=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || stat -f %m "$CONFIG_FILE")
sleep 1
( unset "${MANAGED_VARS[@]}"; load_config >/dev/null 2>&1 )
m2=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || stat -f %m "$CONFIG_FILE")
assert_eq "$m1" "$m2" "a second load with nothing to change does not rewrite bastion.conf"
assert_eq "$(read_env_var MCP_GATEWAY_TOKEN)" "$tok1" "an existing token is never regenerated"

echo "== config_set =="
( unset "${MANAGED_VARS[@]}"; config_set NODE_ALIAS "new-alias" >/dev/null ); rc=$?
assert_eq "$rc" 0 "a valid value is saved"
assert_eq "$(read_env_var NODE_ALIAS)" "new-alias" "the new value is in bastion.conf"
assert_eq "$(read_env_var MCP_GATEWAY_TOKEN)" "$tok1" "other values are preserved"
out=$( config_set WIREGUARD_SERVERPORT 99999 ); rc=$?
assert_eq "$rc" 1 "an invalid value is refused"
assert_contains "$out" "port number" "with the validation message"
out=$( config_set NOT_A_SETTING x ); rc=$?
assert_eq "$rc" 1 "an unknown key is refused"

echo "== every \${VAR} the compose files interpolate is managed or has a default =="
missing=""
# capture the whole ${...} so we can tell ${FOO} from ${FOO:-default}
while read -r ref; do
  case "$ref" in *:-*|*:\?*|*:+*) continue ;; esac   # has a default -> fine if unset
  name=$(printf '%s' "$ref" | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*).*/\1/')
  case " ${MANAGED_VARS[*]} " in *" $name "*) : ;; *) missing="$missing $name" ;; esac
# strip full-line comments first so a ${VAR} written in a comment can't count
done < <(grep -rhE -v '^[[:space:]]*#' stack-*/docker-compose.yml \
          | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(:[-?+][^}]*)?\}' | sort -u)
assert_eq "$missing" "" "no undefaulted compose var is missing from MANAGED_VARS"

echo "== seed_runtime_config is create-only / idempotent =="
mkdir -p "$WORK/tpl"
printf 'TEMPLATE\n' > "$WORK/tpl/src"
SEED_TEMPLATES=("$WORK/tpl/src:$WORK/out/dst")
seed_runtime_config >/dev/null
assert_eq "$(cat "$WORK/out/dst" 2>/dev/null)" "TEMPLATE" "seeds a missing target from its template"
mtime1=$(stat -c %Y "$WORK/out/dst" 2>/dev/null || stat -f %m "$WORK/out/dst")
sleep 1
seed_runtime_config >/dev/null
mtime2=$(stat -c %Y "$WORK/out/dst" 2>/dev/null || stat -f %m "$WORK/out/dst")
assert_eq "$mtime1" "$mtime2" "a second call does not rewrite an existing target"
printf 'OPERATOR EDIT\n' > "$WORK/out/dst"
seed_runtime_config >/dev/null
assert_eq "$(cat "$WORK/out/dst")" "OPERATOR EDIT" "an existing target with different content is left untouched"
rm -f "$WORK/tpl/src"
SEED_TEMPLATES=("$WORK/tpl/src:$WORK/out/gone")
seed_runtime_config >/dev/null
echo "== a missing template seeds nothing =="
assert_ok test '!' -e "$WORK/out/gone"

echo "== seed_teos_config is create-only / idempotent =="
printf 'TEOS TEMPLATE\n' > "$WORK/tpl/teos-src"
TEOS_SEED_SRC="$WORK/tpl/teos-src"; TEOS_SEED_DST="$WORK/teosout/teos.toml"
seed_teos_config >/dev/null
assert_eq "$(cat "$WORK/teosout/teos.toml" 2>/dev/null)" "TEOS TEMPLATE" "seeds teos.toml when the target is absent"
printf 'OPERATOR TEOS EDIT\n' > "$WORK/teosout/teos.toml"
seed_teos_config >/dev/null
assert_eq "$(cat "$WORK/teosout/teos.toml")" "OPERATOR TEOS EDIT" "an existing teos.toml is never overwritten"
TEOS_SEED_SRC="$WORK/tpl/teos-missing"; TEOS_SEED_DST="$WORK/teosout/none.toml"
seed_teos_config >/dev/null
echo "== a missing teos.toml template seeds nothing =="
assert_ok test '!' -e "$WORK/teosout/none.toml"

echo "== ensure_rtl_rune =="
mock_dir=$(mktemp -d)
cat > "$mock_dir/docker" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "exec lightningd" ] && { printf '%s\n' "\${MOCK_EXEC_OUT:-}"; exit "\${MOCK_EXEC_RC:-0}"; }
exit 0
EOF
chmod +x "$mock_dir/docker"; PATH="$mock_dir:$PATH"

RTL_RUNE_FILE="$WORK/rune"; RTL_RUNE_RETRIES=2; RTL_RUNE_WAIT=0
MOCK_EXEC_OUT=$'rune=abcDEF123\nunique_id=0' ensure_rtl_rune >/dev/null
assert_eq "$(cat "$WORK/rune" 2>/dev/null)" 'LIGHTNING_RUNE="abcDEF123"' "writes the rune in LIGHTNING_RUNE= form"
# POSIX modes only round-trip reliably on Linux (Windows maps them to ACLs).
[ "$(uname -s)" = Linux ] && \
  assert_eq "$(stat -c '%a' "$WORK/rune")" "600" "rune file is mode 600"
MOCK_EXEC_OUT='rune=SHOULD_NOT_BE_USED' ensure_rtl_rune >/dev/null
assert_eq "$(cat "$WORK/rune")" 'LIGHTNING_RUNE="abcDEF123"' "an existing rune is left untouched (early return)"
rm -f "$WORK/rune"
MOCK_EXEC_OUT='{"rune":"jsonRUNE99","unique_id":"0"}' ensure_rtl_rune >/dev/null
assert_eq "$(cat "$WORK/rune" 2>/dev/null)" 'LIGHTNING_RUNE="jsonRUNE99"' "parses a rune from a JSON response too"
rm -f "$WORK/rune"
out=$(MOCK_EXEC_RC=1 MOCK_EXEC_OUT="" ensure_rtl_rune 2>&1); rc=$?
assert_eq "$rc" 0 "returns 0 when CLN is unreachable (never aborts the boot)"
assert_contains "$out" "CLN not reachable" "warns when the rune could not be minted"
echo "== writes no file on failure =="
assert_ok test '!' -e "$WORK/rune"

echo "== write_secret_files derives one file per secret from the environment =="
SECRETS_DIR="$WORK/secrets"
PIHOLE_PASSWORD="s3cr3t/with=weird+chars"
CCR_WEB_AUTH_TOKEN="ccrtok"
CLAUDE_CODE_OAUTH_TOKEN=""            # unset optional secret -> empty file
GITHUB_TOKEN="ghtok"
write_secret_files
for f in pihole_password ccr_web_auth_token claude_code_oauth_token github_token; do
  assert_ok test -f "$SECRETS_DIR/$f"
done
assert_eq "$(cat "$SECRETS_DIR/pihole_password")" "s3cr3t/with=weird+chars" "value written verbatim (no quoting, no newline)"
assert_eq "$(wc -c < "$SECRETS_DIR/pihole_password")" "23" "no trailing newline"
assert_eq "$(cat "$SECRETS_DIR/claude_code_oauth_token")" "" "an unset secret becomes an empty file"
[ "$(uname -s)" = Linux ] && {
  assert_eq "$(stat -c '%a' "$SECRETS_DIR")" "700" "secrets dir is 700"
  assert_eq "$(stat -c '%a' "$SECRETS_DIR/pihole_password")" "600" "secret file is 600"
}
# non-secret managed vars never get a file
assert_ok test '!' -e "$SECRETS_DIR/node_alias"
# rewrite only on change
mtb=$(stat -c %Y "$SECRETS_DIR/github_token" 2>/dev/null || stat -f %m "$SECRETS_DIR/github_token")
sleep 1; write_secret_files
mta=$(stat -c %Y "$SECRETS_DIR/github_token" 2>/dev/null || stat -f %m "$SECRETS_DIR/github_token")
assert_eq "$mtb" "$mta" "an unchanged value is not rewritten"
GITHUB_TOKEN="rotated"; write_secret_files
assert_eq "$(cat "$SECRETS_DIR/github_token")" "rotated" "a changed value is rewritten"
# SECRETS_DIR follows CONFIG_FILE, so a scratch CONFIG_FILE keeps it out of the repo
( export CONFIG_FILE="$WORK/x/bastion.conf"
  unset SECRETS_DIR
  # shellcheck disable=SC1091
  source utils/config.sh
  write_secret_files
  assert_eq "$SECRETS_DIR" "$WORK/x/secrets" "SECRETS_DIR defaults next to CONFIG_FILE" )

finish
