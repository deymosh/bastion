# Host firewall

Bastion publishes its Hub services on `0.0.0.0` **by design** so each is
reachable over WireGuard, from `localhost`, and from the trusted LAN, keyed by a
Pi-hole local-DNS record (`bastion.node`). Because the ports are open on every
interface, the **host firewall is the access-control layer**. This is **not
optional in production**.

## What to allow

| Port(s) | Service | Allow from |
|---|---|---|
| `51820/udp` | WireGuard | **anywhere** (this is the VPN entry point) |
| `80, 3000, 3001, 3458, 4000, 4001, 9090` | Hub services (hub, RTL, CLN REST, CCR, Portainer, Grafana, Prometheus) | WireGuard subnet + trusted LAN only |
| `22` | SSH (if used) | WireGuard + LAN only |
| everything else | — | drop |

Never expose the Hub ports to the internet / a router port-forward. **Port `4000`
(Portainer) mounts the Docker socket** — treat it as the most sensitive and, if
you can, do not expose it beyond the host at all.

Bitcoin/Lightning/Tor internals (`8332`, `9050`, `9051`, `9735`, `9814`,
`50051`) are never published by Bastion; the rules below also block them
explicitly as a backstop.

Adjust three values for your network:
- **WAN interface** — the NIC facing your router/internet (e.g. `eth0`).
- **LAN subnet** — your trusted local network (e.g. `192.168.1.0/24`).
- **WireGuard subnet** — `INTERNAL_SUBNET` from `stack-network/docker-compose.yml`
  (default `10.13.13.0/24`).

## Option A — nftables (recommended)

Use the ready-made ruleset: [`firewall.example.nft`](firewall.example.nft). Edit
the three `define` lines at the top, then:

```bash
sudo cp docs/firewall.example.nft /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf        # syntax check only
sudo systemctl enable --now nftables
sudo nft list ruleset                    # verify
```

If Docker manages its own iptables/nft rules (the default), leave that alone —
the reference ruleset only governs the host `input` chain, which is where the
published ports land.

## Option B — ufw

```bash
WG_SUBNET=10.13.13.0/24
LAN_SUBNET=192.168.1.0/24

sudo ufw default deny incoming
sudo ufw default allow outgoing

# WireGuard entry point - open to the world
sudo ufw allow 51820/udp comment 'WireGuard'

# SSH - restrict (drop this block if you do not use SSH)
sudo ufw allow from "$WG_SUBNET" to any port 22 proto tcp comment 'SSH via WG'
sudo ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment 'SSH via LAN'

# Hub services - WireGuard + LAN only
for P in 80 3000 3001 3458 4000 4001 9090; do
  sudo ufw allow from "$WG_SUBNET"  to any port "$P" proto tcp comment 'Bastion Hub via WG'
  sudo ufw allow from "$LAN_SUBNET" to any port "$P" proto tcp comment 'Bastion Hub via LAN'
done

# Backstop: internal ports are never published, deny anyway
for P in 8332 9050 9051 9735 9814 50051; do
  sudo ufw deny "$P"/tcp comment 'Bastion internal - never expose'
done

sudo ufw enable
sudo ufw status verbose
```

> ufw note: with Docker's default iptables integration, published container ports
> can bypass ufw's `INPUT` rules because Docker inserts its own `DOCKER-USER`
> chain earlier. If `ufw status` looks right but a port is still reachable from
> outside, either add matching rules to the `DOCKER-USER` chain, set
> `"iptables": false` is **not** recommended, or prefer Option A (nftables), or
> use the well-known `ufw-docker` helper. Verify from an outside host with
> `nc -vz <public-ip> 4000` — it must fail.

## Verify

From a host that is **not** on WireGuard or the LAN (e.g. a phone on mobile
data, or an external VPS):

```bash
nc -vz <public-ip> 51820   # (udp - use `nc -vzu`) should succeed
nc -vz <public-ip> 3001    # should FAIL (timeout / refused)
nc -vz <public-ip> 4000    # should FAIL
```

From a WireGuard client: `curl -sI http://bastion.node:3001` should return
headers.
