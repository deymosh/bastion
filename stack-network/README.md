# Network Stack

The network foundation for Bastion. Start this stack before any other stack that uses `bastion-network`.

## Services

| Service | Address | Host exposure |
|---|---|---|
| Unbound | `10.0.0.2:53` | Docker network only |
| WireGuard | `10.0.0.3` | `51820/udp` |
| Pi-hole | host network | `8081` and configured DNS ports |

The stack creates the external Docker network `bastion-network` with subnet
`10.0.0.0/24`. Other stacks join this network and use the static service addresses
defined in their Compose files.

## Commands

```bash
docker compose -f ./stack-network/docker-compose.yml up -d
docker compose -f ./stack-network/docker-compose.yml ps
docker compose -f ./stack-network/docker-compose.yml logs -f
```

Stop this stack only after dependent stacks are stopped. Do not remove the network
while other Bastion stacks are running.

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
