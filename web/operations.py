"""Runtime side of operations for Raphael Web: health + backup probes, reboot detection,
internet probe, 30-day hourly metrics, incident history, WhatsApp notifications through
Hermes, the weekly report, and the allowed actions (logged)."""
from __future__ import annotations

import json
import os
import shlex
import sqlite3
import subprocess
import threading
import time
import traceback
import urllib.error
import urllib.request
from datetime import datetime

import ops

KEEP_HOURS = 30 * 24

HEALTH_SCRIPT = r'''
import glob, json, os, re, subprocess, sys
req = json.loads(sys.argv[1])
def sh(c, t=15):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""
o = {"bootId": open("/proc/sys/kernel/random/boot_id").read().strip(), "uptime": float(open("/proc/uptime").read().split()[0])}
o["mmcErrors"] = sum(1 for l in sh("journalctl -k -b --no-pager 2>/dev/null").splitlines() if re.search(r"mmc\d+.*(error|timeout|crc)", l, re.I))
o["rootRO"] = any(l.split()[1] == "/" and "ro" in l.split()[3].split(",") for l in open("/proc/mounts") if len(l.split()) > 3)
if req.get("knownBoot") and req["knownBoot"] != o["bootId"]:
    o["prevBoot"] = {
        "hints": sh("journalctl -b -1 --no-pager -o short-iso 2>/dev/null | grep -iE 'under-voltage|voltage normalised|watchdog|out of memory|oom-kill|thermal|panic|reboot|shutdown|power key' | tail -n 8"),
        "tail": sh("journalctl -b -1 -n 12 --no-pager -o short-iso 2>/dev/null"),
    }
out = []
for b in req.get("backups", []):
    files = sorted((f for f in glob.glob(b["glob"]) if os.path.isfile(f)), key=os.path.getmtime)
    files = [(f, os.path.getsize(f), os.path.getmtime(f)) for f in files[-5:]]
    out.append({"name": b["name"], "files": files, "count": len(glob.glob(b["glob"]))})
o["backups"] = out
print(json.dumps(o))
'''


def backup_problem(cfg: dict, info: dict | None, now: float) -> tuple:
    """(problem or None, detail) for one configured backup."""
    if info is None:
        return "tidak bisa dicek", "device tidak terjangkau"
    files = info.get("files") or []
    if not files:
        return "tidak ada file backup", cfg["glob"]
    path, size, mtime = files[-1]
    age_h = (now - mtime) / 3600
    if size < cfg.get("minBytes", 1):
        return f"file terbaru kosong/terlalu kecil ({size} B)", path
    if age_h > cfg.get("maxAgeHours", 26):
        return f"backup terakhir {age_h:.0f} jam lalu", path
    prev = [s for _, s, _ in files[:-1] if s >= cfg.get("minBytes", 1)]
    if prev and size < max(prev) * cfg.get("shrinkRatio", 0.5):
        return f"ukuran turun drastis ({size // 1024} KB vs {max(prev) // 1024} KB)", path
    return None, path


class Operations:
    def __init__(self, monitor, metrics, workspace, cfg: dict):
        self.mon, self.metrics, self.ws, self.cfg = monitor, metrics, workspace, cfg
        db = metrics.db
        with metrics.lock:
            db.execute("""CREATE TABLE IF NOT EXISTS incident (key TEXT, kind TEXT, node TEXT, title TEXT, detail TEXT,
                          started REAL, ended REAL)""")
            db.execute("CREATE INDEX IF NOT EXISTS incident_started ON incident(started)")
            db.execute("""CREATE TABLE IF NOT EXISTS sample_hour (node TEXT, t REAL, cpu REAL, cpu_max REAL, mem REAL, mem_max REAL,
                          temp REAL, temp_max REAL, disk REAL, load REAL, thr INTEGER, n INTEGER, PRIMARY KEY (node, t))""")
            db.execute("CREATE TABLE IF NOT EXISTS notify_log (t REAL, ok INTEGER, error TEXT, text TEXT)")
            db.execute("CREATE TABLE IF NOT EXISTS action_log (t REAL, node TEXT, kind TEXT, target TEXT, who TEXT, ok INTEGER, output TEXT)")
            open_rows = db.execute("SELECT rowid, key, kind, node, title, detail, started FROM incident WHERE ended IS NULL").fetchall()
        self.tracker = ops.Tracker({r[1]: {"rowid": r[0], "key": r[1], "kind": r[2], "node": r[3], "title": r[4], "detail": r[5], "started": r[6]}
                                    for r in open_rows})
        with metrics.lock:
            for key, ended in db.execute("SELECT key, max(ended) FROM incident WHERE ended IS NOT NULL AND ended > ? GROUP BY key", (time.time() - 86400,)):
                self.tracker.last_closed[key] = ended          # cooldowns survive a restart
        self.health: dict = metrics.get("health", {})
        self.backups: list = []
        self.internet_ok = True
        self.lock = threading.Lock()

    # ── probes ──
    def run_on(self, node: dict, cmd: str, timeout: int = 60) -> tuple:
        argv = ["sh", "-c", cmd] if node.get("local") else \
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", node["ssh"], cmd]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            return p.returncode, (p.stdout + p.stderr)
        except subprocess.TimeoutExpired:
            return -1, "timeout"
        except OSError as e:
            return -1, str(e)

    def probe_health(self):
        now = time.time()
        reboots = []
        for n in self.cfg["nodes"]:
            prev = self.health.get(n["id"]) or {}
            req = {"knownBoot": prev.get("bootId"), "backups": [b for b in self.cfg.get("backups", []) if b.get("node") == n["id"]]}
            code, out = self.run_on(n, "sudo -n python3 -c " + shlex.quote(HEALTH_SCRIPT) + " " + shlex.quote(json.dumps(req)), 60)
            line = next((l for l in reversed(out.splitlines()) if l.startswith("{")), None)
            if not line:
                continue
            h = json.loads(line)
            h["at"] = now
            if prev.get("bootId") and h["bootId"] != prev["bootId"]:
                pb = h.get("prevBoot") or {}
                hints = (pb.get("hints") or "").strip()
                reason = guess_reason(hints)
                when = datetime.fromtimestamp(now - h["uptime"]).strftime("%d %b %H:%M")
                detail = (reason + (" · " if reason and hints else "") + (hints.splitlines()[-1][:160] if hints else "")) or "penyebab tidak tercatat di log"
                reboots.append({"node": n["name"], "when": when, "detail": detail})
                self.record_event("reboot", f"reboot:{n['id']}", n["name"], f"{n['name']} restart sendiri", detail + "\n" + (pb.get("tail") or "")[-1500:],
                                  now - h["uptime"])
            self.health[n["id"]] = {k: h[k] for k in ("bootId", "uptime", "mmcErrors", "rootRO", "at")}
            for b in h.get("backups", []):
                b["node"] = n["id"]
                b["nodeName"] = n["name"]
            self._merge_backups(n["id"], h.get("backups", []), now)
        self.metrics.put("health", self.health)
        return reboots

    def _merge_backups(self, node_id: str, infos: list, now: float):
        with self.lock:
            keep = [b for b in self.backups if b["node"] != node_id]
            for cfg_b in [b for b in self.cfg.get("backups", []) if b.get("node") == node_id]:
                info = next((i for i in infos if i["name"] == cfg_b["name"]), None)
                problem, detail = backup_problem(cfg_b, info, now)
                files = (info or {}).get("files") or []
                keep.append({"name": cfg_b["name"], "node": node_id, "nodeName": next((n["name"] for n in self.cfg["nodes"] if n["id"] == node_id), node_id),
                             "problem": problem, "detail": detail, "latest": files[-1] if files else None,
                             "count": (info or {}).get("count", 0), "maxAgeHours": cfg_b.get("maxAgeHours", 26), "checkedAt": now})
            self.backups = keep

    def probe_internet(self) -> bool:
        for url in self.cfg.get("internetProbes", ["https://1.1.1.1/", "https://www.google.com/generate_204"]):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=6):
                    return True
            except urllib.error.HTTPError:
                return True                              # the internet answered
            except Exception:  # noqa: BLE001
                continue
        return False

    # ── incidents ──
    def record_event(self, kind, key, node, title, detail, t):
        with self.metrics.lock:
            self.metrics.db.execute("INSERT INTO incident VALUES (?,?,?,?,?,?,?)", (key, kind, node, title, detail, t, t))

    def evaluate(self, reboots: list | None = None):
        now = time.time()
        st = self.mon.state_light()
        conds = ops.conditions(self.cfg["nodes"], self.mon.detail, self.mon.last, st["sites"], self.mon.site_status, st["certs"],
                               self.backups, self.health, self.internet_ok, now)
        opened, closed = self.tracker.step(conds, now)
        with self.metrics.lock:
            for i in opened:
                cur = self.metrics.db.execute("INSERT INTO incident VALUES (?,?,?,?,?,?,NULL)", (i["key"], i["kind"], i["node"], i["title"], i["detail"], i["started"]))
                i["rowid"] = cur.lastrowid
                self.tracker.open[i["key"]]["rowid"] = cur.lastrowid
            for i in closed:
                if i.get("rowid"):
                    self.metrics.db.execute("UPDATE incident SET ended=? WHERE rowid=?", (i["ended"], i["rowid"]))
        text = ops.message(opened, closed, reboots or [], self.cfg.get("publicUrl", ""))
        if text:
            self.notify(text)

    def incidents(self, days: float = 30) -> list:
        with self.metrics.lock:
            rows = self.metrics.db.execute("SELECT rowid, key, kind, node, title, detail, started, ended FROM incident WHERE coalesce(ended, ?) >= ? ORDER BY started DESC LIMIT 500",
                                           (time.time(), time.time() - days * 86400)).fetchall()
        return [{"id": r[0], "key": r[1], "kind": r[2], "node": r[3], "title": r[4], "detail": r[5], "started": r[6], "ended": r[7]} for r in rows]

    # ── notifications ──
    def notify(self, text: str, force: bool = False) -> dict:
        n = self.cfg.get("notify") or {}
        if not (n.get("enabled") and n.get("target")) and not force:
            return {"ok": False, "error": "notifikasi nonaktif"}
        if not n.get("target"):
            return {"ok": False, "error": "target belum diatur"}
        if not force:
            with self.metrics.lock:
                sent = self.metrics.db.execute("SELECT count(*) FROM notify_log WHERE ok=1 AND t > ?", (time.time() - 3600,)).fetchone()[0]
            if sent >= int(n.get("maxPerHour", 6)):
                with self.metrics.lock:
                    self.metrics.db.execute("INSERT INTO notify_log VALUES (?,?,?,?)", (time.time(), 0, "ditahan: batas pesan per jam", text[:2000]))
                return {"ok": False, "error": "ditahan: batas pesan per jam"}
        hermes = os.path.expanduser(n.get("hermes") or "~/.local/bin/hermes")
        try:
            p = subprocess.run([hermes, "send", "--to", n["target"], "-q", text], capture_output=True, text=True, timeout=90)
            ok, err = p.returncode == 0, (p.stderr or p.stdout).strip()[-300:]
        except Exception as e:  # noqa: BLE001
            ok, err = False, str(e)
        with self.metrics.lock:
            self.metrics.db.execute("INSERT INTO notify_log VALUES (?,?,?,?)", (time.time(), 1 if ok else 0, None if ok else err, text[:2000]))
        return {"ok": ok, "error": None if ok else err}

    def notify_log(self, limit=30) -> list:
        with self.metrics.lock:
            rows = self.metrics.db.execute("SELECT t, ok, error, text FROM notify_log ORDER BY t DESC LIMIT ?", (limit,)).fetchall()
        return [{"t": r[0], "ok": bool(r[1]), "error": r[2], "text": r[3]} for r in rows]

    # ── metrics (hourly, 30 days) ──
    def rollup(self):
        hour = int(time.time() // 3600 * 3600)
        db = self.metrics.db
        with self.metrics.lock:
            last = db.execute("SELECT max(t) FROM sample_hour").fetchone()[0] or (hour - 25 * 3600)
            rows = db.execute("""SELECT node, CAST(t / 3600 AS INTEGER) * 3600 AS h, avg(cpu), max(cpu), avg(mem), max(mem), avg(temp), max(temp),
                                 max(disk), avg(load), max(coalesce(thr, 0)), count(*) FROM sample WHERE t >= ? AND t < ? GROUP BY node, h""",
                              (last + 3600, hour)).fetchall()
            for r in rows:
                db.execute("INSERT OR REPLACE INTO sample_hour VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", r)
            db.execute("DELETE FROM sample_hour WHERE t < ?", (hour - KEEP_HOURS * 3600,))

    def history30(self, node: str, days: int = 30) -> list:
        with self.metrics.lock:
            rows = self.metrics.db.execute("SELECT t, cpu, cpu_max, mem, mem_max, temp, temp_max, disk, load, thr FROM sample_hour WHERE node=? AND t>=? ORDER BY t",
                                           (node, time.time() - days * 86400)).fetchall()
        keys = ("t", "cpu", "cpuMax", "mem", "memMax", "temp", "tempMax", "disk", "load", "thr")
        return [dict(zip(keys, r)) for r in rows]

    # ── weekly report ──
    def report_text(self) -> str:
        now = time.time()
        st = self.mon.state_light()
        uptime = {}
        for s in st["sites"]:
            with self.metrics.lock:
                r = self.metrics.db.execute("SELECT avg(ok) FROM site_check WHERE url=?", (s["url"],)).fetchone()
            uptime[s["url"]] = r[0]
        temps = {}
        with self.metrics.lock:
            for n in self.cfg["nodes"]:
                r = self.metrics.db.execute("SELECT avg(temp), max(temp_max) FROM sample_hour WHERE node=? AND t>=?", (n["id"], now - 7 * 86400)).fetchone()
                if r and r[0]:
                    temps[n["id"]] = {"avg": r[0], "max": r[1]}
        tokens = None
        try:
            import hermes
            profs = hermes.profiles(self.cfg.get("hermesHome", "~/.hermes"))
            tokens = sum(sum(d["tokens"] for d in hermes.snapshot(p["path"]).get("days", [])) for p in profs)
        except Exception:  # noqa: BLE001
            pass
        snap = self.ws.snapshot()
        done = sum(1 for t in snap["tasks"] if t["completed_at"] and t["completed_at"] >= now - 7 * 86400)
        failed = sum(1 for i in self.incidents(7) if i["kind"] == "job")
        return ops.weekly_report(now, self.incidents(7), st["sites"], uptime, self.cfg["nodes"], temps, tokens, done, failed)

    def maybe_weekly(self):
        w = (self.cfg.get("notify") or {}).get("weekly")
        if not w:
            return
        now = datetime.now()
        key = now.strftime("%G-W%V")
        if now.weekday() == w.get("weekday", 0) and now.hour >= w.get("hour", 8) and self.metrics.get("weeklySent") != key:
            self.metrics.put("weeklySent", key)
            self.notify(self.report_text())

    # ── actions ──
    def action(self, node_id: str, kind: str, target: str, who: str) -> dict:
        node = next((n for n in self.cfg["nodes"] if n["id"] == node_id), None)
        if not node:
            raise ValueError("device tidak dikenal")
        cmd, desc = ops.action_command(kind, target, self.mon.detail.get(node_id) or {}, self.cfg)
        timeout = 900 if kind == "run-job" else 120
        code, out = self.run_on(node, cmd, timeout)
        ok = code == 0
        with self.metrics.lock:
            self.metrics.db.execute("INSERT INTO action_log VALUES (?,?,?,?,?,?,?)", (time.time(), node["name"], kind, target, who or "", 1 if ok else 0, out[-4000:]))
        threading.Thread(target=self.mon.sample, args=(node,), daemon=True).start()
        return {"ok": ok, "description": desc, "output": out[-4000:], "code": code}

    def logs(self, node_id: str, kind: str, target: str) -> dict:
        node = next((n for n in self.cfg["nodes"] if n["id"] == node_id), None)
        if not node:
            raise ValueError("device tidak dikenal")
        cmd = ops.logs_command(kind, target, self.mon.detail.get(node_id) or {})
        code, out = self.run_on(node, cmd, 30)
        return {"ok": code == 0, "output": out[-60000:]}

    def action_log(self, limit=50) -> list:
        with self.metrics.lock:
            rows = self.metrics.db.execute("SELECT t, node, kind, target, who, ok, output FROM action_log ORDER BY t DESC LIMIT ?", (limit,)).fetchall()
        return [{"t": r[0], "node": r[1], "kind": r[2], "target": r[3], "who": r[4], "ok": bool(r[5]), "output": r[6]} for r in rows]

    # ── loops ──
    def start(self):
        def loop(fn, every, delay, name):
            time.sleep(delay)
            while True:
                t0 = time.time()
                try:
                    fn()
                except Exception:
                    print(name, traceback.format_exc(), flush=True)
                time.sleep(max(5, every - (time.time() - t0)))

        def minute():
            self.internet_ok = self.probe_internet()
            self.evaluate()
            self.rollup()
            self.maybe_weekly()

        def ten():
            reboots = self.probe_health()
            if reboots:
                self.evaluate(reboots)

        threading.Thread(target=loop, args=(minute, 60, 45, "ops"), daemon=True).start()
        threading.Thread(target=loop, args=(ten, 600, 30, "health"), daemon=True).start()


def guess_reason(hints: str) -> str:
    h = hints.lower()
    if "under-voltage" in h:
        return "kemungkinan karena daya kurang (under-voltage)"
    if "out of memory" in h or "oom-kill" in h:
        return "kemungkinan karena RAM habis"
    if "watchdog" in h:
        return "kemungkinan sistem macet lalu direset watchdog"
    if "thermal" in h:
        return "kemungkinan karena terlalu panas"
    if "reboot" in h or "shutdown" in h or "power key" in h:
        return "restart/shutdown yang disengaja"
    return ""
