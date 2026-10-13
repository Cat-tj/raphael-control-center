import Foundation

enum AppLocation: String, CaseIterable, Identifiable {
    case server = "Server", cloud = "Cloud", local = "Lokal"
    var id: String { rawValue }
    var icon: String { self == .server ? "server.rack" : self == .cloud ? "cloud" : "laptopcomputer" }
}

enum AppRun: String, CaseIterable, Identifiable {
    case running = "Berjalan", issue = "Bermasalah", stopped = "Tidak berjalan", unknown = "Belum dicek"
    var id: String { rawValue }
}

enum AppKind: String {
    case compose = "Docker", service = "Service", staticSite = "Static", vercel = "Vercel", n8n = "n8n",
         local = "Project lokal", website = "Website"
    var icon: String {
        switch self {
        case .compose: "shippingbox.fill"
        case .service: "gearshape.2.fill"
        case .staticSite: "doc.richtext.fill"
        case .vercel: "triangle.fill"
        case .n8n: "point.3.filled.connected.trianglepath.dotted"
        case .local: "hammer.fill"
        case .website: "globe"
        }
    }
}

/// One thing to watch: an app made of domains, containers/services, a deployment, a repo.
struct MApp: Identifiable, Hashable {
    let id: String
    var name: String
    let kind: AppKind
    let location: AppLocation
    var node: String?                  // device id for server / local apps
    var urls: [String] = []
    var containers: [String] = []
    var services: [String] = []        // unit names
    var dir: String?
    var vercel: VProject?
    var repo: String?
    var local: LocalProject?
    var n8n: N8nInstance?
    var note: String?

    static func == (a: MApp, b: MApp) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Status + figures of an app, computed from the stores.
struct MAppStatus {
    var run: AppRun = .unknown
    var issues: [String] = []
    var uptime: Double?                // 0…1 over the site checks kept
    var latency: Int?                  // last ms
    var cpu: Double?                   // % (sum of components)
    var mem: Double?                   // bytes
    var sslDays: Int?
}

/// Builds the app list from what the monitor, Vercel, GitHub, local scan and n8n know.
@MainActor
enum AppCatalog {
    /// Services that are infrastructure, not apps (matched by name fragment).
    static let infraFragments = ["omniroute", "hermes", "vnc", "cloudflared", "tailscale", "caddy", "nginx", "whatsapp-qr", "9router",
                                 "docker", "containerd", "ssh", "samba", "smb", "nmb", "winbind", "postgresql"]
    static func isInfra(_ name: String) -> Bool { infraFragments.contains { name.contains($0) } }

    struct Overrides: Codable { var names: [String: String] = [:]; var hidden: Set<String> = [] }
    static var overridesURL: URL { NodeStore.supportDir.appendingPathComponent("apps.json") }
    static var overrides: Overrides {
        get { (try? JSONDecoder().decode(Overrides.self, from: Data(contentsOf: overridesURL))) ?? Overrides() }
        set { try? JSONEncoder().encode(newValue).write(to: overridesURL, options: .atomic) }
    }

    static func build() -> [MApp] {
        let mon = MonitorStore.shared, nodes = NodeStore.shared.nodes
        var apps: [String: MApp] = [:]
        var byURLHost: [String: String] = [:]          // host → app id

        func pretty(_ s: String) -> String {
            s.replacingOccurrences(of: "-app", with: "").replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        func attach(_ host: String, to id: String) {
            let url = "https://" + host
            if apps[id]?.urls.contains(url) == false { apps[id]?.urls.append(url) }
            byURLHost[host.lowercased()] = id
        }

        // 1. Docker compose projects and custom services, per server.
        for n in nodes where !n.isLocal {
            guard let d = mon.detail[n.id] else { continue }
            for c in d.containers {
                let proj = c.project.isEmpty ? c.name : c.project
                let id = "compose:\(n.id):\(proj)"
                if apps[id] == nil { apps[id] = MApp(id: id, name: pretty(proj), kind: .compose, location: .server, node: n.id, dir: c.dir.isEmpty ? nil : c.dir) }
                apps[id]?.containers.append(c.name)
            }
            for s in d.services where !isInfra(s.name) {
                let id = "svc:\(n.id):\(s.name)"
                apps[id] = MApp(id: id, name: pretty(s.name), kind: .service, location: .server, node: n.id, services: [s.unit],
                                dir: s.dir.isEmpty || s.dir == "/" ? nil : s.dir, note: s.desc.isEmpty ? nil : s.desc)
            }
        }

        // 2. Caddy routes (+ the Cloudflare tunnel hostnames that reach the catch-all site).
        for n in nodes where !n.isLocal {
            guard let d = mon.detail[n.id], !d.routes.isEmpty else { continue }
            let named = Set(d.routes.flatMap { $0.hosts.compactMap { $0.components(separatedBy: ":").first }.filter { !$0.isEmpty } })
            for r in d.routes {
                var hosts = r.hosts.compactMap { $0.components(separatedBy: ":").first }.filter { !$0.isEmpty }
                if hosts.isEmpty { hosts = (d.tunnel?.hosts ?? []).filter { !named.contains($0) } }      // ":80" catch-all
                // What answers behind the proxy: a container, a custom service, or nothing.
                var backend: String?, missing: String?
                if let proxy = r.proxy, let colon = proxy.lastIndex(of: ":"), let port = Int(proxy[proxy.index(after: colon)...]) {
                    let ip = String(proxy[..<colon]).replacingOccurrences(of: "http://", with: "")
                    let target = ["127.0.0.1", "localhost"].contains(ip) ? n : nodes.first { mon.detail[$0.id]?.ips.contains(ip) == true || $0.host == ip }
                    if let t = target, let td = mon.detail[t.id] {
                        if let c = td.containers.first(where: { $0.ports.contains(port) }) {
                            backend = "compose:\(t.id):\(c.project.isEmpty ? c.name : c.project)"
                        } else if let l = td.listen[port], let sv = td.services.first(where: { $0.pid == l.pid && l.pid > 0 }), !isInfra(sv.name) {
                            backend = "svc:\(t.id):\(sv.name)"
                        } else if td.listen[port] == nil {
                            missing = "Caddy meneruskan ke \(proxy), tapi tidak ada yang listen di port \(port) di \(t.name)"
                            // Likely meant: the published port closest to it.
                            if let guess = td.containers.flatMap({ c in c.ports.map { (c, $0) } }).min(by: { abs($0.1 - port) < abs($1.1 - port) }),
                               abs(guess.1 - port) <= 10 {
                                missing! += ". Mungkin maksudnya port \(guess.1) (\(guess.0.project.isEmpty ? guess.0.name : guess.0.project))"
                            }
                        }
                    }
                }
                var owner = backend
                if let root = r.root {
                    // A static site, with its API backend (if any) folded in.
                    let id = "static:\(n.id):\(hosts.first ?? root)"
                    var app = MApp(id: id, name: hosts.first ?? (root as NSString).lastPathComponent, kind: .staticSite,
                                   location: .server, node: n.id, dir: root)
                    if let b = backend, let be = apps.removeValue(forKey: b) {
                        app.services = be.services; app.containers = be.containers; app.note = "API: \(be.name)"
                        if be.node != n.id { app.node = be.node }
                    }
                    apps[id] = app
                    owner = id
                } else if owner == nil, let missing {
                    let id = "route:\(n.id):\(hosts.first ?? r.proxy ?? "?")"
                    apps[id] = MApp(id: id, name: hosts.first ?? "?", kind: .website, location: .server, node: n.id, note: missing)
                    owner = id
                }
                if let owner { for h in hosts { attach(h, to: owner) } }
            }
        }

        // 3. Vercel projects (merged into an app that already owns one of their domains).
        for p in VercelStore.shared.projects {
            let domains = p.domains.isEmpty ? (p.url.map { [URL(string: $0)?.host ?? $0] } ?? []) : p.domains
            if let existing = domains.compactMap({ byURLHost[$0.lowercased()] }).first {
                let repo = apps[existing]?.repo ?? p.repo; apps[existing]?.vercel = p; apps[existing]?.repo = repo; continue
            }
            let id = "vercel:\(p.id)"
            apps[id] = MApp(id: id, name: p.name, kind: .vercel, location: .cloud, vercel: p, repo: p.repo)
            for h in domains { attach(h, to: id) }
        }

        // 4. n8n instances.
        for inst in N8nStore.shared.instances {
            let host = URL(string: inst.url)?.host ?? inst.url
            let local = host.hasPrefix("192.168.") || host.hasPrefix("100.") || host == "localhost"
            apps["n8n:\(inst.id)"] = MApp(id: "n8n:\(inst.id)", name: "n8n · \(inst.name)", kind: .n8n, location: local ? .server : .cloud,
                                          urls: [inst.url], n8n: inst)
        }

        // 5. Saved websites not owned yet.
        for s in SiteStore.shared.sites {
            guard let host = URL(string: s.url)?.host?.lowercased() else { continue }
            if let owner = byURLHost[host] { if apps[owner]?.urls.contains(s.url) == false { apps[owner]?.urls.append(s.url) }; continue }
            if host.hasSuffix(".ts.net") || host.hasPrefix("100.") { continue }       // own dashboards
            let id = "site:\(host)"
            apps[id] = MApp(id: id, name: s.name, kind: .website, location: .cloud, urls: [s.url])
            byURLHost[host] = id
        }

        // 6. Local projects on this Mac (linked to their GitHub repo and Vercel project).
        let mac = nodes.first { $0.isLocal }?.id
        for p in LocalProjectsStore.shared.projects {
            if let i = apps.values.first(where: { $0.repo != nil && $0.repo?.lowercased() == p.repo?.lowercased() })?.id {
                apps[i]?.local = p
            }
            let id = "local:\(p.path)"
            apps[id] = MApp(id: id, name: p.name, kind: .local, location: .local, node: mac,
                            urls: p.ports.filter { $0 >= 1024 && $0 != 5037 }.map { "http://localhost:\($0)" }, dir: p.path, repo: p.repo, local: p)
        }

        let o = overrides
        return apps.values.compactMap { a in
            guard !o.hidden.contains(a.id) else { return nil }
            var a = a
            if let n = o.names[a.id] { a.name = n }
            a.urls = Array(Set(a.urls)).sorted { $0.count < $1.count }
            return a
        }
        .sorted { ($0.location.rawValue, $0.name.lowercased()) < ($1.location.rawValue, $1.name.lowercased()) }
    }

    /// URLs the website checker should poll (apps add their own domains).
    static func checkURLs(_ apps: [MApp]) -> [String] {
        apps.filter { $0.kind != .local }.flatMap(\.urls)
    }

    static func status(_ a: MApp) -> MAppStatus {
        let mon = MonitorStore.shared, sites = SiteStore.shared
        var st = MAppStatus()
        var parts: [Bool] = []          // each component: running ok?
        var issues: [String] = []
        let d = a.node.flatMap { mon.detail[$0] }
        if d?.error != nil, a.location == .server { issues.append("Server tidak terjangkau") }

        var cpu = 0.0, mem = 0.0, measured = false
        for name in a.containers {
            guard let c = d?.containers.first(where: { $0.name == name }) else { parts.append(false); issues.append("\(name): hilang"); continue }
            parts.append(c.healthy)
            if !c.healthy { issues.append("\(name): \(c.status)") } else if c.restarts > 3 { issues.append("\(name) restart \(c.restarts)×") }
            cpu += c.cpu; mem += c.memBytes; measured = true
        }
        for unit in a.services {
            guard let s = d?.services.first(where: { $0.unit == unit }) else { continue }
            parts.append(s.running)
            if !s.running { issues.append("\(s.name): \(s.state) (\(s.sub))") }
            if let p = mon.components["\(a.node ?? "")|s:\(unit)"]?.last { cpu += p.cpu }
            mem += s.mem; measured = true
        }
        if measured { st.cpu = cpu; st.mem = mem }

        var latencies: [Int] = [], checks: [SitePoint] = []
        for u in a.urls where a.kind != .local {
            if let s = sites.status[u] {
                parts.append(s.ok)
                if !s.ok { issues.append("\(URL(string: u)?.host ?? u): \(s.error ?? "HTTP \(s.code)")") } else if s.latencyMs > 2500 { issues.append("\(URL(string: u)?.host ?? u) lambat (\(s.latencyMs) ms)") }
                latencies.append(s.latencyMs)
            }
            checks += sites.history[u] ?? []
            if let exp = SiteStore.certExpiry(for: u) {
                let days = Int(exp.timeIntervalSinceNow / 86400)
                st.sslDays = min(st.sslDays ?? days, days)
                if days < 14 { issues.append("SSL \(URL(string: u)?.host ?? u) habis \(days) hari lagi") }
            }
        }
        if !checks.isEmpty { st.uptime = Double(checks.filter(\.ok).count) / Double(checks.count) }
        st.latency = latencies.max()

        if let v = a.vercel {
            parts.append(v.state == "READY")
            if let s = v.state, s != "READY" { issues.append("Deploy Vercel: \(s)") }
        }
        if let repo = GitHubStore.shared.repo(a.repo), repo.ci == "failure" { issues.append("CI GitHub gagal: \(repo.ciName ?? "")") }
        if let inst = a.n8n {
            if let e = N8nStore.shared.errors[inst.id] { parts.append(false); issues.append(e) }
            else if let wf = N8nStore.shared.workflows[inst.id] {
                parts.append(true)
                let failing = wf.filter { $0.errors > 0 }
                if !failing.isEmpty { issues.append("\(failing.count) workflow error 24 jam: " + failing.prefix(3).map(\.name).joined(separator: ", ")) }
            }
        }
        if let p = a.local, a.kind == .local {
            parts.append(p.running)
            st.run = p.running ? (issues.isEmpty ? .running : .issue) : .stopped
            st.issues = issues
            return st
        }
        if let note = a.note, a.kind == .website, a.urls.isEmpty || note.contains("tidak ada yang listen") { issues.append(note); parts.append(false) }

        if parts.isEmpty { st.run = .unknown }
        else if parts.allSatisfy({ !$0 }) { st.run = .stopped }
        else if !issues.isEmpty || parts.contains(false) { st.run = .issue }
        else { st.run = .running }
        st.issues = issues
        return st
    }
}
