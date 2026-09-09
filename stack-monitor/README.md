# Monitor Stack

Operational visibility and container administration for Bastion. This stack does
not own node state; it reads metrics and provides management interfaces.

## Services

| Service | Host address | Purpose |
|---|---|---|
| Portainer | `https://localhost:4000` | Container administration (`10.30.0.2`) |
| Grafana | `http://localhost:4001` | Dashboards (`10.30.0.3`) |
| Prometheus | `http://localhost:9090` | Metrics storage and queries (`10.30.0.5`) |
| Node Exporter | `10.30.0.4:9100` | Host metrics |

All services join the private `bastion-monitor` subnet (`10.30.0.0/24`). Prometheus uses `prometheus.yml` and persists
its data in a Docker-managed volume.

### Security

**Portainer mounts the Docker socket** (`/var/run/docker.sock`). That is
root-on-the-host equivalent: anyone who reaches the Portainer UI, or exploits it,
can create a privileged container and escape. Port `4000` must be firewalled the
most tightly of any Hub port - WireGuard + LAN only, never WAN (see
`docs/firewall.md`). A `docker-socket-proxy` in front of Portainer, or
dropping Portainer from the default deploy, is the planned hardening.

Images are pinned by digest; `./bastion versions` shows the pin vs. what runs.

## Commands

```bash
docker compose -f ./stack-monitor/docker-compose.yml up -d
docker compose -f ./stack-monitor/docker-compose.yml ps
docker compose -f ./stack-monitor/docker-compose.yml logs -f prometheus
```

Persistent volumes are managed by Docker: `portainer_data`, `grafana_data`, and
`prometheus_data`. Do not remove them during routine troubleshooting.

Change default Grafana and Portainer credentials immediately after first access.
