# Configuration

Everything Bastion needs lives in one file at the repo root, `bastion.conf`. It
is git-ignored and holds live secrets. `./bastion` creates it on first run,
fills in generated defaults (tokens, the Pi-hole password, your uid/gid and
timezone), and asks for the three values that have no sensible default the
first time you run `up`.

## Reading and changing settings

```bash
./bastion config                          # every setting, grouped; secrets masked
./bastion config get NODE_ALIAS           # one raw value
./bastion config set NODE_ALIAS my-node   # validated, then saved
./bastion config set GITHUB_TOKEN ""      # "" clears a setting
```

The TUI's **Configuration** view does the same interactively: the title line
describes the selected setting, and 0/1 settings toggle on Enter. You can also
edit `bastion.conf` by hand. Keep the `KEY='value'` form; if a key appears
twice, the last one wins.

`set` and the TUI reject invalid values (a port out of range, an unknown
profile, a relative path). An empty value is valid for any optional setting;
if the setting has a default, the default comes back on the next run.

## How settings reach the containers

- **Plain settings** are interpolated into the compose files. `./bastion` runs
  every `docker compose` with `--env-file bastion.conf`, so no per-stack
  `.env` copy exists. Older versions created `stack-*/.env` links, which
  `./bastion` now removes.
- **Secrets** (marked *secret* below) never travel as environment variables.
  `./bastion` writes each one to `secrets/<lower_case_name>` (mode 600, dir
  700), and the compose files mount those at `/run/secrets/<name>`.
- **Daemon settings** are read by `services/bastion-daemon.sh` at start;
  restart the service after changing them.

Changes to plain settings and secrets apply on the next `./bastion up` of the
affected stack. A container that reads its secret only at startup (e.g. the
MCP gateway) also needs `./bastion restart <container>`.

## Opt-in services

`ENABLED_PROFILES` lists the optional services that every `./bastion up`
starts, including the boot daemon's:

```bash
./bastion config set ENABLED_PROFILES watchtower,agent-docker
```

`--with-watchtower` / `--with-agent-docker` (or `BASTION_PROFILES=...`) add a
profile for a single run without saving it. `stop` and `down` always include
every opt-in service. See [agent-docker.md](agent-docker.md) for the Sysbox
requirement of `agent-docker`.

## Notes on specific settings

- **`CODEDECK_OPENCODE_*`**: an optional second session backend
  (CodeDeck+ >= v0.12.0). With all three empty the bridge is Claude Code only.
  Either point `CODEDECK_OPENCODE_SERVER_URL` at an external `opencode serve`
  (it wins if both are set), or set `CODEDECK_OPENCODE_AUTO_START=1` to have
  the bridge run its own, bound to 127.0.0.1 inside the container.
  `CODEDECK_OPENCODE_PORT` pins that server's port.
- **`CODEDECK_GSD_AUTO_INSTALL`**: off by default because installing gsd-core
  is an npm-registry call on every container boot, made outside
  `CODEDECK_TOR_PROXY_URL`. Without it, sessions work normally; the phone's GSD
  stage strip just stays empty.
- **`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`**: has no effect if
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set anywhere.
- **`CLAUDE_CODE_OAUTH_TOKEN`**: used by the CodeDeck+ bridge. CCR itself
  authenticates with an interactive `claude` login stored in
  `stack-ai/data/ccr/.claude/.credentials.json` (see the `ccr-oauth` skill).
- **`BACKUP_DEST`**: must be the mount point of a separate drive. If nothing
  is mounted there, the daemon refuses to back up rather than writing to the
  node's own disk.

## Adding a setting (for contributors)

Add one row to [`utils/settings.registry`](../utils/settings.registry). Its
header documents the columns, types and flags. Wire the value where it is used
(a compose `${VAR}`, or a `secrets:` entry for a secret), then run
`utils/gen-config-docs.sh` to refresh the table below; the static tests fail
while it is stale.

## All settings

The tables below are generated from the registry.

<!-- BEGIN GENERATED: settings (utils/gen-config-docs.sh) -->

### Network

| Setting | Default | Type | Description |
|---|---|---|---|
| `WIREGUARD_SERVERURL` | - | host, **required** | Public IP or DNS name WireGuard clients connect to. |
| `WIREGUARD_SERVERPORT` | - | port, **required** | Public UDP port of the WireGuard server. |
| `WIREGUARD_PEERS` | `1` | int | Number of WireGuard peer profiles to generate. |

### Bitcoin and Core Lightning

| Setting | Default | Type | Description |
|---|---|---|---|
| `NODE_ALIAS` | - | alias, **required** | Alias announced by the Core Lightning node (max 32 characters). |

### Host and access

| Setting | Default | Type | Description |
|---|---|---|---|
| `TIMEZONE` | host timezone | tz | Container and host timezone, e.g. Europe/Madrid. |
| `USER_ID` | your uid | int | Host UID for services that run unprivileged. |
| `GROUP_ID` | your gid | int | Host GID for services that run unprivileged. |
| `PIHOLE_PASSWORD` | random (16 hex) | text, secret | Pi-hole web administration password. |

### CodeDeck+

| Setting | Default | Type | Description |
|---|---|---|---|
| `CODEDECK_RELAYS` | - | relays | Comma-separated trusted Nostr relay URLs (ws:// or wss://). |
| `CODEDECK_TOR_PROXY_URL` | `socks5h://tor:9050` | socks | SOCKS5 proxy for CodeDeck relay connections. |
| `GIT_REPO` | - | text | Comma-separated Git repositories cloned into CodeDeck workspaces. |
| `GIT_USER` | - | text | Git author name used by CodeDeck. |
| `GIT_EMAIL` | - | email | Git author email used by CodeDeck. |
| `CODEDECK_OPENCODE_SERVER_URL` | - | http | OpenCode session backend URL (empty = Claude Code only). |
| `CODEDECK_OPENCODE_AUTO_START` | - | bool | 1 starts an OpenCode server with the bridge (empty = off). |
| `CODEDECK_OPENCODE_PORT` | - | port | Port of the auto-started OpenCode server. |
| `CODEDECK_GSD_AUTO_INSTALL` | - | bool | 1 installs the GSD planning workflow on boot (empty = off). |
| `CLAUDE_CODE_OAUTH_TOKEN` | - | text, secret | Claude Code OAuth token used by CodeDeck+. |
| `GITHUB_TOKEN` | - | text, secret | GitHub token for CodeDeck repository operations. |

### Claude Code Router

| Setting | Default | Type | Description |
|---|---|---|---|
| `CCR_WEB_AUTH_TOKEN` | random (43 chars) | text, secret | Token for the CCR web UI. |
| `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` | `1` | bool | 1 lets Claude Code list models from the gateway (/v1/models). |
| `CCR_TOKEN_REFRESH` | `1` | bool | 1 keeps the CCR OAuth credentials refreshed in-container. |
| `CCR_REFRESH_INTERVAL` | `300` | posint | Seconds between refresher checks. |
| `CCR_REFRESH_SKEW_MS` | `1800000` | posint | Refresh the access token this many milliseconds before it expires. |

### MCP gateway

| Setting | Default | Type | Description |
|---|---|---|---|
| `MCP_GATEWAY_TOKEN` | random (43 chars) | text, secret | Bearer token remote MCP clients send to the gateway (:8811). |
| `CONTEXT7_API_KEY` | - | text, secret | Optional Context7 API key for higher rate limits (empty = keyless). |

### Optional services

| Setting | Default | Type | Description |
|---|---|---|---|
| `ENABLED_PROFILES` | - | profiles | Opt-in services every `up` starts, comma-separated: watchtower, agent-docker. The --with-* flags add to it for one run. |
| `AGENT_DOCKER_CPUS` | `2` | cpus | CPU cap for the agent-docker sidecar and everything it runs. |
| `AGENT_DOCKER_MEMORY` | `4g` | mem | Memory cap for the agent-docker sidecar and everything it runs (e.g. 4g). |

### Daemon

| Setting | Default | Type | Description |
|---|---|---|---|
| `BACKUP_DEST` | `/mnt/backup_cln` | path | Mount point of the drive the daemon mirrors emergency.recover to. |
| `SCB_CHECK_INTERVAL` | `3600` | posint | Seconds between the daemon checks of emergency.recover. |
| `BACKUP_PLUGIN_COMPACT` | `0` | bool | 1 compacts the CLN backup plugin database once a day. |
| `AMBOSS_HEARTBEAT` | `0` | bool | 1 posts a signed health heartbeat to Amboss. |
| `AMBOSS_INTERVAL` | `300` | posint | Seconds between Amboss heartbeats. |

<!-- END GENERATED: settings -->
