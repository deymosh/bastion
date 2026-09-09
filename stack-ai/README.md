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
- `GITHUB_TOKEN`: optional Git credential support.
- `CODEDECK_RELAYS`: trusted Nostr relay URLs.
- `CODEDECK_TOR_PROXY_URL`: relay SOCKS5 proxy.
- `GIT_REPO`, `GIT_USER`, `GIT_EMAIL`: optional workspace and Git settings.

CCR provider credentials are configured in the CCR UI, not through
`CLAUDE_CODE_OAUTH_TOKEN`. CCR runs as root because its upstream entrypoint writes
Nginx configuration at startup; CodeDeck runs as a non-root user.

State is persisted under `data/`. Keep it intact to preserve CCR configuration,
CodeDeck identity, pairings, sessions, and workspaces.
