# 🏴‍☠️ BASTION - Bitcoin & Lightning Infrastructure

Complete Docker infrastructure for running a full Bitcoin node with Lightning Network (CLN), private DNS, VPN access, and monitoring.

## Quick Start

### Prerequisites
- Docker >= 24.0 & Docker Compose >= 2.0
- Linux (Debian/Ubuntu)
- 16GB+ RAM, 4+ CPU cores, 50GB storage

### Installation
```bash
# Make script executable
chmod +x manage.sh

# Deploy all stacks
./manage.sh up
```

## Stacks Overview

| Stack | Services | Purpose |
|-------|----------|---------|
| **bitcoin** | bitcoind, clightning, tor, rtl | Bitcoin node + Lightning Network |
| **network** | pihole, unbound, wireguard | DNS blocking, private DNS, VPN |
| **monitor** | prometheus, grafana, portainer, node-exporter | Metrics & visualization |

## Commands

```bash
./manage.sh up       # Start all stacks in order
./manage.sh stop     # Stop all services
./manage.sh status   # Show container status
./manage.sh logs     # Follow logs
```

## Service Ports

| Service | Port | URL |
|---------|------|-----|
| RTL (Lightning) | 3000 | http://localhost:3000 |
| Grafana | 4001 | http://localhost:4001 |
| Portainer | 4000 | https://localhost:4000 |
| Prometheus | 9090 | http://localhost:9090 |
| Pi-hole | 80 | http://localhost/admin |

**Default credentials:**
- Grafana: `admin` / `admin` (change immediately)
- Pi-hole: `admin` / `pihole` (change immediately)

## Bitcoin & Lightning Commands

```bash
# Bitcoin info
docker exec bitcoind bitcoin-cli -rpcuser=USER -rpcpassword=PASS getblockchaininfo

# Lightning info
docker exec clightning lightning-cli getinfo
docker exec clightning lightning-cli listchannels
docker exec clightning lightning-cli listpeers

# Balance & profits
docker exec clightning lightning-cli bkpr-getbalances

# Watchtower status
docker exec clightning lightning-cli watchtower-client-stats
```

## Configuration

**Bitcoin RPC** (`stack-bitcoin/docker-compose.yml`)
```
User: blockchainuser (change this)
Password: secure_password_here (change this)
Port: 8332
```

**CLN Config** (`stack-bitcoin/config/cln_config`)
```properties
alias=BastionCLN
network=bitcoin
bitcoin-rpcuser=blockchainuser
bitcoin-rpcpassword=secure_password_here
clnrest-port=3001
always-use-proxy=true  # Routes through Tor
```

**Wireguard** (`stack-network/docker-compose.yml`)
```
SERVERURL=your-domain.hopto.org  # Change this
SERVERPORT=51820  # Change this
```

## Backup & Recovery

```bash
# Backup CLN (critical data)
mkdir -p ~/backups
docker compose -f stack-bitcoin/docker-compose.yml stop clightning
tar -czf ~/backups/cln_backup_$(date +%Y%m%d_%H%M%S).tar.gz stack-bitcoin/data/cln/
docker compose -f stack-bitcoin/docker-compose.yml start clightning

# Restore
./manage.sh stop
rm -rf stack-bitcoin/data/cln/
tar -xzf ~/backups/cln_backup_YYYYMMDD_HHMMSS.tar.gz -C stack-bitcoin/data/
./manage.sh up
```

## Watchtower Registration

```bash
docker exec clightning lightning-cli registertower <pubkey>@<host>:<port>
```

## Troubleshooting

**Network not found:**
```bash
docker network create --driver bridge --subnet 10.0.0.0/24 bastion-network
```

**Bitcoin/CLN not syncing:**
```bash
docker logs -f bitcoind  # Check sync progress
docker exec bitcoind bitcoin-cli -rpcuser=USER -rpcpassword=PASS getblockcount
```

**RTL cannot connect to CLN:**
```bash
docker ps | grep clightning  # Verify running
docker exec clightning lightning-cli getinfo  # Test RPC
docker logs rtl  # Check RTL logs
```

**DNS issues (Pi-hole/Unbound):**
```bash
docker exec unbound nslookup google.com localhost
dig @127.0.0.1 +short google.com
docker logs -f pihole
```

**Port conflicts:**
```bash
sudo netstat -tlnp | grep <port>
# Change port in docker-compose.yml and restart
```

## Security Best Practices

1. **Change all default passwords immediately:**
   - RPC Bitcoin password
   - Pi-hole web password
   - Grafana admin password

2. **Firewall (UFW):**
```bash
sudo ufw allow 22/tcp      # SSH only
sudo ufw allow 3000/tcp    # RTL (if exposing)
sudo ufw allow 51820/udp   # Wireguard
sudo ufw allow 53/tcp 53/udp  # DNS
sudo ufw enable
```

3. **Never expose RPC ports to internet** - use Wireguard VPN instead

4. **Regular backups** of CLN data (critical!)

5. **Keep Bitcoin Core updated** for security patches

## Logs & Diagnostics

```bash
# View all logs
./manage.sh logs

# Individual service logs
docker logs -f bitcoind
docker logs -f clightning
docker logs -f rtl
docker logs -f pihole

# System info
df -h          # Disk usage
free -h        # Memory usage
docker stats   # Container stats
docker events  # Docker events
```

## Project Structure

```
bastion/
├── README.md                    # This file
├── manage.sh                    # CLI management script
├── stack-bitcoin/
│   ├── docker-compose.yml
│   ├── Dockerfile.clightning    # Custom CLN with plugins
│   ├── config/
│   │   ├── cln_config
│   │   ├── torrc
│   │   └── RTL-Config.json
│   └── data/                    # Persistent volumes
│       ├── bitcoin/             # Blockchain
│       ├── cln/                 # Lightning data
│       ├── rtl/                 # RTL data
│       └── tor/                 # Tor data
├── stack-network/
│   ├── docker-compose.yml
│   ├── unbound.conf
│   └── data/
│       ├── etc-pihole/
│       ├── etc-dnsmasq.d/
│       └── wireguard/
└── stack-monitor/
    ├── docker-compose.yml
    └── prometheus.yml
```

## Updates

```bash
# Pull latest images
docker pull elementsproject/lightningd:v25.12.1
docker pull lncm/bitcoind:v26.0

# Restart
./manage.sh stop
./manage.sh up
```

## Software Versions

- **Bitcoin Core**: v26.0
- **Core Lightning**: v25.12.1
- **RTL**: v0.15.8
- **Plugins**: clboss, backup, watchtower-client
- **Network**: Pi-hole, Unbound, Wireguard
- **Monitoring**: Prometheus, Grafana, Portainer

## Support

- Bitcoin: https://bitcoin.org/
- Core Lightning: https://github.com/ElementsProject/lightning
- Docker: https://docs.docker.com/

---

**Last Updated**: February 2026
**Version**: 1.0.0
