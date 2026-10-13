# Raphael Control Center

A native macOS menu bar app to run a small self-hosted infrastructure from one window:
servers (Mac, Raspberry Pi, VPS over SSH/Tailscale), the apps on them, cloud projects,
a [Hermes](https://github.com/NousResearch/hermes-agent) AI agent, an
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) LLM router and a 3D knowledge graph.

SwiftUI + AppKit, no third-party dependencies, no telemetry. Secrets stay in the Keychain.

## Pages

| Page | What it does |
|---|---|
| **Overview** | Which projects need attention and the next action for each, my next tasks, delivery insights, operations summary. |
| **Portfolio** | Portfolios with projects as grid, list or lifecycle Kanban (Idea → Archived, Paused flag); project discovery from ~/Projects, GitHub, Vercel and the Monitor. |
| **My Work** | Tasks assigned to me across projects, by due date. |
| **Projects** | Per-project workspace: Overview, Board (drag & drop Kanban, WIP limits, keyboard), Tasks, Roadmap, Development (GitHub), Deployments (Vercel/servers), Monitoring (health), Activity, Settings. |
| **Roadmap / Activity** | Timeline of milestones, epics and due dates; unified, de-duplicated activity feed. |
| **Dashboard** | One-screen summary of the chosen device (or all of them). |
| **Infrastruktur** | Devices, health, Tailscale peers, actions (restart, reboot, terminal), a command runner. |
| **Monitor** | Live + 24 h metrics per device (CPU, RAM, disk, network, temperature/throttling), Docker containers, custom services, pending/security updates, failed SSH logins. **Apps are discovered and watched on their own** — Docker compose projects, systemd services, Caddy sites (followed through the reverse proxy to what answers behind it), Vercel projects, n8n instances, websites and `~/Projects` (git state, running dev servers), linked to their GitHub repo and CI — and grouped Server / Cloud / Lokal and Berjalan / Bermasalah / Tidak berjalan. Website traffic comes from cloudflared metrics and Cloudflare Analytics; websites get uptime, response time and TLS expiry. |
| **Aplikasi & Website** | Containers and services per device, saved websites. |
| **File** | Browse any device, preview/edit text (with a `.raphael.bak` backup), images, download, upload by drag & drop, rename, new folder, delete to a trash folder, sudo reads. |
| **OmniRoute** | Provider topology, account quota, cost; opens each instance's dashboard. |
| **Agents & Token** | Hermes token use per day / task / source / model, the heaviest sessions, tips. |
| **Knowledge** | 3D knowledge graph (graphify galaxy) per project or all merged; drop PDFs, Markdown, folders or a git URL to map them (local, 0 token); SOUL, memory and `.env` editors per Hermes profile. |
| **Chat Raphael** | Chat with Hermes on any device, Claude-Code-style transcript with tool calls, subagents and a token breakdown; several chats can run at once. |

Every page follows the device switcher at the bottom of the sidebar: **Semua device** or one device.

Portfolio and project data is local SQLite — see [docs/WORKSPACE.md](docs/WORKSPACE.md).

## Build

Needs macOS 14+ and the Xcode command line tools (`xcode-select --install`). No Xcode project.

```bash
scripts/build.sh            # → build/Raphael Control Center.app
scripts/build.sh --install  # → ~/Applications, then opens it
scripts/test.sh             # workspace tests (no Xcode needed)
```

Optional: create a code-signing certificate named **Raphael Local** (Keychain Access →
Certificate Assistant → Create a Certificate…, type *Code Signing*) so the Keychain
doesn't ask again after every build.

## Raphael Web

[`web/`](web/README.md) runs the Monitor (servers, websites, cron jobs, traffic) and the
Workspace (portfolios, projects, Kanban) as a small web app on an always-on Linux box, such as
a Raspberry Pi, reachable from any device on your tailnet. Python standard library only; it
uses the same collector and workspace schema as the Mac app.

```
web/deploy.sh user@host 8787
```

## Optional companions

The app works with whatever it finds and greys out what is missing:

- **SSH** access to your servers (key-based; `~/.ssh/config` hosts are added automatically). Servers need `python3`.
- **Tailscale** CLI, for peers and reaching devices off the LAN.
- **Hermes** (`~/.hermes`) on the Mac or a server, for Chat, Agents & Token and Knowledge.
- **OmniRoute**, for the OmniRoute page.
- **graphify-galaxy** in `~/graphify-galaxy`, for the 3D graph and document mapping.
- **gh** (logged in) for GitHub; a **Vercel** token, a **Cloudflare** token with *Analytics: Read*, and **n8n** URL + API key in Monitor → *Sumber data*.

## Data

- Settings and configuration: `~/Library/Application Support/Raphael/` (`nodes.json`, `websites.json`, `omniroute.json`, `n8n.json`, `apps.json`, metrics history, built graphs).
- Secrets: macOS Keychain, service `id.altora.raphael-control-center`.
- Network calls go only to your own devices and the services you connect.

## URL scheme

`raphael://monitor`, `raphael://files`, `raphael://chat?q=…`, `raphael://device?id=…`,
`raphael://knowledge?add=/path/file.pdf` — handy for scripts and agents.

## License

MIT for the code. The Altora logo and app icon are not covered.
