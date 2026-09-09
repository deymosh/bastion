# Network Stack

The network foundation for Bastion. Start this stack before any other stack. It
creates the shared transit network and owns Tor.

`./bastion up` enforces this: it starts `stack-network` first and adds it to the
list automatically when omitted. It also refuses `./bastion stop`/`down` of
`stack-network` while any other stack still has containers running (Lightning and
TEOS reach Tor over `bastion-transit`; removing it mid-flight cuts them off and
orphans the shared network). Bring the dependent stacks down first, or pass
`--force`.

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

## Local DNS & the access model

Pi-hole holds a local-DNS record that maps a friendly name to the host's LAN IP
(for example `bastion.node` -> `192.168.x.x`). Every Hub service - the hub
(`80`), RTL (`3000`), CLN REST (`3001`), the CCR UI (`3458`), Portainer (`4000`),
Grafana (`4001`), Prometheus (`9090`), Pi-hole (`8081`) - is published on
`0.0.0.0` on purpose, so it is reachable **over WireGuard, from localhost, and
from the LAN** by that name.

Because the ports are open on every interface, the **host firewall** is the
access-control layer. `docs/firewall.md` documents a reference nftables ruleset and a ufw recipe that
allows these ports from the WireGuard subnet and the LAN and drops them
everywhere else (never expose them to the internet - only `51820/udp` faces the
WAN). See the "Access model & firewall" section of the root `README.md`.

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

### Migrating from the old flat network

Earlier deployments put every service on a single `bastion-network` at
`10.0.0.0/24`. The network keeps its name but the subnet is now `10.10.0.0/24`,
and Docker will not reconcile a subnet change on an existing network. `./bastion
up` detects the stale network and stops with instructions; `./bastion up
--recreate-networks` brings the stacks down and drops it so it is recreated with
the new subnet. After migrating, review generated WireGuard peer files and
Pi-hole's persisted DNS configuration - they are runtime state, ignored by Git,
and may need regenerating.

To change Tor settings, edit `config/torrc` and restart Tor:

```bash
docker compose -f ./stack-network/docker-compose.yml restart tor
```

The Tor state volume can be inspected with a temporary helper container, but its
runtime files should not be edited during normal operation:

```bash
docker run --rm -it -v bastion-tor-data:/data alpine:latest sh
```
