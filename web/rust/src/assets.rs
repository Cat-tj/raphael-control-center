//! The web UI compiled into the binary (used by the desktop app; the server deploy serves the
//! same files from disk).

macro_rules! assets {
    ($($name:literal),* $(,)?) => {
        pub fn get(name: &str) -> Option<&'static [u8]> {
            match name {
                $($name => Some(include_bytes!(concat!("../../static/", $name)).as_slice()),)*
                _ => None,
            }
        }
        const ALL: &[&[u8]] = &[$(include_bytes!(concat!("../../static/", $name)).as_slice()),*];
    };
}

assets!("index.html", "app.js", "app.css", "icon.svg", "icon-180.png", "icon-192.png", "icon-512.png", "manifest.webmanifest", "sw.js");

const fn fnv(seed: u64, bytes: &[u8]) -> u64 {
    let mut h = seed;
    let mut i = 0;
    while i < bytes.len() {
        h ^= bytes[i] as u64;
        h = h.wrapping_mul(0x100000001b3);
        i += 1;
    }
    h
}

const fn build_id() -> u64 {
    let mut h = 0xcbf29ce484222325;
    let mut i = 0;
    while i < ALL.len() {
        h = fnv(h, ALL[i]);
        i += 1;
    }
    h % 1_000_000_000
}

/// Changes whenever any embedded file changes (cache-busting for app.js / app.css).
pub const BUILD_ID: u64 = build_id();

#[cfg(test)]
mod tests {
    #[test]
    fn embedded() {
        assert!(super::get("index.html").unwrap().starts_with(b"<!doctype html>"));
        assert!(super::get("app.js").is_some() && super::get("nope.js").is_none());
        assert!(super::BUILD_ID > 0);
    }
}
