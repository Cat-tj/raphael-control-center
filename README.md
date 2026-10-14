# Raphael Control Center

Run a small self-hosted infrastructure from one place: servers (Raspberry Pi, VPS, the machine
you are on), the websites and apps on them, cron jobs and backups, a
[Hermes](https://github.com/NousResearch/hermes-agent) AI agent, an
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) LLM router — plus portfolios, projects
and a Kanban board. Alerts reach you as WhatsApp messages (through Hermes) and desktop
notifications.

A native **macOS** menu bar app (SwiftUI + AppKit) plus **Raphael Web**, a small Rust server for
an always-on box that every device can open in a browser. No telemetry; network calls go only
to your own devices and the services you configure.

```
Sources/   the macOS app (Swift) — build with scripts/build.sh
web/       Raphael Web: the server (Rust; Python reference) and its web UI
desktop/   experimental cross-platform shell (Tauri) around the web UI
```

## How it fits together

- **Raphael Web** (`web/`) is a small server for an always-on box such as a Raspberry Pi: it
  samples your devices every minute (SSH, the same collector everywhere), checks websites and
  certificates, reads Cloudflare / OmniRoute / Hermes, keeps incidents and 30 days of hourly
  metrics, sends WhatsApp alerts, and holds the shared workspace. Reach it from any device on
  your tailnet (`tailscale serve`), as a web page or an installable PWA.
- **The app** (`desktop/`) has two modes:
  - *Sambung ke Raphael Web* — the window shows your server: same data, alerts and workspace on
    every computer.
  - *Server lokal* — no separate server: the app runs Raphael Web inside itself and monitors this
    computer (CPU, RAM, disks, network, temperature on Windows, Linux and macOS) plus any SSH
    devices you add to its config.

  Either way it lives in the tray / menu bar and raises a desktop notification for each new
  incident.

## Pages

| Page | What it shows |
|---|---|
| Overview | devices online, websites up, open incidents, backups, what needs attention |
| Insiden · Notifikasi | incident history (30 days), WhatsApp alerts and the weekly report |
| Portfolio · project board · tasks · activity | portfolios, projects, Kanban with drag & drop, task details |
| Server | CPU / RAM / disk / temperature (1 h – 30 days), containers, services, updates, power & SD-card health, restart / logs |
| Website · Traffic | uptime, response time, SSL expiry; Cloudflare Tunnel and Analytics |
| Cron & job | crontab, systemd timers, Hermes cron: last/next run, failures, missed runs, run now |
| File | read-only browser for every device (secrets refused) |
| Agents & Token · OmniRoute | Hermes sessions and tokens; OmniRoute providers, usage and quotas |

## Build the macOS app

```bash
scripts/build.sh --install   # → ~/Applications/Raphael Control Center.app
scripts/test.sh              # workspace + cron tests
```

## Experimental desktop shell (Windows / Linux)

Installers from the latest
[release](https://github.com/Cat-tj/raphael-control-center/releases) or the
[Desktop app workflow](https://github.com/Cat-tj/raphael-control-center/actions/workflows/desktop.yml)
artifacts: `.msi` / `.exe` (Windows), `.deb` / `.AppImage` (Linux), `.dmg` (macOS). Builds are not
code-signed yet: Windows SmartScreen and macOS Gatekeeper will ask once (macOS: right-click →
Open).

## Build

```bash
cargo install tauri-cli --version "^2"
cd desktop && cargo tauri build          # the app for this OS
cargo test -p raphael-web                # server tests
python3 -m unittest discover -s web/tests
web/deploy.sh user@host 8787             # Raphael Web on a Linux box (see web/README.md)
```

Linux build dependencies: `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev`.

## Data

Monitor → Traffic includes a per-domain Cloudflare view: daily unique IPs, page views,
request trends, and a country map of request origins. Unique IPs are counted within
each UTC day; their seven-day sum is not a deduplicated visitor count. Country totals
include all Cloudflare requests and may include bots. The offline map uses
[Natural Earth country outlines](https://www.naturalearthdata.com/about/terms-of-use/)
(public domain), bundled in `Resources/WorldCountries.json`.

- App settings: the OS app-config folder (`id.altora.raphael-desktop/settings.json`); the local
  server's config and data under the app-data folder (`raphael-web/`).
- Server: `~/.config/raphael-web/config.json`, data in `~/.local/share/raphael-web/`.
- Tokens (Cloudflare, OmniRoute) are read on the server from the `.env` files you list; they are
  never sent to a browser or stored in the workspace.

Workspace format and sync: [docs/WORKSPACE.md](docs/WORKSPACE.md).

## License

MIT for the code. The Altora logo and app icon are not covered.
