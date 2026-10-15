//! Knowledge (port of the Mac app's KnowledgeStore for the server's own Hermes): agents and
//! profiles with their SOUL and memory files, the names in each .env (never the values), and
//! graphify graphs. Only files found by discovery can be read or written; writes keep a
//! `.raphael.bak` copy and the file's permissions, and refuse to overwrite a newer version.

use crate::monitor::{expand, parse_env};
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

const MAX_TEXT: usize = 1024 * 1024;

fn files(dir: &Path, f: impl Fn(&str) -> bool) -> Vec<Value> {
    let mut out: Vec<Value> = std::fs::read_dir(dir).into_iter().flatten().flatten().filter_map(|e| {
        let name = e.file_name().to_string_lossy().to_string();
        let meta = e.metadata().ok()?;
        (meta.is_file() && f(&name)).then(|| json!({"path": e.path().to_string_lossy(), "name": name, "size": meta.len()}))
    }).collect();
    out.sort_by(|a, b| b["name"].as_str().cmp(&a["name"].as_str()));
    out
}

/// Agents and graphs under the Hermes home (`hermesHome`, default ~/.hermes).
pub fn discover(home_cfg: &str) -> Value {
    let home = expand(home_cfg);
    let mut dirs = vec![home.clone()];
    let mut profiles: Vec<String> = std::fs::read_dir(format!("{home}/profiles")).into_iter().flatten().flatten()
        .filter(|e| e.path().is_dir() && !e.file_name().to_string_lossy().starts_with('.')).map(|e| e.path().to_string_lossy().to_string()).collect();
    profiles.sort();
    dirs.extend(profiles);
    let agents: Vec<Value> = dirs.iter().filter(|d| Path::new(d).is_dir()).map(|d| {
        let default = *d == home;
        let id = if default { "default".to_string() } else { Path::new(d).file_name().unwrap_or_default().to_string_lossy().to_string() };
        let mut name = id.clone();
        if let Some(c) = name.get_mut(0..1) { c.make_ascii_uppercase(); }
        let soul = files(Path::new(d), |n| n.starts_with("SOUL") && n.ends_with(".md"));
        let mut memory = files(&Path::new(d).join("memories"), |n| n.ends_with(".md"));
        memory.extend(files(&Path::new(d).join("agent-memory"), |n| n.ends_with(".md")));
        let mut env: Vec<String> = std::fs::read_to_string(format!("{d}/.env")).map(|t| parse_env(&t).into_keys().collect()).unwrap_or_default();
        env.sort();
        json!({"id": id, "name": if default { "Raphael".to_string() } else { name }, "home": if default { "~/.hermes".to_string() } else { format!("profiles/{id}") },
               "soul": soul, "memory": memory, "env": env, "envPath": format!("{d}/.env")})
    }).collect();
    let user_home = expand("~");
    let mut candidates = vec![format!("{home}/agent-memory/graphify-out/graph.json"), format!("{user_home}/.graphify/global-graph.json")];
    for pattern in [format!("{user_home}/Projects/*/graphify-out/graph.json"), format!("{user_home}/*/graphify-out/graph.json")] {
        candidates.extend(glob::glob(&pattern).into_iter().flatten().flatten().map(|p| p.to_string_lossy().to_string()));
    }
    let mut graphs = vec![];
    for path in candidates {
        if graphs.iter().any(|g: &Value| g["path"] == path) { continue; }
        let Ok(meta) = std::fs::metadata(&path) else { continue };
        let p = Path::new(&path);
        let root = p.parent().and_then(|x| x.parent());
        let name = if path.ends_with("global-graph.json") { "Global graph".to_string() }
            else if root.map(|r| r.ends_with("agent-memory")).unwrap_or(false) { "Agent memory".to_string() }
            else { root.and_then(|r| r.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_default() };
        let (nodes, links) = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .map(|g| (g["nodes"].as_array().map(|a| a.len()).unwrap_or(0), g["links"].as_array().or(g["edges"].as_array()).map(|a| a.len()).unwrap_or(0)))
            .unwrap_or((0, 0));
        let mtime = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64());
        graphs.push(json!({"path": path, "name": name, "nodes": nodes, "links": links, "mtime": mtime}));
    }
    json!({"agents": agents, "graphs": graphs})
}

fn allowed(home_cfg: &str, path: &str, kinds: &[&str]) -> bool {
    let d = discover(home_cfg);
    d["agents"].as_array().into_iter().flatten().any(|a| kinds.iter().any(|k| a[*k].as_array().into_iter().flatten().any(|f| f["path"] == path)))
}

pub fn read(home_cfg: &str, path: &str) -> Result<Value, String> {
    if !allowed(home_cfg, path, &["soul", "memory"]) {
        return Err("file ini tidak termasuk SOUL atau memory agent".into());
    }
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mtime = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64());
    Ok(json!({"path": path, "text": text, "size": meta.len(), "mtime": mtime}))
}

pub fn write(home_cfg: &str, path: &str, text: &str, base_mtime: Option<f64>) -> Result<Value, (u16, String)> {
    if !allowed(home_cfg, path, &["soul", "memory"]) {
        return Err((400, "file ini tidak termasuk SOUL atau memory agent".into()));
    }
    if text.len() > MAX_TEXT {
        return Err((400, "teks terlalu besar (maks 1 MB)".into()));
    }
    let meta = std::fs::metadata(path).map_err(|e| (400, e.to_string()))?;
    let now_mtime = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    if let Some(b) = base_mtime {
        if (now_mtime - b).abs() > 0.001 {
            return Err((409, "file sudah diubah di tempat lain; muat ulang dulu".into()));
        }
    }
    let mode = meta.permissions().mode();
    std::fs::copy(path, format!("{path}.raphael.bak")).map_err(|e| (500, e.to_string()))?;
    let tmp = format!("{path}.raphael.tmp");
    std::fs::write(&tmp, text).map_err(|e| (500, e.to_string()))?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode)).map_err(|e| (500, e.to_string()))?;
    std::fs::rename(&tmp, path).map_err(|e| (500, e.to_string()))?;
    read(home_cfg, path).map_err(|e| (500, e))
}

/// A graph's nodes and links for the viewer (largest graphs capped).
pub fn graph(home_cfg: &str, path: &str) -> Result<Value, String> {
    let d = discover(home_cfg);
    if !d["graphs"].as_array().into_iter().flatten().any(|g| g["path"] == path) {
        return Err("graph tidak dikenal".into());
    }
    let g: Value = serde_json::from_str(&std::fs::read_to_string(path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let nodes: Vec<Value> = g["nodes"].as_array().cloned().unwrap_or_default().into_iter().take(3000).map(|n| json!({
        "id": n["id"], "label": n.get("label").or(n.get("norm_label")).cloned().unwrap_or(n["id"].clone()),
        "community": n.get("community"), "group": n.get("community_name"), "kind": n.get("file_type").or(n.get("node_kind")), "file": n.get("source_file")})).collect();
    let ids: std::collections::HashSet<String> = nodes.iter().map(|n| n["id"].to_string()).collect();
    let links: Vec<Value> = g["links"].as_array().or(g["edges"].as_array()).cloned().unwrap_or_default().into_iter()
        .filter(|l| ids.contains(&l["source"].to_string()) && ids.contains(&l["target"].to_string()))
        .take(12000).map(|l| json!({"source": l["source"], "target": l["target"], "relation": l.get("relation")})).collect();
    Ok(json!({"path": path, "nodes": nodes, "links": links, "total": g["nodes"].as_array().map(|a| a.len()).unwrap_or(0)}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_read_write_and_guards() {
        let d = std::env::temp_dir().join(format!("raphael-kn-{}", std::process::id()));
        let home = d.join(".hermes");
        std::fs::create_dir_all(home.join("memories")).unwrap();
        std::fs::create_dir_all(home.join("profiles/track/memories")).unwrap();
        std::fs::write(home.join("SOUL.md"), "soul").unwrap();
        std::fs::write(home.join("memories/MEMORY.md"), "mem").unwrap();
        std::fs::write(home.join("profiles/track/SOUL.md"), "t").unwrap();
        std::fs::write(home.join(".env"), "SECRET_TOKEN=hunter2\nOTHER=1\n").unwrap();
        std::fs::set_permissions(home.join("SOUL.md"), std::fs::Permissions::from_mode(0o600)).unwrap();
        let h = home.to_string_lossy().to_string();
        let k = discover(&h);
        assert_eq!(k["agents"][0]["name"], "Raphael");
        assert_eq!(k["agents"][1]["name"], "Track");
        assert_eq!(k["agents"][0]["env"], json!(["OTHER", "SECRET_TOKEN"]));
        assert!(!k.to_string().contains("hunter2"), "env values never leave the server");
        let soul = home.join("SOUL.md").to_string_lossy().to_string();
        let r = read(&h, &soul).unwrap();
        assert_eq!(r["text"], "soul");
        assert!(read(&h, &home.join(".env").to_string_lossy()).is_err());
        assert!(write(&h, "/etc/passwd", "x", None).is_err());
        assert_eq!(write(&h, &soul, "new", Some(1.0)).unwrap_err().0, 409);
        let w = write(&h, &soul, "new", r["mtime"].as_f64()).unwrap();
        assert_eq!(w["text"], "new");
        assert_eq!(std::fs::read_to_string(format!("{soul}.raphael.bak")).unwrap(), "soul");
        assert_eq!(std::fs::metadata(&soul).unwrap().permissions().mode() & 0o777, 0o600);
        std::fs::remove_dir_all(&d).ok();
    }
}
