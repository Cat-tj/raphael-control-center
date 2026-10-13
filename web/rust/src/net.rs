//! Outbound HTTP: website checks, certificate expiry, internet probe, Cloudflare and OmniRoute.

use serde_json::{json, Map, Value};
use std::io::Write;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub const UA: &str = concat!("RaphaelWeb/", env!("CARGO_PKG_VERSION"));

fn agent() -> &'static ureq::Agent {
    static A: OnceLock<ureq::Agent> = OnceLock::new();
    A.get_or_init(|| ureq::AgentBuilder::new().timeout(Duration::from_secs(20)).user_agent(UA).build())
}

/// GET url → (status code or 0, error text).
pub fn check(url: &str) -> (i64, Option<String>) {
    let a = ureq::AgentBuilder::new().timeout(Duration::from_secs(10)).user_agent(UA).build();
    match a.get(url).call() {
        Ok(r) => (r.status() as i64, None),
        Err(ureq::Error::Status(code, _)) => (code as i64, None),
        Err(ureq::Error::Transport(t)) => (0, Some(t.to_string().chars().take(160).collect())),
    }
}

pub fn internet_ok(probes: &[String]) -> bool {
    let a = ureq::AgentBuilder::new().timeout(Duration::from_secs(6)).user_agent(UA).build();
    probes.iter().any(|u| matches!(a.head(u).call(), Ok(_) | Err(ureq::Error::Status(..))))
}

/// Leaf certificate notAfter (unix seconds) of host:port.
pub fn cert_expiry(host: &str, port: u16) -> Option<f64> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions().ok()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).ok()?;
    let mut conn = rustls::ClientConnection::new(Arc::new(cfg), name).ok()?;
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let mut sock = TcpStream::connect_timeout(&addr, Duration::from_secs(8)).ok()?;
    sock.set_read_timeout(Some(Duration::from_secs(8))).ok()?;
    let mut tls = rustls::Stream::new(&mut conn, &mut sock);
    let _ = tls.write_all(b"");
    while tls.conn.is_handshaking() {
        tls.conn.complete_io(tls.sock).ok()?;
    }
    let cert = tls.conn.peer_certificates()?.first()?.clone();
    let (_, x) = x509_parser::parse_x509_certificate(cert.as_ref()).ok()?;
    Some(x.validity().not_after.timestamp() as f64)
}

pub enum CfError {
    #[allow(dead_code)]
    Permission(String),
    Other(String),
}

fn cf_call(token: &str, path: &str, body: Option<&Value>) -> Result<Value, CfError> {
    let url = format!("https://api.cloudflare.com/client/v4{path}");
    let req = agent().request(if body.is_some() { "POST" } else { "GET" }, &url).set("Authorization", &format!("Bearer {token}"));
    let resp = match body {
        Some(b) => req.send_json(b.clone()),
        None => req.call(),
    };
    let j: Value = match resp {
        Ok(r) => r.into_json().map_err(|e| CfError::Other(e.to_string()))?,
        Err(ureq::Error::Status(code, r)) => r.into_json().map_err(|_| CfError::Other(format!("HTTP {code}")))?,
        Err(e) => return Err(CfError::Other(e.to_string())),
    };
    let errs = j.get("errors").and_then(|e| e.as_array()).cloned().unwrap_or_default();
    if !errs.is_empty() {
        let msg = errs.iter().filter_map(|e| e.get("message").and_then(|m| m.as_str())).collect::<Vec<_>>().join("; ");
        let code = errs[0].get("code").and_then(|c| c.as_i64());
        let ext = errs[0].get("extensions").and_then(|e| e.get("code")).and_then(|c| c.as_str());
        if code == Some(10000) || code == Some(9109) || msg.to_lowercase().contains("authentication error") || msg.contains("permission") || msg.contains("authz") || ext == Some("authz") {
            return Err(CfError::Permission(msg));
        }
        if j.get("data").map(|d| d.is_null()).unwrap_or(true) && j.get("result").map(|d| d.is_null()).unwrap_or(true) {
            return Err(CfError::Other(if msg.is_empty() { "Cloudflare error".into() } else { msg }));
        }
    }
    Ok(j)
}

pub fn cloudflare_zones(token: &str) -> Result<Vec<Value>, CfError> {
    let list = cf_call(token, "/zones?per_page=50&status=active", None)?;
    let since = chrono::Local::now().checked_sub_signed(chrono::Duration::days(6)).unwrap().format("%Y-%m-%d").to_string();
    let mut out = vec![];
    for z in list.get("result").and_then(|r| r.as_array()).cloned().unwrap_or_default() {
        let id = z["id"].as_str().unwrap_or("");
        let q = format!("{{ viewer {{ zones(filter: {{zoneTag: \"{id}\"}}) {{ httpRequests1dGroups(limit: 7, orderBy: [date_ASC], filter: {{date_geq: \"{since}\"}}) {{ dimensions {{ date }} uniq {{ uniques }} sum {{ requests bytes cachedRequests threats pageViews countryMap {{ clientCountryName requests }} responseStatusMap {{ edgeResponseStatus requests }} }} }} }} }} }}");
        let j = cf_call(token, "/graphql", Some(&json!({"query": q})))?;
        let groups = j.pointer("/data/viewer/zones/0/httpRequests1dGroups").and_then(|g| g.as_array()).cloned().unwrap_or_default();
        let (mut days, mut countries, mut statuses) = (vec![], Map::new(), Map::new());
        for g in groups {
            let s = &g["sum"];
            let n = |k: &str| s.get(k).and_then(|v| v.as_i64()).unwrap_or(0);
            days.push(json!({"date": g.pointer("/dimensions/date"), "requests": n("requests"), "visitors": g.pointer("/uniq/uniques").and_then(|v| v.as_i64()).unwrap_or(0),
                             "bytes": n("bytes"), "cached": n("cachedRequests"), "threats": n("threats"), "pageViews": n("pageViews")}));
            for c in s.get("countryMap").and_then(|c| c.as_array()).cloned().unwrap_or_default() {
                let k = c.get("clientCountryName").and_then(|v| v.as_str()).unwrap_or("?").to_string();
                let v = countries.get(&k).and_then(|v| v.as_i64()).unwrap_or(0) + c.get("requests").and_then(|v| v.as_i64()).unwrap_or(0);
                countries.insert(k, json!(v));
            }
            for c in s.get("responseStatusMap").and_then(|c| c.as_array()).cloned().unwrap_or_default() {
                let k = c.get("edgeResponseStatus").map(|v| v.to_string()).unwrap_or_default();
                let v = statuses.get(&k).and_then(|v| v.as_i64()).unwrap_or(0) + c.get("requests").and_then(|v| v.as_i64()).unwrap_or(0);
                statuses.insert(k, json!(v));
            }
        }
        let mut cs: Vec<(String, i64)> = countries.into_iter().map(|(k, v)| (k, v.as_i64().unwrap_or(0))).collect();
        cs.sort_by(|a, b| b.1.cmp(&a.1));
        let mut ss: Vec<(String, i64)> = statuses.into_iter().map(|(k, v)| (k, v.as_i64().unwrap_or(0))).collect();
        ss.sort();
        out.push(json!({"id": id, "name": z["name"], "days": days, "countries": cs.into_iter().take(6).map(|(k, v)| json!([k, v])).collect::<Vec<_>>(),
                        "statuses": ss.into_iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>()}));
    }
    out.sort_by_key(|z| -z["days"].as_array().map(|d| d.iter().map(|x| x["requests"].as_i64().unwrap_or(0)).sum::<i64>()).unwrap_or(0));
    Ok(out)
}

pub enum OmniError {
    Denied,
    Other(String),
}

fn omni_get(base: &str, path: &str, key: &str) -> Result<Value, OmniError> {
    let mut req = agent().get(&format!("{base}{path}"));
    if !key.is_empty() {
        req = req.set("Authorization", &format!("Bearer {key}"));
    }
    match req.call() {
        Ok(r) => r.into_json().map_err(|e| OmniError::Other(e.to_string())),
        Err(ureq::Error::Status(401 | 403, _)) => Err(OmniError::Denied),
        Err(ureq::Error::Status(c, _)) => Err(OmniError::Other(format!("HTTP {c}"))),
        Err(e) => Err(OmniError::Other(format!("tidak terjangkau: {e}"))),
    }
}

pub fn omniroute_load(base: &str, key: &str) -> Result<Value, OmniError> {
    let providers = omni_get(base, "/api/providers", key)?;
    let safe = |p: &str| omni_get(base, p, key).unwrap_or(json!({}));
    let conns: Vec<Value> = providers.get("connections").and_then(|c| c.as_array()).cloned().unwrap_or_default();
    let mut out = json!({"connections": conns.iter().map(|c| json!({"name": c.get("name").and_then(|v| v.as_str()).unwrap_or("?"),
        "provider": c.get("provider").and_then(|v| v.as_str()).unwrap_or("?"), "active": c.get("isActive").and_then(|v| v.as_bool()).unwrap_or(false),
        "testStatus": c.get("testStatus").and_then(|v| v.as_str()).unwrap_or(""), "lastError": c.get("lastError").cloned().unwrap_or(Value::Null)})).collect::<Vec<_>>()});
    let o = out.as_object_mut().unwrap();
    let m = safe("/api/providers/health-matrix");
    let sm = m.get("summary").cloned().unwrap_or(json!({}));
    let mut states = Map::new();
    for p in m.get("providers").and_then(|p| p.as_array()).cloned().unwrap_or_default() {
        if let Some(n) = p.get("provider").and_then(|v| v.as_str()) {
            states.insert(n.into(), p.get("state").cloned().unwrap_or(Value::Null));
        }
    }
    let n = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
    o.insert("healthy".into(), json!(n(&sm, "healthyCount") as i64));
    o.insert("degraded".into(), json!(n(&sm, "degradedCount") as i64));
    o.insert("down".into(), json!(n(&sm, "downCount") as i64));
    o.insert("models".into(), json!(n(&sm, "modelCount") as i64));
    let met = safe("/api/provider-metrics").get("metrics").and_then(|m| m.as_object()).cloned().unwrap_or_default();
    let mut metrics: Vec<Value> = met.iter().filter(|(_, v)| v.is_object()).map(|(k, v)| {
        let sr = n(v, "successRate");
        let state = states.get(k).and_then(|s| s.as_str()).map(String::from).unwrap_or_else(|| (if sr >= 90.0 { "healthy" } else if sr >= 70.0 { "degraded" } else { "down" }).into());
        json!({"provider": k, "requests": n(v, "totalRequests") as i64, "successRate": sr, "latency": n(v, "avgLatencyMs") as i64, "lastAt": v.get("lastRequestAt"), "state": state})
    }).collect();
    metrics.sort_by_key(|m| -m["requests"].as_i64().unwrap_or(0));
    o.insert("metrics".into(), json!(metrics));
    o.insert("providerStates".into(), Value::Object(states));
    let a = safe("/api/usage/analytics");
    let s = a.get("summary").cloned().unwrap_or(json!({}));
    o.insert("usage".into(), json!({"requests": n(&s, "totalRequests") as i64, "tokens": n(&s, "totalTokens") as i64, "cost": n(&s, "totalCost"),
        "successRate": s.get("successRatePct"), "latency": s.get("avgLatencyMs"), "since": s.get("firstRequest")}));
    let days: Vec<Value> = a.get("dailyTrend").and_then(|d| d.as_array()).cloned().unwrap_or_default().iter()
        .map(|d| json!({"date": d.get("date"), "requests": n(d, "requests") as i64, "tokens": n(d, "totalTokens") as i64})).collect();
    let skip = days.len().saturating_sub(14);
    o.insert("days".into(), json!(days[skip..]));
    let mut by_model: Vec<Value> = a.get("byModel").and_then(|d| d.as_array()).cloned().unwrap_or_default().iter()
        .map(|r| json!({"name": r.get("model"), "provider": r.get("provider"), "requests": n(r, "requests") as i64, "tokens": n(r, "totalTokens") as i64})).collect();
    by_model.sort_by_key(|r| -r["tokens"].as_i64().unwrap_or(0));
    by_model.truncate(10);
    o.insert("byModel".into(), json!(by_model));
    let lim = safe("/api/usage/provider-limits").get("caches").and_then(|c| c.as_object()).cloned().unwrap_or_default();
    let mut quotas = vec![];
    for (cid, v) in lim.iter().filter(|(_, v)| v.is_object()) {
        let mut ws: Vec<Value> = v.get("quotas").and_then(|q| q.as_object()).cloned().unwrap_or_default().iter().filter(|(_, q)| q.is_object()).map(|(label, q)| {
            let (used, total) = (n(q, "used"), n(q, "total"));
            let rem = q.get("remainingPercentage").and_then(|r| r.as_f64()).unwrap_or(if total > 0.0 { ((total - used) / total * 100.0).max(0.0) } else { 100.0 });
            json!({"label": q.get("displayName").and_then(|d| d.as_str()).unwrap_or(label), "remaining": rem, "resetAt": q.get("resetAt")})
        }).collect();
        ws.sort_by(|a, b| a["remaining"].as_f64().partial_cmp(&b["remaining"].as_f64()).unwrap_or(std::cmp::Ordering::Equal));
        let c = conns.iter().find(|c| c.get("id").and_then(|i| i.as_str()) == Some(cid.as_str()));
        quotas.push(json!({"account": c.and_then(|c| c.get("name")).and_then(|v| v.as_str()).map(String::from).unwrap_or_else(|| cid.chars().take(8).collect()),
                           "provider": c.and_then(|c| c.get("provider")).and_then(|v| v.as_str()).unwrap_or("?"), "plan": v.get("plan"), "windows": ws}));
    }
    quotas.sort_by_key(|q| (q["windows"].as_array().map(|w| w.is_empty()).unwrap_or(true), q["provider"].as_str().unwrap_or("").to_string(), q["account"].as_str().unwrap_or("").to_string()));
    o.insert("quotas".into(), json!(quotas));
    Ok(out)
}
