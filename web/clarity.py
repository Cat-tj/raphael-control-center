"""Microsoft Clarity (Data Export API): how people use one website (same rules as rust/src/clarity.rs).

Clarity allows 10 requests per project per day and only returns the last 1-3 days, so a refresh
spends two calls (totals, then per page), runs at most every 6 hours, never more often than every
15 minutes by hand, and the daily totals are kept here as history. Custom events (contact clicks)
are not part of the export; they stay in Clarity itself.
"""
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

ENV_KEYS = ["CLARITY_API_TOKEN", "CLARITY_TOKEN", "MS_CLARITY_API_TOKEN"]
DAILY_LIMIT = 10
CALLS_PER_REFRESH = 2
EVERY = 6 * 3600
RETRY = 3600
MANUAL_GAP = 15 * 60
HISTORY_DAYS = 90
URL = "https://www.clarity.ms/export-data/api/v1/project-live-insights"
UA = "RaphaelWeb"


class Denied(Exception):
    pass


class Quota(Exception):
    pass


def fetch(token: str, dimension=None):
    q = {"numOfDays": "1"}
    if dimension:
        q["dimension1"] = dimension
    req = urllib.request.Request(URL + "?" + urllib.parse.urlencode(q), headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise Denied("token ditolak Clarity (401/403)")
        if e.code == 429:
            raise Quota()
        raise RuntimeError(f"HTTP {e.code}")


# Parsing (the export's field names vary by metric, so lookups are tolerant)
def key(name) -> str:
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def num(row, names):
    if not isinstance(row, dict):
        return None
    for want in names:
        for k, v in row.items():
            if key(k) == key(want):
                try:
                    n = float(v)
                except (TypeError, ValueError):
                    continue
                if n == n and n not in (float("inf"), float("-inf")):
                    return n
    return None


def label(row, dimension=None):
    if not isinstance(row, dict):
        return None
    if dimension:
        for k, v in row.items():
            if key(k) == key(dimension) and isinstance(v, str):
                return v
    for v in row.values():
        if isinstance(v, str):
            try:
                float(v.strip())
            except ValueError:
                return v
    return None


SESSIONS = ["sessionsCount", "totalSessionCount", "visitsCount", "subTotal", "count"]
ISSUES = [("deadclickcount", "deadClicks"), ("rageclickcount", "rageClicks"), ("quickbackclick", "quickbacks"),
          ("excessivescroll", "excessiveScroll"), ("scripterrorcount", "scriptErrors"), ("errorclickcount", "errorClicks")]
LISTS = [("popularpages", "popularPages"), ("referrerurl", "referrers"), ("device", "devices"), ("countryregion", "countries"),
         ("country", "countries"), ("browser", "browsers"), ("os", "os"), ("pagetitle", "pageTitles")]


def metrics_of(resp):
    if not isinstance(resp, list):
        return []
    return [(key(m.get("metricName", "")), m.get("information") or []) for m in resp if isinstance(m, dict)]


def summarize(resp):
    totals, lists = {}, {}
    for name, rows in metrics_of(resp):
        first = rows[0] if rows else None
        if name == "traffic":
            totals.update(sessions=num(first, ["totalSessionCount"]), bots=num(first, ["totalBotSessionCount"]),
                          users=num(first, ["distinctUserCount", "distantUserCount"]),
                          pagesPerSession=num(first, ["PagesPerSessionPercentage", "pagesPerSession"]))
        elif name == "scrolldepth":
            totals["scrollDepth"] = num(first, ["averageScrollDepth", "scrollDepth", "average"])
        elif name == "engagementtime":
            totals.update(totalTime=num(first, ["totalTime"]), activeTime=num(first, ["activeTime"]))
        elif name in dict(ISSUES):
            totals[dict(ISSUES)[name]] = {"sessions": num(first, ["sessionsCount", "subTotal", "count"]),
                                          "pct": num(first, ["sessionsWithMetricPercentage", "percentage"])}
        elif name in dict(LISTS):
            items = [{"name": label(r), "sessions": num(r, SESSIONS)} for r in rows if label(r) is not None]
            items.sort(key=lambda x: -(x["sessions"] or 0))
            lists[dict(LISTS)[name]] = items[:25]
    return totals, lists


def pages(resp):
    by = {}
    for name, rows in metrics_of(resp):
        for r in rows:
            url = label(r, "Url")
            if url is None:
                continue
            m = by.setdefault(url, {})
            if name == "traffic":
                m.update(sessions=num(r, ["totalSessionCount"]), bots=num(r, ["totalBotSessionCount"]),
                         users=num(r, ["distinctUserCount", "distantUserCount"]))
            elif name == "scrolldepth":
                m["scrollDepth"] = num(r, ["averageScrollDepth", "scrollDepth", "average"])
            elif name == "engagementtime":
                m.update(activeTime=num(r, ["activeTime"]), totalTime=num(r, ["totalTime"]))
            elif name in dict(ISSUES[:3]):
                m[dict(ISSUES)[name]] = num(r, ["sessionsCount", "subTotal", "count"])
    out = [dict(m, url=u) for u, m in by.items()]
    out.sort(key=lambda p: -(p.get("sessions") or 0))
    return out[:60]


def site_of(pgs):
    for p in pgs:
        u = p.get("url") or ""
        if "://" in u:
            host = u.split("://", 1)[1].split("/", 1)[0]
            if host:
                return host
    return None


def today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def used(st) -> int:
    q = st.get("quota") or {}
    return int(q.get("used") or 0) if q.get("date") == today() else 0


def due(st, t) -> bool:
    wait = EVERY if st.get("state") == "ok" else RETRY
    return t - (st.get("lastTry") or 0) >= wait and used(st) + CALLS_PER_REFRESH <= DAILY_LIMIT


def refusal(st, t):
    gap = t - (st.get("lastTry") or 0)
    if gap < MANUAL_GAP and st.get("state") not in ("noToken", "idle"):
        return (f"Clarity baru dimuat {int(gap // 60)} menit lalu. Clarity membatasi {DAILY_LIMIT} permintaan per hari, "
                "jadi coba lagi nanti.")
    if used(st) + CALLS_PER_REFRESH > DAILY_LIMIT:
        return "Jatah Clarity hari ini (UTC) sudah habis; dimuat lagi besok."
    return None


class Clarity:
    def __init__(self, metrics):
        self.metrics = metrics
        saved = metrics.get("clarity")
        self.state = saved if isinstance(saved, dict) else {"state": "idle"}
        self.lock = threading.Lock()

    def view(self) -> dict:
        v = {k: x for k, x in self.state.items() if k != "quota"}
        v.update(used=used(self.state), limit=DAILY_LIMIT, everyHours=EVERY / 3600)
        return v

    def save(self, st):
        self.metrics.put("clarity", st)
        self.state = st

    def refresh(self, tokens, manual=False):
        if not self.lock.acquire(blocking=False):
            return "Clarity sedang dimuat"
        try:
            return self._refresh(tokens, manual)
        finally:
            self.lock.release()

    def _refresh(self, tokens, manual):
        st, t = dict(self.state), time.time()
        if not tokens:
            st.update(state="noToken", tried=[])
            self.save(st)
            return None
        if manual:
            why = refusal(st, t)
            if why:
                return why
        elif not due(st, t):
            return None
        n, tried, outcome = used(st), [], None
        st["lastTry"] = t
        for source, token in tokens:
            n += 1
            try:
                a = fetch(token)
            except Denied as e:
                tried.append({"source": source, "result": str(e)})
                outcome = ("denied", "Token Clarity ditolak. Buat token baru di Clarity → Settings → Data Export.")
                continue
            except Quota:
                tried.append({"source": source, "result": "batas harian Clarity tercapai (429)"})
                n, outcome = DAILY_LIMIT, ("quota", "Batas 10 permintaan per hari dari Clarity tercapai.")
                break
            except Exception as e:  # noqa: BLE001
                tried.append({"source": source, "result": str(e)[:160]})
                outcome = ("error", str(e)[:160])
                continue
            n += 1
            try:
                b, note = fetch(token, "URL"), "OK"
            except Exception:  # noqa: BLE001  # totals are enough to show; pages come next time
                b, note = [], "OK (tanpa rincian halaman)"
            tried.append({"source": source, "result": note})
            outcome = (a, b)
            break
        st.update(quota={"date": today(), "used": min(n, DAILY_LIMIT)}, tried=tried)
        if isinstance(outcome, tuple) and not isinstance(outcome[0], str):
            totals, lists = summarize(outcome[0])
            pgs = pages(outcome[1])
            st.update(state="ok", at=t, error=None, totals=totals, lists=lists, pages=pgs)
            site = site_of(pgs)
            if site:
                st["site"] = site
            hist = [h for h in st.get("history") or [] if h.get("date") != today()]
            hist.append(dict(totals, date=today()))
            hist.sort(key=lambda h: h.get("date", ""))
            st["history"] = hist[-HISTORY_DAYS:]
        elif outcome:
            st.update(state=outcome[0], error=outcome[1])
        self.save(st)
        return None
