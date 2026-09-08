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
before stacks that use `bastion-network`:

```bash
docker compose -f ./stack-network/docker-compose.yml up -d
docker compose -f ./stack-ai/docker-compose.yml up -d
```

## 📦 Bastion Stacks

| Stack | Services | IPs |
|-------|----------|-----|
| **network** | unbound DNS, WireGuard VPN, Pi-hole | 10.0.0.2-3 |
| **bitcoin** | bitcoind, lightningd, Tor, RTL, TEOS | 10.0.0.10-14 |
| **monitor** | prometheus, grafana, portainer, node-exporter | 10.0.0.20-23 |
| **web** | Bastion operations hub | 10.0.0.30 |
| **ai** | Claude Code Router, CodeDeck+ bridge | 10.0.0.40-41 |

## ⚙️ Commands

```bash
./bastion up       # Start all stacks
./bastion stop     # Stop services
./bastion down     # Remove containers
./bastion status   # Show containers
./bastion audit    # Check node profitability
./bastion logs     # Tail logs
```

Run one stack:

```bash
docker compose -f ./stack-<name>/docker-compose.yml up -d
```

## 🌐 Access

| Service | Port | Location | Version |
|---------|------|----------|---------|
| **Hub** (Bastion operations hub) | 80 | http://localhost | - |
| RTL (Lightning UI) | 3000 | http://localhost:3000 | v0.15.8 |
| Grafana | 4001 | http://localhost:4001 | latest |
| Portainer | 4000 | https://localhost:4000 | latest |
| Prometheus | 9090 | http://localhost:9090 | latest |
| Pi-hole | 8081 | http://localhost:8081/admin | latest |
| CLN REST API | 3001 | http://localhost:3001 | (CLN native) |
| Wireguard VPN | 51820/udp | External | latest |
| CCR management UI | 3458 | http://localhost:3458 | pinned fix branch |

The Hub links to the available panels above using whatever hostname you're currently browsing with (localhost, LAN IP, WireGuard IP, or a Tor address), so you don't need to remember each port. CCR is included in the Hub, remains protected by its own web authentication, and is host-local by design at `127.0.0.1:3458`.

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
stack-network/docker-compose.yml    # Wireguard server config
stack-web/html/index.html           # Hub landing page (edit to add/remove panels)
bastion.conf                        # GENERATED - in .gitignore
stack-*/.env                        # SYMLINKS - in .gitignore
stack-*/data/                       # Volumes - in .gitignore
stack-ai/docker-compose.yml        # CCR + CodeDeck+ integration
stack-ai/Dockerfile.ccr             # CCR fix branch plus Claude Code
```

### AI Stack

The AI stack builds Claude Code Router from the `fix/log-body.worker.js` branch of
`deymosh/claude-code-router`, including its Docker worker fix. CCR includes Claude
Code and runs as root because its upstream Docker entrypoint writes the Nginx
configuration at startup. CodeDeck+ uses the published
`ghcr.io/deymosh/codedeck-plus-bridge:v0.11.1` image, runs as its own non-root user,
and routes Claude Code requests through CCR at `http://ccr:8080`.

AI state is persisted under `stack-ai/data/`. CCR provider credentials are configured
in the CCR UI; CodeDeck's Claude OAuth token is a separate credential used by the
bridge.

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
-rpcallowip=10.0.0.0/24             # Allow RPC from container network
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
proxy=10.0.0.11:9050               # Tor SOCKS proxy
addr=statictor:10.0.0.11:9051      # Tor control port
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

RTL connects to CLN via Docker network (10.0.0.10:3001). Configuration template is in `stack-bitcoin/config/RTL-Config.json` but must be manually copied to the persistent data directory after first run:

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
docker exec lightningd ping -c 3 10.0.0.12

# RTL cannot reach CLN
docker logs rtl
docker exec lightningd lightning-cli getinfo

# DNS issues
docker exec unbound dig @127.0.0.1 google.com

# TOR connectivity (config restart to refresh circuits)
docker kill --signal=HUP tor
docker logs tor

# TOR connectivity (delete tor state and cache for fresh start)
docker stop tor
rm -f stack-bitcoin/data/tor/state stack-bitcoin/data/tor/cached-* stack-bitcoin/data/tor/microdesc-*
docker start tor

# Container resource usage
docker stats
df -h
```

## 🔒 Security and Boundaries

All containers are isolated on Docker network `10.0.0.0/24`. External access only via:
- **Wireguard VPN** (51820/udp)
- **SSH** (port 22)
- **HTTP/HTTPS** web services (RTL, Grafana, etc)

**Internal isolation:**
- Bitcoin RPC: `10.0.0.12:8332` (Docker network only)
- CLN REST: `10.0.0.10:3001` (Docker network only)
- CCR gateway: `ccr:8080` (Docker network only; management UI is localhost-published)
- CodeDeck bridge: no published host port; relay traffic uses the shared Docker network

**Recommended:**
- Change default passwords (Grafana: admin:admin, Pi-hole, Bitcoin RPC)
- Keep `.gitignore` protected
- Use Wireguard for remote access

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
