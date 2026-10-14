//! Microsoft Clarity (Data Export API): how people use one website.
//!
//! Clarity allows 10 requests per project per day and only returns the last 1–3 days, so a
//! refresh spends two calls (totals, then per page), runs at most every 6 hours, never more
//! often than every 15 minutes by hand, and the daily totals are kept here as history.
//! Custom events (contact clicks) are not part of the export; they stay in Clarity itself.

use crate::core::now;
use crate::metrics::Metrics;
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const ENV_KEYS: [&str; 3] = ["CLARITY_API_TOKEN", "CLARITY_TOKEN", "MS_CLARITY_API_TOKEN"];
pub const DAILY_LIMIT: i64 = 10;
const CALLS_PER_REFRESH: i64 = 2;
pub const EVERY: f64 = 6.0 * 3600.0;
const RETRY: f64 = 3600.0;
pub const MANUAL_GAP: f64 = 15.0 * 60.0;
const HISTORY_DAYS: usize = 90;
const URL: &str = "https://www.clarity.ms/export-data/api/v1/project-live-insights";

pub enum FetchError {
    Denied(String),
    Quota,
    Other(String),
}

fn fetch(token: &str, dimension: Option<&str>) -> Result<Value, FetchError> {
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(30)).user_agent(crate::net::UA).build();
    let mut req = agent.get(URL).query("numOfDays", "1").set("Authorization", &format!("Bearer {token}")).set("Content-Type", "application/json");
    if let Some(d) = dimension {
        req = req.query("dimension1", d);
    }
    match req.call() {
        Ok(r) => r.into_json().map_err(|e| FetchError::Other(e.to_string())),
        Err(ureq::Error::Status(401 | 403, _)) => Err(FetchError::Denied("token ditolak Clarity (401/403)".into())),
        Err(ureq::Error::Status(429, _)) => Err(FetchError::Quota),
        Err(ureq::Error::Status(code, _)) => Err(FetchError::Other(format!("HTTP {code}"))),
        Err(e) => Err(FetchError::Other(e.to_string().chars().take(160).collect())),
    }
}

// ── Parsing (the export's field names vary by metric, so lookups are tolerant) ──

fn key(name: &str) -> String {
    name.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>().to_ascii_lowercase()
}

fn num(row: &Value, names: &[&str]) -> Option<f64> {
    let obj = row.as_object()?;
    for want in names {
        for (k, v) in obj {
            if key(k) == key(want) {
                let n = v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse::<f64>().ok()));
                if let Some(n) = n.filter(|n| n.is_finite()) {
                    return Some(n);
                }
            }
        }
    }
    None
}

/// The dimension value of a row (URL, device, country…): its first text field that isn't a number.
fn label(row: &Value, dimension: Option<&str>) -> Option<String> {
    let obj = row.as_object()?;
    if let Some(d) = dimension {
        if let Some(v) = obj.iter().find(|(k, _)| key(k) == key(d)).and_then(|(_, v)| v.as_str()) {
            return Some(v.to_string());
        }
    }
    obj.values().filter_map(|v| v.as_str()).find(|v| v.trim().parse::<f64>().is_err()).map(String::from)
}

const SESSIONS: [&str; 5] = ["sessionsCount", "totalSessionCount", "visitsCount", "subTotal", "count"];

fn issue(rows: &[Value]) -> Value {
    let r = rows.first().cloned().unwrap_or(Value::Null);
    json!({"sessions": num(&r, &["sessionsCount", "subTotal", "count"]), "pct": num(&r, &["sessionsWithMetricPercentage", "percentage"])})
}

fn metrics_of(resp: &Value) -> Vec<(String, Vec<Value>)> {
    resp.as_array().map(|a| a.iter().map(|m| (key(m.get("metricName").and_then(|n| n.as_str()).unwrap_or("")),
        m.get("information").and_then(|i| i.as_array()).cloned().unwrap_or_default())).collect()).unwrap_or_default()
}

const ISSUES: [(&str, &str); 6] = [("deadclickcount", "deadClicks"), ("rageclickcount", "rageClicks"), ("quickbackclick", "quickbacks"),
    ("excessivescroll", "excessiveScroll"), ("scripterrorcount", "scriptErrors"), ("errorclickcount", "errorClicks")];
const LISTS: [(&str, &str); 8] = [("popularpages", "popularPages"), ("referrerurl", "referrers"), ("device", "devices"), ("countryregion", "countries"),
    ("country", "countries"), ("browser", "browsers"), ("os", "os"), ("pagetitle", "pageTitles")];

/// Totals and top lists from the call without a dimension.
pub fn summarize(resp: &Value) -> (Value, Value) {
    let mut totals = Map::new();
    let mut lists = Map::new();
    for (name, rows) in metrics_of(resp) {
        let first = rows.first().cloned().unwrap_or(Value::Null);
        match name.as_str() {
            "traffic" => {
                totals.insert("sessions".into(), json!(num(&first, &["totalSessionCount"])));
                totals.insert("bots".into(), json!(num(&first, &["totalBotSessionCount"])));
                totals.insert("users".into(), json!(num(&first, &["distinctUserCount", "distantUserCount"])));
                totals.insert("pagesPerSession".into(), json!(num(&first, &["PagesPerSessionPercentage", "pagesPerSession"])));
            }
            "scrolldepth" => {
                totals.insert("scrollDepth".into(), json!(num(&first, &["averageScrollDepth", "scrollDepth", "average"])));
            }
            "engagementtime" => {
                totals.insert("totalTime".into(), json!(num(&first, &["totalTime"])));
                totals.insert("activeTime".into(), json!(num(&first, &["activeTime"])));
            }
            n => {
                if let Some((_, k)) = ISSUES.iter().find(|(m, _)| *m == n) {
                    totals.insert(k.to_string(), issue(&rows));
                } else if let Some((_, k)) = LISTS.iter().find(|(m, _)| *m == n) {
                    let mut l: Vec<Value> = rows.iter().filter_map(|r| Some(json!({"name": label(r, None)?, "sessions": num(r, &SESSIONS)}))).collect();
                    l.sort_by(|a, b| b["sessions"].as_f64().unwrap_or(0.0).total_cmp(&a["sessions"].as_f64().unwrap_or(0.0)));
                    l.truncate(25);
                    lists.insert(k.to_string(), json!(l));
                }
            }
        }
    }
    (Value::Object(totals), Value::Object(lists))
}

/// Per-page rows from the call broken down by URL.
pub fn pages(resp: &Value) -> Vec<Value> {
    let mut by: Vec<(String, Map<String, Value>)> = vec![];
    for (name, rows) in metrics_of(resp) {
        for r in &rows {
            let Some(url) = label(r, Some("Url")) else { continue };
            let i = match by.iter().position(|(u, _)| *u == url) {
                Some(i) => i,
                None => {
                    by.push((url.clone(), Map::new()));
                    by.len() - 1
                }
            };
            let m = &mut by[i].1;
            match name.as_str() {
                "traffic" => {
                    m.insert("sessions".into(), json!(num(r, &["totalSessionCount"])));
                    m.insert("bots".into(), json!(num(r, &["totalBotSessionCount"])));
                    m.insert("users".into(), json!(num(r, &["distinctUserCount", "distantUserCount"])));
                }
                "scrolldepth" => {
                    m.insert("scrollDepth".into(), json!(num(r, &["averageScrollDepth", "scrollDepth", "average"])));
                }
                "engagementtime" => {
                    m.insert("activeTime".into(), json!(num(r, &["activeTime"])));
                    m.insert("totalTime".into(), json!(num(r, &["totalTime"])));
                }
                n => {
                    if let Some((_, k)) = ISSUES.iter().take(3).find(|(x, _)| *x == n) {
                        m.insert(k.to_string(), json!(num(r, &["sessionsCount", "subTotal", "count"])));
                    }
                }
            }
        }
    }
    let mut out: Vec<Value> = by.into_iter().map(|(url, mut m)| {
        m.insert("url".into(), json!(url));
        Value::Object(m)
    }).collect();
    out.sort_by(|a, b| b["sessions"].as_f64().unwrap_or(0.0).total_cmp(&a["sessions"].as_f64().unwrap_or(0.0)));
    out.truncate(60);
    out
}

/// The website's host, taken from the page URLs (no configuration needed).
fn site_of(pages: &[Value]) -> Option<String> {
    pages.iter().filter_map(|p| p["url"].as_str()).find_map(|u| u.split("://").nth(1).map(|r| r.split('/').next().unwrap_or("").to_string())).filter(|h| !h.is_empty())
}

// ── State, quota and schedule ──

pub struct Clarity {
    metrics: Arc<Metrics>,
    pub state: Mutex<Value>,
    busy: Mutex<bool>,
}

fn today() -> String {
    chrono::Utc::now().format("%Y-%m-%d").to_string()
}

impl Clarity {
    pub fn new(metrics: Arc<Metrics>) -> Clarity {
        let saved = metrics.get("clarity").filter(|v| v.is_object()).unwrap_or(json!({"state": "idle"}));
        Clarity { metrics, state: Mutex::new(saved), busy: Mutex::new(false) }
    }

    /// Calls already spent today (UTC, the day Clarity counts in).
    pub fn used(st: &Value) -> i64 {
        if st["quota"]["date"].as_str() == Some(today().as_str()) { st["quota"]["used"].as_i64().unwrap_or(0) } else { 0 }
    }

    /// Whether the background loop should spend calls now.
    pub fn due(st: &Value, t: f64) -> bool {
        let last_try = st["lastTry"].as_f64().unwrap_or(0.0);
        let wait = if st["state"] == "ok" { EVERY } else { RETRY };
        t - last_try >= wait && Self::used(st) + CALLS_PER_REFRESH <= DAILY_LIMIT
    }

    /// Why a manual refresh would be refused now (None = allowed).
    pub fn refusal(st: &Value, t: f64) -> Option<String> {
        let gap = t - st["lastTry"].as_f64().unwrap_or(0.0);
        if gap < MANUAL_GAP && st["state"] != "noToken" && st["state"] != "idle" {
            return Some(format!("Clarity baru dimuat {} menit lalu. Clarity membatasi {} permintaan per hari, jadi coba lagi nanti.", (gap / 60.0).floor(), DAILY_LIMIT));
        }
        if Self::used(st) + CALLS_PER_REFRESH > DAILY_LIMIT {
            return Some("Jatah Clarity hari ini (UTC) sudah habis; dimuat lagi besok.".into());
        }
        None
    }

    /// The view for the UIs: everything but the quota bookkeeping.
    pub fn view(&self) -> Value {
        let mut v = self.state.lock().unwrap().clone();
        let used = Self::used(&v);
        if let Some(o) = v.as_object_mut() {
            o.remove("quota");
            o.insert("used".into(), json!(used));
            o.insert("limit".into(), json!(DAILY_LIMIT));
            o.insert("everyHours".into(), json!(EVERY / 3600.0));
        }
        v
    }

    fn save(&self, st: &Value) {
        self.metrics.put("clarity", st);
        *self.state.lock().unwrap() = st.clone();
    }

    /// `manual` = the Refresh button: refused (with a reason) inside the 15-minute gap or
    /// when today's calls are spent, so a click can't burn Clarity's daily limit.
    pub fn refresh(&self, tokens: Vec<(String, String)>, manual: bool) -> Result<(), String> {
        {
            let mut busy = self.busy.lock().unwrap();
            if *busy {
                return Err("Clarity sedang dimuat".into());
            }
            *busy = true;
        }
        let r = self.refresh_inner(tokens, manual);
        *self.busy.lock().unwrap() = false;
        r
    }

    fn refresh_inner(&self, tokens: Vec<(String, String)>, manual: bool) -> Result<(), String> {
        let mut st = self.state.lock().unwrap().clone();
        let t = now();
        if tokens.is_empty() {
            st["state"] = json!("noToken");
            st["tried"] = json!([]);
            self.save(&st);
            return Ok(());
        }
        if manual {
            if let Some(why) = Self::refusal(&st, t) {
                return Err(why);
            }
        } else if !Self::due(&st, t) {
            return Ok(());
        }
        let mut used = Self::used(&st);
        st["lastTry"] = json!(t);
        let mut tried = vec![];
        let mut outcome: Result<(Value, Value), (String, String)> = Err(("noToken".into(), String::new()));
        for (source, token) in tokens {
            used += 1;
            let totals = fetch(&token, None);
            let per_page = match &totals {
                Ok(_) => {
                    used += 1;
                    fetch(&token, Some("URL"))
                }
                Err(_) => Err(FetchError::Other(String::new())),
            };
            match (totals, per_page) {
                (Ok(a), Ok(b)) => {
                    tried.push(json!({"source": source, "result": "OK"}));
                    outcome = Ok((a, b));
                    break;
                }
                (Ok(a), Err(_)) => {
                    // Totals are enough to show; pages come with the next refresh.
                    tried.push(json!({"source": source, "result": "OK (tanpa rincian halaman)"}));
                    outcome = Ok((a, json!([])));
                    break;
                }
                (Err(FetchError::Denied(m)), _) => {
                    tried.push(json!({"source": source, "result": m}));
                    outcome = Err(("denied".into(), "Token Clarity ditolak. Buat token baru di Clarity → Settings → Data Export.".into()));
                }
                (Err(FetchError::Quota), _) => {
                    tried.push(json!({"source": source, "result": "batas harian Clarity tercapai (429)"}));
                    used = DAILY_LIMIT;
                    outcome = Err(("quota".into(), "Batas 10 permintaan per hari dari Clarity tercapai.".into()));
                    break;
                }
                (Err(FetchError::Other(m)), _) => {
                    tried.push(json!({"source": source, "result": m.clone()}));
                    outcome = Err(("error".into(), m));
                }
            }
        }
        st["quota"] = json!({"date": today(), "used": used.min(DAILY_LIMIT)});
        st["tried"] = json!(tried);
        match outcome {
            Ok((a, b)) => {
                let (totals, lists) = summarize(&a);
                let pages = pages(&b);
                st["state"] = json!("ok");
                st["at"] = json!(t);
                st["error"] = Value::Null;
                if let Some(site) = site_of(&pages) {
                    st["site"] = json!(site);
                }
                // One row per UTC day: the latest 24-hour window measured that day.
                let mut hist: Vec<Value> = st["history"].as_array().cloned().unwrap_or_default();
                hist.retain(|h| h["date"].as_str() != Some(today().as_str()));
                let mut row = totals.clone();
                row["date"] = json!(today());
                hist.push(row);
                hist.sort_by(|a, b| a["date"].as_str().cmp(&b["date"].as_str()));
                let skip = hist.len().saturating_sub(HISTORY_DAYS);
                st["history"] = json!(hist.into_iter().skip(skip).collect::<Vec<_>>());
                st["totals"] = totals;
                st["lists"] = lists;
                st["pages"] = json!(pages);
            }
            Err((state, msg)) => {
                st["state"] = json!(state);
                st["error"] = json!(msg);
            }
        }
        self.save(&st);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Value {
        json!([
            {"metricName": "Traffic", "information": [{"totalSessionCount": "120", "totalBotSessionCount": "30", "distantUserCount": "95", "PagesPerSessionPercentage": 1.8}]},
            {"metricName": "Scroll Depth", "information": [{"averageScrollDepth": 42.5}]},
            {"metricName": "Engagement Time", "information": [{"totalTime": "180", "activeTime": "64"}]},
            {"metricName": "DeadClickCount", "information": [{"sessionsCount": "9", "sessionsWithMetricPercentage": 7.5}]},
            {"metricName": "QuickbackClick", "information": [{"sessionsCount": "14", "sessionsWithMetricPercentage": 11.7}]},
            {"metricName": "Device", "information": [{"name": "Mobile", "sessionsCount": "80"}, {"name": "PC", "sessionsCount": "40"}]},
            {"metricName": "Unknown thing", "information": [{"x": 1}]}
        ])
    }

    #[test]
    fn totals_and_lists_tolerate_field_names() {
        let (t, l) = summarize(&sample());
        assert_eq!(t["sessions"], json!(120.0));
        assert_eq!(t["bots"], json!(30.0));
        assert_eq!(t["users"], json!(95.0));
        assert_eq!(t["scrollDepth"], json!(42.5));
        assert_eq!(t["activeTime"], json!(64.0));
        assert_eq!(t["deadClicks"], json!({"sessions": 9.0, "pct": 7.5}));
        assert_eq!(t["quickbacks"]["pct"], json!(11.7));
        assert_eq!(l["devices"], json!([{"name": "Mobile", "sessions": 80.0}, {"name": "PC", "sessions": 40.0}]));
        assert_eq!(summarize(&json!({"not": "a list"})), (json!({}), json!({})));
    }

    #[test]
    fn pages_merge_metrics_per_url_and_give_the_site() {
        let resp = json!([
            {"metricName": "Traffic", "information": [
                {"totalSessionCount": "10", "distinctUserCount": "8", "Url": "https://example.test/contact"},
                {"totalSessionCount": "50", "distinctUserCount": "41", "Url": "https://example.test/"}]},
            {"metricName": "ScrollDepth", "information": [{"averageScrollDepth": 31.0, "Url": "https://example.test/contact"}]},
            {"metricName": "RageClickCount", "information": [{"sessionsCount": "2", "Url": "https://example.test/contact"}]}
        ]);
        let p = pages(&resp);
        assert_eq!(p[0]["url"], "https://example.test/");
        assert_eq!(p[1]["scrollDepth"], json!(31.0));
        assert_eq!(p[1]["rageClicks"], json!(2.0));
        assert_eq!(site_of(&p).as_deref(), Some("example.test"));
    }

    #[test]
    fn schedule_respects_the_daily_limit() {
        let t = 1_000_000.0;
        assert!(Clarity::due(&json!({"state": "idle"}), t));
        assert!(!Clarity::due(&json!({"state": "ok", "lastTry": t - 3600.0}), t));
        assert!(Clarity::due(&json!({"state": "ok", "lastTry": t - EVERY}), t));
        assert!(!Clarity::due(&json!({"state": "error", "lastTry": t - 600.0}), t));
        let spent = json!({"state": "ok", "lastTry": 0.0, "quota": {"date": today(), "used": 9}});
        assert!(!Clarity::due(&spent, t));
        assert_eq!(Clarity::used(&json!({"quota": {"date": "2000-01-01", "used": 10}})), 0);
        // 6-hourly refreshes of 2 calls each stay inside the limit with room for manual ones.
        assert!(24.0 / (EVERY / 3600.0) * CALLS_PER_REFRESH as f64 <= DAILY_LIMIT as f64 - 2.0);
    }
}
