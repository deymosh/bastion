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
| `mcp-gateway` | `10.50.0.5` | `8811` (`/mcp`) | Five MCP servers behind one Bearer token. See [docs/mcp.md](../docs/mcp.md) |
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
within a day, and CCR never refreshes it itself. A CCR plugin bundled in the
image (`ccr/ccr-oauth-refresh-plugin.cjs`) does, on demand: when Anthropic
answers a request with `401`, CCR retries it once, and on that retry the
plugin has the official `claude` CLI refresh the login (rotating both tokens in
the credentials file), then sends the retry with the new token. The account
usage CCR shows for the provider (a separate request, which CCR itself never
retries) gets the same treatment: a `401` there refreshes and resends it once.
Nothing runs in the background and nothing is polled; CCR re-reads the file on every request,
so no restart is needed. The CLI run spends no inference: it asks for a model
that does not exist, after refreshing.

A refresh that fails leaves the original `401` to reach the client, and is not
retried for a minute. The refresh token itself expires too (about 9-10 days
after it was issued, in the logins observed so far), and only an interactive
login replaces it. Every successful refresh logs both expiries and warns
when the refresh token has under two days left; every case that needs you to
log in again (refresh token rejected or expired, no login at all) logs a line
containing `LOGIN NEEDED`. Check with
`./bastion logs ccr | grep bastion-claude-oauth-refresh`, or alert on
`LOGIN NEEDED`. `CCR_TOKEN_REFRESH=0` turns the plugin off. Like the schema
sanitizer below, a fresh install gets the plugin from its second start.

### Tool schemas other providers reject

Claude Code describes its tools with JSON Schema, and some providers compile
those schemas and refuse the whole request when one uses regex syntax their
engine lacks. DeepSeek, for one, answers every Claude Code request with HTTP
400 because the `Artifact` tool's `file_paths` items carry the pattern
`^[^\0]*$`: `\0` (NUL) is valid JavaScript and PCRE, but not portable.

The image bundles a CCR plugin, `ccr/ccr-tool-schema-plugin.cjs` (using
`ccr/ccr-tool-schema-sanitizer.cjs`), that removes such patterns (backtracking
syntax: digit escapes like `\0`, lookarounds, atomic groups) and the
`prefixItems` / `propertyNames` keywords from every request's tools, and keeps
the tools themselves. A pattern only steers the model; Claude Code still
validates every tool call against its own schema. It runs inside CCR's core
gateway as a request transform, after routing has settled, so it covers every
route, including subagents routed by a model tag, and never picks a model.
Running it there (rather than as a CCR-side transform or custom router) keeps
CCR serving straight from its core gateway, with no extra proxy in between.

At start, the wrapper registers the bundled plugins
(`ccr/ccr-enable-plugins.mjs`). CCR keeps them through edits in its UI. A
fresh install gets them on its second start, since CCR writes its config on
the first. An entry an operator pointed at another module is left alone; one
the operator disabled stays disabled. Upgrading from an image that ran the
sanitizer as CCR's `CUSTOM_ROUTER_PATH` removes that setting (any other
router stays). To check: `./bastion logs ccr | grep ccr-enable-plugins`.

As a last resort, a tool a provider cannot take at all can be dropped for it.
With `CCR_DROP_TOOLS` set to `deepseek=Artifact,ArtifactData;gemini=Monitor`,
the listed tools are dropped whenever the routed model or its provider's
name contains the text before `=` (`./bastion config set CCR_DROP_TOOLS '...'`, then restart
`ccr`).

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
`memory` (basic-memory) and `time`. The gateway serves their tools merged,
namespaced (`searxng_web_search`, `memory_search_notes`, …) and trimmed to a
lean context budget (useless tools dropped, verbose descriptions rewritten)
over Streamable HTTP at `:8811/mcp`. The packages are pinned exactly at build
time, and nothing is fetched at runtime. A child that crashes only fails its
own calls and is respawned on the next one. The endpoint, the tool list,
token rotation and a ready-to-use `.mcp.json` are in
[docs/mcp.md](../docs/mcp.md).

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
| `data/mcp/` | MCP gateway state: the memory knowledge base (`memory/`) |
| volumes `agent_docker_*` | The agent daemon's images, TLS tree and published CLI |
