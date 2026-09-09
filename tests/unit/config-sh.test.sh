#!/usr/bin/env bash
###############################################################################
# Unit tests for utils/config.sh: read_env_var, validate_env_value,
# config_var_is_secret, write_config idempotency, MANAGED_VARS coverage.
# Runs against a scratch CONFIG_FILE - never touches the real bastion.conf.
###############################################################################
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
done < <(grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*(:[-?+][^}]*)?\}' stack-*/docker-compose.yml | sort -u)
assert_eq "$missing" "" "no undefaulted compose var is missing from MANAGED_VARS"

finish
