import Foundation

/// One metrics sample of a device (all counters raw; rates come from two samples).
struct MSample: Codable, Equatable {
    var t: Double                       // unix time
    var cpu: Double = 0                 // 0…1
    var mem: Double = 0                 // 0…1
    var swap: Double = 0
    var disk: Double = 0                // root filesystem 0…1
    var load: Double = 0
    var temp: Double?
    var rx: Double = 0                  // bytes/s (computed)
    var tx: Double = 0
    var req: Double?                    // tunnel requests/min (computed)
}

struct MProc: Hashable { let pid: Int; let name: String; let cpu: Double; let mem: Double }
struct MContainer: Hashable { let name: String; let status: String; let cpu: Double; let mem: String; let memPct: Double; let net: String; let restarts: Int
    var project = ""
    var dir = ""
    var ports: [Int] = []
    var healthy: Bool { status.hasPrefix("Up") && !status.contains("unhealthy") && !status.contains("Restarting") }
    var memBytes: Double { MonitorStore.bytes(mem) }
}
/// A custom systemd service (unit file written by hand, not a distro package).
struct MService: Hashable {
    let unit: String; let user: Bool; let state: String; let sub: String
    let mem: Double; let cpuNs: Double; let restarts: Int; let pid: Int; let desc: String; let dir: String
    var name: String { unit.replacingOccurrences(of: ".service", with: "") }
    var running: Bool { state == "active" }
}
/// A Caddy site block: hosts → reverse proxy target and/or static root.
struct MRoute: Hashable { let hosts: [String]; let proxy: String?; let root: String? }
/// One CPU/RAM point of a container or service.
struct MPoint: Equatable { let t: Double; let cpu: Double; let mem: Double }
struct MDisk: Hashable { let mount: String; let used: Double; let totalGB: Double }

/// Cloudflare tunnel counters (cloudflared /metrics) on a device.
struct MTunnel: Equatable {
    var port = 0
    var total: Double = 0
    var errors: Double = 0
    var codes: [String: Double] = [:]
    var connections: Double = 0
    var concurrent: Double = 0
    var hosts: [String] = []
}

/// Everything the latest sample said, besides the numbers kept as history.
/// What the device is: board/laptop model, OS, CPU, RAM, storage.
struct MHardware: Codable, Equatable {
    var model = ""
    var os = ""
    var cpu = ""
    var kernel = ""
    var storage: [String] = []
    var ramGB = 0.0
    /// "Raspberry Pi 4 Model B · 4 GB RAM · Debian 13"
    var summary: String {
        let short = model.replacingOccurrences(of: #" Rev [\d.]+"#, with: "", options: .regularExpression).replacingOccurrences(of: " Plus", with: "+")
        let os2 = os.replacingOccurrences(of: "GNU/Linux ", with: "").replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)
        return [short, ramGB > 0 ? "\(ramGB < 1.5 ? "1" : String(Int(ramGB.rounded()))) GB RAM" : nil, os2.isEmpty ? nil : os2].compactMap { $0 }.joined(separator: " · ")
    }
}

struct MDetail: Equatable {
    static func == (a: MDetail, b: MDetail) -> Bool { a.at == b.at && a.error == b.error }
    var cores = 1
    var memTotalGB = 0.0
    var uptime: Double = 0
    var throttled: String?              // RasPi vcgencmd get_throttled (0x0 = fine)
    var disks: [MDisk] = []
    var topCPU: [MProc] = []
    var topMem: [MProc] = []
    var containers: [MContainer] = []
    var failed: [String] = []
    var updates: Int?                   // pending apt upgrades
    var securityUpdates: Int?
    var sshFails: Int?                  // failed SSH logins, last 24 h
    var rebootRequired = false
    var tunnel: MTunnel?
    var services: [MService] = []
    var jobs: [MJob] = []
    var routes: [MRoute] = []
    var listen: [Int: (name: String, pid: Int)] = [:]
    var ips: [String] = []
    var error: String?
    var at: Date?
}

/// A health signal worth looking at.
struct MAlert: Identifiable, Hashable {
    enum Level: Int { case info, warn, bad }
    var id: String { node + ":" + text }
    let node: String
    let level: Level
    let icon: String
    let text: String
}

/// Samples every device's metrics (60 s in the background, 10 s while the Monitor page is
/// open) and keeps 24 h of history per device on disk.
@MainActor
final class MonitorStore: ObservableObject {
    static let shared = MonitorStore()

    @Published private(set) var history: [String: [MSample]] = [:]
    @Published private(set) var detail: [String: MDetail] = [:]
    /// Hardware per device (kept on disk; refreshed every 30 min).
    @Published private(set) var hardware: [String: MHardware] = [:]
    @Published private(set) var sampling: Set<String> = []
    @Published var live = false { didSet { reschedule() } }
    /// App catalog + statuses, rebuilt once per sampling round (not on every redraw).
    @Published private(set) var apps: [MApp] = []
    @Published private(set) var appStatus: [String: MAppStatus] = [:]

    func rebuildCatalog() {
        let list = AppCatalog.build()
        apps = list
        appStatus = Dictionary(uniqueKeysWithValues: list.map { ($0.id, AppCatalog.status($0)) })
    }
    /// CPU (%) / RAM (bytes) per container and service: "node|c:name" or "node|s:unit".
    @Published private(set) var components: [String: [MPoint]] = [:]
    private var lastCPU: [String: (t: Double, ns: Double)] = [:]

    private var raw: [String: (t: Double, rx: Double, tx: Double, req: Double?)] = [:]
    private var lastSlow: [String: Double] = [:]
    private var failures: [String: Int] = [:]
    private var lastWebSample: [String: Double] = [:]
    private var timer: Timer?
    private var lastSave = Date()
    private var lastSiteCheck = Date.distantPast
    private var lastSources = Date.distantPast
    static let keep: Double = 24 * 3600

    private init() {
        load()
        reschedule()
        Task { await sampleAll() }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: live ? 10 : 60, repeats: true) { _ in
            Task { @MainActor in await MonitorStore.shared.sampleAll() }
        }
    }

    func sampleAll() async {
        let nodes = NodeStore.shared.nodes
        await withTaskGroup(of: Void.self) { g in
            for n in nodes {
                // Unreachable devices back off (every 5 min after 3 failures).
                let f = failures[n.id] ?? 0
                if f >= 3, let last = history[n.id]?.last?.t ?? lastSlow[n.id], Date().timeIntervalSince1970 - last < 300, !live { continue }
                g.addTask { await MonitorStore.shared.sample(n) }
            }
        }
        rebuildCatalog()
        MonitorTransitions.record()       // project-linked resources going down / recovering → activity
        if Date().timeIntervalSince(lastSiteCheck) > 55 {
            lastSiteCheck = Date()
            SiteStore.shared.extra = AppCatalog.checkURLs(apps)
            SiteStore.shared.checkAll()
        }
        // Cloud sources and the local project scan, every 10 minutes.
        if Date().timeIntervalSince(lastSources) > 600 {
            lastSources = Date()
            VercelStore.shared.refresh(); GitHubStore.shared.refresh(); LocalProjectsStore.shared.refresh(); N8nStore.shared.refreshAll()
            CloudflareStore.shared.refresh()
        }
        if Date().timeIntervalSince(lastSave) > 600 { save() }
    }

    func sample(_ node: RNode) async {
        guard !sampling.contains(node.id) else { return }
        sampling.insert(node.id)
        defer { sampling.remove(node.id) }
        var now = Date().timeIntervalSince1970
        var slow = now - (lastSlow[node.id] ?? 0) > 1800        // apt + ssh log checks every 30 min
        var j: [String: Any]?
        var output = ""
        // Raphael Web already samples this device: reuse its sample instead of running the collector twice.
        if !node.isLocal, let web = await Self.webSample(node.id) {
            if web.at <= (lastWebSample[node.id] ?? 0) { return }                 // nothing new since last time
            lastWebSample[node.id] = web.at
            j = web.raw; now = web.at; slow = web.raw["updates"] != nil
        } else {
            let script = (node.isLocal ? Self.macScript : Self.linuxScript).replacingOccurrences(of: "__SLOW__", with: slow ? "1" : "0")
            let r = await NodeStore.run(node: node, script: script, timeout: 25)
            output = r.output
            if let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }) {
                j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        }
        guard let j else {
            let r = (output: output, exitCode: Int32(0))
            failures[node.id, default: 0] += 1
            var d = detail[node.id] ?? MDetail()
            d.error = r.output.isEmpty ? "Tidak terhubung" : String(r.output.suffix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            d.at = Date()
            detail[node.id] = d
            return
        }
        failures[node.id] = 0
        if slow { lastSlow[node.id] = now }
        let (s, d) = Self.parse(j, previous: detail[node.id], slow: slow)
        var sample = s
        sample.t = now
        // Rates from the previous raw counters.
        let rx = (j["rx"] as? NSNumber)?.doubleValue ?? 0, tx = (j["tx"] as? NSNumber)?.doubleValue ?? 0
        let req = d.tunnel?.total
        if let p = raw[node.id], now > p.t {
            let dt = now - p.t
            sample.rx = max(0, (rx - p.rx) / dt); sample.tx = max(0, (tx - p.tx) / dt)
            if let req, let pr = p.req { sample.req = max(0, (req - pr) / dt * 60) }
        }
        raw[node.id] = (now, rx, tx, req)
        var h = history[node.id] ?? []
        h.append(sample)
        h.removeAll { now - $0.t > Self.keep }
        history[node.id] = h
        detail[node.id] = d
        if let hw = j["hw"] as? [String: Any] {
            var m = MHardware(model: hw["model"] as? String ?? "", os: hw["os"] as? String ?? "", cpu: hw["cpu"] as? String ?? "",
                              kernel: hw["kernel"] as? String ?? "", storage: hw["storage"] as? [String] ?? [], ramGB: d.memTotalGB)
            if m.model.isEmpty { m.model = node.kind == "mac" ? "Mac" : "Linux server" }
            hardware[node.id] = m
            if let data = try? JSONEncoder().encode(hardware) { try? data.write(to: Self.dir.appendingPathComponent("hardware.json.cache"), options: .atomic) }
        }
        for c in d.containers { record("\(node.id)|c:\(c.name)", MPoint(t: now, cpu: c.cpu, mem: c.memBytes)) }
        for sv in d.services {
            let key = "\(node.id)|s:\(sv.unit)"
            var cpu = 0.0
            if let p = lastCPU[key], now > p.t, sv.cpuNs >= p.ns { cpu = (sv.cpuNs - p.ns) / 1e9 / (now - p.t) * 100 }
            lastCPU[key] = (now, sv.cpuNs)
            record(key, MPoint(t: now, cpu: cpu, mem: sv.mem))
        }
    }

    /// Raphael Web base URL (e.g. https://host.tailnet.ts.net:8787), empty = always sample over SSH.
    static var webURL: String {
        get { UserDefaults.standard.string(forKey: "raphaelWebURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "raphaelWebURL") }
    }

    /// The device's latest raw collector output from Raphael Web, if it is fresh (< 3 min).
    nonisolated static func webSample(_ nodeId: String) async -> (at: Double, raw: [String: Any])? {
        let base = await MainActor.run { webURL }
        guard !base.isEmpty, var comps = URLComponents(string: base.hasSuffix("/") ? String(base.dropLast()) + "/api/raw" : base + "/api/raw") else { return nil }
        comps.queryItems = [URLQueryItem(name: "node", value: nodeId)]
        guard let url = comps.url, let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = (j["at"] as? NSNumber)?.doubleValue, let raw = j["raw"] as? [String: Any],
              Date().timeIntervalSince1970 - at < 180 else { return nil }
        return (at, raw)
    }

    private func record(_ key: String, _ p: MPoint) {
        var h = components[key] ?? []
        h.append(p)
        if let first = h.first, p.t - first.t > Self.keep { h.removeAll { p.t - $0.t > Self.keep } }
        components[key] = h
    }

    /// "123.4MiB" / "1.2GiB" / "512kB" → bytes.
    nonisolated static func bytes(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let m = t.range(of: #"^[0-9.]+"#, options: .regularExpression), let v = Double(t[m]) else { return 0 }
        let unit = t[m.upperBound...].lowercased()
        let mult: Double = unit.hasPrefix("g") ? 1_073_741_824 : unit.hasPrefix("m") ? 1_048_576 : unit.hasPrefix("k") ? 1024 : 1
        return v * mult
    }

    // MARK: Parsing

    nonisolated static func parse(_ j: [String: Any], previous: MDetail?, slow: Bool) -> (MSample, MDetail) {
        func n(_ k: String) -> Double { (j[k] as? NSNumber)?.doubleValue ?? 0 }
        var s = MSample(t: Date().timeIntervalSince1970)
        s.cpu = n("cpu"); s.mem = n("mem"); s.swap = n("swap"); s.load = n("load")
        s.temp = (j["temp"] as? NSNumber)?.doubleValue
        var d = MDetail()
        d.cores = Int(n("cores")); d.memTotalGB = n("memTotal") / 1_073_741_824; d.uptime = n("uptime")
        d.throttled = j["throttled"] as? String
        d.disks = ((j["disks"] as? [[Any]]) ?? []).compactMap { a in
            guard a.count >= 3, let m = a[0] as? String else { return nil }
            return MDisk(mount: m, used: (a[1] as? NSNumber)?.doubleValue ?? 0, totalGB: (a[2] as? NSNumber)?.doubleValue ?? 0)
        }
        s.disk = d.disks.first(where: { $0.mount == "/" })?.used ?? d.disks.first?.used ?? 0
        func procs(_ k: String) -> [MProc] {
            ((j[k] as? [[Any]]) ?? []).compactMap { a in
                guard a.count >= 4 else { return nil }
                return MProc(pid: (a[0] as? NSNumber)?.intValue ?? 0, name: a[1] as? String ?? "?",
                             cpu: (a[2] as? NSNumber)?.doubleValue ?? 0, mem: (a[3] as? NSNumber)?.doubleValue ?? 0)
            }
        }
        d.topCPU = procs("topCPU"); d.topMem = procs("topMem")
        d.containers = ((j["containers"] as? [[String: Any]]) ?? []).map { c in
            MContainer(name: c["name"] as? String ?? "?", status: c["status"] as? String ?? "",
                       cpu: (c["cpu"] as? NSNumber)?.doubleValue ?? 0, mem: c["mem"] as? String ?? "",
                       memPct: (c["memPct"] as? NSNumber)?.doubleValue ?? 0, net: c["net"] as? String ?? "",
                       restarts: (c["restarts"] as? NSNumber)?.intValue ?? 0,
                       project: c["project"] as? String ?? "", dir: c["dir"] as? String ?? "",
                       ports: (c["ports"] as? [NSNumber])?.map(\.intValue) ?? [])
        }.sorted { ($0.healthy ? 1 : 0, -$0.cpu) < ($1.healthy ? 1 : 0, -$1.cpu) }
        d.failed = j["failed"] as? [String] ?? []
        d.ips = j["ips"] as? [String] ?? []
        let tz = (j["tz"] as? NSNumber)?.intValue ?? TimeZone.current.secondsFromGMT()
        d.jobs = ((j["jobs"] as? [[String: Any]]) ?? []).map { MJob.parse($0, tz: tz) }
        d.services = ((j["services"] as? [[String: Any]]) ?? []).map { v in
            MService(unit: v["unit"] as? String ?? "", user: v["user"] as? Bool ?? false, state: v["state"] as? String ?? "",
                     sub: v["sub"] as? String ?? "", mem: (v["mem"] as? NSNumber)?.doubleValue ?? 0,
                     cpuNs: (v["cpuNs"] as? NSNumber)?.doubleValue ?? 0, restarts: (v["restarts"] as? NSNumber)?.intValue ?? 0,
                     pid: (v["pid"] as? NSNumber)?.intValue ?? 0, desc: v["desc"] as? String ?? "", dir: v["dir"] as? String ?? "")
        }
        d.routes = ((j["caddy"] as? [[String: Any]]) ?? []).map { r in
            MRoute(hosts: r["hosts"] as? [String] ?? [], proxy: r["proxy"] as? String, root: r["root"] as? String)
        }
        for (k, v) in (j["listen"] as? [String: [Any]]) ?? [:] {
            if let port = Int(k) { d.listen[port] = (v.first as? String ?? "", (v.dropFirst().first as? NSNumber)?.intValue ?? 0) }
        }
        if slow {
            d.updates = (j["updates"] as? NSNumber)?.intValue
            d.securityUpdates = (j["security"] as? NSNumber)?.intValue
            d.sshFails = (j["sshFails"] as? NSNumber)?.intValue
            d.rebootRequired = (j["reboot"] as? Bool) ?? false
        } else if let p = previous {
            d.updates = p.updates; d.securityUpdates = p.securityUpdates; d.sshFails = p.sshFails; d.rebootRequired = p.rebootRequired
        }
        if let t = j["tunnel"] as? [String: Any] {
            var m = MTunnel()
            m.port = (t["port"] as? NSNumber)?.intValue ?? 0
            m.total = (t["total"] as? NSNumber)?.doubleValue ?? 0
            m.errors = (t["errors"] as? NSNumber)?.doubleValue ?? 0
            m.connections = (t["ha"] as? NSNumber)?.doubleValue ?? 0
            m.concurrent = (t["concurrent"] as? NSNumber)?.doubleValue ?? 0
            m.codes = (t["codes"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
            m.hosts = t["hosts"] as? [String] ?? []
            d.tunnel = m
        }
        d.at = Date()
        return (s, d)
    }

    /// What the device does, from what runs on it: "Cloudflare Tunnel · Caddy (4 situs) · Docker: plane, altora-office".
    func role(_ id: String) -> String? {
        guard let d = detail[id] else { return nil }
        var r: [String] = []
        if d.tunnel != nil { r.append("Cloudflare Tunnel") }
        if !d.routes.isEmpty { r.append("Caddy (\(d.routes.count) situs)") }
        let svc = Set(d.services.map(\.name))
        if svc.contains(where: { $0.hasPrefix("hermes") }) { r.append("Hermes") }
        if svc.contains("omniroute") { r.append("OmniRoute") }
        let projects = Array(Set(d.containers.map { $0.project.isEmpty ? $0.name : $0.project })).sorted()
        if !projects.isEmpty { r.append("Docker: " + projects.map { $0.replacingOccurrences(of: "-app", with: "") }.joined(separator: ", ")) }
        let apps = d.services.filter { !AppCatalog.isInfra($0.name) && !$0.name.hasPrefix("hermes") }.map(\.name)
        if !apps.isEmpty { r.append(apps.joined(separator: ", ")) }
        return r.isEmpty ? nil : r.joined(separator: " · ")
    }

    // MARK: Alerts

    func alerts(for nodes: [RNode], sites includeSites: Bool = true) -> [MAlert] {
        var out: [MAlert] = []
        for n in nodes {
            guard let d = detail[n.id] else { continue }
            if let e = d.error { out.append(MAlert(node: n.name, level: .bad, icon: "bolt.horizontal.circle", text: "Tidak bisa diambil datanya: \(e)")); continue }
            let s = history[n.id]?.last
            for disk in d.disks where disk.used > 0.85 {
                out.append(MAlert(node: n.name, level: disk.used > 0.93 ? .bad : .warn, icon: "internaldrive", text: "Disk \(disk.mount) \(Int(disk.used * 100))% penuh"))
            }
            if let s, s.mem > 0.9 { out.append(MAlert(node: n.name, level: .warn, icon: "memorychip", text: "RAM \(Int(s.mem * 100))% terpakai" + (s.swap > 0.5 ? ", swap \(Int(s.swap * 100))%" : ""))) }
            if let t = s?.temp, t > 75 { out.append(MAlert(node: n.name, level: t > 80 ? .bad : .warn, icon: "thermometer.high", text: "Suhu \(Int(t))°C")) }
            if let th = d.throttled, th != "0x0" { out.append(MAlert(node: n.name, level: .warn, icon: "bolt.trianglebadge.exclamationmark", text: "Daya/suhu: \(MonitorPage.throttleText(th)). Cek adaptor daya & pendingin")) }
            if let s, s.load > Double(d.cores) * 1.5 { out.append(MAlert(node: n.name, level: .warn, icon: "gauge.high", text: "Load \(String(format: "%.1f", s.load)) untuk \(d.cores) core")) }
            for c in d.containers where !c.healthy { out.append(MAlert(node: n.name, level: .bad, icon: "shippingbox", text: "Container \(c.name): \(c.status)")) }
            for c in d.containers where c.restarts > 3 { out.append(MAlert(node: n.name, level: .warn, icon: "arrow.clockwise", text: "Container \(c.name) restart \(c.restarts)×")) }
            for f in d.failed { out.append(MAlert(node: n.name, level: .bad, icon: "xmark.octagon", text: "Service gagal: \(f)")) }
            for job in d.jobs where !job.system || job.health == .failed {
                switch job.health {
                case .failed: out.append(MAlert(node: n.name, level: .bad, icon: "clock.badge.xmark", text: "Job \(job.name) gagal\(job.detail.isEmpty ? "" : ": \(job.detail)")"))
                case .missed: out.append(MAlert(node: n.name, level: .warn, icon: "clock.badge.exclamationmark", text: "Job \(job.name) tidak jalan sesuai jadwal (\(job.scheduleText))"))
                default: break
                }
            }
            if let u = d.securityUpdates, u > 0 { out.append(MAlert(node: n.name, level: .warn, icon: "lock.shield", text: "\(u) update keamanan tertunda")) }
            else if let u = d.updates, u > 20 { out.append(MAlert(node: n.name, level: .info, icon: "arrow.down.circle", text: "\(u) update paket tertunda")) }
            if d.rebootRequired { out.append(MAlert(node: n.name, level: .info, icon: "restart", text: "Perlu reboot untuk menyelesaikan update")) }
            if let f = d.sshFails, f > 20 { out.append(MAlert(node: n.name, level: f > 200 ? .bad : .warn, icon: "person.badge.shield.checkmark", text: "\(f) login SSH gagal (24 jam)")) }
            if let t = d.tunnel {
                if t.connections < 1 { out.append(MAlert(node: n.name, level: .bad, icon: "network.slash", text: "Cloudflare tunnel tidak terhubung")) }
                if let r = s?.req, r > 0, let prev = history[n.id]?.dropLast().last?.req, prev > 0, r > prev * 8, r > 60 {
                    out.append(MAlert(node: n.name, level: .warn, icon: "chart.line.uptrend.xyaxis", text: "Lonjakan traffic: \(Int(r)) req/menit"))
                }
            }
        }
        let sites = SiteStore.shared
        for site in includeSites ? sites.sites : [] {
            if let st = sites.status[site.url], !st.ok { out.append(MAlert(node: site.name, level: .bad, icon: "globe", text: "Website down: \(st.error ?? "HTTP \(st.code)")")) }
            if let exp = SiteStore.certExpiry(for: site.url) {
                let days = Int(exp.timeIntervalSinceNow / 86400)
                if days < 14 { out.append(MAlert(node: site.name, level: days < 5 ? .bad : .warn, icon: "lock.trianglebadge.exclamationmark", text: "Sertifikat SSL habis \(days) hari lagi")) }
            }
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }

    // MARK: Persistence (24 h)

    nonisolated private static var dir: URL {
        let d = NodeStore.supportDir.appendingPathComponent("metrics")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func save() {
        lastSave = Date()
        let h = history
        Task.detached(priority: .utility) {
            for (id, samples) in h {
                if let data = try? JSONEncoder().encode(samples) {
                    try? data.write(to: Self.dir.appendingPathComponent("\(id).json"), options: .atomic)
                }
            }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.dir.appendingPathComponent("hardware.json.cache")),
           let hw = try? JSONDecoder().decode([String: MHardware].self, from: data) { hardware = hw }
        let now = Date().timeIntervalSince1970
        for url in (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([MSample].self, from: data) {
                history[url.deletingPathExtension().lastPathComponent] = s.filter { now - $0.t < Self.keep }
            }
        }
    }

    // MARK: Collectors

    /// Linux: one python3 pass (stdlib only), JSON on the last line.
    nonisolated static let linuxScript = #"""
    python3 - <<'RAPHAEL_PY'
    import json, os, re, subprocess, time, shutil
    def sh(c, t=8):
        try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
        except Exception: return ""
    def cpu():
        a = [int(x) for x in open('/proc/stat').readline().split()[1:]]; time.sleep(0.4)
        b = [int(x) for x in open('/proc/stat').readline().split()[1:]]
        d = [y - x for x, y in zip(a, b)]; tot = sum(d) or 1
        return 1 - (d[3] + d[4]) / tot
    o = {"cpu": round(cpu(), 4), "cores": os.cpu_count()}
    mi = {l.split(':')[0]: int(l.split()[1]) * 1024 for l in open('/proc/meminfo') if len(l.split()) > 1}
    o["memTotal"] = mi.get("MemTotal", 0)
    o["mem"] = round(1 - mi.get("MemAvailable", 0) / max(mi.get("MemTotal", 1), 1), 4)
    o["swap"] = round(1 - mi.get("SwapFree", 0) / mi["SwapTotal"], 4) if mi.get("SwapTotal") else 0
    o["load"] = os.getloadavg()[0]
    o["uptime"] = float(open('/proc/uptime').read().split()[0])
    disks = []
    seen = set()
    for l in open('/proc/mounts'):
        dev, mnt, fs = l.split()[:3]
        if not dev.startswith('/dev/') or fs in ('squashfs', 'tmpfs') or dev in seen or mnt.startswith(('/boot', '/snap')): continue
        seen.add(dev)
        try: st = os.statvfs(mnt)
        except Exception: continue
        tot = st.f_blocks * st.f_frsize
        if tot < 1e9: continue
        disks.append([mnt, round(1 - st.f_bavail / max(st.f_blocks, 1), 4), round(tot / 1e9, 1)])
    o["disks"] = disks
    rx = tx = 0
    for l in open('/proc/net/dev').readlines()[2:]:
        name, data = l.split(':', 1); name = name.strip(); f = data.split()
        if name == 'lo' or name.startswith(('veth', 'docker', 'br-', 'tailscale')): continue
        rx += int(f[0]); tx += int(f[8])
    o["rx"], o["tx"] = rx, tx
    try: o["temp"] = int(open('/sys/class/thermal/thermal_zone0/temp').read()) / 1000
    except Exception: pass
    if shutil.which('vcgencmd'):
        m = re.search(r'throttled=(\S+)', sh('vcgencmd get_throttled', 3))
        if m: o["throttled"] = m.group(1)
    me = {os.getpid(), os.getppid()}
    def top(key):
        out = []
        for l in sh(f'ps -eo pid,comm,%cpu,%mem --sort=-{key} | head -12').splitlines()[1:]:
            p = l.split()
            if len(p) >= 4:
                try: row = [int(p[0]), ' '.join(p[1:-2]), float(p[-2]), float(p[-1])]
                except ValueError: continue
                if row[0] in me or row[1] in ('ps', 'sh', 'sshd-session', 'sshd', 'head'): continue
                out.append(row)
        return out[:5]
    o["topCPU"], o["topMem"] = top('%cpu'), top('%mem')
    if shutil.which('docker'):
        stats = {}
        for l in sh("docker stats --no-stream --format '{{json .}}'", 12).splitlines():
            try: j = json.loads(l); stats[j["Name"]] = j
            except Exception: pass
        cs = []
        for l in sh("docker ps -a --format '{{.Names}}|{{.Status}}|{{.Label \"com.docker.compose.project\"}}|{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Ports}}'").splitlines():
            if l.count('|') < 4: continue
            name, status, project, wdir, ports = l.split('|', 4)
            if status.startswith('Exited (0)'): continue
            j = stats.get(name, {})
            num = lambda v: float(re.sub(r'[^0-9.]', '', v) or 0)
            cs.append({"name": name, "status": status, "cpu": num(j.get("CPUPerc", "0")), "mem": j.get("MemUsage", "").split(' / ')[0],
                       "memPct": num(j.get("MemPerc", "0")), "net": j.get("NetIO", ""), "project": project, "dir": wdir,
                       "ports": sorted({int(p) for p in re.findall(r':(\d+)->', ports)})})
        if cs:
            rc = {}
            for l in sh("docker inspect -f '{{.Name}} {{.RestartCount}}' $(docker ps -aq) 2>/dev/null").splitlines():
                p = l.split()
                if len(p) == 2: rc[p[0].lstrip('/')] = int(p[1])
            for c in cs: c["restarts"] = rc.get(c["name"], 0)
        o["containers"] = cs
    o["ips"] = sh('hostname -I').split()
    # Custom services (regular unit files, not distro symlinks), system and user.
    svcs = []
    for scope, d in (('', '/etc/systemd/system'), ('--user', os.path.expanduser('~/.config/systemd/user'))):
        try: units = [f for f in os.listdir(d) if f.endswith('.service') and not os.path.islink(os.path.join(d, f))]
        except Exception: units = []
        for u in units:
            props = dict(l.split('=', 1) for l in sh(f"systemctl {scope} show {u} -p ActiveState,SubState,MemoryCurrent,CPUUsageNSec,NRestarts,MainPID,Description,WorkingDirectory").splitlines() if '=' in l)
            if props.get('ActiveState') in (None, '', 'inactive') and props.get('SubState') == 'dead' and props.get('NRestarts', '0') == '0': continue
            def num(v):
                try: return int(v)
                except Exception: return 0
            pid = num(props.get('MainPID'))
            mem = num(props.get('MemoryCurrent')) if props.get('MemoryCurrent', '').isdigit() else 0
            cpu = num(props.get('CPUUsageNSec')) if props.get('CPUUsageNSec', '').isdigit() else 0
            if pid and (not mem or not cpu):
                try:
                    st = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
                    cpu = cpu or int((int(st[11]) + int(st[12])) / os.sysconf('SC_CLK_TCK') * 1e9)
                    mem = mem or int(st[21]) * os.sysconf('SC_PAGE_SIZE')
                except Exception: pass
            svcs.append({"unit": u, "user": bool(scope), "state": props.get('ActiveState', ''), "sub": props.get('SubState', ''),
                         "mem": mem, "cpuNs": cpu,
                         "restarts": num(props.get('NRestarts')), "pid": num(props.get('MainPID')), "desc": props.get('Description', ''),
                         "dir": props.get('WorkingDirectory', '')})
    o["services"] = svcs
    # Listening TCP ports → process (for mapping reverse proxies to apps).
    ports = {}
    for l in sh('sudo -n ss -ltnpH 2>/dev/null || ss -ltnH').splitlines():
        f = l.split()
        if len(f) < 4 or ':' not in f[3]: continue
        u = re.search(r'users:\(\("([^"]+)",pid=(\d+)', l)
        ports[f[3].rsplit(':', 1)[1]] = [u.group(1) if u else '', int(u.group(2)) if u else 0]
    o["listen"] = ports
    # Caddy sites → reverse_proxy target or static root.
    routes = []
    try: cf = open('/etc/caddy/Caddyfile').read()
    except Exception: cf = ''
    depth, cur = 0, None
    for raw in cf.splitlines():
        line = raw.split('#', 1)[0].rstrip()
        if not line.strip(): continue
        if depth == 0 and line.endswith('{'):
            cur = {"hosts": [h.strip().rstrip(',') for h in line[:-1].split() if h.strip()], "proxy": None, "root": None}
            routes.append(cur)
        elif cur is not None:
            t = line.strip().split()
            if t[0] == 'reverse_proxy' and len(t) > 1 and not cur["proxy"]: cur["proxy"] = t[1]
            if t[0] == 'root' and len(t) > 1: cur["root"] = t[-1]
        depth += line.count('{') - line.count('}')
    o["caddy"] = routes
    # ── Scheduled jobs: cron, systemd timers, Hermes cron ─────────────────
    jobs = []
    o["tz"] = time.localtime().tm_gmtoff
    sysnames = ('e2scrub', 'sysstat', 'debian-sa1', 'run-parts', 'popularity-contest', 'apt', 'anacron', 'logrotate', 'man-db', 'dpkg')
    cron_runs = {}
    for l in sh("sudo -n journalctl -u cron -u crond --since '-26h' -o short-unix --no-pager 2>/dev/null | grep ' CMD ('", 15).splitlines():
        m = re.match(r'([0-9.]+) .*CMD \((.*)\)\s*$', l)
        if m: cron_runs[m.group(2).strip()] = float(m.group(1))
    def cron_lines(text, src, has_user):
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith('#') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=', line): continue
            parts = line.split()
            if parts[0].startswith('@'): expr, rest = parts[0], parts[1:]
            elif len(parts) >= 6: expr, rest = ' '.join(parts[:5]), parts[5:]
            else: continue
            user = rest[0] if has_user and rest else src.split(':')[0]
            cmd = ' '.join(rest[1:] if has_user else rest)
            if not cmd: continue
            seg = re.split(r'\|\||&&|;', re.sub(r'[12]?>>?\s*\S+|2>&1', '', cmd))[-1].split()
            name = os.path.basename(seg[0]) if seg else cmd[:40]
            if name in ('run-parts',) and len(seg) > 1: name = 'run-parts ' + os.path.basename(seg[-1])
            import hashlib
            j = {"kind": "cron", "id": "cron:" + src + ":" + hashlib.sha1((expr + cmd).encode()).hexdigest()[:10], "name": name[:60],
                 "expr": expr, "user": user, "command": cmd[:300], "source": src, "enabled": True,
                 "system": any(n in cmd for n in sysnames) or any(n in src for n in ('e2scrub', 'sysstat'))}
            if cmd in cron_runs: j["last"] = cron_runs[cmd]
            lm = re.search(r'>>?\s*(/[^\s;|&]+)', cmd)
            if lm:
                log = lm.group(1); j["log"] = log
                tail = sh(f"sudo -n tail -n 6 {log} 2>/dev/null || tail -n 6 {log} 2>/dev/null").strip().splitlines()
                try: j["logModified"] = os.path.getmtime(log)
                except Exception:
                    st = sh(f"sudo -n stat -c %Y {log} 2>/dev/null").strip()
                    if st.isdigit(): j["logModified"] = float(st)
                if tail:
                    lines = [x.strip() for x in tail if x.strip()]
                    bad = [x for x in lines[-4:] if re.search(r'error|fail|fatal|refused|denied|traceback|exception', x, re.I)]
                    j["detail"] = (bad[0] if bad else (lines[-1] if lines else ''))[:240]
                    j["status"] = "failed" if bad else "ok"
            jobs.append(j)
    cron_lines(sh('crontab -l 2>/dev/null'), os.environ.get('USER', 'user') + ':crontab', False)
    cron_lines(sh('sudo -n crontab -l 2>/dev/null'), 'root:crontab', False)
    try: cron_lines(open('/etc/crontab').read(), 'etc:crontab', True)
    except Exception: pass
    for f in sorted(os.listdir('/etc/cron.d')) if os.path.isdir('/etc/cron.d') else []:
        try: cron_lines(open('/etc/cron.d/' + f).read(), 'cron.d:' + f, True)
        except Exception: pass
    for scope in ('', '--user'):
        try: timers = json.loads(sh(f'systemctl {scope} list-timers --all --no-pager --output=json 2>/dev/null') or '[]')
        except Exception: timers = []
        for t in timers:
            svc = t.get('activates') or ''
            props = dict(l.split('=', 1) for l in sh(f'systemctl {scope} show {svc} -p Result,ExecMainStatus,ExecMainExitTimestamp,ActiveState,FragmentPath,Description --timestamp=unix').splitlines() if '=' in l)
            frag = props.get('FragmentPath', '')
            ts = lambda v: (v / 1e6) if isinstance(v, (int, float)) and v > 0 else None
            exit_ts = props.get('ExecMainExitTimestamp', '').lstrip('@')
            j = {"kind": "timer", "id": f"timer:{scope or 'system'}:{t.get('unit')}", "name": (t.get('unit') or '').replace('.timer', ''), "unit": t.get('unit'),
                 "service": svc, "command": props.get('Description', ''), "user": 'user' if scope else 'root', "enabled": True,
                 "next": ts(t.get('next')), "last": ts(t.get('last')) or (float(exit_ts) if exit_ts.replace('.', '').isdigit() else None),
                 "status": "running" if props.get('ActiveState') == 'activating' else ("ok" if props.get('Result') == 'success' and props.get('ExecMainStatus', '0') == '0' else ("failed" if props.get('Result') not in (None, '', 'success') or props.get('ExecMainStatus', '0') not in ('0', '') else "")),
                 "detail": "" if props.get('Result') in (None, '', 'success') else f"Result={props.get('Result')} exit={props.get('ExecMainStatus')}",
                 "system": frag.startswith(('/lib/', '/usr/lib/')) or any(n in (t.get('unit') or '') for n in sysnames + ('fstrim', 'zram', 'tmpfiles'))}
            jobs.append(j)
    for home in [os.path.expanduser('~/.hermes')] + [os.path.join(os.path.expanduser('~/.hermes/profiles'), d) for d in (os.listdir(os.path.expanduser('~/.hermes/profiles')) if os.path.isdir(os.path.expanduser('~/.hermes/profiles')) else [])]:
        jf = os.path.join(home, 'cron', 'jobs.json')
        if not os.path.exists(jf): continue
        try: data = json.load(open(jf))
        except Exception: continue
        hist = {}
        try:
            import sqlite3
            c = sqlite3.connect('file:' + os.path.join(home, 'cron', 'executions.db') + '?mode=ro', uri=True)
            for job_id, status, started, finished, err in c.execute("SELECT job_id, status, started_at, finished_at, substr(COALESCE(error,''),1,200) FROM executions ORDER BY started_at DESC LIMIT 300"):
                hist.setdefault(job_id, [])
                if len(hist[job_id]) < 8: hist[job_id].append([started, finished, status, err])
        except Exception: pass
        profile = 'default' if home.endswith('.hermes') else os.path.basename(home)
        for jb in data.get('jobs', []) if isinstance(data, dict) else data:
            sch = jb.get('schedule') or {}
            jobs.append({"kind": "hermes", "id": f"hermes:{profile}:{jb.get('id')}", "name": jb.get('name') or jb.get('id'), "profile": profile,
                         "expr": sch.get('expr') or '', "schedule": jb.get('schedule_display') or sch.get('display') or '', "enabled": bool(jb.get('enabled', True)) and not jb.get('paused_at'),
                         "state": jb.get('state') or '', "nextISO": jb.get('next_run_at'), "lastISO": jb.get('last_run_at'), "status": {"ok": "ok", "success": "ok", "completed": "ok", "failed": "failed", "error": "failed"}.get(str(jb.get('last_status') or '').lower(), str(jb.get('last_status') or '')),
                         "detail": (jb.get('last_error') or jb.get('last_delivery_error') or '')[:240], "failureStreak": jb.get('failure_streak') or 0,
                         "workdir": jb.get('workdir') or '', "history": hist.get(jb.get('id'), []), "system": False})
    o["jobs"] = jobs
    o["failed"] = [l.split()[0] for l in sh("systemctl --failed --no-legend --plain 2>/dev/null; systemctl --user --failed --no-legend --plain 2>/dev/null").splitlines() if l.strip()]
    # cloudflared tunnel metrics (Prometheus endpoint on localhost)
    if 'cloudflared' in sh('ps -eo comm'):
        ports = set(re.findall(r'127\.0\.0\.1:(\d+).*cloudflared', sh('sudo -n ss -ltnp 2>/dev/null')))
        for port in sorted(ports) or ['20241']:
            txt = sh(f'curl -s -m 3 http://127.0.0.1:{port}/metrics', 5)
            if 'cloudflared_tunnel' not in txt: continue
            g = lambda n: sum(float(m) for m in re.findall(r'^%s(?:\{[^}]*\})? ([0-9.e+]+)$' % n, txt, re.M))
            codes = {m[0]: float(m[1]) for m in re.findall(r'^cloudflared_tunnel_response_by_code\{status_code="(\d+)"\} ([0-9.e+]+)$', txt, re.M)}
            hosts = []
            for f in ('/etc/cloudflared/config.yml', os.path.expanduser('~/.cloudflared/config.yml')):
                try: hosts += re.findall(r'hostname:\s*(\S+)', open(f).read())
                except Exception: pass
            o["tunnel"] = {"port": int(port), "total": g('cloudflared_tunnel_total_requests'), "errors": g('cloudflared_tunnel_request_errors'),
                           "ha": g('cloudflared_tunnel_ha_connections'), "concurrent": g('cloudflared_tunnel_concurrent_requests_per_tunnel'),
                           "codes": codes, "hosts": sorted(set(hosts))}
            break
    if __SLOW__:
        hw = {}
        try: hw["model"] = open('/proc/device-tree/model').read().strip('\x00 \n')
        except Exception:
            try: hw["model"] = (open('/sys/class/dmi/id/sys_vendor').read().strip() + ' ' + open('/sys/class/dmi/id/product_name').read().strip()).strip()
            except Exception: pass
        try: hw["os"] = re.search(r'PRETTY_NAME="([^"]+)"', open('/etc/os-release').read()).group(1)
        except Exception: pass
        cpu = sh('lscpu')
        m = re.search(r'Model name:\s*(.+)', cpu); mh = re.search(r'CPU max MHz:\s*([\d.]+)', cpu)
        hw["cpu"] = ((m.group(1).strip() if m else '') + (f" @ {float(mh.group(1))/1000:.1f} GHz" if mh else '')).strip()
        hw["kernel"] = os.uname().release
        hw["storage"] = []
        for l in sh('lsblk -dno NAME,SIZE,TRAN,MODEL').splitlines():
            f = l.split(None, 3)
            if not f or f[0].startswith(('loop', 'zram', 'ram')): continue
            kind = 'microSD' if f[0].startswith('mmcblk') else 'NVMe' if f[0].startswith('nvme') else ('USB ' if len(f) > 2 and f[2] == 'usb' else '') + 'disk'
            hw["storage"].append(f"{kind} {f[1] if len(f) > 1 else ''}" + (f" ({f[3].strip()})" if len(f) > 3 else ''))
        o["hw"] = hw
        up = sh('apt list --upgradable 2>/dev/null', 20).splitlines()
        o["updates"] = sum(1 for l in up if '/' in l)
        o["security"] = sum(1 for l in up if '-security' in l)
        o["sshFails"] = len(re.findall(r'Failed password|Invalid user|authentication failure',
                                       sh("sudo -n journalctl --since '-24h' -u ssh -u sshd --no-pager 2>/dev/null", 15)))
        o["reboot"] = os.path.exists('/var/run/reboot-required')
    print(json.dumps(o))
    RAPHAEL_PY
    """#

    /// macOS: same fields where they exist.
    nonisolated static let macScript = #"""
    /usr/bin/python3 - <<'RAPHAEL_PY'
    import json, os, re, subprocess, shutil, time
    def sh(c, t=8):
        try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
        except Exception: return ""
    o = {"cores": os.cpu_count()}
    m = re.search(r'CPU usage: ([\d.]+)% user, ([\d.]+)% sys', sh('top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1', 6))
    o["cpu"] = (float(m.group(1)) + float(m.group(2))) / 100 if m else 0
    total = int(sh('sysctl -n hw.memsize') or 0); o["memTotal"] = total
    vm = sh('vm_stat'); ps = int(re.search(r'page size of (\d+)', vm).group(1)) if 'page size' in vm else 16384
    pages = {k.strip(): int(v.strip().rstrip('.')) for k, v in re.findall(r'^([^:]+):\s+(\d+)\.?$', vm, re.M)}
    used = (pages.get('Pages active', 0) + pages.get('Pages wired down', 0) + pages.get('Pages occupied by compressor', 0)) * ps
    o["mem"] = round(used / total, 4) if total else 0
    sw = re.search(r'used = ([\d.]+)M.*?free = ([\d.]+)M', sh('sysctl -n vm.swapusage'))
    o["swap"] = round(float(sw.group(1)) / max(float(sw.group(1)) + float(sw.group(2)), 1), 4) if sw else 0
    o["load"] = os.getloadavg()[0]
    bt = re.search(r'sec = (\d+)', sh('sysctl -n kern.boottime'))
    import time; o["uptime"] = time.time() - int(bt.group(1)) if bt else 0
    st = os.statvfs('/System/Volumes/Data') if os.path.exists('/System/Volumes/Data') else os.statvfs('/')
    o["disks"] = [["/", round(1 - st.f_bavail / max(st.f_blocks, 1), 4), round(st.f_blocks * st.f_frsize / 1e9, 1)]]
    rx = tx = 0
    for l in sh('netstat -ibn').splitlines()[1:]:
        p = l.split()
        if len(p) >= 10 and '<Link#' in p[2] and not p[0].startswith(('lo', 'utun', 'awdl', 'llw', 'bridge', 'gif', 'stf', 'anpi', 'ap')):
            rx += int(p[6]); tx += int(p[9])
    o["rx"], o["tx"] = rx, tx
    me = {os.getpid(), os.getppid()}
    def top(flag):
        out = []
        for l in sh(f'ps -Aceo pid,comm,%cpu,%mem {flag} | head -12').splitlines()[1:]:
            p = l.split()
            if len(p) >= 4:
                try: row = [int(p[0]), ' '.join(p[1:-2]), float(p[-2]), float(p[-1])]
                except Exception: continue
                if row[0] in me or row[1] in ('ps', 'sh', 'head', 'top'): continue
                out.append(row)
        return out[:5]
    o["topCPU"], o["topMem"] = top('-r'), top('-m')
    jobs = []
    o["tz"] = time.localtime().tm_gmtoff
    for raw in sh('crontab -l 2>/dev/null').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=', line): continue
        p = line.split()
        expr, rest = (p[0], p[1:]) if p[0].startswith('@') else (' '.join(p[:5]), p[5:])
        import hashlib
        if rest: jobs.append({"kind": "cron", "id": "cron:user:" + hashlib.sha1(line.encode()).hexdigest()[:10], "name": os.path.basename(rest[0])[:60], "expr": expr, "command": ' '.join(rest)[:300], "user": os.environ.get('USER', ''), "enabled": True, "system": False})
    import plistlib, glob
    for f in sorted(glob.glob(os.path.expanduser('~/Library/LaunchAgents/*.plist'))):
        try: pl = plistlib.load(open(f, 'rb'))
        except Exception: continue
        sched = pl.get('StartCalendarInterval'); interval = pl.get('StartInterval')
        if not sched and not interval: continue
        label = pl.get('Label', os.path.basename(f))
        info = sh(f'launchctl list {label} 2>/dev/null')
        m = re.search(r'"LastExitStatus" = (-?\d+);', info)
        code = int(m.group(1)) if m else None
        disp = f"tiap {interval // 3600} jam" if interval and interval % 3600 == 0 else (f"tiap {interval // 60} menit" if interval else json.dumps(sched))
        jobs.append({"kind": "launchd", "id": "launchd:" + label, "name": label, "schedule": disp, "command": ' '.join(pl.get('ProgramArguments', []) or [pl.get('Program', '')])[:300],
                     "enabled": not pl.get('Disabled', False), "loaded": bool(info), "status": "" if code is None else ("ok" if code == 0 else "failed"),
                     "detail": "" if not code else f"exit {code}", "system": label.startswith(('com.apple', 'com.google', 'com.microsoft', 'us.zoom'))})
    o["jobs"] = jobs
    if __SLOW__:
        sp = sh('system_profiler SPHardwareDataType', 15)
        g = lambda k: (re.search(k + r':\s*(.+)', sp) or [None, None])[1]
        name, ident = g('Model Name'), g('Model Identifier')
        years = {"MacBookAir10,1": "M1, 2020", "Mac14,2": "M2, 2022", "Mac14,15": "15-inch, M2, 2023", "Mac15,12": "M3, 2024", "Mac16,12": "M4, 2025"}
        ver = sh('sw_vers -productVersion').strip()
        o["hw"] = {"model": (name or 'Mac') + (f" ({years[ident]})" if ident in years else f" ({ident})" if ident else ''),
                   "cpu": (g('Chip') or g('Processor Name') or '') + (f" · {g('Total Number of Cores').split(' (')[0]} core" if g('Total Number of Cores') else ''),
                   "os": f"macOS {ver}", "kernel": os.uname().release,
                   "storage": [f"SSD {round(st.f_blocks * st.f_frsize / 1e9)} GB"]}
    print(json.dumps(o))
    RAPHAEL_PY
    """#
}
