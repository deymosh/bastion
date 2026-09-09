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

## Commands

```bash
docker compose -f ./stack-web/docker-compose.yml up -d
docker compose -f ./stack-web/docker-compose.yml ps
docker compose -f ./stack-web/docker-compose.yml logs -f hub
```

The site is served read-only from `html/`. `favicon.svg` is the local Bastion
favicon. Edit `html/index.html` to add or remove service links; keep links aligned
with the actual published ports in the corresponding Compose files.
