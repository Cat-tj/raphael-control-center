//! The HTTP server and its background loops, as a library: the `raphael-web` binary on a
//! Linux box and the desktop app (Tauri) both start it with `start`.

use crate::core::{now, s};
use crate::{files, hermes, metrics, monitor, operations, workspace};
use crate::util::log;
use serde_json::{json, Value};
use std::io::Read;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use tiny_http::{Header, Method, Request, Response, Server};

const COLLECTOR: &str = include_str!("../../remote/collector_linux.sh");
const SCHEMA_V1: &str = include_str!("../../schema/schema_v1.sql");

pub struct App {
    cfg: Value,
    metrics: Arc<metrics::Metrics>,
    ws: Arc<workspace::Workspace>,
    mon: Arc<monitor::Monitor>,
    ops: Arc<operations::Operations>,
    ws_rev: Arc<AtomicI64>,
    statics: Static,
    last_refresh: Mutex<f64>,
}

pub fn load_config(path: &str) -> Value {
    let mut cfg = json!({"port": 8790, "nodes": [{"id": "local", "name": hostname(), "local": true}], "sites": [],
                         "data": monitor::expand("~/.local/share/raphael-web"), "envFiles": ["~/.hermes/.env"]});
    if let Ok(text) = std::fs::read_to_string(monitor::expand(path)) {
        match serde_json::from_str::<Value>(&text) {
            Ok(Value::Object(m)) => {
                for (k, v) in m {
                    cfg[k] = v;
                }
            }
            _ => log(&format!("config {path} tidak valid, memakai default")),
        }
    }
    let data = monitor::expand(s(&cfg, "data"));
    let _ = std::fs::create_dir_all(&data);
    cfg["data"] = json!(data);
    cfg
}

fn hostname() -> String {
    std::fs::read_to_string("/etc/hostname").map(|h| h.trim().to_string()).unwrap_or_else(|_| "server".into())
}

impl App {
    fn new(cfg: Value, statics: Static) -> App {
        let data = std::path::PathBuf::from(s(&cfg, "data"));
        let metrics = Arc::new(metrics::Metrics::open(data.join("metrics.sqlite").to_str().unwrap()).expect("metrics.sqlite"));
        let ws = Arc::new(workspace::Workspace::open(data.join("workspace.sqlite").to_str().unwrap(), &[(1, SCHEMA_V1)]).expect("workspace.sqlite"));
        let ws_rev = Arc::new(AtomicI64::new(metrics.get("wsRev").and_then(|v| v.as_i64()).unwrap_or(0)));
        {
            let (m, r) = (metrics.clone(), ws_rev.clone());
            *ws.on_change.lock().unwrap() = Some(Arc::new(move || {
                let v = r.fetch_add(1, Ordering::SeqCst) + 1;
                m.put("wsRev", &json!(v));
            }));
        }
        let mon = Arc::new(monitor::Monitor::new(cfg.clone(), metrics.clone(), COLLECTOR.to_string()));
        let ops = Arc::new(operations::Operations::new(mon.clone(), metrics.clone(), ws.clone(), cfg.clone()));
        App { cfg, metrics, ws, mon, ops, ws_rev, statics, last_refresh: Mutex::new(0.0) }
    }

    fn start(self: &Arc<Self>) {
        let loop_ = |every: f64, delay: u64, f: Box<dyn Fn() + Send>| {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(delay));
                loop {
                    let t0 = now();
                    f();
                    std::thread::sleep(std::time::Duration::from_secs_f64((every - (now() - t0)).max(5.0)));
                }
            });
        };
        let m = self.mon.clone();
        loop_(60.0, 0, Box::new(move || m.sample_all()));
        let m = self.mon.clone();
        loop_(60.0, 20, Box::new(move || m.check_sites()));
        let m = self.mon.clone();
        loop_(600.0, 5, Box::new(move || m.refresh_cloudflare()));
        let m = self.mon.clone();
        loop_(120.0, 8, Box::new(move || m.refresh_omniroute()));
        self.ops.start();
    }

    fn state(&self) -> Value {
        let mut st = self.mon.state();
        let health = self.ops.health.lock().unwrap().clone();
        if let Some(nodes) = st["nodes"].as_array_mut() {
            for n in nodes {
                let id = s(n, "id").to_string();
                n["health"] = health.get(&id).cloned().unwrap_or(Value::Null);
            }
        }
        let backups = self.ops.backups.lock().unwrap().clone();
        let internet = *self.ops.internet_ok.lock().unwrap();
        let alerts = st["alerts"].as_array_mut().unwrap();
        for b in &backups {
            if let Some(p) = b.get("problem").and_then(|p| p.as_str()) {
                alerts.push(json!({"node": b["nodeName"], "level": 2, "text": format!("Backup {}: {p}", s(b, "name")), "kind": "backup"}));
            }
        }
        if !internet {
            alerts.insert(0, json!({"node": "Rumah", "level": 2, "text": "Internet rumah putus — status website ditahan", "kind": "internet"}));
        }
        let om = self.mon.omniroute.lock().unwrap().clone();
        if s(&om, "state") == "ok" && om.get("down").and_then(|d| d.as_i64()).unwrap_or(0) > 0 {
            alerts.push(json!({"node": "OmniRoute", "level": 1, "text": format!("{} provider down", om["down"]), "kind": "omniroute"}));
        }
        alerts.sort_by_key(|a| -a["level"].as_i64().unwrap_or(0));
        let notify = self.cfg.get("notify").cloned().unwrap_or(json!({}));
        let actions = self.cfg.get("actions").cloned().unwrap_or(json!({}));
        let o = st.as_object_mut().unwrap();
        o.insert("wsRev".into(), json!(self.ws_rev.load(Ordering::SeqCst)));
        o.insert("backups".into(), json!(backups));
        o.insert("internetOk".into(), json!(internet));
        o.insert("openIncidents".into(), json!(self.ops.open_incidents()));
        o.insert("notify".into(), json!({"enabled": notify.get("enabled").and_then(|e| e.as_bool()).unwrap_or(false) && !s(&notify, "target").is_empty(), "label": s(&notify, "label")}));
        o.insert("actions".into(), json!({"containers": actions.get("containers").and_then(|v| v.as_bool()).unwrap_or(false),
                                           "jobs": actions.get("jobs").and_then(|v| v.as_bool()).unwrap_or(false), "services": actions.get("services").cloned().unwrap_or(json!([]))}));
        o.insert("omniroute".into(), json!({"state": om.get("state"), "healthy": om.get("healthy"), "degraded": om.get("degraded"), "down": om.get("down"), "dashboard": om.get("dashboard")}));
        st
    }
}

// ── HTTP ──
fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).unwrap()
}

fn respond(req: Request, code: u16, body: Vec<u8>, ctype: &str) {
    let mut r = Response::from_data(body).with_status_code(code).with_header(header("Content-Type", ctype))
        .with_header(header("Cache-Control", if ctype.starts_with("application/json") { "no-store" } else { "no-cache" }))
        .with_header(header("X-Content-Type-Options", "nosniff"))
        .with_header(header("X-Frame-Options", "DENY"))
        .with_header(header("Referrer-Policy", "no-referrer"))
        .with_header(header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"));
    r.add_header(header("Server", concat!("RaphaelWeb/", env!("CARGO_PKG_VERSION"))));
    let _ = req.respond(r);
}

fn json_resp(req: Request, code: u16, v: Value) {
    respond(req, code, v.to_string().into_bytes(), "application/json; charset=utf-8");
}

fn hdr(req: &Request, name: &str) -> Option<String> {
    req.headers().iter().find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name)).map(|h| h.value.as_str().to_string())
}

fn query(url: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    if let Some((_, q)) = url.split_once('?') {
        for pair in q.split('&') {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            out.insert(decode(k), decode(v));
        }
    }
    out
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                match u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"), 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn mime(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "webmanifest" => "application/manifest+json",
        "json" => "application/json",
        _ => "application/octet-stream",
    }
}

/// Where the web UI comes from: a folder on disk (the server deploy) or the copy compiled into
/// the binary (the desktop app).
#[derive(Clone)]
pub enum Static {
    Dir(std::path::PathBuf),
    Embedded,
}

fn serve_static(app: &App, req: Request, path: &str) {
    let rel = if path == "/" || path.is_empty() { "index.html".to_string() } else { path.trim_start_matches('/').split('?').next().unwrap_or("").to_string() };
    let (name, mut body, version): (String, Vec<u8>, Box<dyn Fn(&str) -> u64>) = match &app.statics {
        Static::Embedded => {
            let (n, b) = crate::assets::get(&rel).map(|b| (rel.clone(), b)).unwrap_or_else(|| ("index.html".to_string(), crate::assets::get("index.html").unwrap()));
            let v = crate::assets::BUILD_ID;
            (n, b.to_vec(), Box::new(move |_| v))
        }
        Static::Dir(dir) => {
            let root = std::fs::canonicalize(dir).unwrap_or(dir.clone());
            let full = std::fs::canonicalize(root.join(&rel)).ok().filter(|p| p.starts_with(&root) && p.is_file()).unwrap_or_else(|| root.join("index.html"));
            let Ok(b) = std::fs::read(&full) else { return json_resp(req, 404, json!({"error": "tidak ada"})) };
            let r2 = root.clone();
            (full.to_string_lossy().to_string(), b, Box::new(move |asset: &str| {
                std::fs::metadata(r2.join(asset)).and_then(|m| m.modified()).ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0)
            }))
        }
    };
    if name.ends_with("index.html") {
        // Cache-bust the assets so a new version is picked up on the next load.
        let mut text = String::from_utf8_lossy(&body).to_string();
        for asset in ["app.js", "app.css"] {
            text = text.replace(&format!("\"{asset}\""), &format!("\"{asset}?v={}\"", version(asset)));
        }
        body = text.into_bytes();
    }
    respond(req, 200, body, mime(&name));
}

fn write_allowed(req: &Request) -> bool {
    // Cross-site forms can't set custom headers or a JSON content type → simple CSRF guard.
    if hdr(req, "X-Raphael").as_deref() != Some("1") || !hdr(req, "Content-Type").map(|c| c.starts_with("application/json")).unwrap_or(false) {
        return false;
    }
    if let Some(origin) = hdr(req, "Origin") {
        let host = hdr(req, "X-Forwarded-Host").or_else(|| hdr(req, "Host")).unwrap_or_default();
        let netloc = origin.split("://").nth(1).unwrap_or("").trim_end_matches('/');
        if netloc != host {
            return false;
        }
    }
    true
}

fn handle(app: Arc<App>, mut req: Request) {
    let url = req.url().to_string();
    let path = url.split('?').next().unwrap_or("/").to_string();
    let q = query(&url);
    let method = req.method().clone();
    if method == Method::Get || method == Method::Head {
        let r: Value = match path.as_str() {
            "/api/state" => app.state(),
            "/api/history" => {
                let hours = q.get("hours").and_then(|h| h.parse::<f64>().ok()).unwrap_or(6.0).clamp(0.1, 24.0);
                json!({"node": q.get("node"), "samples": app.metrics.samples(q.get("node").map(|s| s.as_str()).unwrap_or(""), hours)})
            }
            "/api/site" => json!({"url": q.get("url"), "checks": app.metrics.checks(q.get("url").map(|s| s.as_str()).unwrap_or(""), 24.0)}),
            "/api/workspace" => match app.ws.snapshot() {
                Ok(mut v) => {
                    v["rev"] = json!(app.ws_rev.load(Ordering::SeqCst));
                    v
                }
                Err(e) => return json_resp(req, 500, json!({"error": e.0})),
            },
            "/api/ws/rev" => json!({"rev": app.ws_rev.load(Ordering::SeqCst)}),
            "/api/ws/dump" => match app.ws.dump() {
                Ok(t) => json!({"rev": app.ws_rev.load(Ordering::SeqCst), "tables": t}),
                Err(e) => return json_resp(req, 500, json!({"error": e.0})),
            },
            "/api/raw" => match app.mon.raw_line.lock().unwrap().get(q.get("node").map(|s| s.as_str()).unwrap_or("")).cloned() {
                Some(v) => v,
                None => return json_resp(req, 404, json!({"error": "belum ada sample"})),
            },
            "/api/agents" => {
                let home = app.cfg.get("hermesHome").and_then(|h| h.as_str()).unwrap_or("~/.hermes");
                let profs = hermes::profiles(home);
                let sel = profs.iter().find(|p| q.get("profile").map(|w| w == s(p, "id")).unwrap_or(false)).or(profs.first()).cloned();
                let snap = sel.as_ref().map(|p| hermes::snapshot(s(p, "path"), None)).unwrap_or(json!({"error": "Hermes tidak ditemukan di server ini"}));
                json!({"profiles": profs.iter().map(|p| json!({"id": p["id"], "name": p["name"]})).collect::<Vec<_>>(), "profile": sel.map(|p| p["id"].clone()), "snapshot": snap})
            }
            "/api/omniroute" => app.mon.omniroute.lock().unwrap().clone(),
            "/api/files" | "/api/file" => {
                let nodes = app.cfg["nodes"].as_array().cloned().unwrap_or_default();
                let Some(node) = nodes.iter().find(|n| q.get("node").map(|w| w == s(n, "id")).unwrap_or(false)) else {
                    return json_resp(req, 404, json!({"error": "device tidak dikenal"}));
                };
                files::run(node, if path == "/api/files" { "list" } else { "read" }, q.get("path").map(|s| s.as_str()).filter(|s| !s.is_empty()).unwrap_or("~"))
            }
            "/api/incidents" => json!({"incidents": app.ops.incidents(q.get("days").and_then(|d| d.parse().ok()).unwrap_or(30.0)), "open": app.ops.open_incidents()}),
            "/api/history30" => json!({"node": q.get("node"), "hours": app.ops.history30(q.get("node").map(|s| s.as_str()).unwrap_or(""), q.get("days").and_then(|d| d.parse().ok()).unwrap_or(30.0))}),
            "/api/notify" => {
                let n = app.cfg.get("notify").cloned().unwrap_or(json!({}));
                json!({"enabled": n.get("enabled").and_then(|e| e.as_bool()).unwrap_or(false) && !s(&n, "target").is_empty(), "label": s(&n, "label"),
                       "weekly": n.get("weekly"), "log": app.ops.notify_log(30)})
            }
            "/api/report" => json!({"text": app.ops.report_text()}),
            "/api/actionlog" => json!({"log": app.ops.action_log(50)}),
            "/api/logs" => match app.ops.logs(q.get("node").map(|s| s.as_str()).unwrap_or(""), q.get("kind").map(|s| s.as_str()).unwrap_or(""), q.get("target").map(|s| s.as_str()).unwrap_or("")) {
                Ok(v) => v,
                Err(e) => return json_resp(req, 400, json!({"error": e})),
            },
            "/api/me" => json!({"login": hdr(&req, "Tailscale-User-Login"), "name": hdr(&req, "Tailscale-User-Name")}),
            "/healthz" => json!({"ok": true, "version": env!("CARGO_PKG_VERSION"), "workspace": app.ws.integrity_ok(), "impl": "rust"}),
            p if p.starts_with("/api/") => return json_resp(req, 404, json!({"error": "tidak ada"})),
            _ => return serve_static(&app, req, &path),
        };
        return json_resp(req, 200, r);
    }
    if !(method == Method::Post || method == Method::Patch || method == Method::Delete) {
        return json_resp(req, 405, json!({"error": "metode tidak didukung"}));
    }
    if !write_allowed(&req) {
        return json_resp(req, 403, json!({"error": "ditolak (header X-Raphael / Origin)"}));
    }
    let len = req.body_length().unwrap_or(0);
    if len > 8 * 1024 * 1024 {
        return json_resp(req, 400, json!({"error": "request terlalu besar"}));
    }
    let mut raw = String::new();
    let body: Value = if method == Method::Delete {
        json!({})
    } else {
        if req.as_reader().take(8 * 1024 * 1024).read_to_string(&mut raw).is_err() {
            return json_resp(req, 400, json!({"error": "JSON tidak valid"}));
        }
        match serde_json::from_str::<Value>(if raw.trim().is_empty() { "{}" } else { &raw }) {
            Ok(v @ Value::Object(_)) => v,
            Ok(_) => return json_resp(req, 400, json!({"error": "JSON harus object"})),
            Err(_) => return json_resp(req, 400, json!({"error": "JSON tidak valid"})),
        }
    };
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let ws = &app.ws;
    let res: Result<(u16, Value), String> = (|| {
        let wse = |e: workspace::WsError| e.0;
        match (method.clone(), parts.as_slice()) {
            (Method::Post, ["api", "refresh"]) => {
                let mut last = app.last_refresh.lock().unwrap();
                if now() - *last > 10.0 {
                    *last = now();
                    let (m1, m2) = (app.mon.clone(), app.mon.clone());
                    std::thread::spawn(move || m1.sample_all());
                    std::thread::spawn(move || m2.check_sites());
                }
                Ok((202, json!({"ok": true})))
            }
            (Method::Post, ["api", "cloudflare"]) => {
                let m = app.mon.clone();
                std::thread::spawn(move || m.refresh_cloudflare());
                Ok((202, json!({"ok": true})))
            }
            (Method::Post, ["api", "omniroute"]) => {
                let m = app.mon.clone();
                std::thread::spawn(move || m.refresh_omniroute());
                Ok((202, json!({"ok": true})))
            }
            (Method::Post, ["api", "notify"]) => {
                let text = if body.get("report").and_then(|v| v.as_bool()).unwrap_or(false) {
                    app.ops.report_text()
                } else if body.get("test").and_then(|v| v.as_bool()).unwrap_or(false) {
                    "✅ Tes notifikasi dari Raphael Web. Kalau pesan ini sampai, alert server akan dikirim ke sini.".to_string()
                } else {
                    return Err("tidak ada yang dikirim".into());
                };
                Ok((200, app.ops.notify(&text, true)))
            }
            (Method::Post, ["api", "action"]) => {
                let who = hdr(&req, "Tailscale-User-Login").unwrap_or_default();
                app.ops.action(s(&body, "node"), s(&body, "kind"), s(&body, "target"), &who).map(|v| (200, v))
            }
            (Method::Post, ["api", "ws", "apply"]) => {
                let base = app.ws_rev.load(Ordering::SeqCst);
                let stmts = body.get("statements").and_then(|v| v.as_array()).cloned().unwrap_or_default();
                let n = ws.apply(&stmts).map_err(wse)?;
                Ok((200, json!({"applied": n, "rev": app.ws_rev.load(Ordering::SeqCst), "clean": body.get("baseRev").and_then(|v| v.as_i64()) == Some(base)})))
            }
            (Method::Post, ["api", kind]) if ["portfolio", "project", "task"].contains(kind) => {
                let id = match *kind {
                    "portfolio" => ws.create_portfolio(&body),
                    "project" => ws.create_project(&body),
                    _ => ws.create_task(&body),
                }.map_err(wse)?;
                Ok((201, json!({"id": id})))
            }
            (Method::Post, ["api", "task", id, "move"]) => {
                ws.move_task(id, s(&body, "status"), body.get("before").and_then(|b| b.as_str())).map_err(wse)?;
                Ok((200, json!({"ok": true})))
            }
            (Method::Patch, ["api", kind, id]) if ["portfolio", "project", "task"].contains(kind) => {
                match *kind {
                    "portfolio" => ws.update_portfolio(id, &body),
                    "project" => ws.update_project(id, &body),
                    _ => ws.update_task(id, &body),
                }.map_err(wse)?;
                Ok((200, json!({"ok": true})))
            }
            (Method::Delete, ["api", kind, id]) if ["portfolio", "project", "task"].contains(kind) => {
                ws.delete(kind, id).map_err(wse)?;
                Ok((200, json!({"ok": true})))
            }
            _ => Ok((404, json!({"error": "tidak ada"}))),
        }
    })();
    match res {
        Ok((code, v)) => json_resp(req, code, v),
        Err(e) => json_resp(req, 400, json!({"error": e})),
    }
}


/// A running server.
pub struct Handle {
    pub port: u16,
    pub app: Arc<App>,
}

/// Starts the server (and, with `sampling`, its loops) on 127.0.0.1:`port` (0 = any free port).
pub fn start(cfg: Value, statics: Static, sampling: bool) -> Result<Handle, String> {
    let app = Arc::new(App::new(cfg.clone(), statics));
    if sampling {
        app.start();
    }
    let port = cfg.get("port").and_then(|p| p.as_u64()).unwrap_or(8790) as u16;
    let server = Arc::new(Server::http(("127.0.0.1", port)).map_err(|e| e.to_string())?);
    let port = server.server_addr().to_ip().map(|a| a.port()).unwrap_or(port);
    log(&format!("Raphael Web {} (rust) on http://127.0.0.1:{port} · {} device · data {}", env!("CARGO_PKG_VERSION"),
                 cfg["nodes"].as_array().map(|n| n.len()).unwrap_or(0), s(&cfg, "data")));
    for _ in 0..8 {
        let (srv, app) = (server.clone(), app.clone());
        std::thread::spawn(move || loop {
            match srv.recv() {
                Ok(req) => {
                    let app = app.clone();
                    // A panic in one request must not take the worker down.
                    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handle(app, req))).is_err() {
                        log("request handler panicked");
                    }
                }
                Err(e) => {
                    log(&format!("recv: {e}"));
                    break;
                }
            }
        });
    }
    Ok(Handle { port, app })
}
