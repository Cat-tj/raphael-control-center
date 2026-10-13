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
import server  # noqa: E402
from workspace import Workspace, WorkspaceError, make_key, position  # noqa: E402

BUILD = os.path.join(WEB, "build")
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
        self.ws = Workspace(os.path.join(self.dir, "w.sqlite"), BUILD)

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
        again = Workspace(os.path.join(self.dir, "w.sqlite"), BUILD).snapshot()
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
    @classmethod
    def setUpClass(cls):
        d = tempfile.mkdtemp()
        cfg = {"port": free_port(), "data": d, "nodes": [{"id": "local", "name": "Test", "local": True}],
               "sites": [{"name": "x", "url": "https://example.invalid"}], "envFiles": []}
        cls.app = server.App(cfg)
        cls.srv = server.ThreadingHTTPServer(("127.0.0.1", cfg["port"]), server.make_handler(cls.app))
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cfg['port']}"

    @classmethod
    def tearDownClass(cls):
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
        self.app.monitor.raw_line["local"] = {"at": 1, "raw": {"cpu": 0.1}}
        code, r, _ = self.req("GET", "/api/raw?node=local", headers={})
        self.assertEqual((code, r["raw"]["cpu"]), (200, 0.1))
        code, r, _ = self.req("GET", "/api/files?node=local&path=" + urllib.request.quote(WEB), headers={})
        self.assertIn("server.py", [i["name"] for i in r["items"]])
        self.assertEqual(self.req("GET", "/api/files?node=nope&path=/", headers={})[0], 404)
        code, r, _ = self.req("GET", "/api/agents", headers={})
        self.assertEqual(code, 200)
        self.assertEqual(self.req("GET", "/api/omniroute", headers={})[1]["state"], "idle")

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


class Collector(unittest.TestCase):
    def test_extracted_from_swift(self):
        s = open(os.path.join(BUILD, "collector_linux.sh"), encoding="utf-8").read()
        self.assertTrue(s.startswith("python3 - <<'RAPHAEL_PY'"))
        self.assertIn("__SLOW__", s)
        self.assertTrue(s.rstrip().endswith("RAPHAEL_PY"))


if __name__ == "__main__":
    unittest.main()
