import Foundation

/// One coding-agent session, as recorded by the agent itself (never inferred from processes).
struct AgentSession: Identifiable, Hashable {
    let id: String              // "hermes:<device>:<session>" / "codex:<session>"
    let agent: String           // Hermes, Codex
    let runtime: String         // device / client
    let title: String
    let model: String?
    let startedAt: Date?
    let endedAt: Date?
    let lastActivity: Date?
    let tokens: Int?
    let costUSD: Double?
    let result: String?         // end reason / error
    let cwd: String
    let branch: String?
    var active: Bool { endedAt == nil && (lastActivity.map { Date().timeIntervalSince($0) < 300 } ?? false) }
    var duration: TimeInterval? { startedAt.map { (endedAt ?? lastActivity ?? Date()).timeIntervalSince($0) } }
}

@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loadedAt: Date?
    private var loading = false

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var all: [AgentSession] = []
        // Hermes on every device that has it (a retired install's history now lives elsewhere).
        let nodes = NodeStore.shared.nodes.filter { DeviceContext.shared.has("hermes", $0) && !DeviceContext.retiredHermes.contains($0.id) }
        await withTaskGroup(of: (String, [AgentSession], String?).self) { g in
            for n in nodes { g.addTask { let r = await Self.hermes(n); return (n.id, r.0, r.1) } }
            for await (id, list, err) in g { all += list; errors["hermes:\(id)"] = err }
        }
        all += await Task.detached { Self.codex() }.value
        sessions = all.sorted { ($0.lastActivity ?? $0.startedAt ?? .distantPast) > ($1.lastActivity ?? $1.startedAt ?? .distantPast) }
        loadedAt = Date()
        recordEvents()
    }

    nonisolated static func hermes(_ node: RNode) async -> ([AgentSession], String?) {
        let since = Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970
        let q = SQLQuery(sql: """
            SELECT id, COALESCE(title, ''), source, model, started_at, ended_at, end_reason, last_activity_at,
                   COALESCE(input_tokens,0) + COALESCE(output_tokens,0) + COALESCE(cache_read_tokens,0) + COALESCE(cache_write_tokens,0),
                   estimated_cost_usd, COALESCE(git_repo_root, cwd, ''), git_branch
            FROM sessions WHERE parent_session_id IS NULL AND started_at >= ? AND COALESCE(git_repo_root, cwd, '') <> ''
            ORDER BY started_at DESC LIMIT 400
            """, args: [since])
        let rows = await DeviceContext.sql(node, [q]).first ?? []
        let list = rows.map { r in
            AgentSession(id: "hermes:\(node.id):\(r.text(0))", agent: "Hermes", runtime: "\(node.name) · \(r.text(2))", title: r.text(1).isEmpty ? r.text(0) : r.text(1),
                         model: r.isNull(3) ? nil : r.text(3), startedAt: r.isNull(4) ? nil : Date(timeIntervalSince1970: r.double(4)),
                         endedAt: r.isNull(5) ? nil : Date(timeIntervalSince1970: r.double(5)), lastActivity: r.isNull(7) ? nil : Date(timeIntervalSince1970: r.double(7)),
                         tokens: r.int(8), costUSD: r.isNull(9) ? nil : r.double(9), result: r.isNull(6) ? nil : r.text(6),
                         cwd: r.text(10), branch: r.isNull(11) ? nil : r.text(11))
        }
        return (list, rows.isEmpty ? nil : nil)
    }

    /// Codex CLI / desktop rollouts in ~/.codex/sessions (session_meta + token_count events).
    nonisolated static func codex() -> [AgentSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        var files: [(URL, Date)] = []
        for case let u as URL in e where u.pathExtension == "jsonl" {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff { files.append((u, m)) }
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return files.sorted { $0.1 > $1.1 }.prefix(200).compactMap { (url, modified) -> AgentSession? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var meta: [String: Any] = [:], model: String?, tokens: Int?, first: Date?, last: Date?, finished = false
            for line in text.split(separator: "\n") {
                guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let ts = (j["timestamp"] as? String).flatMap { iso.date(from: $0) }
                if first == nil { first = ts }
                if let ts { last = ts }
                let p = j["payload"] as? [String: Any] ?? [:]
                switch j["type"] as? String {
                case "session_meta": meta = p
                case "turn_context": model = p["model"] as? String ?? model
                case "event_msg":
                    if p["type"] as? String == "token_count",
                       let total = ((p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int { tokens = total }
                    if p["type"] as? String == "task_complete" { finished = true }
                default: break
                }
            }
            guard let sid = meta["id"] as? String ?? meta["session_id"] as? String else { return nil }
            let cwd = meta["cwd"] as? String ?? ""
            return AgentSession(id: "codex:\(sid)", agent: "Codex", runtime: (meta["originator"] as? String) ?? "Codex", title: (cwd as NSString).lastPathComponent,
                                model: model, startedAt: first, endedAt: finished || Date().timeIntervalSince(modified) > 600 ? last : nil, lastActivity: last,
                                tokens: tokens, costUSD: nil, result: finished ? "selesai" : nil, cwd: cwd, branch: nil)
        }
    }

    // MARK: Project association

    /// A session belongs to a project when its working directory is inside a folder linked to
    /// the project, or ends with the same folder name (the same repo checked out elsewhere).
    func sessions(for projectId: String) -> [AgentSession] {
        let paths = WorkspaceStore.shared.links(of: projectId, .local).map(\.ref)
        let repos = WorkspaceStore.shared.links(of: projectId, .repo).map { $0.ref.components(separatedBy: "/").last?.lowercased() ?? "" }
        guard !paths.isEmpty || !repos.isEmpty else { return [] }
        let names = Set(paths.map { ($0 as NSString).lastPathComponent.lowercased() } + repos.filter { !$0.isEmpty })
        return sessions.filter { s in
            paths.contains { s.cwd == $0 || s.cwd.hasPrefix($0 + "/") } ||
            s.cwd.split(separator: "/").map { $0.lowercased() }.contains { names.contains($0) }
        }
    }

    private func recordEvents() {
        let ws = WorkspaceStore.shared
        var ev: [ActivityEvent] = []
        for p in ws.projects where p.lifecycle != .archived {
            for s in sessions(for: p.id) where s.endedAt != nil {
                ev.append(ActivityEvent(id: "\(s.id)|\(p.id)", projectId: p.id, type: "agent.session", ts: s.endedAt!, source: s.agent.lowercased(),
                                        title: "\(s.agent): \(s.title)\(s.tokens.map { " · \($0.compact) token" } ?? "")",
                                        meta: ["model": s.model ?? "", "result": s.result ?? ""]))
            }
        }
        ws.record(ev)
    }
}
