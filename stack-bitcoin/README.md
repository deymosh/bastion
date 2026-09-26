# Bitcoin stack

The stack that holds funds: a pruned Bitcoin Core, Core Lightning with its
plugins, RTL, and an optional watchtower. Treat every change here as a
production change once the node is funded, and read
[disaster recovery](../docs/disaster-recovery.md) first.

## Services

| Service | `bastion-bitcoin` | `bastion-transit` | Host port | Purpose |
|---|---|---|---|---|
| `lightningd` | `10.20.0.2` (REST `:3001`) | `10.254.0.10` (P2P `:9735`) | `3001` | Core Lightning (custom image) |
| `bitcoind` | `10.20.0.3` (RPC `:8332`) | dynamic | — | Pruned Bitcoin Core, P2P over Tor, no inbound |
| `rtl` | `10.20.0.4` | — | `3000` | Lightning web UI |
| `teosd` *(opt-in)* | `10.20.0.5` | `10.254.0.11` (API `:9814`) | — | Your own watchtower (rust-teos) |

**Tor.** Tor runs in `stack-network`. This stack reaches it over transit at
`10.254.0.2:9050` (SOCKS) and `:9051` (control), and mounts the
`bastion-tor-data` volume read-only for the control cookie. CLN and `teosd`
publish their onion services through that Tor. Each one advertises its **pinned
transit address** as the hidden-service forward target, because the `tor`
container can only route within `bastion-transit`. For that reason `bind-addr`
in `config/cln_config` and `api_bind` in `config/teos.toml` must stay on
`10.254.0.10` and `10.254.0.11`, and must never be `0.0.0.0`.

**The `.onion` is stable.** `addr=statictor:` derives the onion key from
`hsm_secret`, so rebuilding the containers, wiping the Tor volume or moving
hosts all keep the same address.

## Core Lightning

`Dockerfile.lightningd` builds the plugin set on top of a digest-pinned
`elementsproject/lightningd` image: clboss, peerswap and xrebalance compile
from pinned commits, watchtower-client from upstream `rust-teos` at a pinned commit,
and trustedcoin is a prebuilt binary verified by its release checksum.
`config/cln_config` enables them:

| Plugin | Role |
|---|---|
| `trustedcoin` | **Chain backend** (`important-plugin`) in place of the disabled built-in `bcli`. It uses `bitcoind` through the `bitcoin-rpc*` lines when that node is reachable and has the block, and otherwise falls back to public block explorers over Tor. |
| `watchtower-client` | Breach protection for *this* node against an external tower (`important-plugin`) |
| `clboss` | Channel autopilot (v0.17.x, requires CLN ≥ v25.09). **It opens channels and moves funds.** Tuned via `command:` in the compose file (min channel 1M sat, no auto-close). Since v0.17 rebalancing runs through `xrebalance` |
| `xrebalance` | clboss's rebalancing executor, a separate plugin since clboss v0.17 (without it clboss runs but never rebalances) |
| `peerswap` | Submarine-swap rebalancing, **Bitcoin swaps only** (`config/peerswap.conf`, mounted read-only; state in `data/cln/peerswap/`). Protocol v7: swaps only work between peers running the same protocol version |
| `darknet.py` | Local plugin that prefers peers' `.onion` addresses |

Other settings in `cln_config`:

- **Wallet replication.** `wallet=sqlite3://…:/backup_usb/lightningd.sqlite3`
  makes CLN write every database transaction to the backup drive as well as
  its own, in one commit — the replica is never stale. The drive is
  `BACKUP_DEST` on the host (default `/mnt/backup_cln`); mount it before `up`.
  This native replication is the only backup mechanism; the old `backup`
  plugin is not shipped.
- **Autoclean.** Failed payments and forwards are removed after 7 days, expired
  invoices after 30 days.
- **REST.** `clnrest` listens on `:3001` over plain HTTP. Only reach it over
  WireGuard or the LAN.
- **Tor only.** `always-use-proxy=true`, so no clearnet connections.

## Watchtower (`teosd`) is opt-in

`teosd` runs **your own** tower, which watches *other* nodes' channels (for
example for tower swaps). It carries the `watchtower` compose profile and is off
by default:

```bash
./bastion config set ENABLED_PROFILES watchtower   # every up, boot included
./bastion up --with-watchtower                     # or: this run only
```

`./bastion` builds the `teosd:latest` image from the [`rust-teos`](../rust-teos)
submodule (repo root) through `utils/build_teos.sh`. It rebuilds whenever the
submodule commit changes. `stop` and `down` always include `teosd`, so it is
never orphaned. The `watchtower-client` plugin above is unrelated to `teosd`
and always on.

## First-run seeding

When an `up` includes this stack, `./bastion` creates the following files,
**but only if they are missing**. An existing file is never touched.

| File | From |
|---|---|
| `data/rtl/RTL-Config.json` | `config/RTL-Config.json` |
| `data/rtl/access.rune` | minted with `lightning-cli createrune`, mode `600`. If CLN is not ready yet this step is skipped with a warning, so run `up` again |
| `data/teos/teos.toml` *(watchtower only)* | `config/teos.toml`. Without it rust-teos falls back to `127.0.0.1`, runs without Tor, and is unreachable |

After seeding, the files under `data/` belong to the operator. Edit the live
copies, not the templates.

## Operations

```bash
./bastion up bitcoin                                 # stack-network comes up first
./bastion logs lightningd
./bastion exec lightningd -- lightning-cli getinfo
./bastion audit                                      # routing profitability (scripts/node-audit.py)
```

- **Stopping.** `./bastion stop bitcoin` shuts both nodes down cleanly.
  `lightningd` runs `lightning-cli stop` from its entrypoint
  (`lightningd-entrypoint.sh`) and has up to 3 minutes; `bitcoind` has 5.
  Never `docker kill` either of them.
- **Health.** `./bastion ps` shows `lightningd` as healthy once its RPC
  answers. After a restart that takes until the chain catch-up finishes,
  which can be several minutes.
- **Bitcoin RPC credentials** are `bitcoind.user` / `bitcoind.pass`, set in the
  compose `command:` and healthcheck and in `cln_config`. RPC only listens on
  the stack network (`rpcallowip=10.20.0.0/24`). If you change them, change all
  three places together.

### Optional helpers (`scripts/`)

- `amboss-healthcheck.sh` signs a timestamp with CLN and posts a heartbeat to
  Amboss over Tor. Every step runs inside `lightningd`. Enable it through the
  daemon with `./bastion config set AMBOSS_HEARTBEAT 1`. Note that this links
  the node's identity to Amboss.
- `node-audit.py` is the report behind `./bastion audit`.

### Troubleshooting

| Symptom | Check |
|---|---|
| CLN not syncing | `./bastion logs lightningd`, then look for `trustedcoin` lines; `./bastion ps` should show `tor` as healthy |
| RTL cannot reach CLN | `./bastion exec lightningd -- lightning-cli getinfo`, then check `data/rtl/access.rune` exists |
| No `.onion` in `getinfo` | `./bastion logs tor`; the `bastion-tor-data` cookie must be readable (see `stack-network`) |
