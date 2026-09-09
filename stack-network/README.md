# Network Stack

The network foundation for Bastion. Start this stack before any other stack. It
creates the shared transit network and owns Tor.

## Services

| Service | Address | Host exposure |
|---|---|---|
| Unbound | `10.10.0.2:53` | Network stack only |
| WireGuard | `10.10.0.3` | `51820/udp` |
| Tor | `10.254.0.2:9050`, `:9051` | Shared transit proxy/control service |
| Pi-hole | host network | `8081` and configured DNS ports |

The stack creates its private `bastion-network` subnet (`10.10.0.0/24`)
and the cross-stack `bastion-transit` subnet (`10.254.0.0/24`). Only services
that need cross-stack communication join the transit network.

## Commands

```bash
docker compose -f ./stack-network/docker-compose.yml up -d
docker compose -f ./stack-network/docker-compose.yml ps
docker compose -f ./stack-network/docker-compose.yml logs -f
```

Stop this stack only after dependent stacks are stopped. Do not remove the networks
while other Bastion stacks are running. Tor state is kept in the Docker-managed
`bastion-tor-data` volume; `config/torrc` remains an ordinary editable file.

## Configuration

Values come from the root `bastion.conf` through `.env` on Linux:

- `TIMEZONE`
- `PIHOLE_PASSWORD`
- `WIREGUARD_SERVERURL`
- `WIREGUARD_SERVERPORT`
- `WIREGUARD_PEERS`
- `USER_ID` and `GROUP_ID`

Persistent WireGuard and Pi-hole state lives under `data/`. Keep it intact when
troubleshooting or upgrading.

After migrating an existing installation, review generated WireGuard peer files
and Pi-hole's persisted DNS configuration. They are runtime state and are ignored
by Git; the Compose values are updated for new deployments, but existing generated
files may need to be regenerated or updated during the maintenance window.

To change Tor settings, edit `config/torrc` and restart Tor:

```bash
docker compose -f ./stack-network/docker-compose.yml restart tor
```

The Tor state volume can be inspected with a temporary helper container, but its
runtime files should not be edited during normal operation:

```bash
docker run --rm -it -v bastion-tor-data:/data alpine:latest sh
```
