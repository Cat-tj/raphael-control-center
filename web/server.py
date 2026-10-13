#!/usr/bin/env python3
"""Raphael Web — the Control Center's Monitor and Workspace as a small web app.

Runs on one always-on Linux box (stdlib only), samples the configured devices with the same
collector the Mac app uses, checks websites, reads Cloudflare analytics, and serves the
workspace (portfolios, projects, Kanban) from a workspace.sqlite in the Mac app's format.

Listens on 127.0.0.1 only; expose it with `tailscale serve` (tailnet only). Nothing here runs
commands on request: sampling is the only thing that executes, on a fixed schedule.

  python3 server.py [--config ~/.config/raphael-web/config.json]
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import core  # noqa: E402
from workspace import Workspace, WorkspaceError  # noqa: E402

VERSION = "0.1.0"
KEEP = 24 * 3600
CF_ENV_KEYS = ["CLOUDFLARE_API_TOKEN_FULL", "CF_API_TOKEN_FULL", "API_TOKEN_FULL", "CLOUDFLARE_ANALYTICS_TOKEN",
               "CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ── Config ────────────────────────────────────────────────────────────────────

def load_config(path: str) -> dict:
    cfg = {"port": 8790, "nodes": [{"id": "local", "name": socket.gethostname(), "local": True}], "sites": [],
           "data": os.path.expanduser("~/.local/share/raphael-web"), "envFiles": ["~/.hermes/.env"]}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    cfg["data"] = os.path.expanduser(cfg["data"])
    os.makedirs(cfg["data"], exist_ok=True)
    return cfg


def parse_env(text: str) -> dict:
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k.strip().upper().replace(" ", "_")] = v
    return out


# ── Metrics store (24 h) ──────────────────────────────────────────────────────

class Metrics:
    def __init__(self, path: str):
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS sample (node TEXT, t REAL, cpu REAL, mem REAL, swap REAL, disk REAL,
                           load REAL, temp REAL, rx REAL, tx REAL, req REAL)""")
        self.db.execute("CREATE INDEX IF NOT EXISTS sample_node_t ON sample(node, t)")
        self.db.execute("CREATE TABLE IF NOT EXISTS site_check (url TEXT, t REAL, code INTEGER, ms INTEGER, ok INTEGER)")
        self.db.execute("CREATE INDEX IF NOT EXISTS site_url_t ON site_check(url, t)")
        self.db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")

    def add_sample(self, node: str, s: dict):
        with self.lock:
            self.db.execute("INSERT INTO sample VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                            (node, s["t"], s["cpu"], s["mem"], s["swap"], s["disk"], s["load"], s.get("temp"), s["rx"], s["tx"], s.get("req")))
            self.db.execute("DELETE FROM sample WHERE t < ?", (time.time() - KEEP,))

    def samples(self, node: str, hours: float) -> list:
        with self.lock:
            rows = self.db.execute("SELECT t, cpu, mem, swap, disk, load, temp, rx, tx, req FROM sample WHERE node=? AND t>=? ORDER BY t",
                                   (node, time.time() - hours * 3600)).fetchall()
        keys = ("t", "cpu", "mem", "swap", "disk", "load", "temp", "rx", "tx", "req")
        return [dict(zip(keys, r)) for r in rows]

    def add_check(self, url: str, t: float, code: int, ms: int, ok: bool):
        with self.lock:
            self.db.execute("INSERT INTO site_check VALUES (?,?,?,?,?)", (url, t, code, ms, 1 if ok else 0))
            self.db.execute("DELETE FROM site_check WHERE t < ?", (time.time() - KEEP,))

    def checks(self, url: str, hours: float = 24) -> list:
        with self.lock:
            rows = self.db.execute("SELECT t, code, ms, ok FROM site_check WHERE url=? AND t>=? ORDER BY t", (url, time.time() - hours * 3600)).fetchall()
        return [{"t": r[0], "code": r[1], "ms": r[2], "ok": bool(r[3])} for r in rows]

    def get(self, key: str, default=None):
        with self.lock:
            r = self.db.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        return json.loads(r[0]) if r else default

    def put(self, key: str, value):
        with self.lock:
            self.db.execute("INSERT INTO kv VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, json.dumps(value)))


# ── Monitor ───────────────────────────────────────────────────────────────────

class Monitor:
    def __init__(self, cfg: dict, metrics: Metrics, collector: str):
        self.cfg, self.metrics, self.collector = cfg, metrics, collector
        self.nodes = cfg["nodes"]
        self.detail: dict = {}
        self.last: dict = {}
        self.raw: dict = {}
        self.last_slow: dict = {}
        self.failures: dict = {}
        self.sampling: set = set()
        self.site_status: dict = {}
        self.certs: dict = {k: v for k, v in metrics.get("certs", {}).items() if "://" not in k}
        self.cert_checked: dict = {}
        self.cloudflare = {"state": "idle", "zones": [], "tried": [], "loadedAt": None}
        self.lock = threading.Lock()
        # Last known state survives a restart (shown until the first new sample arrives).
        saved = metrics.get("last", {})
        ids = {n["id"] for n in self.nodes}
        self.detail = {k: v for k, v in (saved.get("detail") or {}).items() if k in ids}
        self.last = {k: v for k, v in (saved.get("last") or {}).items() if k in ids}
        self.site_status = saved.get("sites") or {}

    def persist(self):
        self.metrics.put("last", {"detail": self.detail, "last": self.last, "sites": self.site_status})

    # Devices
    def run_collector(self, node: dict, slow: bool) -> tuple:
        script = self.collector.replace("__SLOW__", "1" if slow else "0")
        if node.get("local"):
            cmd = ["sh", "-s"]
        else:
            cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", node["ssh"], "sh -s"]
        try:
            p = subprocess.run(cmd, input=script, capture_output=True, text=True, timeout=45)
            return p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            return "timeout", -1
        except OSError as e:
            return str(e), -1

    def sample(self, node: dict):
        nid = node["id"]
        with self.lock:
            if nid in self.sampling:
                return
            self.sampling.add(nid)
        try:
            now = time.time()
            slow = now - self.last_slow.get(nid, 0) > 1800
            out, _ = self.run_collector(node, slow)
            line = next((l for l in reversed(out.splitlines()) if l.startswith("{")), None)
            try:
                j = json.loads(line) if line else None
            except ValueError:
                j = None
            if not isinstance(j, dict):
                self.failures[nid] = self.failures.get(nid, 0) + 1
                prev = dict(self.detail.get(nid) or {})
                prev["error"] = "Tidak terhubung" if not out.strip() else out.strip()[-160:]
                prev["at"] = now
                prev.setdefault("jobs", [])
                prev.setdefault("disks", [])
                prev.setdefault("containers", [])
                self.detail[nid] = prev
                return
            self.failures[nid] = 0
            if slow:
                self.last_slow[nid] = now
            d = core.parse(j, now=now, previous=self.detail.get(nid), slow=slow)
            rx, tx = float(j.get("rx") or 0), float(j.get("tx") or 0)
            req = d["tunnel"]["total"] if d.get("tunnel") else None
            s = {"t": now, "cpu": d["cpu"], "mem": d["mem"], "swap": d["swap"], "disk": d["disk"], "load": d["load"],
                 "temp": d["temp"], "rx": 0.0, "tx": 0.0, "req": None}
            p = self.raw.get(nid)
            if p and now > p[0]:
                dt = now - p[0]
                s["rx"], s["tx"] = max(0.0, (rx - p[1]) / dt), max(0.0, (tx - p[2]) / dt)
                if req is not None and p[3] is not None:
                    s["req"] = max(0.0, (req - p[3]) / dt * 60)
            self.raw[nid] = (now, rx, tx, req)
            self.metrics.add_sample(nid, s)
            self.last[nid] = s
            self.detail[nid] = d
        except Exception:
            log("sample", nid, traceback.format_exc())
        finally:
            with self.lock:
                self.sampling.discard(nid)

    def sample_all(self):
        threads = []
        for n in self.nodes:
            f = self.failures.get(n["id"], 0)
            last = (self.detail.get(n["id"]) or {}).get("at", 0)
            if f >= 3 and time.time() - last < 300:
                continue                       # unreachable: back off to every 5 min
            t = threading.Thread(target=self.sample, args=(n,), daemon=True)
            t.start()
            threads.append(t)
        for t in threads:
            t.join(60)
        self.persist()

    # Websites
    def site_list(self) -> list:
        sites = [dict(s) for s in self.cfg.get("sites", [])]
        seen = {s["url"].rstrip("/") for s in sites}
        for n in self.nodes:
            d = self.detail.get(n["id"]) or {}
            for h in (d.get("tunnel") or {}).get("hosts", []):
                if "*" in h:
                    continue
                u = f"https://{h}"
                if u not in seen:
                    seen.add(u)
                    sites.append({"name": h, "url": u, "auto": True, "node": n["name"]})
        return sites

    def check_site(self, url: str):
        t0 = time.time()
        st = {"code": 0, "error": None, "checkedAt": t0}
        req = urllib.request.Request(url, headers={"User-Agent": f"RaphaelWeb/{VERSION}"})
        try:
            with urllib.request.urlopen(req, timeout=10, context=ssl.create_default_context()) as r:
                st["code"] = r.status
        except urllib.error.HTTPError as e:
            st["code"] = e.code
        except Exception as e:  # noqa: BLE001 — every failure is a status here
            reason = getattr(e, "reason", e)
            st["error"] = str(reason)[:160] or type(e).__name__
        st["ms"] = int((time.time() - t0) * 1000)
        st["ok"] = core.site_ok(st)
        self.site_status[url] = st
        self.metrics.add_check(url, t0, st["code"], st["ms"], st["ok"])
        host = urlparse(url).hostname
        if url.startswith("https://") and host and time.time() - self.cert_checked.get(host_key(url), 0) > 6 * 3600:
            self.cert_checked[host_key(url)] = time.time()
            exp = cert_expiry(host, urlparse(url).port or 443)
            if exp:
                self.certs[host_key(url)] = exp
                self.metrics.put("certs", self.certs)

    def check_sites(self):
        threads = [threading.Thread(target=self.check_site, args=(s["url"],), daemon=True) for s in self.site_list()]
        for t in threads:
            t.start()
        for t in threads:
            t.join(20)
        self.persist()

    # Cloudflare
    def cf_tokens(self) -> list:
        out = []
        tok = os.environ.get("RAPHAEL_CLOUDFLARE_TOKEN")
        if tok:
            out.append(("env RAPHAEL_CLOUDFLARE_TOKEN", tok))
        for f in self.cfg.get("envFiles", []):
            p = os.path.expanduser(f)
            try:
                with open(p, encoding="utf-8") as fh:
                    env = parse_env(fh.read())
            except OSError:
                continue
            extra = sorted(k for k in env if k not in CF_ENV_KEYS and (("TOKEN" in k and "FULL" in k) or "CLOUDFLARE" in k or k.startswith("CF_")))
            for k in CF_ENV_KEYS + extra:
                v = (env.get(k) or "").strip()
                if v and all(v != t for _, t in out):
                    out.append((f"{f} · {k}", v))
        return out

    def refresh_cloudflare(self):
        tokens = self.cf_tokens()
        if not tokens:
            self.cloudflare = {"state": "noToken", "zones": [], "tried": [], "loadedAt": None}
            return
        tried, state, zones = [], "noPermission", []
        for source, tok in tokens:
            if len(tok) == 37 and all(c in "0123456789abcdef" for c in tok):
                tried.append({"source": source, "result": "Global API Key — tidak didukung, buat API Token"})
                continue
            try:
                zones = cloudflare_zones(tok)
                tried.append({"source": source, "result": f"OK · {len(zones)} zone"})
                state = "ok"
                break
            except PermissionError:
                tried.append({"source": source, "result": "tidak punya izin Analytics / Zone Read"})
            except Exception as e:  # noqa: BLE001
                tried.append({"source": source, "result": str(e)[:160]})
                state = "error"
        if state != "ok" and any(t["result"].startswith("tidak punya") for t in tried):
            state = "noPermission"
        self.cloudflare = {"state": state, "zones": zones if state == "ok" else self.cloudflare.get("zones", []), "tried": tried,
                           "loadedAt": time.time() if state == "ok" else self.cloudflare.get("loadedAt")}

    # Loops
    def start(self):
        def loop(fn, every, name):
            while True:
                t0 = time.time()
                try:
                    fn()
                except Exception:
                    log(name, traceback.format_exc())
                time.sleep(max(5, every - (time.time() - t0)))
        threading.Thread(target=loop, args=(self.sample_all, 60, "sample"), daemon=True).start()
        threading.Thread(target=lambda: (time.sleep(20), loop(self.check_sites, 60, "sites")), daemon=True).start()
        threading.Thread(target=lambda: (time.sleep(5), loop(self.refresh_cloudflare, 600, "cloudflare")), daemon=True).start()

    # Views
    def state(self) -> dict:
        nodes = []
        for n in self.nodes:
            d = self.detail.get(n["id"])
            nodes.append({"id": n["id"], "name": n["name"], "description": n.get("description", ""), "local": bool(n.get("local")),
                          "detail": d, "last": self.last.get(n["id"]), "sampling": n["id"] in self.sampling})
        sites = self.site_list()
        for s in sites:
            s["status"] = self.site_status.get(s["url"])
            exp = self.certs.get(host_key(s["url"]))
            s["certDays"] = int((exp - time.time()) // 86400) if exp else None
            checks = self.metrics.checks(s["url"], 24)
            s["uptime"] = (sum(1 for c in checks if c["ok"]) / len(checks)) if checks else None
            s["recent"] = [{"t": c["t"], "ms": c["ms"], "ok": c["ok"]} for c in checks[-60:]]
        cf = dict(self.cloudflare)
        alerts = core.alerts(self.nodes, self.detail, self.last, sites, self.site_status,
                             {s["url"]: self.certs[host_key(s["url"])] for s in sites if host_key(s["url"]) in self.certs})
        return {"version": VERSION, "now": time.time(), "nodes": nodes, "sites": sites, "alerts": alerts, "cloudflare": cf}


def host_key(url: str) -> str:
    """Certificates belong to host:port, shared by every URL on it."""
    u = urlparse(url)
    return f"{u.hostname}:{u.port or 443}"


def cert_expiry(host: str, port: int):
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=8) as sock, ctx.wrap_socket(sock, server_hostname=host) as s:
            na = s.getpeercert().get("notAfter")
        return ssl.cert_time_to_seconds(na) if na else None
    except Exception:  # noqa: BLE001
        return None


def cf_call(token: str, path: str, body=None) -> dict:
    req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, headers={"Authorization": f"Bearer {token}"})
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            j = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            j = json.loads(e.read())
        except ValueError:
            raise RuntimeError(f"HTTP {e.code}")
    errs = j.get("errors") or []
    if errs:
        msg = "; ".join(str(e.get("message", "")) for e in errs if isinstance(e, dict))
        code = errs[0].get("code") if isinstance(errs[0], dict) else None
        ext = (errs[0].get("extensions") or {}).get("code") if isinstance(errs[0], dict) else None
        if code in (10000, 9109) or "authentication error" in msg.lower() or "permission" in msg or "authz" in msg or ext == "authz":
            raise PermissionError(msg)
        if not j.get("data") and not j.get("result"):
            raise RuntimeError(msg or "Cloudflare error")
    return j


def cloudflare_zones(token: str) -> list:
    lst = cf_call(token, "/zones?per_page=50&status=active")
    since = datetime.fromtimestamp(time.time() - 6 * 86400).strftime("%Y-%m-%d")
    out = []
    for z in lst.get("result") or []:
        q = ('{ viewer { zones(filter: {zoneTag: "%s"}) { httpRequests1dGroups(limit: 7, orderBy: [date_ASC], filter: {date_geq: "%s"}) {'
             ' dimensions { date } uniq { uniques } sum { requests bytes cachedRequests threats pageViews'
             ' countryMap { clientCountryName requests } responseStatusMap { edgeResponseStatus requests } } } } } }') % (z["id"], since)
        j = cf_call(token, "/graphql", {"query": q})
        groups = (((j.get("data") or {}).get("viewer") or {}).get("zones") or [{}])[0].get("httpRequests1dGroups") or []
        days, countries, statuses = [], {}, {}
        for g in groups:
            s = g.get("sum") or {}
            days.append({"date": (g.get("dimensions") or {}).get("date"), "requests": s.get("requests", 0),
                         "visitors": (g.get("uniq") or {}).get("uniques", 0), "bytes": s.get("bytes", 0),
                         "cached": s.get("cachedRequests", 0), "threats": s.get("threats", 0), "pageViews": s.get("pageViews", 0)})
            for c in s.get("countryMap") or []:
                countries[c.get("clientCountryName") or "?"] = countries.get(c.get("clientCountryName") or "?", 0) + (c.get("requests") or 0)
            for c in s.get("responseStatusMap") or []:
                k = str(c.get("edgeResponseStatus"))
                statuses[k] = statuses.get(k, 0) + (c.get("requests") or 0)
        out.append({"id": z["id"], "name": z["name"], "days": days,
                    "countries": sorted(countries.items(), key=lambda kv: -kv[1])[:6], "statuses": sorted(statuses.items())})
    out.sort(key=lambda z: -sum(d["requests"] for d in z["days"]))
    return out


# ── HTTP ──────────────────────────────────────────────────────────────────────

class App:
    def __init__(self, cfg: dict):
        build = os.path.join(HERE, "build")
        self.cfg = cfg
        self.metrics = Metrics(os.path.join(cfg["data"], "metrics.sqlite"))
        self.ws = Workspace(os.path.join(cfg["data"], "workspace.sqlite"), build)
        with open(os.path.join(build, "collector_linux.sh"), encoding="utf-8") as f:
            self.monitor = Monitor(cfg, self.metrics, f.read())
        self.static = os.path.join(HERE, "static")
        self.last_refresh = 0.0


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"RaphaelWeb/{VERSION}"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quieter: only errors
            if args and str(args[1] if len(args) > 1 else "").startswith(("4", "5")):
                log(self.address_string(), fmt % args)

        def _send(self, code: int, body: bytes, ctype: str, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store" if ctype.startswith("application/json") else "no-cache")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, code: int, obj):
            self._send(code, json.dumps(obj, default=str).encode(), "application/json; charset=utf-8")

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 256 * 1024:
                raise WorkspaceError("request terlalu besar")
            raw = self.rfile.read(n) if n else b"{}"
            try:
                v = json.loads(raw or b"{}")
            except ValueError:
                raise WorkspaceError("JSON tidak valid")
            if not isinstance(v, dict):
                raise WorkspaceError("JSON harus object")
            return v

        def _write_allowed(self) -> bool:
            # Cross-site forms can't set custom headers or a JSON content type → simple CSRF guard.
            if self.headers.get("X-Raphael") != "1" or not (self.headers.get("Content-Type") or "").startswith("application/json"):
                return False
            origin = self.headers.get("Origin")
            if origin:
                host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or ""
                if urlparse(origin).netloc != host:
                    return False
            return True

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            u = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            try:
                if u.path == "/api/state":
                    return self._json(200, app.monitor.state())
                if u.path == "/api/history":
                    hours = min(24.0, max(0.1, float(q.get("hours", "6"))))
                    return self._json(200, {"node": q.get("node"), "samples": app.metrics.samples(q.get("node", ""), hours)})
                if u.path == "/api/site":
                    return self._json(200, {"url": q.get("url"), "checks": app.metrics.checks(q.get("url", ""), 24)})
                if u.path == "/api/workspace":
                    return self._json(200, app.ws.snapshot())
                if u.path == "/api/me":
                    return self._json(200, {"login": self.headers.get("Tailscale-User-Login"), "name": self.headers.get("Tailscale-User-Name")})
                if u.path == "/healthz":
                    return self._json(200, {"ok": True, "version": VERSION, "workspace": app.ws.integrity_ok()})
                if u.path.startswith("/api/"):
                    return self._json(404, {"error": "tidak ada"})
                return self._static(u.path)
            except Exception as e:  # noqa: BLE001
                log("GET", u.path, traceback.format_exc())
                return self._json(500, {"error": str(e)})

        def _static(self, path: str):
            rel = "index.html" if path in ("/", "") else path.lstrip("/").split("?")[0]
            full = os.path.realpath(os.path.join(app.static, rel))
            if not full.startswith(os.path.realpath(app.static) + os.sep) or not os.path.isfile(full):
                full = os.path.join(app.static, "index.html")          # SPA routes
            with open(full, "rb") as f:
                body = f.read()
            if full.endswith("index.html"):
                # Cache-bust the assets with their mtime so a deploy is picked up on the next load.
                for asset in ("app.js", "app.css"):
                    v = int(os.path.getmtime(os.path.join(app.static, asset)))
                    body = body.replace(f'"{asset}"'.encode(), f'"{asset}?v={v}"'.encode())
            ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript",):
                ctype += "; charset=utf-8"
            self._send(200, body, ctype)

        def _write(self, method: str):
            u = urlparse(self.path)
            if not self._write_allowed():
                return self._json(403, {"error": "ditolak (header X-Raphael / Origin)"})
            parts = [p for p in u.path.split("/") if p]
            try:
                body = self._body() if method in ("POST", "PATCH") else {}
                if parts[:2] == ["api", "refresh"] and method == "POST":
                    if time.time() - app.last_refresh > 10:
                        app.last_refresh = time.time()
                        threading.Thread(target=app.monitor.sample_all, daemon=True).start()
                        threading.Thread(target=app.monitor.check_sites, daemon=True).start()
                    return self._json(202, {"ok": True})
                if parts[:2] == ["api", "cloudflare"] and method == "POST":
                    threading.Thread(target=app.monitor.refresh_cloudflare, daemon=True).start()
                    return self._json(202, {"ok": True})
                if len(parts) >= 2 and parts[0] == "api" and parts[1] in ("portfolio", "project", "task"):
                    kind, rid = parts[1], parts[2] if len(parts) > 2 else None
                    ws = app.ws
                    if method == "POST" and rid is None:
                        new = {"portfolio": ws.create_portfolio, "project": ws.create_project, "task": ws.create_task}[kind](body)
                        return self._json(201, {"id": new})
                    if rid and method == "POST" and kind == "task" and len(parts) > 3 and parts[3] == "move":
                        ws.move_task(rid, body.get("status"), body.get("before"))
                        return self._json(200, {"ok": True})
                    if rid and method == "PATCH":
                        {"portfolio": ws.update_portfolio, "project": ws.update_project, "task": ws.update_task}[kind](rid, body)
                        return self._json(200, {"ok": True})
                    if rid and method == "DELETE":
                        {"portfolio": ws.delete_portfolio, "project": ws.delete_project, "task": ws.delete_task}[kind](rid)
                        return self._json(200, {"ok": True})
                return self._json(404, {"error": "tidak ada"})
            except WorkspaceError as e:
                return self._json(400, {"error": str(e)})
            except sqlite3.IntegrityError as e:
                return self._json(400, {"error": f"data tidak valid: {e}"})
            except Exception as e:  # noqa: BLE001
                log(method, u.path, traceback.format_exc())
                return self._json(500, {"error": str(e)})

        def do_POST(self):
            self._write("POST")

        def do_PATCH(self):
            self._write("PATCH")

        def do_DELETE(self):
            self._write("DELETE")

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.expanduser("~/.config/raphael-web/config.json"))
    ap.add_argument("--no-sampling", action="store_true", help="serve only (tests / development)")
    args = ap.parse_args()
    cfg = load_config(args.config)
    app = App(cfg)
    if not args.no_sampling:
        app.monitor.start()
    srv = ThreadingHTTPServer(("127.0.0.1", int(cfg["port"])), make_handler(app))
    srv.daemon_threads = True
    log(f"Raphael Web {VERSION} on http://127.0.0.1:{cfg['port']} · {len(cfg['nodes'])} device · data {cfg['data']}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
