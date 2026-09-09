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

### `integration/` — real containers, ~1-2 min, needs outbound network

| File | Covers |
|---|---|
| `tor.compose.yml` + `hidden-service-reachability.sh` | builds the real `Dockerfile.tor` with a torrc derived from the real one, on a hermetic project + isolated subnets; asserts from inside the tor container that the CLN/TEOS forward targets (`bastion-transit` addresses) are reachable and that a per-stack-subnet address, `0.0.0.0`, and Tor's own loopback are **not**. This is the regression guard for the class of bug where a service advertises an onion target Tor can't route to. |

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
- **A live CLN/TEOS node.** A `regtest` bitcoind + CLN(bcli) + tor compose would
  let the suite assert the real onion is created and its forward target matches
  the pinned IP, end to end. It is the highest-value addition still open; it
  belongs in `integration/` behind its own job because it needs ~2 min and
  reaches external block explorers only if `trustedcoin` is used (regtest+bcli
  avoids that). Scaffolding welcome.
- **`utils/tui.sh`** beyond `bash -n` + `shellcheck`. It is exercised by hand
  with a pty (tmux) driver; a recorded smoke test could be added but the TUI is
  a convenience layer with full CLI parity, so a break is low-severity.
- **`amboss-healthcheck.sh` / `node-audit.py` / `services/*`** — operator
  helpers, not wired into `./bastion`; lint-only.
