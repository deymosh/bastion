# AI Stack

The AI control plane for Bastion. It combines Claude Code Router (CCR) with the
CodeDeck+ bridge for remote Claude Code sessions.

## Services

| Service | Address | Purpose |
|---|---|---|
| CCR | `http://localhost:3458` | Provider, routing, logs, and gateway UI |
| CodeDeck bridge | `10.50.0.3` | Nostr bridge for the Android client |

Inside `bastion-ai`, CodeDeck sends Claude requests to CCR at
`http://ccr:8080`. The bridge has no published host port. Relay connections use
Bastion's Tor service on `bastion-transit` at `socks5h://tor:9050` by default.

## CCR authentication and token refresh

CCR authenticates to Anthropic with a Claude Code OAuth token created by an
interactive `claude` login (`docker exec -it ccr claude`), stored in
`data/ccr/.claude/.credentials.json`. That access token expires roughly daily.

The image runs a small refresher alongside CCR that, shortly before expiry,
exchanges the stored refresh token for a new one and rewrites the credentials
file atomically. CCR re-reads the file on every upstream request, so no restart
or signal is needed. If the refresh token itself is ever rejected
(`invalid_grant`), the log says so and an operator must run `claude` login
again. Controls (all optional, sane defaults):

- `CCR_TOKEN_REFRESH` (default `1`) - set `0` to disable the refresher.
- `CCR_REFRESH_INTERVAL` (default `300`) - seconds between checks.
- `CCR_REFRESH_SKEW_MS` (default `1800000`) - refresh this long before expiry.

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

- `CCR_WEB_AUTH_TOKEN`: required for the CCR management UI.
- `CLAUDE_CODE_OAUTH_TOKEN`: used by CodeDeck+ for Claude Code sessions.
- `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`: `1` lets Claude Code fill its
  `/model` picker from CCR's `/v1/models`. It makes no gateway request if
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set anywhere; the manual
  fallback is `ANTHROPIC_CUSTOM_MODEL_OPTION`.
- `GITHUB_TOKEN`: optional Git credential support.
- `CODEDECK_RELAYS`: trusted Nostr relay URLs.
- `CODEDECK_TOR_PROXY_URL`: relay SOCKS5 proxy.
- `GIT_REPO`, `GIT_USER`, `GIT_EMAIL`: optional workspace and Git settings.

CCR runs as root because its upstream entrypoint writes Nginx configuration at
startup; CodeDeck runs as a non-root user.

State is persisted under `data/`. Keep it intact to preserve CCR configuration,
CodeDeck identity, pairings, sessions, and workspaces.
