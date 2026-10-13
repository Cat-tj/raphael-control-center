"""Workspace store for Raphael Web: same SQLite schema and rules as the Mac app
(WorkspaceSchema / WorkspaceStore), so a workspace.sqlite moves between the two unchanged.

Every write runs in one transaction; validation errors raise WorkspaceError (→ HTTP 400)."""
from __future__ import annotations

import glob
import json
import os
import re
import sqlite3
import threading
import time
import uuid

LIFECYCLES = ("idea", "planned", "building", "live", "maintenance", "archived")
STATUSES = ("backlog", "ready", "in_progress", "review", "done")
STATUS_TITLE = {"backlog": "Backlog", "ready": "Ready", "in_progress": "In Progress", "review": "Review", "done": "Done"}
LIFECYCLE_TITLE = {"idea": "Idea", "planned": "Planned", "building": "Building", "live": "Live", "maintenance": "Maintenance", "archived": "Archived"}


class WorkspaceError(ValueError):
    pass


def new_id() -> str:
    return str(uuid.uuid4())


def make_key(name: str, taken: set) -> str:
    words = [w for w in re.split(r"[^0-9A-Za-z]+", name.upper()) if w]
    base = "".join(w[0] for w in words[:3]) if len(words) > 1 else (words[0][:3] if words else "P")
    base = base or "P"
    key, n = base, 2
    while key in taken:
        key, n = f"{base}{n}", n + 1
    return key


def position(positions: list, before: int | None) -> float:
    if before is None or before >= len(positions):
        return (positions[-1] if positions else 0) + 1024
    nxt = positions[before]
    prev = positions[before - 1] if before > 0 else nxt - 2048
    return (prev + nxt) / 2


class Workspace:
    def __init__(self, path: str, schema_dir: str):
        self.path = path
        self.lock = threading.RLock()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA busy_timeout=5000")
        self._migrate(schema_dir)

    # ── Migrations ──
    def _migrate(self, schema_dir: str):
        files = sorted(glob.glob(os.path.join(schema_dir, "schema_v*.sql")), key=lambda f: int(re.search(r"v(\d+)", f).group(1)))
        if not files:
            raise RuntimeError(f"no schema files in {schema_dir}")
        current = self.db.execute("PRAGMA user_version").fetchone()[0]
        pending = [(int(re.search(r"v(\d+)", f).group(1)), f) for f in files]
        pending = [(v, f) for v, f in pending if v > current]
        if pending and current > 0:
            self.backup("pre-migration")
        for v, f in pending:
            with open(f, encoding="utf-8") as fh:
                sql = fh.read()
            try:
                self.db.execute("BEGIN")
                for stmt in _statements(sql):
                    self.db.execute(stmt)
                self.db.execute(f"PRAGMA user_version={v}")
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise

    def backup(self, reason: str) -> str:
        d = os.path.join(os.path.dirname(self.path), "backups")
        os.makedirs(d, exist_ok=True)
        out = os.path.join(d, f"workspace-{time.strftime('%Y%m%d-%H%M%S')}-{reason}.sqlite")
        dst = sqlite3.connect(out)
        with self.lock:
            self.db.backup(dst)
        dst.close()
        for old in sorted(glob.glob(os.path.join(d, "workspace-*.sqlite")))[:-10]:
            os.remove(old)
        return out

    on_change = None            # called after every committed change (bumps the sync revision)

    def _tx(self, fn):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                r = fn(self.db)
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise
        if self.on_change:
            self.on_change()
        return r

    # ── Replication (the Mac app keeps a local copy) ──
    def tables(self) -> list:
        with self.lock:
            return [r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]

    def dump(self) -> dict:
        out = {}
        with self.lock:
            for t in self.tables():
                cur = self.db.execute(f'SELECT * FROM "{t}"')
                cols = [c[0] for c in cur.description]
                out[t] = [dict(zip(cols, r)) for r in cur.fetchall()]
        return out

    def apply(self, statements: list) -> int:
        """Runs a client's committed write statements in one transaction. Only INSERT/UPDATE/DELETE
        (and the reads they need) on workspace tables are allowed — enforced by SQLite itself."""
        if not isinstance(statements, list) or len(statements) > 5000:
            raise WorkspaceError("batch tidak valid")
        allowed_tables = set(self.tables())
        import sqlite3 as _s

        def auth(action, a1, a2, dbname, trigger):
            if action in (_s.SQLITE_INSERT, _s.SQLITE_DELETE):
                return _s.SQLITE_OK if a1 in allowed_tables else _s.SQLITE_DENY
            if action in (_s.SQLITE_UPDATE, _s.SQLITE_READ):
                return _s.SQLITE_OK if a1 in allowed_tables else _s.SQLITE_DENY
            if action in (_s.SQLITE_SELECT, _s.SQLITE_FUNCTION):
                return _s.SQLITE_OK
            return _s.SQLITE_DENY                      # PRAGMA, ATTACH, CREATE, DROP, ALTER, BEGIN/COMMIT…
        n = 0
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute("PRAGMA defer_foreign_keys = ON")
                self.db.set_authorizer(auth)
                for st in statements:
                    if not (isinstance(st, dict) and isinstance(st.get("sql"), str) and isinstance(st.get("args", []), list)):
                        raise WorkspaceError("statement tidak valid")
                    self.db.execute(st["sql"], [a if isinstance(a, (int, float, str)) or a is None else str(a) for a in st.get("args", [])])
                    n += 1
                self.db.set_authorizer(None)
                self.db.execute("COMMIT")
            except sqlite3.DatabaseError as e:
                self.db.set_authorizer(None)
                self.db.execute("ROLLBACK")
                raise WorkspaceError(f"ditolak: {e}")
            except Exception:
                self.db.set_authorizer(None)
                self.db.execute("ROLLBACK")
                raise
        if self.on_change and n:
            self.on_change()
        return n

    def _event(self, db, project_id, type_, title, meta=None):
        db.execute("INSERT OR IGNORE INTO activity (id, project_id, type, ts, source, title, url, meta) VALUES (?,?,?,?,?,?,?,?)",
                   ("raphael:" + new_id(), project_id, type_, time.time(), "raphael", title, "", json.dumps(meta or {})))

    # ── Read ──
    def snapshot(self) -> dict:
        with self.lock:
            q = lambda sql, *a: [dict(r) for r in self.db.execute(sql, a)]  # noqa: E731
            portfolios = q("SELECT * FROM portfolio ORDER BY archived, sort, name")
            projects = q("SELECT * FROM project ORDER BY sort, name COLLATE NOCASE")
            tasks = q("SELECT * FROM task ORDER BY project_id, status, position")
            milestones = q("SELECT * FROM milestone ORDER BY target_date IS NULL, target_date")
            activity = q("SELECT a.*, p.name AS project_name FROM activity a LEFT JOIN project p ON p.id = a.project_id ORDER BY ts DESC LIMIT 150")
            links = q("SELECT * FROM resource_link ORDER BY kind, ref")
        for p in projects:
            p["labels"] = _json(p["labels"], [])
            p["wip_limits"] = _json(p["wip_limits"], {})
            top = [t for t in tasks if t["project_id"] == p["id"] and not t["archived"] and t["parent_id"] is None]
            done = sum(1 for t in top if t["status"] == "done")
            p["progress"] = (done / len(top)) if top else None          # None = belum terukur
            p["open_tasks"] = sum(1 for t in top if t["status"] != "done")
            p["blocked_tasks"] = sum(1 for t in top if t["blocked"] and t["status"] != "done")
            today = _start_of_day(time.time())
            p["overdue_tasks"] = sum(1 for t in top if t["due_date"] and t["status"] != "done" and t["due_date"] < today)
        for t in tasks:
            t["labels"] = _json(t["labels"], [])
        for a in activity:
            a["meta"] = _json(a["meta"], {})
        return {"portfolios": portfolios, "projects": projects, "tasks": tasks, "milestones": milestones, "activity": activity, "links": links}

    def _project(self, db, pid):
        r = db.execute("SELECT * FROM project WHERE id=?", (pid,)).fetchone()
        if not r:
            raise WorkspaceError("project tidak ditemukan")
        return dict(r)

    def _task(self, db, tid):
        r = db.execute("SELECT * FROM task WHERE id=?", (tid,)).fetchone()
        if not r:
            raise WorkspaceError("task tidak ditemukan")
        return dict(r)

    # ── Portfolios ──
    def create_portfolio(self, data: dict) -> str:
        name = _req(data, "name")
        pid, now = new_id(), time.time()

        def run(db):
            sort = (db.execute("SELECT MAX(sort) FROM portfolio").fetchone()[0] or 0) + 1
            db.execute("INSERT INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,0,?,?,?)",
                       (pid, name, _s(data.get("description")), _s(data.get("color")) or "violet", sort, now, now))
        self._tx(run)
        return pid

    def update_portfolio(self, pid: str, data: dict):
        fields = {k: data[k] for k in ("name", "description", "color", "archived") if k in data}
        if "name" in fields:
            fields["name"] = _req(fields, "name")
        if "archived" in fields:
            fields["archived"] = 1 if fields["archived"] else 0
        self._update("portfolio", pid, fields)

    def delete_portfolio(self, pid: str):
        self._tx(lambda db: db.execute("DELETE FROM portfolio WHERE id=?", (pid,)))

    # ── Projects ──
    PROJECT_FIELDS = ("name", "description", "category", "labels", "lifecycle", "paused", "priority", "favorite", "pinned",
                      "start_date", "target_date", "portfolio_id", "wip_limits")

    def create_project(self, data: dict) -> str:
        name = _req(data, "name")
        lifecycle = data.get("lifecycle") or "idea"
        if lifecycle not in LIFECYCLES:
            raise WorkspaceError("lifecycle tidak valid")
        pid, now = new_id(), time.time()

        def run(db):
            taken = {r[0] for r in db.execute("SELECT key FROM project")}
            key = (_s(data.get("key")).upper() or make_key(name, taken))[:6]
            if key in taken:
                raise WorkspaceError(f"key {key} sudah dipakai")
            sort = (db.execute("SELECT MAX(sort) FROM project").fetchone()[0] or 0) + 1
            db.execute("""INSERT INTO project (id, portfolio_id, name, description, category, labels, lifecycle, paused, priority,
                          favorite, pinned, start_date, target_date, key, next_number, sort, wip_limits, created_at, updated_at)
                          VALUES (?,?,?,?,?,?,?,0,?,0,0,?,?,?,1,?, '{}',?,?)""",
                       (pid, data.get("portfolio_id") or None, name, _s(data.get("description")), _s(data.get("category")),
                        json.dumps(_labels(data.get("labels"))), lifecycle, _prio(data.get("priority")),
                        _num(data.get("start_date")), _num(data.get("target_date")), key, sort, now, now))
            self._event(db, pid, "project.created", f"Project {name} dibuat")
        self._tx(run)
        return pid

    def update_project(self, pid: str, data: dict):
        fields = {k: data[k] for k in self.PROJECT_FIELDS if k in data}
        if "name" in fields:
            fields["name"] = _req(fields, "name")
        if "lifecycle" in fields and fields["lifecycle"] not in LIFECYCLES:
            raise WorkspaceError("lifecycle tidak valid")
        for b in ("paused", "favorite", "pinned"):
            if b in fields:
                fields[b] = 1 if fields[b] else 0
        if "priority" in fields:
            fields["priority"] = _prio(fields["priority"])
        if "labels" in fields:
            fields["labels"] = json.dumps(_labels(fields["labels"]))
        if "wip_limits" in fields:
            w = fields["wip_limits"] if isinstance(fields["wip_limits"], dict) else {}
            fields["wip_limits"] = json.dumps({k: int(v) for k, v in w.items() if k in STATUSES and str(v).isdigit() and int(v) > 0})
        for d in ("start_date", "target_date"):
            if d in fields:
                fields[d] = _num(fields[d])
        if "portfolio_id" in fields:
            fields["portfolio_id"] = fields["portfolio_id"] or None

        def after(db, old):
            if "lifecycle" in fields and fields["lifecycle"] != old["lifecycle"]:
                self._event(db, pid, "project.lifecycle",
                            f"{fields.get('name', old['name'])}: {LIFECYCLE_TITLE[old['lifecycle']]} → {LIFECYCLE_TITLE[fields['lifecycle']]}",
                            {"from": old["lifecycle"], "to": fields["lifecycle"]})
        self._update("project", pid, fields, after)

    def delete_project(self, pid: str):
        self._tx(lambda db: db.execute("DELETE FROM project WHERE id=?", (pid,)))

    # ── Tasks ──
    TASK_FIELDS = ("title", "description", "priority", "assignee", "labels", "due_date", "blocked", "blocked_reason",
                   "archived", "milestone_id", "epic_id")

    def create_task(self, data: dict) -> str:
        title = _req(data, "title")
        status = data.get("status") or "backlog"
        if status not in STATUSES:
            raise WorkspaceError("status tidak valid")
        tid, now = new_id(), time.time()

        def run(db):
            p = self._project(db, data.get("project_id"))
            last = db.execute("SELECT MAX(position) FROM task WHERE project_id=? AND status=? AND archived=0 AND parent_id IS NULL",
                              (p["id"], status)).fetchone()[0]
            db.execute("""INSERT INTO task (id, number, project_id, parent_id, title, description, status, position, priority, assignee,
                          labels, due_date, blocked, blocked_reason, archived, started_at, completed_at, created_at, updated_at)
                          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,'',0,?,?,?,?)""",
                       (tid, p["next_number"], p["id"], data.get("parent_id") or None, title, _s(data.get("description")), status,
                        (last or 0) + 1024, _prio(data.get("priority")), _s(data.get("assignee")), json.dumps(_labels(data.get("labels"))),
                        _num(data.get("due_date")), now if status == "in_progress" else None, now if status == "done" else None, now, now))
            db.execute("UPDATE project SET next_number = next_number + 1 WHERE id=?", (p["id"],))
            self._event(db, p["id"], "task.created", f"{p['key'] or 'T'}-{p['next_number']} dibuat: {title}", {"task": tid})
        self._tx(run)
        return tid

    def update_task(self, tid: str, data: dict):
        fields = {k: data[k] for k in self.TASK_FIELDS if k in data}
        if "title" in fields:
            fields["title"] = _req(fields, "title")
        for b in ("blocked", "archived"):
            if b in fields:
                fields[b] = 1 if fields[b] else 0
        if "priority" in fields:
            fields["priority"] = _prio(fields["priority"])
        if "labels" in fields:
            fields["labels"] = json.dumps(_labels(fields["labels"]))
        if "due_date" in fields:
            fields["due_date"] = _num(fields["due_date"])
        for k in ("milestone_id", "epic_id"):
            if k in fields:
                fields[k] = fields[k] or None
        if "status" in data:
            self.move_task(tid, data["status"], None)
        if fields:
            self._update("task", tid, fields)

    def move_task(self, tid: str, status: str, before: str | None):
        """Moves a card to `status`, placed before card `before` (None = end). Renumbers the column
        in the same transaction when the gap is too small to split."""
        if status not in STATUSES:
            raise WorkspaceError("status tidak valid")
        if before == tid:
            return

        def run(db):
            old = self._task(db, tid)
            col = [dict(r) for r in db.execute(
                "SELECT id, position FROM task WHERE project_id=? AND status=? AND archived=0 AND parent_id IS NULL AND id<>? ORDER BY position",
                (old["project_id"], status, tid))]
            idx = next((i for i, c in enumerate(col) if c["id"] == before), None) if before else None
            pos = position([c["position"] for c in col], idx)
            if idx is not None:
                prev = col[idx - 1]["position"] if idx > 0 else None
                if prev is not None and abs(col[idx]["position"] - prev) < 1e-6:
                    order = [c["id"] for c in col]
                    order.insert(idx, tid)
                    for i, cid in enumerate(order):
                        if cid != tid:
                            db.execute("UPDATE task SET position=? WHERE id=?", ((i + 1) * 1024.0, cid))
                    pos = (order.index(tid) + 1) * 1024.0
            now = time.time()
            started, completed = old["started_at"], old["completed_at"]
            if status != old["status"]:
                if status == "in_progress" and started is None:
                    started = now
                completed = (completed or now) if status == "done" else None
            db.execute("UPDATE task SET status=?, position=?, started_at=?, completed_at=?, updated_at=? WHERE id=?",
                       (status, pos, started, completed, now, tid))
            if status != old["status"]:
                p = self._project(db, old["project_id"])
                code = f"{p['key'] or 'T'}-{old['number']}"
                if status == "done":
                    self._event(db, p["id"], "task.completed", f"{code} selesai: {old['title']}", {"task": tid, "from": old["status"], "to": status})
                else:
                    self._event(db, p["id"], "task.status", f"{code}: {STATUS_TITLE[old['status']]} → {STATUS_TITLE[status]}",
                                {"task": tid, "from": old["status"], "to": status})
        self._tx(run)

    def delete_task(self, tid: str):
        self._tx(lambda db: db.execute("DELETE FROM task WHERE id=?", (tid,)))

    # ── Generic update ──
    def _update(self, table: str, rid: str, fields: dict, after=None):
        if not fields:
            return

        def run(db):
            old = db.execute(f"SELECT * FROM {table} WHERE id=?", (rid,)).fetchone()
            if not old:
                raise WorkspaceError(f"{table} tidak ditemukan")
            cols = ", ".join(f"{k}=?" for k in fields)
            db.execute(f"UPDATE {table} SET {cols}, updated_at=? WHERE id=?", (*fields.values(), time.time(), rid))
            if after:
                after(db, dict(old))
        self._tx(run)

    def integrity_ok(self) -> bool:
        with self.lock:
            return self.db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"


# ── helpers ──
def _statements(sql: str):
    buf = []
    for line in sql.splitlines():
        if line.strip().startswith("--"):
            continue
        buf.append(line)
        if line.rstrip().endswith(";"):
            s = "\n".join(buf).strip()
            if s:
                yield s
            buf = []
    rest = "\n".join(buf).strip()
    if rest:
        yield rest


def _json(s, default):
    try:
        return json.loads(s) if s else default
    except (TypeError, ValueError):
        return default


def _s(v) -> str:
    return v.strip() if isinstance(v, str) else ""


def _req(d: dict, k: str) -> str:
    v = _s(d.get(k))
    if not v:
        raise WorkspaceError(f"{k} wajib diisi")
    if len(v) > 300:
        raise WorkspaceError(f"{k} terlalu panjang")
    return v


def _prio(v) -> int:
    try:
        return min(4, max(0, int(v or 0)))
    except (TypeError, ValueError):
        return 0


def _num(v):
    if v in (None, ""):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        raise WorkspaceError("tanggal tidak valid")


def _labels(v) -> list:
    if isinstance(v, str):
        v = v.split(",")
    return [s.strip() for s in v or [] if isinstance(s, str) and s.strip()][:20]


def _start_of_day(t: float) -> float:
    lt = time.localtime(t)
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
