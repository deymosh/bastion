<div align="center">

<img src="stack-web/html/favicon.svg" alt="Bastion" width="96" height="96">

# BASTION

### Sovereign Infrastructure, Operations &amp; AI

Self-hosted systems for private networking, Bitcoin and Lightning, observability,
and local AI workflows.

</div>

---

## What It Is

Bastion is a deliberate Docker environment for the services that matter:

- A guarded network edge with private DNS and WireGuard.
- Bitcoin, Core Lightning, Tor, TEOS, swaps, automation, and backups.
- Monitoring, administration, and a single operations Hub.
- An AI control plane built around Claude Code Router and CodeDeck+.

## ⚠️ Disclaimer

Lightning nodes handle real funds. Software is provided as-is. **Use only at your own risk.** See [CLN security docs](https://docs.corelightning.org/).

Before you run this with real funds, read **[docs/disaster-recovery.md](docs/disaster-recovery.md)** (what to back up, how to restore, how to move hosts) and set up the host firewall ([docs/firewall.md](docs/firewall.md)).

## 🚀 Quick Start

### Prerequisites
- Docker >= 24.0 & Docker Compose >= 2.0
- Linux (Debian/Ubuntu)
- 16GB+ RAM, 4+ CPU cores, 50GB+ storage

### Install
```bash
chmod +x bastion
./bastion up
```

**What happens:**
- Generates `bastion.conf` (auto-prompted for Wireguard URL, port, CLN alias)
- Creates `.env` symlinks → `bastion.conf` (one source of truth)
- Deploys: network → bitcoin → monitor → web → AI

For a single stack, use Docker Compose directly. The network stack must be running
before any other stack that uses Bastion's networks:

```bash
docker compose -f ./stack-network/docker-compose.yml up -d
docker compose -f ./stack-ai/docker-compose.yml up -d
```

## 📦 Bastion Stacks

| Stack | Services | IPs |
|-------|----------|-----|
| **network** | unbound DNS, WireGuard VPN, Pi-hole, Tor | 10.10.0.2-3 + transit |
| **bitcoin** | bitcoind, lightningd, RTL (TEOS opt-in) | 10.20.0.2-5 + transit |
| **monitor** | prometheus, grafana, portainer, node-exporter | 10.30.0.2-5 |
| **web** | Bastion operations hub | 10.40.0.2 |
| **ai** | Claude Code Router, CodeDeck+ bridge | 10.50.0.2-3 + transit |

The private stack networks use `10.10.0.0/24` through `10.50.0.0/24`.
Cross-stack services use the restricted `bastion-transit` network at
`10.254.0.0/24`. Pinned there: Tor `10.254.0.2`, Core Lightning `10.254.0.10`,
TEOS `10.254.0.11` — the last two publish their onion services through Tor and
must advertise a transit address the `tor` container can route to.

## ⚙️ Commands

Run `./bastion` with no arguments on a terminal for the interactive dashboard
(stack picker, live status, config editor, log viewer). For scripts and cron,
use the subcommands:

```bash
./bastion up       [stack ...]   # Start stacks in order (default: all)
./bastion stop     [stack ...]   # Stop services (reverse order)
./bastion down     [stack ...]   # Remove containers (reverse order)
./bastion build    [stack ...]   # Build images without starting
./bastion logs     [stack ...]   # Tail logs
./bastion status                 # Show containers and networks
./bastion audit                  # Check node profitability
./bastion tui                    # Force the dashboard
```

A stack name may be given with or without the `stack-` prefix
(`./bastion up web ai`). On `up`, `--recreate-networks` drops a stale
`bastion-network` left from the old flat-network layout before starting.
`--with-watchtower` (or `BASTION_PROFILES=watchtower`) also starts `teosd` -
your own watchtower - which is otherwise off. `./bastion versions` shows the
image pin vs. what is running.

On a fresh install `./bastion up` seeds `data/rtl/RTL-Config.json` and mints an
RTL access rune from CLN; both are created only if absent, so an existing
install is untouched. See `stack-bitcoin/README.md`.

`stack-network` is the foundation - it owns the `bastion-transit` network and
runs Tor, which the Bitcoin and AI stacks attach to. `./bastion up` always
brings it up first and adds it automatically when it is left out of the list.
For the same reason it will not `stop` or `down` `stack-network` while another
stack still has containers running; bring those down first, or pass `--force`.

Any non-interactive invocation (a pipe, cron, `services/bastion-daemon.sh`)
runs the plain path; the dashboard only opens on a real terminal.

## 🌐 Access

| Service | Port | Location | Version |
|---------|------|----------|---------|
| **Hub** (Bastion operations hub) | 80 | http://bastion.node | nginx 1.31.5-alpine |
| RTL (Lightning UI) | 3000 | http://bastion.node:3000 | v0.15.8 |
| Grafana | 4001 | http://bastion.node:4001 | 13.2.1 |
| Portainer | 4000 | https://bastion.node:4000 | 2.45.0 |
| Prometheus | 9090 | http://bastion.node:9090 | v3.14.0 |
| Pi-hole | 8081 | http://bastion.node:8081/admin | 2026.07.2 |
| CLN REST API | 3001 | http://bastion.node:3001 | (CLN native) |
| CCR management UI | 3458 | http://bastion.node:3458 | pinned fix commit |
| Wireguard VPN | 51820/udp | External (WAN) | 1.0.20260223-r0-ls121 |

Image versions are pinned by digest; `./bastion versions` shows the pin and what
is actually running. Bitcoin Core (`v26.0`) and the built images
(`lightningd-custom`, `teosd`, `tor-custom`, `bastion-claude-code-router`) are
not on this list — they carry no published UI.

### Access model & firewall

Every service above is published on `0.0.0.0` **by design**, so you can reach it
three ways:

- **over WireGuard** — the recommended path from outside the LAN;
- **from `localhost`** on the host itself;
- **from the trusted LAN** — e.g. a desktop on the same network.

Pi-hole holds a local-DNS record (`bastion.node → <host LAN IP>`) so the Hub and
every panel work by name from all three. The Hub itself links panels using
whatever hostname you are browsing with, so you never need to remember a port.

Because the ports are open on every interface, **the host firewall is the access
control** — this is not optional in production. [docs/firewall.md](docs/firewall.md)
gives a ready-to-use nftables ruleset and a `ufw` recipe that allow these ports
from the WireGuard subnet and the LAN and drop them everywhere else, in
particular from any WAN interface / router port-forward. Only `51820/udp`
(WireGuard) is meant to face the internet. Portainer (port `4000`) mounts the
Docker socket — firewall it the most tightly of all.

**Defaults (change immediately):**
- Grafana: `admin:admin`
- Pi-hole: `admin:${PIHOLE_PASSWORD}`
- Bitcoin RPC: `bitcoind.user:bitcoind.pass`
- CLN REST API: Access via `http://localhost:3001`

## 🛠️ Configuration

`./bastion` creates and maintains an organized `bastion.conf`:
- **Interactive prompts:** Wireguard URL/port, CLN node alias
- **Auto-generated:** TIMEZONE, PIHOLE_PASSWORD, USER_ID, GROUP_ID, CCR web token
- **AI settings:** CodeDeck relay, Tor proxy, Git, Claude, and GitHub variables
- **Idempotent:** managed variables are rewritten without duplicates on repeated runs
- **Symlinks:** Each stack references `../bastion.conf` via `.env` on Linux

On Windows, use a real `.env` file in each stack directory if symlinks are not
enabled. Keep credentials out of Git in every environment.

### Key Files

```
stack-bitcoin/docker-compose.yml    # Edit RPC user/pass, pruning settings
stack-bitcoin/config/cln_config     # CLN configuration (alias, plugins, proxy)
stack-network/docker-compose.yml    # Network, WireGuard, and Tor config
stack-web/html/index.html           # Hub landing page (edit to add/remove panels)
bastion.conf                        # GENERATED - in .gitignore
stack-*/.env                        # SYMLINKS - in .gitignore
stack-*/data/                       # Volumes - in .gitignore
stack-ai/docker-compose.yml        # CCR + CodeDeck+ integration
stack-ai/Dockerfile.ccr             # CCR pinned commit + Claude Code
```

### AI Stack

The AI stack builds Claude Code Router from a **pinned commit** of the project's
CCR fork (`CCR_REF` / `CCR_REPOSITORY` in `stack-ai/Dockerfile.ccr`; bump with
`gh api repos/deymosh/claude-code-router/commits/<branch> --jq .sha`), including
its Docker worker fix, and bakes in an OAuth token refresher so the login stays
valid without manual re-auth. CCR includes Claude Code and runs as root because
its upstream Docker entrypoint writes the Nginx configuration at startup.
CodeDeck+ uses its published bridge image (`ghcr.io/deymosh/codedeck-plus-bridge`),
runs as its own non-root user, and routes Claude Code requests through CCR at
`http://ccr:8080`.

AI state is persisted under `stack-ai/data/`. CCR authenticates with an
interactive `claude` login stored under `stack-ai/data/ccr/.claude/`; CodeDeck's
Claude OAuth token is a separate credential used by the bridge.

Before starting Bastion, add these values to the generated `bastion.conf`:

```bash
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-...
GITHUB_TOKEN=                 # optional
CODEDECK_RELAYS=wss://your-trusted-relay.example
```

CodeDeck relay connections use Bastion's existing Tor service at
`socks5h://tor:9050` by default. Pair the Android app by reading the bridge logs:

```bash
docker logs codedeck-bridge
```

### Bitcoin Core Defaults

```dockerfile
-rpcuser=bitcoind.user              # RPC user (change if desired)
-rpcpassword=bitcoind.pass          # RPC password (change if desired)
-prune=20000                        # ~20GB block storage (adjust as needed)
-txindex=0                          # Disabled (not needed for CLN)
-rpcallowip=10.20.0.0/24            # Allow RPC from the Bitcoin stack network
-rpcbind=0.0.0.0                    # Listen on all interfaces (container network)
```

**Note:** RPC credentials must match those in `stack-bitcoin/config/cln_config` and RTL config.

### Core Lightning Plugins

All plugins included and enabled by default:

| Plugin | Commit | Purpose |
|--------|--------|---------|
| **clboss** | [95d195f8](https://github.com/ksedgwic/clboss/tree/95d195f8baafa1aa22f7aa95fa1dd1fd26003583) | Channel autopilot & rebalancing |
| **watchtower-client** | [be344ecc](https://github.com/talaia-labs/rust-teos/tree/be344ecc5286dd9436bf343d30954135da8ad4ac) | TEOS breach watching |
| **peerswap** | [23b32d3a](https://github.com/ElementsProject/peerswap/tree/23b32d3a1b1665c7c5e50e76d530fff5bf8be3d8) | Submarine swap rebalancing |
| **backup** | [cb3adab](https://github.com/lightningd/plugins/tree/cb3adabfcb95e802ff27be85a53a353150a4907d) | Replication to USB/external |
| **trustedcoin** | [v0.8.6](https://github.com/nbd-wtf/trustedcoin/releases/tag/v0.8.6) | Fee and block validity estimator; verifies block data and channel existence |
| **darknet** | Local | Prefer .onion addresses for peers |

**CLN Configuration:**
```ini
# Autopilot settings (clboss)
--clboss-min-channel=1000000       # Minimum channel: 1M sats
--clboss-max-rebalance-fee-ppm=250 # Max rebalancing fee
--clboss-auto-close=false          # Don't auto-close channels

# Autoclean settings (remove failed payments & invoices)
autoclean-failedpays-age=604800    # Remove failed pays after 7 days
autoclean-failedforwards-age=604800 # Remove failed forwards after 7 days
autoclean-expiredinvoices-age=2592000 # Remove expired invoices after 30 days

# Wallet & backup
wallet=sqlite3:///root/.lightning/bitcoin/lightningd.sqlite3:/backup_usb/lightningd.sqlite3

# Network settings
proxy=10.254.0.2:9050              # Tor SOCKS proxy
addr=statictor:10.254.0.2:9051     # Tor control port
always-use-proxy=true              # Route all traffic through Tor
bind-addr=0.0.0.0:9735             # Listen on all interfaces
```

**Important Plugins:**
- `trustedcoin` - Critical for fee estimation and block validation (marked as `important-plugin`)
- `watchtower-client` - Critical for channel security (marked as `important-plugin`)
- `bcli` - Disabled in favor of trustedcoin

### TEOS Configuration

TEOS (`teosd`) is included but not configured by default. Running a watchtower on the same machine as your node is risky—if your node is compromised, so is the watchtower.

Configuration files are templates in `stack-bitcoin/config/teos.toml` but must be manually copied to the persistent data directory after first run:

```bash
# After first run of the stack, copy config to data directory
cp stack-bitcoin/config/teos.toml stack-bitcoin/data/teos/teos.toml
docker restart teosd
```

**Why manual copy?** The container mounts `stack-bitcoin/data/teos:/home/teos/.teos` for persistence. We can't simultaneously mount `config/` templates into the same directory, so templates must be copied after first initialization.

### RTL Configuration

RTL connects to CLN via the Bitcoin stack network (10.20.0.2:3001). Configuration template is in `stack-bitcoin/config/RTL-Config.json` but must be manually copied to the persistent data directory after first run:

```bash
# After first run of the stack, copy config to data directory
cp stack-bitcoin/config/RTL-Config.json stack-bitcoin/data/rtl/RTL-Config.json
docker restart rtl
```

**Why manual copy?** The container mounts `stack-bitcoin/data/rtl:/data` for persistence. We can't simultaneously mount `config/` templates into the same directory, so templates must be copied after first initialization. Any changes to CLN RPC credentials or ports require updating this file.

## 🔧 Troubleshooting
General troubleshooting steps for common issues. Always check container logs first (`docker logs <container>`).
The commands below assume you are in the project root and have the necessary permissions to run Docker commands. Adjust paths and container names as needed based on your specific setup.

```bash
# CLN backup plugin backup not initialized - ensure USB mount is correct and accessible
# Example command to initialize backup plugin with mounted USB path:
docker run --rm -it -v $(pwd)/stack-bitcoin/data/cln:~/.lightning/bitcoin -v /mnt/backup_cln:/backup_usb --entrypoint /usr/local/bin/backup/backup-cli lightningd-custom:latest init --lightning-dir ~/.lightning/bitcoin file:///backup_usb/backup.sqlite.bkp

# CLN backup plugin - restore from backup file
docker run --rm -it -v $(pwd)/stack-bitcoin/data/cln:~/.lightning/bitcoin -v /mnt/backup_cln:/backup_usb --entrypoint /usr/local/bin/backup/backup-cli lightningd-custom:latest restore file:///backup_usb/backup.sqlite.bkp --lightning-dir ~/.lightning/bitcoin

# CLN backup plugin - compact backup file
docker exec lightningd lightning-cli backup-compact

# CLN not connecting to Bitcoin
docker logs lightningd
docker exec lightningd ping -c 3 10.20.0.3

# RTL cannot reach CLN
docker logs rtl
docker exec lightningd lightning-cli getinfo

# DNS issues
docker exec unbound dig @127.0.0.1 google.com

# TOR connectivity (config restart to refresh circuits)
docker kill --signal=HUP tor
docker logs tor

# TOR connectivity (delete Tor state for fresh circuits)
docker stop tor
docker volume rm bastion-tor-data
docker start tor

# Container resource usage
docker stats
df -h
```

## 🔒 Security and Boundaries

Each stack has a private Docker subnet. Cross-stack dependencies use the restricted
`bastion-transit` network (`10.254.0.0/24`). External access is through:
- **Wireguard VPN** (51820/udp)
- **SSH** (port 22)
- **HTTP/HTTPS** web services (RTL, Grafana, etc)

**Internal isolation:**
- Bitcoin RPC: `10.20.0.3:8332` (Bitcoin stack network only)
- CLN REST: `10.20.0.2:3001` internally; host port `3001` for host/WireGuard clients
- CLN P2P / TEOS API: only on `bastion-transit` (`10.254.0.10:9735` /
  `10.254.0.11:9814`), reachable only through their Tor onion services
- CCR gateway: `ccr:8080` (AI stack network only; management UI is host/WireGuard published)
- CodeDeck bridge: no published host port; relay traffic uses `bastion-transit`

**Recommended:**
- Change default passwords (Grafana: admin:admin, Pi-hole, Bitcoin RPC)
- Keep `.gitignore` protected
- Use Wireguard for remote access
- CLN REST (`3001`) and the CCR UI (`3458`) are published on the host so VPN
  clients can reach them at the host LAN IP, or by a Pi-hole local-DNS name
  (e.g. `http://bastion.node:3001`). Lock those host ports to the WireGuard
  interface/subnet in the host firewall; never expose them to the Internet.

## 📊 Versions

| Component | Version |
|-----------|---------|
| Bitcoin Core | v26.0 |
| Core Lightning | v25.12.1 |
| RTL | v0.15.8 |
| Claude Code Router | `fix/log-body.worker.js` |
| CodeDeck+ bridge | v0.11.1 |
| **CLN Plugins:** |
| clboss | [95d195f8](https://github.com/ksedgwic/clboss/tree/95d195f8baafa1aa22f7aa95fa1dd1fd26003583) |
| watchtower-client | [be344ecc](https://github.com/talaia-labs/rust-teos/tree/be344ecc5286dd9436bf343d30954135da8ad4ac) |
| backup | [cb3adab](https://github.com/lightningd/plugins/tree/cb3adabfcb95e802ff27be85a53a353150a4907d) |
| trustedcoin | [v0.8.6](https://github.com/nbd-wtf/trustedcoin/releases/tag/v0.8.6) (disabled) |

## 📚 Resources

- **Bitcoin**: https://bitcoin.org
- **Core Lightning**: https://github.com/ElementsProject/lightning
- **Docker**: https://docs.docker.com
- **Block explorer**: https://mempool.space

---

**Software provided as-is.** Use at your own risk. Change defaults immediately. Never commit secrets.
