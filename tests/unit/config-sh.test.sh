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

# We only want config.sh's helper functions, not the prompts / .env links.
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
assert_contains "$first" "MY_CUSTOM=keepme"     "carries over a user's non-managed var"
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
