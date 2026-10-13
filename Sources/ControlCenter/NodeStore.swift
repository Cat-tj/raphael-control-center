import Foundation
import AppKit

enum NodeHealth: String, Codable { case ok, warn, down, unknown }

/// One machine Raphael watches: the local Mac or an SSH target (key-based auth only).
struct RNode: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: String          // "mac" | "raspi" | "vps" | "server"
    /// `user@host` or an alias from ~/.ssh/config. Empty = this Mac.
    var ssh: String
    /// Optional jump host (`ssh -J`), e.g. reach a LAN-only RasPi through one on Tailscale.
    var jump: String? = nil
    /// Address the Mac uses to open the node's web ports (defaults to the SSH host).
    var webHost: String? = nil
    var isLocal: Bool { ssh.isEmpty }

    var host: String {
        if let webHost, !webHost.isEmpty { return webHost }
        if isLocal { return "localhost" }
        return ssh.split(separator: "@").last.map(String.init) ?? ssh
    }
}

/// Something running on a node: a Docker container or a systemd service.
struct RApp: Identifiable, Hashable {
    enum Kind: String { case docker, service }
    var id: String { "\(kind.rawValue):\(name)" }
    let kind: Kind
    let name: String
    let project: String      // compose project, or "systemd"
    let state: String        // running / exited / failed / restarting…
    let status: String       // "Up 3 hours (healthy)"
    let ports: [Int]         // published host ports

    var health: NodeHealth {
        let s = (state + " " + status).lowercased()
        if s.contains("unhealthy") || s.contains("restarting") { return .warn }
        if state == "running" || state == "active" { return .ok }
        if isCompletedJob { return .ok }
        return .down
    }

    /// One-shot containers (migrations, seeders) that finished successfully.
    var isCompletedJob: Bool { kind == .docker && state == "exited" && status.hasPrefix("Exited (0)") }
}

struct NodeStatus: Equatable {
    var health: NodeHealth = .unknown
    var hostname = ""
    var uptime: TimeInterval = 0
    var load: [Double] = []
    var cores = 1
    var memTotalKB = 0
    var memAvailKB = 0
    var diskTotalKB = 0
    var diskUsedKB = 0
    var tempC: Double?
    var failedUnits: [String] = []
    var apps: [RApp] = []
    var error: String?
    var checkedAt: Date?
    var latencyMs: Int?
    /// What the node runs: "hermes", "omniroute", "tailscale", "docker", "graphify".
    var caps: Set<String> = []

    var memUsed: Double { memTotalKB > 0 ? 1 - Double(memAvailKB) / Double(memTotalKB) : 0 }
    var diskUsed: Double { diskTotalKB > 0 ? Double(diskUsedKB) / Double(diskTotalKB) : 0 }
    var loadPerCore: Double { (load.first ?? 0) / Double(max(cores, 1)) }
    var appsDown: Int { apps.filter { $0.health != .ok }.count }
}

struct CommandResult: Identifiable {
    let id = UUID()
    let node: String
    let command: String
    let output: String
    let exitCode: Int32
    let at = Date()
}

/// Runs probes and actions. Personal-use policy: every action runs on click,
/// no confirmation; privileged commands use `sudo -n` so they fail fast
/// instead of hanging on a password prompt.
@MainActor
final class NodeStore: ObservableObject {
    static let shared = NodeStore()

    @Published var nodes: [RNode] = []
    @Published var status: [String: NodeStatus] = [:]
    @Published var busy: Set<String> = []
    @Published var log: [CommandResult] = []

    private var timer: Timer?
    private static let configVersion = 2
    private struct ConfigFile: Codable { var version: Int; var nodes: [RNode] }

    nonisolated static var supportDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Raphael")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var configURL: URL { supportDir.appendingPathComponent("nodes.json") }

    private init() { load() }

    // MARK: Config

    func load() {
        let data = try? Data(contentsOf: Self.configURL)
        if let data, let file = try? JSONDecoder().decode(ConfigFile.self, from: data), file.version >= Self.configVersion {
            nodes = file.nodes
            return
        }
        // v1 (plain array, RasPis on LAN IPs) or nothing: rebuild from defaults, keep user-added nodes.
        let old = data.flatMap { try? JSONDecoder().decode([RNode].self, from: $0) } ?? []
        var merged = Self.defaultNodes()
        for n in old where !merged.contains(where: { $0.id == n.id }) && n.id != "mac" {
            merged.append(n)
        }
        nodes = merged
        save()
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(ConfigFile(version: Self.configVersion, nodes: nodes)).write(to: Self.configURL, options: .atomic)
    }

    func add(_ node: RNode) { nodes.append(node); save(); Task { await probe(node) } }
    func remove(_ node: RNode) { nodes.removeAll { $0.id == node.id }; status[node.id] = nil; save() }

    static func defaultNodes() -> [RNode] {
        // This Mac, plus every host in ~/.ssh/config. More devices: Infrastruktur → Tambah device.
        var out: [RNode] = [RNode(id: "mac", name: Host.current().localizedName ?? "This Mac", kind: "mac", ssh: "")]
        for alias in sshConfigHosts() where !out.contains(where: { $0.ssh == alias }) {
            out.append(RNode(id: "ssh-\(alias)", name: alias, kind: "vps", ssh: alias))
        }
        return out
    }

    /// First alias of every concrete `Host` entry in ~/.ssh/config (wildcards and bare IPs skipped).
    static func sshConfigHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            let alias = String(parts[1])
            if alias.contains("*") || alias.contains("?") { continue }
            if alias.allSatisfy({ $0.isNumber || $0 == "." }) { continue }
            out.append(alias)
        }
        return out
    }

    // MARK: Polling (only while the Control Center is open: 0 % CPU otherwise)

    func startPolling() {
        guard timer == nil else { return }
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in NodeStore.shared.refreshAll() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refreshAll() { for n in nodes where !busy.contains(n.id) { Task { await probe(n) } } }

    var allApps: [(node: RNode, app: RApp)] {
        nodes.flatMap { n in (status[n.id]?.apps ?? []).map { (n, $0) } }
    }

    // MARK: Probe

    /// systemd units that are plumbing, not "apps".
    private static let serviceNoise = "systemd|dbus|getty|user@|ssh|cron|rsyslog|polkit|udisks|wpa_|avahi|bluetooth|ModemManager|NetworkManager|triggerhappy|alsa|rng-|serial|hciuart|accounts-daemon|colord|cups|lightdm|packagekit|rtkit|upower|dphys|udev|snapd|multipathd|unattended|irqbalance|chrony|ntp|atd|fwupd|containerd|uuidd|lvm|iscsid|open-vm|networkd|resolved|timesyncd|logind|journald|haveged|wtmp|keyboard|console|plymouth|thermald|nmbd|winbind|tailscaled|docker\\.service|ufw|apparmor|qemu|gpu-manager|power-profiles|switcheroo|kerneloops|whoopsie|smartmontools|mdmonitor|lm-sensors|fail2ban"

    private static var linuxProbe: String { #"""
    echo "H=$(hostname)"; echo "UP=$(cut -d. -f1 /proc/uptime)"; echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg)"
    echo "CPU=$(nproc 2>/dev/null || echo 1)"
    awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print "MEM="t" "a}' /proc/meminfo
    df -Pk / | awk 'NR==2{print "DISK="$2" "$3}'
    [ -r /sys/class/thermal/thermal_zone0/temp ] && echo "TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --failed --no-legend --plain 2>/dev/null | awk '{print "F|"$1}'
      systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -vE '__NOISE__' | sed 's/^/S|/'
    fi
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --format 'D|{{.Names}}|{{.State}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null
    fi
    __CAPS__
    true
    """#.replacingOccurrences(of: "__CAPS__", with: capsProbe).replacingOccurrences(of: "__NOISE__", with: serviceNoise) }

    private static let macProbe = #"""
    echo "H=$(hostname -s)"
    b=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/'); echo "UP=$(( $(date +%s) - b ))"
    echo "LOAD=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}')"
    echo "CPU=$(sysctl -n hw.ncpu)"
    ps=$(sysctl -n hw.pagesize); t=$(( $(sysctl -n hw.memsize) / 1024 ))
    a=$(vm_stat | awk -v ps=$ps '/Pages free|Pages inactive|Pages speculative|Pages purgeable/{gsub("\\.","",$NF); s+=$NF}END{print int(s*ps/1024)}')
    echo "MEM=$t $a"
    df -Pk /System/Volumes/Data | awk 'NR==2{print "DISK="$2" "$3}'
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --format 'D|{{.Names}}|{{.State}}|{{.Status}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null
    fi
    for p in omniroute hermes ollama; do pgrep -qf "$p" && echo "P|$p"; done
    __CAPS__
    true
    """#.replacingOccurrences(of: "__CAPS__", with: capsProbe)

    private static let capsProbe = #"""
    [ -f "$HOME/.hermes/state.db" ] && echo "CAP=hermes"
    { pgrep -f omniroute >/dev/null 2>&1 || [ -d "$HOME/.omniroute" ]; } && echo "CAP=omniroute"
    command -v tailscale >/dev/null 2>&1 || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && echo "CAP=tailscale"
    command -v docker >/dev/null 2>&1 && echo "CAP=docker"
    { command -v graphify >/dev/null 2>&1 || [ -x "$HOME/graphify-galaxy/.venv/bin/graphify" ]; } && echo "CAP=graphify"
    """#

    func probe(_ node: RNode) async {
        busy.insert(node.id)
        defer { busy.remove(node.id) }
        let t0 = Date()
        let r = await Self.run(node: node, script: node.isLocal ? Self.macProbe : Self.linuxProbe, timeout: 15)
        var s = NodeStatus()
        s.checkedAt = Date()
        s.latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        if !r.output.contains("H=") {
            s.health = .down
            s.error = Self.friendlyError(r.output, node: node)
            status[node.id] = s
            return
        }
        var apps: [RApp] = []
        for line in r.output.components(separatedBy: .newlines) {
            if line.hasPrefix("D|") {
                let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5 else { continue }
                apps.append(RApp(kind: .docker, name: f[1], project: f.count > 5 && !f[5].isEmpty ? f[5] : "docker",
                                 state: f[2], status: f[3], ports: Self.publishedPorts(f[4])))
                continue
            }
            if line.hasPrefix("P|") {
                apps.append(RApp(kind: .service, name: String(line.dropFirst(2)), project: "proses", state: "active", status: "running", ports: []))
                continue
            }
            if line.hasPrefix("S|") {
                let name = String(line.dropFirst(2)).replacingOccurrences(of: ".service", with: "")
                apps.append(RApp(kind: .service, name: name, project: "systemd", state: "active", status: "running", ports: []))
                continue
            }
            if line.hasPrefix("F|") {
                let unit = String(line.dropFirst(2))
                s.failedUnits.append(unit)
                apps.append(RApp(kind: .service, name: unit.replacingOccurrences(of: ".service", with: ""),
                                 project: "systemd", state: "failed", status: "failed", ports: []))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let nums = v.split(separator: " ").compactMap { Double($0) }
            switch k {
            case "H": s.hostname = v
            case "UP": s.uptime = nums.first ?? 0
            case "LOAD": s.load = nums
            case "CPU": s.cores = Int(nums.first ?? 1)
            case "MEM": if nums.count == 2 { s.memTotalKB = Int(nums[0]); s.memAvailKB = Int(nums[1]) }
            case "DISK": if nums.count == 2 { s.diskTotalKB = Int(nums[0]); s.diskUsedKB = Int(nums[1]) }
            case "TEMP": if let t = nums.first { s.tempC = t > 1000 ? t / 1000 : t }
            case "CAP": s.caps.insert(v)
            default: break
            }
        }
        s.apps = apps.sorted { ($0.health != .ok ? 0 : 1, $0.project, $0.name) < ($1.health != .ok ? 0 : 1, $1.project, $1.name) }
        let hot = (s.tempC ?? 0) > 75
        let warn = s.diskUsed > 0.9 || s.memUsed > 0.92 || s.loadPerCore > 1.5 || hot || !s.failedUnits.isEmpty || s.appsDown > 0
        s.health = warn ? .warn : .ok
        status[node.id] = s
    }

    /// "0.0.0.0:8090->80/tcp, :::8090->80/tcp" → [8090]
    static func publishedPorts(_ s: String) -> [Int] {
        var out: [Int] = []
        for part in s.components(separatedBy: ",") where part.contains("->") {
            let left = part.components(separatedBy: "->")[0]
            if let p = Int(left.split(separator: ":").last ?? ""), !out.contains(p) { out.append(p) }
        }
        return out
    }

    static func friendlyError(_ out: String, node: RNode) -> String {
        let o = out.lowercased()
        if o.contains("permission denied") { return "SSH key belum terpasang. Jalankan sekali di Terminal: ssh-copy-id \(node.ssh)" }
        if o.contains("no route to host") || o.contains("timed out") || o.contains("host is down") {
            return "Tidak terjangkau. Cek jaringan/Tailscale, atau izinkan Raphael di Privacy & Security → Local Network."
        }
        if o.contains("could not resolve") { return "Host tidak dikenal: \(node.ssh)" }
        let last = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
        return last.isEmpty ? "Gagal terhubung" : String(last.prefix(160))
    }

    // MARK: Actions

    @discardableResult
    func runCommand(_ node: RNode, _ command: String, label: String? = nil) async -> CommandResult {
        busy.insert(node.id)
        defer { busy.remove(node.id) }
        let r = await Self.run(node: node, script: command, timeout: 300)
        let result = CommandResult(node: node.name, command: label ?? command, output: r.output, exitCode: r.exitCode)
        log.insert(result, at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        return result
    }

    func restart(_ app: RApp, on node: RNode) async {
        let q = Self.shellQuote(app.name)
        switch app.kind {
        case .docker: await runCommand(node, "docker restart \(q)", label: "docker restart \(app.name)")
        case .service: await runCommand(node, "sudo -n systemctl restart \(q) && systemctl is-active \(q)", label: "restart \(app.name)")
        }
        await probe(node)
    }

    func stop(_ app: RApp, on node: RNode) async {
        let q = Self.shellQuote(app.name)
        switch app.kind {
        case .docker: await runCommand(node, "docker stop \(q)", label: "docker stop \(app.name)")
        case .service: await runCommand(node, "sudo -n systemctl stop \(q)", label: "stop \(app.name)")
        }
        await probe(node)
    }

    func start(_ app: RApp, on node: RNode) async {
        let q = Self.shellQuote(app.name)
        switch app.kind {
        case .docker: await runCommand(node, "docker start \(q)", label: "docker start \(app.name)")
        case .service: await runCommand(node, "sudo -n systemctl start \(q)", label: "start \(app.name)")
        }
        await probe(node)
    }

    func logs(_ app: RApp, on node: RNode) async {
        let q = Self.shellQuote(app.name)
        switch app.kind {
        case .docker: await runCommand(node, "docker logs --tail 80 \(q) 2>&1", label: "logs \(app.name)")
        case .service: await runCommand(node, "journalctl -u \(q) -n 80 --no-pager 2>&1", label: "logs \(app.name)")
        }
    }

    func reboot(_ node: RNode) async {
        await runCommand(node, "sudo -n reboot", label: "reboot")
        status[node.id]?.health = .unknown
    }

    func shutdown(_ node: RNode) async {
        await runCommand(node, "sudo -n shutdown -h now", label: "shutdown")
        status[node.id]?.health = .unknown
    }

    func openTerminal(_ node: RNode, at dir: String? = nil) {
        var cmd = "cd " + (dir.map(Self.shellQuote) ?? "~")
        if !node.isLocal {
            cmd = "ssh " + (node.jump.flatMap { $0.isEmpty ? nil : "-J \($0) " } ?? "") + (dir == nil ? node.ssh
                : "-t \(node.ssh) " + Self.shellQuote("cd \(Self.shellQuote(dir!)) && exec $SHELL -l"))
        }
        let src = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }

    // MARK: Process plumbing

    nonisolated static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    nonisolated static var toolPath: String {
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    /// Runs `script` with /bin/sh locally or over SSH (stdin), off the main thread.
    nonisolated static func run(node: RNode, script: String, timeout: TimeInterval) async -> (output: String, exitCode: Int32) {
        var args: [String] = []
        if !node.ssh.isEmpty {
            args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=5"]
            if let j = node.jump, !j.isEmpty { args += ["-J", j] }
            args += [node.ssh, "sh -s"]
        }
        return await runProcess(node.ssh.isEmpty ? "/bin/sh" : "/usr/bin/ssh", node.ssh.isEmpty ? ["-s"] : args,
                                stdin: script, timeout: timeout)
    }

    nonisolated static func runProcess(_ exe: String, _ args: [String], stdin: String? = nil,
                                       timeout: TimeInterval) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = toolPath
                p.environment = env
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = outPipe
                do { try p.run() } catch {
                    cont.resume(returning: (error.localizedDescription, -1)); return
                }
                if let stdin { inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data()) }
                try? inPipe.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let text = String(decoding: data, as: UTF8.self)
                cont.resume(returning: (String(text.suffix(30_000)), p.terminationStatus))
            }
        }
    }
}
