//! Raphael Web server binary (127.0.0.1 only; publish it with `tailscale serve`).
//!
//!   raphael-web [--config ~/.config/raphael-web/config.json] [--static DIR] [--no-sampling]

use raphael_web::server::{self, Static};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let cfg = server::load_config(&arg("--config").unwrap_or_else(|| "~/.config/raphael-web/config.json".into()));
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.to_path_buf())).unwrap_or_default();
    let statics = match arg("--static") {
        Some(d) => Static::Dir(d.into()),
        None => [exe_dir.join("static"), exe_dir.join("../static"), exe_dir.join("../../../static")]
            .into_iter().find(|p| p.join("index.html").exists()).map(Static::Dir).unwrap_or(Static::Embedded),
    };
    match server::start(cfg, statics, !args.iter().any(|a| a == "--no-sampling")) {
        Ok(_) => loop {
            std::thread::park();
        },
        Err(e) => {
            eprintln!("raphael-web: {e}");
            std::process::exit(1);
        }
    }
}
