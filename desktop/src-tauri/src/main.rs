//! Raphael Control Center desktop (Windows, Linux, macOS).
//!
//! Two modes:
//! - **server**: the window shows a Raphael Web server (e.g. the one on your Raspberry Pi) —
//!   same data and workspace as every other device.
//! - **local**: the app starts the Raphael Web server inside itself (127.0.0.1, random port),
//!   monitoring this machine (in-process collector) plus any SSH devices in its config.
//!
//! A tray icon keeps it running in the background and shows desktop notifications for new
//! incidents. Only the bundled settings window can call the app's commands; the Raphael Web
//! pages (local or remote) get no IPC.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_notification::NotificationExt;

#[derive(Serialize, Deserialize, Clone)]
struct Settings {
    /// "server" or "local"; empty = not set up yet.
    mode: String,
    #[serde(rename = "serverUrl")]
    server_url: String,
    #[serde(default = "yes")]
    notifications: bool,
}
fn yes() -> bool {
    true
}
impl Default for Settings {
    fn default() -> Self {
        Settings { mode: String::new(), server_url: String::new(), notifications: true }
    }
}

struct State {
    settings: Mutex<Settings>,
    /// The URL the main window shows (remote server or the local one).
    base: Mutex<String>,
    local_port: Mutex<Option<u16>>,
}

fn settings_path(app: &AppHandle) -> PathBuf {
    app.path().app_config_dir().unwrap_or_else(|_| PathBuf::from(".")).join("settings.json")
}

fn data_dir(app: &AppHandle) -> PathBuf {
    app.path().app_data_dir().unwrap_or_else(|_| PathBuf::from(".")).join("raphael-web")
}

fn load_settings(app: &AppHandle) -> Settings {
    std::fs::read_to_string(settings_path(app)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn save_settings_file(app: &AppHandle, s: &Settings) -> Result<(), String> {
    let p = settings_path(app);
    std::fs::create_dir_all(p.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(p, serde_json::to_string_pretty(s).unwrap()).map_err(|e| e.to_string())
}

/// The local server's config: created on first use (this machine only); devices reachable over
/// SSH, websites and the rest can be added to it by hand.
fn local_config(app: &AppHandle) -> Value {
    let dir = data_dir(app);
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("config.json");
    if !path.exists() {
        let host = hostname();
        let cfg = json!({
            "nodes": [{"id": "this", "name": host, "native": true, "local": true}],
            "sites": [], "envFiles": ["~/.hermes/.env"],
            "actions": {"services": [], "containers": false, "jobs": false}
        });
        let _ = std::fs::write(&path, serde_json::to_string_pretty(&cfg).unwrap());
    }
    let mut cfg = raphael_web::server::load_config(path.to_str().unwrap());
    cfg["port"] = json!(0);
    cfg["data"] = json!(dir.to_string_lossy());
    cfg
}

fn hostname() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).ok()
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string()))
        .or_else(|| std::process::Command::new("hostname").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()))
        .map(|s| s.trim_end_matches(".local").to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Komputer ini".into())
}

fn ensure_local_server(app: &AppHandle) -> Result<u16, String> {
    let st = app.state::<State>();
    if let Some(p) = *st.local_port.lock().unwrap() {
        return Ok(p);
    }
    let h = raphael_web::server::start(local_config(app), raphael_web::server::Static::Embedded, true)?;
    *st.local_port.lock().unwrap() = Some(h.port);
    std::mem::forget(h); // runs for the life of the app
    let port = st.local_port.lock().unwrap().unwrap();
    Ok(port)
}

fn resolve_base(app: &AppHandle) -> Result<String, String> {
    let s = app.state::<State>().settings.lock().unwrap().clone();
    match s.mode.as_str() {
        "server" if !s.server_url.trim().is_empty() => Ok(s.server_url.trim().trim_end_matches('/').to_string()),
        "local" => ensure_local_server(app).map(|p| format!("http://127.0.0.1:{p}")),
        _ => Err("belum diatur".into()),
    }
}

fn show_main(app: &AppHandle) {
    let base = match resolve_base(app) {
        Ok(b) => b,
        Err(_) => return show_settings(app),
    };
    *app.state::<State>().base.lock().unwrap() = base.clone();
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        return;
    }
    let Ok(url) = base.parse() else { return show_settings(app) };
    let w = WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
        .title("Raphael Control Center")
        .inner_size(1240.0, 820.0)
        .min_inner_size(380.0, 520.0)
        .build();
    if let Ok(w) = w {
        let w2 = w.clone();
        w.on_window_event(move |e| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = e {
                api.prevent_close(); // keep running in the tray
                let _ = w2.hide();
            }
        });
    }
}

fn show_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("Pengaturan · Raphael")
        .inner_size(560.0, 620.0)
        .resizable(true)
        .build();
}

// ── Commands (settings window only) ──
#[tauri::command]
fn get_settings(app: AppHandle) -> Value {
    let s = app.state::<State>().settings.lock().unwrap().clone();
    json!({"mode": s.mode, "serverUrl": s.server_url, "notifications": s.notifications,
           "localConfig": data_dir(&app).join("config.json").to_string_lossy(), "version": env!("CARGO_PKG_VERSION"),
           "autostart": tauri_plugin_autostart::ManagerExt::autolaunch(&app).is_enabled().unwrap_or(false)})
}

#[tauri::command]
fn test_server(url: String) -> Result<Value, String> {
    let u = format!("{}/healthz", url.trim().trim_end_matches('/'));
    ureq::get(&u).timeout(std::time::Duration::from_secs(8)).call().map_err(|e| e.to_string())?.into_json::<Value>().map_err(|e| e.to_string())
}

#[tauri::command]
fn save_settings(app: AppHandle, mode: String, server_url: String, notifications: bool, autostart: bool) -> Result<(), String> {
    if mode == "server" {
        test_server(server_url.clone()).map_err(|e| format!("Server tidak menjawab: {e}"))?;
    }
    let s = Settings { mode, server_url, notifications };
    save_settings_file(&app, &s)?;
    *app.state::<State>().settings.lock().unwrap() = s;
    let al = tauri_plugin_autostart::ManagerExt::autolaunch(&app);
    let _ = if autostart { al.enable() } else { al.disable() };
    // Reopen the main window on the new target.
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.destroy();
    }
    show_main(&app);
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.close();
    }
    Ok(())
}

// ── Notifications: new incidents from whichever server the window shows ──
fn watch_incidents(app: AppHandle) {
    std::thread::spawn(move || {
        let mut seen: Option<HashSet<String>> = None;
        loop {
            std::thread::sleep(std::time::Duration::from_secs(60));
            let st = app.state::<State>();
            if !st.settings.lock().unwrap().notifications {
                continue;
            }
            let base = st.base.lock().unwrap().clone();
            if base.is_empty() {
                continue;
            }
            let Ok(r) = ureq::get(&format!("{base}/api/state")).timeout(std::time::Duration::from_secs(15)).call() else { continue };
            let Ok(state) = r.into_json::<Value>() else { continue };
            let open: Vec<Value> = state.get("openIncidents").and_then(|o| o.as_array()).cloned().unwrap_or_default();
            let keys: HashSet<String> = open.iter().filter_map(|i| i.get("key").and_then(|k| k.as_str()).map(String::from)).collect();
            if let Some(prev) = &seen {
                for i in &open {
                    let key = i.get("key").and_then(|k| k.as_str()).unwrap_or("");
                    let quiet = i.get("quiet").and_then(|q| q.as_bool()).unwrap_or(false);
                    if !prev.contains(key) && !quiet {
                        let _ = app.notification().builder().title(i.get("title").and_then(|t| t.as_str()).unwrap_or("Raphael"))
                            .body(i.get("detail").and_then(|t| t.as_str()).unwrap_or("")).show();
                    }
                }
            }
            seen = Some(keys);
        }
    });
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show_main(app)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .invoke_handler(tauri::generate_handler![get_settings, save_settings, test_server])
        .setup(|app| {
            let handle = app.handle().clone();
            let settings = load_settings(&handle);
            app.manage(State { settings: Mutex::new(settings), base: Mutex::new(String::new()), local_port: Mutex::new(None) });
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory); // menu-bar app, like before

            let open = MenuItem::with_id(app, "open", "Buka Raphael", true, None::<&str>)?;
            let settings_item = MenuItem::with_id(app, "settings", "Pengaturan…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Keluar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &settings_item, &PredefinedMenuItem::separator(app)?, &quit])?;
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().cloned().unwrap())
                .icon_as_template(false)
                .tooltip("Raphael Control Center")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "open" => show_main(app),
                    "settings" => show_settings(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        show_main(tray.app_handle());
                    }
                })
                .build(app)?;
            show_main(&handle);
            watch_incidents(handle);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Raphael Control Center")
        .run(|app, e| match e {
            tauri::RunEvent::ExitRequested { api, code, .. } => {
                if code.is_none() {
                    api.prevent_exit(); // last window closed: stay in the tray
                }
            }
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Reopen { .. } => show_main(app),
            _ => {
                let _ = app;
            }
        });
}
