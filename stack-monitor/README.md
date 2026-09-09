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

## Commands

```bash
docker compose -f ./stack-monitor/docker-compose.yml up -d
docker compose -f ./stack-monitor/docker-compose.yml ps
docker compose -f ./stack-monitor/docker-compose.yml logs -f prometheus
```

Persistent volumes are managed by Docker: `portainer_data`, `grafana_data`, and
`prometheus_data`. Do not remove them during routine troubleshooting.

Change default Grafana and Portainer credentials immediately after first access.
