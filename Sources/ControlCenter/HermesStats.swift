import Foundation
import SQLite3

/// Read-only view of Hermes's own bookkeeping (~/.hermes/state.db): sessions,
/// transcripts, subagents and where the tokens go. Never writes.
struct HermesSessionRow: Identifiable, Hashable {
    let id: String
    let title: String
    let source: String
    let model: String
    let parentId: String?
    let startedAt: Date
    let lastActivity: Date?
    let active: Bool
    let messages: Int
    let toolCalls: Int
    let apiCalls: Int
    let input: Int
    let cacheRead: Int
    let output: Int
    let cost: Double
    /// Node id the session lives on (set after loading).
    var device: String = ""

    /// Prompt tokens actually sent per API call (fresh + cached).
    var contextPerCall: Int { apiCalls > 0 ? (input + cacheRead) / apiCalls : 0 }
    var totalTokens: Int { input + cacheRead + output }
    var when: Date { lastActivity ?? startedAt }
}

struct HermesDay: Identifiable, Hashable {
    var id: String { day }
    let day: String
    let sessions: Int
    let calls: Int
    let input: Int
    let cacheRead: Int
    let output: Int
    var total: Int { input + cacheRead + output }
}

struct HermesBucket: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let sessions: Int
    let calls: Int
    let tokens: Int
}

struct HermesSnapshot {
    var days: [HermesDay] = []
    var sources: [HermesBucket] = []
    var tasks: [HermesBucket] = []
    var models: [HermesBucket] = []
    var heaviest: [HermesSessionRow] = []
    var recent: [HermesSessionRow] = []
    var allTime = (sessions: 0, calls: 0, input: 0, cacheRead: 0, output: 0, cost: 0.0)
    var today = (calls: 0, tokens: 0)
    var dbBytes: Int64 = 0
    var systemPromptTokens = 0
    var error: String?
    /// Devices whose Hermes data is included (names).
    var devices: [String] = []

    var week: (calls: Int, input: Int, cacheRead: Int, output: Int) {
        days.reduce((0, 0, 0, 0)) { ($0.0 + $1.calls, $0.1 + $1.input, $0.2 + $1.cacheRead, $0.3 + $1.output) }
    }
    var weekTotal: Int { let w = week; return w.input + w.cacheRead + w.output }
    var allTimeTotal: Int { allTime.input + allTime.cacheRead + allTime.output }
    var avgContextPerCall: Int { week.calls > 0 ? (week.input + week.cacheRead) / week.calls : 0 }
    var activeCount: Int { recent.filter { $0.active && Date().timeIntervalSince($0.when) < 1800 }.count }
}

// MARK: - Transcript

struct HToolCall: Identifiable, Hashable {
    let id: String
    let name: String
    let arguments: String
    var result: String?
    var resultTokens: Int = 0
    var isSubagent: Bool { name == "delegate_task" }
}

struct HTranscriptItem: Identifiable, Hashable {
    enum Kind: Hashable { case user, assistant, system }
    let id: Int
    let kind: Kind
    let text: String
    let reasoning: String?
    var tools: [HToolCall]
    let at: Date
}

struct HBreakdownPart: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let tokens: Int
}

struct HTranscript {
    var session: HermesSessionRow?
    var items: [HTranscriptItem] = []
    var children: [HermesSessionRow] = []
    var tasks: [HBreakdownPart] = []        // session_model_usage by task (tokens billed)
    var context: [HBreakdownPart] = []      // what fills the prompt (estimated from text)
    var toolUse: [HBreakdownPart] = []      // tool results by tool
    var contextTotal: Int { context.reduce(0) { $0 + $1.tokens } }
}

@MainActor
final class HermesStats: ObservableObject {
    static let shared = HermesStats()
    @Published var snapshot = HermesSnapshot()
    @Published var loading = false

    nonisolated static var dbPath: String { HermesConfig.home.appendingPathComponent("state.db").path }

    /// Loads every Hermes in scope ("Semua device" → all of them, merged).
    func refresh() {
        guard !loading else { return }
        loading = true
        let nodes = DeviceContext.shared.hermesNodes, scopeId = DeviceContext.shared.currentId
        Task.detached(priority: .utility) {
            var snaps: [(RNode, HermesSnapshot)] = []
            await withTaskGroup(of: (RNode, HermesSnapshot).self) { group in
                for n in nodes { group.addTask { (n, await HermesStats.load(n)) } }
                for await r in group { snaps.append(r) }
            }
            let merged = HermesStats.merge(snaps)
            await MainActor.run {
                HermesStats.shared.loading = false
                guard DeviceContext.shared.currentId == scopeId else { return }
                HermesStats.shared.snapshot = merged
            }
        }
    }

    nonisolated static func merge(_ snaps: [(RNode, HermesSnapshot)]) -> HermesSnapshot {
        guard !snaps.isEmpty else {
            var s = HermesSnapshot(); s.error = "Tidak ada Hermes di scope ini"; return s
        }
        if snaps.count == 1 {
            var s = snaps[0].1
            s.devices = [snaps[0].0.name]
            s.heaviest = s.heaviest.map { var r = $0; r.device = snaps[0].0.id; return r }
            s.recent = s.recent.map { var r = $0; r.device = snaps[0].0.id; return r }
            return s
        }
        var out = HermesSnapshot()
        var days: [String: HermesDay] = [:]
        func addBuckets(_ a: [HermesBucket], into d: inout [String: HermesBucket]) {
            for b in a {
                let o = d[b.name]
                d[b.name] = HermesBucket(name: b.name, sessions: (o?.sessions ?? 0) + b.sessions,
                                         calls: (o?.calls ?? 0) + b.calls, tokens: (o?.tokens ?? 0) + b.tokens)
            }
        }
        var sources: [String: HermesBucket] = [:], tasks: [String: HermesBucket] = [:], models: [String: HermesBucket] = [:]
        for (node, s) in snaps where s.error == nil {
            out.devices.append(node.name)
            for d in s.days {
                let o = days[d.day]
                days[d.day] = HermesDay(day: d.day, sessions: (o?.sessions ?? 0) + d.sessions, calls: (o?.calls ?? 0) + d.calls,
                                        input: (o?.input ?? 0) + d.input, cacheRead: (o?.cacheRead ?? 0) + d.cacheRead,
                                        output: (o?.output ?? 0) + d.output)
            }
            out.allTime = (out.allTime.sessions + s.allTime.sessions, out.allTime.calls + s.allTime.calls,
                           out.allTime.input + s.allTime.input, out.allTime.cacheRead + s.allTime.cacheRead,
                           out.allTime.output + s.allTime.output, out.allTime.cost + s.allTime.cost)
            out.today = (out.today.calls + s.today.calls, out.today.tokens + s.today.tokens)
            addBuckets(s.sources, into: &sources); addBuckets(s.tasks, into: &tasks); addBuckets(s.models, into: &models)
            out.heaviest += s.heaviest.map { var r = $0; r.device = node.id; return r }
            out.recent += s.recent.map { var r = $0; r.device = node.id; return r }
            out.dbBytes += s.dbBytes
            out.systemPromptTokens = max(out.systemPromptTokens, s.systemPromptTokens)
        }
        out.days = days.values.sorted { $0.day < $1.day }
        out.sources = sources.values.sorted { $0.tokens > $1.tokens }
        out.tasks = tasks.values.sorted { $0.tokens > $1.tokens }
        out.models = models.values.sorted { $0.tokens > $1.tokens }.prefix(8).map { $0 }
        out.heaviest = out.heaviest.sorted { $0.totalTokens > $1.totalTokens }.prefix(12).map { $0 }
        out.recent = out.recent.sorted { $0.when > $1.when }.prefix(25).map { $0 }
        if out.devices.isEmpty { out.error = snaps.first?.1.error }
        return out
    }

    // MARK: Snapshot

    nonisolated static let sessionCols = """
        id, coalesce(nullif(title,''), nullif(display_name,''), substr(id,1,15)), source, coalesce(model,''),
        parent_session_id, started_at, last_activity_at, ended_at IS NULL, message_count, tool_call_count,
        api_call_count, input_tokens, cache_read_tokens, output_tokens, coalesce(actual_cost_usd, estimated_cost_usd, 0)
        """

    nonisolated static func sessionRow(_ s: SQLRow) -> HermesSessionRow {
        HermesSessionRow(id: s.text(0), title: s.text(1), source: s.text(2), model: s.text(3),
                         parentId: s.isNull(4) ? nil : s.text(4),
                         startedAt: Date(timeIntervalSince1970: s.double(5)),
                         lastActivity: s.isNull(6) ? nil : Date(timeIntervalSince1970: s.double(6)),
                         active: s.int(7) == 1, messages: s.int(8), toolCalls: s.int(9), apiCalls: s.int(10),
                         input: s.int(11), cacheRead: s.int(12), output: s.int(13), cost: s.double(14))
    }

    nonisolated static func load(_ node: RNode) async -> HermesSnapshot {
        var snap = HermesSnapshot()
        let weekAgo = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let qs: [SQLQuery] = [
            SQLQuery(sql: """
                SELECT date(started_at,'unixepoch','localtime'), count(*), sum(api_call_count), sum(input_tokens),
                       sum(cache_read_tokens), sum(output_tokens)
                FROM sessions WHERE started_at > ? GROUP BY 1 ORDER BY 1
                """, args: [weekAgo]),
            SQLQuery(sql: """
                SELECT count(*), sum(api_call_count), sum(input_tokens), sum(cache_read_tokens), sum(output_tokens),
                       sum(coalesce(actual_cost_usd, estimated_cost_usd, 0)) FROM sessions
                """),
            SQLQuery(sql: "SELECT sum(api_call_count), sum(input_tokens+cache_read_tokens+output_tokens) FROM sessions WHERE started_at > ?",
                     args: [midnight]),
            SQLQuery(sql: """
                SELECT source, count(*), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens)
                FROM sessions WHERE started_at > ? GROUP BY source ORDER BY 4 DESC
                """, args: [weekAgo]),
            SQLQuery(sql: """
                SELECT coalesce(nullif(task,''),'chat'), count(DISTINCT session_id), sum(api_call_count),
                       sum(input_tokens + cache_read_tokens + output_tokens)
                FROM session_model_usage WHERE last_seen > ? GROUP BY 1 ORDER BY 4 DESC
                """, args: [weekAgo]),
            SQLQuery(sql: """
                SELECT model, count(DISTINCT session_id), sum(api_call_count), sum(input_tokens + cache_read_tokens + output_tokens)
                FROM session_model_usage WHERE last_seen > ? GROUP BY 1 ORDER BY 4 DESC LIMIT 8
                """, args: [weekAgo]),
            SQLQuery(sql: "SELECT \(sessionCols) FROM sessions WHERE started_at > ? ORDER BY input_tokens + cache_read_tokens DESC LIMIT 12",
                     args: [weekAgo]),
            SQLQuery(sql: "SELECT \(sessionCols) FROM sessions WHERE hidden = 0 ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT 25"),
            SQLQuery(sql: """
                SELECT length(p.prompt) FROM sessions s JOIN system_prompts p ON p.hash = s.system_prompt_hash
                ORDER BY s.started_at DESC LIMIT 1
                """),
            SQLQuery(sql: "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()"),
        ]
        let r = await DeviceContext.sql(node, qs)
        guard r.count == qs.count else { snap.error = "Tidak bisa membaca state.db di \(node.name)"; return snap }
        snap.days = r[0].map { HermesDay(day: $0.text(0), sessions: $0.int(1), calls: $0.int(2), input: $0.int(3), cacheRead: $0.int(4), output: $0.int(5)) }
        if let a = r[1].first { snap.allTime = (a.int(0), a.int(1), a.int(2), a.int(3), a.int(4), a.double(5)) }
        if let t = r[2].first { snap.today = (t.int(0), t.int(1)) }
        let bucket: (SQLRow) -> HermesBucket = { HermesBucket(name: $0.text(0), sessions: $0.int(1), calls: $0.int(2), tokens: $0.int(3)) }
        snap.sources = r[3].map(bucket)
        snap.tasks = r[4].map(bucket)
        snap.models = r[5].map(bucket)
        snap.heaviest = r[6].map(sessionRow)
        snap.recent = r[7].map(sessionRow)
        snap.systemPromptTokens = (r[8].first?.int(0) ?? 0) / 4
        snap.dbBytes = Int64(r[9].first?.int(0) ?? 0)
        if r[1].isEmpty && r[7].isEmpty { snap.error = "Hermes tidak ditemukan di \(node.name)" }
        return snap
    }

    // MARK: Chat history

    nonisolated static func sessions(_ node: RNode, search: String, source: String?, limit: Int = 200) async -> [HermesSessionRow] {
        var sql = "SELECT \(sessionCols) FROM sessions WHERE hidden = 0 AND parent_session_id IS NULL"
        var args: [Any] = []
        if let source, !source.isEmpty { sql += " AND source = ?"; args.append(source) }
        if !search.isEmpty { sql += " AND (title LIKE ? OR id LIKE ?)"; args += ["%\(search)%", "%\(search)%"] }
        sql += " ORDER BY coalesce(last_activity_at, started_at) DESC LIMIT \(limit)"
        return (await DeviceContext.sql(node, [SQLQuery(sql: sql, args: args)])).first?.map(sessionRow) ?? []
    }

    nonisolated static func newestSession(_ node: RNode, after t: Double) async -> String? {
        let r = await DeviceContext.sql(node, [SQLQuery(sql: "SELECT id FROM sessions WHERE started_at >= ? AND parent_session_id IS NULL ORDER BY started_at DESC LIMIT 1",
                                                       args: [t - 2])])
        return r.first?.first?.text(0)
    }

    /// The session a new chat's run created: the one started after the run whose first user
    /// message is the prompt (so two new chats running at once never swap sessions).
    nonisolated static func sessionFor(_ node: RNode, prompt: String, after t: Double) async -> String? {
        let r = await DeviceContext.sql(node, [SQLQuery(sql: """
            SELECT s.id FROM sessions s WHERE s.started_at >= ? AND s.parent_session_id IS NULL
              AND (SELECT m.content FROM messages m WHERE m.session_id = s.id AND m.role = 'user' ORDER BY m.timestamp, m.id LIMIT 1) = ?
            ORDER BY s.started_at LIMIT 1
            """, args: [t - 2, prompt])])
        return r.first?.first?.text(0)
    }

    /// Longest text kept per message: huge tool outputs would make SwiftUI layout crawl.
    nonisolated static let maxMessageChars = 4000
    /// Most recent messages shown for very long sessions.
    nonisolated static let maxMessages = 600

    nonisolated static func transcript(_ node: RNode, _ sessionId: String) async -> HTranscript {
        var t = HTranscript()
        let qs: [SQLQuery] = [
            SQLQuery(sql: "SELECT \(sessionCols) FROM sessions WHERE id = ?", args: [sessionId]),
            SQLQuery(sql: "SELECT \(sessionCols) FROM sessions WHERE parent_session_id = ? ORDER BY started_at", args: [sessionId]),
            SQLQuery(sql: """
                SELECT coalesce(nullif(task,''),'chat'), sum(input_tokens + cache_read_tokens + output_tokens)
                FROM session_model_usage WHERE session_id = ? GROUP BY 1 ORDER BY 2 DESC
                """, args: [sessionId]),
            SQLQuery(sql: """
                SELECT * FROM (
                  SELECT id, role, substr(coalesce(content,''),1,\(maxMessageChars)), coalesce(tool_calls,''), coalesce(tool_name,''),
                         coalesce(tool_call_id,''), timestamp, substr(coalesce(reasoning, reasoning_content, ''),1,2000),
                         length(coalesce(content,''))
                  FROM messages WHERE session_id = ? AND active = 1 ORDER BY timestamp DESC, id DESC LIMIT \(maxMessages)
                ) ORDER BY 7, 1
                """, args: [sessionId]),
            SQLQuery(sql: "SELECT length(p.prompt) FROM sessions s JOIN system_prompts p ON p.hash = s.system_prompt_hash WHERE s.id = ?",
                     args: [sessionId]),
            SQLQuery(sql: """
                SELECT coalesce(nullif(tool_name,''),'tool'), sum(length(coalesce(content,'')))/4
                FROM messages WHERE session_id = ? AND role = 'tool' GROUP BY 1 ORDER BY 2 DESC
                """, args: [sessionId]),
            SQLQuery(sql: """
                SELECT role, sum(length(coalesce(content,'')))/4, sum(length(coalesce(reasoning, reasoning_content, '')))/4
                FROM messages WHERE session_id = ? GROUP BY role
                """, args: [sessionId]),
        ]
        let r = await DeviceContext.sql(node, qs)
        guard r.count == qs.count else { return t }
        t.session = r[0].first.map(sessionRow)
        t.children = r[1].map(sessionRow)
        t.tasks = r[2].map { HBreakdownPart(name: $0.text(0), tokens: $0.int(1)) }
        t.toolUse = r[5].map { HBreakdownPart(name: $0.text(0), tokens: $0.int(1)) }

        var lastUserText = ""
        for row in r[3] {
            let role = row.text(1), content = row.text(2), at = Date(timeIntervalSince1970: row.double(6))
            switch role {
            case "user":
                if content == lastUserText { continue }    // Hermes sometimes stores the prompt twice
                lastUserText = content
                t.items.append(HTranscriptItem(id: row.int(0), kind: .user, text: content, reasoning: nil, tools: [], at: at))
            case "assistant":
                var calls: [HToolCall] = []
                if let arr = try? JSONSerialization.jsonObject(with: Data(row.text(3).utf8)) as? [[String: Any]] {
                    for c in arr {
                        let fn = c["function"] as? [String: Any] ?? [:]
                        calls.append(HToolCall(id: (c["call_id"] as? String) ?? (c["id"] as? String) ?? UUID().uuidString,
                                               name: fn["name"] as? String ?? "tool",
                                               arguments: String((fn["arguments"] as? String ?? "").prefix(3000))))
                    }
                }
                let reasoning = row.text(7)
                t.items.append(HTranscriptItem(id: row.int(0), kind: .assistant, text: content,
                                               reasoning: reasoning.isEmpty ? nil : reasoning, tools: calls, at: at))
            case "tool":
                let callId = row.text(5), toolName = row.text(4), tok = row.int(8) / 4
                outer: for i in t.items.indices.reversed() where t.items[i].kind == .assistant {
                    for j in t.items[i].tools.indices where t.items[i].tools[j].id == callId
                        || (callId.isEmpty && t.items[i].tools[j].result == nil && t.items[i].tools[j].name == toolName) {
                        t.items[i].tools[j].result = content
                        t.items[i].tools[j].resultTokens = tok
                        break outer
                    }
                }
            default:
                break
            }
        }

        var byRole: [String: (Int, Int)] = [:]
        for row in r[6] { byRole[row.text(0)] = (row.int(1), row.int(2)) }
        let toolTotal = t.toolUse.reduce(0) { $0 + $1.tokens }
        t.context = [
            HBreakdownPart(name: "System prompt + memory", tokens: (r[4].first?.int(0) ?? 0) / 4),
            HBreakdownPart(name: "Hasil tool", tokens: toolTotal),
            HBreakdownPart(name: "Pesan kamu", tokens: byRole["user"]?.0 ?? 0),
            HBreakdownPart(name: "Jawaban Raphael", tokens: byRole["assistant"]?.0 ?? 0),
            HBreakdownPart(name: "Reasoning", tokens: byRole["assistant"]?.1 ?? 0),
        ].filter { $0.tokens > 0 }
        return t
    }
}
