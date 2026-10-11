import Foundation
import Security

/// OmniRoute (the LLM router Hermes talks to): provider topology, account
/// quotas and cost, read from its management API with a Bearer key.
struct ORInstance: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseURL: String     // root, e.g. http://127.0.0.1:20128
    /// The instance's web dashboard.
    var dashboardURL: String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/dashboard" }
}

struct ORConnection: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let active: Bool
    let testStatus: String
    let priority: Int
    let lastError: String?
}

struct ORProviderMetric: Identifiable, Hashable {
    var id: String { provider }
    let provider: String
    let requests: Int
    let successRate: Double
    let avgLatencyMs: Int
    let lastStatus: Int
    let lastRequestAt: Date?
    var state: String = ""          // healthy / degraded / down (health matrix)
}

struct ORQuotaWindow: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let used: Double
    let total: Double
    let remainingPct: Double
    let resetAt: Date?
}

struct ORAccountQuota: Identifiable, Hashable {
    let id: String              // connection id
    let account: String
    let provider: String
    let plan: String?
    let message: String?
    let windows: [ORQuotaWindow]
}

struct ORUsageRow: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
    let requests: Int
    let tokens: Int
    let cost: Double
}

struct ORDay: Identifiable, Hashable {
    var id: String { date }
    let date: String
    let requests: Int
    let tokens: Int
    let cost: Double
}

struct ORSnapshot {
    var reachable = false
    var error: String?
    var connections: [ORConnection] = []
    var metrics: [ORProviderMetric] = []
    var lastProvider = ""
    var errorProvider = ""
    var healthy = 0, degraded = 0, down = 0, modelCount = 0
    var quotas: [ORAccountQuota] = []
    var totalRequests = 0, totalTokens = 0, promptTokens = 0, completionTokens = 0
    var totalCost = 0.0, successRate = 0.0, avgLatencyMs = 0
    var since: Date?
    var days: [ORDay] = []
    var byModel: [ORUsageRow] = []
    var byProvider: [ORUsageRow] = []
    var byAccount: [ORUsageRow] = []
    var fetchedAt: Date?

    var todayCost: Double { days.last?.cost ?? 0 }
    var weekCost: Double { days.suffix(7).reduce(0) { $0 + $1.cost } }
    var weekTokens: Int { days.suffix(7).reduce(0) { $0 + $1.tokens } }

    /// Display name for a provider id (custom OpenAI-compatible ids → their connection name).
    func label(_ provider: String) -> String {
        if provider.hasPrefix("openai-compatible"), let c = connections.first(where: { $0.provider == provider }) {
            return c.name
        }
        return provider
    }
}

@MainActor
final class OmniRouteStore: ObservableObject {
    static let shared = OmniRouteStore()
    @Published var instances: [ORInstance] = []
    @Published var snapshots: [String: ORSnapshot] = [:]
    @Published var loading: Set<String> = []
    @Published var selected: String = "local"

    static var configURL: URL { NodeStore.supportDir.appendingPathComponent("omniroute.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.configURL),
           let saved = try? JSONDecoder().decode([ORInstance].self, from: data), !saved.isEmpty {
            instances = saved
        } else {
            let local = HermesConfig.endpoint()?.baseURL ?? "http://127.0.0.1:20128"
            // Other devices' OmniRoute instances are added when that device is opened (followDevice).
            instances = [ORInstance(id: "local", name: "Mac ini", baseURL: local)]
            save()
        }
        // The primary Hermes device's OmniRoute (the RasPi) is the one shown first.
        selected = instances.first(where: { $0.id == DeviceContext.primaryHermesId })?.id ?? instances.first?.id ?? "local"
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(instances).write(to: Self.configURL, options: .atomic)
    }

    var current: ORSnapshot? { snapshots[selected] }

    /// Per-instance key in the Keychain, else the key that device's Hermes uses.
    func key(for inst: ORInstance) async -> String {
        if let k = KeychainStore.shared.get("omniroute-key-\(inst.id)"), !k.isEmpty { return k }
        if inst.id == "local" { return HermesConfig.endpoint()?.apiKey ?? "" }
        if let node = NodeStore.shared.nodes.first(where: { $0.id == inst.id }),
           let ep = await DeviceContext.endpoint(node) { return ep.apiKey }
        return HermesConfig.endpoint()?.apiKey ?? ""
    }

    /// Follow the device switcher: the Mac shows its own OmniRoute, a RasPi its own.
    func followDevice() {
        let id = DeviceContext.shared.currentId
        let target = DeviceContext.shared.current.isLocal ? "local" : id
        if instances.contains(where: { $0.id == target }) {
            selected = target
        } else if !DeviceContext.shared.current.isLocal {
            let node = DeviceContext.shared.current
            Task {
                guard let ep = await DeviceContext.endpoint(node) else { return }
                let base = ep.baseURL.replacingOccurrences(of: "/v1", with: "")
                instances.append(ORInstance(id: node.id, name: node.name, baseURL: base))
                save()
                selected = node.id
                refresh(instances.last!)
            }
        }
    }

    func setKey(_ key: String, for inst: ORInstance) {
        KeychainStore.shared.set("omniroute-key-\(inst.id)", value: key)
        refresh(inst)
    }

    func refreshAll() { instances.forEach(refresh) }

    func refresh(_ inst: ORInstance) {
        guard !loading.contains(inst.id) else { return }
        loading.insert(inst.id)
        Task {
            let key = await key(for: inst)
            let snap = await Self.load(base: inst.baseURL, key: key)
            snapshots[inst.id] = snap
            loading.remove(inst.id)
        }
    }

    // MARK: Loading

    nonisolated private static func get(_ base: String, _ path: String, key: String) async -> (Any?, Int) {
        guard let url = URL(string: base + path) else { return (nil, 0) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (try? JSONSerialization.jsonObject(with: data), code)
    }

    nonisolated private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    nonisolated private static func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    nonisolated static func load(base: String, key: String) async -> ORSnapshot {
        var s = ORSnapshot()
        s.fetchedAt = Date()
        async let providersR = get(base, "/api/providers", key: key)
        async let metricsR = get(base, "/api/provider-metrics", key: key)
        async let matrixR = get(base, "/api/providers/health-matrix", key: key)
        async let limitsR = get(base, "/api/usage/provider-limits", key: key)
        async let analyticsR = get(base, "/api/usage/analytics", key: key)

        let (providers, code) = await providersR
        guard code == 200, let pj = providers as? [String: Any] else {
            s.error = code == 401 || code == 403 ? "API key ditolak. Masukkan key OmniRoute untuk instance ini."
                    : code == 0 ? "Tidak terjangkau di \(base)" : "HTTP \(code)"
            return s
        }
        s.reachable = true
        s.connections = (pj["connections"] as? [[String: Any]] ?? []).map { c in
            ORConnection(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "?",
                         provider: c["provider"] as? String ?? "?", active: c["isActive"] as? Bool ?? false,
                         testStatus: c["testStatus"] as? String ?? "", priority: Int(num(c["priority"])),
                         lastError: c["lastError"] as? String)
        }

        var states: [String: String] = [:]
        if let m = await matrixR.0 as? [String: Any] {
            let sum = m["summary"] as? [String: Any] ?? [:]
            s.healthy = Int(num(sum["healthyCount"])); s.degraded = Int(num(sum["degradedCount"]))
            s.down = Int(num(sum["downCount"])); s.modelCount = Int(num(sum["modelCount"]))
            for p in m["providers"] as? [[String: Any]] ?? [] {
                if let name = p["provider"] as? String { states[name] = p["state"] as? String ?? "" }
            }
        }
        if let m = await metricsR.0 as? [String: Any] {
            for (name, v) in m["metrics"] as? [String: Any] ?? [:] {
                guard let d = v as? [String: Any] else { continue }
                var row = ORProviderMetric(provider: name, requests: Int(num(d["totalRequests"])),
                                           successRate: num(d["successRate"]), avgLatencyMs: Int(num(d["avgLatencyMs"])),
                                           lastStatus: Int(num(d["lastStatus"])), lastRequestAt: date(d["lastRequestAt"]))
                row.state = states[name] ?? (row.successRate >= 90 ? "healthy" : row.successRate >= 70 ? "degraded" : "down")
                s.metrics.append(row)
            }
            s.metrics.sort { $0.requests > $1.requests }
            let topo = m["topology"] as? [String: Any] ?? [:]
            s.lastProvider = topo["lastProvider"] as? String ?? ""
            s.errorProvider = topo["errorProvider"] as? String ?? ""
        }
        if let l = await limitsR.0 as? [String: Any] {
            for (cid, v) in l["caches"] as? [String: Any] ?? [:] {
                guard let d = v as? [String: Any] else { continue }
                let conn = s.connections.first { $0.id == cid }
                var windows: [ORQuotaWindow] = []
                for (label, q) in d["quotas"] as? [String: Any] ?? [:] {
                    guard let q = q as? [String: Any] else { continue }
                    let used = num(q["used"]), total = num(q["total"])
                    let rem = q["remainingPercentage"] != nil ? num(q["remainingPercentage"])
                            : total > 0 ? max(0, (total - used) / total * 100) : 100
                    windows.append(ORQuotaWindow(label: (q["displayName"] as? String) ?? label, used: used, total: total,
                                                 remainingPct: rem, resetAt: date(q["resetAt"])))
                }
                windows.sort { $0.remainingPct < $1.remainingPct }
                s.quotas.append(ORAccountQuota(id: cid, account: conn?.name ?? String(cid.prefix(8)),
                                               provider: conn?.provider ?? "?", plan: d["plan"] as? String,
                                               message: d["message"] as? String, windows: windows))
            }
            s.quotas.sort { ($0.windows.isEmpty ? 1 : 0, $0.provider, $0.account) < ($1.windows.isEmpty ? 1 : 0, $1.provider, $1.account) }
        }
        if let a = await analyticsR.0 as? [String: Any] {
            let sum = a["summary"] as? [String: Any] ?? [:]
            s.totalRequests = Int(num(sum["totalRequests"])); s.totalTokens = Int(num(sum["totalTokens"]))
            s.promptTokens = Int(num(sum["promptTokens"])); s.completionTokens = Int(num(sum["completionTokens"]))
            s.totalCost = num(sum["totalCost"]); s.successRate = num(sum["successRatePct"])
            s.avgLatencyMs = Int(num(sum["avgLatencyMs"])); s.since = date(sum["firstRequest"])
            s.days = (a["dailyTrend"] as? [[String: Any]] ?? []).map {
                ORDay(date: $0["date"] as? String ?? "", requests: Int(num($0["requests"])),
                      tokens: Int(num($0["totalTokens"])), cost: num($0["cost"]))
            }
            func rows(_ key: String, name: String, detail: String) -> [ORUsageRow] {
                (a[key] as? [[String: Any]] ?? []).map {
                    ORUsageRow(name: $0[name] as? String ?? "?", detail: $0[detail] as? String ?? "",
                               requests: Int(num($0["requests"])), tokens: Int(num($0["totalTokens"])), cost: num($0["cost"]))
                }.sorted { $0.tokens > $1.tokens }
            }
            s.byModel = rows("byModel", name: "model", detail: "provider")
            s.byProvider = rows("byProvider", name: "provider", detail: "")
            s.byAccount = rows("byAccount", name: "account", detail: "")
        }
        return s
    }
}

// MARK: - Websites

struct RSite: Identifiable, Codable, Hashable {
    var id: String { url }
    var name: String
    var url: String
}

struct SitePoint: Equatable { let t: Double; let ms: Int; let ok: Bool }

struct RSiteStatus: Equatable {
    var code: Int = 0
    var latencyMs: Int = 0
    var error: String?
    var checkedAt: Date?
    var ok: Bool { error == nil && (200..<400).contains(code) }
}

/// HTTP checks from this Mac: saved websites plus every published port the
/// node probes discover (http://host:port).
@MainActor
final class SiteStore: ObservableObject {
    static let shared = SiteStore()
    @Published var sites: [RSite] = []
    @Published var status: [String: RSiteStatus] = [:]
    /// Response time per check (last 720 checks per site, in memory).
    @Published var history: [String: [SitePoint]] = [:]

    // TLS certificate expiry per host, captured while checking (any thread).
    nonisolated(unsafe) private static var certs: [String: Date] = [:]
    private static let certLock = NSLock()

    nonisolated static func recordCertificate(_ trust: SecTrust, host: String) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let n = entry[kSecPropertyKeyValue] as? NSNumber else { return }
        certLock.lock(); certs[host] = Date(timeIntervalSinceReferenceDate: n.doubleValue); certLock.unlock()
    }

    nonisolated static func certExpiry(for url: String) -> Date? {
        guard let host = URL(string: url)?.host else { return nil }
        certLock.lock(); defer { certLock.unlock() }
        return certs[host]
    }

    static var configURL: URL { NodeStore.supportDir.appendingPathComponent("websites.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.configURL),
           let saved = try? JSONDecoder().decode([RSite].self, from: data) {
            sites = saved
        } else {
            sites = []      // added in Aplikasi & Website; apps found on servers are watched automatically
            save()
        }
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(sites).write(to: Self.configURL, options: .atomic)
    }

    func add(name: String, url: String) {
        var u = url.trimmingCharacters(in: .whitespaces)
        if !u.hasPrefix("http") { u = "https://" + u }
        sites.append(RSite(name: name.isEmpty ? u : name, url: u)); save(); check(u)
    }

    func remove(_ site: RSite) { sites.removeAll { $0.url == site.url }; save() }

    /// Published ports discovered on nodes, as URLs.
    var discovered: [(node: RNode, app: RApp, url: String)] {
        NodeStore.shared.allApps.flatMap { pair in
            pair.app.ports.filter { ![22, 5432, 6379, 3306, 27017, 5672, 9000].contains($0) }.map { port -> (RNode, RApp, String) in
                let scheme = [443, 8443].contains(port) ? "https" : "http"
                return (pair.node, pair.app, "\(scheme)://\(pair.node.host):\(port)")
            }
        }
    }

    /// App domains the monitor watches besides the saved sites.
    var extra: [String] = []

    func checkAll() {
        sites.forEach { check($0.url) }
        discovered.forEach { check($0.url) }
        Set(extra).subtracting(sites.map(\.url)).forEach { check($0) }
    }

    func check(_ url: String) {
        guard let u = URL(string: url) else { return }
        Task {
            var req = URLRequest(url: u, timeoutInterval: 10)
            req.httpMethod = "GET"
            let t0 = Date()
            var st = RSiteStatus()
            do {
                let (_, resp) = try await SiteStore.session.data(for: req)
                st.code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                st.error = (error as NSError).localizedDescription
            }
            st.latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            st.checkedAt = Date()
            status[url] = st
            var h = history[url] ?? []
            h.append(SitePoint(t: Date().timeIntervalSince1970, ms: st.latencyMs, ok: st.ok))
            if h.count > 720 { h.removeFirst(h.count - 720) }
            history[url] = h
        }
    }

    /// Self-signed certs on LAN/Tailscale ports are fine for a liveness check.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg, delegate: TrustingDelegate(), delegateQueue: nil)
    }()

    final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                SiteStore.recordCertificate(trust, host: challenge.protectionSpace.host)
            }
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               let host = Optional(challenge.protectionSpace.host),
               host.hasPrefix("100.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host == "localhost" {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
