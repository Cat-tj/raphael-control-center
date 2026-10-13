//! In-process collector for the machine the app runs on (Windows, macOS, Linux), producing the
//! same JSON fields as the shell collector, so parsing, alerts and the UI need nothing special.
//! Used for nodes with `"native": true` (the desktop app's own machine).

use serde_json::{json, Value};
use std::sync::Mutex;
use sysinfo::{Components, Disks, Networks, ProcessesToUpdate, System};

static SYS: Mutex<Option<System>> = Mutex::new(None);

pub fn collect(slow: bool) -> Value {
    let mut guard = SYS.lock().unwrap();
    let sys = guard.get_or_insert_with(System::new_all);
    sys.refresh_cpu_usage();
    std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL.max(std::time::Duration::from_millis(400)));
    sys.refresh_cpu_usage();
    sys.refresh_memory();
    sys.refresh_processes(ProcessesToUpdate::All, true);

    let total = sys.total_memory() as f64;
    let swap_total = sys.total_swap() as f64;
    let disks = Disks::new_with_refreshed_list();
    let mut disk_rows: Vec<Value> = disks
        .list()
        .iter()
        .filter(|d| d.total_space() > 1 << 30)
        .map(|d| {
            let t = d.total_space() as f64;
            let mount = d.mount_point().to_string_lossy().to_string();
            json!([if mount == "C:\\" { "/".to_string() } else { mount }, ((t - d.available_space() as f64) / t * 10000.0).round() / 10000.0, (t / 1e9 * 10.0).round() / 10.0])
        })
        .collect();
    // macOS: the data volume is what fills up; show it as "/".
    if let Some(i) = disk_rows.iter().position(|d| d[0] == "/System/Volumes/Data") {
        let mut d = disk_rows.remove(i);
        d[0] = json!("/");
        disk_rows.retain(|x| x[0] != "/");
        disk_rows.insert(0, d);
    }
    disk_rows.dedup_by(|a, b| a[0] == b[0]);

    let nets = Networks::new_with_refreshed_list();
    let (rx, tx) = nets.iter().filter(|(n, _)| !n.starts_with("lo")).fold((0u64, 0u64), |(r, t), (_, d)| (r + d.total_received(), t + d.total_transmitted()));

    let cores = sys.cpus().len().max(1);
    let mut procs: Vec<(u32, String, f32, f64)> = sys
        .processes()
        .iter()
        .map(|(pid, p)| (pid.as_u32(), p.name().to_string_lossy().to_string(), p.cpu_usage() / cores as f32, p.memory() as f64 / total.max(1.0) * 100.0))
        .collect();
    procs.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
    let top_cpu: Vec<Value> = procs.iter().take(6).map(|p| json!([p.0, p.1, (p.2 as f64 * 10.0).round() / 10.0, (p.3 * 10.0).round() / 10.0])).collect();
    procs.sort_by(|a, b| b.3.partial_cmp(&a.3).unwrap_or(std::cmp::Ordering::Equal));
    let top_mem: Vec<Value> = procs.iter().take(6).map(|p| json!([p.0, p.1, (p.2 as f64 * 10.0).round() / 10.0, (p.3 * 10.0).round() / 10.0])).collect();

    let temp = Components::new_with_refreshed_list()
        .iter()
        .filter_map(|c| c.temperature())
        .filter(|t| t.is_finite() && *t > 0.0)
        .fold(None, |m: Option<f32>, t| Some(m.map_or(t, |m| m.max(t))));

    let load = System::load_average().one;
    let mut o = json!({
        "cpu": (sys.global_cpu_usage() as f64 / 100.0 * 10000.0).round() / 10000.0,
        "cores": cores,
        // sysinfo reports available = 0 on some macOS versions; fall back to "used" there.
        "mem": if total > 0.0 {
            let used = if sys.available_memory() > 0 { total - sys.available_memory() as f64 } else { sys.used_memory() as f64 };
            (used / total * 10000.0).round() / 10000.0
        } else { 0.0 },
        "memTotal": total,
        "swap": if swap_total > 0.0 { sys.used_swap() as f64 / swap_total } else { 0.0 },
        "load": if cfg!(windows) { sys.global_cpu_usage() as f64 / 100.0 * cores as f64 } else { load },
        "uptime": System::uptime(),
        "disks": disk_rows,
        "rx": rx, "tx": tx,
        "topCPU": top_cpu, "topMem": top_mem,
        "temp": temp.map(|t| (t as f64 * 10.0).round() / 10.0),
        "tz": chrono::Local::now().offset().local_minus_utc(),
        "jobs": [], "containers": [], "services": [], "failed": [],
        "hw": {"model": sys.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default(), "os": System::long_os_version().unwrap_or_default(),
               "cpu": sys.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default(), "kernel": System::kernel_version().unwrap_or_default(), "storage": []},
    });
    if slow {
        o["updates"] = Value::Null;
        o["reboot"] = json!(false);
    }
    o
}

#[cfg(test)]
mod tests {
    #[test]
    fn collects_this_machine() {
        let j = super::collect(true);
        assert!(j["cores"].as_u64().unwrap() >= 1);
        assert!(j["memTotal"].as_f64().unwrap() > 0.0);
        assert!((0.0..=1.0).contains(&j["mem"].as_f64().unwrap()));
        assert!(!j["disks"].as_array().unwrap().is_empty());
        let d = crate::core::parse(&j, crate::core::now(), None, true);
        assert!(d["error"].is_null() && d["memTotalGB"].as_f64().unwrap() > 0.5);
    }
}
