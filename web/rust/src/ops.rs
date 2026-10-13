//! Operations logic (port of ops.py): problem conditions, incident tracking with hysteresis and
//! damping, notification text, weekly report, and validation for the allowed actions.

use crate::core::{arr, b, f, s};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::OnceLock;

fn hold(kind: &str) -> u32 {
    match kind {
        "site" | "power" | "internet" => 2,
        "node" | "temp" => 3,
        _ => 1,
    }
}
fn close_hold(kind: &str) -> u32 {
    match kind {
        "power" => 10,
        "temp" => 5,
        _ => 1,
    }
}
fn cooldown(kind: &str) -> f64 {
    match kind {
        "power" | "temp" | "disk" => 6.0 * 3600.0,
        "sdcard" | "ssl" => 24.0 * 3600.0,
        _ => 0.0,
    }
}
fn emoji(kind: &str) -> &'static str {
    match kind {
        "site" => "🌐",
        "node" => "🖥",
        "temp" => "🌡",
        "power" => "⚡",
        "disk" => "💾",
        "job" => "⏰",
        "ssl" => "🔒",
        "backup" => "🗄",
        "internet" => "📡",
        "reboot" => "🔁",
        "sdcard" => "💽",
        _ => "⚠️",
    }
}

#[allow(clippy::too_many_arguments)]
pub fn conditions(nodes: &[Value], details: &Map<String, Value>, last: &Map<String, Value>, sites: &[Value], site_status: &Map<String, Value>,
                  certs: &Map<String, Value>, backups: &[Value], health: &Map<String, Value>, internet_ok: bool, now: f64) -> Map<String, Value> {
    let mut out = Map::new();
    let mut add = |key: String, kind: &str, node: &str, title: String, detail: String| {
        out.insert(key, json!({"kind": kind, "node": node, "title": title, "detail": detail}));
    };
    if !internet_ok {
        add("internet".into(), "internet", "Rumah", "Internet rumah putus".into(), "Server tidak bisa menjangkau internet; status website ditahan.".into());
    }
    let empty = json!({});
    for n in nodes {
        let id = s(n, "id");
        let name = s(n, "name");
        let d = details.get(id).unwrap_or(&empty);
        if let Some(e) = d.get("error").and_then(|e| e.as_str()) {
            add(format!("node:{id}"), "node", name, format!("{name} tidak terjangkau"), e.to_string());
            continue;
        }
        if d.as_object().map(|o| o.is_empty()).unwrap_or(true) {
            continue;
        }
        let smp = last.get(id).unwrap_or(&empty);
        if let Some(t) = smp.get("temp").and_then(|t| t.as_f64()).filter(|t| *t >= 80.0) {
            add(format!("temp:{id}"), "temp", name, format!("{name} panas {}°C", t as i64), "Cek pendingin / aliran udara".into());
        }
        let thr = s(d, "throttled");
        if !thr.is_empty() && thr != "0x0" && i64::from_str_radix(thr.trim_start_matches("0x"), 16).map(|v| v & 1 != 0).unwrap_or(false) {
            add(format!("power:{id}"), "power", name, format!("{name} kekurangan daya (undervoltage)"), "Ganti adaptor/kabel daya yang lebih kuat".into());
        }
        for disk in arr(d, "disks") {
            if f(disk, "used") >= 0.93 {
                add(format!("disk:{id}:{}", s(disk, "mount")), "disk", name, format!("Disk {} di {name} {}% penuh", s(disk, "mount"), (f(disk, "used") * 100.0) as i64), String::new());
            }
        }
        for j in arr(d, "jobs") {
            let h = s(j, "health");
            if b(j, "system") && h != "failed" {
                continue;
            }
            if h == "failed" {
                add(format!("job:{id}|{}", s(j, "id")), "job", name, format!("Job {} gagal", s(j, "name")), s(j, "detail").to_string());
            } else if h == "missed" {
                add(format!("job:{id}|{}", s(j, "id")), "job", name, format!("Job {} tidak jalan sesuai jadwal", s(j, "name")), s(j, "scheduleText").to_string());
            }
        }
        let h = health.get(id).unwrap_or(&empty);
        if b(h, "rootRO") {
            add(format!("sdcard:{id}"), "sdcard", name, format!("Filesystem / di {name} read-only"), "Biasanya tanda kartu SD/SSD bermasalah".into());
        } else if f(h, "mmcErrors") > 0.0 {
            add(format!("sdcard:{id}"), "sdcard", name, format!("Error kartu SD di {name} ({}× sejak boot)", f(h, "mmcErrors") as i64), "Siapkan cadangan & ganti kartu".into());
        }
    }
    if internet_ok {
        for site in sites {
            if let Some(st) = site_status.get(s(site, "url")) {
                if !st.get("ok").and_then(|o| o.as_bool()).unwrap_or(false) {
                    let why = st.get("error").and_then(|e| e.as_str()).filter(|e| !e.is_empty()).map(String::from).unwrap_or_else(|| format!("HTTP {}", f(st, "code") as i64));
                    add(format!("site:{}", s(site, "url")), "site", s(site, "name"), format!("{} down", s(site, "name")), why);
                }
            }
        }
    }
    for site in sites {
        if let Some(exp) = certs.get(s(site, "url")).and_then(|e| e.as_f64()) {
            if exp - now < 7.0 * 86400.0 {
                add(format!("ssl:{}", s(site, "url")), "ssl", s(site, "name"), format!("SSL {} habis {} hari lagi", s(site, "name"), (((exp - now) / 86400.0).floor() as i64).max(0)), String::new());
            }
        }
    }
    for bk in backups {
        if let Some(p) = bk.get("problem").and_then(|p| p.as_str()) {
            add(format!("backup:{}", s(bk, "name")), "backup", s(bk, "nodeName"), format!("Backup {}: {p}", s(bk, "name")), s(bk, "detail").to_string());
        }
    }
    out
}

/// Turns condition snapshots into incident open/close transitions.
#[derive(Default)]
pub struct Tracker {
    pub open: Map<String, Value>,
    streak: HashMap<String, u32>,
    clean: HashMap<String, u32>,
    pub last_closed: HashMap<String, f64>,
}

impl Tracker {
    pub fn new(open: Map<String, Value>) -> Tracker {
        Tracker { open, ..Default::default() }
    }

    /// (opened, closed). "quiet" incidents recurred within their cooldown: recorded, not sent.
    pub fn step(&mut self, conds: &Map<String, Value>, now: f64) -> (Vec<Value>, Vec<Value>) {
        let (mut opened, mut closed) = (vec![], vec![]);
        for (key, c) in conds {
            let st = self.streak.entry(key.clone()).or_insert(0);
            *st += 1;
            self.clean.remove(key);
            let kind = s(c, "kind").to_string();
            if !self.open.contains_key(key) && *st >= hold(&kind) {
                let quiet = now - self.last_closed.get(key).copied().unwrap_or(-1e18) < cooldown(&kind);
                let mut inc = c.clone();
                let o = inc.as_object_mut().unwrap();
                o.insert("key".into(), json!(key));
                o.insert("started".into(), json!(now));
                o.insert("quiet".into(), json!(quiet));
                self.open.insert(key.clone(), inc.clone());
                opened.push(inc);
            } else if let Some(o) = self.open.get_mut(key).and_then(|v| v.as_object_mut()) {
                o.insert("title".into(), c["title"].clone());
                o.insert("detail".into(), c["detail"].clone());
            }
        }
        let keys: Vec<String> = self.open.keys().cloned().collect();
        for key in keys {
            if conds.contains_key(&key) {
                continue;
            }
            let n = self.clean.entry(key.clone()).or_insert(0);
            *n += 1;
            let kind = s(&self.open[&key], "kind").to_string();
            if *n >= close_hold(&kind) {
                let mut inc = self.open.remove(&key).unwrap();
                self.clean.remove(&key);
                self.last_closed.insert(key, now);
                inc.as_object_mut().unwrap().insert("ended".into(), json!(now));
                closed.push(inc);
            }
        }
        self.streak.retain(|k, _| conds.contains_key(k));
        (opened, closed)
    }
}

pub fn duration(secs: f64) -> String {
    let s = secs.max(0.0) as i64;
    if s < 90 {
        format!("{s} detik")
    } else if s < 3600 {
        format!("{} menit", ((s as f64) / 60.0).round() as i64)
    } else if s < 86400 {
        format!("{} jam {} menit", s / 3600, (s % 3600) / 60)
    } else {
        format!("{} hari {} jam", s / 86400, (s % 86400) / 3600)
    }
}

/// One WhatsApp message for a round's transitions (None when there is nothing to say).
pub fn message(opened: &[Value], closed: &[Value], reboots: &[Value], base_url: &str) -> Option<String> {
    let opened: Vec<&Value> = opened.iter().filter(|i| !b(i, "quiet")).collect();
    let closed: Vec<&Value> = closed.iter().filter(|i| !b(i, "quiet")).collect();
    let mut lines = vec![];
    for i in &opened {
        let det = s(i, "detail");
        lines.push(format!("{} *{}*{}", emoji(s(i, "kind")), s(i, "title"), if det.is_empty() { String::new() } else { format!("\n   {}", det.chars().take(180).collect::<String>()) }));
    }
    for r in reboots {
        let det = s(r, "detail");
        lines.push(format!("🔁 *{} restart sendiri* ({}){}", s(r, "node"), s(r, "when"), if det.is_empty() { String::new() } else { format!("\n   {}", det.chars().take(220).collect::<String>()) }));
    }
    for i in &closed {
        lines.push(format!("✅ Pulih: {} (setelah {})", s(i, "title"), duration(f(i, "ended") - f(i, "started"))));
    }
    if lines.is_empty() {
        return None;
    }
    let alarm = !opened.is_empty() || !reboots.is_empty();
    Some(format!("{}\n{}{}", if alarm { "🚨 Raphael" } else { "Raphael" }, lines.join("\n"), if alarm && !base_url.is_empty() { format!("\n\n{base_url}") } else { String::new() }))
}

#[allow(clippy::too_many_arguments)]
pub fn weekly_report(now: f64, incidents: &[Value], sites: &[Value], uptime: &Map<String, Value>, nodes: &[Value], temps: &Map<String, Value>,
                     hermes_tokens: Option<i64>, tasks_done: i64, jobs_failed: i64) -> String {
    use chrono::{Local, TimeZone};
    let week = now - 7.0 * 86400.0;
    let fmt = |t: f64| Local.timestamp_opt(t as i64, 0).single().map(|d| d.format("%d %b").to_string()).unwrap_or_default();
    let ended = |i: &Value| i.get("ended").and_then(|e| e.as_f64()).unwrap_or(now);
    let recent: Vec<&Value> = incidents.iter().filter(|i| ended(i) >= week).collect();
    let down: f64 = recent.iter().filter(|i| s(i, "kind") == "site").map(|i| ended(i) - f(i, "started").max(week)).sum();
    let mut lines = vec![format!("📊 *Laporan mingguan Raphael* · {}–{}", fmt(week), fmt(now))];
    let ups: Vec<String> = sites.iter().filter_map(|st| uptime.get(s(st, "url")).and_then(|u| u.as_f64()).map(|u| format!("{} {:.1}%", s(st, "name"), u * 100.0))).take(8).collect();
    if !ups.is_empty() {
        lines.push(format!("🌐 Uptime: {}", ups.join(", ")));
    }
    lines.push(format!("🚨 Insiden: {}{}", recent.len(), if down > 0.0 { format!(" · website down total {}", duration(down)) } else { String::new() }));
    let mut worst = recent.clone();
    worst.sort_by(|a, b| (ended(b) - f(b, "started")).partial_cmp(&(ended(a) - f(a, "started"))).unwrap());
    for i in worst.iter().take(5) {
        let open = i.get("ended").map(|e| e.is_null()).unwrap_or(true);
        lines.push(format!("   • {} ({}{})", s(i, "title"), duration(ended(i) - f(i, "started")), if open { ", masih terbuka" } else { "" }));
    }
    for n in nodes {
        if let Some(t) = temps.get(s(n, "id")) {
            lines.push(format!("🌡 {}: rata-rata {:.0}°C, puncak {:.0}°C", s(n, "name"), f(t, "avg"), f(t, "max")));
        }
    }
    lines.push(format!("⏰ Job gagal: {jobs_failed}"));
    if let Some(t) = hermes_tokens {
        let digits = t.to_string();
        let mut grouped = String::new();
        for (i, c) in digits.chars().enumerate() {
            if i > 0 && (digits.len() - i) % 3 == 0 {
                grouped.push('.');
            }
            grouped.push(c);
        }
        lines.push(format!("🤖 Token Hermes 7 hari: {grouped}"));
    }
    lines.push(format!("✅ Task selesai: {tasks_done}"));
    lines.join("\n")
}

// ── Actions ──
fn name_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,120}$").unwrap())
}

pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

/// (shell command, description) for an allowed action.
pub fn action_command(kind: &str, target: &str, detail: &Value, cfg: &Value) -> Result<(String, String), String> {
    let allow = cfg.get("actions").cloned().unwrap_or(json!({}));
    if !name_re().is_match(target) {
        return Err("nama tidak valid".into());
    }
    match kind {
        "restart-service" => {
            let unit = if target.ends_with(".service") { target.to_string() } else { format!("{target}.service") };
            let bare = unit.trim_end_matches(".service");
            let listed = arr(&allow, "services").iter().any(|v| v.as_str() == Some(target) || v.as_str() == Some(bare));
            let known = arr(detail, "services").iter().any(|v| s(v, "unit") == unit) || arr(detail, "failed").iter().any(|v| v.as_str() == Some(unit.as_str()));
            if !listed && !known {
                return Err("service ini tidak ada di daftar yang diizinkan".into());
            }
            let user = arr(detail, "services").iter().find(|v| s(v, "unit") == unit).map(|v| b(v, "user")).unwrap_or(false);
            Ok((if user { format!("systemctl --user restart {unit}") } else { format!("sudo -n systemctl restart {unit}") }, format!("Restart service {unit}")))
        }
        "restart-container" => {
            if !b(&allow, "containers") {
                return Err("restart container tidak diizinkan di config".into());
            }
            if !arr(detail, "containers").iter().any(|c| s(c, "name") == target) {
                return Err("container tidak ditemukan di device ini".into());
            }
            Ok((format!("docker restart {target}"), format!("Restart container {target}")))
        }
        "run-job" => {
            if !b(&allow, "jobs") {
                return Err("menjalankan job tidak diizinkan di config".into());
            }
            let Some(job) = arr(detail, "jobs").iter().find(|j| s(j, "id") == target).filter(|j| !b(j, "system")) else {
                return Err("job tidak ditemukan (job sistem tidak bisa dijalankan dari sini)".into());
            };
            if s(job, "kind") == "hermes" {
                let parts: Vec<&str> = target.split(':').collect();
                if parts.len() < 3 || !name_re().is_match(parts[1]) || !name_re().is_match(parts[2]) {
                    return Err("id job Hermes tidak valid".into());
                }
                let home = if parts[1] == "default" || parts[1].is_empty() { "~/.hermes".to_string() } else { format!("~/.hermes/profiles/{}", parts[1]) };
                return Ok((format!("HERMES_HOME={home} ~/.local/bin/hermes cron run {}", parts[2]), format!("Jalankan job Hermes {}", s(job, "name"))));
            }
            if s(job, "kind") != "cron" || s(job, "command").is_empty() {
                return Err("hanya job cron dan Hermes yang bisa dijalankan".into());
            }
            let user = s(job, "user");
            if !user.is_empty() && !name_re().is_match(user) {
                return Err("user tidak valid".into());
            }
            let cmd = shell_quote(s(job, "command"));
            Ok((if !user.is_empty() && user != "pi" { format!("sudo -n -u {user} sh -c {cmd}") } else { format!("sh -c {cmd}") }, format!("Jalankan job {}", s(job, "name"))))
        }
        _ => Err("aksi tidak dikenal".into()),
    }
}

pub fn logs_command(kind: &str, target: &str, detail: &Value) -> Result<String, String> {
    if !name_re().is_match(target) {
        return Err("nama tidak valid".into());
    }
    match kind {
        "service" => {
            let unit = if target.ends_with(".service") { target.to_string() } else { format!("{target}.service") };
            let user = arr(detail, "services").iter().find(|v| s(v, "unit") == unit).map(|v| b(v, "user")).unwrap_or(false);
            Ok(if user { format!("journalctl --user -u {unit} -n 200 --no-pager -o short-iso") } else { format!("sudo -n journalctl -u {unit} -n 200 --no-pager -o short-iso") })
        }
        "container" => {
            if !arr(detail, "containers").iter().any(|c| s(c, "name") == target) {
                return Err("container tidak ditemukan".into());
            }
            Ok(format!("docker logs --tail 200 --timestamps {target} 2>&1"))
        }
        "job" => {
            let job = arr(detail, "jobs").iter().find(|j| s(j, "id") == target);
            match job.and_then(|j| j.get("log")).and_then(|l| l.as_str()) {
                Some(log) => Ok(format!("sudo -n tail -n 200 {}", shell_quote(log))),
                None => Err("job ini tidak menulis ke file log".into()),
            }
        }
        _ => Err("jenis log tidak dikenal".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{self, tests::{base, sample}};

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    #[test]
    fn conditions_cover_everything() {
        let nodes = vec![json!({"id": "a", "name": "Box A"}), json!({"id": "b", "name": "Box B"})];
        let details = obj(json!({"a": core::parse(&sample(), base(), None, true), "b": {"error": "timeout"}}));
        let c = conditions(&nodes, &details, &obj(json!({"a": {"temp": 82}})), &[json!({"name": "S", "url": "https://s"})],
                           &obj(json!({"https://s": {"code": 502, "ok": false}})), &obj(json!({"https://s": base() + 3.0 * 86400.0})),
                           &[json!({"name": "DB", "nodeName": "Box A", "problem": "backup terakhir 40 jam lalu"})], &obj(json!({"a": {"mmcErrors": 2}})), true, base());
        let kinds: std::collections::HashSet<&str> = c.values().map(|v| s(v, "kind")).collect();
        for k in ["node", "temp", "power", "disk", "job", "site", "ssl", "backup", "sdcard"] {
            assert!(kinds.contains(k), "{k}");
        }
        let off = conditions(&nodes, &details, &Map::new(), &[json!({"name": "S", "url": "https://s"})], &obj(json!({"https://s": {"code": 502}})),
                             &Map::new(), &[], &Map::new(), false, base());
        assert!(off.contains_key("internet") && !off.keys().any(|k| k.starts_with("site:")));
    }

    #[test]
    fn tracker_hysteresis_damping_and_message() {
        let mut tr = Tracker::default();
        let site = obj(json!({"site:https://s": {"kind": "site", "node": "S", "title": "S down", "detail": "HTTP 502"}}));
        assert!(tr.step(&site, 0.0).0.is_empty());
        let (opened, _) = tr.step(&site, 60.0);
        assert_eq!(opened.len(), 1);
        assert!(tr.step(&site, 120.0).0.is_empty());
        let (_, closed) = tr.step(&Map::new(), 900.0);
        assert_eq!(f(&closed[0], "ended") - f(&closed[0], "started"), 840.0);
        let msg = message(&opened, &closed, &[json!({"node": "Box A", "when": "13 Okt", "detail": "panas"})], "https://x").unwrap();
        assert!(msg.contains("*S down*") && msg.contains("Pulih: S down (setelah 14 menit)") && msg.contains("restart sendiri"));
        assert!(message(&[], &[], &[], "").is_none());
        let mut tr = Tracker::default();
        let p = obj(json!({"power:a": {"kind": "power", "node": "A", "title": "A undervoltage", "detail": ""}}));
        tr.step(&p, 0.0);
        assert!(!b(&tr.step(&p, 60.0).0[0], "quiet"));
        for i in 0..9 {
            assert!(tr.step(&Map::new(), 120.0 + i as f64 * 60.0).1.is_empty());
        }
        assert_eq!(tr.step(&Map::new(), 720.0).1.len(), 1);
        tr.step(&p, 800.0);
        let again = tr.step(&p, 860.0).0;
        assert!(b(&again[0], "quiet"));
        assert!(message(&again, &[], &[], "").is_none());
    }

    #[test]
    fn actions_are_allowlisted_and_quoted() {
        let detail = json!({"services": [{"unit": "app.service", "user": true}], "failed": ["nginx.service"], "containers": [{"name": "web-1"}],
            "jobs": [{"id": "c1", "kind": "cron", "name": "backup", "command": "echo 'hi'; rm -rf /tmp/x", "user": "root", "system": false},
                     {"id": "s1", "kind": "cron", "name": "logrotate", "command": "x", "system": true},
                     {"id": "hermes:michael:abc123", "kind": "hermes", "name": "seo", "system": false}]});
        let cfg = json!({"actions": {"services": ["caddy"], "containers": true, "jobs": true}});
        assert_eq!(action_command("restart-service", "app.service", &detail, &cfg).unwrap().0, "systemctl --user restart app.service");
        assert_eq!(action_command("restart-service", "nginx.service", &detail, &cfg).unwrap().0, "sudo -n systemctl restart nginx.service");
        assert_eq!(action_command("restart-service", "caddy", &detail, &cfg).unwrap().0, "sudo -n systemctl restart caddy.service");
        assert!(action_command("restart-service", "sshd", &detail, &cfg).is_err());
        assert!(action_command("restart-service", "x; reboot", &detail, &cfg).is_err());
        assert_eq!(action_command("restart-container", "web-1", &detail, &cfg).unwrap().0, "docker restart web-1");
        assert!(action_command("restart-container", "web-1", &detail, &json!({})).is_err());
        assert_eq!(action_command("run-job", "c1", &detail, &cfg).unwrap().0, "sudo -n -u root sh -c 'echo '\"'\"'hi'\"'\"'; rm -rf /tmp/x'");
        assert!(action_command("run-job", "s1", &detail, &cfg).is_err());
        assert!(action_command("run-job", "hermes:michael:abc123", &detail, &cfg).unwrap().0.contains("HERMES_HOME=~/.hermes/profiles/michael"));
        assert!(logs_command("container", "other", &detail).is_err());
        assert!(logs_command("service", "app", &detail).unwrap().contains("journalctl --user -u app.service"));
    }

    #[test]
    fn weekly_report_text() {
        let now = base();
        let inc = vec![json!({"kind": "site", "title": "S down", "started": now - 3600.0, "ended": now - 3000.0}),
                       json!({"kind": "job", "title": "Job x gagal", "started": now - 100.0, "ended": null})];
        let r = weekly_report(now, &inc, &[json!({"name": "S", "url": "https://s"})], &obj(json!({"https://s": 0.995})),
                              &[json!({"id": "a", "name": "Box A"})], &obj(json!({"a": {"avg": 61, "max": 79}})), Some(123456), 4, 1);
        for want in ["Laporan mingguan", "S 99.5%", "Insiden: 2", "10 menit", "masih terbuka", "Box A: rata-rata 61°C", "123.456", "Task selesai: 4"] {
            assert!(r.contains(want), "{want} in {r}");
        }
    }
}
