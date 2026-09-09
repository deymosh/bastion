---
name: stack-compose
description: Use when editing any stack-*/docker-compose.yml in Bastion, adding or moving a service, changing networks/volumes/ports, or reasoning about how the five stacks talk to each other. Encodes the per-stack-subnet + bastion-transit model, the IP allocation convention, and the cross-stack contracts (bastion-transit, bastion-tor-data) owned by stack-network.
---

# Bastion stack / compose model

## Core principle

Every stack is an **independent Compose project** (`name:` at the top of its
`docker-compose.yml`) with its **own bridge network** `bastion-<stack>`. Services
only reach services in another stack if **both** join the single shared
`bastion-transit` network. `stack-network` is the owner of everything shared —
the `bastion-transit` network and the `bastion-tor-data` volume — and every other
stack consumes those as `external: true`. Keep that ownership one-directional:
never declare `bastion-transit` or `bastion-tor-data` as non-external anywhere
except `stack-network`.

## When to use this skill

- Adding a service to a stack, or moving one between stacks.
- Changing a `networks:`, `volumes:`, `ports:`, or `ipv4_address:` block.
- A service in stack A needs to talk to a service in stack B.
- A `docker compose up` fails with a network subnet / "already exists" error.
- Wiring a new consumer of Tor.

## 1. IP allocation convention

| Network | Name | Subnet | Members |
|---|---|---|---|
| per-stack | `bastion-network` | `10.10.0.0/24` | `stack-network` services |
| per-stack | `bastion-bitcoin` | `10.20.0.0/24` | `stack-bitcoin` services |
| per-stack | `bastion-monitor` | `10.30.0.0/24` | `stack-monitor` services |
| per-stack | `bastion-web` | `10.40.0.0/24` | `stack-web` services |
| per-stack | `bastion-ai` | `10.50.0.0/24` | `stack-ai` services |
| shared | `bastion-transit` | `10.254.0.0/24` | `tor` (.2), `lightningd` (.10), `teosd` (.11), `bitcoind` (dyn), `codedeck-bridge` (dyn) |

- First service in a stack gets `.2`, then `.3`, `.4`, … Static
  `ipv4_address` is used so config files can reference literal IPs.
- On `bastion-transit`, three members are pinned and load-bearing (see
  `CLAUDE.md`): `tor` `.2`, `lightningd` `.10`, `teosd` `.11`. The last two are
  pinned because each advertises its own address to Tor as an **inbound
  hidden-service forward target** — the `tor` container is on `bastion-transit`
  only and cannot route to a per-stack subnet, so a service reachable *through*
  Tor must sit on transit at a stable address (never `0.0.0.0`, which Tor
  resolves to its own loopback). `bitcoind` and `codedeck-bridge` only make
  outbound Tor connections, so they stay dynamic.

## 2. Deciding whether a service needs `bastion-transit`

Add `transit` to a service **only** if it must reach a service in another stack.
Today that means: it needs Tor (`10.254.0.2:9050/9051`), or it needs `bitcoind` /
`lightningd` from outside `stack-bitcoin`. Everything else stays on its
per-stack network only. `stack-monitor` and `stack-web` are fully self-contained
— do not give them `transit` "just in case"; Prometheus has no cross-stack
scrape targets today, and adding one is a deliberate transit-membership decision.

```yaml
# a cross-stack service
services:
  myservice:
    networks:
      net:                       # the per-stack network (aliased "net" in-file)
        ipv4_address: 10.50.0.4
      transit: {}                # no static IP unless it's a well-known endpoint
networks:
  net:
    name: bastion-ai
    ipam: { config: [{ subnet: 10.50.0.0/24 }] }
  transit:
    name: bastion-transit
    external: true               # ALWAYS external outside stack-network
```

## 3. Tor

`tor` lives in `stack-network`, on `bastion-transit` at `10.254.0.2`, ports
`9050` (SOCKS) and `9051` (control, cookie auth). State is the named volume
`bastion-tor-data` mounted at `/data/.tor` — read-write in `tor`, **read-only**
in `lightningd` and `teosd` (they read `control_auth_cookie`). Config is
`stack-network/config/torrc` bind-mounted read-only.

To add a Tor consumer: join `bastion-transit`; use `tor:9050` (DNS) for SOCKS if
you share the network, or the literal `10.254.0.2:9050` if a config file needs a
static value; mount `bastion-tor-data:/data/.tor:ro` if you need the control
cookie.

To expose a service **through** Tor (an inbound onion), the service must be
reachable from the `tor` container: pin it a `bastion-transit` `ipv4_address`
and advertise that address (not `0.0.0.0`, not its per-stack IP) as the onion's
forward target. `lightningd` (`.10`, via `cln_config` `bind-addr`) and `teosd`
(`.11`, via `teos.toml` `api_bind`) are the current examples.

## 4. `./bastion up` ordering

`stack-network` is always first (it creates `bastion-transit` +
`bastion-tor-data`), and `./bastion` blocks until the `tor` container is healthy
before starting `stack-bitcoin`. Cross-stack `depends_on` is impossible (separate
Compose projects) — ordering between stacks is the script's job, ordering
*within* a stack is `depends_on:`.

## Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `network bastion-X declared as external, but could not be found` | stack-network not up yet, or network was removed | `./bastion up stack-network` first |
| `pool overlaps with other one on this address space` | two stacks with the same subnet, or a stale network | pick an unused `10.N.0.0/24`; `docker network rm` the stale one |
| `bastion-network already exists` with a different subnet | old flat-network deployment (`10.0.0.0/24`) | `./bastion down` then `docker network rm bastion-network`, or `./bastion up --recreate-networks` |
| service can't resolve `bitcoind` / `tor` | not on a shared network | add `transit` to both |

## When NOT to apply

- Purely in-container changes (env, command flags, image tag) that don't touch
  networking, volumes, or ports.
- `stack-monitor` / `stack-web` internal wiring — they're single-network islands.

## In Bastion

The current topology is the result of a migration from one flat `bastion-network`
(`10.0.0.0/24`) to this model; older docs / a running deployment may still show
`10.0.0.x`. The per-stack `.env` files are symlinks to `bastion.conf` created by
`utils/config.sh` — every stack sees the same variables.

## Related

- [../local-testing/SKILL.md](../local-testing/SKILL.md)
- [../ccr-oauth/SKILL.md](../ccr-oauth/SKILL.md)
