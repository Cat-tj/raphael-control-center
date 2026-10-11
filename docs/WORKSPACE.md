# Workspace: portfolios, projects, tasks

Local-first project management inside Raphael Control Center. Everything lives in one
SQLite file; integrations only read from external systems.

## Storage

`~/Library/Application Support/Raphael/workspace.sqlite` (override for development with
`RAPHAEL_WORKSPACE_DB=/path/file.sqlite`). WAL journal, foreign keys on, every change in a
transaction (`WorkspaceDB.transaction`). The store writes to SQLite first and only then
updates memory; a failed write reloads from disk so the UI never shows unsaved state.

Backups: `backups/workspace-<time>-<reason>.sqlite` next to the database, taken with the
SQLite backup API before every pending migration, before an import and when the integrity
check fails (newest 10 kept). Export/import: `WorkspaceStore.exportData()` /
`importData(_:)` (JSON; import merges by id and never deletes).

No credentials are stored here (tokens stay in the Keychain).

## Schema (v1, `WorkspaceSchema.swift`)

| Table | Purpose |
|---|---|
| `portfolio` | name, description, archived, sort |
| `project` | portfolio (SET NULL), lifecycle (`idea planned building live maintenance archived`), `paused` flag, priority, favorite/pinned, start/target date, task key + next number, labels, WIP limits |
| `epic`, `milestone`, `release` | per project (CASCADE) |
| `task` | stable UUID + per-project number (`UNIQUE(project_id, number)`), status (`backlog ready in_progress review done`), fractional `position`, priority, assignee, labels, due date, `blocked` flag + reason, archived, parent (subtasks), epic/milestone (SET NULL), started/completed timestamps |
| `task_checklist`, `task_dependency` | dependency PK `(task_id, depends_on)`, no self-links; cycles refused in code |
| `resource_link` | project ↔ repo / local folder / domain / server / compose / service / Vercel / n8n / Monitor app / GitHub Project / cron job, `UNIQUE(project_id, kind, ref)` |
| `external_ref` | local record ↔ external id, `UNIQUE(system, external_id)` |
| `activity` | event with a stable id (`PRIMARY KEY`), project, type, time, source, url, metadata |
| `sync_state` | adapter state (last sync, settings, monitor transition states) |
| `registry_decision` | discovery suggestions accepted/dismissed |

Migrations are additive: add a new `(version, sql)` entry, never edit a shipped one.
`PRAGMA user_version` records the applied version; each migration runs in its own
transaction and rolls back on failure.

## Rules worth knowing

- **Progress** = done ÷ planned, counting non-archived top-level tasks. No tasks → "belum
  terukur" (never estimated from commits, tokens or guesses).
- **Milestone at risk** = not completed and past its date, or due within 7 days with < 70 % done.
- **Operational health** (per project, from linked resources) is separate from progress:
  `Sehat` only when every signal is healthy and fresh (< 10 min); old data = `Data usang`,
  missing data = `Belum diketahui`, any failure = `Terganggu`, all failing = `Down`.
- **Ordering**: a move takes the midpoint between neighbours; when gaps run out the column
  is renumbered in the same transaction.
- **Insights** use stored data only; a metric without data is shown as missing.

## Integrations (read-only)

| Source | What | Notes |
|---|---|---|
| GitHub (`gh` login) | repo info, branches, commits, issues, PRs (+ review state), Actions runs, releases, milestones per linked repo | refreshed every 10 min; an inaccessible repo shows its error, others continue |
| Issue sync | issue → task, GitHub milestone → milestone (opt-in per project) | `(system, external_id)` unique; title and open/closed flow in; locally deleted tasks are not recreated; nothing is written to GitHub |
| GitHub Projects v2 | items → tasks, Status field → board column by name | needs `gh auth refresh -s read:project`; issues share the issue-sync id, so the two adapters never duplicate |
| Vercel | deployments of linked projects | token in Monitor → Sumber data |
| Monitor | linked apps, domains, servers, containers, services, cron jobs | down/degraded/recovered transitions become activity events |
| Hermes / Codex | sessions whose working directory is a linked folder or repo | read from `state.db` / `~/.codex/sessions`; observability only |

Every external event id is `<source>:<kind>:<external id>|<project>`, so repeated syncs
insert nothing new.

## Tests

`scripts/test.sh` builds `Sources/Workspace` (+ the cron parser) with `Tests/main.swift` and
runs it: CRUD and restart persistence, drag-and-drop ordering and gap exhaustion,
dependency cycles, sync idempotency, export/import, migration + rollback + backup,
malformed database/JSON, insights, cron expressions.

## Rollback

Workspace data is self-contained: quitting the app and moving `workspace.sqlite*` aside
returns to an empty workspace; any file in `backups/` can be copied back as
`workspace.sqlite`. The rest of Raphael (Monitor, Hermes, Knowledge…) does not depend on it.
