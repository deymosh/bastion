# Bitcoin Stack

Bastion's sensitive financial-services stack. It contains Bitcoin Core, Core
Lightning, RTL, and TEOS. Treat changes to this directory as production changes
when the node holds funds.

## Services

| Service | `bastion-bitcoin` | `bastion-transit` | Purpose |
|---|---|---|---|
| Bitcoin Core | `10.20.0.3` | dynamic | Pruned Bitcoin backend (RPC `:8332`) |
| Core Lightning | `10.20.0.2` (REST `:3001`) | `10.254.0.10` (P2P `:9735`) | Lightning node |
| RTL | `10.20.0.4:3000` | — | Lightning UI |
| TEOS | `10.20.0.5` (bitcoind RPC) | `10.254.0.11` (API `:9814`) | Watchtower daemon |

Tor itself runs in `stack-network`; this stack reaches it over `bastion-transit`
at `tor:9050` (SOCKS) and `10.254.0.2:9051` (control). CLN and TEOS **publish**
their onion services through that Tor: each advertises its pinned
`bastion-transit` address (`10.254.0.10` / `10.254.0.11`) as the hidden-service
forward target, since the `tor` container can only route within
`bastion-transit`. `bind-addr` in `cln_config` and `api_bind` in `teos.toml`
must stay on those addresses.

Compose publishes CLN REST on host port `3001` so a CLN-REST client on the
WireGuard VPN can reach it at the host (raw LAN IP, or a Pi-hole local-DNS name
such as `http://bastion.node:3001`). RTL is on host port `3000`. Lock these
ports to the WireGuard interface/subnet in the host firewall; never expose them
to the public Internet.

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
plan. The full procedure - what is irreplaceable, how to back up, how to restore,
how to move to a new host, and why the `.onion` stays stable - is in
[../docs/disaster-recovery.md](../docs/disaster-recovery.md). Read it first.

## Watchtower (teosd) is opt-in

`teosd` runs **your own** watchtower - a service that watches *other* people's
channels (e.g. for tower swaps). It is **not** started by `./bastion up`. Enable
it with `./bastion up --with-watchtower` (or `BASTION_PROFILES=watchtower`); it
carries the `watchtower` compose profile. `stop` / `down` always tear it down so
it is never orphaned.

Unrelated: the CLN `watchtower-client` plugin (breach protection *for this node*,
pointed at an external tower URL) is always on and needs no local `teosd`.

## First-run seeding (idempotent)

On `./bastion up`, if they do not already exist:

- `config/RTL-Config.json` is copied to `data/rtl/RTL-Config.json`.
- `data/rtl/access.rune` is minted from CLN (`lightning-cli createrune`) and
  written as `LIGHTNING_RUNE="<rune>"`, mode `600` - RTL reads it via `runePath`.
  If CLN is not up yet this is skipped with a warning; re-run `./bastion up`.

Anything that already exists is left exactly as it is - an established install is
never touched.

## Configuration and state

- `config/cln_config` controls CLN plugins, REST, Tor, and automation.
- `config/RTL-Config.json` / `config/teos.toml` are templates; the live copies
  under `data/` are seeded once (see above) and then owned by the operator.
- `data/cln/`, `data/bitcoin/`, `data/rtl/`, and `data/teos/` are persistent state.
- Tor runtime state lives in the external Docker volume `bastion-tor-data`, owned
  by `stack-network`. It only holds Tor's client cache; CLN and TEOS keep their
  own state (including onion identities) under `data/`, so recreating the Tor
  volume is harmless.
- `rust-teos/` is the initialized TEOS source submodule used by `utils/build_teos.sh`.

Review logs before restarting a service. Lightning plugins such as CLBoss and
PeerSwap can affect funds and channel operations.

## Optional scripts

`scripts/` holds operator helpers that are **not** wired into `./bastion`:

- `amboss-healthcheck.sh` - signs a timestamp with CLN and posts a heartbeat to
  Amboss.space over Tor. Every step runs inside the `lightningd` container, so
  the host needs only Docker (no `jq`, no `curl`, no published Tor port). Opt-in;
  run it from cron (`*/5 * * * *`) or set `ENABLE_AMBOSS_HEARTBEAT=true` for
  `services/bastion-daemon.sh`. `TOR_PROXY` / `AMBOSS_URL` / `CLN_CONTAINER`
  override the defaults. Note: it ties the node's identity to Amboss.
- `node-audit.py` - routing profitability summary (also `./bastion audit`).
