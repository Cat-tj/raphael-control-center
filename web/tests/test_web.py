"""Raphael Web tests: cron/job rules (same cases as Tests/main.swift), collector parsing,
alerts, the workspace store, and the HTTP API end to end (server started on a free port with
sampling off). Run: python3 -m unittest discover -s web/tests -v"""
import json
import os
import socket
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

WEB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, WEB)
import core  # noqa: E402
import files  # noqa: E402
import hermes  # noqa: E402
import operations  # noqa: E402
import ops  # noqa: E402
import server  # noqa: E402
from workspace import Workspace, WorkspaceError, make_key, position  # noqa: E402

SCHEMA = os.path.join(WEB, "schema")
REMOTE = os.path.join(WEB, "remote")
TZ = 8 * 3600
ZONE = timezone(timedelta(seconds=TZ))
BASE = datetime(2026, 10, 11, 19, 7, tzinfo=ZONE).timestamp()   # a Sunday


def hm(t):
    if t is None:
        return "nil"
    d = datetime.fromtimestamp(t, ZONE)
    return f"{d.day} {d.hour}:{d.minute} w{(d.weekday() + 1) % 7 + 1}"    # w = Calendar weekday (1 = Sunday)


class Cron(unittest.TestCase):
    def test_same_cases_as_swift(self):
        c = core.CronExpr.parse
        self.assertEqual(hm(c("30 2 * * *").next(BASE, TZ)), "12 2:30 w2")
        self.assertEqual(hm(c("30 2 * * *").previous(BASE, TZ)), "11 2:30 w1")
        self.assertEqual(hm(c("5-55/10 * * * *").next(BASE, TZ)), "11 19:15 w1")
        self.assertEqual(hm(c("0 8 * * 1").next(BASE, TZ)), "12 8:0 w2")
        self.assertEqual(hm(c("@hourly").next(BASE, TZ)), "11 20:0 w1")
        self.assertTrue(hm(c("0 0 1 * *").next(BASE, TZ)).startswith("1 0:0"))
        self.assertIsNone(c("bad expr"))
        self.assertIsNone(c("61 * * * *"))
        self.assertEqual(c("30 2 * * *").describe(), "tiap hari 02:30")

    def test_more_shapes(self):
        c = core.CronExpr.parse
        self.assertEqual(hm(c("*/15 * * * *").next(BASE, TZ)), "11 19:15 w1")
        self.assertEqual(hm(c("0 9 * * mon-fri").next(BASE, TZ)), "12 9:0 w2")       # names + range
        self.assertEqual(hm(c("0 0 * * 7").next(BASE, TZ)), "18 0:0 w1")             # 7 = Sunday
        self.assertEqual(hm(c("0 12 15 * 1").next(BASE, TZ)), "12 12:0 w2")          # dom OR dow
        self.assertEqual(c("0 8 * * 1").describe(), "tiap Senin 08:00")
        self.assertEqual(c("*/5 * * * *").describe(), "tiap 5 menit")
        self.assertEqual(hm(c("59 23 31 12 *").previous(BASE, TZ)), "31 23:59 w4")    # last year
        self.assertIsNone(c("* * * *"))
        self.assertIsNone(c("*/0 * * * *"))


class Jobs(unittest.TestCase):
    def test_health(self):
        now = time.time()
        stale = core.job({"kind": "cron", "id": "a", "name": "backup", "expr": "30 2 * * *", "last": now - 2 * 86400, "status": "ok"}, TZ, now)
        self.assertTrue(stale["missed"])
        self.assertEqual(stale["health"], "missed")
        failing = core.job({"kind": "cron", "id": "b", "name": "backup", "expr": "30 2 * * *", "status": "failed", "detail": "pg_dump: error"}, TZ, now)
        self.assertEqual(failing["health"], "failed")
        unknown = core.job({"kind": "cron", "id": "c", "name": "x", "expr": "*/5 * * * *"}, TZ, now)
        self.assertEqual(unknown["health"], "unknown")
        self.assertFalse(unknown["missed"])
        timer = core.job({"kind": "timer", "id": "t", "name": "t", "next": now + 600}, TZ, now)
        self.assertEqual(timer["health"], "scheduled")
        late = core.job({"kind": "timer", "id": "t", "name": "t", "next": now - 3600, "last": now - 7200, "status": "ok"}, TZ, now)
        self.assertEqual(late["health"], "missed")
        off = core.job({"kind": "cron", "id": "d", "name": "d", "expr": "* * * * *", "enabled": False, "status": "failed"}, TZ, now)
        self.assertEqual(off["health"], "disabled")

    def test_hermes_history_and_iso(self):
        j = core.job({"kind": "hermes", "id": "h", "name": "report", "expr": "0 8 * * *", "status": "ok",
                      "history": [["2026-10-11T08:00:02Z", "2026-10-11T08:01:00Z", "ok", ""]]}, TZ, BASE)
        self.assertAlmostEqual(j["last"], datetime(2026, 10, 11, 8, 0, 2, tzinfo=timezone.utc).timestamp())
        self.assertEqual(j["history"][0]["status"], "ok")


class Parse(unittest.TestCase):
    SAMPLE = {"cpu": 0.25, "mem": 0.5, "swap": 0.1, "load": 0.4, "cores": 4, "memTotal": 4 * 1073741824, "tz": TZ,
              "disks": [["/boot", 0.2, 0.5], ["/", 0.95, 58]], "throttled": "0x50005",
              "containers": [{"name": "web-app", "status": "Up 2 days", "cpu": 1.5, "mem": "120MiB"},
                             {"name": "bad", "status": "Restarting (1) 3s ago", "restarts": 9}],
              "failed": ["proxy.service"], "jobs": [{"kind": "cron", "id": "x", "name": "db-backup", "expr": "30 2 * * *", "status": "failed", "detail": "Connection refused"}],
              "tunnel": {"total": 100, "ha": 0, "hosts": ["example.com", "*.wild.example"]}, "security": 5, "updates": 30}

    def test_parse_and_alerts(self):
        d = core.parse(self.SAMPLE, now=BASE)
        self.assertEqual(d["disk"], 0.95)
        self.assertEqual(d["containers"][0]["name"], "bad")          # unhealthy first
        self.assertEqual(core.mem_bytes("120MiB"), 120 * 1048576)
        nodes = [{"id": "n", "name": "Box"}]
        a = core.alerts(nodes, {"n": d}, {"n": {"mem": 0.95, "swap": 0.6, "load": 7, "temp": 82}}, [], {}, {}, BASE)
        texts = " | ".join(x["text"] for x in a)
        for want in ("Disk / 95%", "RAM 95%", "Suhu 82", "undervoltage", "Load 7.0", "Container bad", "restart 9×",
                     "Service gagal: proxy", "db-backup gagal: Connection refused", "5 update keamanan", "tunnel tidak terhubung"):
            self.assertIn(want, texts)
        self.assertEqual(a[0]["level"], 2)                              # sorted bad first

    def test_unreachable_and_sites(self):
        a = core.alerts([{"id": "n", "name": "X"}], {"n": {"error": "timeout"}}, {}, [{"name": "s", "url": "https://s"}],
                        {"https://s": {"code": 502}}, {"https://s": BASE + 3 * 86400}, BASE)
        self.assertEqual([x["text"] for x in a][:1], ["Tidak bisa diambil datanya: timeout"])
        self.assertTrue(any("HTTP 502" in x["text"] for x in a))
        self.assertTrue(any("SSL habis 3 hari" in x["text"] and x["level"] == 2 for x in a))
        self.assertTrue(core.site_ok({"code": 301}))
        self.assertFalse(core.site_ok({"code": 200, "error": "x"}))

    def test_throttle(self):
        self.assertEqual(core.throttle_text("0x50005"), "sekarang: undervoltage, throttled · pernah: undervoltage, throttled")
        self.assertEqual(core.throttle_text("0x0"), "")


class Store(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.ws = Workspace(os.path.join(self.dir, "w.sqlite"), SCHEMA)

    def test_helpers_match_swift(self):
        self.assertEqual(position([], None), 1024)
        self.assertEqual(position([1024, 2048], 1), 1536)
        self.assertLess(position([1024], 0), 1024)
        self.assertEqual(make_key("raphael", set()), "RAP")
        self.assertEqual(make_key("Raphael Control Center", set()), "RCC")
        self.assertEqual(make_key("raphael", {"RAP"}), "RAP2")

    def test_crud_progress_and_persistence(self):
        pf = self.ws.create_portfolio({"name": "Studio"})
        pid = self.ws.create_project({"name": "Raphael Control Center", "portfolio_id": pf, "lifecycle": "building"})
        snap = self.ws.snapshot()
        self.assertIsNone(snap["projects"][0]["progress"])            # no tasks → belum terukur
        a = self.ws.create_task({"project_id": pid, "title": "A"})
        b = self.ws.create_task({"project_id": pid, "title": "B"})
        self.ws.move_task(a, "done", None)
        snap = self.ws.snapshot()
        p = snap["projects"][0]
        self.assertEqual((p["key"], p["next_number"], p["progress"]), ("RCC", 3, 0.5))
        t = {x["id"]: x for x in snap["tasks"]}
        self.assertEqual((t[a]["number"], t[b]["number"]), (1, 2))
        self.assertIsNotNone(t[a]["completed_at"])
        self.assertTrue(any(e["type"] == "task.completed" and "RCC-1 selesai" in e["title"] for e in snap["activity"]))
        # restart: a new store on the same file sees everything
        again = Workspace(os.path.join(self.dir, "w.sqlite"), SCHEMA).snapshot()
        self.assertEqual(len(again["tasks"]), 2)
        self.ws.update_project(pid, {"lifecycle": "live"})
        self.assertTrue(any(e["type"] == "project.lifecycle" for e in self.ws.snapshot()["activity"]))
        self.ws.delete_project(pid)
        self.assertEqual(self.ws.snapshot()["tasks"], [])                # cascade

    def test_move_order_and_renumber(self):
        pid = self.ws.create_project({"name": "P"})
        ids = [self.ws.create_task({"project_id": pid, "title": str(i)}) for i in range(3)]
        col = lambda: [t["title"] for t in sorted((t for t in self.ws.snapshot()["tasks"] if t["status"] == "ready"), key=lambda t: t["position"])]  # noqa: E731
        for i in ids:
            self.ws.move_task(i, "ready", None)
        self.assertEqual(col(), ["0", "1", "2"])
        self.ws.move_task(ids[2], "ready", ids[0])
        self.assertEqual(col(), ["2", "0", "1"])
        # exhaust the gap: always insert right before "0"
        for _ in range(60):
            self.ws.move_task(ids[1], "ready", ids[0])
            self.ws.move_task(ids[2], "ready", ids[1])
        self.assertEqual(col(), ["2", "1", "0"])
        pos = sorted(t["position"] for t in self.ws.snapshot()["tasks"])
        self.assertTrue(all(b - a > 1e-6 for a, b in zip(pos, pos[1:])))
        started = {t["id"]: t["started_at"] for t in self.ws.snapshot()["tasks"]}
        self.ws.move_task(ids[0], "in_progress", None)
        self.assertIsNotNone({t["id"]: t["started_at"] for t in self.ws.snapshot()["tasks"]}[ids[0]])
        self.assertIsNone(started[ids[0]])

    def test_validation(self):
        with self.assertRaises(WorkspaceError):
            self.ws.create_project({"name": "  "})
        with self.assertRaises(WorkspaceError):
            self.ws.create_project({"name": "x", "lifecycle": "nope"})
        pid = self.ws.create_project({"name": "x"})
        with self.assertRaises(WorkspaceError):
            self.ws.create_task({"project_id": pid, "title": "t", "status": "nope"})
        with self.assertRaises(WorkspaceError):
            self.ws.create_task({"project_id": "missing", "title": "t"})
        with self.assertRaises(WorkspaceError):
            self.ws.create_project({"name": "y", "key": "X"}) if self.ws.create_project({"name": "z", "key": "X"}) else None

    def test_replication_apply_is_sandboxed(self):
        bumps = []
        self.ws.on_change = lambda: bumps.append(1)
        now = time.time()
        n = self.ws.apply([
            {"sql": "INSERT INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
             "args": ["pf1", "Dari Mac; dengan titik koma", "", "violet", 0, 1, now, now]},
            {"sql": "INSERT INTO project (id, portfolio_id, name, key, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["p1", "pf1", "Mac", "MAC", now, now]},
            {"sql": "UPDATE project SET description=? WHERE id=?", "args": ["x", "p1"]},
        ])
        self.assertEqual((n, len(bumps)), (3, 1))
        self.assertEqual(self.ws.dump()["project"][0]["description"], "x")
        for bad in ["PRAGMA foreign_keys = OFF", "DROP TABLE task", "ATTACH DATABASE '/tmp/x.db' AS x", "CREATE TABLE evil (a)",
                    "DELETE FROM sqlite_master", "UPDATE project SET name='a' WHERE id='p1'; DROP TABLE task", "COMMIT"]:
            with self.assertRaises(WorkspaceError, msg=bad):
                self.ws.apply([{"sql": bad, "args": []}])
        # a failing batch leaves nothing behind
        with self.assertRaises(WorkspaceError):
            self.ws.apply([{"sql": "UPDATE project SET name=? WHERE id=?", "args": ["ganti", "p1"]}, {"sql": "INSERT INTO nope VALUES (1)", "args": []}])
        self.assertEqual(self.ws.dump()["project"][0]["name"], "Mac")
        self.assertIn("task", self.ws.tables())
        # deferred foreign keys: a child before its parent in one batch is fine, a dangling one is not
        self.ws.apply([{"sql": "INSERT INTO task (id, number, project_id, parent_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?,?)", "args": ["t2", 2, "p1", "t1", "anak", now, now]},
                       {"sql": "INSERT INTO task (id, number, project_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["t1", 1, "p1", "induk", now, now]}])
        with self.assertRaises(WorkspaceError):
            self.ws.apply([{"sql": "INSERT INTO task (id, number, project_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["t3", 3, "missing", "x", now, now]}])

    def test_reads_mac_app_database(self):
        # A workspace.sqlite written by the Mac app opens unchanged (same schema, user_version 1).
        db = sqlite3.connect(os.path.join(self.dir, "w.sqlite"))
        self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)
        cols = {r[1] for r in db.execute("PRAGMA table_info(task)")}
        self.assertTrue({"position", "blocked_reason", "started_at", "completed_at"} <= cols)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Http(unittest.TestCase):
    """The HTTP contract. Runs against the Python server, or against another implementation
    (the Rust binary) when RAPHAEL_WEB_BIN points at it."""

    @classmethod
    def setUpClass(cls):
        d = tempfile.mkdtemp()
        cfg = {"port": free_port(), "data": d, "nodes": [{"id": "local", "name": "Test", "local": True}],
               "sites": [{"name": "x", "url": "https://example.invalid"}], "envFiles": []}
        cls.base = f"http://127.0.0.1:{cfg['port']}"
        cls.external = os.environ.get("RAPHAEL_WEB_BIN")
        if cls.external:
            import subprocess
            path = os.path.join(d, "config.json")
            with open(path, "w") as f:
                json.dump(cfg, f)
            cls.proc = subprocess.Popen([cls.external, "--config", path, "--no-sampling", "--static", os.path.join(WEB, "static")],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                try:
                    urllib.request.urlopen(cls.base + "/healthz", timeout=1)
                    break
                except Exception:
                    time.sleep(0.05)
            cls.app = None
        else:
            cls.app = server.App(cfg)
            cls.srv = server.ThreadingHTTPServer(("127.0.0.1", cfg["port"]), server.make_handler(cls.app))
            threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        if cls.external:
            cls.proc.terminate()
            cls.proc.wait(5)
        else:
            cls.srv.shutdown()

    def req(self, method, path, body=None, headers=None):
        h = {"X-Raphael": "1", "Content-Type": "application/json"} if headers is None else headers
        r = urllib.request.Request(self.base + path, method=method, data=json.dumps(body).encode() if body is not None else None, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status, json.loads(resp.read() or b"null"), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null"), dict(e.headers)

    def test_state_and_static(self):
        code, st, h = self.req("GET", "/api/state", headers={})
        self.assertEqual(code, 200)
        self.assertEqual(st["nodes"][0]["name"], "Test")
        self.assertIn("frame-ancestors 'none'", h["Content-Security-Policy"])
        with urllib.request.urlopen(self.base + "/", timeout=5) as r:
            page = r.read()
            self.assertIn(b"<title>", page)
            self.assertIn(b'app.js?v=', page)                          # cache-busted assets
        with urllib.request.urlopen(self.base + "/app.js?v=1", timeout=5) as r:
            self.assertIn("javascript", r.headers["Content-Type"])
        with urllib.request.urlopen(self.base + "/../../server.py", timeout=5) as r:     # traversal → index.html
            self.assertIn(b"<title>", r.read())

    def test_workspace_flow(self):
        code, r, _ = self.req("POST", "/api/project", {"name": "Web Test"})
        self.assertEqual(code, 201)
        pid = r["id"]
        code, r, _ = self.req("POST", "/api/task", {"project_id": pid, "title": "Kartu"})
        tid = r["id"]
        self.assertEqual(self.req("POST", f"/api/task/{tid}/move", {"status": "review"})[0], 200)
        self.assertEqual(self.req("PATCH", f"/api/task/{tid}", {"title": "Kartu 2", "priority": 3})[0], 200)
        snap = self.req("GET", "/api/workspace", headers={})[1]
        t = next(x for x in snap["tasks"] if x["id"] == tid)
        self.assertEqual((t["status"], t["title"], t["priority"]), ("review", "Kartu 2", 3))
        self.assertEqual(self.req("POST", "/api/task", {"project_id": pid, "title": ""})[0], 400)
        self.assertEqual(self.req("DELETE", f"/api/project/{pid}")[0], 200)

    def test_csrf_guard(self):
        self.assertEqual(self.req("POST", "/api/project", {"name": "x"}, headers={"Content-Type": "application/json"})[0], 403)
        self.assertEqual(self.req("POST", "/api/project", {"name": "x"}, headers={"X-Raphael": "1", "Content-Type": "text/plain"})[0], 403)
        self.assertEqual(self.req("POST", "/api/project", {"name": "x"},
                                  headers={"X-Raphael": "1", "Content-Type": "application/json", "Origin": "https://evil.example"})[0], 403)

    def test_new_endpoints(self):
        self.assertEqual(self.req("GET", "/api/raw?node=local", headers={})[0], 404)          # nothing sampled yet
        if self.app:
            self.app.monitor.raw_line["local"] = {"at": 1, "raw": {"cpu": 0.1}}
            code, r, _ = self.req("GET", "/api/raw?node=local", headers={})
            self.assertEqual((code, r["raw"]["cpu"]), (200, 0.1))
        code, r, _ = self.req("GET", "/api/files?node=local&path=" + urllib.request.quote(WEB), headers={})
        self.assertIn("server.py", [i["name"] for i in r["items"]])
        self.assertEqual(self.req("GET", "/api/files?node=nope&path=/", headers={})[0], 404)
        code, r, _ = self.req("GET", "/api/agents", headers={})
        self.assertEqual(code, 200)
        self.assertEqual(self.req("GET", "/api/omniroute", headers={})[1]["state"], "idle")

    def test_replication_endpoints(self):
        rev0 = self.req("GET", "/api/ws/rev", headers={})[1]["rev"]
        now = time.time()
        code, r, _ = self.req("POST", "/api/ws/apply", {"baseRev": rev0, "statements": [
            {"sql": "INSERT INTO portfolio (id, name, created_at, updated_at) VALUES (?,?,?,?)", "args": ["pfx", "Sync", now, now]}]})
        self.assertEqual((code, r["applied"], r["rev"], r["clean"]), (200, 1, rev0 + 1, True))
        dump = self.req("GET", "/api/ws/dump", headers={})[1]
        self.assertEqual(dump["rev"], rev0 + 1)
        self.assertIn("pfx", [p["id"] for p in dump["tables"]["portfolio"]])
        self.assertEqual(self.req("POST", "/api/ws/apply", {"statements": [{"sql": "DROP TABLE task", "args": []}]})[0], 400)
        self.assertEqual(self.req("POST", "/api/ws/apply", {"statements": []}, headers={"Content-Type": "application/json"})[0], 403)

    def test_bad_json(self):
        r = urllib.request.Request(self.base + "/api/project", method="POST", data=b"{nope", headers={"X-Raphael": "1", "Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(r, timeout=5)
        self.assertEqual(e.exception.code, 400)


class Env(unittest.TestCase):
    def test_parse_env_and_token_order(self):
        env = server.parse_env('export A=1\n# c\nCLOUDFLARE_API_TOKEN="x"\napi token full = y\n')
        self.assertEqual(env["A"], "1")
        self.assertEqual(env["CLOUDFLARE_API_TOKEN"], "x")
        self.assertEqual(env["API_TOKEN_FULL"], "y")
        d = tempfile.mkdtemp()
        p = os.path.join(d, ".env")
        with open(p, "w") as f:
            f.write("CLOUDFLARE_API_TOKEN=old\nCLOUDFLARE_API_TOKEN_FULL=new\n")
        m = server.Monitor({"nodes": [], "envFiles": [p]}, server.Metrics(os.path.join(d, "m.sqlite")), "")
        self.assertEqual([t for _, t in m.cf_tokens()], ["new", "old"])                 # FULL first


class Persist(unittest.TestCase):
    def test_last_state_survives_restart(self):
        d = tempfile.mkdtemp()
        cfg = {"nodes": [{"id": "a", "name": "A", "local": True}], "sites": []}
        m = server.Monitor(cfg, server.Metrics(os.path.join(d, "m.sqlite")), "")
        m.detail["a"] = core.parse(Parse.SAMPLE, now=BASE)
        m.site_status["https://x"] = {"code": 200, "ok": True}
        m.persist()
        again = server.Monitor(cfg, server.Metrics(os.path.join(d, "m.sqlite")), "")
        self.assertEqual(again.detail["a"]["disk"], 0.95)
        self.assertTrue(again.site_status["https://x"]["ok"])
        gone = server.Monitor({"nodes": [], "sites": []}, server.Metrics(os.path.join(d, "m.sqlite")), "")
        self.assertEqual(gone.detail, {})                               # removed devices are dropped


class Files(unittest.TestCase):
    def test_secret_names(self):
        for p in ["~/.hermes/.env", "/etc/app/db.env", "/home/u/.ssh/config", "/srv/x/server.key", "cert.pem", "api_token.txt",
                  "/home/u/.git-credentials", "/home/u/.ssh/", "id_ed25519.pub"]:
            self.assertTrue(files.is_secret(p), p)
        for p in ["/etc/caddy/Caddyfile", "/var/log/syslog", "~/notes.md", "/etc/nginx/nginx.conf"]:
            self.assertFalse(files.is_secret(p), p)

    def test_list_read_and_symlink_guard(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "a.txt"), "w") as f:
            f.write("halo")
        with open(os.path.join(d, ".env"), "w") as f:
            f.write("SECRET=1")
        os.symlink(os.path.join(d, ".env"), os.path.join(d, "innocent.txt"))
        node = {"local": True}
        lst = files.run(node, "list", d)
        names = {i["name"]: i for i in lst["items"]}
        self.assertTrue(names[".env"]["secret"])
        self.assertFalse(names["a.txt"]["secret"])
        self.assertEqual(files.run(node, "read", os.path.join(d, "a.txt"))["text"], "halo")
        self.assertIn("rahasia", files.run(node, "read", os.path.join(d, ".env"))["error"])
        self.assertIn("rahasia", files.run(node, "read", os.path.join(d, "innocent.txt"))["error"])   # via symlink
        self.assertIn("error", files.run(node, "read", os.path.join(d, "missing")))


class Hermes(unittest.TestCase):
    def test_snapshot_from_state_db(self):
        home = tempfile.mkdtemp()
        db = sqlite3.connect(os.path.join(home, "state.db"))
        db.executescript("""CREATE TABLE sessions (id TEXT, title TEXT, display_name TEXT, source TEXT, model TEXT, parent_session_id TEXT,
            started_at REAL, last_activity_at REAL, ended_at REAL, message_count INT, tool_call_count INT, api_call_count INT,
            input_tokens INT, cache_read_tokens INT, output_tokens INT, actual_cost_usd REAL, estimated_cost_usd REAL, hidden INT DEFAULT 0);""")
        now = time.time()
        db.execute("INSERT INTO sessions VALUES ('s1','Chat A','', 'whatsapp','gpt',NULL,?,?,NULL,4,2,3,100,50,20,NULL,0.01,0)", (now - 60, now - 30))
        db.execute("INSERT INTO sessions VALUES ('s2','','Old', 'cli','gpt',NULL,?,?,?,1,0,1,10,0,5,NULL,NULL,0)", (now - 30 * 86400,) * 3)
        db.commit()
        db.close()
        s = hermes.snapshot(home, now)
        self.assertEqual(s["allTime"]["sessions"], 2)
        self.assertEqual(s["today"]["tokens"], 170)
        self.assertEqual(s["recent"][0]["title"], "Chat A")
        self.assertTrue(s["recent"][0]["active"])
        self.assertEqual(s["models"], [])                                # no session_model_usage table: tolerated
        self.assertEqual(hermes.profiles(home)[0]["id"], "default")
        self.assertIn("error", hermes.snapshot(tempfile.mkdtemp()))


class Ops(unittest.TestCase):
    NODES = [{"id": "a", "name": "Box A"}, {"id": "b", "name": "Box B"}]

    def conds(self, **kw):
        base = dict(nodes=self.NODES, details={"a": core.parse(Parse.SAMPLE, now=BASE), "b": {"error": "timeout"}},
                    last={"a": {"temp": 82}}, sites=[{"name": "S", "url": "https://s"}], site_status={"https://s": {"code": 502, "ok": False}},
                    certs={"https://s": BASE + 3 * 86400}, backups=[{"name": "DB", "nodeName": "Box A", "problem": "backup terakhir 40 jam lalu"}],
                    health={"a": {"mmcErrors": 2}}, internet_ok=True, now=BASE)
        base.update(kw)
        return ops.conditions(**base)

    def test_conditions(self):
        c = self.conds()
        kinds = {v["kind"] for v in c.values()}
        self.assertTrue({"node", "temp", "power", "disk", "job", "site", "ssl", "backup", "sdcard"} <= kinds, kinds)
        self.assertIn("node:b", c)
        offline = self.conds(internet_ok=False)
        self.assertIn("internet", offline)
        self.assertFalse(any(k.startswith("site:") for k in offline))       # website status held while offline

    def test_tracker_hysteresis_and_message(self):
        tr = ops.Tracker()
        site = {"site:https://s": {"kind": "site", "node": "S", "title": "S down", "detail": "HTTP 502"}}
        self.assertEqual(tr.step(site, 0), ([], []))                         # 1st bad check: not yet
        opened, _ = tr.step(site, 60)
        self.assertEqual([i["key"] for i in opened], ["site:https://s"])
        self.assertEqual(tr.step(site, 120), ([], []))                       # still open, no repeat
        _, closed = tr.step({}, 900)
        self.assertEqual(closed[0]["ended"] - closed[0]["started"], 840)
        msg = ops.message(opened, closed, [{"node": "Box A", "when": "13 Okt 16:30", "detail": "kemungkinan karena terlalu panas"}], "https://x")
        self.assertIn("*S down*", msg)
        self.assertIn("Pulih: S down (setelah 14 menit)", msg)
        self.assertIn("restart sendiri", msg)
        self.assertIsNone(ops.message([], [], []))
        flap = ops.Tracker()
        flap.step(site, 0)
        flap.step({}, 60)
        self.assertEqual(flap.step(site, 120), ([], []))                     # a blip resets the streak

    def test_flapping_is_damped(self):
        tr = ops.Tracker()
        p = {"power:a": {"kind": "power", "node": "A", "title": "A undervoltage", "detail": ""}}
        tr.step(p, 0)
        opened, _ = tr.step(p, 60)
        self.assertFalse(opened[0]["quiet"])
        for i in range(9):                                                   # 9 clean minutes: still open
            self.assertEqual(tr.step({}, 120 + i * 60), ([], []))
        _, closed = tr.step({}, 720)
        self.assertEqual(len(closed), 1)
        tr.step(p, 800)
        again, _ = tr.step(p, 860)                                           # recurrence within 6 h: recorded, quiet
        self.assertTrue(again[0]["quiet"])
        self.assertIsNone(ops.message(again, [], []))

    def test_backup_problem(self):
        cfg = {"name": "DB", "glob": "/x/*.dump", "maxAgeHours": 26, "minBytes": 1000}
        now = BASE
        self.assertEqual(operations.backup_problem(cfg, {"files": []}, now)[0], "tidak ada file backup")
        self.assertIn("kosong", operations.backup_problem(cfg, {"files": [["/x/a", 0, now]]}, now)[0])
        self.assertIn("40 jam", operations.backup_problem(cfg, {"files": [["/x/a", 5000, now - 40 * 3600]]}, now)[0])
        self.assertIn("turun drastis", operations.backup_problem(cfg, {"files": [["/x/a", 9000, now - 90000], ["/x/b", 2000, now]]}, now)[0])
        self.assertIsNone(operations.backup_problem(cfg, {"files": [["/x/a", 9000, now - 90000], ["/x/b", 9100, now - 3600]]}, now)[0])
        self.assertEqual(operations.backup_problem(cfg, None, now)[0], "tidak bisa dicek")

    def test_actions_are_allowlisted_and_quoted(self):
        detail = {"services": [{"unit": "app.service", "user": True}], "failed": ["nginx.service"],
                  "containers": [{"name": "web-1"}],
                  "jobs": [{"id": "c1", "kind": "cron", "name": "backup", "command": "echo 'hi'; rm -rf /tmp/x", "user": "root", "system": False},
                           {"id": "s1", "kind": "cron", "name": "logrotate", "command": "x", "system": True},
                           {"id": "hermes:michael:abc123", "kind": "hermes", "name": "seo", "system": False}]}
        cfg = {"actions": {"services": ["caddy"], "containers": True, "jobs": True}}
        self.assertEqual(ops.action_command("restart-service", "app.service", detail, cfg)[0], "systemctl --user restart app.service")
        self.assertEqual(ops.action_command("restart-service", "nginx.service", detail, cfg)[0], "sudo -n systemctl restart nginx.service")
        self.assertEqual(ops.action_command("restart-service", "caddy", detail, cfg)[0], "sudo -n systemctl restart caddy.service")
        with self.assertRaises(ValueError):
            ops.action_command("restart-service", "sshd", detail, cfg)                    # not allowed
        with self.assertRaises(ValueError):
            ops.action_command("restart-service", "x; reboot", detail, cfg)               # injection
        self.assertEqual(ops.action_command("restart-container", "web-1", detail, cfg)[0], "docker restart web-1")
        with self.assertRaises(ValueError):
            ops.action_command("restart-container", "web-1", detail, {"actions": {}})     # containers not enabled
        cmd = ops.action_command("run-job", "c1", detail, cfg)[0]
        self.assertEqual(cmd, "sudo -n -u root sh -c 'echo '\"'\"'hi'\"'\"'; rm -rf /tmp/x'")
        with self.assertRaises(ValueError):
            ops.action_command("run-job", "s1", detail, cfg)                              # system job
        self.assertIn("HERMES_HOME=~/.hermes/profiles/michael", ops.action_command("run-job", "hermes:michael:abc123", detail, cfg)[0])
        with self.assertRaises(ValueError):
            ops.logs_command("container", "other", detail)
        self.assertIn("journalctl --user -u app.service", ops.logs_command("service", "app", detail))

    def test_weekly_report_and_reason(self):
        now = BASE
        inc = [{"kind": "site", "title": "S down", "started": now - 3600, "ended": now - 3000}, {"kind": "job", "title": "Job x gagal", "started": now - 100, "ended": None}]
        r = ops.weekly_report(now, inc, [{"name": "S", "url": "https://s"}], {"https://s": 0.995}, self.NODES, {"a": {"avg": 61, "max": 79}}, 123456, 4, 1)
        for want in ("Laporan mingguan", "S 99.5%", "Insiden: 2", "10 menit", "masih terbuka", "Box A: rata-rata 61°C", "123.456", "Task selesai: 4"):
            self.assertIn(want, r)
        self.assertIn("under-voltage", operations.guess_reason("kernel: Under-voltage detected!"))
        self.assertIn("watchdog", operations.guess_reason("watchdog: watchdog0: ..."))

    def test_rollup_and_incident_store(self):
        d = tempfile.mkdtemp()
        cfg = {"nodes": [{"id": "a", "name": "A", "local": True}], "sites": [], "data": d}
        app = server.App({**cfg, "port": 0})
        m = app.metrics
        h = int(time.time() // 3600 * 3600) - 3 * 3600
        for i in range(6):
            m.add_sample("a", {"t": h + i * 600, "cpu": 0.1 * i, "mem": 0.5, "swap": 0, "disk": 0.4, "load": 1, "temp": 60 + i, "rx": 0, "tx": 0, "thr": 1 if i == 3 else 0})
        app.ops.rollup()
        rows = app.ops.history30("a")
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["tempMax"], rows[0]["thr"]), (65, 1))
        app.ops.record_event("reboot", "reboot:a", "A", "A restart sendiri", "x", time.time() - 10)
        self.assertEqual(app.ops.incidents(1)[0]["kind"], "reboot")
        self.assertEqual(app.ops.notify("hi")["error"], "notifikasi nonaktif")


class Collector(unittest.TestCase):
    def test_collector_python_compiles(self):
        # A syntax error here makes every device look unreachable (and pages someone).
        s = open(os.path.join(REMOTE, "collector_linux.sh"), encoding="utf-8").read()
        body = s.split("<<'RAPHAEL_PY'\n", 1)[1].rsplit("RAPHAEL_PY", 1)[0]
        compile(body.replace("__SLOW__", "0"), "collector_linux", "exec")
        import files as f, operations as o
        compile(f.SCRIPT, "files", "exec")
        compile(o.HEALTH_SCRIPT, "health", "exec")

    def test_collector_shape(self):
        s = open(os.path.join(REMOTE, "collector_linux.sh"), encoding="utf-8").read()
        self.assertTrue(s.startswith("python3 - <<'RAPHAEL_PY'"))
        self.assertIn("__SLOW__", s)
        self.assertTrue(s.rstrip().endswith("RAPHAEL_PY"))


if __name__ == "__main__":
    unittest.main()
