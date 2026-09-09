# Bastion test suite

Bastion is mostly declarative — compose files, service configs, and shell
orchestration — with two pieces of real code (`utils/tui.sh`, the CCR token
refresher). The suite is built to catch the failure modes that actually bite:
cross-references that drift out of sync, shell that breaks on an edge case, and
network wiring that looks right but isn't routable.

## Running

```bash
./tests/run.sh              # static + unit  (no Docker daemon needed)
./tests/run.sh --all        # + integration (needs Docker + outbound network)
./tests/run.sh static       # one tier
```

Individual files are runnable directly (`bash tests/unit/config-sh.test.sh`).

## Tiers

### `static/` — no daemon, milliseconds

| File | Guards against |
|---|---|
| `shell-lint.sh` | `bash -n` + `shellcheck -S warning` on every tracked script |
| `yaml-lint.sh` | malformed compose / workflow YAML, CRLF, missing final newline |
| `compose-lint.sh` | `docker compose config` per stack — schema, interpolation, network/volume refs (needs the `docker` CLI, not a daemon) |
| `validate-config.sh` | the cross-references that hold the stacks together: the Tor transit IP is consistent across `torrc` / `cln_config` / `teos.toml`; no stale `10.0.0.x`; the CLN/TEOS onion forward targets are the pinned `bastion-transit` IPs and never `0.0.0.0`; per-stack subnets are unique and correct; `bastion-transit` is `external` everywhere except `stack-network`; `torrc` has an explicit `CookieAuthFile`; `Dockerfile.tor` pre-creates `/data/.tor` `0750`; `.gitmodules` pins `rust-teos` to `bastion-integration` |

### `unit/` — mocked deps, seconds

| File | Covers |
|---|---|
| `config-sh.test.sh` | `read_env_var`, `validate_env_value` (every branch), `config_var_is_secret`, `write_config` (idempotent, preserves a user's non-managed vars), and that every un-defaulted `${VAR}` in the compose files is in `MANAGED_VARS` |
| `bastion-cli.test.sh` | `./bastion` dispatch driven with a stubbed `docker` (`tests/lib/mock-bin.sh`): stack-name resolution (shorthand, reordering, unknown), `--recreate-networks` stripping, the stale-network preflight (blocks on `10.0.0.0/24`, passes on `10.10.0.0/24` / absent), usage/exit codes |
| `ccr-wrapper.test.sh` | `ccr-entrypoint-wrapper.sh` always `exec`s the upstream entrypoint (args passed through) whether or not a token exists; `CCR_TOKEN_REFRESH=0` only skips the helper |
| `ccr-refresher.test.mjs` | `node --test` for `ccr-token-refresher.mjs` against a mock token endpoint: `idle` on no/API-key file, no request when far from expiry, refresh + both-token rotation + key preservation on expiry, `invalid_grant` / 5xx leave the file intact |

### `integration/` — real containers, ~2-3 min

Hermetic: each test is its own Compose project on a private `10.25x.0.0/24`
subnet and cleans up with `down -v`. Needs Docker + compose + a Docker Hub pull.

| File | Covers |
|---|---|
| `tor.compose.yml` + `hidden-service-reachability.sh` | builds the real `Dockerfile.tor` with a torrc derived from the real one; asserts from inside the tor container that the CLN/TEOS forward targets (`bastion-transit` addresses) are reachable and that a per-stack-subnet address, `0.0.0.0`, and Tor's own loopback are **not**. Guards the class of bug where a service advertises an onion target Tor can't route to. |
| `cln-onion.compose.yml` + `cln-onion-target.sh` | boots a real Core Lightning (stock `elementsproject/lightningd` image — only `bcli` + the built-in `statictor` path are exercised, so no multi-minute custom build) against a throwaway **regtest** bitcoind and the real `Dockerfile.tor`. `cln_config.regtest`'s Tor block matches `stack-bitcoin/config/cln_config`. Asserts CLN parses the config and comes up, and that the static Tor service it registers **forwards to CLN's own pinned address, never `0.0.0.0`** — the exact regression. Fully offline (regtest); ~30-60s. |

## CI

`.github/workflows/ci.yml` runs `static` + `unit` + `integration` as independent
jobs on every push/PR to `master`, skipped for docs-only changes. Submodules are
not checked out — nothing in the suite needs `rust-teos`.

## Not covered here (deliberately)

- **Image builds** for `Dockerfile.lightningd` (builds five CLN plugins from
  source, ~15 min), `Dockerfile.ccr` (clones the fork, `npm ci` + build), and
  `rust-teos/docker/Dockerfile` (cargo musl build). These are slow and
  network-heavy; validate them with `./bastion build <stack>` before a release
  or wire a nightly `workflow_dispatch` job. `Dockerfile.tor` *is* built by the
  integration tier.
- **TEOS onion registration.** The CLN test proves the mechanism; a parallel
  `teosd` boot (against the same regtest bitcoind) asserting its onion forward
  target == `10.254.0.11` would close the loop. Small addition, same pattern as
  `cln-onion-target.sh`.
- **The prod chain-backend path.** `cln-onion-target.sh` runs on regtest+bcli
  for hermeticity. The production config is `network=bitcoin` + `trustedcoin`.
  `trustedcoin` starts instantly *only if no `bitcoin-rpc*` lines are present*
  (then it fetches the tip + recent blocks from block explorers over Tor -
  measured ~7s to `getinfo`, ~5 min to fully synced, and it is a hard external
  dependency). To smoke that path locally, drop the `bitcoin-rpc*` lines from a
  copy of `cln_config`, keep `network=bitcoin`, and boot CLN against the tor
  compose. It is deliberately **not** in CI - non-deterministic and network-
  bound. A nightly `workflow_dispatch` job is the place for it if wanted.
- **`utils/tui.sh`** beyond `bash -n` + `shellcheck`. It is exercised by hand
  with a pty (tmux) driver; a recorded smoke test could be added but the TUI is
  a convenience layer with full CLI parity, so a break is low-severity.
- **`amboss-healthcheck.sh` / `node-audit.py` / `services/*`** — operator
  helpers, not wired into `./bastion`; lint-only.
