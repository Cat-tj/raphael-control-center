import Foundation
import SQLite3

/// One value from a SQL row, the same whether it came from the local SQLite C API
/// or from a remote device's python3 (JSON).
struct SQLRow {
    let values: [Any?]
    func text(_ i: Int32) -> String {
        guard Int(i) < values.count, let v = values[Int(i)] else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }
    func int(_ i: Int32) -> Int {
        guard Int(i) < values.count, let v = values[Int(i)] else { return 0 }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? Int(Double(s) ?? 0) }
        return 0
    }
    func double(_ i: Int32) -> Double {
        guard Int(i) < values.count, let v = values[Int(i)] else { return 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
    func isNull(_ i: Int32) -> Bool { Int(i) >= values.count || values[Int(i)] == nil || values[Int(i)] is NSNull }
}

struct SQLQuery {
    let sql: String
    var args: [Any] = []
}

/// The device the Control Center is looking at: this Mac, or any node reachable
/// over SSH. Hermes data (stats, chat, SOUL, .env, memory, graphs), OmniRoute
/// and Tailscale are all read from — and actions run on — this device.
@MainActor
final class DeviceContext: ObservableObject {
    static let shared = DeviceContext()

    static let allId = "all"

    /// "all" (fleet overview) or a node id.
    @Published var currentId: String = UserDefaults.standard.string(forKey: "raphaelDevice") ?? DeviceContext.allId {
        didSet {
            UserDefaults.standard.set(currentId, forKey: "raphaelDevice")
            endpointCache = nil
            NotificationCenter.default.post(name: .raphaelDeviceChanged, object: nil)
        }
    }
    @Published var endpointCache: HermesConfig.Endpoint?

    var isAll: Bool { currentId == Self.allId || selected == nil }

    /// The chosen device, or nil for "Semua device".
    var selected: RNode? { NodeStore.shared.nodes.first { $0.id == currentId } }

    /// Device used for single-device work (new chat, editing files): the chosen one, else this Mac.
    var current: RNode {
        selected ?? NodeStore.shared.nodes.first { $0.isLocal } ?? RNode(id: "mac", name: "Mac ini", kind: "mac", ssh: "")
    }

    var scopeName: String { selected?.name ?? "Semua device" }

    /// Nodes the pages show: every node, or just the chosen one.
    var scope: [RNode] { selected.map { [$0] } ?? NodeStore.shared.nodes }

    /// Whether a node runs something (hermes, omniroute, tailscale, docker), from its last probe.
    func has(_ cap: String, _ node: RNode) -> Bool {
        if let caps = NodeStore.shared.status[node.id]?.caps, !caps.isEmpty { return caps.contains(cap) }
        if node.isLocal {
            switch cap {
            case "hermes": return HermesConfig.endpoint() != nil || FileManager.default.fileExists(atPath: HermesConfig.home.appendingPathComponent("state.db").path)
            case "tailscale": return TailscaleStore.cli != nil
            default: return false
            }
        }
        return false
    }

    /// Hermes installs in scope (aggregated in "Semua device"). A retired install (its
    /// history was migrated elsewhere) only shows when that device is picked on its own,
    /// so "Semua device" never counts the same sessions twice.
    var hermesNodes: [RNode] { scope.filter { has("hermes", $0) && (selected != nil || !Self.retiredHermes.contains($0.id)) } }

    /// The device whose Hermes new chats go to (UserDefaults "raphaelPrimaryHermes").
    static var primaryHermesId: String {
        UserDefaults.standard.string(forKey: "raphaelPrimaryHermes")
            ?? NodeStore.shared.nodes.first { !$0.isLocal && shared.has("hermes", $0) }?.id ?? "mac"
    }
    /// Devices whose Hermes was migrated away (UserDefaults "raphaelRetiredHermes").
    static var retiredHermes: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "raphaelRetiredHermes") ?? []) }

    /// Hermes home on the device ("~" is expanded on the device itself).
    nonisolated static func hermesHome(_ node: RNode) -> String { node.isLocal ? HermesConfig.home.path : "~/.hermes" }

    // MARK: Shell + files

    nonisolated static func run(_ node: RNode, _ script: String, timeout: TimeInterval = 30) async -> (output: String, exitCode: Int32) {
        await NodeStore.run(node: node, script: script, timeout: timeout)
    }

    nonisolated static func readFile(_ node: RNode, _ path: String) async -> String {
        if node.isLocal { return (try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)) ?? "" }
        let r = await run(node, "cat \(remotePath(path)) 2>/dev/null", timeout: 20)
        return r.output
    }

    /// Writes with a rolling `.raphael.bak` copy and the original permissions (local or remote).
    nonisolated static func writeFile(_ node: RNode, _ path: String, _ text: String) async -> Bool {
        await writeFileResult(node, path, text) == nil
    }

    /// nil on success, else a short reason (SSH error, Python exception…). Retries once when SSH itself fails.
    nonisolated static func writeFileResult(_ node: RNode, _ path: String, _ text: String) async -> String? {
        if node.isLocal {
            return KnowledgeStore.write(text, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) ? nil : "tidak bisa menulis \(path)"
        }
        let b64 = Data(text.utf8).base64EncodedString()
        let py = """
        import base64, os, shutil, stat, sys
        p = os.path.expanduser(\(pyString(path)))
        mode = stat.S_IMODE(os.stat(p).st_mode) if os.path.exists(p) else 0o600
        if os.path.exists(p): shutil.copy2(p, p + '.raphael.bak')
        tmp = p + '.raphael.tmp'
        with open(tmp, 'wb') as f: f.write(base64.b64decode('\(b64)'))
        os.chmod(tmp, mode); os.replace(tmp, p); print('OK')
        """
        let script = "python3 - <<'RAPHAEL_PY'\n\(py)\nRAPHAEL_PY"
        var r = await run(node, script, timeout: 30)
        if r.exitCode == 255 || r.exitCode == 15 { r = await run(node, script, timeout: 45) }   // SSH dropped / timed out
        if r.output.contains("OK") { return nil }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if r.exitCode == 15 { return "timeout ke \(node.name)" }
        return lines.last.map { String($0.prefix(160)) } ?? "\(node.name) tidak menjawab (exit \(r.exitCode))"
    }

    nonisolated static func listDir(_ node: RNode, _ path: String) async -> [String] {
        if node.isLocal {
            return ((try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).expandingTildeInPath)) ?? []).sorted()
        }
        let r = await run(node, "ls -1A \(remotePath(path)) 2>/dev/null", timeout: 20)
        return r.output.split(separator: "\n").map(String.init).sorted()
    }

    /// `~/x y` → `~/'x y'` so the remote shell still expands the tilde.
    nonisolated static func remotePath(_ p: String) -> String {
        p.hasPrefix("~/") ? "~/" + NodeStore.shellQuote(String(p.dropFirst(2))) : NodeStore.shellQuote(p)
    }

    nonisolated static func pyString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())   // a JSON string literal is a valid Python literal
    }

    // MARK: Hermes state.db

    /// Runs several read-only queries against the device's ~/.hermes/state.db in one go
    /// (one SSH round trip for remote devices).
    nonisolated static func sql(_ node: RNode, _ queries: [SQLQuery], db: String = "state.db") async -> [[SQLRow]] {
        if node.isLocal {
            return localSQL(HermesConfig.home.appendingPathComponent(db).path, queries)
        }
        let payload: [[Any]] = queries.map { [$0.sql, $0.args] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return [] }
        let py = """
        import base64, json, os, sqlite3
        qs = json.loads(base64.b64decode('\(data.base64EncodedString())'))
        p = os.path.expanduser('~/.hermes/\(db)')
        out = []
        try:
            c = sqlite3.connect('file:' + p + '?mode=ro', uri=True, timeout=5)
            for sql, args in qs:
                try: out.append([list(r) for r in c.execute(sql, args).fetchall()])
                except Exception: out.append([])
        except Exception:
            out = [[] for _ in qs]
        print(json.dumps(out, default=str))
        """
        let r = await run(node, "python3 - <<'RAPHAEL_PY'\n\(py)\nRAPHAEL_PY", timeout: 40)
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[[Any]]] else {
            return queries.map { _ in [] }
        }
        return json.map { rows in rows.map { SQLRow(values: $0.map { $0 is NSNull ? nil : $0 }) } }
    }

    nonisolated static func localSQL(_ path: String, _ queries: [SQLQuery]) -> [[SQLRow]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return queries.map { _ in [] } }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return queries.map { q in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, q.sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, a) in q.args.enumerated() {
                let idx = Int32(i + 1)
                if let d = a as? Double { sqlite3_bind_double(stmt, idx, d) }
                else if let n = a as? Int { sqlite3_bind_int64(stmt, idx, Int64(n)) }
                else if let s = a as? String { sqlite3_bind_text(stmt, idx, s, -1, transient) }
            }
            var rows: [SQLRow] = []
            let cols = sqlite3_column_count(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var vals: [Any?] = []
                for c in 0..<cols {
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_NULL: vals.append(nil)
                    case SQLITE_INTEGER: vals.append(NSNumber(value: sqlite3_column_int64(stmt, c)))
                    case SQLITE_FLOAT: vals.append(NSNumber(value: sqlite3_column_double(stmt, c)))
                    default: vals.append(sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "")
                    }
                }
                rows.append(SQLRow(values: vals))
            }
            return rows
        }
    }

    // MARK: Hermes endpoint on the device

    /// The device's Hermes chat endpoint, with 127.0.0.1/localhost rewritten to the
    /// device's address so this Mac can reach it (e.g. OmniRoute on RasPi over Tailscale).
    nonisolated static func endpoint(_ node: RNode) async -> HermesConfig.Endpoint? {
        if node.isLocal { return HermesConfig.endpoint() }
        let r = await run(node, "cat ~/.hermes/config.yaml; echo '__RAPHAEL_ENV__'; cat ~/.hermes/.env 2>/dev/null; echo '__RAPHAEL_SERVE__'; tailscale serve status 2>/dev/null", timeout: 20)
        let serveParts = r.output.components(separatedBy: "__RAPHAEL_SERVE__")
        let parts = serveParts[0].components(separatedBy: "__RAPHAEL_ENV__")
        guard let yaml = parts.first else { return nil }
        let block = HermesConfig.topLevelBlock(named: "model", in: yaml)
        guard var base = block["base_url"], !base.isEmpty else { return nil }
        if let published = Self.tailscaleServeURL(for: base, status: serveParts.count > 1 ? serveParts[1] : "") {
            base = published      // e.g. https://pi.tailnet.ts.net:20128 (only HTTPS answers on the tailnet)
        } else {
            for local in ["127.0.0.1", "localhost", "0.0.0.0"] { base = base.replacingOccurrences(of: "//\(local)", with: "//\(node.host)") }
        }
        let env = HermesConfig.parseEnv(parts.count > 1 ? parts[1] : "")
        return HermesConfig.Endpoint(baseURL: LocalChat.normaliseURL(base),
                                     apiKey: HermesConfig.resolve(block["api_key"] ?? "", env: env),
                                     model: block["default"] ?? "default")
    }
}

extension DeviceContext {
    /// The `tailscale serve` URL that proxies a device-local URL, keeping its path:
    /// "https://pi.x.ts.net:20128 (tailnet only)\n|-- / proxy http://127.0.0.1:20128".
    nonisolated static func tailscaleServeURL(for local: String, status: String) -> String? {
        guard let u = URLComponents(string: local), let port = u.port,
              ["127.0.0.1", "localhost", "0.0.0.0"].contains(u.host ?? "") else { return nil }
        var front: String?
        for line in status.split(separator: "\n").map(String.init) {
            if line.hasPrefix("https://") || line.hasPrefix("http://") { front = line.split(separator: " ").first.map(String.init) }
            else if let f = front, line.contains("proxy"), line.contains("/") ,
                    let target = line.split(separator: " ").last, let t = URLComponents(string: String(target)), t.port == port,
                    line.contains("|-- / ") {
                return f.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + u.path
            }
        }
        return nil
    }
}

extension Notification.Name {
    static let raphaelDeviceChanged = Notification.Name("raphaelDeviceChanged")
}
