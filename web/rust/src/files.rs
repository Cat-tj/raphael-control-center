//! Read-only file browser (port of files.py). The listing/reading script runs on the device as
//! the service user; names that usually hold secrets are refused, also through symlinks.

use crate::util;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::OnceLock;

pub const SCRIPT: &str = include_str!("../../remote/files.py");
const MAX_BYTES: usize = 512 * 1024;

fn secret_re() -> &'static (Regex, Regex) {
    static R: OnceLock<(Regex, Regex)> = OnceLock::new();
    R.get_or_init(|| {
        (
            Regex::new(r"(?ix)(^|/)(\.env(\..*)?|.*\.env|\.netrc|\.pgpass|\.npmrc|\.pypirc|\.git-credentials|credentials(\.json)?|
                auth\.json|secrets?(\.\w+)?|.*\.(pem|key|p12|pfx|keystore|jks|kdbx|gpg|asc)|id_(rsa|dsa|ecdsa|ed25519)[^/]*|
                authorized_keys|known_hosts|shadow|gshadow|.*token.*|.*passw(or)?d.*|db\.env)$").unwrap(),
            Regex::new(r"(^|/)(\.ssh|\.gnupg|\.password-store|\.aws|\.docker|\.kube|\.config/gh)(/|$)").unwrap(),
        )
    })
}

pub fn is_secret(path: &str) -> bool {
    let (a, b) = secret_re();
    a.is_match(path.trim_end_matches('/')) || b.is_match(path)
}

pub fn run(node: &Value, op: &str, path: &str) -> Value {
    if is_secret(path) {
        return json!({"path": path, "error": "disembunyikan: file ini biasanya berisi rahasia"});
    }
    let req = json!({"op": op, "path": path, "max": MAX_BYTES}).to_string() + "\n";
    let (out, _) = if node.get("local").and_then(|v| v.as_bool()).unwrap_or(false) {
        util::run(&["python3", "-c", SCRIPT], Some(&req), 25)
    } else {
        let cmd = format!("python3 -c {}", crate::ops::shell_quote(SCRIPT));
        util::run(&["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", node.get("ssh").and_then(|v| v.as_str()).unwrap_or(""), &cmd], Some(&req), 25)
    };
    let Some(mut res) = util::last_json_line(&out) else {
        let tail: String = out.trim().chars().rev().take(200).collect::<Vec<_>>().into_iter().rev().collect();
        return json!({"path": path, "error": if tail.is_empty() { "tidak ada jawaban".to_string() } else { tail }});
    };
    let real = res.get("real").and_then(|r| r.as_str()).unwrap_or("").to_string();
    if op == "list" {
        if is_secret(&format!("{real}/")) {
            return json!({"path": path, "error": "disembunyikan: folder ini biasanya berisi rahasia"});
        }
        let base = res.get("path").and_then(|p| p.as_str()).unwrap_or("").trim_end_matches('/').to_string();
        let items: Vec<Value> = res.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default().iter().filter_map(|it| it.as_array()).map(|a| {
            let name = a[0].as_str().unwrap_or("");
            let dir = a[1].as_bool().unwrap_or(false);
            json!({"name": name, "dir": dir, "size": a[2], "mtime": a[3], "link": a[4], "secret": is_secret(&format!("{base}/{name}")) && !dir})
        }).collect();
        res["items"] = json!(items);
    } else if is_secret(res.get("path").and_then(|p| p.as_str()).unwrap_or("")) || is_secret(&real) {
        return json!({"path": path, "error": "disembunyikan: file ini biasanya berisi rahasia"});
    }
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_names() {
        for p in ["~/.hermes/.env", "/etc/app/db.env", "/home/u/.ssh/config", "/srv/x/server.key", "cert.pem", "api_token.txt", "/home/u/.git-credentials", "/home/u/.ssh/", "id_ed25519.pub"] {
            assert!(is_secret(p), "{p}");
        }
        for p in ["/etc/caddy/Caddyfile", "/var/log/syslog", "~/notes.md", "/etc/nginx/nginx.conf"] {
            assert!(!is_secret(p), "{p}");
        }
    }

    #[test]
    fn list_read_and_symlink_guard() {
        let d = std::env::temp_dir().join(format!("rwf-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("a.txt"), "halo").unwrap();
        std::fs::write(d.join(".env"), "SECRET=1").unwrap();
        std::os::unix::fs::symlink(d.join(".env"), d.join("innocent.txt")).unwrap();
        let node = json!({"local": true});
        let ds = d.to_str().unwrap();
        let l = run(&node, "list", ds);
        let items = l["items"].as_array().unwrap();
        assert!(items.iter().any(|i| i["name"] == ".env" && i["secret"] == true));
        assert!(items.iter().any(|i| i["name"] == "a.txt" && i["secret"] == false));
        assert_eq!(run(&node, "read", &format!("{ds}/a.txt"))["text"], "halo");
        assert!(run(&node, "read", &format!("{ds}/.env"))["error"].as_str().unwrap().contains("rahasia"));
        assert!(run(&node, "read", &format!("{ds}/innocent.txt"))["error"].as_str().unwrap().contains("rahasia"));
        assert!(run(&node, "read", &format!("{ds}/missing")).get("error").is_some());
    }
}
