//! Running processes with a timeout, logging.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Runs argv (stdin optional), returns (stdout+stderr, exit code; -1 on timeout/spawn error).
pub fn run(argv: &[&str], stdin: Option<&str>, timeout_s: u64) -> (String, i32) {
    let mut cmd = Command::new(argv[0]);
    cmd.args(&argv[1..]).stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (e.to_string(), -1),
    };
    if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let input = input.to_string();
        std::thread::spawn(move || {
            let _ = pipe.write_all(input.as_bytes());
        });
    }
    let mut out = child.stdout.take().unwrap();
    let mut err = child.stderr.take().unwrap();
    let t_out = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = out.read_to_end(&mut s);
        s
    });
    let t_err = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = err.read_to_end(&mut s);
        s
    });
    let start = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st.code().unwrap_or(-1),
            Ok(None) if start.elapsed() > Duration::from_secs(timeout_s) => {
                let _ = child.kill();
                let _ = child.wait();
                let mut s = String::from_utf8_lossy(&t_out.join().unwrap_or_default()).to_string();
                s.push_str("timeout");
                return (s, -1);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => return (e.to_string(), -1),
        }
    };
    let mut s = String::from_utf8_lossy(&t_out.join().unwrap_or_default()).to_string();
    s.push_str(&String::from_utf8_lossy(&t_err.join().unwrap_or_default()));
    (s, code)
}

/// A command on a device: locally through `sh -c`, remotely over SSH (BatchMode).
pub fn run_on(node: &serde_json::Value, cmd: &str, stdin: Option<&str>, timeout_s: u64) -> (String, i32) {
    if node.get("local").and_then(|v| v.as_bool()).unwrap_or(false) {
        run(&["sh", "-c", cmd], stdin, timeout_s)
    } else {
        let ssh = node.get("ssh").and_then(|v| v.as_str()).unwrap_or("");
        run(&["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", ssh, cmd], stdin, timeout_s)
    }
}

pub fn last_json_line(out: &str) -> Option<serde_json::Value> {
    out.lines().rev().find(|l| l.starts_with('{')).and_then(|l| serde_json::from_str(l).ok())
}

pub fn log(msg: &str) {
    println!("{} {msg}", chrono::Local::now().format("%H:%M:%S"));
}

#[cfg(test)]
mod tests {
    #[test]
    fn runs_with_stdin_and_timeout() {
        let (out, code) = super::run(&["sh", "-s"], Some("echo halo; echo err >&2"), 5);
        assert_eq!(code, 0);
        assert!(out.contains("halo") && out.contains("err"));
        let (out, code) = super::run(&["sh", "-c", "sleep 5"], None, 1);
        assert_eq!(code, -1);
        assert!(out.contains("timeout"));
    }
}
