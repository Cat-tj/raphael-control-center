//! Collector output → detail records, job health and alerts (port of core.py). JSON in, JSON out:
//! the shapes are the API contract the web UI reads.

use crate::cron::CronExpr;
use serde_json::{json, Map, Value};

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

// ── small JSON helpers ──
pub fn f(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0)
}
pub fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("")
}
pub fn b(v: &Value, k: &str) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(false)
}
pub fn arr<'a>(v: &'a Value, k: &str) -> &'a [Value] {
    v.get(k).and_then(|x| x.as_array()).map(|a| a.as_slice()).unwrap_or(&[])
}
fn num_opt(v: &Value, k: &str) -> Option<f64> {
    v.get(k).filter(|x| !x.is_boolean()).and_then(|x| x.as_f64())
}

pub fn iso(v: Option<&Value>) -> Option<f64> {
    let s = v?.as_str()?;
    if s.is_empty() {
        return None;
    }
    let s = s.replace('Z', "+00:00");
    chrono::DateTime::parse_from_rfc3339(&s)
        .or_else(|_| chrono::DateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%.f%:z"))
        .map(|d| d.timestamp_millis() as f64 / 1000.0)
        .ok()
        .or_else(|| chrono::NaiveDateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%.f").ok().map(|d| d.and_utc().timestamp() as f64))
}

fn date(j: &Value, k: &str) -> Option<f64> {
    if let Some(n) = num_opt(j, k) {
        if n > 0.0 {
            return Some(n);
        }
    }
    iso(j.get(&format!("{k}ISO"))).or_else(|| iso(j.get(k)))
}

const KINDS: [(&str, &str); 4] = [("cron", "Cron"), ("timer", "systemd timer"), ("launchd", "launchd"), ("hermes", "Hermes cron")];

pub fn health_title(h: &str) -> &'static str {
    match h {
        "ok" => "OK",
        "failed" => "Gagal",
        "missed" => "Terlewat",
        "running" => "Berjalan",
        "scheduled" => "Terjadwal",
        "disabled" => "Nonaktif",
        _ => "Belum diketahui",
    }
}

/// Collector job dict → the fields the UI shows, with health computed like MJob.
pub fn job(j: &Value, tz: i32, now: f64) -> Value {
    let kind = KINDS.iter().find(|(k, _)| *k == s(j, "kind")).copied().unwrap_or(KINDS[0]);
    let expr = s(j, "expr").to_string();
    let cron = CronExpr::parse(&expr);
    let history: Vec<Value> = arr(j, "history")
        .iter()
        .filter_map(|r| r.as_array())
        .map(|r| {
            json!({"started": iso(r.first()), "finished": iso(r.get(1)),
                   "status": r.get(2).and_then(|x| x.as_str()).unwrap_or(""), "error": r.get(3).and_then(|x| x.as_str()).unwrap_or("")})
        })
        .collect();
    let enabled = j.get("enabled").and_then(|x| x.as_bool()) != Some(false);
    let log_modified = num_opt(j, "logModified");
    let mut last = date(j, "last");
    let mut next = date(j, "next");
    if last.is_none() {
        last = log_modified;
    }
    if next.is_none() {
        next = cron.as_ref().and_then(|c| c.next(now, tz));
    }
    if last.is_none() && kind.0 == "hermes" {
        last = history.first().and_then(|h| h["started"].as_f64());
    }
    let expected_last = cron.as_ref().and_then(|c| c.previous(now, tz));
    let status = s(j, "status").to_string();
    let failure_streak = f(j, "failureStreak") as i64;
    let missed = enabled
        && ((kind.0 != "cron" && next.map(|n| n < now - 900.0).unwrap_or(false))
            || match (expected_last, last) {
                (Some(exp), Some(l)) if now - exp > 600.0 => exp - l > 300.0,
                _ => false,
            });
    let health = if !enabled {
        "disabled"
    } else if status == "failed" || failure_streak > 0 {
        "failed"
    } else if status == "running" {
        "running"
    } else if missed {
        "missed"
    } else if status == "ok" {
        "ok"
    } else if last.is_none() && kind.0 != "cron" && next.map(|n| n > now).unwrap_or(false) {
        "scheduled"
    } else {
        "unknown"
    };
    let schedule = s(j, "schedule");
    let schedule_text = if !schedule.is_empty() {
        schedule.to_string()
    } else if let Some(c) = &cron {
        c.describe()
    } else if expr.is_empty() {
        "–".into()
    } else {
        expr.clone()
    };
    let user = if !s(j, "user").is_empty() { s(j, "user") } else { s(j, "profile") };
    let source = if !s(j, "source").is_empty() { s(j, "source") } else { s(j, "unit") };
    json!({
        "id": s(j, "id"), "kind": kind.0, "kindTitle": kind.1, "name": if s(j, "name").is_empty() { "?" } else { s(j, "name") }, "expr": expr,
        "command": s(j, "command"), "user": user, "source": source, "enabled": enabled, "system": b(j, "system"),
        "next": next, "last": last, "status": status, "detail": s(j, "detail").trim(), "log": j.get("log").cloned().unwrap_or(Value::Null),
        "logModified": log_modified, "failureStreak": failure_streak, "workdir": s(j, "workdir"), "history": history,
        "expectedLast": expected_last, "missed": missed, "health": health, "healthTitle": health_title(health), "scheduleText": schedule_text,
    })
}

#[cfg_attr(not(test), allow(dead_code))]
pub fn mem_bytes(text: &str) -> f64 {
    let t = text.trim();
    let n: String = t.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
    let v: f64 = n.parse().unwrap_or(0.0);
    let unit = t[n.len()..].trim().to_lowercase();
    v * if unit.starts_with('g') { 1073741824.0 } else if unit.starts_with('m') { 1048576.0 } else if unit.starts_with('k') { 1024.0 } else { 1.0 }
}

pub fn container_healthy(status: &str) -> bool {
    status.starts_with("Up") && !status.contains("unhealthy") && !status.contains("Restarting")
}

/// Collector JSON → one detail record (what the latest sample said).
pub fn parse(j: &Value, now: f64, previous: Option<&Value>, slow: bool) -> Value {
    let disks: Vec<Value> = arr(j, "disks")
        .iter()
        .filter_map(|a| a.as_array().filter(|a| a.len() >= 3))
        .map(|a| json!({"mount": a[0].as_str().unwrap_or(""), "used": a[1].as_f64().unwrap_or(0.0), "totalGB": a[2].as_f64().unwrap_or(0.0)}))
        .collect();
    let root = disks.iter().find(|d| d["mount"] == "/").or(disks.first());
    let procs = |k: &str| -> Vec<Value> {
        arr(j, k)
            .iter()
            .filter_map(|a| a.as_array().filter(|a| a.len() >= 4))
            .map(|a| json!({"pid": a[0], "name": a[1], "cpu": a[2], "mem": a[3]}))
            .collect()
    };
    let mut containers: Vec<Value> = arr(j, "containers")
        .iter()
        .map(|c| {
            let st = s(c, "status");
            json!({"name": if s(c, "name").is_empty() { "?" } else { s(c, "name") }, "status": st, "cpu": f(c, "cpu"), "mem": s(c, "mem"),
                   "memPct": f(c, "memPct"), "restarts": f(c, "restarts") as i64, "project": s(c, "project"),
                   "ports": c.get("ports").cloned().unwrap_or(json!([])), "healthy": container_healthy(st)})
        })
        .collect();
    containers.sort_by(|a, b| {
        let ka = (a["healthy"].as_bool() == Some(true), -a["cpu"].as_f64().unwrap_or(0.0));
        let kb = (b["healthy"].as_bool() == Some(true), -b["cpu"].as_f64().unwrap_or(0.0));
        ka.partial_cmp(&kb).unwrap_or(std::cmp::Ordering::Equal)
    });
    let tz = f(j, "tz") as i32;
    let jobs: Vec<Value> = arr(j, "jobs").iter().map(|x| job(x, tz, now)).collect();
    let services: Vec<Value> = arr(j, "services")
        .iter()
        .map(|v| {
            let unit = s(v, "unit");
            json!({"unit": unit, "name": unit.replace(".service", ""), "user": b(v, "user"), "state": s(v, "state"), "sub": s(v, "sub"),
                   "mem": f(v, "mem"), "restarts": f(v, "restarts") as i64, "desc": s(v, "desc"), "running": s(v, "state") == "active"})
        })
        .collect();
    let routes: Vec<Value> = arr(j, "caddy")
        .iter()
        .map(|r| json!({"hosts": r.get("hosts").cloned().unwrap_or(json!([])), "proxy": r.get("proxy").cloned().unwrap_or(Value::Null), "root": r.get("root").cloned().unwrap_or(Value::Null)}))
        .collect();
    let mut d = json!({
        "at": now, "error": null, "cores": (f(j, "cores") as i64).max(1), "memTotalGB": f(j, "memTotal") / 1073741824.0, "uptime": f(j, "uptime"),
        "cpu": f(j, "cpu"), "mem": f(j, "mem"), "swap": f(j, "swap"), "load": f(j, "load"), "temp": j.get("temp").cloned().unwrap_or(Value::Null),
        "disk": root.map(|r| r["used"].clone()).unwrap_or(json!(0)), "throttled": j.get("throttled").cloned().unwrap_or(Value::Null), "disks": disks,
        "topCPU": procs("topCPU"), "topMem": procs("topMem"), "containers": containers,
        "failed": j.get("failed").cloned().unwrap_or(json!([])), "ips": j.get("ips").cloned().unwrap_or(json!([])), "tz": tz,
        "jobs": jobs, "services": services, "routes": routes, "tunnel": null,
        "hw": if j.get("hw").map(|h| h.is_object()).unwrap_or(false) { j["hw"].clone() } else { previous.and_then(|p| p.get("hw")).cloned().unwrap_or(Value::Null) },
    });
    let m = d.as_object_mut().unwrap();
    for (k, jk) in [("updates", "updates"), ("securityUpdates", "security"), ("sshFails", "sshFails"), ("rebootRequired", "reboot")] {
        let v = if slow { j.get(jk).cloned() } else { previous.and_then(|p| p.get(k)).cloned() };
        m.insert(k.into(), v.unwrap_or(Value::Null));
    }
    if let Some(t) = j.get("tunnel").filter(|t| t.is_object()) {
        let codes: Map<String, Value> = t.get("codes").and_then(|c| c.as_object()).map(|c| c.iter().map(|(k, v)| (k.clone(), json!(v.as_f64().unwrap_or(0.0)))).collect()).unwrap_or_default();
        m.insert("tunnel".into(), json!({"total": f(t, "total"), "errors": f(t, "errors"), "connections": f(t, "ha"), "concurrent": f(t, "concurrent"),
                                         "codes": codes, "hosts": t.get("hosts").cloned().unwrap_or(json!([]))}));
    }
    d
}

pub fn throttle_text(hex: &str) -> String {
    let Ok(v) = i64::from_str_radix(hex.trim_start_matches("0x"), 16) else { return hex.to_string() };
    let now: Vec<&str> = [(0x1, "undervoltage"), (0x2, "frekuensi dibatasi"), (0x4, "throttled"), (0x8, "batas suhu")].iter().filter(|(b, _)| v & b != 0).map(|x| x.1).collect();
    let past: Vec<&str> = [(0x10000, "undervoltage"), (0x40000, "throttled"), (0x80000, "batas suhu")].iter().filter(|(b, _)| v & b != 0).map(|x| x.1).collect();
    let mut out = String::new();
    if !now.is_empty() {
        out += &format!("sekarang: {}", now.join(", "));
    }
    if !past.is_empty() {
        if !out.is_empty() {
            out += " · ";
        }
        out += &format!("pernah: {}", past.join(", "));
    }
    out
}

pub fn site_ok(st: &Value) -> bool {
    st.is_object() && st.get("error").map(|e| e.is_null() || e == "").unwrap_or(true) && (200..400).contains(&(f(st, "code") as i64))
}

/// Same rules as MonitorStore.alerts. level: 2 bad, 1 warn, 0 info.
pub fn alerts(nodes: &[Value], details: &Map<String, Value>, last: &Map<String, Value>, sites: &[Value], site_status: &Map<String, Value>,
              certs: &Map<String, Value>, now: f64) -> Vec<Value> {
    let mut out = vec![];
    let mut add = |node: &str, level: i64, text: String, kind: &str| out.push(json!({"node": node, "level": level, "text": text, "kind": kind}));
    for n in nodes {
        let Some(d) = details.get(s(n, "id")) else { continue };
        let name = s(n, "name");
        if let Some(e) = d.get("error").and_then(|e| e.as_str()) {
            add(name, 2, format!("Tidak bisa diambil datanya: {e}"), "server");
            continue;
        }
        let empty = json!({});
        let smp = last.get(s(n, "id")).unwrap_or(&empty);
        for disk in arr(d, "disks") {
            let u = f(disk, "used");
            if u > 0.85 {
                add(name, if u > 0.93 { 2 } else { 1 }, format!("Disk {} {}% penuh", s(disk, "mount"), (u * 100.0) as i64), "server");
            }
        }
        if f(smp, "mem") > 0.9 {
            let swap = if f(smp, "swap") > 0.5 { format!(", swap {}%", (f(smp, "swap") * 100.0) as i64) } else { String::new() };
            add(name, 1, format!("RAM {}% terpakai{swap}", (f(smp, "mem") * 100.0) as i64), "server");
        }
        if let Some(t) = num_opt(smp, "temp").filter(|t| *t > 75.0) {
            add(name, if t > 80.0 { 2 } else { 1 }, format!("Suhu {}°C", t as i64), "server");
        }
        let thr = s(d, "throttled");
        if !thr.is_empty() && thr != "0x0" {
            add(name, 1, format!("Daya/suhu: {}. Cek adaptor daya & pendingin", throttle_text(thr)), "server");
        }
        let cores = f(d, "cores").max(1.0);
        if f(smp, "load") > cores * 1.5 {
            add(name, 1, format!("Load {:.1} untuk {} core", f(smp, "load"), cores as i64), "server");
        }
        for c in arr(d, "containers") {
            if !b(c, "healthy") {
                add(name, 2, format!("Container {}: {}", s(c, "name"), s(c, "status")), "server");
            }
            if f(c, "restarts") > 3.0 {
                add(name, 1, format!("Container {} restart {}×", s(c, "name"), f(c, "restarts") as i64), "server");
            }
        }
        for fl in arr(d, "failed") {
            add(name, 2, format!("Service gagal: {}", fl.as_str().unwrap_or("")), "server");
        }
        for jb in arr(d, "jobs") {
            let h = s(jb, "health");
            if b(jb, "system") && h != "failed" {
                continue;
            }
            if h == "failed" {
                let det = s(jb, "detail");
                add(name, 2, format!("Job {} gagal{}", s(jb, "name"), if det.is_empty() { String::new() } else { format!(": {det}") }), "job");
            } else if h == "missed" {
                add(name, 1, format!("Job {} tidak jalan sesuai jadwal ({})", s(jb, "name"), s(jb, "scheduleText")), "job");
            }
        }
        let sec = f(d, "securityUpdates") as i64;
        if sec > 0 {
            add(name, 1, format!("{sec} update keamanan tertunda"), "server");
        } else if f(d, "updates") > 20.0 {
            add(name, 0, format!("{} update paket tertunda", f(d, "updates") as i64), "server");
        }
        if b(d, "rebootRequired") {
            add(name, 0, "Perlu reboot untuk menyelesaikan update".into(), "server");
        }
        let ssh = f(d, "sshFails") as i64;
        if ssh > 20 {
            add(name, if ssh > 200 { 2 } else { 1 }, format!("{ssh} login SSH gagal (24 jam)"), "server");
        }
        if let Some(t) = d.get("tunnel").filter(|t| t.is_object()) {
            if f(t, "connections") < 1.0 {
                add(name, 2, "Cloudflare tunnel tidak terhubung".into(), "server");
            }
        }
    }
    for site in sites {
        let url = s(site, "url");
        if let Some(st) = site_status.get(url) {
            if !site_ok(st) {
                let why = st.get("error").and_then(|e| e.as_str()).filter(|e| !e.is_empty()).map(String::from).unwrap_or_else(|| format!("HTTP {}", f(st, "code") as i64));
                add(s(site, "name"), 2, format!("Website down: {why}"), "site");
            }
        }
        if let Some(exp) = certs.get(url).and_then(|e| e.as_f64()) {
            let days = ((exp - now) / 86400.0).floor() as i64;
            if days < 14 {
                add(s(site, "name"), if days < 5 { 2 } else { 1 }, format!("Sertifikat SSL habis {days} hari lagi"), "site");
            }
        }
    }
    out.sort_by_key(|a| -a["level"].as_i64().unwrap_or(0));
    out
}

#[cfg(test)]
pub mod tests {
    use super::*;
    pub const TZ: i32 = 8 * 3600;
    pub fn base() -> f64 {
        use chrono::TimeZone;
        chrono::FixedOffset::east_opt(TZ).unwrap().with_ymd_and_hms(2026, 10, 11, 19, 7, 0).unwrap().timestamp() as f64
    }
    pub fn sample() -> Value {
        json!({"cpu": 0.25, "mem": 0.5, "swap": 0.1, "load": 0.4, "cores": 4, "memTotal": 4.0 * 1073741824.0, "tz": TZ,
               "disks": [["/boot", 0.2, 0.5], ["/", 0.95, 58]], "throttled": "0x50005",
               "containers": [{"name": "web-app", "status": "Up 2 days", "cpu": 1.5, "mem": "120MiB"},
                              {"name": "bad", "status": "Restarting (1) 3s ago", "restarts": 9}],
               "failed": ["proxy.service"], "jobs": [{"kind": "cron", "id": "x", "name": "db-backup", "expr": "30 2 * * *", "status": "failed", "detail": "Connection refused"}],
               "tunnel": {"total": 100, "ha": 0, "hosts": ["example.com", "*.wild.example"]}, "security": 5, "updates": 30})
    }

    #[test]
    fn job_health() {
        let now = now();
        let stale = job(&json!({"kind": "cron", "id": "a", "name": "backup", "expr": "30 2 * * *", "last": now - 2.0 * 86400.0, "status": "ok"}), TZ, now);
        assert_eq!((stale["missed"].as_bool(), stale["health"].as_str()), (Some(true), Some("missed")));
        let failing = job(&json!({"kind": "cron", "id": "b", "name": "backup", "expr": "30 2 * * *", "status": "failed", "detail": "pg_dump: error"}), TZ, now);
        assert_eq!(failing["health"], "failed");
        let unknown = job(&json!({"kind": "cron", "id": "c", "name": "x", "expr": "*/5 * * * *"}), TZ, now);
        assert_eq!((unknown["health"].as_str(), unknown["missed"].as_bool()), (Some("unknown"), Some(false)));
        assert_eq!(job(&json!({"kind": "timer", "id": "t", "name": "t", "next": now + 600.0}), TZ, now)["health"], "scheduled");
        assert_eq!(job(&json!({"kind": "timer", "id": "t", "name": "t", "next": now - 3600.0, "last": now - 7200.0, "status": "ok"}), TZ, now)["health"], "missed");
        assert_eq!(job(&json!({"kind": "cron", "id": "d", "name": "d", "expr": "* * * * *", "enabled": false, "status": "failed"}), TZ, now)["health"], "disabled");
        let h = job(&json!({"kind": "hermes", "id": "h", "name": "r", "expr": "0 8 * * *", "status": "ok", "history": [["2026-10-11T08:00:02Z", "2026-10-11T08:01:00Z", "ok", ""]]}), TZ, base());
        assert_eq!(h["last"].as_f64().unwrap() as i64, 1791705602);
    }

    #[test]
    fn parse_and_alerts() {
        let d = parse(&sample(), base(), None, true);
        assert_eq!(d["disk"], 0.95);
        assert_eq!(d["containers"][0]["name"], "bad");
        assert_eq!(mem_bytes("120MiB"), 120.0 * 1048576.0);
        let nodes = vec![json!({"id": "n", "name": "Box"})];
        let mut details = Map::new();
        details.insert("n".into(), d);
        let mut last = Map::new();
        last.insert("n".into(), json!({"mem": 0.95, "swap": 0.6, "load": 7, "temp": 82}));
        let a = alerts(&nodes, &details, &last, &[], &Map::new(), &Map::new(), base());
        let texts: Vec<String> = a.iter().map(|x| x["text"].as_str().unwrap().to_string()).collect();
        let all = texts.join(" | ");
        for want in ["Disk / 95%", "RAM 95%", "Suhu 82", "undervoltage", "Load 7.0", "Container bad", "restart 9×", "Service gagal: proxy",
                     "db-backup gagal: Connection refused", "5 update keamanan", "tunnel tidak terhubung"] {
            assert!(all.contains(want), "missing {want} in {all}");
        }
        assert_eq!(a[0]["level"], 2);
        assert_eq!(throttle_text("0x50005"), "sekarang: undervoltage, throttled · pernah: undervoltage, throttled");
        assert_eq!(throttle_text("0x0"), "");
        assert!(site_ok(&json!({"code": 301})));
        assert!(!site_ok(&json!({"code": 200, "error": "x"})));
    }
}
