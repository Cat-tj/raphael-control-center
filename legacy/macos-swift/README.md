# Raphael Control Center — macOS (Swift), legacy

The original native macOS menu-bar app (SwiftUI + AppKit). Replaced by the cross-platform desktop
app in [`desktop/`](../../desktop) (Rust + Tauri, Windows / Linux / macOS) and the server in
[`web/`](../../web). Kept so features not ported yet (Knowledge graph, Chat, Hermes .env / SOUL
editors, Studio, GitHub/Vercel views, roadmap) stay available and buildable:

```bash
cd legacy/macos-swift && scripts/build.sh --install   # ~/Applications/Raphael Control Center.app
scripts/test.sh                                       # workspace + cron tests
```

Its Linux collector and workspace schema are copies; the source of truth is now
`web/remote/collector_linux.sh` and `web/schema/schema_v1.sql`.
