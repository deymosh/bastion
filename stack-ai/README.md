# AI Stack

The AI control plane for Bastion. It combines Claude Code Router (CCR) with the
CodeDeck+ bridge for remote Claude Code sessions.

## Services

| Service | Address | Purpose |
|---|---|---|
| CCR | `http://localhost:3458` | Provider, routing, logs, and gateway UI |
| CodeDeck bridge | `10.50.0.3` | Nostr bridge for the Android client |
| MCP gateway | `http://localhost:8811/mcp` | Single Bearer-authenticated MCP endpoint for remote agents — [docs/mcp.md](../docs/mcp.md) |
| SearXNG | `10.50.0.4` (no host port) | Internal metasearch for the gateway's `searxng` namespace |

Inside `bastion-ai`, CodeDeck sends Claude requests to CCR at
`http://ccr:8080`. The bridge and SearXNG have no published host port. Relay
connections use Bastion's Tor service on `bastion-transit` at
`socks5h://tor:9050` by default.

## MCP gateway

`mcp-gateway` (built from `mcp-gateway/Dockerfile.mcp-gateway` + `mcp-gateway/gateway.py`) runs the
four MCP servers — searxng, context7, memory, time — as **stdio children** of
one container and serves their tools merged and namespaced (`searxng_web_search`,
`memory_create_entities`, …) over **Streamable HTTP** at `:8811/mcp`, behind a
single Bearer token read from `/run/secrets/mcp_gateway_token`. No MCP server
is published individually; SearXNG itself is internal-only infrastructure.
Endpoint, namespaces, auth rotation, and a ready-to-use `.mcp.json` live in
[docs/mcp.md](../docs/mcp.md).

The children are exact-pinned npm/PyPI packages baked in at build time (no
`npx`/`uvx` at runtime). Both new containers drop all capabilities, forbid
privilege escalation, and mount a read-only rootfs with a `/tmp` tmpfs; the
gateway runs as uid/gid 1000 and the memory knowledge graph persists in the
`mcp_memory_data` named volume. A crashed child only fails its own tool calls —
the gateway reconnects it on the next call. The gateway has no `depends_on`:
children connect lazily, so startup order never matters.

## CCR authentication and token refresh

CCR can authenticate to Anthropic with a Claude Code OAuth token created by an
interactive `claude` login (`docker exec -it ccr claude`, stored in
`data/ccr/.claude/.credentials.json`), or with a plain API key configured in the
CCR UI - either way CCR starts normally.

For the OAuth case the access token expires roughly daily, so the image runs a
small refresher alongside CCR that, shortly before expiry, exchanges the stored
refresh token for a new one and rewrites the credentials file atomically. CCR
re-reads the file on every upstream request, so no restart or signal is needed.
The refresher never blocks CCR: with no credentials file, or a non-OAuth one, it
just logs `idle` and keeps checking. If the refresh token is rejected
(`invalid_grant`), the log says so and an operator must run `claude` login
again. Controls (all optional, sane defaults):

- `CCR_TOKEN_REFRESH` (default `1`) - set `0` to disable the refresher.
- `CCR_REFRESH_INTERVAL` (default `300`) - seconds between checks.
- `CCR_REFRESH_SKEW_MS` (default `1800000`) - refresh this long before expiry.

All three are managed `bastion.conf` values - editable from the TUI's
Configuration view, not just via `stack-ai/.env`.

Debug: `docker logs ccr | grep ccr-token-refresher`.

## Commands

```bash
docker compose -f ./stack-ai/docker-compose.yml up -d --build
docker compose -f ./stack-ai/docker-compose.yml ps
docker compose -f ./stack-ai/docker-compose.yml logs -f codedeck-bridge
```

Pair the Android app by scanning the QR code shown in the bridge logs.

## Configuration

Bastion normally supplies this stack from the root `bastion.conf` through
`stack-ai/.env`. On Linux, that file is a symlink created by `./bastion`. For a
standalone Compose run, copy `.env.example` to `.env` and fill in the values.

- `CCR_WEB_AUTH_TOKEN`, `MCP_GATEWAY_TOKEN`, `CONTEXT7_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN` are
  **secrets**: `./bastion` writes them to `secrets/<name>` (repo root,
  git-ignored, `600`) from `bastion.conf`, and the compose file mounts each as
  a file under `/run/secrets/` for the one service that needs it - never a
  plaintext env var. `ccr-entrypoint-wrapper.sh` reads
  `/run/secrets/ccr_web_auth_token`; the CodeDeck+ bridge image reads
  `/run/secrets/{claude_code_oauth_token,github_token}` itself. Those three
  fall back to the env var when the file is absent (standalone Compose runs);
  the MCP gateway does **not** - it reads only the mounted token file and
  refuses to start without it.
- `MCP_GATEWAY_TOKEN`: Bearer token for the MCP gateway's `:8811/mcp`
  endpoint. Generated automatically; rotate via `bastion.conf` + a gateway
  restart.
- `CONTEXT7_API_KEY`: optional Context7 rate-limit key; empty = keyless.
- `CLAUDE_CODE_OAUTH_TOKEN`: used by CodeDeck+ for Claude Code sessions.
- `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`: `1` lets Claude Code fill its
  `/model` picker from CCR's `/v1/models`. It makes no gateway request if
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set anywhere; the manual
  fallback is `ANTHROPIC_CUSTOM_MODEL_OPTION`.
- `GITHUB_TOKEN`: optional Git credential support.
- `CODEDECK_RELAYS`: trusted Nostr relay URLs.
- `CODEDECK_TOR_PROXY_URL`: relay SOCKS5 proxy.
- `GIT_REPO`, `GIT_USER`, `GIT_EMAIL`: optional workspace and Git settings.
- `CODEDECK_OPENCODE_SERVER_URL`, `CODEDECK_OPENCODE_AUTO_START`,
  `CODEDECK_OPENCODE_PORT`: optional second session backend
  ([OpenCode](https://opencode.ai), CodeDeck+ >= v0.12.0). All empty by
  default - a bridge with none of them set behaves exactly as it always has.
- `CODEDECK_GSD_AUTO_INSTALL`: `1` installs the optional
  [GSD](https://github.com/open-gsd/gsd-core) planning workflow on boot
  (CodeDeck+ >= v0.12.0); empty/`0` skips it (default).

Both containers run **unprivileged**. `ccr-entrypoint-wrapper.sh` starts as root
only long enough to align ownership of the writable paths (nginx config/state,
the `/data` bind mount) to the host uid/gid (`USER_ID`/`GROUP_ID`, passed as
`PUID`/`PGID`), then drops to that user with `gosu` before running anything.
The compose service adds `cap_drop: [ALL]` + `no-new-privileges:true`; the five
`cap_add` entries are used only by the root wrapper at startup - the long-running
nginx / pm2 / node processes hold no capabilities and run as the host user.
Read-only rootfs is a possible future tightening (nginx writes to several
locations that would each need a tmpfs).

State is persisted under `data/`. Keep it intact to preserve CCR configuration,
CodeDeck identity, pairings, sessions, and workspaces.
