//! Runtime operations (port of operations.py): health + backup probes, reboot detection,
//! internet probe, incidents, WhatsApp notifications through Hermes, hourly rollups, the weekly
//! report, and the allowed actions.

use crate::core::{f, now, s};
use crate::metrics::{Metrics, KEEP_HOURS};
use crate::monitor::{expand, Monitor};
use crate::ops::{self, Tracker};
use crate::util::{self, log};
use crate::workspace::Workspace;
use rusqlite::params;
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};

pub const HEALTH_SCRIPT: &str = include_str!("../../remote/health.py");

/// (problem or None, detail) for one configured backup.
pub fn backup_problem(cfg: &Value, info: Option<&Value>, now: f64) -> (Option<String>, String) {
    let Some(info) = info else { return (Some("tidak bisa dicek".into()), "device tidak terjangkau".into()) };
    let files: Vec<(String, f64, f64)> = info.get("files").and_then(|f| f.as_array()).cloned().unwrap_or_default().iter()
        .filter_map(|x| x.as_array().map(|a| (a[0].as_str().unwrap_or("").to_string(), a[1].as_f64().unwrap_or(0.0), a[2].as_f64().unwrap_or(0.0)))).collect();
    let Some((path, size, mtime)) = files.last().cloned() else { return (Some("tidak ada file backup".into()), s(cfg, "glob").into()) };
    let min = cfg.get("minBytes").and_then(|v| v.as_f64()).unwrap_or(1.0);
    let age_h = (now - mtime) / 3600.0;
    if size < min {
        return (Some(format!("file terbaru kosong/terlalu kecil ({} B)", size as i64)), path);
    }
    if age_h > cfg.get("maxAgeHours").and_then(|v| v.as_f64()).unwrap_or(26.0) {
        return (Some(format!("backup terakhir {age_h:.0} jam lalu")), path);
    }
    let prev: Vec<f64> = files[..files.len() - 1].iter().map(|x| x.1).filter(|s| *s >= min).collect();
    if let Some(mx) = prev.iter().cloned().fold(None, |a: Option<f64>, b| Some(a.map_or(b, |a| a.max(b)))) {
        if size < mx * cfg.get("shrinkRatio").and_then(|v| v.as_f64()).unwrap_or(0.5) {
            return (Some(format!("ukuran turun drastis ({} KB vs {} KB)", size as i64 / 1024, mx as i64 / 1024)), path);
        }
    }
    (None, path)
}

pub fn guess_reason(hints: &str) -> &'static str {
    let h = hints.to_lowercase();
    if h.contains("under-voltage") {
        "kemungkinan karena daya kurang (under-voltage)"
    } else if h.contains("out of memory") || h.contains("oom-kill") {
        "kemungkinan karena RAM habis"
    } else if h.contains("watchdog") {
        "kemungkinan sistem macet lalu direset watchdog"
    } else if h.contains("thermal") {
        "kemungkinan karena terlalu panas"
    } else if h.contains("reboot") || h.contains("shutdown") || h.contains("power key") {
        "restart/shutdown yang disengaja"
    } else {
        ""
    }
}

pub struct Operations {
    pub mon: Arc<Monitor>,
    pub metrics: Arc<Metrics>,
    pub ws: Arc<Workspace>,
    pub cfg: Value,
    pub tracker: Mutex<Tracker>,
    pub health: Mutex<Map<String, Value>>,
    pub backups: Mutex<Vec<Value>>,
    pub internet_ok: Mutex<bool>,
}

impl Operations {
    pub fn new(mon: Arc<Monitor>, metrics: Arc<Metrics>, ws: Arc<Workspace>, cfg: Value) -> Operations {
        let mut open = Map::new();
        let mut closed = std::collections::HashMap::new();
        {
            let db = metrics.db.lock().unwrap();
            if let Ok(mut st) = db.prepare("SELECT rowid, key, kind, node, title, detail, started FROM incident WHERE ended IS NULL") {
                let rows = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?,
                                                    r.get::<_, String>(4)?, r.get::<_, Option<String>>(5)?, r.get::<_, f64>(6)?)));
                for (rowid, key, kind, node, title, detail, started) in rows.map(|it| it.filter_map(|r| r.ok()).collect::<Vec<_>>()).unwrap_or_default() {
                    open.insert(key.clone(), json!({"rowid": rowid, "key": key, "kind": kind, "node": node, "title": title, "detail": detail.unwrap_or_default(), "started": started}));
                }
            }
            let pairs: Vec<(String, f64)> = match db.prepare("SELECT key, max(ended) FROM incident WHERE ended IS NOT NULL AND ended > ? GROUP BY key") {
                Ok(mut st) => st.query_map([now() - 86400.0], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?))).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default(),
                Err(_) => vec![],
            };
            for (k, e) in pairs {
                closed.insert(k, e); // cooldowns survive a restart
            }
        }
        let mut tracker = Tracker::new(open);
        tracker.last_closed = closed;
        let health = metrics.get("health").and_then(|h| h.as_object().cloned()).unwrap_or_default();
        Operations { mon, metrics, ws, cfg, tracker: Mutex::new(tracker), health: Mutex::new(health), backups: Mutex::new(vec![]), internet_ok: Mutex::new(true) }
    }

    fn nodes(&self) -> Vec<Value> {
        self.cfg.get("nodes").and_then(|n| n.as_array()).cloned().unwrap_or_default()
    }

    // ── probes ──
    pub fn probe_health(&self) -> Vec<Value> {
        let t = now();
        let mut reboots = vec![];
        for n in self.nodes() {
            let id = s(&n, "id").to_string();
            let prev = self.health.lock().unwrap().get(&id).cloned().unwrap_or(json!({}));
            let backups: Vec<Value> = self.cfg.get("backups").and_then(|b| b.as_array()).cloned().unwrap_or_default().into_iter().filter(|b| s(b, "node") == id).collect();
            let req = json!({"knownBoot": prev.get("bootId"), "backups": backups});
            let cmd = format!("sudo -n python3 -c {} {}", ops::shell_quote(HEALTH_SCRIPT), ops::shell_quote(&req.to_string()));
            let (out, _) = util::run_on(&n, &cmd, None, 60);
            let Some(h) = util::last_json_line(&out) else { continue };
            if let Some(pb) = prev.get("bootId").and_then(|b| b.as_str()) {
                if s(&h, "bootId") != pb {
                    let hints = h.pointer("/prevBoot/hints").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                    let reason = guess_reason(&hints);
                    let started = t - f(&h, "uptime");
                    let when = chrono::DateTime::from_timestamp(started as i64, 0).map(|d| d.with_timezone(&chrono::Local).format("%d %b %H:%M").to_string()).unwrap_or_default();
                    let last_hint: String = hints.lines().last().unwrap_or("").chars().take(160).collect();
                    let mut detail = reason.to_string();
                    if !reason.is_empty() && !last_hint.is_empty() {
                        detail.push_str(" · ");
                    }
                    detail.push_str(&last_hint);
                    if detail.is_empty() {
                        detail = "penyebab tidak tercatat di log".into();
                    }
                    reboots.push(json!({"node": s(&n, "name"), "when": when, "detail": detail}));
                    let tail = h.pointer("/prevBoot/tail").and_then(|x| x.as_str()).unwrap_or("");
                    let tail: String = tail.chars().rev().take(1500).collect::<Vec<_>>().into_iter().rev().collect();
                    self.record_event("reboot", &format!("reboot:{id}"), s(&n, "name"), &format!("{} restart sendiri", s(&n, "name")), &format!("{detail}\n{tail}"), started);
                }
            }
            self.health.lock().unwrap().insert(id.clone(), json!({"bootId": h["bootId"], "uptime": h["uptime"], "mmcErrors": h["mmcErrors"], "rootRO": h["rootRO"], "at": t}));
            self.merge_backups(&n, h.get("backups").and_then(|b| b.as_array()).cloned().unwrap_or_default(), t);
        }
        let hv = Value::Object(self.health.lock().unwrap().clone());
        self.metrics.put("health", &hv);
        reboots
    }

    fn merge_backups(&self, node: &Value, infos: Vec<Value>, t: f64) {
        let id = s(node, "id");
        let mut list = self.backups.lock().unwrap();
        list.retain(|b| s(b, "node") != id);
        for cb in self.cfg.get("backups").and_then(|b| b.as_array()).cloned().unwrap_or_default().iter().filter(|b| s(b, "node") == id) {
            let info = infos.iter().find(|i| s(i, "name") == s(cb, "name"));
            let (problem, detail) = backup_problem(cb, info, t);
            let latest = info.and_then(|i| i.get("files")).and_then(|f| f.as_array()).and_then(|a| a.last()).cloned().unwrap_or(Value::Null);
            list.push(json!({"name": s(cb, "name"), "node": id, "nodeName": s(node, "name"), "problem": problem, "detail": detail, "latest": latest,
                             "count": info.map(|i| f(i, "count") as i64).unwrap_or(0), "maxAgeHours": cb.get("maxAgeHours").cloned().unwrap_or(json!(26)), "checkedAt": t}));
        }
    }

    pub fn probe_internet(&self) -> bool {
        let probes: Vec<String> = self.cfg.get("internetProbes").and_then(|p| p.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_else(|| vec!["https://1.1.1.1/".into(), "https://www.google.com/generate_204".into()]);
        crate::net::internet_ok(&probes)
    }

    // ── incidents ──
    pub fn record_event(&self, kind: &str, key: &str, node: &str, title: &str, detail: &str, t: f64) {
        let db = self.metrics.db.lock().unwrap();
        let _ = db.execute("INSERT INTO incident VALUES (?,?,?,?,?,?,?)", params![key, kind, node, title, detail, t, t]);
    }

    pub fn evaluate(&self, reboots: &[Value]) {
        let t = now();
        let sites = self.mon.site_list();
        let certs = self.mon.certs_by_url(&sites);
        // One lock at a time (copies), never several held together.
        let detail = self.mon.detail.lock().unwrap().clone();
        let last = self.mon.last.lock().unwrap().clone();
        let status = self.mon.site_status.lock().unwrap().clone();
        let backups = self.backups.lock().unwrap().clone();
        let health = self.health.lock().unwrap().clone();
        let internet = *self.internet_ok.lock().unwrap();
        let conds = ops::conditions(&self.mon.nodes, &detail, &last, &sites, &status, &certs, &backups, &health, internet, t);
        let (mut opened, closed) = self.tracker.lock().unwrap().step(&conds, t);
        let mut rowids = vec![];
        {
            let db = self.metrics.db.lock().unwrap();
            for i in opened.iter_mut() {
                if db.execute("INSERT INTO incident VALUES (?,?,?,?,?,?,NULL)", params![s(i, "key"), s(i, "kind"), s(i, "node"), s(i, "title"), s(i, "detail"), f(i, "started")]).is_ok() {
                    let rowid = db.last_insert_rowid();
                    i["rowid"] = json!(rowid);
                    rowids.push((s(i, "key").to_string(), rowid));
                }
            }
            for i in &closed {
                if let Some(r) = i.get("rowid").and_then(|r| r.as_i64()) {
                    let _ = db.execute("UPDATE incident SET ended=? WHERE rowid=?", params![f(i, "ended"), r]);
                }
            }
        }
        {
            let mut tr = self.tracker.lock().unwrap();
            for (k, r) in rowids {
                if let Some(o) = tr.open.get_mut(&k) {
                    o["rowid"] = json!(r);
                }
            }
        }
        if let Some(text) = ops::message(&opened, &closed, reboots, s(&self.cfg, "publicUrl")) {
            self.notify(&text, false);
        }
    }

    pub fn incidents(&self, days: f64) -> Vec<Value> {
        let db = self.metrics.db.lock().unwrap();
        let t = now();
        let mut st = db.prepare("SELECT rowid, key, kind, node, title, detail, started, ended FROM incident WHERE coalesce(ended, ?) >= ? ORDER BY started DESC LIMIT 500").unwrap();
        st.query_map(params![t, t - days * 86400.0], |r| Ok(json!({"id": r.get::<_, i64>(0)?, "key": r.get::<_, String>(1)?, "kind": r.get::<_, String>(2)?,
            "node": r.get::<_, Option<String>>(3)?, "title": r.get::<_, String>(4)?, "detail": r.get::<_, Option<String>>(5)?, "started": r.get::<_, f64>(6)?, "ended": r.get::<_, Option<f64>>(7)?})))
            .map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    pub fn open_incidents(&self) -> Vec<Value> {
        self.tracker.lock().unwrap().open.values().cloned().collect()
    }

    // ── notifications ──
    pub fn notify(&self, text: &str, force: bool) -> Value {
        let n = self.cfg.get("notify").cloned().unwrap_or(json!({}));
        let enabled = n.get("enabled").and_then(|e| e.as_bool()).unwrap_or(false) && !s(&n, "target").is_empty();
        if !enabled && !force {
            return json!({"ok": false, "error": "notifikasi nonaktif"});
        }
        if s(&n, "target").is_empty() {
            return json!({"ok": false, "error": "target belum diatur"});
        }
        let log_row = |ok: bool, err: Option<&str>| {
            let db = self.metrics.db.lock().unwrap();
            let _ = db.execute("INSERT INTO notify_log VALUES (?,?,?,?)", params![now(), ok as i64, err, text.chars().take(2000).collect::<String>()]);
        };
        if !force {
            let sent: i64 = self.metrics.db.lock().unwrap().query_row("SELECT count(*) FROM notify_log WHERE ok=1 AND t > ?", [now() - 3600.0], |r| r.get(0)).unwrap_or(0);
            if sent >= n.get("maxPerHour").and_then(|m| m.as_i64()).unwrap_or(6) {
                log_row(false, Some("ditahan: batas pesan per jam"));
                return json!({"ok": false, "error": "ditahan: batas pesan per jam"});
            }
        }
        let hermes = expand(if s(&n, "hermes").is_empty() { "~/.local/bin/hermes" } else { s(&n, "hermes") });
        let (out, code) = util::run(&[&hermes, "send", "--to", s(&n, "target"), "-q", text], None, 90);
        let ok = code == 0;
        let err: String = out.trim().chars().rev().take(300).collect::<Vec<_>>().into_iter().rev().collect();
        log_row(ok, if ok { None } else { Some(&err) });
        json!({"ok": ok, "error": if ok { Value::Null } else { json!(err) }})
    }

    pub fn notify_log(&self, limit: i64) -> Vec<Value> {
        let db = self.metrics.db.lock().unwrap();
        let mut st = db.prepare("SELECT t, ok, error, text FROM notify_log ORDER BY t DESC LIMIT ?").unwrap();
        st.query_map([limit], |r| Ok(json!({"t": r.get::<_, f64>(0)?, "ok": r.get::<_, i64>(1)? != 0, "error": r.get::<_, Option<String>>(2)?, "text": r.get::<_, Option<String>>(3)?})))
            .map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    // ── hourly rollup (30 days) ──
    pub fn rollup(&self) {
        let hour = ((now() / 3600.0).floor() * 3600.0) as i64 as f64;
        let db = self.metrics.db.lock().unwrap();
        let last: f64 = db.query_row("SELECT max(t) FROM sample_hour", [], |r| r.get::<_, Option<f64>>(0)).ok().flatten().unwrap_or(hour - 25.0 * 3600.0);
        let _ = db.execute("INSERT OR REPLACE INTO sample_hour SELECT node, CAST(t / 3600 AS INTEGER) * 3600 AS h, avg(cpu), max(cpu), avg(mem), max(mem), avg(temp), max(temp),
                            max(disk), avg(load), max(coalesce(thr, 0)), count(*) FROM sample WHERE t >= ? AND t < ? GROUP BY node, h", params![last + 3600.0, hour]);
        let _ = db.execute("DELETE FROM sample_hour WHERE t < ?", [hour - KEEP_HOURS * 3600.0]);
    }

    pub fn history30(&self, node: &str, days: f64) -> Vec<Value> {
        let db = self.metrics.db.lock().unwrap();
        let mut st = db.prepare("SELECT t, cpu, cpu_max, mem, mem_max, temp, temp_max, disk, load, thr FROM sample_hour WHERE node=? AND t>=? ORDER BY t").unwrap();
        st.query_map(params![node, now() - days * 86400.0], |r| {
            let g = |i: usize| r.get::<_, Option<f64>>(i);
            Ok(json!({"t": g(0)?, "cpu": g(1)?, "cpuMax": g(2)?, "mem": g(3)?, "memMax": g(4)?, "temp": g(5)?, "tempMax": g(6)?, "disk": g(7)?, "load": g(8)?, "thr": r.get::<_, Option<i64>>(9)?}))
        }).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    // ── weekly report ──
    pub fn report_text(&self) -> String {
        let t = now();
        let sites = self.mon.site_list();
        let mut uptime = Map::new();
        let mut temps = Map::new();
        {
            let db = self.metrics.db.lock().unwrap();
            for st in &sites {
                if let Ok(Some(u)) = db.query_row("SELECT avg(ok) FROM site_check WHERE url=?", [s(st, "url")], |r| r.get::<_, Option<f64>>(0)) {
                    uptime.insert(s(st, "url").into(), json!(u));
                }
            }
            for n in self.nodes() {
                if let Ok((Some(a), Some(m))) = db.query_row("SELECT avg(temp), max(temp_max) FROM sample_hour WHERE node=? AND t>=?", params![s(&n, "id"), t - 7.0 * 86400.0],
                                                             |r| Ok((r.get::<_, Option<f64>>(0)?, r.get::<_, Option<f64>>(1)?))) {
                    temps.insert(s(&n, "id").into(), json!({"avg": a, "max": m}));
                }
            }
        }
        let home = self.cfg.get("hermesHome").and_then(|h| h.as_str()).unwrap_or("~/.hermes");
        let tokens: i64 = crate::hermes::profiles(home).iter().map(|p| {
            crate::hermes::snapshot(s(p, "path"), None).get("days").and_then(|d| d.as_array()).map(|d| d.iter().map(|x| x["tokens"].as_i64().unwrap_or(0)).sum::<i64>()).unwrap_or(0)
        }).sum();
        let snap = self.ws.snapshot().unwrap_or(json!({"tasks": []}));
        let done = snap["tasks"].as_array().map(|a| a.iter().filter(|x| x["completed_at"].as_f64().map(|c| c >= t - 7.0 * 86400.0).unwrap_or(false)).count()).unwrap_or(0) as i64;
        let week = self.incidents(7.0);
        let failed = week.iter().filter(|i| s(i, "kind") == "job").count() as i64;
        ops::weekly_report(t, &week, &sites, &uptime, &self.nodes(), &temps, Some(tokens), done, failed)
    }

    pub fn maybe_weekly(&self) {
        let Some(w) = self.cfg.pointer("/notify/weekly") else { return };
        use chrono::{Datelike, Timelike};
        let n = chrono::Local::now();
        let key = n.format("%G-W%V").to_string();
        let wd = w.get("weekday").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
        let hr = w.get("hour").and_then(|x| x.as_u64()).unwrap_or(8) as u32;
        if n.weekday().num_days_from_monday() == wd && n.hour() >= hr && self.metrics.get("weeklySent").and_then(|v| v.as_str().map(String::from)) != Some(key.clone()) {
            self.metrics.put("weeklySent", &json!(key));
            let text = self.report_text();
            self.notify(&text, false);
        }
    }

    // ── actions ──
    pub fn action(&self, node_id: &str, kind: &str, target: &str, who: &str) -> Result<Value, String> {
        let node = self.nodes().into_iter().find(|n| s(n, "id") == node_id).ok_or("device tidak dikenal")?;
        let detail = self.mon.detail.lock().unwrap().get(node_id).cloned().unwrap_or(json!({}));
        let (cmd, desc) = ops::action_command(kind, target, &detail, &self.cfg)?;
        let (out, code) = util::run_on(&node, &cmd, None, if kind == "run-job" { 900 } else { 120 });
        let out: String = out.chars().rev().take(4000).collect::<Vec<_>>().into_iter().rev().collect();
        {
            let db = self.metrics.db.lock().unwrap();
            let _ = db.execute("INSERT INTO action_log VALUES (?,?,?,?,?,?,?)", params![now(), s(&node, "name"), kind, target, who, (code == 0) as i64, out]);
        }
        let mon = self.mon.clone();
        std::thread::spawn(move || mon.sample(&node));
        Ok(json!({"ok": code == 0, "description": desc, "output": out, "code": code}))
    }

    pub fn logs(&self, node_id: &str, kind: &str, target: &str) -> Result<Value, String> {
        let node = self.nodes().into_iter().find(|n| s(n, "id") == node_id).ok_or("device tidak dikenal")?;
        let detail = self.mon.detail.lock().unwrap().get(node_id).cloned().unwrap_or(json!({}));
        let cmd = ops::logs_command(kind, target, &detail)?;
        let (out, code) = util::run_on(&node, &cmd, None, 30);
        let out: String = out.chars().rev().take(60000).collect::<Vec<_>>().into_iter().rev().collect();
        Ok(json!({"ok": code == 0, "output": out}))
    }

    pub fn action_log(&self, limit: i64) -> Vec<Value> {
        let db = self.metrics.db.lock().unwrap();
        let mut st = db.prepare("SELECT t, node, kind, target, who, ok, output FROM action_log ORDER BY t DESC LIMIT ?").unwrap();
        st.query_map([limit], |r| Ok(json!({"t": r.get::<_, f64>(0)?, "node": r.get::<_, Option<String>>(1)?, "kind": r.get::<_, Option<String>>(2)?,
            "target": r.get::<_, Option<String>>(3)?, "who": r.get::<_, Option<String>>(4)?, "ok": r.get::<_, i64>(5)? != 0, "output": r.get::<_, Option<String>>(6)?})))
            .map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    // ── loops ──
    pub fn start(self: &Arc<Self>) {
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(45));
            loop {
                let t0 = now();
                let ok = me.probe_internet();
                *me.internet_ok.lock().unwrap() = ok;
                me.evaluate(&[]);
                me.rollup();
                me.maybe_weekly();
                std::thread::sleep(std::time::Duration::from_secs_f64((60.0 - (now() - t0)).max(5.0)));
            }
        });
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(30));
            loop {
                let t0 = now();
                let reboots = me.probe_health();
                if !reboots.is_empty() {
                    me.evaluate(&reboots);
                }
                std::thread::sleep(std::time::Duration::from_secs_f64((600.0 - (now() - t0)).max(5.0)));
            }
        });
        log("operations loops started");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::tests::base;

    #[test]
    fn backup_rules() {
        let cfg = json!({"name": "DB", "glob": "/x/*.dump", "maxAgeHours": 26, "minBytes": 1000});
        let t = base();
        assert_eq!(backup_problem(&cfg, Some(&json!({"files": []})), t).0.unwrap(), "tidak ada file backup");
        assert!(backup_problem(&cfg, Some(&json!({"files": [["/x/a", 0, t]]})), t).0.unwrap().contains("kosong"));
        assert!(backup_problem(&cfg, Some(&json!({"files": [["/x/a", 5000, t - 40.0 * 3600.0]]})), t).0.unwrap().contains("40 jam"));
        assert!(backup_problem(&cfg, Some(&json!({"files": [["/x/a", 9000, t - 90000.0], ["/x/b", 2000, t]]})), t).0.unwrap().contains("turun drastis"));
        assert!(backup_problem(&cfg, Some(&json!({"files": [["/x/a", 9000, t - 90000.0], ["/x/b", 9100, t - 3600.0]]})), t).0.is_none());
        assert_eq!(backup_problem(&cfg, None, t).0.unwrap(), "tidak bisa dicek");
        assert!(guess_reason("kernel: Under-voltage detected!").contains("under-voltage"));
        assert!(guess_reason("watchdog: watchdog0").contains("watchdog"));
    }
}
