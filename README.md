# 🏴‍☠️ BASTION - Bitcoin & Lightning Infrastructure

Complete Docker infrastructure for running a Bitcoin node with Core Lightning, private DNS, VPN, and monitoring.

## ⚠️ Disclaimer

Lightning nodes handle real funds. Software is provided as-is. **Use only at your own risk.** See [CLN security docs](https://docs.corelightning.org/).

## 🚀 Quick Start

### Prerequisites
- Docker >= 24.0 & Docker Compose >= 2.0
- Linux (Debian/Ubuntu)
- 16GB+ RAM, 4+ CPU cores, 50GB+ storage

### Install
```bash
chmod +x manage.sh
./manage.sh up
```

**What happens:**
- Generates `bastion.conf` (auto-prompted for Wireguard URL, port, CLN alias)
- Creates `.env` symlinks → `bastion.conf` (one source of truth)
- Deploys: network → bitcoin → monitor

## 📦 Stacks

| Stack | Services | IPs |
|-------|----------|-----|
| **network** | unbound DNS, wireguard VPN, pi-hole | 10.0.0.2-3 |
| **bitcoin** | bitcoind, clightning, tor, rtl, teosd | 10.0.0.10-14 |
| **monitor** | prometheus, grafana, portainer, node-exporter | 10.0.0.20-23 |

## ⚙️ Commands

```bash
./manage.sh up       # Start all stacks
./manage.sh stop     # Stop services
./manage.sh down     # Remove containers
./manage.sh status   # Show containers
./manage.sh logs     # Tail logs
```

## 🌐 Access

| Service | Port | Location |
|---------|------|----------|
| RTL (Lightning UI) | 3000 | http://localhost:3000 |
| Grafana | 4001 | http://localhost:4001 |
| Portainer | 4000 | https://localhost:4000 |
| Prometheus | 9090 | http://localhost:9090 |
| Pi-hole | 80 | http://localhost/admin |
| Wireguard VPN | 51820/udp | External |

**Defaults (change immediately):**
- Grafana: `admin:admin`
- Pi-hole: `admin:${PIHOLE_PASSWORD}`
- Bitcoin RPC: `bitcoind.user:bitcoind.pass`

## 🛠️ Configuration

`manage.sh` auto-generates `bastion.conf` on first run:
- **Interactive prompts:** Wireguard URL/port, CLN node alias
- **Auto-generated:** TIMEZONE, PIHOLE_PASSWORD, USER_ID, GROUP_ID
- **Symlinks:** Each stack references `../bastion.conf` via `.env`

### Key Files

```
stack-bitcoin/docker-compose.yml    # Edit RPC user/pass, pruning settings
stack-bitcoin/config/cln_config     # CLN configuration (alias, plugins, proxy)
stack-network/docker-compose.yml    # Wireguard server config
bastion.conf                        # GENERATED - in .gitignore
stack-*/.env                        # SYMLINKS - in .gitignore
stack-*/data/                       # Volumes - in .gitignore
```

### Bitcoin Core Defaults

```dockerfile
-rpcuser=bitcoind.user              # Change if desired, but update in CLN and RTL configs
-rpcpassword=bitcoind.pass          # Change if desired, but update in CLN and RTL configs
-prune=20000                        # ~20GB block storage
```

### Core Lightning Plugins

All plugins included and enabled by default (except trustedcoin, disabled since we use bitcoind):

- **clboss** - Channel autopilot ([b827b258](https://github.com/ksedgwic/clboss/commit/b827b258a2607ec39985d46307d8c430e8e1caf4))
- **watchtower-client** - TEOS breach watching ([be344ecc](https://github.com/talaia-labs/rust-teos/commit/be344ecc5286dd9436bf343d30954135da8ad4ac))
- **backup** - Expects USB mount at `/mnt/backup_cln` ([cb3adab](https://github.com/lightningd/plugins/commit/cb3adabfcb95e802ff27be85a53a353150a4907d))
- **trustedcoin** - [v0.8.6](https://github.com/nbd-wtf/trustedcoin/releases/tag/v0.8.6) (disabled - we have bitcoind)

Tor always enabled: routes through 10.0.0.11:9050

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

```bash
# CLN backup plugin backup not initialized - ensure USB mount is correct and accessible
# Example command to initialize backup plugin with mounted USB path:
docker run --rm -it -v $(pwd)/data/cln:/root/.lightning/bitcoin -v /mnt/backup_cln:/backup_usb --entrypoint /usr/local/bin/backup/backup-cli clightning-custom:latest init --lightning-dir /root/.lightning/bitcoin file:///backup_usb/backup.sqlite.bkp

# CLN not connecting to Bitcoin
docker logs clightning
docker exec clightning ping -c 3 10.0.0.12

# RTL cannot reach CLN
docker logs rtl
docker exec clightning lightning-cli getinfo

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

## 🔒 Security

All containers are isolated on Docker network `10.0.0.0/24`. External access only via:
- **Wireguard VPN** (51820/udp)
- **SSH** (port 22)
- **HTTP/HTTPS** web services (RTL, Grafana, etc)

**Internal isolation:**
- Bitcoin RPC: `10.0.0.12:8332` (Docker network only)
- CLN REST: `10.0.0.10:3001` (Docker network only)

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
| **CLN Plugins:** |
| clboss | [b827b258](https://github.com/ksedgwic/clboss/commit/b827b258a2607ec39985d46307d8c430e8e1caf4) |
| watchtower-client | [be344ecc](https://github.com/talaia-labs/rust-teos/commit/be344ecc5286dd9436bf343d30954135da8ad4ac) |
| backup | [cb3adab](https://github.com/lightningd/plugins/commit/cb3adabfcb95e802ff27be85a53a353150a4907d) |
| trustedcoin | [v0.8.6](https://github.com/nbd-wtf/trustedcoin/releases/tag/v0.8.6) (disabled) |

## 📚 Resources

- **Bitcoin**: https://bitcoin.org
- **Core Lightning**: https://github.com/ElementsProject/lightning
- **Docker**: https://docs.docker.com
- **Block explorer**: https://mempool.space

---

**Software provided as-is.** Use at your own risk. Change defaults immediately. Never commit secrets.
