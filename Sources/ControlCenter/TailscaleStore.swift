import Foundation

struct TSPeer: Identifiable, Hashable {
    let id: String
    let name: String
    let dnsName: String
    let os: String
    let ip: String
    let online: Bool
    let isSelf: Bool
    let lastSeen: Date?
    let relay: String
    let direct: Bool          // has a direct (non-DERP) path
    let exitNode: Bool
    let rxBytes: Int64
    let txBytes: Int64
}

/// Tailscale connectivity from `tailscale status --json` on this Mac.
@MainActor
final class TailscaleStore: ObservableObject {
    static let shared = TailscaleStore()
    @Published var backend = ""
    @Published var tailnet = ""
    @Published var peers: [TSPeer] = []
    @Published var error: String?
    @Published var pings: [String: String] = [:]
    @Published var checkedAt: Date?

    static var cli: String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var onlineCount: Int { peers.filter(\.online).count }

    /// Runs the tailscale CLI on the current device (local binary, or `tailscale` over SSH).
    private func tailscale(_ args: [String], timeout: TimeInterval) async -> (output: String, exitCode: Int32) {
        let node = DeviceContext.shared.current
        if node.isLocal {
            guard let cli = Self.cli else { return ("Tailscale CLI tidak ditemukan", -1) }
            return await NodeStore.runProcess(cli, args, timeout: timeout)
        }
        return await NodeStore.run(node: node, script: "tailscale " + args.map(NodeStore.shellQuote).joined(separator: " "), timeout: timeout)
    }

    func refresh() {
        Task {
            let r = await tailscale(["status", "--json"], timeout: 10)
            guard let data = r.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Tailscale tidak menjawab" : String(r.output.prefix(200))
                return
            }
            error = nil
            backend = json["BackendState"] as? String ?? ""
            tailnet = (json["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? ""
            var out: [TSPeer] = []
            if let me = json["Self"] as? [String: Any] { out.append(Self.peer(me, isSelf: true)) }
            for (_, v) in (json["Peer"] as? [String: Any] ?? [:]) {
                if let p = v as? [String: Any] { out.append(Self.peer(p, isSelf: false)) }
            }
            peers = out.sorted { ($0.isSelf ? 0 : $0.online ? 1 : 2, $0.name.lowercased()) < ($1.isSelf ? 0 : $1.online ? 1 : 2, $1.name.lowercased()) }
            checkedAt = Date()
        }
    }

    func ping(_ peer: TSPeer) {
        pings[peer.id] = "…"
        Task {
            let r = await tailscale(["ping", "-c", "1", "--timeout", "5s", peer.ip], timeout: 10)
            let line = r.output.components(separatedBy: .newlines).last { $0.contains("pong") || $0.contains("timeout") || $0.contains("no reply") } ?? r.output
            if let range = line.range(of: #"via (.+) in (\d+ms)"#, options: .regularExpression) {
                pings[peer.id] = String(line[range])
            } else {
                pings[peer.id] = line.isEmpty ? "tidak ada balasan" : String(line.prefix(80))
            }
        }
    }

    private static let iso = ISO8601DateFormatter()

    private static func peer(_ p: [String: Any], isSelf: Bool) -> TSPeer {
        let ips = p["TailscaleIPs"] as? [String] ?? []
        let seen = (p["LastSeen"] as? String).flatMap { iso.date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) }
        let cur = p["CurAddr"] as? String ?? ""
        return TSPeer(id: p["ID"] as? String ?? (p["HostName"] as? String ?? UUID().uuidString),
                      name: p["HostName"] as? String ?? "?",
                      dnsName: (p["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                      os: p["OS"] as? String ?? "",
                      ip: ips.first(where: { !$0.contains(":") }) ?? ips.first ?? "",
                      online: isSelf ? true : (p["Online"] as? Bool ?? false),
                      isSelf: isSelf,
                      lastSeen: (seen?.timeIntervalSince1970 ?? 0) > 0 ? seen : nil,
                      relay: p["Relay"] as? String ?? "",
                      direct: !cur.isEmpty,
                      exitNode: p["ExitNode"] as? Bool ?? false,
                      rxBytes: (p["RxBytes"] as? NSNumber)?.int64Value ?? 0,
                      txBytes: (p["TxBytes"] as? NSNumber)?.int64Value ?? 0)
    }
}
