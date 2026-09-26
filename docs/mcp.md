# MCP gateway

The AI stack exposes a curated set of MCP (Model Context Protocol) servers to
remote AI agents through **one** Streamable HTTP endpoint. Agents authenticate
with a single Bearer token; individual MCP servers are never published and
cannot be reached from outside the `bastion-ai` network.

```
AI agent (LAN / WireGuard)            bastion-ai (10.50.0.0/24)
──────────────────────────            ──────────────────────────────────────────────────
        │ Streamable HTTP + Bearer    ┌─ mcp-gateway 10.50.0.5 (FastMCP 4.x) ─┐
        ▼                             │                                       │
  bastion.node:8811/mcp ─────────────►│  stdio children:                      │
  (host firewall = the ACL)           │    mcp-searxng ───── HTTP ────────────┼──► searxng 10.50.0.4
                                      │    context7-mcp ──── HTTPS ───────────┼──► context7.com
                                      │    mcp-server-memory (/data volume)   │
                                      │    mcp-server-time                    │
                                      └───────────────────────────────────────┘
```

## Endpoint and authentication

| | |
|---|---|
| URL | `http://bastion.node:8811/mcp` (Streamable HTTP, stateless) |
| Auth | `Authorization: Bearer <MCP_GATEWAY_TOKEN>` — required on every call |
| Health | `GET /healthz` — unauthenticated liveness probe (no token) |
| Transport | Streamable HTTP only (no SSE-only / stdio exposure on the host) |

The token lives in `bastion.conf` as `MCP_GATEWAY_TOKEN` (generated on first
run). `./bastion` projects it into `secrets/mcp_gateway_token` (git-ignored,
mode `600`), which Docker mounts into the gateway as
`/run/secrets/mcp_gateway_token` — the token never travels as an environment
variable and never appears in `docker inspect`. Requests without the token (or
with the wrong one) get `401` with `WWW-Authenticate: Bearer`.

Rotate the token with `./bastion config set MCP_GATEWAY_TOKEN "<new>"` (this
rewrites the secret file at once), then `./bastion restart mcp-gateway`, because
the token is read at startup.

## Namespaces and tools

Every tool is namespaced `<namespace>_<tool>` so children can never collide.
The four namespaces:

| Namespace | MCP server (pinned) | Tools |
|---|---|---|
| `searxng` | `mcp-searxng` 2.3.0 | `searxng_web_search`, `searxng_web_url_read`, `searxng_search_suggestions`, `searxng_instance_info` |
| `context7` | `@upstash/context7-mcp` 4.1.1 | `context7_resolve-library-id`, `context7_query-docs` |
| `memory` | `@modelcontextprotocol/server-memory` 2026.8.31 | `memory_create_entities`, `memory_create_relations`, `memory_add_observations`, `memory_delete_entities`, `memory_delete_relations`, `memory_delete_observations`, `memory_read_graph`, `memory_search_nodes`, `memory_open_nodes` |
| `time` | `mcp-server-time` 2026.8.18 | `time_get_current_time`, `time_convert_time` |

Notes:

- `searxng_*` queries the stack-internal SearXNG instance (see below), so
  search behavior follows its configured engines. The memory namespace edits
  the agent knowledge graph persisted in the `mcp_memory_data` volume.
- `time_*` uses the host timezone from `bastion.conf` (`TIMEZONE`).
- Upstream tool names are respected inside each namespace: mcp-searxng ships
  some tools already prefixed (`searxng_web_search`) and others not
  (`web_url_read`); the gateway strips the redundant upstream prefix so the
  served names stay uniform.
- The gateway also sends MCP server **instructions** on `initialize` (clients
  such as Claude Code place them in the model's system prompt): a short map of
  the namespaces, the two-step context7 and search-then-read flows, and the
  rule that the memory graph is shared by every agent and never holds secrets.
  They live in `INSTRUCTIONS` in `stack-ai/mcp-gateway/gateway.py`; keep them
  in sync when a namespace is added.
- Children are long-lived: each starts once (the first `tools/list` pays a
  ~1 s cold start), later calls reuse it, and a child that dies is respawned
  on the next call to its namespace.
- An optional `CONTEXT7_API_KEY` in `bastion.conf` raises context7's rate
  limits; empty (the default) means keyless service at lower limits. It is
  delivered as a secret file like the token.

## Example: remote agent configuration

Claude Code (`.mcp.json` in the project, or `claude mcp add`):

```json
{
  "mcpServers": {
    "bastion": {
      "type": "http",
      "url": "http://bastion.node:8811/mcp",
      "headers": {
        "Authorization": "Bearer <MCP_GATEWAY_TOKEN>"
      }
    }
  }
}
```

Any other MCP client that speaks Streamable HTTP works the same way: point it
at `/mcp` and set the `Authorization` header. From outside the LAN, connect
over WireGuard first — the gateway is a LAN/WireGuard service, not an internet
service (see the firewall section below).

## Network boundaries

- The gateway publishes **only** `8811` on the host (`0.0.0.0` like every Hub
  service, so WireGuard, `localhost`, and the trusted LAN all work). The host
  firewall is the access-control layer; `docs/firewall.example.nft` includes
  `8811` in `HUB_PORTS`.
- `searxng` has **no published port**. It is internal infrastructure for the
  gateway's `searxng` namespace, reachable only inside `bastion-ai`.
- No MCP service joins `bastion-transit`. The MCP layer is self-contained in
  stack-ai and cannot reach the Bitcoin/Lightning/Tor internals.
- `tests/static/validate-config.sh` asserts all of the above (unprivileged
  services, no transit membership, no extra published ports).

## Hardening

Both containers run `cap_drop: ALL` + `no-new-privileges:true` with a
**read-only root filesystem** (`/tmp` is the only writable path, a tmpfs):

- `mcp-gateway` runs as uid/gid `1000` (no capabilities, no root wrapper —
  unlike CCR it needs no ownership juggling: the memory volume is a named
  volume owned from the image, and secrets arrive as uid-1000 files).
- `searxng` runs as the image's unprivileged `searxng` user (977) with its
  settings mounted read-only.

The MCP server packages are **pinned at build time**
(`stack-ai/mcp-gateway/Dockerfile.mcp-gateway`): the three npm children install via
`npm ci` from a committed `mcp-gateway/package-lock.json`
(`mcp-searxng@2.3.0`, `@upstash/context7-mcp@4.1.1`,
`@modelcontextprotocol/server-memory@2026.8.31`), the Python layer installs
`fastmcp==4.0.5` under the `mcp-gateway/constraints.txt` transitive-pin
snapshot, and `mcp-server-time==2026.8.18` lives in its own virtualenv (it
tracks the `mcp` 1.x line, which conflicts with fastmcp's 2.x). Both base
images are digest-pinned. Children never execute `npx`/`uvx` at runtime, so a
running gateway makes no package fetches; bump a version by editing the
Dockerfile (and regenerating the lock/constraints files), then
`./bastion build stack-ai`.

## Troubleshooting

```bash
# Gateway alive?
./bastion logs mcp-gateway         # startup errors (e.g. missing token) land here
curl -s http://localhost:8811/healthz

# Gateway logs "no bearer token"? file-secrets are bind mounts, so the HOST
# file's permissions carry into the container: secrets/mcp_gateway_token must
# be readable by the container's uid 1000 (chmod 644 or chown 1000 on the
# host file fixes it - e.g. after running ./bastion as a non-1000 user).

# 401 from a client: is the token the container sees the one you are sending?
./bastion exec mcp-gateway -- cat /run/secrets/mcp_gateway_token

# Search tools return errors: check the internal SearXNG instance
./bastion logs searxng
./bastion exec mcp-gateway -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://searxng:8080/search?q=test&format=json').status)"
# (a 403 here means JSON output is disabled - the settings.yml mount is the
# fix; note SearXNG matches SHORT format names, so the list needs `- json`,
# not `- application/json`)
```

`tests/` covers the wiring without Docker (`./tests/run.sh` static + unit);
bring the subset up with `./bastion up stack-ai`.
