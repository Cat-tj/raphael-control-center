//! metrics.sqlite: 24 h of samples and website checks, 30 days of hourly rollups, incidents,
//! notification and action logs, and a small key/value store. Same file and tables as the
//! Python server, so either can run on the same data.

use crate::core::now;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::sync::Mutex;

pub const KEEP: f64 = 24.0 * 3600.0;
pub const KEEP_HOURS: f64 = 30.0 * 24.0;

pub struct Metrics {
    pub db: Mutex<Connection>,
}

impl Metrics {
    pub fn open(path: &str) -> rusqlite::Result<Metrics> {
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
             CREATE TABLE IF NOT EXISTS sample (node TEXT, t REAL, cpu REAL, mem REAL, swap REAL, disk REAL, load REAL, temp REAL, rx REAL, tx REAL, req REAL);
             CREATE INDEX IF NOT EXISTS sample_node_t ON sample(node, t);
             CREATE TABLE IF NOT EXISTS site_check (url TEXT, t REAL, code INTEGER, ms INTEGER, ok INTEGER);
             CREATE INDEX IF NOT EXISTS site_url_t ON site_check(url, t);
             CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
             CREATE TABLE IF NOT EXISTS incident (key TEXT, kind TEXT, node TEXT, title TEXT, detail TEXT, started REAL, ended REAL);
             CREATE INDEX IF NOT EXISTS incident_started ON incident(started);
             CREATE TABLE IF NOT EXISTS sample_hour (node TEXT, t REAL, cpu REAL, cpu_max REAL, mem REAL, mem_max REAL, temp REAL, temp_max REAL,
                                                     disk REAL, load REAL, thr INTEGER, n INTEGER, PRIMARY KEY (node, t));
             CREATE TABLE IF NOT EXISTS notify_log (t REAL, ok INTEGER, error TEXT, text TEXT);
             CREATE TABLE IF NOT EXISTS action_log (t REAL, node TEXT, kind TEXT, target TEXT, who TEXT, ok INTEGER, output TEXT);",
        )?;
        let has_thr = db.prepare("SELECT 1 FROM pragma_table_info('sample') WHERE name='thr'")?.exists([])?;
        if !has_thr {
            db.execute_batch("ALTER TABLE sample ADD COLUMN thr INTEGER")?;
        }
        Ok(Metrics { db: Mutex::new(db) })
    }

    pub fn add_sample(&self, node: &str, s: &Value) {
        let db = self.db.lock().unwrap();
        let g = |k: &str| s.get(k).and_then(|v| v.as_f64());
        let _ = db.execute(
            "INSERT INTO sample (node, t, cpu, mem, swap, disk, load, temp, rx, tx, req, thr) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            params![node, g("t"), g("cpu"), g("mem"), g("swap"), g("disk"), g("load"), g("temp"), g("rx"), g("tx"), g("req"), s.get("thr").and_then(|v| v.as_i64())],
        );
        let _ = db.execute("DELETE FROM sample WHERE t < ?", [now() - KEEP]);
    }

    pub fn samples(&self, node: &str, hours: f64) -> Vec<Value> {
        let db = self.db.lock().unwrap();
        let mut st = db.prepare("SELECT t, cpu, mem, swap, disk, load, temp, rx, tx, req FROM sample WHERE node=? AND t>=? ORDER BY t").unwrap();
        st.query_map(params![node, now() - hours * 3600.0], |r| {
            Ok(json!({"t": r.get::<_, Option<f64>>(0)?, "cpu": r.get::<_, Option<f64>>(1)?, "mem": r.get::<_, Option<f64>>(2)?, "swap": r.get::<_, Option<f64>>(3)?,
                      "disk": r.get::<_, Option<f64>>(4)?, "load": r.get::<_, Option<f64>>(5)?, "temp": r.get::<_, Option<f64>>(6)?, "rx": r.get::<_, Option<f64>>(7)?,
                      "tx": r.get::<_, Option<f64>>(8)?, "req": r.get::<_, Option<f64>>(9)?}))
        })
        .map(|it| it.filter_map(|r| r.ok()).collect())
        .unwrap_or_default()
    }

    pub fn add_check(&self, url: &str, t: f64, code: i64, ms: i64, ok: bool) {
        let db = self.db.lock().unwrap();
        let _ = db.execute("INSERT INTO site_check VALUES (?,?,?,?,?)", params![url, t, code, ms, ok as i64]);
        let _ = db.execute("DELETE FROM site_check WHERE t < ?", [now() - KEEP]);
    }

    pub fn checks(&self, url: &str, hours: f64) -> Vec<Value> {
        let db = self.db.lock().unwrap();
        let mut st = db.prepare("SELECT t, code, ms, ok FROM site_check WHERE url=? AND t>=? ORDER BY t").unwrap();
        st.query_map(params![url, now() - hours * 3600.0], |r| {
            Ok(json!({"t": r.get::<_, f64>(0)?, "code": r.get::<_, Option<i64>>(1)?, "ms": r.get::<_, Option<i64>>(2)?, "ok": r.get::<_, i64>(3)? != 0}))
        })
        .map(|it| it.filter_map(|r| r.ok()).collect())
        .unwrap_or_default()
    }

    pub fn get(&self, key: &str) -> Option<Value> {
        let db = self.db.lock().unwrap();
        db.query_row("SELECT value FROM kv WHERE key=?", [key], |r| r.get::<_, String>(0)).ok().and_then(|s| serde_json::from_str(&s).ok())
    }

    pub fn put(&self, key: &str, value: &Value) {
        let db = self.db.lock().unwrap();
        let _ = db.execute("INSERT INTO kv VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key, value.to_string()]);
    }
}
