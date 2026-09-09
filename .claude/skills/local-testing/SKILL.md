---
name: local-testing
description: Use when verifying a Bastion change locally — which stacks/containers a given change actually needs, how to bring up Core Lightning without bitcoind (trustedcoin's block-explorer fallback path), what cannot be tested on Docker Desktop for Windows, and the CLN gossip_store named-volume workaround. Read before running ./bastion up or docker compose up for verification.
---

# Testing Bastion changes locally

## Core principle

Never run the whole stack to check one thing, and **never start `bitcoind`** (it
begins a full-chain sync). Bring up the minimum subset that exercises the change.
`stack-network` (specifically `tor`) is the only common prerequisite, because
almost everything Tor-adjacent needs `10.254.0.2:9050/9051` reachable.

## When to use this skill

- Before any `./bastion up` / `docker compose up` done for verification.
- A change touches CLN, Tor, TEOS, the network topology, CCR, or the hub.
- CLN won't start with a `gossip_store` corruption error on Windows.

## 1. What each change needs

| Change area | Minimum to bring up | Notes |
|---|---|---|
| Hub / `stack-web` | `docker compose -f stack-web/docker-compose.yml up -d` | fully standalone; or just open `stack-web/html/index.html` in a browser |
| `stack-monitor` | that stack alone | self-contained, no Tor |
| Tor / `torrc` / `Dockerfile.tor` | `stack-network` `tor` service only | `docker compose -f stack-network/docker-compose.yml up -d tor` |
| CLN config / `cln_config` / CLN compose | `tor`, then `lightningd` (NO bitcoind) | trustedcoin path, see §2 |
| TEOS / `teos.toml` / `rust-teos` | `tor`, `lightningd`, rebuilt `teosd` | `teosd` carries the `watchtower` profile — `./bastion build --with-watchtower stack-bitcoin` (or `utils/build_teos.sh force`) to build, `./bastion up --with-watchtower ...` to start it |
| CCR / `stack-ai` | `stack-ai` alone (+ `tor` if testing relay/bridge egress) | `/health` on `:3458` |
| `bastion` script / `utils/*.sh` | nothing — run it, check output + `bastion.conf` | use a non-TTY invocation to test the plain path |

## 2. Core Lightning without bitcoind

CLN's `stack-bitcoin/config/cln_config` has `disable-plugin=bcli` and
`important-plugin=/usr/local/bin/trustedcoin`. `trustedcoin` prefers `bitcoind`
(via the `bitcoin-rpc*` lines in the same file) when it is up, and falls back to
public block explorers **over the configured Tor proxy** when it is not — so with
no `bitcoind` running, CLN still reaches "synced to chain" on the explorer path
alone. (In production `bitcoind` is up, so the explorer path is only a backstop.)

Procedure:

1. `docker compose -f stack-network/docker-compose.yml up -d tor` and wait for
   `docker inspect --format '{{.State.Health.Status}}' tor` = `healthy`.
2. `docker compose -f stack-bitcoin/docker-compose.yml up -d lightningd` — this
   starts *only* `lightningd` (it has no `depends_on`), with a throwaway data
   directory (see §3 for the volume). If you ever add a `depends_on: bitcoind`,
   pass `--no-deps` or you will start a full-chain sync.
3. Expect: container joins `bastion-bitcoin` + `bastion-transit`; connects to the
   Tor control port at `10.254.0.2:9051`; `trustedcoin` begins syncing headers.
4. `docker exec lightningd lightning-cli getinfo` → returns; `getinfo` shows the
   node id and a `.onion` address once the hidden service is up.

The public `.onion` is derived from the HSM secret in the CLN data dir, not from
Tor's `DataDirectory`, so wiping `bastion-tor-data` does not change it.

## 3. The CLN gossip_store workaround (Windows)

On Docker Desktop for Windows, bind-mounting the CLN data dir
(`./data/cln:/root/.lightning/bitcoin`) can leave `gossip_store` un-initialised
or flagged corrupt on startup. A **named Docker volume** for
`/root/.lightning/bitcoin` does not have this problem.

For local Windows testing: swap the bind mount for a named volume in a local
override (`docker-compose.override.yml`, git-ignored) — do **not** change the
committed compose file; the Linux target keeps the bind mount.

```yaml
# stack-bitcoin/docker-compose.override.yml  (local only, git-ignored)
services:
  lightningd:
    volumes:
      - cln-test-data:/root/.lightning/bitcoin
volumes:
  cln-test-data:
```

A known alternative (not required, and not the objective of any task): opening
`gossip_store` for read+write once — a trivial Python
`open(path, "r+b"); f.read(1); f.seek(0); f.write(...)` — has been observed to
clear the "corrupted" state so the bind-mounted node then starts. Prefer the
named volume.

## 4. What cannot be tested on Docker Desktop for Windows

- **Pi-hole** — `network_mode: host` behaves differently / not at all.
- **WireGuard** — needs the `/lib/modules` mount and kernel WireGuard.
- Anything asserting real host-port firewall behaviour.

Verify those on the Linux target. A full `./bastion up` is Linux-target-only and
is the final acceptance gate — call that out explicitly in any PR.

## Quick reference

| Symptom | Likely cause | Action |
|---|---|---|
| CLN exits: `gossip_store` corrupt (Windows) | bind-mount init bug | use a named volume override (§3) |
| CLN stuck "not synced" | Tor not healthy / trustedcoin can't egress | check `tor` health, `torrc` bind IP |
| `teosd` still dials `10.0.0.11` | stale `teosd:latest` image | `utils/build_teos.sh force` |
| CLN can't reach Tor control port | not on `bastion-transit`, or wrong IP | check `networks:` + `10.254.0.2` |

## When NOT to apply

- CI / the Linux deployment — there the full `./bastion up` is fine and
  `bitcoind` runs for real.

## Related

- [../stack-compose/SKILL.md](../stack-compose/SKILL.md)
- [../ccr-oauth/SKILL.md](../ccr-oauth/SKILL.md)
