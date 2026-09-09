# Bastion test suite

Bastion is mostly declarative — compose files, service configs, and shell
orchestration — with two pieces of real code (`utils/tui.sh`, the CCR token
refresher). Tests are built on three principles: **every test earns its keep**
(catches a plausible regression not caught cheaper elsewhere); **the per-push
lane is fast and 100% deterministic** (a flaky blocking test trains people to
ignore red); and **we test what we own** — our config and wiring, not CLN's or
Docker's behaviour.

## Three lanes

| Lane | When | Blocks merge? | What |
|---|---|---|---|
| **per-push** | every push / PR (`ci.yml`) | yes | `static` + `unit` + `integration` — all hermetic, ~4 min |
| **weekly** | Mondays 04:00 UTC + on demand (`weekly.yml`) | no | image builds + a real-config CLN boot — slow, catches upstream drift |
| **release** | manual, before shipping | — | full `./bastion up` on a Linux host; see below |

Public-repo Actions minutes are unmetered; neither workflow uploads artifacts,
pushes images, or uses `actions/cache`, so account storage stays at zero.
GitHub auto-disables the weekly schedule after 60 days of repo inactivity.

## Running locally

```bash
./tests/run.sh              # static + unit  (no Docker daemon needed)
./tests/run.sh --all        # + integration (needs Docker)
./tests/run.sh weekly       # image builds + real-config CLN boot (~20-45 min)
./tests/run.sh static       # one tier
```

Individual files run directly (`bash tests/unit/config-sh.test.sh`).

## `static/` — no daemon, milliseconds

| File | Guards against |
|---|---|
| `shell-lint.sh` | `bash -n` + `shellcheck -S warning` on every tracked script |
| `yaml-lint.sh` | malformed compose / workflow YAML, CRLF, missing final newline |
| `compose-lint.sh` | `docker compose config` per stack — schema, interpolation, network/volume refs (needs the `docker` CLI, not a daemon) |
| `validate-config.sh` | the cross-references that hold the stacks together: Tor transit IP consistent across `torrc` / `cln_config` / `teos.toml`; no stale `10.0.0.x`; the CLN/TEOS onion forward targets are the pinned `bastion-transit` IPs and never `0.0.0.0`; per-stack subnets unique and correct; `bastion-transit` is `external` everywhere except `stack-network`; `torrc` has an explicit `CookieAuthFile`; `Dockerfile.tor` pre-creates `/data/.tor` `0750`; `.gitmodules` pins `rust-teos` to `bastion-integration` |

## `unit/` — mocked deps, seconds

| File | Covers |
|---|---|
| `config-sh.test.sh` | `read_env_var`, `validate_env_value` (every branch), `config_var_is_secret`, `write_config` (idempotent, preserves a user's non-managed vars), and that every un-defaulted `${VAR}` in the compose files is in `MANAGED_VARS` |
| `bastion-cli.test.sh` | `./bastion` dispatch with a stubbed `docker` (`tests/lib/mock-bin.sh`): stack-name resolution (shorthand, reordering, unknown), `--recreate-networks` stripping, the stale-network preflight (blocks on `10.0.0.0/24`, passes on `10.10.0.0/24` / absent), usage/exit codes |
| `ccr-wrapper.test.sh` | `ccr-entrypoint-wrapper.sh` always `exec`s the upstream entrypoint (args passed through) whether or not a token exists; `CCR_TOKEN_REFRESH=0` only skips the helper |
| `ccr-refresher.test.mjs` | `node --test` for `ccr-token-refresher.mjs` against a mock endpoint: `idle` on no/API-key file, no request when far from expiry, refresh + both-token rotation + key preservation on expiry, `invalid_grant` / 5xx leave the file intact |

## `integration/` — real containers, hermetic, ~2-3 min

Each test is its own Compose project on a private `10.25x.0.0/24` subnet;
`down -v` cleanup. Needs Docker + compose + a Docker Hub pull.

| File | Covers |
|---|---|
| `tor.compose.yml` + `hidden-service-reachability.sh` | builds the real `Dockerfile.tor` with a torrc derived from the real one; asserts from inside the tor container that the CLN/TEOS forward targets (transit addresses) are reachable and that a per-stack-subnet address, `0.0.0.0`, and Tor's own loopback are **not**. Guards the class of bug where a service advertises an onion target Tor can't route to. |

## `weekly/` — slow, non-blocking

| File | Covers |
|---|---|
| `build-images.sh` | plain `docker build` of `Dockerfile.tor`, `Dockerfile.lightningd` (five CLN plugins from source, ~15 min), `Dockerfile.ccr` (clones the fork), and `rust-teos/docker/Dockerfile`. No `--push`, no registry, no cache export — catches a Dockerfile that broke because a pinned base moved or a build dep vanished. |
| `cln.compose.yml` + `cln-real-config.sh` | boots the **real `lightningd-custom` image** with a config **mechanically derived** from `stack-bitcoin/config/cln_config` — the derivation only swaps the chain backend to a throwaway regtest bitcoind and remaps the transit octet; the Tor block (`proxy` / `addr=statictor` / `always-use-proxy` / `bind-addr`) passes through untouched, so a break in those real lines breaks the test. Asserts CLN parses the real config with the real image and comes up, and that the static Tor service forwards to CLN's own pinned address, never `0.0.0.0`. Offline (regtest), ~1-2 min. |

## Not covered (deliberately)

- **TEOS onion registration.** `cln-real-config.sh` proves the mechanism; a
  parallel `teosd` boot against the same regtest bitcoind, asserting its onion
  target == the pinned TEOS transit address, would close the loop. Same pattern.
- **The prod chain-backend path.** `cln-real-config.sh` runs regtest+bcli. The
  production backend is `trustedcoin` on `network=bitcoin` — it starts instantly
  only with no `bitcoin-rpc*` lines, then fetches the tip + recent blocks from
  block explorers over Tor (~7 s to `getinfo`, ~5 min to fully synced, a hard
  external dependency). Deliberately not automated: non-deterministic and
  network-bound. To smoke it by hand: drop `bitcoin-rpc*` from a copy of
  `cln_config`, keep `network=bitcoin`, boot against `tests/integration/tor.compose.yml`.
- **`utils/tui.sh`** beyond `bash -n` + `shellcheck` — exercised by hand with a
  pty (tmux) driver. The TUI has full CLI parity, so a break is low-severity.
- **`amboss-healthcheck.sh` / `node-audit.py` / `services/*`** — operator
  helpers, not wired into `./bastion`; lint-only.
- **Full `./bastion up`** — the release-lane check: on a Linux host with a
  regtest bitcoind, `./bastion up`, then verify every panel loads, both onions
  are reachable end-to-end (rendezvous, not just the last hop), and the
  watchtower client registers with `teosd`.
