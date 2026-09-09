# Bitcoin Stack

Bastion's sensitive financial-services stack. It contains Bitcoin Core, Core
Lightning, Tor, RTL, and TEOS. Treat changes to this directory as production
changes when the node holds funds.

## Services

| Service | Container address | Purpose |
|---|---|---|
| Bitcoin Core | `10.20.0.3:8332` | Pruned Bitcoin backend |
| Core Lightning | `10.20.0.2:9735` | Lightning node and CLN REST |
| Tor | `tor:9050`, `tor:9051` | Shared transit proxy/control service |
| RTL | `10.20.0.4:3000` | Lightning UI |
| TEOS | `10.20.0.5` | Watchtower daemon |

Compose publishes CLN REST on host port `3001` so Zeus can reach it through
WireGuard. Restrict host firewall/Docker traffic to the WireGuard subnet and
never expose this port directly to the public Internet.
Tor SOCKS on host port `9050`, Tor control on `127.0.0.1:9051`, and RTL on
host port `3000`. Review those bindings against your host firewall before
exposing the machine beyond a trusted network.

The stack owns the private `bastion-bitcoin` subnet (`10.20.0.0/24`) and joins
the external `bastion-transit` network created by `stack-network`. Lightning,
Bitcoin Core, and TEOS reach Tor through that transit network. CLN and TEOS mount
the Tor state volume read-only so they can read the control cookie.

## Commands

```bash
# Build the custom Lightning image and start the stack through Bastion.
./bastion up

# Or start only this Compose project after the network exists.
docker compose -f ./stack-bitcoin/docker-compose.yml up -d
docker compose -f ./stack-bitcoin/docker-compose.yml ps
docker compose -f ./stack-bitcoin/docker-compose.yml logs -f lightningd
```

Use `docker compose stop` for a temporary stop. Do not use `down`, remove data
folders, or change wallet/plugin configuration without a backup and a recovery
plan.

## Configuration and state

- `config/cln_config` controls CLN plugins, REST, Tor, and automation.
- `config/RTL-Config.json` is a template copied to `data/rtl/` after initialization.
- `config/teos.toml` is a template copied to `data/teos/` after initialization.
- `data/cln/`, `data/bitcoin/`, `data/rtl/`, and `data/teos/` are persistent state.
- Tor runtime state is stored in the external Docker volume `bastion-tor-data`, owned by `stack-network`.

The Tor state volume is intentionally new during this migration. CLN and TEOS
state remain untouched; only Tor client cache/state is recreated.
- `rust-teos/` is the initialized TEOS source submodule used by `utils/build_teos.sh`.

Review logs before restarting a service. Lightning plugins such as CLBoss and
PeerSwap can affect funds and channel operations.
