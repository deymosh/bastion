# Bitcoin Stack

Bastion's sensitive financial-services stack. It contains Bitcoin Core, Core
Lightning, Tor, RTL, and TEOS. Treat changes to this directory as production
changes when the node holds funds.

## Services

| Service | Container address | Purpose |
|---|---|---|
| Bitcoin Core | `10.0.0.12:8332` | Pruned Bitcoin backend |
| Core Lightning | `10.0.0.10:9735` | Lightning node and CLN REST |
| Tor | `10.0.0.11:9050`, `:9051` | Proxy and control service |
| RTL | `10.0.0.13:3000` | Lightning UI |
| TEOS | `10.0.0.14` | Watchtower daemon |

Compose also publishes CLN REST on `127.0.0.1:3001` and `10.0.0.1:3001`,
Tor SOCKS on host port `9050`, Tor control on `127.0.0.1:9051`, and RTL on
host port `3000`. Review those bindings against your host firewall before
exposing the machine beyond a trusted network.

The stack joins the external `bastion-network` created by `stack-network`.
Lightning, Bitcoin Core, and TEOS share the configured Tor service internally.

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
- `data/cln/`, `data/bitcoin/`, `data/rtl/`, `data/teos/`, and `data/tor/` are persistent state.
- `rust-teos/` is the initialized TEOS source submodule used by `utils/build_teos.sh`.

Review logs before restarting a service. Lightning plugins such as CLBoss and
PeerSwap can affect funds and channel operations.
