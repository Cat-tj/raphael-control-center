import Foundation

struct CFDay: Identifiable, Hashable {
    var id: String { date }
    let date: String
    let requests: Int
    let visitors: Int
    let bytes: Double
    let cached: Int
    let threats: Int
    let pageViews: Int
}

struct CFZone: Identifiable, Hashable {
    let id: String
    let name: String
    var days: [CFDay] = []
    var countries: [(String, Int)] = []
    var statuses: [(Int, Int)] = []

    static func == (a: CFZone, b: CFZone) -> Bool { a.id == b.id && a.days == b.days }
    func hash(into h: inout Hasher) { h.combine(id) }

    var requests: Int { days.reduce(0) { $0 + $1.requests } }
    var visitors: Int { days.reduce(0) { $0 + $1.visitors } }
    var bytes: Double { days.reduce(0) { $0 + $1.bytes } }
    var cachedRatio: Double { requests > 0 ? Double(days.reduce(0) { $0 + $1.cached }) / Double(requests) : 0 }
    var threats: Int { days.reduce(0) { $0 + $1.threats } }
}

/// Website traffic from Cloudflare's GraphQL Analytics API (7 days, per zone).
/// Token: Keychain "cloudflare-analytics-token", else CLOUDFLARE_API_TOKEN from the
/// primary Hermes device's .env. It needs the "Zone · Analytics · Read" permission.
@MainActor
final class CloudflareStore: ObservableObject {
    static let shared = CloudflareStore()
    enum State: Equatable { case idle, loading, ok, noToken, noPermission, error(String) }

    @Published private(set) var zones: [CFZone] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var loadedAt: Date?

    static let keychainKey = "cloudflare-analytics-token"

    func setToken(_ t: String) {
        KeychainStore.shared.set(Self.keychainKey, value: t.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh()
    }

    func refresh() {
        guard state != .loading else { return }
        state = .loading
        Task {
            let token = await Self.token()
            guard let token, !token.isEmpty else { state = .noToken; return }
            do {
                let zones = try await Self.load(token: token)
                self.zones = zones
                state = .ok
                loadedAt = Date()
            } catch CFError.permission {
                state = .noPermission
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    enum CFError: Error { case permission, api(String) }

    private static func token() async -> String? {
        if let t = KeychainStore.shared.get(keychainKey), !t.isEmpty { return t }
        let node = NodeStore.shared.nodes.first { $0.id == DeviceContext.primaryHermesId } ?? DeviceContext.shared.current
        let env = await DeviceContext.readFile(node, node.isLocal ? HermesConfig.home.appendingPathComponent(".env").path : "~/.hermes/.env")
        return HermesConfig.parseEnv(env)["CLOUDFLARE_API_TOKEN"]
    }

    private static func call(_ token: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4" + path)!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CFError.api("respons tidak valid") }
        if let errs = j["errors"] as? [[String: Any]], !errs.isEmpty {
            let msg = errs.compactMap { $0["message"] as? String }.joined(separator: "; ")
            if msg.contains("permission") || msg.contains("authz") || (errs.first?["extensions"] as? [String: Any])?["code"] as? String == "authz" { throw CFError.permission }
            if j["data"] == nil || j["data"] is NSNull { throw CFError.api(msg) }
        }
        return j
    }

    static func load(token: String) async throws -> [CFZone] {
        let list = try await call(token, "/zones?per_page=50&status=active")
        let zones = (list["result"] as? [[String: Any]] ?? []).compactMap { z -> CFZone? in
            guard let id = z["id"] as? String, let name = z["name"] as? String else { return nil }
            return CFZone(id: id, name: name)
        }
        let since = ISO8601DateFormatter.string(from: Date().addingTimeInterval(-6 * 86400), timeZone: .current, formatOptions: [.withFullDate])
        var out: [CFZone] = []
        for var z in zones {
            let q = """
            { viewer { zones(filter: {zoneTag: "\(z.id)"}) { httpRequests1dGroups(limit: 7, orderBy: [date_ASC], filter: {date_geq: "\(since)"}) {
              dimensions { date } uniq { uniques }
              sum { requests bytes cachedRequests threats pageViews
                    countryMap { clientCountryName requests } responseStatusMap { edgeResponseStatus requests } } } } } }
            """
            let j = try await call(token, "/graphql", body: ["query": q])
            let groups = (((j["data"] as? [String: Any])?["viewer"] as? [String: Any])?["zones"] as? [[String: Any]])?.first?["httpRequests1dGroups"] as? [[String: Any]] ?? []
            var countries: [String: Int] = [:], statuses: [Int: Int] = [:]
            for g in groups {
                let sum = g["sum"] as? [String: Any] ?? [:]
                func n(_ k: String) -> Int { (sum[k] as? NSNumber)?.intValue ?? 0 }
                z.days.append(CFDay(date: ((g["dimensions"] as? [String: Any])?["date"] as? String) ?? "",
                                    requests: n("requests"), visitors: ((g["uniq"] as? [String: Any])?["uniques"] as? NSNumber)?.intValue ?? 0,
                                    bytes: (sum["bytes"] as? NSNumber)?.doubleValue ?? 0, cached: n("cachedRequests"),
                                    threats: n("threats"), pageViews: n("pageViews")))
                for c in sum["countryMap"] as? [[String: Any]] ?? [] {
                    countries[c["clientCountryName"] as? String ?? "?", default: 0] += (c["requests"] as? NSNumber)?.intValue ?? 0
                }
                for s in sum["responseStatusMap"] as? [[String: Any]] ?? [] {
                    statuses[(s["edgeResponseStatus"] as? NSNumber)?.intValue ?? 0, default: 0] += (s["requests"] as? NSNumber)?.intValue ?? 0
                }
            }
            z.countries = countries.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
            z.statuses = statuses.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            out.append(z)
        }
        return out.sorted { $0.requests > $1.requests }
    }
}
