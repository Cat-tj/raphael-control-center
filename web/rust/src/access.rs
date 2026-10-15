//! Cloudflare Access in front of the public hostname. A request that came through Cloudflare
//! (it carries `Cf-Ray`) must also carry a valid Access token: an RS256 JWT signed by one of the
//! team's keys, for this application's AUD tag, not expired. Cloudflare checks this at its edge;
//! checking it here too means a misconfigured or deleted Access application can't open the server.
//! Tailnet requests (tailscale serve) are unchanged.

use crate::core::now;
use serde_json::Value;
use std::sync::Mutex;
use std::time::Duration;

pub struct Access {
    team: String,
    aud: String,
    keys: Mutex<(f64, Vec<(String, Vec<u8>, Vec<u8>)>)>,
}

/// Request headers that only Cloudflare's edge adds (tailscale serve never does).
pub fn via_cloudflare(header: &dyn Fn(&str) -> Option<String>) -> bool {
    header("Cf-Ray").is_some() || header("Cf-Connecting-Ip").is_some()
}

pub fn b64url(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => continue,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

impl Access {
    /// `access: {"team": "<team>.cloudflareaccess.com", "aud": "<application AUD tag>"}` in the config.
    pub fn from_config(cfg: &Value) -> Option<Access> {
        let a = cfg.get("access")?;
        let team = a.get("team")?.as_str()?.trim_start_matches("https://").trim_end_matches('/').to_string();
        let aud = a.get("aud")?.as_str()?.to_string();
        (!team.is_empty() && !aud.is_empty()).then(|| Access { team, aud, keys: Mutex::new((0.0, vec![])) })
    }

    fn keys(&self, force: bool) -> Vec<(String, Vec<u8>, Vec<u8>)> {
        let mut k = self.keys.lock().unwrap();
        let age = now() - k.0;
        if k.1.is_empty() || age > 3600.0 || (force && age > 60.0) {
            let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(10)).user_agent(crate::net::UA).build();
            if let Ok(j) = agent.get(&format!("https://{}/cdn-cgi/access/certs", self.team)).call().and_then(|r| r.into_json::<Value>().map_err(|e| e.into())) {
                let list: Vec<(String, Vec<u8>, Vec<u8>)> = j.get("keys").and_then(|v| v.as_array()).cloned().unwrap_or_default().iter().filter_map(|key| {
                    Some((key.get("kid")?.as_str()?.to_string(), b64url(key.get("n")?.as_str()?)?, b64url(key.get("e")?.as_str()?)?))
                }).collect();
                if !list.is_empty() {
                    *k = (now(), list);
                }
            }
        }
        k.1.clone()
    }

    /// The signed-in email, or why the token is refused.
    pub fn check(&self, token: Option<String>) -> Result<String, String> {
        let token = token.ok_or("belum login lewat Cloudflare Access")?;
        let parts: Vec<&str> = token.split('.').collect();
        if parts.len() != 3 {
            return Err("token Access tidak valid".into());
        }
        let header: Value = serde_json::from_slice(&b64url(parts[0]).ok_or("token Access tidak valid")?).map_err(|_| "token Access tidak valid")?;
        if header.get("alg").and_then(|a| a.as_str()) != Some("RS256") {
            return Err("algoritma token Access tidak didukung".into());
        }
        let kid = header.get("kid").and_then(|k| k.as_str()).unwrap_or("").to_string();
        let sig = b64url(parts[2]).ok_or("token Access tidak valid")?;
        let msg = format!("{}.{}", parts[0], parts[1]);
        let mut keys = self.keys(false);
        if !keys.iter().any(|(k, _, _)| *k == kid) {
            keys = self.keys(true);
        }
        let (_, n, e) = keys.iter().find(|(k, _, _)| *k == kid).ok_or("kunci token Access tidak dikenal")?;
        ring::signature::RsaPublicKeyComponents { n, e }
            .verify(&ring::signature::RSA_PKCS1_2048_8192_SHA256, msg.as_bytes(), &sig)
            .map_err(|_| "tanda tangan token Access salah")?;
        let claims: Value = serde_json::from_slice(&b64url(parts[1]).ok_or("token Access tidak valid")?).map_err(|_| "token Access tidak valid")?;
        let aud_ok = match claims.get("aud") {
            Some(Value::Array(a)) => a.iter().any(|x| x.as_str() == Some(&self.aud)),
            Some(Value::String(s)) => *s == self.aud,
            _ => false,
        };
        if !aud_ok {
            return Err("token Access untuk aplikasi lain".into());
        }
        if claims.get("exp").and_then(|x| x.as_f64()).unwrap_or(0.0) < now() {
            return Err("sesi Access kedaluwarsa".into());
        }
        if claims.get("iss").and_then(|x| x.as_str()) != Some(&format!("https://{}", self.team)) {
            return Err("penerbit token Access salah".into());
        }
        Ok(claims.get("email").and_then(|x| x.as_str()).unwrap_or("").to_string())
    }
}

/// The Access token from the header Cloudflare adds, or the CF_Authorization cookie.
pub fn token(header: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    header("Cf-Access-Jwt-Assertion").or_else(|| {
        header("Cookie")?.split(';').map(|c| c.trim()).find_map(|c| c.strip_prefix("CF_Authorization=").map(String::from))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn base64url_and_token_sources() {
        assert_eq!(b64url("aGVsbG8").unwrap(), b"hello");
        assert_eq!(b64url("_-8").unwrap(), vec![0xff, 0xef]);
        assert!(b64url("a b").is_none());
        let h = |n: &str| match n { "Cookie" => Some("x=1; CF_Authorization=abc.def.ghi".to_string()), _ => None };
        assert_eq!(token(&h).as_deref(), Some("abc.def.ghi"));
        let cf = |n: &str| (n == "Cf-Ray").then(|| "1".to_string());
        assert!(via_cloudflare(&cf));
        assert!(!via_cloudflare(&|_: &str| None));
    }

    #[test]
    fn refuses_without_or_with_bad_tokens() {
        let a = Access::from_config(&json!({"access": {"team": "example.cloudflareaccess.com", "aud": "aud1"}})).unwrap();
        assert!(a.check(None).is_err());
        assert!(a.check(Some("not-a-jwt".into())).is_err());
        let hs = "eyJhbGciOiJIUzI1NiJ9.e30.c2ln";       // {"alg":"HS256"}: never accepted
        assert_eq!(a.check(Some(hs.into())).unwrap_err(), "algoritma token Access tidak didukung");
        assert!(Access::from_config(&json!({})).is_none());
    }
}
