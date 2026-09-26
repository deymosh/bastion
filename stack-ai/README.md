# AI stack

The AI control plane:

- **Claude Code Router** (CCR), the gateway to Claude;
- the **CodeDeck+ bridge**, which lets you drive remote Claude Code sessions
  from the Android app over Nostr;
- an **MCP gateway**, which gives remote agents one authenticated tool endpoint.

## Services

| Service | Address | Host port | Purpose |
|---|---|---|---|
| `ccr` | `10.50.0.2` (gateway `ccr:8080`) | `3458` (UI) | Claude Code Router, built from a pinned upstream commit |
| `codedeck-bridge` | `10.50.0.3` + transit | — | Nostr bridge for the CodeDeck+ app. Relay traffic goes over Tor |
| `searxng` | `10.50.0.4` | — | Internal metasearch, used only by the gateway |
| `mcp-gateway` | `10.50.0.5` | `8811` (`/mcp`) | Four MCP servers behind one Bearer token. See [docs/mcp.md](../docs/mcp.md) |
| `agent-docker` *(opt-in)* | `10.50.0.6` | — | Private Docker daemon for the agent, on Sysbox. See [docs/agent-docker.md](../docs/agent-docker.md) |

The bridge sends Claude requests to CCR at `http://ccr:8080`, and its relay
connections use Tor at `socks5h://tor:9050`. That is why it is the only
service in this stack on `bastion-transit`.

Every container here runs **unprivileged**, with `cap_drop: ALL` and
`no-new-privileges`. The MCP gateway and SearXNG also run on a read-only
root filesystem.

## CCR

`ccr/Dockerfile.ccr` builds CCR from the upstream commit pinned as `CCR_REF`
(in the compose file). The comment there has the command for bumping it.
The image also bundles Claude Code.

The entrypoint wrapper (`ccr/ccr-entrypoint-wrapper.sh`) starts as root only to
`chown` the writable paths to `USER_ID`/`GROUP_ID`, then drops privileges with
`gosu`. The five `cap_add` entries are used only during that step, and the
nginx, pm2 and node processes hold no capabilities. The UI token is read from
`/run/secrets/ccr_web_auth_token`.

### Authentication and token refresh

Log in once, interactively:

```bash
./bastion exec ccr -- claude     # stores data/ccr/.claude/.credentials.json
```

A plain API key set in the CCR UI also works. The OAuth access token expires
about once a day. A refresher bundled in the image (`ccr/ccr-token-refresher.mjs`)
swaps the refresh token for a new pair shortly before expiry and rewrites the
credentials file atomically. CCR re-reads the file on every request, so no
restart is needed. If there is no credentials file, or it is not an OAuth file,
the refresher just logs `idle`. On `invalid_grant`, log in again.

The refresher's settings are `CCR_TOKEN_REFRESH`, `CCR_REFRESH_INTERVAL` and
`CCR_REFRESH_SKEW_MS`. To debug it:
`./bastion logs ccr | grep ccr-token-refresher`.

## CodeDeck+ bridge

The bridge is the published image `ghcr.io/deymosh/codedeck-plus-bridge`,
pinned by digest. It runs as uid 1000 and keeps its identity, pairings,
sessions and workspaces in `data/codedeck/`.

1. Set `CODEDECK_RELAYS` (your trusted relays) and `CLAUDE_CODE_OAUTH_TOKEN`;
   `GIT_*` and `GITHUB_TOKEN` are optional.
2. `./bastion up ai`
3. Pair the app by scanning the QR code in `./bastion logs codedeck-bridge`.

Optional features: an OpenCode backend (`CODEDECK_OPENCODE_*`) and the GSD
planning workflow (`CODEDECK_GSD_AUTO_INSTALL`). Both are off by default; see
[docs/configuration.md](../docs/configuration.md#notes-on-specific-settings).

With `agent-docker` running, the bridge also gets `docker` (with buildx and
compose) on its `PATH`. The agent can then build and run a project's toolchain
container against `/data/workspaces/<repo>`, over mutual TLS, while staying
invisible to the host's Docker.

## MCP gateway

Four stdio MCP servers run as children of one container: `searxng`, `context7`,
`memory` and `time`. The gateway serves their tools merged and namespaced
(`searxng_web_search`, `memory_create_entities`, …) over Streamable HTTP at
`:8811/mcp`. The packages are pinned exactly at build time, and nothing is
fetched at runtime. A child that crashes only fails its own calls and is
respawned on the next one. The endpoint, the tool list, token rotation and a
ready-to-use `.mcp.json` are in [docs/mcp.md](../docs/mcp.md).

## Configuration

Every setting is in [docs/configuration.md](../docs/configuration.md). The
secrets `CCR_WEB_AUTH_TOKEN`, `MCP_GATEWAY_TOKEN`, `CONTEXT7_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN` and `GITHUB_TOKEN` are mounted as
`/run/secrets/<name>` files, only into the one service that needs each. CCR and
the bridge fall back to the env var when the file is absent (a standalone run);
the MCP gateway does not, and refuses to start without its token file.

## State

| Path | What |
|---|---|
| `data/ccr/` | CCR config and the Claude login (`.claude/.credentials.json`, live secret) |
| `data/codedeck/` | Bridge identity, pairings, sessions and `workspaces/` |
| volume `mcp_memory_data` | The memory server's knowledge graph |
| volumes `agent_docker_*` | The agent daemon's images, TLS tree and published CLI |
