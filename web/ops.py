"""Operations logic for Raphael Web (pure, unit tested): which conditions are problems right
now, when they become incidents (with hysteresis so a blip is not a page), the notification
text, the weekly report, and validation for the few allowed actions."""
from __future__ import annotations

import re
import time
from datetime import datetime

# How many consecutive bad evaluations before a condition opens an incident (≈ minutes).
HOLD = {"site": 2, "node": 3, "temp": 3, "power": 2, "disk": 1, "job": 1, "ssl": 1, "backup": 1, "internet": 2, "sdcard": 1}
# Consecutive clean evaluations before an open incident counts as recovered (flappy signals).
CLOSE_HOLD = {"power": 10, "temp": 5, "site": 1, "node": 1}
# A recurrence within this window is still recorded but not sent again.
COOLDOWN = {"power": 6 * 3600, "temp": 6 * 3600, "sdcard": 24 * 3600, "ssl": 24 * 3600, "disk": 6 * 3600}
EMOJI = {"site": "🌐", "node": "🖥", "temp": "🌡", "power": "⚡", "disk": "💾", "job": "⏰", "ssl": "🔒", "backup": "🗄",
         "internet": "📡", "reboot": "🔁", "sdcard": "💽", "report": "📊"}


def conditions(nodes: list, details: dict, last: dict, sites: list, site_status: dict, certs: dict,
               backups: list, health: dict, internet_ok: bool, now: float) -> dict:
    """key → {kind, node, title, detail} for everything that is a problem now."""
    out = {}
    add = lambda key, kind, node, title, detail="": out.__setitem__(key, {"kind": kind, "node": node, "title": title, "detail": detail})  # noqa: E731
    if not internet_ok:
        add("internet", "internet", "Rumah", "Internet rumah putus", "Server tidak bisa menjangkau internet; status website ditahan.")
    for n in nodes:
        d = details.get(n["id"]) or {}
        name = n["name"]
        if d.get("error"):
            add(f"node:{n['id']}", "node", name, f"{name} tidak terjangkau", d["error"])
            continue
        if not d:
            continue
        s = last.get(n["id"]) or {}
        if s.get("temp") and s["temp"] >= 80:
            add(f"temp:{n['id']}", "temp", name, f"{name} panas {int(s['temp'])}°C", "Cek pendingin / aliran udara")
        thr = d.get("throttled")
        if thr and thr != "0x0":
            try:
                v = int(thr[2:], 16)
            except ValueError:
                v = 0
            if v & 0x1:
                add(f"power:{n['id']}", "power", name, f"{name} kekurangan daya (undervoltage)", "Ganti adaptor/kabel daya yang lebih kuat")
        for disk in d.get("disks") or []:
            if disk["used"] >= 0.93:
                add(f"disk:{n['id']}:{disk['mount']}", "disk", name, f"Disk {disk['mount']} di {name} {int(disk['used'] * 100)}% penuh")
        for j in d.get("jobs") or []:
            if j.get("system") and j.get("health") != "failed":
                continue
            if j.get("health") == "failed":
                add(f"job:{n['id']}|{j['id']}", "job", name, f"Job {j['name']} gagal", j.get("detail") or "")
            elif j.get("health") == "missed":
                add(f"job:{n['id']}|{j['id']}", "job", name, f"Job {j['name']} tidak jalan sesuai jadwal", j.get("scheduleText") or "")
        h = health.get(n["id"]) or {}
        if h.get("rootRO"):
            add(f"sdcard:{n['id']}", "sdcard", name, f"Filesystem / di {name} read-only", "Biasanya tanda kartu SD/SSD bermasalah")
        elif (h.get("mmcErrors") or 0) > 0:
            add(f"sdcard:{n['id']}", "sdcard", name, f"Error kartu SD di {name} ({h['mmcErrors']}× sejak boot)", "Siapkan cadangan & ganti kartu")
    if internet_ok:
        for site in sites:
            st = site_status.get(site["url"])
            if st and not st.get("ok"):
                add(f"site:{site['url']}", "site", site["name"], f"{site['name']} down", st.get("error") or f"HTTP {st.get('code')}")
    for site in sites:
        exp = certs.get(site["url"])
        if exp and exp - now < 7 * 86400:
            add(f"ssl:{site['url']}", "ssl", site["name"], f"SSL {site['name']} habis {max(0, int((exp - now) // 86400))} hari lagi")
    for b in backups:
        if b.get("problem"):
            add(f"backup:{b['name']}", "backup", b.get("nodeName", ""), f"Backup {b['name']}: {b['problem']}", b.get("detail", ""))
    return out


class Tracker:
    """Turns condition snapshots into incident open/close transitions with hysteresis."""

    def __init__(self, open_incidents: dict | None = None):
        self.open = dict(open_incidents or {})       # key → incident dict (has "started")
        self.streak: dict = {}
        self.clean: dict = {}                        # open key → consecutive clean evaluations
        self.last_closed: dict = {}                  # key → when it last recovered

    def step(self, conds: dict, now: float) -> tuple:
        """(opened, closed). An incident marked "quiet" recurred within its cooldown: record it,
        don't send it (nor its recovery)."""
        opened, closed = [], []
        for key, c in conds.items():
            self.streak[key] = self.streak.get(key, 0) + 1
            self.clean.pop(key, None)
            if key not in self.open and self.streak[key] >= HOLD.get(c["kind"], 1):
                quiet = now - self.last_closed.get(key, -1e18) < COOLDOWN.get(c["kind"], 0)
                inc = {**c, "key": key, "started": now, "quiet": quiet}
                self.open[key] = inc
                opened.append(inc)
            elif key in self.open:
                self.open[key].update({"title": c["title"], "detail": c["detail"]})
        for key in list(self.open):
            if key not in conds:
                self.clean[key] = self.clean.get(key, 0) + 1
                if self.clean[key] >= CLOSE_HOLD.get(self.open[key]["kind"], 1):
                    inc = self.open.pop(key)
                    self.clean.pop(key, None)
                    self.last_closed[key] = now
                    closed.append({**inc, "ended": now})
        for key in list(self.streak):
            if key not in conds:
                del self.streak[key]
        return opened, closed


def duration(s: float) -> str:
    s = max(0, int(s))
    if s < 90:
        return f"{s} detik"
    if s < 3600:
        return f"{round(s / 60)} menit"
    if s < 86400:
        return f"{s // 3600} jam {(s % 3600) // 60} menit"
    return f"{s // 86400} hari {(s % 86400) // 3600} jam"


def message(opened: list, closed: list, reboots: list, base_url: str = "") -> str | None:
    """One WhatsApp message for a round's transitions (None when there is nothing to say)."""
    lines = []
    opened = [i for i in opened if not i.get("quiet")]
    closed = [i for i in closed if not i.get("quiet")]
    for i in opened:
        lines.append(f"{EMOJI.get(i['kind'], '⚠️')} *{i['title']}*" + (f"\n   {i['detail'][:180]}" if i.get("detail") else ""))
    for r in reboots:
        lines.append(f"{EMOJI['reboot']} *{r['node']} restart sendiri* ({r.get('when', '')})" + (f"\n   {r['detail'][:220]}" if r.get("detail") else ""))
    for i in closed:
        lines.append(f"✅ Pulih: {i['title']} (setelah {duration(i['ended'] - i['started'])})")
    if not lines:
        return None
    head = "🚨 Raphael" if opened or reboots else "Raphael"
    return f"{head}\n" + "\n".join(lines) + (f"\n\n{base_url}" if base_url and (opened or reboots) else "")


def weekly_report(now: float, incidents: list, sites: list, uptime: dict, nodes: list, temps: dict,
                  hermes_tokens: int | None, tasks_done: int, jobs_failed: int) -> str:
    week = now - 7 * 86400
    recent = [i for i in incidents if (i.get("ended") or now) >= week]
    total_down = sum(((i.get("ended") or now) - max(i["started"], week)) for i in recent if i["kind"] == "site")
    lines = [f"{EMOJI['report']} *Laporan mingguan Raphael* · {datetime.fromtimestamp(week).strftime('%d %b')}–{datetime.fromtimestamp(now).strftime('%d %b')}"]
    if sites:
        ups = [f"{s['name']} {uptime[s['url']] * 100:.1f}%" for s in sites if uptime.get(s["url"]) is not None]
        if ups:
            lines.append("🌐 Uptime: " + ", ".join(ups[:8]))
    lines.append(f"🚨 Insiden: {len(recent)}" + (f" · website down total {duration(total_down)}" if total_down else ""))
    for i in sorted(recent, key=lambda x: -((x.get('ended') or now) - x['started']))[:5]:
        lines.append(f"   • {i['title']} ({duration((i.get('ended') or now) - i['started'])}{', masih terbuka' if not i.get('ended') else ''})")
    for n in nodes:
        t = temps.get(n["id"])
        if t:
            lines.append(f"🌡 {n['name']}: rata-rata {t['avg']:.0f}°C, puncak {t['max']:.0f}°C")
    lines.append(f"⏰ Job gagal: {jobs_failed}")
    if hermes_tokens is not None:
        lines.append(f"🤖 Token Hermes 7 hari: {hermes_tokens:,}".replace(",", "."))
    lines.append(f"✅ Task selesai: {tasks_done}")
    return "\n".join(lines)


# ── Actions ──
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,120}$")


def action_command(kind: str, target: str, detail: dict, cfg: dict) -> tuple:
    """(argv-safe shell command, description) for an allowed action, or raises ValueError."""
    allow = cfg.get("actions") or {}
    if not NAME.match(target or ""):
        raise ValueError("nama tidak valid")
    if kind == "restart-service":
        unit = target if target.endswith(".service") else target + ".service"
        known = {s["unit"] for s in detail.get("services") or []} | {f for f in detail.get("failed") or []}
        if target not in allow.get("services", []) and unit.replace(".service", "") not in allow.get("services", []) and unit not in known:
            raise ValueError("service ini tidak ada di daftar yang diizinkan")
        user = next((s.get("user") for s in detail.get("services") or [] if s["unit"] == unit), False)
        return (f"systemctl --user restart {unit}" if user else f"sudo -n systemctl restart {unit}"), f"Restart service {unit}"
    if kind == "restart-container":
        if not allow.get("containers", False):
            raise ValueError("restart container tidak diizinkan di config")
        if target not in {c["name"] for c in detail.get("containers") or []}:
            raise ValueError("container tidak ditemukan di device ini")
        return f"docker restart {target}", f"Restart container {target}"
    if kind == "run-job":
        if not allow.get("jobs", False):
            raise ValueError("menjalankan job tidak diizinkan di config")
        job = next((j for j in detail.get("jobs") or [] if j["id"] == target), None)
        if not job or job.get("system"):
            raise ValueError("job tidak ditemukan (job sistem tidak bisa dijalankan dari sini)")
        if job["kind"] == "hermes":
            parts = target.split(":")
            if len(parts) < 3 or not NAME.match(parts[1]) or not NAME.match(parts[2]):
                raise ValueError("id job Hermes tidak valid")
            home = "~/.hermes" if parts[1] in ("default", "") else f"~/.hermes/profiles/{parts[1]}"
            return f"HERMES_HOME={home} ~/.local/bin/hermes cron run {parts[2]}", f"Jalankan job Hermes {job['name']}"
        if job["kind"] != "cron" or not job.get("command"):
            raise ValueError("hanya job cron dan Hermes yang bisa dijalankan")
        user = job.get("user") or ""
        if user and not NAME.match(user):
            raise ValueError("user tidak valid")
        cmd = shell_quote(job["command"])
        return (f"sudo -n -u {user} sh -c {cmd}" if user and user != "pi" else f"sh -c {cmd}"), f"Jalankan job {job['name']}"
    raise ValueError("aksi tidak dikenal")


def logs_command(kind: str, target: str, detail: dict) -> str:
    if not NAME.match(target or ""):
        raise ValueError("nama tidak valid")
    if kind == "service":
        unit = target if target.endswith(".service") else target + ".service"
        user = next((s.get("user") for s in detail.get("services") or [] if s["unit"] == unit), False)
        return f"journalctl --user -u {unit} -n 200 --no-pager -o short-iso" if user else f"sudo -n journalctl -u {unit} -n 200 --no-pager -o short-iso"
    if kind == "container":
        if target not in {c["name"] for c in detail.get("containers") or []}:
            raise ValueError("container tidak ditemukan")
        return f"docker logs --tail 200 --timestamps {target} 2>&1"
    if kind == "job":
        job = next((j for j in detail.get("jobs") or [] if j["id"] == target), None)
        if not job or not job.get("log"):
            raise ValueError("job ini tidak menulis ke file log")
        return f"sudo -n tail -n 200 {shell_quote(job['log'])}"
    raise ValueError("jenis log tidak dikenal")


def shell_quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"


def now() -> float:
    return time.time()
