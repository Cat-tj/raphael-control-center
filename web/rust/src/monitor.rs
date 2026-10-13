//! Device sampling, websites, Cloudflare and OmniRoute (port of the Monitor class in server.py).

use crate::core::{self, f, now, s};
use crate::metrics::Metrics;
use crate::net;
use crate::util;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

pub const CF_ENV_KEYS: [&str; 6] = ["CLOUDFLARE_API_TOKEN_FULL", "CF_API_TOKEN_FULL", "API_TOKEN_FULL", "CLOUDFLARE_ANALYTICS_TOKEN", "CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"];
pub const OMNIROUTE_ENV_KEYS: [&str; 3] = ["OMNIROUTE_API_KEY", "HERMES_CUSTOM_OMNIROUTE_API_KEY", "HERMES_CUSTOM_LOCALHOST_20128_API_KEY"];

pub fn parse_env(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for raw in text.lines() {
        let mut line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("export ") {
            line = rest;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        let mut v = v.trim();
        if v.len() >= 2 && (v.starts_with('"') && v.ends_with('"') || v.starts_with('\'') && v.ends_with('\'')) {
            v = &v[1..v.len() - 1];
        }
        out.insert(k.trim().to_uppercase().replace(' ', "_"), v.to_string());
    }
    out
}

pub fn expand(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        format!("{}/{rest}", std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_default())
    } else {
        p.to_string()
    }
}

pub fn host_key(url: &str) -> String {
    let rest = url.split("://").nth(1).unwrap_or(url);
    let hostport = rest.split('/').next().unwrap_or("");
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) => (h, p.to_string()),
        _ => (hostport, "443".to_string()),
    };
    format!("{host}:{port}")
}

fn throttle_now(hex: &Value) -> i64 {
    hex.as_str().and_then(|h| i64::from_str_radix(h.trim_start_matches("0x"), 16).ok()).map(|v| v & 0xF).unwrap_or(0)
}

pub struct Monitor {
    pub cfg: Value,
    pub nodes: Vec<Value>,
    pub metrics: Arc<Metrics>,
    collector: String,
    pub detail: Mutex<Map<String, Value>>,
    pub last: Mutex<Map<String, Value>>,
    raw: Mutex<HashMap<String, (f64, f64, f64, Option<f64>)>>,
    last_slow: Mutex<HashMap<String, f64>>,
    failures: Mutex<HashMap<String, u32>>,
    pub sampling: Mutex<HashSet<String>>,
    pub raw_line: Mutex<Map<String, Value>>,
    pub site_status: Mutex<Map<String, Value>>,
    pub certs: Mutex<Map<String, Value>>,
    cert_checked: Mutex<HashMap<String, f64>>,
    pub cloudflare: Mutex<Value>,
    pub omniroute: Mutex<Value>,
}

impl Monitor {
    pub fn new(cfg: Value, metrics: Arc<Metrics>, collector: String) -> Monitor {
        let nodes: Vec<Value> = cfg.get("nodes").and_then(|n| n.as_array()).cloned().unwrap_or_default();
        let ids: HashSet<String> = nodes.iter().map(|n| s(n, "id").to_string()).collect();
        let saved = metrics.get("last").unwrap_or(json!({}));
        let keep = |k: &str| -> Map<String, Value> {
            saved.get(k).and_then(|v| v.as_object()).map(|m| m.iter().filter(|(id, _)| ids.contains(*id)).map(|(a, b)| (a.clone(), b.clone())).collect()).unwrap_or_default()
        };
        let certs: Map<String, Value> = metrics.get("certs").and_then(|c| c.as_object().cloned()).map(|m| m.into_iter().filter(|(k, _)| !k.contains("://")).collect()).unwrap_or_default();
        Monitor {
            detail: Mutex::new(keep("detail")),
            last: Mutex::new(keep("last")),
            site_status: Mutex::new(saved.get("sites").and_then(|v| v.as_object()).cloned().unwrap_or_default()),
            certs: Mutex::new(certs),
            cfg,
            nodes,
            metrics,
            collector,
            raw: Mutex::new(HashMap::new()),
            last_slow: Mutex::new(HashMap::new()),
            failures: Mutex::new(HashMap::new()),
            sampling: Mutex::new(HashSet::new()),
            raw_line: Mutex::new(Map::new()),
            cert_checked: Mutex::new(HashMap::new()),
            cloudflare: Mutex::new(json!({"state": "idle", "zones": [], "tried": [], "loadedAt": null})),
            omniroute: Mutex::new(json!({"state": "idle"})),
        }
    }

    pub fn persist(&self) {
        let v = json!({"detail": *self.detail.lock().unwrap(), "last": *self.last.lock().unwrap(), "sites": *self.site_status.lock().unwrap()});
        self.metrics.put("last", &v);
    }

    // ── Devices ──
    pub fn sample(&self, node: &Value) {
        let id = s(node, "id").to_string();
        if !self.sampling.lock().unwrap().insert(id.clone()) {
            return;
        }
        let t = now();
        let slow = t - self.last_slow.lock().unwrap().get(&id).copied().unwrap_or(0.0) > 1800.0;
        let script = self.collector.replace("__SLOW__", if slow { "1" } else { "0" });
        let (out, _) = if node.get("native").and_then(|v| v.as_bool()).unwrap_or(false) {
            (crate::native::collect(slow).to_string(), 0)                 // this machine, any OS
        } else if node.get("local").and_then(|v| v.as_bool()).unwrap_or(false) {
            util::run(&["sh", "-s"], Some(&script), 45)
        } else {
            util::run(&["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", s(node, "ssh"), "sh -s"], Some(&script), 45)
        };
        match util::last_json_line(&out).filter(|j| j.is_object()) {
            None => {
                *self.failures.lock().unwrap().entry(id.clone()).or_insert(0) += 1;
                let mut det = self.detail.lock().unwrap();
                let mut prev = det.get(&id).cloned().unwrap_or(json!({}));
                let o = prev.as_object_mut().unwrap();
                let tail: String = out.trim().chars().rev().take(160).collect::<Vec<_>>().into_iter().rev().collect();
                o.insert("error".into(), json!(if out.trim().is_empty() { "Tidak terhubung".to_string() } else { tail }));
                o.insert("at".into(), json!(t));
                for k in ["jobs", "disks", "containers"] {
                    o.entry(k).or_insert(json!([]));
                }
                det.insert(id.clone(), prev);
            }
            Some(j) => {
                self.failures.lock().unwrap().insert(id.clone(), 0);
                self.raw_line.lock().unwrap().insert(id.clone(), json!({"at": t, "raw": j}));
                if slow {
                    self.last_slow.lock().unwrap().insert(id.clone(), t);
                }
                let prev = self.detail.lock().unwrap().get(&id).cloned();
                let d = core::parse(&j, t, prev.as_ref(), slow);
                let (rx, tx) = (f(&j, "rx"), f(&j, "tx"));
                let req = d.get("tunnel").filter(|t| t.is_object()).map(|t| f(t, "total"));
                let mut smp = json!({"t": t, "cpu": d["cpu"], "mem": d["mem"], "swap": d["swap"], "disk": d["disk"], "load": d["load"], "temp": d["temp"],
                                     "rx": 0.0, "tx": 0.0, "req": null, "thr": throttle_now(&d["throttled"])});
                if let Some(&(pt, prx, ptx, preq)) = self.raw.lock().unwrap().get(&id) {
                    if t > pt {
                        let dt = t - pt;
                        smp["rx"] = json!(((rx - prx) / dt).max(0.0));
                        smp["tx"] = json!(((tx - ptx) / dt).max(0.0));
                        if let (Some(r), Some(p)) = (req, preq) {
                            smp["req"] = json!(((r - p) / dt * 60.0).max(0.0));
                        }
                    }
                }
                self.raw.lock().unwrap().insert(id.clone(), (t, rx, tx, req));
                self.metrics.add_sample(&id, &smp);
                self.last.lock().unwrap().insert(id.clone(), smp);
                self.detail.lock().unwrap().insert(id.clone(), d);
            }
        }
        self.sampling.lock().unwrap().remove(&id);
    }

    pub fn sample_all(self: &Arc<Self>) {
        let mut hs = vec![];
        for n in self.nodes.clone() {
            let id = s(&n, "id").to_string();
            let fails = self.failures.lock().unwrap().get(&id).copied().unwrap_or(0);
            let at = self.detail.lock().unwrap().get(&id).map(|d| f(d, "at")).unwrap_or(0.0);
            if fails >= 3 && now() - at < 300.0 {
                continue; // unreachable: back off to every 5 min
            }
            let me = self.clone();
            hs.push(std::thread::spawn(move || me.sample(&n)));
        }
        for h in hs {
            let _ = h.join();
        }
        self.persist();
    }

    // ── Websites ──
    pub fn site_list(&self) -> Vec<Value> {
        let mut sites: Vec<Value> = self.cfg.get("sites").and_then(|s| s.as_array()).cloned().unwrap_or_default();
        let mut seen: HashSet<String> = sites.iter().map(|x| s(x, "url").trim_end_matches('/').to_string()).collect();
        let det = self.detail.lock().unwrap();
        for n in &self.nodes {
            if let Some(hosts) = det.get(s(n, "id")).and_then(|d| d.pointer("/tunnel/hosts")).and_then(|h| h.as_array()) {
                for h in hosts.iter().filter_map(|h| h.as_str()).filter(|h| !h.contains('*')) {
                    let u = format!("https://{h}");
                    if seen.insert(u.clone()) {
                        sites.push(json!({"name": h, "url": u, "auto": true, "node": s(n, "name")}));
                    }
                }
            }
        }
        sites
    }

    pub fn check_site(&self, url: &str) {
        let t0 = now();
        let (code, error) = net::check(url);
        let ms = ((now() - t0) * 1000.0) as i64;
        let mut st = json!({"code": code, "error": error, "checkedAt": t0, "ms": ms});
        let ok = core::site_ok(&st);
        st["ok"] = json!(ok);
        self.site_status.lock().unwrap().insert(url.to_string(), st);
        self.metrics.add_check(url, t0, code, ms, ok);
        let hk = host_key(url);
        let due = now() - self.cert_checked.lock().unwrap().get(&hk).copied().unwrap_or(0.0) > 6.0 * 3600.0;
        if url.starts_with("https://") && due {
            self.cert_checked.lock().unwrap().insert(hk.clone(), now());
            let (host, port) = hk.rsplit_once(':').unwrap();
            if let Some(exp) = net::cert_expiry(host, port.parse().unwrap_or(443)) {
                self.certs.lock().unwrap().insert(hk, json!(exp));
                let c = Value::Object(self.certs.lock().unwrap().clone());
                self.metrics.put("certs", &c);
            }
        }
    }

    pub fn check_sites(self: &Arc<Self>) {
        let hs: Vec<_> = self.site_list().into_iter().map(|site| {
            let me = self.clone();
            std::thread::spawn(move || me.check_site(s(&site, "url")))
        }).collect();
        for h in hs {
            let _ = h.join();
        }
        self.persist();
    }

    // ── .env values (tokens stay on the server) ──
    pub fn env_values(&self, keys: &[&str], extra: Option<&dyn Fn(&str) -> bool>) -> Vec<(String, String)> {
        let mut out: Vec<(String, String)> = vec![];
        if let Ok(t) = std::env::var("RAPHAEL_CLOUDFLARE_TOKEN") {
            if keys == CF_ENV_KEYS && !t.is_empty() {
                out.push(("env RAPHAEL_CLOUDFLARE_TOKEN".into(), t));
            }
        }
        for file in self.cfg.get("envFiles").and_then(|e| e.as_array()).cloned().unwrap_or_default() {
            let Some(fname) = file.as_str() else { continue };
            let Ok(text) = std::fs::read_to_string(expand(fname)) else { continue };
            let env = parse_env(&text);
            let mut names: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
            if let Some(extra) = extra {
                let mut more: Vec<String> = env.keys().filter(|k| !keys.contains(&k.as_str()) && extra(k)).cloned().collect();
                more.sort();
                names.extend(more);
            }
            for k in names {
                if let Some(v) = env.get(&k).map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
                    if !out.iter().any(|(_, t)| *t == v) {
                        out.push((format!("{fname} · {k}"), v));
                    }
                }
            }
        }
        out
    }

    pub fn refresh_cloudflare(&self) {
        let extra = |k: &str| (k.contains("TOKEN") && k.contains("FULL")) || k.contains("CLOUDFLARE") || k.starts_with("CF_");
        let tokens = self.env_values(&CF_ENV_KEYS, Some(&extra));
        if tokens.is_empty() {
            *self.cloudflare.lock().unwrap() = json!({"state": "noToken", "zones": [], "tried": [], "loadedAt": null});
            return;
        }
        let (mut tried, mut state, mut zones) = (vec![], "noPermission", vec![]);
        for (source, tok) in tokens {
            if tok.len() == 37 && tok.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()) {
                tried.push(json!({"source": source, "result": "Global API Key — tidak didukung, buat API Token"}));
                continue;
            }
            match net::cloudflare_zones(&tok) {
                Ok(z) => {
                    tried.push(json!({"source": source, "result": format!("OK · {} zone", z.len())}));
                    zones = z;
                    state = "ok";
                    break;
                }
                Err(net::CfError::Permission(_)) => tried.push(json!({"source": source, "result": "tidak punya izin Analytics / Zone Read"})),
                Err(net::CfError::Other(e)) => {
                    tried.push(json!({"source": source, "result": e.chars().take(160).collect::<String>()}));
                    state = "error";
                }
            }
        }
        if state != "ok" && tried.iter().any(|t| s(t, "result").starts_with("tidak punya")) {
            state = "noPermission";
        }
        let mut cf = self.cloudflare.lock().unwrap();
        let keep_zones = cf.get("zones").cloned().unwrap_or(json!([]));
        let keep_at = cf.get("loadedAt").cloned().unwrap_or(Value::Null);
        *cf = json!({"state": state, "zones": if state == "ok" { json!(zones) } else { keep_zones }, "tried": tried,
                     "loadedAt": if state == "ok" { json!(now()) } else { keep_at }});
    }

    pub fn refresh_omniroute(&self) {
        let o = self.cfg.get("omniroute").cloned().unwrap_or(json!({}));
        let base = s(&o, "base");
        let base = if base.is_empty() { "http://127.0.0.1:20128" } else { base }.trim_end_matches('/').to_string();
        let names: Vec<String> = o.get("envKeys").and_then(|k| k.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_else(|| OMNIROUTE_ENV_KEYS.iter().map(|s| s.to_string()).collect());
        let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
        let mut keys = self.env_values(&refs, None);
        if keys.is_empty() {
            keys.push(("tanpa key".into(), String::new()));
        }
        let mut res = json!({"state": "noKey", "base": base, "dashboard": o.get("dashboard"), "tried": [], "at": now()});
        for (source, key) in keys {
            match net::omniroute_load(&base, &key) {
                Ok(v) => {
                    for (k, x) in v.as_object().unwrap() {
                        res[k] = x.clone();
                    }
                    res["state"] = json!("ok");
                    res["keySource"] = json!(source);
                    break;
                }
                Err(net::OmniError::Denied) => {
                    res["tried"].as_array_mut().unwrap().push(json!({"source": source, "result": "key ditolak"}));
                    res["state"] = json!("denied");
                }
                Err(net::OmniError::Other(e)) => {
                    res["tried"].as_array_mut().unwrap().push(json!({"source": source, "result": e}));
                    res["state"] = json!("error");
                }
            }
        }
        *self.omniroute.lock().unwrap() = res;
    }

    // ── Views ──
    pub fn certs_by_url(&self, sites: &[Value]) -> Map<String, Value> {
        let c = self.certs.lock().unwrap();
        sites.iter().filter_map(|x| c.get(&host_key(s(x, "url"))).map(|e| (s(x, "url").to_string(), e.clone()))).collect()
    }

    pub fn state(&self) -> Value {
        let det = self.detail.lock().unwrap().clone();
        let last = self.last.lock().unwrap().clone();
        let sampling = self.sampling.lock().unwrap().clone();
        let nodes: Vec<Value> = self.nodes.iter().map(|n| {
            let id = s(n, "id");
            json!({"id": id, "name": s(n, "name"), "description": s(n, "description"), "local": n.get("local").and_then(|v| v.as_bool()).unwrap_or(false),
                   "detail": det.get(id), "last": last.get(id), "sampling": sampling.contains(id)})
        }).collect();
        let mut sites = self.site_list();
        let status = self.site_status.lock().unwrap().clone();
        let certs = self.certs_by_url(&sites);
        let t = now();
        for st in sites.iter_mut() {
            let url = s(st, "url").to_string();
            let checks = self.metrics.checks(&url, 24.0);
            let o = st.as_object_mut().unwrap();
            o.insert("status".into(), status.get(&url).cloned().unwrap_or(Value::Null));
            o.insert("certDays".into(), certs.get(&url).and_then(|e| e.as_f64()).map(|e| json!(((e - t) / 86400.0).floor() as i64)).unwrap_or(Value::Null));
            o.insert("uptime".into(), if checks.is_empty() { Value::Null } else { json!(checks.iter().filter(|c| c["ok"] == true).count() as f64 / checks.len() as f64) });
            let skip = checks.len().saturating_sub(60);
            o.insert("recent".into(), json!(checks[skip..].iter().map(|c| json!({"t": c["t"], "ms": c["ms"], "ok": c["ok"]})).collect::<Vec<_>>()));
        }
        let alerts = core::alerts(&self.nodes, &det, &last, &sites, &status, &certs, t);
        json!({"version": env!("CARGO_PKG_VERSION"), "now": t, "nodes": nodes, "sites": sites, "alerts": alerts, "cloudflare": *self.cloudflare.lock().unwrap(),
               "links": self.cfg.get("links").cloned().unwrap_or(json!([]))})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_and_host_keys() {
        let env = parse_env("export A=1\n# c\nCLOUDFLARE_API_TOKEN=\"x\"\napi token full = y\n");
        assert_eq!(env["A"], "1");
        assert_eq!(env["CLOUDFLARE_API_TOKEN"], "x");
        assert_eq!(env["API_TOKEN_FULL"], "y");
        assert_eq!(host_key("https://a.b/x"), "a.b:443");
        assert_eq!(host_key("https://a.b:20128/dashboard"), "a.b:20128");
    }

    #[test]
    fn token_order_and_persistence() {
        let dir = std::env::temp_dir().join(format!("rwm-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let envp = dir.join(".env");
        std::fs::write(&envp, "CLOUDFLARE_API_TOKEN=old\nCLOUDFLARE_API_TOKEN_FULL=new\n").unwrap();
        let m = Arc::new(Metrics::open(dir.join("m.sqlite").to_str().unwrap()).unwrap());
        let cfg = json!({"nodes": [{"id": "a", "name": "A", "local": true}], "envFiles": [envp.to_str().unwrap()]});
        let mon = Monitor::new(cfg.clone(), m.clone(), String::new());
        let toks: Vec<String> = mon.env_values(&CF_ENV_KEYS, None).into_iter().map(|t| t.1).collect();
        assert_eq!(toks, ["new", "old"]);
        mon.detail.lock().unwrap().insert("a".into(), json!({"disk": 0.95}));
        mon.site_status.lock().unwrap().insert("https://x".into(), json!({"code": 200, "ok": true}));
        mon.persist();
        let again = Monitor::new(cfg, m.clone(), String::new());
        assert_eq!(again.detail.lock().unwrap()["a"]["disk"], 0.95);
        assert_eq!(again.site_status.lock().unwrap()["https://x"]["ok"], true);
        let gone = Monitor::new(json!({"nodes": []}), m, String::new());
        assert!(gone.detail.lock().unwrap().is_empty());
    }
}
