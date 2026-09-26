# Agent Docker (Sysbox)

An opt-in, private Docker daemon for the `codedeck-bridge` agent. It lets the
agent `docker build` / `docker run` a project's own toolchain container — the
same container a developer would use to build the project — without sudo,
without installing toolchains into the bridge, and without touching the host's
Docker.

```
codedeck-bridge (uid 1000)                agent-docker 10.50.0.6  [runtime: sysbox-runc]
  docker CLI ── tcp://agent-docker:2376 ──► dockerd (docker:<ver>-dind, NOT privileged)
  (mutual TLS)                                 └─ the agent's images / containers / networks
  /data/workspaces/<repo>  ◄── same path ───►  /data/workspaces/<repo>
```

- **Separate daemon.** Everything the agent builds or runs lives inside the
  sidecar's own `dockerd`. The host's `docker ps` / `docker images` never see
  it, so names, networks and ports cannot collide with Bastion's containers,
  and the agent cannot stop, inspect or exec into `lightningd` or anything else.
- **Not privileged.** The stock `docker:dind` image normally needs
  `privileged: true`, which is root on the host — unacceptable on the machine
  holding the Lightning keys. The [Sysbox](https://github.com/nestybox/sysbox)
  runtime runs it as a user-namespaced "system container" instead: root inside
  maps to an unprivileged host uid. Bastion refuses to start the sidecar on any
  other runtime; there is no privileged fallback.
- **Mutual TLS.** The API listens on `2376` only, with `--tlsverify`; the
  bridge holds the only client certificate. No host port is published.
- **Only the repositories are shared.** The sidecar mounts the bridge's
  `data/codedeck/workspaces` at the same path, so `-v /data/workspaces/...`
  works from the agent. The rest of the bridge's `/data` (agent config and
  auth) is never visible to a build.

## Requirements

Sysbox is Linux-only. It does **not** work on Docker Desktop (Windows/macOS),
so this feature is for the Linux deployment target.

| | |
|---|---|
| Distro | Ubuntu or Debian (packages); others must build Sysbox from source |
| Kernel | ≥ 5.12 (ID-mapped mounts; older kernels need the `shiftfs` module) |
| Init | systemd |
| Docker | Docker Engine from docker.com's apt repo — **not** the snap |
| Arch | amd64 or arm64 |

## Install Sysbox

```bash
./bastion install-sysbox
```

This:

1. checks the host against the table above, changing nothing if it fails;
2. on a terminal, asks for confirmation and lists the stacks it will stop;
3. stops every running Bastion stack **gracefully**. The Sysbox installer
   restarts Docker, and Docker's own shutdown gives each container about 15 s,
   far less than `bitcoind`'s 5-minute `stop_grace_period`;
4. downloads the pinned Sysbox package and verifies its SHA-256 before `apt`
   sees it;
5. installs it (`sudo apt-get install jq ./sysbox-ce_*.deb`), which registers
   `sysbox-runc` with Docker and restarts Docker;
6. confirms Docker now lists `sysbox-runc`, then starts the stacks that were
   running.

`./bastion up --with-agent-docker` makes the same offer on a terminal when
Sysbox is missing. Non-interactive runs (cron, the daemon) only print these
instructions and exit non-zero.

Manual equivalent, for reference (use the version and checksum pinned in
`utils/install-sysbox.sh`):

```bash
./bastion stop                                   # graceful - before Docker restarts
curl -fsSLO https://github.com/nestybox/sysbox/releases/download/v<ver>/sysbox-ce_<ver>.linux_amd64.deb
echo "<sha256>  sysbox-ce_<ver>.linux_amd64.deb" | sha256sum -c
sudo apt-get install -y jq ./sysbox-ce_<ver>.linux_amd64.deb
docker info | grep -i runtimes                   # must list sysbox-runc
./bastion up --with-agent-docker
```

The installer also adds `bip` and `default-address-pools` to
`/etc/docker/daemon.json` if they are absent (172.24.0.0/16 and 172.31.0.0/16
by default). Bastion's own networks use explicit `10.x` subnets and are not
affected. If those ranges clash with your LAN, set your own values in
`daemon.json` before installing.

## Enable

```bash
./bastion up --with-agent-docker          # or BASTION_PROFILES=agent-docker ./bastion up
```

The sidecar carries the `agent-docker` compose profile, so a plain `./bastion up`
never starts it. `stop` / `down` always include it. Both flags combine:
`./bastion up --with-watchtower --with-agent-docker`.

## Using it from the agent

Inside `codedeck-bridge` the environment is already set up (`DOCKER_HOST`,
`DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`, and `docker` on `PATH`). The CLI,
including `buildx` and `compose`, is copied from the sidecar image at every
start, so it always matches the daemon's version. When the sidecar is off,
`docker` is simply not on `PATH`.

```bash
cd /data/workspaces/myproject
docker build -t myproject-builder -f docker/Dockerfile.build .
docker run --rm --user "$(id -u):$(id -g)" \
  -v /data/workspaces/myproject:/src -w /src myproject-builder make release
```

Two rules:

- **Bind-mount only paths under `/data/workspaces`.** A `-v` source is
  resolved by the sidecar's daemon, and that is the only bridge path it can
  see at the same location.
- **Pass `--user "$(id -u):$(id -g)"`** (uid 1000) when a container writes into
  the checkout. Files written as the container's root end up owned by root on
  the host, and the agent can no longer modify or delete them.

## Limits and housekeeping

| `bastion.conf` key | Default | |
|---|---|---|
| `AGENT_DOCKER_CPUS` | `2` | CPU cap for the sidecar and everything it runs |
| `AGENT_DOCKER_MEMORY` | `4g` | Memory cap, same scope |

Both are optional. They keep builds from starving `bitcoind` and `lightningd`.
A `pids_limit` of 4096 guards against fork bombs.

The image and build cache live in the `agent_docker_data` volume, which only
grows. Prune it from time to time:

```bash
./bastion exec agent-docker -- docker system prune -af    # images, containers, build cache
```

## Security model — what this does and does not protect

Protected:

- The host's Docker daemon and every Bastion container. The agent has no
  socket to them.
- Host root. Nothing runs privileged; root inside the sidecar is an
  unprivileged uid on the host.
- The bridge's credentials. They are not mounted into the sidecar.

Not protected — plan for it:

- **Shared kernel.** Sysbox is a strong container boundary, not a VM. A
  kernel exploit from a malicious build script is out of its scope. For
  untrusted code at scale, a separate VM is stronger still.
- **Network reach.** Containers the agent runs can reach what the bridge can:
  other `bastion-ai` services (CCR, the MCP gateway), your LAN, and the
  internet over clearnet — **not over Tor**. They cannot reach
  `bastion-transit`, `bitcoind` RPC or the Tor ports, which are never
  published.
- **Disk.** The data volume has no size cap; see pruning above.

## Troubleshooting

```bash
./bastion logs agent-docker                         # dockerd startup / TLS generation
docker info | grep -i runtimes                      # host: must list sysbox-runc
systemctl status sysbox                             # host: the Sysbox services
./bastion exec codedeck-bridge -- docker version    # the agent's view (client + server)
```

- **`docker: not found` in the bridge**: the sidecar is not running, or has
  not finished its first start. The CLI is published before `dockerd` starts.
- **`x509: certificate is valid for ..., not agent-docker`**: the sidecar's
  `hostname:` must stay `agent-docker`. The dind entrypoint builds the
  server certificate from it.
- **`bind source path does not exist`**: `./bastion up --with-agent-docker`
  creates `stack-ai/data/codedeck/workspaces` as the operator. Raw `docker
  compose` does not, and the compose entry deliberately refuses to let Docker
  create it root-owned.

## Uninstall

```bash
./bastion down stack-ai                   # removes the sidecar with the stack
docker volume rm stack-ai_agent_docker_data     # optional: the agent's images/cache
sudo apt-get purge sysbox-ce               # restarts Docker - stop the stacks first
```

Verified by `tests/integration/agent-docker.sh`. CI runs it on a real Sysbox
install, done by `utils/install-sysbox.sh`, with the privileged test fallback
forbidden.
