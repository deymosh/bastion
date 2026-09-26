# Network stack

The foundation that every other stack depends on. It runs Tor, private DNS and
the VPN, and it **owns the two shared resources** the other stacks attach to:

- `bastion-transit` (`10.254.0.0/24`), the one cross-stack network;
- `bastion-tor-data`, Tor's data volume, which `lightningd` and `teosd` mount
  read-only for the control cookie.

`./bastion up` always starts this stack first and waits for `tor` to be healthy.
`stop`/`down` of this stack, or of any of its containers, is refused while
another stack is running, because that would cut Lightning off from Tor.
Stop the dependants first, or pass `--force`.

## Services

| Service | Address | Host exposure | Purpose |
|---|---|---|---|
| `tor` | `10.254.0.2` (`:9050` SOCKS, `:9051` control) | none | Egress proxy and onion-service host for the node |
| `pihole` | host network | `8081` (admin), `53` (DNS) | Ad-blocking DNS and the `bastion.node` record |
| `unbound` | `10.10.0.2:53` | none | Recursive resolver, Pi-hole's only upstream |
| `wireguard` | `10.10.0.3` | `51820/udp` | Remote access (clients on `10.13.13.0/24`) |

`tor`'s address is pinned and referenced by `config/torrc`, `cln_config`,
`teos.toml` and the healthcheck. Keep all of them in sync if it ever changes.
`tor` sits on `bastion-transit` only and cannot reach any per-stack subnet.

## Access model

Pi-hole holds a local DNS record that points a name such as `bastion.node` at
the host's LAN IP. Every Hub panel is published on `0.0.0.0`, so that one name
works over WireGuard, from `localhost` and from the LAN. The **host firewall**
controls access; the reference setup is in [docs/firewall.md](../docs/firewall.md).

## Configuration

Settings (see [docs/configuration.md](../docs/configuration.md)):
`WIREGUARD_SERVERURL`, `WIREGUARD_SERVERPORT`, `WIREGUARD_PEERS`, `TIMEZONE`,
`USER_ID`, `GROUP_ID`, and `PIHOLE_PASSWORD`, which reaches the container as
`/run/secrets/pihole_password` rather than as an env var.

| File | What |
|---|---|
| `config/torrc` | SOCKS and control ports bound to the transit IP; cookie auth that the node's group can read |
| `config/unbound.conf` | Resolver configuration |
| `Dockerfile.tor` | Tor image. Pre-creates `/data/.tor` as gid 1000, mode `0750` |
| `data/` | WireGuard peers and Pi-hole state. Runtime data; keep it |

After changing `torrc`, run `./bastion restart tor --force` (`--force` is needed
while other stacks are running).

## Linux-only pieces

Pi-hole uses `network_mode: host`, and WireGuard mounts `/lib/modules`. Neither
works on Docker Desktop, so verify them on the Linux host.

## Troubleshooting

```bash
./bastion logs tor
./bastion exec unbound -- drill @127.0.0.1 example.com     # resolver works?
docker kill --signal=HUP tor                               # reload torrc, new circuits
```

To reset Tor's state (circuits and consensus cache only; the node's onion keys
live in CLN's `hsm_secret`), run:

```bash
./bastion down                 # every stack: the volume is in use by lightningd/teosd
docker volume rm bastion-tor-data
./bastion up
```

### Migrating from the old flat network

Early versions used one `bastion-network` on `10.0.0.0/24`. The name stayed the
same but the subnet is now `10.10.0.0/24`, and Docker will not change the
subnet of an existing network. `./bastion up` detects this and stops;
`./bastion up --recreate-networks` brings everything down and recreates the
network. Afterwards, review the WireGuard peer files and Pi-hole's DNS settings.
