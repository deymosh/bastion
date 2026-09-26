# Web stack

The Hub is a single static page, served read-only by nginx on port `80`, that
links to every Bastion panel. It is self-contained, with its own network and no
transit access.

| Service | Address | Host port |
|---|---|---|
| `hub` | `10.40.0.2` | `80` |

## How it works

- Opening a panel keeps you in the Hub. A top banner (the Bastion icon and the
  current section) stays visible while the panel loads in an embedded frame.
  Clicking the icon returns to the directory.
- Routing happens only in the browser (`location.hash`), so a bookmark like
  `/#grafana` opens that panel directly.
- Links are built from the hostname you are browsing with, so the Hub works the
  same over `bastion.node`, a raw IP or `localhost`.
- Every embedded view has an **Open in new tab** button. A service can refuse to
  be framed (`X-Frame-Options` / `frame-ancestors`), and the Hub cannot override
  another container's headers. Portainer and Pi-hole always open in a new tab.

## Editing

The panel list is the `services` array in `html/index.html`. Each entry needs a
unique `key` (used in the URL hash) and a `port`/`path` that match what the
compose file actually publishes. The page is mounted read-only, so a browser
refresh is enough and no restart is needed.

```bash
./bastion up web
./bastion logs hub
```
