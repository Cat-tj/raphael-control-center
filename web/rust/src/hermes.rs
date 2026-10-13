//! Hermes sessions and token use from state.db, read-only (port of hermes.py).

use crate::core::now;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};

const SESSION_COLS: &str = "id, coalesce(nullif(title,''), nullif(display_name,''), substr(id,1,15)), source, coalesce(model,''),
  parent_session_id, started_at, last_activity_at, ended_at IS NULL, message_count, tool_call_count,
  api_call_count, input_tokens, cache_read_tokens, output_tokens, coalesce(actual_cost_usd, estimated_cost_usd, 0)";

/// [{id, name, path}] for the main Hermes home and each profile with a state.db.
pub fn profiles(home: &str) -> Vec<Value> {
    let home = crate::monitor::expand(home);
    let mut out = vec![];
    if std::path::Path::new(&home).join("state.db").exists() {
        out.push(json!({"id": "default", "name": "Raphael", "path": home}));
    }
    let mut ps: Vec<_> = glob::glob(&format!("{home}/profiles/*/state.db")).map(|g| g.filter_map(|p| p.ok()).collect()).unwrap_or_default();
    ps.sort();
    for p in ps {
        let dir = p.parent().unwrap();
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let pretty: String = name.split('-').map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }).collect::<Vec<_>>().join(" ").replace("V3", "-V3").replace(" -V3", "-V3");
        out.push(json!({"id": name, "name": pretty, "path": dir.to_string_lossy()}));
    }
    out
}

fn session(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({"id": r.get::<_, String>(0)?, "title": r.get::<_, Option<String>>(1)?, "source": r.get::<_, Option<String>>(2)?, "model": r.get::<_, Option<String>>(3)?,
              "parent": r.get::<_, Option<String>>(4)?, "startedAt": r.get::<_, Option<f64>>(5)?, "lastActivity": r.get::<_, Option<f64>>(6)?,
              "active": r.get::<_, Option<i64>>(7)?.unwrap_or(0) == 1, "messages": r.get::<_, Option<i64>>(8)?.unwrap_or(0),
              "toolCalls": r.get::<_, Option<i64>>(9)?.unwrap_or(0), "apiCalls": r.get::<_, Option<i64>>(10)?.unwrap_or(0),
              "input": r.get::<_, Option<i64>>(11)?.unwrap_or(0), "cacheRead": r.get::<_, Option<i64>>(12)?.unwrap_or(0),
              "output": r.get::<_, Option<i64>>(13)?.unwrap_or(0), "cost": r.get::<_, Option<f64>>(14)?.unwrap_or(0.0)}))
}

pub fn snapshot(path: &str, now_t: Option<f64>) -> Value {
    let t = now_t.unwrap_or_else(now);
    let db_path = std::path::Path::new(path).join("state.db");
    if !db_path.exists() {
        return json!({"error": "state.db tidak ditemukan"});
    }
    let db = match Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX) {
        Ok(d) => d,
        Err(e) => return json!({"error": e.to_string()}),
    };
    let _ = db.busy_timeout(std::time::Duration::from_secs(5));
    let week = t - 7.0 * 86400.0;
    let midnight = crate::workspace::start_of_day(t);
    let r: rusqlite::Result<Value> = (|| {
        let i = |r: &rusqlite::Row, n: usize| -> rusqlite::Result<i64> { Ok(r.get::<_, Option<i64>>(n)?.unwrap_or(0)) };
        let days: Vec<Value> = db.prepare("SELECT date(started_at,'unixepoch','localtime'), count(*), sum(api_call_count), sum(input_tokens), sum(cache_read_tokens), sum(output_tokens)
                                           FROM sessions WHERE started_at > ? GROUP BY 1 ORDER BY 1")?
            .query_map([week], |r| Ok(json!({"date": r.get::<_, Option<String>>(0)?, "sessions": i(r, 1)?, "calls": i(r, 2)?, "input": i(r, 3)?, "cacheRead": i(r, 4)?,
                                             "output": i(r, 5)?, "tokens": i(r, 3)? + i(r, 4)? + i(r, 5)?})))?.filter_map(|x| x.ok()).collect();
        let all = db.query_row("SELECT count(*), sum(api_call_count), sum(input_tokens), sum(cache_read_tokens), sum(output_tokens),
                                sum(coalesce(actual_cost_usd, estimated_cost_usd, 0)) FROM sessions", [], |r| {
            Ok(json!({"sessions": i(r, 0)?, "calls": i(r, 1)?, "input": i(r, 2)?, "cacheRead": i(r, 3)?, "output": i(r, 4)?, "cost": r.get::<_, Option<f64>>(5)?.unwrap_or(0.0)}))
        })?;
        let today = db.query_row("SELECT sum(api_call_count), sum(input_tokens+cache_read_tokens+output_tokens) FROM sessions WHERE started_at > ?", [midnight],
                                 |r| Ok(json!({"calls": i(r, 0)?, "tokens": i(r, 1)?})))?;
        let bucket = |r: &rusqlite::Row| -> rusqlite::Result<Value> { Ok(json!({"name": r.get::<_, Option<String>>(0)?.unwrap_or_else(|| "?".into()), "sessions": i(r, 1)?, "calls": i(r, 2)?, "tokens": i(r, 3)?})) };
        let sources: Vec<Value> = db.prepare("SELECT source, count(*), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens) FROM sessions WHERE started_at > ? GROUP BY source ORDER BY 4 DESC")?
            .query_map([week], |r| bucket(r))?.filter_map(|x| x.ok()).collect();
        let models: Vec<Value> = db.prepare("SELECT model, count(DISTINCT session_id), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens) FROM session_model_usage WHERE last_seen > ? GROUP BY 1 ORDER BY 4 DESC LIMIT 8")
            .and_then(|mut st| st.query_map([week], |r| bucket(r)).map(|it| it.filter_map(|x| x.ok()).collect()))
            .unwrap_or_default(); // older Hermes without per-model usage
        let recent: Vec<Value> = db.prepare(&format!("SELECT {SESSION_COLS} FROM sessions WHERE hidden = 0 ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT 25"))?
            .query_map([], session)?.filter_map(|x| x.ok()).collect();
        Ok(json!({"days": days, "allTime": all, "today": today, "sources": sources, "models": models, "recent": recent,
                  "dbBytes": std::fs::metadata(&db_path).map(|m| m.len()).unwrap_or(0), "at": t}))
    })();
    r.unwrap_or_else(|e| json!({"error": format!("state.db tidak terbaca: {e}")}))
}
