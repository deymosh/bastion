# Monitor stack

Observability and container administration. This stack holds no node state. It
is self-contained, with its own network and no transit access.

## Services

| Service | Address | Host port | Purpose |
|---|---|---|---|
| `portainer` | `10.30.0.2` | `4000` (https) | Container administration |
| `grafana` | `10.30.0.3` | `4001` | Dashboards |
| `node-exporter` | `10.30.0.4:9100` | — | Host metrics |
| `prometheus` | `10.30.0.5` | `9090` | Metrics storage and queries (`prometheus.yml`) |

State lives in the named volumes `portainer_data`, `grafana_data` and
`prometheus_data`. `./bastion down` keeps them.

## Security

- **Portainer mounts the Docker socket**, which is equivalent to root on the
  host. Anyone who reaches its UI can escape to the host. Firewall port `4000`
  the most tightly of any port (WireGuard and LAN only, never WAN). The planned
  hardening is a `docker-socket-proxy` in front of it.
- **Grafana** starts with `admin` / `admin`, and **Portainer** asks you to create
  an admin on first visit. Do both right after the first `up`.
- Grafana sets `GF_SECURITY_ALLOW_EMBEDDING=true` so the Hub can frame it; it
  still requires a login. Portainer's CSP can only be lifted completely, and
  that is not worth it for a container that holds the Docker socket, so the Hub
  opens Portainer in a new tab instead.

## Operations

```bash
./bastion up monitor
./bastion logs prometheus
./bastion restart grafana
```
