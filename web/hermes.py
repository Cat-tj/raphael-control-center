"""Hermes agent activity for Raphael Web: the same state.db queries as the Mac app's
HermesStats.load, read-only (sqlite URI mode=ro), for ~/.hermes and every profile."""
from __future__ import annotations

import glob
import os
import sqlite3
import time
from datetime import datetime

SESSION_COLS = """id, coalesce(nullif(title,''), nullif(display_name,''), substr(id,1,15)), source, coalesce(model,''),
  parent_session_id, started_at, last_activity_at, ended_at IS NULL, message_count, tool_call_count,
  api_call_count, input_tokens, cache_read_tokens, output_tokens, coalesce(actual_cost_usd, estimated_cost_usd, 0)"""


def profiles(home: str = "~/.hermes") -> list:
    """[{id, name, path}] for the main Hermes home and each profile that has a state.db."""
    home = os.path.expanduser(home)
    out = []
    if os.path.exists(os.path.join(home, "state.db")):
        out.append({"id": "default", "name": "Raphael", "path": home})
    for p in sorted(glob.glob(os.path.join(home, "profiles", "*", "state.db"))):
        d = os.path.dirname(p)
        name = os.path.basename(d)
        if name.startswith("."):
            continue
        out.append({"id": name, "name": name.replace("-", " ").title().replace("V3", "-V3"), "path": d})
    return out


def _session(r) -> dict:
    return {"id": r[0], "title": r[1], "source": r[2], "model": r[3], "parent": r[4], "startedAt": r[5], "lastActivity": r[6],
            "active": r[7] == 1, "messages": r[8] or 0, "toolCalls": r[9] or 0, "apiCalls": r[10] or 0,
            "input": r[11] or 0, "cacheRead": r[12] or 0, "output": r[13] or 0, "cost": r[14] or 0}


def snapshot(path: str, now: float | None = None) -> dict:
    now = time.time() if now is None else now
    db_path = os.path.join(path, "state.db")
    if not os.path.exists(db_path):
        return {"error": "state.db tidak ditemukan"}
    week = now - 7 * 86400
    lt = time.localtime(now)
    midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    try:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error as e:
        return {"error": str(e)}
    try:
        q = lambda sql, *a: db.execute(sql, a).fetchall()  # noqa: E731
        days = q("""SELECT date(started_at,'unixepoch','localtime'), count(*), sum(api_call_count), sum(input_tokens),
                    sum(cache_read_tokens), sum(output_tokens) FROM sessions WHERE started_at > ? GROUP BY 1 ORDER BY 1""", week)
        allt = q("""SELECT count(*), sum(api_call_count), sum(input_tokens), sum(cache_read_tokens), sum(output_tokens),
                    sum(coalesce(actual_cost_usd, estimated_cost_usd, 0)) FROM sessions""")[0]
        today = q("SELECT sum(api_call_count), sum(input_tokens+cache_read_tokens+output_tokens) FROM sessions WHERE started_at > ?", midnight)[0]
        sources = q("""SELECT source, count(*), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens)
                       FROM sessions WHERE started_at > ? GROUP BY source ORDER BY 4 DESC""", week)
        try:
            models = q("""SELECT model, count(DISTINCT session_id), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens)
                          FROM session_model_usage WHERE last_seen > ? GROUP BY 1 ORDER BY 4 DESC LIMIT 8""", week)
        except sqlite3.Error:
            models = []                                   # older Hermes without per-model usage
        recent = q(f"SELECT {SESSION_COLS} FROM sessions WHERE hidden = 0 ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT 25")
    except sqlite3.Error as e:
        return {"error": f"state.db tidak terbaca: {e}"}
    finally:
        db.close()
    bucket = lambda r: {"name": r[0] or "?", "sessions": r[1] or 0, "calls": r[2] or 0, "tokens": r[3] or 0}  # noqa: E731
    return {
        "days": [{"date": r[0], "sessions": r[1], "calls": r[2] or 0, "input": r[3] or 0, "cacheRead": r[4] or 0, "output": r[5] or 0,
                  "tokens": (r[3] or 0) + (r[4] or 0) + (r[5] or 0)} for r in days],
        "allTime": {"sessions": allt[0] or 0, "calls": allt[1] or 0, "input": allt[2] or 0, "cacheRead": allt[3] or 0,
                    "output": allt[4] or 0, "cost": allt[5] or 0},
        "today": {"calls": today[0] or 0, "tokens": today[1] or 0},
        "sources": [bucket(r) for r in sources], "models": [bucket(r) for r in models],
        "recent": [_session(r) for r in recent],
        "dbBytes": os.path.getsize(db_path), "at": now,
        "day": datetime.fromtimestamp(now).strftime("%Y-%m-%d"),
    }
