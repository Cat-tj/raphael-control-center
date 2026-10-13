"""Pure logic shared by the Raphael Web server: cron schedules, job health, sample parsing and
alerts. Ported 1:1 from the Mac app (Jobs.swift, MonitorStore.swift) so both read the same
collector output the same way. No I/O here — everything is unit tested."""
from __future__ import annotations

import re
import time
from datetime import datetime, timedelta, timezone

# ── Cron expressions ──────────────────────────────────────────────────────────

MACROS = {"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
          "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"}
MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
DAY_NAMES = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"]


def _field(f: str, lo: int, hi: int, names=()):
    out = set()
    for part in f.lower().split(","):
        step_parts = part.split("/")
        try:
            step = int(step_parts[1]) if len(step_parts) > 1 else 1
        except ValueError:
            return None
        if step <= 0:
            return None

        def num(t):
            if t.isdigit():
                return int(t)
            return names.index(t) + (1 if lo == 1 else 0) if t in names else None

        a, b = lo, hi
        rng = step_parts[0]
        if rng != "*":
            ends = rng.split("-")
            x = num(ends[0])
            if x is None:
                return None
            a = x
            if len(ends) > 1:
                y = num(ends[1])
                b = x if y is None else y
            else:
                b = hi if len(step_parts) > 1 else x      # "5/15" = from 5 to the end, every 15
        if a < lo or b > hi or a > b:
            return None
        out.update(range(a, b + 1, step))
    return out


class CronExpr:
    """Five-field cron (plus @macros), evaluated in a fixed UTC offset (the device's)."""

    def __init__(self, minutes, hours, days, months, weekdays, any_day, any_weekday, source):
        self.minutes, self.hours, self.days, self.months, self.weekdays = minutes, hours, days, months, weekdays
        self.any_day, self.any_weekday, self.source = any_day, any_weekday, source

    @classmethod
    def parse(cls, raw: str):
        s = (raw or "").strip()
        s = MACROS.get(s, s)
        f = s.split()
        if len(f) != 5:
            return None
        mi, h, d = _field(f[0], 0, 59), _field(f[1], 0, 23), _field(f[2], 1, 31)
        mo, w = _field(f[3], 1, 12, MONTHS), _field(f[4], 0, 7, DAYS)
        if None in (mi, h, d, mo, w):
            return None
        return cls(mi, h, d, mo, {0 if x == 7 else x for x in w}, f[2] == "*", f[4] == "*", raw)

    def _day_ok(self, t: datetime) -> bool:
        dom, dow = t.day in self.days, (t.weekday() + 1) % 7 in self.weekdays
        if self.any_day and self.any_weekday:
            return True
        if self.any_day:
            return dow
        if self.any_weekday:
            return dom
        return dom or dow

    def next(self, after: float, tz: int):
        """First matching minute strictly after `after` (unix seconds)."""
        zone = timezone(timedelta(seconds=tz))
        t = datetime.fromtimestamp((int(after) // 60) * 60 + 60, zone)
        for _ in range(366 * 24 * 60):
            if t.month not in self.months or not self._day_ok(t):
                t = (t + timedelta(days=1)).replace(hour=0, minute=0)
                continue
            if t.hour not in self.hours:
                t = t.replace(minute=0) + timedelta(hours=1)
                continue
            if t.minute in self.minutes:
                return t.timestamp()
            t += timedelta(minutes=1)
        return None

    def previous(self, before: float, tz: int):
        """Last matching minute at or before `before`."""
        zone = timezone(timedelta(seconds=tz))
        t = datetime.fromtimestamp((int(before) // 60) * 60, zone)
        for _ in range(400 * 24 * 60):
            if t.month not in self.months or not self._day_ok(t):
                t = t.replace(hour=0, minute=0) - timedelta(minutes=1)
                continue
            if t.hour not in self.hours:
                t = t.replace(minute=0) - timedelta(minutes=1)
                continue
            if t.minute in self.minutes:
                return t.timestamp()
            t -= timedelta(minutes=1)
        return None

    def describe(self) -> str:
        f = self.source.split()
        if len(f) != 5:
            return self.source
        if len(self.minutes) == 60 and len(self.hours) == 24:
            return "tiap menit"
        if len(self.hours) == 24 and self.any_day and self.any_weekday and len(self.months) == 12:
            return f"tiap jam, menit {min(self.minutes)}" if len(self.minutes) == 1 else f"tiap {60 // max(len(self.minutes), 1)} menit"
        time_s = f"{min(self.hours):02d}:{min(self.minutes):02d}" if len(self.hours) == 1 and len(self.minutes) == 1 else None
        if time_s and self.any_day and self.any_weekday and len(self.months) == 12:
            return f"tiap hari {time_s}"
        if time_s and self.any_day and not self.any_weekday and len(self.weekdays) == 1:
            return f"tiap {DAY_NAMES[min(self.weekdays)]} {time_s}"
        if time_s and not self.any_day and self.any_weekday and len(self.days) == 1:
            return f"tiap tanggal {min(self.days)} {time_s}"
        return self.source


# ── Jobs ──────────────────────────────────────────────────────────────────────

HEALTH = {"ok": "OK", "failed": "Gagal", "missed": "Terlewat", "running": "Berjalan", "scheduled": "Terjadwal",
          "disabled": "Nonaktif", "unknown": "Belum diketahui"}
KIND_TITLE = {"cron": "Cron", "timer": "systemd timer", "launchd": "launchd", "hermes": "Hermes cron"}


def _iso(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _date(j: dict, k: str):
    v = j.get(k)
    if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
        return float(v)
    return _iso(j.get(k + "ISO")) or _iso(v)


def job(j: dict, tz: int, now: float | None = None) -> dict:
    """Collector job dict → the fields the UI shows, with health computed like MJob."""
    now = time.time() if now is None else now
    kind = j.get("kind") if j.get("kind") in KIND_TITLE else "cron"
    expr = j.get("expr") or ""
    cron = CronExpr.parse(expr)
    history = []
    for r in j.get("history") or []:
        if isinstance(r, list):
            history.append({"started": _iso(r[0]) if r else None, "finished": _iso(r[1]) if len(r) > 1 else None,
                            "status": (r[2] if len(r) > 2 else "") or "", "error": (r[3] if len(r) > 3 else "") or ""})
    out = {
        "id": j.get("id") or "", "kind": kind, "kindTitle": KIND_TITLE[kind], "name": j.get("name") or "?", "expr": expr,
        "command": j.get("command") or "", "user": j.get("user") or j.get("profile") or "",
        "source": j.get("source") or j.get("unit") or "", "enabled": j.get("enabled", True) is not False,
        "system": bool(j.get("system")), "next": _date(j, "next"), "last": _date(j, "last"),
        "status": j.get("status") or "", "detail": (j.get("detail") or "").strip(), "log": j.get("log"),
        "logModified": float(j["logModified"]) if isinstance(j.get("logModified"), (int, float)) else None,
        "failureStreak": int(j.get("failureStreak") or 0), "workdir": j.get("workdir") or "", "history": history,
    }
    if out["last"] is None and out["logModified"]:
        out["last"] = out["logModified"]
    if out["next"] is None and cron:
        out["next"] = cron.next(now, tz)
    if out["last"] is None and kind == "hermes" and history:
        out["last"] = history[0]["started"]
    out["expectedLast"] = cron.previous(now, tz) if cron else None
    out["missed"] = _missed(out, now)
    out["health"] = _health(out, now)
    out["healthTitle"] = HEALTH[out["health"]]
    out["scheduleText"] = j.get("schedule") or (cron.describe() if cron else (expr or "–"))
    return out


def _missed(j, now):
    if not j["enabled"]:
        return False
    if j["kind"] != "cron" and j["next"] and j["next"] < now - 900:
        return True
    exp, last = j["expectedLast"], j["last"]
    if exp is None or now - exp <= 600 or last is None:
        return False
    return exp - last > 300


def _health(j, now):
    if not j["enabled"]:
        return "disabled"
    if j["status"] == "failed" or j["failureStreak"] > 0:
        return "failed"
    if j["status"] == "running":
        return "running"
    if j["missed"]:
        return "missed"
    if j["status"] == "ok":
        return "ok"
    if j["last"] is None and j["kind"] != "cron" and j["next"] and j["next"] > now:
        return "scheduled"
    return "unknown"


# ── Collector output ──────────────────────────────────────────────────────────

def mem_bytes(s: str) -> float:
    m = re.match(r"^\s*([0-9.]+)\s*([a-zA-Z]*)", s or "")
    if not m:
        return 0.0
    v, unit = float(m.group(1)), m.group(2).lower()
    return v * (1073741824 if unit.startswith("g") else 1048576 if unit.startswith("m") else 1024 if unit.startswith("k") else 1)


def container_healthy(status: str) -> bool:
    return status.startswith("Up") and "unhealthy" not in status and "Restarting" not in status


def parse(j: dict, now: float | None = None, previous: dict | None = None, slow: bool = True) -> dict:
    """Collector JSON → one detail record (what the latest sample said)."""
    now = time.time() if now is None else now
    n = lambda k: float(j.get(k) or 0)  # noqa: E731
    disks = [{"mount": a[0], "used": float(a[1] or 0), "totalGB": float(a[2] or 0)}
             for a in j.get("disks") or [] if isinstance(a, list) and len(a) >= 3]
    root = next((d for d in disks if d["mount"] == "/"), disks[0] if disks else None)
    procs = lambda k: [{"pid": a[0], "name": a[1], "cpu": a[2], "mem": a[3]} for a in j.get(k) or [] if isinstance(a, list) and len(a) >= 4]  # noqa: E731
    containers = []
    for c in j.get("containers") or []:
        st = c.get("status") or ""
        containers.append({"name": c.get("name") or "?", "status": st, "cpu": float(c.get("cpu") or 0), "mem": c.get("mem") or "",
                           "memPct": float(c.get("memPct") or 0), "restarts": int(c.get("restarts") or 0),
                           "project": c.get("project") or "", "ports": c.get("ports") or [], "healthy": container_healthy(st)})
    containers.sort(key=lambda c: (1 if c["healthy"] else 0, -c["cpu"]))
    tz = int(j.get("tz") or 0)
    d = {
        "at": now, "error": None, "cores": int(n("cores")) or 1, "memTotalGB": n("memTotal") / 1073741824, "uptime": n("uptime"),
        "cpu": n("cpu"), "mem": n("mem"), "swap": n("swap"), "load": n("load"), "temp": j.get("temp"),
        "disk": root["used"] if root else 0, "throttled": j.get("throttled"), "disks": disks,
        "topCPU": procs("topCPU"), "topMem": procs("topMem"), "containers": containers, "failed": j.get("failed") or [],
        "ips": j.get("ips") or [], "tz": tz, "jobs": [job(x, tz, now) for x in j.get("jobs") or []],
        "services": [{"unit": v.get("unit") or "", "name": (v.get("unit") or "").replace(".service", ""), "state": v.get("state") or "",
                      "sub": v.get("sub") or "", "mem": float(v.get("mem") or 0), "restarts": int(v.get("restarts") or 0),
                      "desc": v.get("desc") or "", "running": v.get("state") == "active"} for v in j.get("services") or []],
        "routes": [{"hosts": r.get("hosts") or [], "proxy": r.get("proxy"), "root": r.get("root")} for r in j.get("caddy") or []],
        "tunnel": None, "hw": j.get("hw") if isinstance(j.get("hw"), dict) else (previous or {}).get("hw"),
    }
    for k, jk in (("updates", "updates"), ("securityUpdates", "security"), ("sshFails", "sshFails"), ("rebootRequired", "reboot")):
        d[k] = j.get(jk) if slow else (previous or {}).get(k)
    t = j.get("tunnel")
    if isinstance(t, dict):
        d["tunnel"] = {"total": float(t.get("total") or 0), "errors": float(t.get("errors") or 0), "connections": float(t.get("ha") or 0),
                       "concurrent": float(t.get("concurrent") or 0), "codes": {k: float(v) for k, v in (t.get("codes") or {}).items()},
                       "hosts": t.get("hosts") or []}
    return d


def throttle_text(hexs: str) -> str:
    try:
        v = int(hexs[2:], 16)
    except (ValueError, TypeError):
        return hexs or ""
    now = [s for b, s in ((0x1, "undervoltage"), (0x2, "frekuensi dibatasi"), (0x4, "throttled"), (0x8, "batas suhu")) if v & b]
    past = [s for b, s in ((0x10000, "undervoltage"), (0x40000, "throttled"), (0x80000, "batas suhu")) if v & b]
    return ("sekarang: " + ", ".join(now) if now else "") + ((" · " if now else "") + "pernah: " + ", ".join(past) if past else "")


def site_ok(st: dict | None) -> bool:
    return bool(st) and not st.get("error") and 200 <= int(st.get("code") or 0) < 400


# ── Alerts ────────────────────────────────────────────────────────────────────

def alerts(nodes: list, details: dict, last_samples: dict, sites: list, site_status: dict, certs: dict, now=None) -> list:
    """Same rules as MonitorStore.alerts. level: 2 bad, 1 warn, 0 info."""
    now = time.time() if now is None else now
    out = []
    add = lambda node, level, text, kind="server": out.append({"node": node, "level": level, "text": text, "kind": kind})  # noqa: E731
    for n in nodes:
        d = details.get(n["id"])
        if not d:
            continue
        name = n["name"]
        if d.get("error"):
            add(name, 2, f"Tidak bisa diambil datanya: {d['error']}")
            continue
        s = last_samples.get(n["id"]) or {}
        for disk in d["disks"]:
            if disk["used"] > 0.85:
                add(name, 2 if disk["used"] > 0.93 else 1, f"Disk {disk['mount']} {int(disk['used'] * 100)}% penuh")
        if s.get("mem", 0) > 0.9:
            add(name, 1, f"RAM {int(s['mem'] * 100)}% terpakai" + (f", swap {int(s['swap'] * 100)}%" if s.get("swap", 0) > 0.5 else ""))
        temp = s.get("temp")
        if temp and temp > 75:
            add(name, 2 if temp > 80 else 1, f"Suhu {int(temp)}°C")
        if d.get("throttled") and d["throttled"] != "0x0":
            add(name, 1, f"Daya/suhu: {throttle_text(d['throttled'])}. Cek adaptor daya & pendingin")
        if s.get("load", 0) > d["cores"] * 1.5:
            add(name, 1, f"Load {s['load']:.1f} untuk {d['cores']} core")
        for c in d["containers"]:
            if not c["healthy"]:
                add(name, 2, f"Container {c['name']}: {c['status']}")
            if c["restarts"] > 3:
                add(name, 1, f"Container {c['name']} restart {c['restarts']}×")
        for f in d["failed"]:
            add(name, 2, f"Service gagal: {f}")
        for jb in d["jobs"]:
            if jb["system"] and jb["health"] != "failed":
                continue
            if jb["health"] == "failed":
                add(name, 2, f"Job {jb['name']} gagal" + (f": {jb['detail']}" if jb["detail"] else ""), "job")
            elif jb["health"] == "missed":
                add(name, 1, f"Job {jb['name']} tidak jalan sesuai jadwal ({jb['scheduleText']})", "job")
        if d.get("securityUpdates"):
            add(name, 1, f"{d['securityUpdates']} update keamanan tertunda")
        elif (d.get("updates") or 0) > 20:
            add(name, 0, f"{d['updates']} update paket tertunda")
        if d.get("rebootRequired"):
            add(name, 0, "Perlu reboot untuk menyelesaikan update")
        if (d.get("sshFails") or 0) > 20:
            add(name, 2 if d["sshFails"] > 200 else 1, f"{d['sshFails']} login SSH gagal (24 jam)")
        if d.get("tunnel") and d["tunnel"]["connections"] < 1:
            add(name, 2, "Cloudflare tunnel tidak terhubung")
    for site in sites:
        st = site_status.get(site["url"])
        if st and not site_ok(st):
            add(site["name"], 2, "Website down: " + (st.get("error") or f"HTTP {st.get('code')}"), "site")
        exp = certs.get(site["url"])
        if exp:
            days = int((exp - now) // 86400)
            if days < 14:
                add(site["name"], 2 if days < 5 else 1, f"Sertifikat SSL habis {days} hari lagi", "site")
    out.sort(key=lambda a: -a["level"])
    return out
