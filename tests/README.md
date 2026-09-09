# Bastion test suite

Bastion is mostly declarative — compose files, service configs, and shell
orchestration — with the logic concentrated in `bastion` + `utils/*.sh`
(stack/container dispatch, config + secret derivation, first-run seeding, the
TUI) and the CCR token refresher. Tests are built on three principles: **every
test earns its keep**
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
| `yaml-lint.sh` | malformed compose / workflow YAML, missing final newline (yamllint, relaxed) |
| `compose-lint.sh` | `docker compose config` per stack — schema, interpolation, network/volume refs (needs the `docker` CLI, not a daemon) |
| `validate-config.sh` | the cross-references that hold the stacks together (~40 checks): Tor transit IP consistent across `torrc` / `cln_config` / `teos.toml`; no stale `10.0.0.x`; the CLN/TEOS onion forward targets are the pinned `bastion-transit` IPs and never `0.0.0.0`; per-stack subnets unique and correct; `bastion-transit` is `external` everywhere except `stack-network`; `torrc` has an explicit `CookieAuthFile`; `Dockerfile.tor` pre-creates `/data/.tor` `0750`; `.gitmodules` pins `rust-teos` to `bastion-integration`. Plus the boundary-hardening invariants: every pulled image is `@sha256:`-pinned and off a rolling tag, `CCR_REF` is a 40-hex commit, `teosd` carries `profiles: [watchtower]` and `utils/config.sh` seeds its `teos.toml`, `CONTAINER_STACK` in `config.sh` matches the compose service list exactly, no secret var is interpolated as a plain env (each is wired to a `file:` / `_FILE` / wrapper), and `ccr` runs unprivileged (`cap_drop: ALL`, `no-new-privileges`, `PUID`, `gosu`) |

## `unit/` — mocked deps, seconds

| File | Covers |
|---|---|
| `config-sh.test.sh` | `read_env_var`, `validate_env_value` (every branch), `config_var_is_secret`, `write_config` (idempotent, preserves a user's non-managed vars), every un-defaulted `${VAR}` in the compose files is in `MANAGED_VARS`; `seed_runtime_config` / `seed_teos_config` (create-only, never overwrite an operator file); `ensure_rtl_rune` (flat + JSON parse, mode 600, non-fatal when CLN is down); `write_secret_files` (one 600 file per secret, verbatim value, rewrite-only-on-change, `SECRETS_DIR` follows `CONFIG_FILE`) |
| `bastion-cli.test.sh` | `./bastion` dispatch with a stubbed `docker` (`tests/lib/mock-bin.sh`): stack-name resolution (shorthand, reordering, unknown), `--recreate-networks` stripping, the stale-network preflight, config demanded only when a command boots containers, mandatory `stack-network` auto-add + teardown guard, `teosd` opt-in profile (`--with-watchtower` / `BASTION_PROFILES`), RTL rune + `teos.toml` seeding on `up`, per-container `restart`/`stop`/`start`/`logs`/`exec`/`shell` routing to the right compose project + the per-container network guard, `versions`, usage/exit codes |
| `tui.test.sh` | headless smoke of `utils/tui.sh`: every view (`main` / `stacks` / `config` / `logs` / `containers` / `container_actions`) builds without a runtime error, the Containers list is in compose order, back-navigation, the menu-scroll offset math, and the menu/status focus model |
| `ccr-wrapper.test.sh` | `ccr-entrypoint-wrapper.sh` always `exec`s the upstream entrypoint (args passed through) whether or not a token exists; `CCR_TOKEN_REFRESH=0` only skips the helper; `CCR_WEB_AUTH_TOKEN` read from `/run/secrets/ccr_web_auth_token` (file wins over env, never logged, env fallback when absent); as root it `chown`s the writable paths then `gosu`-drops to `PUID:PGID` before handing off |
| `ccr-refresher.test.mjs` | `node --test` for `ccr-token-refresher.mjs` against a mock endpoint: `idle` on no/API-key file, no request when far from expiry, refresh + both-token rotation + key preservation on expiry, a past `refreshTokenExpiresAt` short-circuits the POST, `invalid_grant` / 5xx leave the file intact |
| `amboss-healthcheck.test.sh` | `amboss-healthcheck.sh` with a stubbed `docker`: signs via `docker exec lightningd`, strips the `zbase=` prefix, builds valid JSON, POSTs to `api.amboss.space/graphql` through `--proxy socks5h://10.254.0.2:9050`, exits non-zero on a signing failure / an error response, honours `TOR_PROXY` |

## `integration/` — real containers, hermetic, ~2-3 min

Each test is its own throwaway Compose project on its own private subnet, with
`down -v` cleanup and no contact with a running Bastion. Needs Docker + compose +
a Docker Hub pull.

| File | Covers |
|---|---|
| `tor.compose.yml` + `hidden-service-reachability.sh` | builds the real `Dockerfile.tor` with a torrc derived from the real one; asserts from inside the tor container that the CLN/TEOS forward targets (transit addresses) are reachable and that a per-stack-subnet address, `0.0.0.0`, and Tor's own loopback are **not**. Guards the class of bug where a service advertises an onion target Tor can't route to. |
| `container-ops.sh` + `copstest/` | drives real `./bastion ps` / `exec` / `shell` / `logs` / `restart` / `stop` / `start` / unknown-name against an isolated one-service project (`bastion-copstest`, `10.199.0.0/24`) registered via the `BASTION_EXTRA_CONTAINER_STACK` test hook — proves the per-container verbs hit the right compose project without going near a production stack. |
| `secrets.sh` + `sectest/` | writes a random value to a `file:` secret, brings up a probe container (`bastion-sectest`, `10.198.0.0/24`), and asserts the value is readable at `/run/secrets/<name>` but absent from `docker inspect`'s `.Config.Env` and `/proc/1/environ` (with a normal env var as the positive control). Turns the Phase-5 "secret is a file, not an env var" claim from operator-verified into CI-verified. |

## `weekly/` — slow, non-blocking

| File | Covers |
|---|---|
| `build-images.sh` | plain `docker build` of `Dockerfile.tor`, `Dockerfile.lightningd` (five CLN plugins from source, ~15 min), `Dockerfile.ccr` (clones the fork), and `rust-teos/docker/Dockerfile`. No `--push`, no registry, no cache export — catches a Dockerfile that broke because a pinned base moved or a build dep vanished. |
| `cln.compose.yml` + `cln-real-config.sh` | boots the **real `lightningd-custom` image** with a config **mechanically derived** from `stack-bitcoin/config/cln_config` — the derivation only swaps the chain backend to a throwaway regtest bitcoind and remaps the transit octet; the Tor block (`proxy` / `addr=statictor` / `always-use-proxy` / `bind-addr`) passes through untouched, so a break in those real lines breaks the test. Asserts CLN parses the real config with the real image and comes up, and that the static Tor service forwards to CLN's own pinned address, never `0.0.0.0`. Offline (regtest), ~1-2 min. |

## Not covered (deliberately)

- **TEOS onion registration.** `cln-real-config.sh` proves the mechanism; a
  parallel `teosd` boot against the same regtest bitcoind, asserting its onion
  target == the pinned TEOS transit address, would close the loop. Same pattern.
- **The TUI beyond the headless smoke.** `tui.test.sh` drives the view/menu/focus
  model with no terminal; the actual rendering + key handling is exercised by
  hand with a pty (tmux) driver. The TUI has full CLI parity, so a render break
  is low-severity.
- **The prod chain-backend path.** `cln-real-config.sh` runs regtest+bcli. The
  production backend is `trustedcoin` on `network=bitcoin`: it talks to
  `bitcoind` through the `bitcoin-rpc*` lines in `cln_config` when that node is
  reachable, and falls back to public block explorers over Tor when it is not.
  Neither half is automated here — the `bitcoind` half needs a synced (pruned)
  chain, the explorer half is non-deterministic and network-bound. To smoke the
  explorer fallback by hand: drop the `bitcoin-rpc*` lines from a copy of
  `cln_config`, keep `network=bitcoin`, boot against
  `tests/integration/tor.compose.yml` (~7 s to `getinfo`, ~5 min to fully synced).
- **`node-audit.py` / `services/*`** — operator helpers, not wired into the
  per-push path of `./bastion`; lint-only. (`amboss-healthcheck.sh` is an
  operator helper too but now has `amboss-healthcheck.test.sh` in `unit/`.)
- **Full `./bastion up`** — the release-lane check: on a Linux host with a
  regtest bitcoind, `./bastion up`, then verify every panel loads, both onions
  are reachable end-to-end (rendezvous, not just the last hop), and the
  watchtower client registers with `teosd`.
