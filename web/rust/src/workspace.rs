//! Workspace store (port of workspace.py): same schema as the Mac app, every write in one
//! transaction, and `apply` for replication under an SQLite authorizer.

use crate::core::now;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{params_from_iter, Connection};
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};

pub const LIFECYCLES: [(&str, &str); 6] = [("idea", "Idea"), ("planned", "Planned"), ("building", "Building"), ("live", "Live"), ("maintenance", "Maintenance"), ("archived", "Archived")];
pub const STATUSES: [(&str, &str); 5] = [("backlog", "Backlog"), ("ready", "Ready"), ("in_progress", "In Progress"), ("review", "Review"), ("done", "Done")];

#[derive(Debug)]
pub struct WsError(pub String);
impl std::fmt::Display for WsError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl From<rusqlite::Error> for WsError {
    fn from(e: rusqlite::Error) -> Self {
        WsError(format!("data tidak valid: {e}"))
    }
}
type R<T> = Result<T, WsError>;
fn err<T>(m: &str) -> R<T> {
    Err(WsError(m.to_string()))
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub fn make_key(name: &str, taken: &[String]) -> String {
    let up = name.to_uppercase();
    let words: Vec<&str> = up.split(|c: char| !c.is_ascii_alphanumeric()).filter(|w| !w.is_empty()).collect();
    let mut base: String = if words.len() > 1 { words.iter().take(3).map(|w| &w[..1]).collect() } else { words.first().map(|w| w.chars().take(3).collect()).unwrap_or_else(|| "P".into()) };
    if base.is_empty() {
        base = "P".into();
    }
    let (mut key, mut n) = (base.clone(), 2);
    while taken.contains(&key) {
        key = format!("{base}{n}");
        n += 1;
    }
    key
}

pub fn position(positions: &[f64], before: Option<usize>) -> f64 {
    match before {
        Some(i) if i < positions.len() => {
            let next = positions[i];
            let prev = if i > 0 { positions[i - 1] } else { next - 2048.0 };
            (prev + next) / 2.0
        }
        _ => positions.last().copied().unwrap_or(0.0) + 1024.0,
    }
}

fn to_json(v: ValueRef) -> Value {
    match v {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(i) => json!(i),
        ValueRef::Real(f) => json!(f),
        ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
        ValueRef::Blob(b) => json!(String::from_utf8_lossy(b)),
    }
}
fn to_sql(v: &Value) -> SqlValue {
    match v {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(*b as i64),
        Value::Number(n) => n.as_i64().map(SqlValue::Integer).unwrap_or_else(|| SqlValue::Real(n.as_f64().unwrap_or(0.0))),
        Value::String(s) => SqlValue::Text(s.clone()),
        other => SqlValue::Text(other.to_string()),
    }
}

fn s_(d: &Value, k: &str) -> String {
    d.get(k).and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default()
}
fn req(d: &Value, k: &str) -> R<String> {
    let v = s_(d, k);
    if v.is_empty() {
        return Err(WsError(format!("{k} wajib diisi")));
    }
    if v.chars().count() > 300 {
        return Err(WsError(format!("{k} terlalu panjang")));
    }
    Ok(v)
}
fn prio(v: Option<&Value>) -> i64 {
    v.and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)).or_else(|| x.as_str().and_then(|s| s.parse().ok()))).unwrap_or(0).clamp(0, 4)
}
fn num(v: Option<&Value>) -> R<Option<f64>> {
    match v {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.is_empty() => Ok(None),
        Some(Value::Number(n)) => Ok(n.as_f64()),
        Some(Value::String(s)) => s.parse().map(Some).map_err(|_| WsError("tanggal tidak valid".into())),
        _ => err("tanggal tidak valid"),
    }
}
fn labels(v: Option<&Value>) -> String {
    let list: Vec<String> = match v {
        Some(Value::String(s)) => s.split(',').map(|x| x.trim().to_string()).collect(),
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str()).map(|x| x.trim().to_string()).collect(),
        _ => vec![],
    };
    serde_json::to_string(&list.into_iter().filter(|x| !x.is_empty()).take(20).collect::<Vec<_>>()).unwrap()
}
fn truthy(v: Option<&Value>) -> i64 {
    match v {
        Some(Value::Bool(b)) => *b as i64,
        Some(Value::Number(n)) => (n.as_f64().unwrap_or(0.0) != 0.0) as i64,
        Some(Value::String(s)) => (!s.is_empty() && s != "0" && s != "false") as i64,
        _ => 0,
    }
}

pub struct Workspace {
    pub db: Mutex<Connection>,
    pub on_change: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    pub path: String,
}

impl Workspace {
    pub fn open(path: &str, schemas: &[(i64, &str)]) -> R<Workspace> {
        if let Some(dir) = std::path::Path::new(path).parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")?;
        let ws = Workspace { db: Mutex::new(db), on_change: Mutex::new(None), path: path.to_string() };
        ws.migrate(schemas)?;
        Ok(ws)
    }

    fn migrate(&self, schemas: &[(i64, &str)]) -> R<()> {
        let current: i64 = self.db.lock().unwrap().query_row("PRAGMA user_version", [], |r| r.get(0))?;
        let pending: Vec<&(i64, &str)> = schemas.iter().filter(|(v, _)| *v > current).collect();
        if !pending.is_empty() && current > 0 {
            let _ = self.backup("pre-migration");
        }
        let mut db = self.db.lock().unwrap();
        for (v, sql) in pending {
            let tx = db.transaction()?;
            tx.execute_batch(sql)?;
            tx.execute_batch(&format!("PRAGMA user_version={v}"))?;
            tx.commit()?;
        }
        Ok(())
    }

    pub fn backup(&self, reason: &str) -> R<String> {
        let dir = std::path::Path::new(&self.path).parent().unwrap().join("backups");
        std::fs::create_dir_all(&dir).map_err(|e| WsError(e.to_string()))?;
        let out = dir.join(format!("workspace-{}-{reason}.sqlite", chrono::Local::now().format("%Y%m%d-%H%M%S")));
        let db = self.db.lock().unwrap();
        db.execute("VACUUM INTO ?", [out.to_string_lossy().to_string()])?;
        let mut files: Vec<_> = std::fs::read_dir(&dir).map(|r| r.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.file_name().map(|n| n.to_string_lossy().starts_with("workspace-")).unwrap_or(false)).collect()).unwrap_or_default();
        files.sort();
        if files.len() > 10 {
            for f in &files[..files.len() - 10] {
                let _ = std::fs::remove_file(f);
            }
        }
        Ok(out.to_string_lossy().to_string())
    }

    fn changed(&self) {
        if let Some(f) = self.on_change.lock().unwrap().clone() {
            f();
        }
    }

    fn tx<T>(&self, body: impl FnOnce(&rusqlite::Transaction) -> R<T>) -> R<T> {
        let r = {
            let mut db = self.db.lock().unwrap();
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let r = body(&tx)?;
            tx.commit()?;
            r
        };
        self.changed();
        Ok(r)
    }

    fn event(tx: &rusqlite::Transaction, project: Option<&str>, kind: &str, title: &str, meta: Value) -> R<()> {
        tx.execute("INSERT OR IGNORE INTO activity (id, project_id, type, ts, source, title, url, meta) VALUES (?,?,?,?,?,?,?,?)",
                   rusqlite::params![format!("raphael:{}", new_id()), project, kind, now(), "raphael", title, "", meta.to_string()])?;
        Ok(())
    }

    fn rows(db: &Connection, sql: &str, args: &[SqlValue]) -> R<Vec<Map<String, Value>>> {
        let mut st = db.prepare(sql)?;
        let cols: Vec<String> = st.column_names().iter().map(|c| c.to_string()).collect();
        let mut out = vec![];
        let mut q = st.query(params_from_iter(args.iter()))?;
        while let Some(r) = q.next()? {
            let mut m = Map::new();
            for (i, c) in cols.iter().enumerate() {
                m.insert(c.clone(), to_json(r.get_ref(i)?));
            }
            out.push(m);
        }
        Ok(out)
    }

    // ── Read ──
    pub fn snapshot(&self) -> R<Value> {
        let db = self.db.lock().unwrap();
        let portfolios = Self::rows(&db, "SELECT * FROM portfolio ORDER BY archived, sort, name", &[])?;
        let mut projects = Self::rows(&db, "SELECT * FROM project ORDER BY sort, name COLLATE NOCASE", &[])?;
        let mut tasks = Self::rows(&db, "SELECT * FROM task ORDER BY project_id, status, position", &[])?;
        let milestones = Self::rows(&db, "SELECT * FROM milestone ORDER BY target_date IS NULL, target_date", &[])?;
        let mut activity = Self::rows(&db, "SELECT a.*, p.name AS project_name FROM activity a LEFT JOIN project p ON p.id = a.project_id ORDER BY ts DESC LIMIT 150", &[])?;
        let links = Self::rows(&db, "SELECT * FROM resource_link ORDER BY kind, ref", &[])?;
        drop(db);
        let parse = |v: &Value, d: Value| v.as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(d);
        for t in tasks.iter_mut() {
            let l = parse(&t["labels"], json!([]));
            t.insert("labels".into(), l);
        }
        let today = start_of_day(now());
        for p in projects.iter_mut() {
            let l = parse(&p["labels"], json!([]));
            let w = parse(&p["wip_limits"], json!({}));
            p.insert("labels".into(), l);
            p.insert("wip_limits".into(), w);
            let id = p["id"].clone();
            let top: Vec<&Map<String, Value>> = tasks.iter().filter(|t| t["project_id"] == id && t["archived"] == 0 && t["parent_id"].is_null()).collect();
            let done = top.iter().filter(|t| t["status"] == "done").count();
            p.insert("progress".into(), if top.is_empty() { Value::Null } else { json!(done as f64 / top.len() as f64) });
            p.insert("open_tasks".into(), json!(top.iter().filter(|t| t["status"] != "done").count()));
            p.insert("blocked_tasks".into(), json!(top.iter().filter(|t| t["blocked"] != 0 && t["status"] != "done").count()));
            p.insert("overdue_tasks".into(), json!(top.iter().filter(|t| t["status"] != "done" && t["due_date"].as_f64().map(|d| d < today).unwrap_or(false)).count()));
        }
        for a in activity.iter_mut() {
            let m = parse(&a["meta"], json!({}));
            a.insert("meta".into(), m);
        }
        Ok(json!({"portfolios": portfolios, "projects": projects, "tasks": tasks, "milestones": milestones, "activity": activity, "links": links}))
    }

    fn one(tx: &rusqlite::Transaction, table: &str, id: &str, missing: &str) -> R<Map<String, Value>> {
        Self::rows(tx, &format!("SELECT * FROM {table} WHERE id=?"), &[SqlValue::Text(id.into())])?.into_iter().next().ok_or_else(|| WsError(missing.into()))
    }

    // ── Portfolios ──
    pub fn create_portfolio(&self, d: &Value) -> R<String> {
        let name = req(d, "name")?;
        let id = new_id();
        let t = now();
        let color = if s_(d, "color").is_empty() { "violet".to_string() } else { s_(d, "color") };
        self.tx(|tx| {
            let sort: f64 = tx.query_row("SELECT coalesce(MAX(sort),0) FROM portfolio", [], |r| r.get(0))?;
            tx.execute("INSERT INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,0,?,?,?)",
                       rusqlite::params![id, name, s_(d, "description"), color, sort + 1.0, t, t])?;
            Ok(())
        })?;
        Ok(id)
    }

    pub fn update_portfolio(&self, id: &str, d: &Value) -> R<()> {
        let mut f: Vec<(&str, SqlValue)> = vec![];
        if d.get("name").is_some() {
            f.push(("name", SqlValue::Text(req(d, "name")?)));
        }
        for k in ["description", "color"] {
            if d.get(k).is_some() {
                f.push((k, SqlValue::Text(s_(d, k))));
            }
        }
        if d.get("archived").is_some() {
            f.push(("archived", SqlValue::Integer(truthy(d.get("archived")))));
        }
        self.update("portfolio", id, f, |_, _| Ok(()))
    }

    pub fn delete(&self, table: &str, id: &str) -> R<()> {
        self.tx(|tx| {
            tx.execute(&format!("DELETE FROM {table} WHERE id=?"), [id])?;
            Ok(())
        })
    }

    // ── Projects ──
    pub fn create_project(&self, d: &Value) -> R<String> {
        let name = req(d, "name")?;
        let lifecycle = if s_(d, "lifecycle").is_empty() { "idea".to_string() } else { s_(d, "lifecycle") };
        if !LIFECYCLES.iter().any(|(k, _)| *k == lifecycle) {
            return err("lifecycle tidak valid");
        }
        let id = new_id();
        let t = now();
        let (start, target) = (num(d.get("start_date"))?, num(d.get("target_date"))?);
        self.tx(|tx| {
            let taken: Vec<String> = tx.prepare("SELECT key FROM project")?.query_map([], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
            let wanted = s_(d, "key").to_uppercase();
            let key: String = (if wanted.is_empty() { make_key(&name, &taken) } else { wanted }).chars().take(6).collect();
            if taken.contains(&key) {
                return Err(WsError(format!("key {key} sudah dipakai")));
            }
            let sort: f64 = tx.query_row("SELECT coalesce(MAX(sort),0) FROM project", [], |r| r.get(0))?;
            let pf = d.get("portfolio_id").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
            tx.execute("INSERT INTO project (id, portfolio_id, name, description, category, labels, lifecycle, paused, priority, favorite, pinned,
                        start_date, target_date, key, next_number, sort, wip_limits, created_at, updated_at) VALUES (?,?,?,?,?,?,?,0,?,0,0,?,?,?,1,?,'{}',?,?)",
                       rusqlite::params![id, pf, name, s_(d, "description"), s_(d, "category"), labels(d.get("labels")), lifecycle, prio(d.get("priority")),
                                         start, target, key, sort + 1.0, t, t])?;
            Self::event(tx, Some(&id), "project.created", &format!("Project {name} dibuat"), json!({}))?;
            Ok(())
        })?;
        Ok(id)
    }

    pub fn update_project(&self, id: &str, d: &Value) -> R<()> {
        let mut f: Vec<(&str, SqlValue)> = vec![];
        if d.get("name").is_some() {
            f.push(("name", SqlValue::Text(req(d, "name")?)));
        }
        for k in ["description", "category"] {
            if d.get(k).is_some() {
                f.push((k, SqlValue::Text(s_(d, k))));
            }
        }
        let lifecycle = s_(d, "lifecycle");
        if d.get("lifecycle").is_some() {
            if !LIFECYCLES.iter().any(|(k, _)| *k == lifecycle) {
                return err("lifecycle tidak valid");
            }
            f.push(("lifecycle", SqlValue::Text(lifecycle.clone())));
        }
        for k in ["paused", "favorite", "pinned"] {
            if d.get(k).is_some() {
                f.push((k, SqlValue::Integer(truthy(d.get(k)))));
            }
        }
        if d.get("priority").is_some() {
            f.push(("priority", SqlValue::Integer(prio(d.get("priority")))));
        }
        if d.get("labels").is_some() {
            f.push(("labels", SqlValue::Text(labels(d.get("labels")))));
        }
        if let Some(w) = d.get("wip_limits") {
            let mut m = Map::new();
            if let Some(o) = w.as_object() {
                for (k, v) in o {
                    let n = v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())).unwrap_or(0);
                    if STATUSES.iter().any(|(s, _)| s == k) && n > 0 {
                        m.insert(k.clone(), json!(n));
                    }
                }
            }
            f.push(("wip_limits", SqlValue::Text(Value::Object(m).to_string())));
        }
        for k in ["start_date", "target_date"] {
            if d.get(k).is_some() {
                f.push((k, num(d.get(k))?.map(SqlValue::Real).unwrap_or(SqlValue::Null)));
            }
        }
        if d.get("portfolio_id").is_some() {
            let v = s_(d, "portfolio_id");
            f.push(("portfolio_id", if v.is_empty() { SqlValue::Null } else { SqlValue::Text(v) }));
        }
        let new_name = d.get("name").map(|_| s_(d, "name"));
        let id2 = id.to_string();
        self.update("project", id, f, move |tx, old| {
            if d.get("lifecycle").is_some() && old["lifecycle"] != lifecycle.as_str() {
                let title = |k: &str| LIFECYCLES.iter().find(|(x, _)| *x == k).map(|x| x.1).unwrap_or("?");
                let name = new_name.clone().unwrap_or_else(|| old["name"].as_str().unwrap_or("").to_string());
                let from = old["lifecycle"].as_str().unwrap_or("");
                Self::event(tx, Some(&id2), "project.lifecycle", &format!("{name}: {} → {}", title(from), title(&lifecycle)), json!({"from": from, "to": lifecycle}))?;
            }
            Ok(())
        })
    }

    // ── Tasks ──
    pub fn create_task(&self, d: &Value) -> R<String> {
        let title = req(d, "title")?;
        let status = if s_(d, "status").is_empty() { "backlog".to_string() } else { s_(d, "status") };
        if !STATUSES.iter().any(|(k, _)| *k == status) {
            return err("status tidak valid");
        }
        let id = new_id();
        let t = now();
        let due = num(d.get("due_date"))?;
        self.tx(|tx| {
            let p = Self::one(tx, "project", &s_(d, "project_id"), "project tidak ditemukan")?;
            let pid = p["id"].as_str().unwrap().to_string();
            let last: f64 = tx.query_row("SELECT coalesce(MAX(position),0) FROM task WHERE project_id=? AND status=? AND archived=0 AND parent_id IS NULL",
                                         rusqlite::params![pid, status], |r| r.get(0))?;
            let number = p["next_number"].as_i64().unwrap_or(1);
            let parent = d.get("parent_id").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
            tx.execute("INSERT INTO task (id, number, project_id, parent_id, title, description, status, position, priority, assignee, labels, due_date,
                        blocked, blocked_reason, archived, started_at, completed_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,'',0,?,?,?,?)",
                       rusqlite::params![id, number, pid, parent, title, s_(d, "description"), status, last + 1024.0, prio(d.get("priority")),
                                         s_(d, "assignee"), labels(d.get("labels")), due,
                                         if status == "in_progress" { Some(t) } else { None }, if status == "done" { Some(t) } else { None }, t, t])?;
            tx.execute("UPDATE project SET next_number = next_number + 1 WHERE id=?", [&pid])?;
            let key = p["key"].as_str().filter(|k| !k.is_empty()).unwrap_or("T");
            Self::event(tx, Some(&pid), "task.created", &format!("{key}-{number} dibuat: {title}"), json!({"task": id}))?;
            Ok(())
        })?;
        Ok(id)
    }

    pub fn update_task(&self, id: &str, d: &Value) -> R<()> {
        let mut f: Vec<(&str, SqlValue)> = vec![];
        if d.get("title").is_some() {
            f.push(("title", SqlValue::Text(req(d, "title")?)));
        }
        for k in ["description", "assignee", "blocked_reason"] {
            if d.get(k).is_some() {
                f.push((k, SqlValue::Text(s_(d, k))));
            }
        }
        for k in ["blocked", "archived"] {
            if d.get(k).is_some() {
                f.push((k, SqlValue::Integer(truthy(d.get(k)))));
            }
        }
        if d.get("priority").is_some() {
            f.push(("priority", SqlValue::Integer(prio(d.get("priority")))));
        }
        if d.get("labels").is_some() {
            f.push(("labels", SqlValue::Text(labels(d.get("labels")))));
        }
        if d.get("due_date").is_some() {
            f.push(("due_date", num(d.get("due_date"))?.map(SqlValue::Real).unwrap_or(SqlValue::Null)));
        }
        for k in ["milestone_id", "epic_id"] {
            if d.get(k).is_some() {
                let v = s_(d, k);
                f.push((k, if v.is_empty() { SqlValue::Null } else { SqlValue::Text(v) }));
            }
        }
        if let Some(st) = d.get("status").and_then(|v| v.as_str()) {
            self.move_task(id, st, None)?;
        }
        if f.is_empty() {
            return Ok(());
        }
        self.update("task", id, f, |_, _| Ok(()))
    }

    /// Moves a card to `status`, before card `before` (None = end); renumbers the column in the
    /// same transaction when the gap is too small to split.
    pub fn move_task(&self, id: &str, status: &str, before: Option<&str>) -> R<()> {
        if !STATUSES.iter().any(|(k, _)| *k == status) {
            return err("status tidak valid");
        }
        if before == Some(id) {
            return Ok(());
        }
        self.tx(|tx| {
            let old = Self::one(tx, "task", id, "task tidak ditemukan")?;
            let pid = old["project_id"].as_str().unwrap().to_string();
            let col: Vec<(String, f64)> = tx
                .prepare("SELECT id, position FROM task WHERE project_id=? AND status=? AND archived=0 AND parent_id IS NULL AND id<>? ORDER BY position")?
                .query_map(rusqlite::params![pid, status, id], |r| Ok((r.get(0)?, r.get(1)?)))?
                .filter_map(|r| r.ok())
                .collect();
            let idx = before.and_then(|b| col.iter().position(|(c, _)| c == b));
            let mut pos = position(&col.iter().map(|c| c.1).collect::<Vec<_>>(), idx);
            if let Some(i) = idx {
                if i > 0 && (col[i].1 - col[i - 1].1).abs() < 1e-6 {
                    let mut order: Vec<String> = col.iter().map(|c| c.0.clone()).collect();
                    order.insert(i, id.to_string());
                    for (n, cid) in order.iter().enumerate() {
                        if cid != id {
                            tx.execute("UPDATE task SET position=? WHERE id=?", rusqlite::params![(n as f64 + 1.0) * 1024.0, cid])?;
                        }
                    }
                    pos = (order.iter().position(|c| c == id).unwrap() as f64 + 1.0) * 1024.0;
                }
            }
            let t = now();
            let old_status = old["status"].as_str().unwrap_or("").to_string();
            let (mut started, mut completed) = (old["started_at"].as_f64(), old["completed_at"].as_f64());
            if status != old_status {
                if status == "in_progress" && started.is_none() {
                    started = Some(t);
                }
                completed = if status == "done" { Some(completed.unwrap_or(t)) } else { None };
            }
            tx.execute("UPDATE task SET status=?, position=?, started_at=?, completed_at=?, updated_at=? WHERE id=?",
                       rusqlite::params![status, pos, started, completed, t, id])?;
            if status != old_status {
                let p = Self::one(tx, "project", &pid, "project tidak ditemukan")?;
                let code = format!("{}-{}", p["key"].as_str().filter(|k| !k.is_empty()).unwrap_or("T"), old["number"]);
                let title_of = |k: &str| STATUSES.iter().find(|(x, _)| *x == k).map(|x| x.1).unwrap_or("?");
                let meta = json!({"task": id, "from": old_status, "to": status});
                if status == "done" {
                    Self::event(tx, Some(&pid), "task.completed", &format!("{code} selesai: {}", old["title"].as_str().unwrap_or("")), meta)?;
                } else {
                    Self::event(tx, Some(&pid), "task.status", &format!("{code}: {} → {}", title_of(&old_status), title_of(status)), meta)?;
                }
            }
            Ok(())
        })
    }

    fn update(&self, table: &str, id: &str, fields: Vec<(&str, SqlValue)>, after: impl FnOnce(&rusqlite::Transaction, &Map<String, Value>) -> R<()>) -> R<()> {
        if fields.is_empty() {
            return Ok(());
        }
        let missing = format!("{table} tidak ditemukan");
        self.tx(|tx| {
            let old = Self::one(tx, table, id, &missing)?;
            let cols = fields.iter().map(|(k, _)| format!("{k}=?")).collect::<Vec<_>>().join(", ");
            let mut args: Vec<SqlValue> = fields.into_iter().map(|(_, v)| v).collect();
            args.push(SqlValue::Real(now()));
            args.push(SqlValue::Text(id.into()));
            tx.execute(&format!("UPDATE {table} SET {cols}, updated_at=? WHERE id=?"), params_from_iter(args.iter()))?;
            after(tx, &old)
        })
    }

    // ── Replication ──
    pub fn tables(&self) -> R<Vec<String>> {
        let db = self.db.lock().unwrap();
        let mut st = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")?;
        let v = st.query_map([], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
        Ok(v)
    }

    pub fn dump(&self) -> R<Value> {
        let names = self.tables()?;
        let db = self.db.lock().unwrap();
        let mut out = Map::new();
        for t in names {
            out.insert(t.clone(), json!(Self::rows(&db, &format!("SELECT * FROM \"{t}\""), &[])?));
        }
        Ok(Value::Object(out))
    }

    /// Runs a client's committed write statements in one transaction. Only INSERT/UPDATE/DELETE
    /// (and the reads they need) on workspace tables pass — enforced by SQLite's authorizer.
    pub fn apply(&self, statements: &[Value]) -> R<usize> {
        if statements.len() > 5000 {
            return err("batch tidak valid");
        }
        let allowed = self.tables()?;
        let mut n = 0;
        {
            let mut db = self.db.lock().unwrap();
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            tx.execute_batch("PRAGMA defer_foreign_keys = ON")?;
            let allowed2 = allowed.clone();
            tx.authorizer(Some(move |ctx: AuthContext<'_>| match ctx.action {
                AuthAction::Insert { table_name } | AuthAction::Delete { table_name } | AuthAction::Update { table_name, .. } | AuthAction::Read { table_name, .. } => {
                    if allowed2.iter().any(|t| t == table_name) { Authorization::Allow } else { Authorization::Deny }
                }
                AuthAction::Select | AuthAction::Function { .. } => Authorization::Allow,
                _ => Authorization::Deny,
            }));
            let result: R<()> = (|| {
                for st in statements {
                    let sql = st.get("sql").and_then(|v| v.as_str()).ok_or_else(|| WsError("statement tidak valid".into()))?;
                    let args: Vec<SqlValue> = st.get("args").and_then(|v| v.as_array()).map(|a| a.iter().map(to_sql).collect()).unwrap_or_default();
                    // prepare() would silently run only the first statement: refuse anything after it.
                    if has_tail(sql) {
                        return err("ditolak: satu statement per entri");
                    }
                    let mut stmt = tx.prepare(sql).map_err(|e| WsError(format!("ditolak: {e}")))?;
                    stmt.execute(params_from_iter(args.iter())).map_err(|e| WsError(format!("ditolak: {e}")))?;
                    n += 1;
                }
                Ok(())
            })();
            tx.authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
            match result {
                Ok(()) => tx.commit().map_err(|e| WsError(format!("ditolak: {e}")))?,
                Err(e) => {
                    let _ = tx.rollback();
                    return Err(e);
                }
            }
        }
        if n > 0 {
            self.changed();
        }
        Ok(n)
    }

    pub fn integrity_ok(&self) -> bool {
        self.db.lock().unwrap().query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0)).map(|s| s == "ok").unwrap_or(false)
    }
}

/// True when `sql` has anything but whitespace/comments after its first `;` (outside quotes).
fn has_tail(sql: &str) -> bool {
    let c: Vec<char> = sql.chars().collect();
    let (mut i, mut quote, mut ended) = (0, None::<char>, false);
    while i < c.len() {
        let ch = c[i];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            }
        } else if ch == '-' && c.get(i + 1) == Some(&'-') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            i += 2;
            while i + 1 < c.len() && !(c[i] == '*' && c[i + 1] == '/') {
                i += 1;
            }
            i += 1;
        } else if ch == '\'' || ch == '"' || ch == '`' {
            if ended {
                return true;
            }
            quote = Some(ch);
        } else if ch == '[' && !ended {
            while i < c.len() && c[i] != ']' {
                i += 1;
            }
        } else if ch == ';' {
            ended = true;
        } else if ended && !ch.is_whitespace() {
            return true;
        }
        i += 1;
    }
    false
}

pub fn start_of_day(t: f64) -> f64 {
    use chrono::{Local, TimeZone};
    let d = Local.timestamp_opt(t as i64, 0).single().unwrap();
    d.date_naive().and_hms_opt(0, 0, 0).and_then(|n| Local.from_local_datetime(&n).earliest()).map(|x| x.timestamp() as f64).unwrap_or(t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn store() -> Workspace {
        let dir = std::env::temp_dir().join(format!("rw-{}", new_id()));
        Workspace::open(dir.join("w.sqlite").to_str().unwrap(), &[(1, include_str!("../../schema/schema_v1.sql"))]).unwrap()
    }
    fn snap(ws: &Workspace) -> Value {
        ws.snapshot().unwrap()
    }

    #[test]
    fn helpers_match_swift() {
        assert_eq!(position(&[], None), 1024.0);
        assert_eq!(position(&[1024.0, 2048.0], Some(1)), 1536.0);
        assert!(position(&[1024.0], Some(0)) < 1024.0);
        assert_eq!(make_key("raphael", &[]), "RAP");
        assert_eq!(make_key("Raphael Control Center", &[]), "RCC");
        assert_eq!(make_key("raphael", &["RAP".into()]), "RAP2");
    }

    #[test]
    fn crud_progress_and_moves() {
        let ws = store();
        let pf = ws.create_portfolio(&json!({"name": "Studio"})).unwrap();
        let pid = ws.create_project(&json!({"name": "Raphael Control Center", "portfolio_id": pf, "lifecycle": "building"})).unwrap();
        assert!(snap(&ws)["projects"][0]["progress"].is_null());
        let a = ws.create_task(&json!({"project_id": pid, "title": "A"})).unwrap();
        let _b = ws.create_task(&json!({"project_id": pid, "title": "B"})).unwrap();
        ws.move_task(&a, "done", None).unwrap();
        let s = snap(&ws);
        assert_eq!((s["projects"][0]["key"].as_str(), s["projects"][0]["next_number"].as_i64(), s["projects"][0]["progress"].as_f64()), (Some("RCC"), Some(3), Some(0.5)));
        assert!(s["activity"].as_array().unwrap().iter().any(|e| e["type"] == "task.completed" && e["title"].as_str().unwrap().contains("RCC-1 selesai")));
        ws.update_project(&pid, &json!({"lifecycle": "live"})).unwrap();
        assert!(snap(&ws)["activity"].as_array().unwrap().iter().any(|e| e["type"] == "project.lifecycle"));
        // ordering + gap exhaustion
        let ids: Vec<String> = (0..3).map(|i| ws.create_task(&json!({"project_id": pid, "title": i.to_string()})).unwrap()).collect();
        for i in &ids {
            ws.move_task(i, "ready", None).unwrap();
        }
        let col = |ws: &Workspace| -> Vec<String> {
            let s = snap(ws);
            let mut t: Vec<&Value> = s["tasks"].as_array().unwrap().iter().filter(|t| t["status"] == "ready").collect();
            t.sort_by(|a, b| a["position"].as_f64().partial_cmp(&b["position"].as_f64()).unwrap());
            t.iter().map(|t| t["title"].as_str().unwrap().to_string()).collect()
        };
        ws.move_task(&ids[2], "ready", Some(&ids[0])).unwrap();
        assert_eq!(col(&ws), ["2", "0", "1"]);
        for _ in 0..60 {
            ws.move_task(&ids[1], "ready", Some(&ids[0])).unwrap();
            ws.move_task(&ids[2], "ready", Some(&ids[1])).unwrap();
        }
        assert_eq!(col(&ws), ["2", "1", "0"]);
        ws.delete("project", &pid).unwrap();
        assert!(snap(&ws)["tasks"].as_array().unwrap().is_empty());
    }

    #[test]
    fn validation() {
        let ws = store();
        assert!(ws.create_project(&json!({"name": "  "})).is_err());
        assert!(ws.create_project(&json!({"name": "x", "lifecycle": "nope"})).is_err());
        let pid = ws.create_project(&json!({"name": "x"})).unwrap();
        assert!(ws.create_task(&json!({"project_id": pid, "title": "t", "status": "nope"})).is_err());
        assert!(ws.create_task(&json!({"project_id": "missing", "title": "t"})).is_err());
        ws.create_project(&json!({"name": "z", "key": "QQ"})).unwrap();
        assert!(ws.create_project(&json!({"name": "y", "key": "QQ"})).is_err());
        assert!(!has_tail("INSERT INTO t VALUES ('a;b'); -- komentar"));
        assert!(has_tail("UPDATE t SET a=1; DROP TABLE t"));
        assert!(has_tail("UPDATE t SET a=1;/**/DELETE FROM t"));
    }

    #[test]
    fn replication_is_sandboxed() {
        let ws = store();
        let bumps = Arc::new(AtomicUsize::new(0));
        let b2 = bumps.clone();
        *ws.on_change.lock().unwrap() = Some(Arc::new(move || {
            b2.fetch_add(1, Ordering::SeqCst);
        }));
        let t = now();
        let n = ws.apply(&[
            json!({"sql": "INSERT INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                   "args": ["pf1", "Dari Mac; dengan titik koma", "", "violet", 0, 1, t, t]}),
            json!({"sql": "INSERT INTO project (id, portfolio_id, name, key, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["p1", "pf1", "Mac", "MAC", t, t]}),
            json!({"sql": "UPDATE project SET description=? WHERE id=?", "args": ["x", "p1"]}),
        ]).unwrap();
        assert_eq!((n, bumps.load(Ordering::SeqCst)), (3, 1));
        assert_eq!(ws.dump().unwrap()["project"][0]["description"], "x");
        for bad in ["PRAGMA foreign_keys = OFF", "DROP TABLE task", "ATTACH DATABASE '/tmp/x.db' AS x", "CREATE TABLE evil (a)",
                    "DELETE FROM sqlite_master", "UPDATE project SET name='a' WHERE id='p1'; DROP TABLE task", "COMMIT"] {
            assert!(ws.apply(&[json!({"sql": bad, "args": []})]).is_err(), "{bad}");
        }
        assert!(ws.apply(&[json!({"sql": "UPDATE project SET name=? WHERE id=?", "args": ["ganti", "p1"]}), json!({"sql": "INSERT INTO nope VALUES (1)", "args": []})]).is_err());
        assert_eq!(ws.dump().unwrap()["project"][0]["name"], "Mac");
        assert!(ws.tables().unwrap().contains(&"task".to_string()));
        ws.apply(&[json!({"sql": "INSERT INTO task (id, number, project_id, parent_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?,?)", "args": ["t2", 2, "p1", "t1", "anak", t, t]}),
                   json!({"sql": "INSERT INTO task (id, number, project_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["t1", 1, "p1", "induk", t, t]})]).unwrap();
        assert!(ws.apply(&[json!({"sql": "INSERT INTO task (id, number, project_id, title, created_at, updated_at) VALUES (?,?,?,?,?,?)", "args": ["t3", 3, "missing", "x", t, t]})]).is_err());
    }
}
