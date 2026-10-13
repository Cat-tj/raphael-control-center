# Raphael Web

The Control Center's Monitor and Workspace as a small web app for an always-on Linux box
(built for a Raspberry Pi 4).

Two implementations of the same server, same API, same data files:

- **Rust** (`rust/`, default): one ~5 MB static-ish binary, ~20 MB RAM on the Pi.
  Cross-compiled on the Mac with `cargo zigbuild --target aarch64-unknown-linux-gnu.2.36`.
- **Python** (`server.py` and friends, stdlib only): kept as the reference and fallback.

`tests/test_web.py` holds the HTTP contract; with `RAPHAEL_WEB_BIN=…/raphael-web` it runs against
the Rust binary, and `deploy.sh` refuses to ship a Rust build that fails it. The Rust unit tests
(`cargo test`) cover the same cron, job, alert, incident, action, backup and workspace cases as the
Python ones. Scripts that run on the devices are shared files: `remote/collector_linux.sh`,
`remote/health.py`, `remote/files.py`; the workspace schema is `schema/schema_v1.sql`. The desktop
app (`../desktop`) embeds the same server as a library, with the UI compiled in and an
in-process collector (`native.rs`) for the computer it runs on.

| Page | What it shows |
|---|---|
| Overview | devices online, websites up, alerts, active projects |
| Server | CPU / RAM / disk / temperature with 1–24 h history, containers, services, failed units, pending updates, power/thermal throttling |
| Website | HTTP status, response time, 24 h uptime, SSL expiry — configured sites plus every Cloudflare Tunnel hostname found |
| Cron & job | crontab, /etc/cron.d, systemd timers and Hermes cron jobs with last/next run, failures and missed runs |
| Traffic | Cloudflare Tunnel counters (from cloudflared) and Cloudflare Analytics (7 days, when a token with Analytics read is available) |
| File | read-only browser for every device (as the service user, no sudo); files that usually hold secrets (`.env`, keys, tokens, `~/.ssh`) are refused, also through symlinks |
| Agents & Token | Hermes sessions and token use per profile, read-only from `state.db` (same queries as the Mac app) |
| OmniRoute | provider health, usage, quotas and connections (API key read on the server from the configured `.env`) |
| Portfolio · project board · tasks · activity | the workspace: portfolios, projects, Kanban with drag & drop, task details |

| Insiden | open incidents and 30 days of history (opened when a problem persists, closed when it recovers), plus the action log |
| Notifikasi | WhatsApp alerts through `hermes send` (open + recovery, one message per round, damped for flapping signals, max 6/h), test message, weekly report |

Alerts cover: website down (2 checks), device unreachable (3 min), temperature ≥ 80 °C, undervoltage,
disk ≥ 93 %, failed/missed jobs, SSL < 7 days, backups (stale, empty or shrinking — `backups` in the
config), SD-card errors / read-only root, unexpected reboots (with the likely cause from the previous
boot's journal) and the home internet being down (website status is held instead of paging for
every site). The ⌘K palette searches pages, devices, jobs, containers, websites, projects and tasks.
The app installs as a PWA (manifest + offline shell).

**Actions** (opt-in per kind in `actions`): restart a service from the allow-list or one the device
reports, restart a container, run a cron/Hermes job now — always behind a confirmation dialog,
built from validated names (no free-form commands) and logged with who did it. Logs of services,
containers and job log files are read-only.

## How it fits with the Mac app

- **Same collector.** `remote/collector_linux.sh` is the one script every device runs (it started
  in the Swift app, which keeps a copy in `legacy/`). Job, alert and parsing rules are tested on
  the same cases in Python and Rust.
- **One collector run per device.** In the Mac app, Monitor → Sumber data → *Raphael Web* takes
  the URL; the Mac then reuses Raphael Web's latest sample (`/api/raw`) for those devices instead
  of SSH-ing in every minute, and falls back to SSH when Raphael Web doesn't answer.
- **One workspace.** Raphael Web holds the shared `workspace.sqlite` (`schema/schema_v1.sql`). With *Sinkronkan workspace* on (Monitor → Sumber data), the Mac app
  keeps a local copy: every committed local transaction is captured as its write statements,
  queued in `workspace-outbox.json` (kept while offline) and applied in order through
  `/api/ws/apply`, which only lets INSERT/UPDATE/DELETE on workspace tables through (SQLite
  authorizer — no PRAGMA, ATTACH, DDL or transaction control). When the server's revision moves,
  the Mac pulls `/api/ws/dump` and replaces its copy. An empty server is seeded from the Mac on
  the first connection; otherwise the server wins (local file backed up first).

## Run and deploy

```bash
python3 -m unittest discover -s web/tests               # tests
python3 web/server.py --config path/to/config.json      # http://127.0.0.1:8790
web/deploy.sh user@host 8787                            # tests (python, rust, contract), cross-compile, deploy
RAPHAEL_WEB_IMPL=python web/deploy.sh user@host 8787    # run the Python server instead (rollback)
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
