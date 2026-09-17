# Web Stack

The Bastion operations Hub: a small static Nginx site that links to the services
available on the current host.

## Service

| Service | Address | Purpose |
|---|---|---|
| Hub | `http://localhost` | Service directory and access point |

The Hub includes RTL, Grafana, Portainer, Prometheus, Pi-hole, and CCR. CCR is
published on host port `3458`, so its Hub link works from the Bastion host and
from clients connected through WireGuard.

Picking a service keeps you inside the Hub instead of opening a new tab: a
persistent top banner (Bastion icon + current section) stays visible while the
service loads in an embedded panel, and clicking the icon returns to the
directory. This is client-side routing only (`location.hash`, no server
component) - a bookmark like `/#grafana` reopens straight into that service.
Every embedded view keeps an "Open in new tab" button in the banner, because a
service can send `X-Frame-Options`/`frame-ancestors` headers that refuse to be
framed at all - the Hub has no control over another container's own response
headers, so that button is the guaranteed fallback, not just a convenience.

## Commands

```bash
docker compose -f ./stack-web/docker-compose.yml up -d
docker compose -f ./stack-web/docker-compose.yml ps
docker compose -f ./stack-web/docker-compose.yml logs -f hub
```

The site is served read-only from `html/`. `favicon.svg` is the local Bastion
favicon. To add or remove a service, edit the `services` array in
`html/index.html` (each entry needs a unique `key` for the URL hash); keep
ports/paths aligned with what the corresponding Compose file actually
publishes.
