# Raphael Web

The Control Center's Monitor and Workspace as a small web app for an always-on Linux box
(built for a Raspberry Pi 4). Python standard library only: no pip, no Node, no build step.

| Page | What it shows |
|---|---|
| Overview | devices online, websites up, alerts, active projects |
| Server | CPU / RAM / disk / temperature with 1–24 h history, containers, services, failed units, pending updates, power/thermal throttling |
| Website | HTTP status, response time, 24 h uptime, SSL expiry — configured sites plus every Cloudflare Tunnel hostname found |
| Cron & job | crontab, /etc/cron.d, systemd timers and Hermes cron jobs with last/next run, failures and missed runs |
| Traffic | Cloudflare Tunnel counters (from cloudflared) and Cloudflare Analytics (7 days, when a token with Analytics read is available) |
| Portfolio · project board · tasks · activity | the workspace: portfolios, projects, Kanban with drag & drop, task details |

## How it fits with the Mac app

- **Same collector.** `extract.py` copies `MonitorStore.linuxScript` out of the Swift source at
  deploy time, so both apps read devices identically. Job, alert and parsing rules in
  `core.py` are ported from `Jobs.swift` / `MonitorStore.swift` and tested on the same cases.
- **Same workspace format.** The schema is extracted from `WorkspaceSchema.swift`; a
  `workspace.sqlite` moves between the Mac app and Raphael Web unchanged. Today each keeps its
  own file (no sync yet).

## Run and deploy

```bash
python3 web/extract.py                                  # build/collector_linux.sh + build/schema_v1.sql
python3 -m unittest discover -s web/tests               # tests
python3 web/server.py --config path/to/config.json      # http://127.0.0.1:8790
web/deploy.sh user@host 8787                            # tests, copy, systemd user service, tailscale serve
```

`config.example.json` shows the config (devices: `local` or an `ssh` target/alias; websites;
`.env` files to read a Cloudflare token from). `deploy.sh` installs `web/config.local.json`
(git-ignored) as `~/.config/raphael-web/config.json` only when none exists yet.

## Security

- Listens on `127.0.0.1` only; reachable through `tailscale serve` (tailnet only).
- Writes need `X-Raphael: 1`, a JSON body and a same-origin `Origin` (CSRF guard); strict CSP,
  no framing.
- No commands run on request. Sampling is the only thing that executes, on a fixed schedule,
  and the service is capped (30 % CPU, 200 MB RAM, idle I/O).
- The Cloudflare token is read on the server from the configured `.env` files and never sent
  to the browser. No other credentials are read.

## Data and rollback

Data lives in `~/.local/share/raphael-web/` (`workspace.sqlite` with `backups/`, and
`metrics.sqlite` with 24 h of samples). The previous app version stays in
`~/raphael-web/app.old`.

```bash
systemctl --user disable --now raphael-web               # stop
sudo tailscale serve --https=8787 off                    # unpublish
```
