# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project identity

Bastion is a self-hosted "sovereign node" stack: a Bitcoin full node + Core
Lightning node, the supporting privacy plumbing (Tor, a recursive DNS resolver,
Pi-hole, WireGuard), an observability stack, a web hub, and an AI stack
(Claude Code Router + a CodeDeck+ bridge). Everything runs in Docker, split into
five **stacks**, each its own Compose project with its own `docker-compose.yml`
and `README.md`:

| Stack | What it runs |
|---|---|
| `stack-network` | Pi-hole, `unbound`, WireGuard, **Tor** (owns the shared Tor volume + the `bastion-transit` network) |
| `stack-bitcoin` | `bitcoind`, `lightningd` (CLN), RTL; `teosd` (own watchtower, opt-in `--with-watchtower`) |
| `stack-monitor` | Portainer, Prometheus, Grafana, node-exporter |
| `stack-web` | `hub` (static nginx landing page) |
| `stack-ai` | `ccr` (Claude Code Router), `codedeck-bridge` |

Design ethos: Tor-first (all outbound Bitcoin/Lightning/relay traffic proxied),
network-segmented (one bridge network per stack, a single narrow `bastion-transit`
for the few services that must talk across stacks), and **no personal data in the
tree** — no node alias/pubkey/onion, no real IPs/domains, no wallet-app names, no
account identifiers. Generic self-host documentation only.

The root `bastion` bash script + `utils/config.sh` orchestrate the stacks.
`rust-teos` is a git submodule (a fork). `bastion.conf` + the per-stack
`stack-*/.env` symlinks are generated, git-ignored, and hold live secrets.

## Commands

The maintainer's dev host is **Windows** (Docker Desktop, Git Bash); the
deployment target is **Linux**. Bash syntax is identical either way.

```bash
./bastion                       # no args + a TTY -> interactive TUI
./bastion up [stack...]         # deploy all stacks in order, or just the named ones
./bastion stop [stack|ctr...]   # stop a stack set (reverse order) or one container
./bastion down [stack...]       # stop + remove (reverse order)
./bastion build [stack...]      # build images without starting
./bastion logs [stack|ctr...]   # tail logs
./bastion restart|start <ctr>   # per-container lifecycle
./bastion exec <ctr> -- <cmd>   # run a command in a container
./bastion shell <ctr>           # shell into a container (bash if present, else sh)
./bastion ps                    # every container: state + health + owning stack
./bastion status                # docker ps table
./bastion versions              # image pin vs. running
./bastion audit                 # node profitability audit (python)
```

A single container name on `stop`/`logs` uses the per-container path; a stack
name keeps the stack behaviour. `restart`/`stop` of a `stack-network` container
hit the same "other stacks running" guard as the stack-level `stop`
(`--force` overrides). `docker compose` should never need to be run by hand.

Any non-TTY invocation (`services/bastion-daemon.sh`, cron, a pipe) runs the
plain path — the TUI never launches without an interactive terminal.

`stack-network` is mandatory: `up` prepends it when omitted, and `stop`/`down`
refuse to touch it while another stack has containers running (`--force`
overrides). The TUI's deploy picker keeps it checked; its stop/down picker
blocks the run and explains why.

### Dev environment constraints

- **Never start `bitcoind` in dev.** It would begin a full-chain sync. For local
  testing bring up only what a change needs (see the `local-testing` skill).
  CLN can run **without** `bitcoind`: `bcli` is disabled and `trustedcoin`
  (block data over Tor) is an `important-plugin`.
- The Lightning node used for testing is **empty** — no channels, no funds.
- `network_mode: host` (Pi-hole) and the `/lib/modules` mount (WireGuard) do not
  work on Docker Desktop for Windows. Those pieces are Linux-target-only for any
  end-to-end verification.

## Workflow

- **Branch + PR, never direct commits to `master`.** Start from an up-to-date
  `master`, create `claude/<short-kebab-slug>`, do all of a request's commits
  there (one branch per request, not per commit), then open a PR with
  `gh pr create` and a real summary. Leave the PR open for the user to merge
  unless they explicitly say to merge it.
- **Multi-part requests: one task at a time.** Implement, verify with the
  narrowest sufficient check, commit that task, then start the next. Do not batch
  unrelated changes into one commit.
- A change is not finished until it is verified. If you could not run the
  verification (Docker unavailable, needs the Linux target), say so plainly in
  the summary and PR — do not imply it passed.

## Commit and comment safety

- **English only, everywhere it lands in the tree or history**: code, comments,
  commit subjects and bodies, PR titles and descriptions. The conversation with
  the maintainer may be in another language; the artifacts are not.
- **No literal `@word` in any commit message, PR body, or code comment.** GitHub
  auto-links `@word` as a user mention and notifies a real account. The trap here
  is image / package references that do not *feel* like a mention:
  `@anthropic-ai/claude-code`, `@claude-code-router/core`. Wrap the token in
  backticks, drop the `@`, or rephrase. Scan every drafted commit message for
  `@` before `git commit`.
- **Every commit Claude Code makes ends with a `Co-Authored-By:` trailer** naming
  the model that did the work, e.g.
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`. Apply it every time,
  unprompted.
- **Comments and commit messages must stand on their own.** State the actual
  invariant or behaviour being preserved — do not make "see the task" / "per the
  plan" / a commit hash the only explanation.

## Absolute constraints (do not suggest workarounds)

- **Never commit `bastion.conf`, any `stack-*/.env`, `secrets/`, or anything
  under `stack-*/data/`.** They hold live secrets — Pi-hole password, CCR web
  token, Claude OAuth `accessToken`/`refreshToken` in
  `stack-ai/data/ccr/.claude/.credentials.json`, CLN state, HSM secret. They are
  git-ignored; keep it that way. `bastion.conf` is the operator's single source
  of truth; `utils/config.sh write_secret_files` projects the four secret values
  (see `config_var_is_secret`) into `secrets/<lower_name>` (mode 600) which the
  compose files mount at `/run/secrets/<name>` — secrets reach a container as a
  file, never a plaintext env var. Add a new secret → add it to
  `config_var_is_secret`, wire the compose `secrets:` block, and the file is
  created automatically.
- **Never start `bitcoind` in dev** (see above).
- **`rust-teos` is a submodule.** Any change to it is a real commit *inside* the
  submodule (on a branch of the fork) plus a pointer bump in the superproject.
  Never leave it `-dirty`. `git submodule update` silently discards uncommitted
  submodule work.
- **Pinned `bastion-transit` addresses are load-bearing.** Three are fixed via
  `ipv4_address` and referenced by config:
  - `10.254.0.2` — `tor`. In `stack-network/config/torrc`
    (`SocksPort`/`ControlPort`), `cln_config` (`proxy`, `statictor`),
    `teos.toml` (`tor_control_host`), the `tor` healthcheck.
  - `10.254.0.10` — `lightningd`. It is `cln_config`'s `bind-addr`, which CLN
    hands to Tor as its **static hidden-service forward target**, so it must be
    an address the tor container can reach (i.e. on `bastion-transit`, never
    `0.0.0.0` — Tor cannot connect to 0.0.0.0 at all - verified).
  - `10.254.0.11` — `teosd`. It is `teos.toml`'s `api_bind`, which rust-teos
    uses as both the API listen socket and the watchtower hidden-service
    forward target — same reachability requirement.

  The `tor` container is on `bastion-transit` only; it cannot route to any
  per-stack subnet. Any service that must be reachable *through* Tor (inbound
  onion) has to advertise a `bastion-transit` address. Keep these three IPs and
  their config references in sync.
- **Intentional design — do not "fix" it:** every Hub-listed service is published
  on `0.0.0.0` on the host on purpose — the hub (`80`), RTL (`3000`), CLN REST
  (`3001`), CCR (`3458`), Portainer (`4000`), Grafana (`4001`), Prometheus
  (`9090`). The maintainer wants each reachable three ways: over WireGuard, from
  `localhost` on the host, and from the trusted LAN — keyed by a Pi-hole
  local-DNS record (`bastion.node` → host LAN IP). The **host firewall** is the
  access-control layer (`docs/firewall.md` is the reference; it is not
  optional in production). Do not switch any of these to `127.0.0.1:` bindings.
  This does **not** extend to `bitcoind` RPC, the Tor SOCKS/control ports, or any
  other internal endpoint — those are never published.
- Do not downgrade a pinned image tag / toolchain version to work around a build
  failure — fix the root cause. Pulled images are pinned `repo:<version>@sha256:…`;
  bump the version *and* re-resolve the digest together. `./bastion versions`
  shows the pin vs. what is running.

## Architecture / boot order

`./bastion up` deploys in this order (defined in `utils/config.sh` `STACKS`):

```
stack-network   creates bastion-transit + the bastion-tor-data volume, runs tor
     │          -> ./bastion waits for the tor container to become healthy
stack-bitcoin   bitcoind, lightningd, rtl  (+ teosd only with --with-watchtower;
     │          it carries the "watchtower" compose profile). On up, ./bastion
     │          seeds data/rtl/RTL-Config.json + mints the RTL access.rune from
     │          CLN - both only if absent. With --with-watchtower it also seeds
     │          data/teos/teos.toml from config/teos.toml (else teosd would run
     │          on rust-teos defaults, unreachable at its pinned transit IP).
stack-monitor   self-contained (own network, no transit)
stack-web       self-contained
stack-ai        ccr + codedeck-bridge
```

Networks: each stack owns `bastion-<stack>` (`10.<10|20|30|40|50>.0.0/24`, first
service at `.2`). `bastion-transit` (`10.254.0.0/24`) is created by
`stack-network` and joined `external: true` by the services that must cross stack
boundaries: `tor`, `lightningd`, `bitcoind`, `teosd`, `codedeck-bridge`. The
`bastion-tor-data` named volume is created by `stack-network` and mounted
read-only by `lightningd` and `teosd` for the Tor control cookie.

## Skills

- `stack-compose` — the network/volume model and how to edit a
  `docker-compose.yml` without breaking cross-stack wiring.
- `local-testing` — validating changes without `bitcoind`, which stack subset a
  given change needs, and the CLN `gossip_store` named-volume workaround.
- `ccr-oauth` — how CCR consumes the Claude OAuth credentials file and how the
  in-container token refresher keeps it fresh.
