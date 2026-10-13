import Foundation

/// Chat with the full Hermes agent (tools, memory, skills, subagents).
/// Sending runs `hermes -z … --resume <session>`; the transcript itself is read
/// back from ~/.hermes/state.db and refreshed while the agent works, so tool
/// calls and subagents show up live, the way Claude Code shows them.
@MainActor
final class RaphaelAgent: ObservableObject {
    static let shared = RaphaelAgent()

    @Published var sessions: [HermesSessionRow] = []
    @Published var search = "" { didSet { reloadList() } }
    @Published var sourceFilter = "" { didSet { reloadList() } }
    @Published var selectedId: String?
    @Published var transcript = HTranscript()
    @Published var children: [String: HTranscript] = [:]
    /// One `hermes -z` run per chat, so several chats can work at once and each
    /// shows only its own "thinking" state.
    struct ChatRun {
        let key: UUID
        var sessionId: String?          // known up front when resuming, discovered for a new chat
        let node: RNode
        let prompt: String
        let started: Double
        var process: Process?
        var promptSeen = false          // the prompt is in the transcript, stop showing it as pending
    }
    @Published private(set) var runs: [UUID: ChatRun] = [:]
    /// The new chat being looked at whose run hasn't revealed its session id yet.
    @Published private(set) var viewRunKey: UUID?
    /// Result of the last run per chat (session id, or run key while it has none).
    @Published private var outcomes: [String: (usage: String?, error: String?)] = [:]

    private var poll: Timer?

    var currentRun: ChatRun? {
        if let id = selectedId { return runs.values.first { $0.sessionId == id } }
        if let k = viewRunKey { return runs[k] }
        return nil
    }
    /// The open chat is working.
    var running: Bool { currentRun != nil }
    /// Any chat is working (sidebar spinner).
    var anyRunning: Bool { !runs.isEmpty }
    func isRunning(_ sessionId: String) -> Bool { runs.values.contains { $0.sessionId == sessionId } }
    var pendingPrompt: String? { currentRun.flatMap { $0.promptSeen ? nil : $0.prompt } }
    private var outcomeKey: String? { selectedId ?? viewRunKey?.uuidString }
    var lastUsage: String? { outcomeKey.flatMap { outcomes[$0]?.usage } }
    var lastError: String? { outcomeKey.flatMap { outcomes[$0]?.error } }

    private init() {
        NotificationCenter.default.addObserver(forName: .raphaelDeviceChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let me = RaphaelAgent.shared
                if !me.running { me.newChat() }
                me.reloadList()
            }
        }
    }

    /// Device whose Hermes the open session (or the next new chat) runs on.
    @Published var chatDeviceId: String = "mac"

    private var node: RNode {
        NodeStore.shared.nodes.first { $0.id == chatDeviceId } ?? Self.defaultChatNode
    }

    /// New chats go to the chosen device when it runs Hermes, else the first Hermes in scope.
    static var defaultChatNode: RNode {
        let ctx = DeviceContext.shared
        if let sel = ctx.selected, ctx.has("hermes", sel) { return sel }
        if let primary = ctx.hermesNodes.first(where: { $0.id == DeviceContext.primaryHermesId }) { return primary }
        return ctx.hermesNodes.first ?? ctx.current
    }

    func deviceName(_ id: String) -> String { NodeStore.shared.nodes.first { $0.id == id }?.name ?? id }

    static var hermesPath: String {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes").path,
                          "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "hermes"
    }

    // MARK: History

    func reloadList() {
        let q = search, src = sourceFilter
        let nodes = DeviceContext.shared.hermesNodes, scopeId = DeviceContext.shared.currentId
        Task.detached(priority: .userInitiated) {
            var rows: [HermesSessionRow] = []
            await withTaskGroup(of: [HermesSessionRow].self) { group in
                for n in nodes {
                    group.addTask {
                        await HermesStats.sessions(n, search: q, source: src.isEmpty ? nil : src)
                            .map { var r = $0; r.device = n.id; return r }
                    }
                }
                for await part in group { rows += part }
            }
            rows.sort { $0.when > $1.when }
            let merged = Array(rows.prefix(300))
            await MainActor.run { if DeviceContext.shared.currentId == scopeId { RaphaelAgent.shared.sessions = merged } }
        }
    }

    func select(_ id: String?, device: String? = nil) {
        if let device { chatDeviceId = device }
        else if let id, let row = sessions.first(where: { $0.id == id }), !row.device.isEmpty { chatDeviceId = row.device }
        selectedId = id
        viewRunKey = nil
        children = [:]
        if id == nil { transcript = HTranscript(); return }
        reloadTranscript()
    }

    func newChat() {
        chatDeviceId = Self.defaultChatNode.id
        select(nil)
    }

    func reloadTranscript() {
        guard let id = selectedId else { return }
        let open = Array(children.keys), n = currentRun?.node ?? node
        Task.detached(priority: .userInitiated) {
            let t = await HermesStats.transcript(n, id)
            var kids: [String: HTranscript] = [:]
            for c in open { kids[c] = await HermesStats.transcript(n, c) }
            await MainActor.run {
                let me = RaphaelAgent.shared
                guard me.selectedId == id else { return }
                me.transcript = t
                for (k, v) in kids { me.children[k] = v }
                if let r = me.runs.values.first(where: { $0.sessionId == id }), !r.promptSeen,
                   t.items.contains(where: { $0.kind == .user && $0.text == r.prompt }) { me.runs[r.key]?.promptSeen = true }
            }
        }
    }

    func toggleChild(_ id: String) {
        if children[id] != nil { children[id] = nil; return }
        children[id] = HTranscript()
        let n = node
        Task.detached {
            let t = await HermesStats.transcript(n, id)
            await MainActor.run { RaphaelAgent.shared.children[id] = t }
        }
    }

    // MARK: Sending

    /// Stops the open chat's run.
    func stop() {
        guard let r = currentRun else { return }
        r.process?.terminate()
        finish(r.key, usage: (nil, nil), error: nil)
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        let target = node
        let run = ChatRun(key: UUID(), sessionId: selectedId, node: target, prompt: prompt, started: Date().timeIntervalSince1970)
        runs[run.key] = run
        if selectedId == nil { viewRunKey = run.key }
        outcomes[selectedId ?? run.key.uuidString] = nil
        startPolling()
        if target.isLocal { sendLocal(run) } else { sendRemote(run) }
    }

    private func sendLocal(_ run: ChatRun) {
        let usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("raphael-usage-\(run.key.uuidString).json")
        var args = ["-z", run.prompt, "--usage-file", usageURL.path]
        if let resume = run.sessionId { args += ["--resume", resume] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.hermesPath)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:" + NodeStore.toolPath
        env["GRAPHIFY_NO_AUTO_REFRESH"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        runs[run.key]?.process = p
        let key = run.key

        DispatchQueue.global(qos: .userInitiated).async {
            var text = "", code: Int32 = -1
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                code = p.terminationStatus
                text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if code != 0, text.isEmpty { text = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                text = "Tidak bisa menjalankan hermes: \(error.localizedDescription)"
            }
            let usage = Self.readUsage(usageURL)
            try? FileManager.default.removeItem(at: usageURL)
            let finalText = text, exit = code
            Task { @MainActor in
                let error = exit == 0 ? nil : (finalText.isEmpty ? "hermes keluar dengan kode \(exit)" : String(finalText.suffix(600)))
                RaphaelAgent.shared.finish(key, usage: usage, error: error)
            }
        }
    }

    /// Same as a local run, but `hermes -z` runs on the device over SSH.
    private func sendRemote(_ run: ChatRun) {
        let usagePath = "/tmp/raphael-usage-\(run.key.uuidString).json"
        var cmd = "cd ~ && GRAPHIFY_NO_AUTO_REFRESH=1 ~/.local/bin/hermes -z \(NodeStore.shellQuote(run.prompt)) --usage-file \(usagePath)"
        if let resume = run.sessionId { cmd += " --resume \(NodeStore.shellQuote(resume))" }
        cmd += "; echo; echo __RAPHAEL_USAGE__; cat \(usagePath) 2>/dev/null; rm -f \(usagePath)"
        let key = run.key, target = run.node
        Task {
            let r = await NodeStore.run(node: target, script: cmd, timeout: 1800)
            let parts = r.output.components(separatedBy: "__RAPHAEL_USAGE__")
            let usageFile = FileManager.default.temporaryDirectory.appendingPathComponent("raphael-usage-\(key.uuidString).json")
            try? (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespacesAndNewlines).write(to: usageFile, atomically: true, encoding: .utf8)
            let usage = Self.readUsage(usageFile)
            try? FileManager.default.removeItem(at: usageFile)
            let error = usage.summary == nil && r.exitCode != 0 ? String((parts.first ?? r.output).suffix(600)) : nil
            finish(key, usage: usage, error: error)
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in RaphaelAgent.shared.tick() }
        }
    }

    /// Finds the session of new chats as soon as Hermes creates it, and refreshes the open chat.
    private func tick() {
        for r in runs.values where r.sessionId == nil {
            let claimed = Set(runs.values.compactMap(\.sessionId))
            Task {
                guard let sid = await HermesStats.sessionFor(r.node, prompt: r.prompt, after: r.started), !claimed.contains(sid),
                      runs[r.key]?.sessionId == nil else { return }
                adopt(r.key, sid)
            }
        }
        if currentRun?.sessionId != nil { reloadTranscript() }
    }

    /// A new chat's run now has a session id; if that chat is on screen, show the session.
    private func adopt(_ key: UUID, _ sid: String) {
        runs[key]?.sessionId = sid
        if let o = outcomes.removeValue(forKey: key.uuidString) { outcomes[sid] = o }
        if viewRunKey == key, selectedId == nil {
            selectedId = sid
            viewRunKey = nil
            reloadTranscript()
        }
    }

    private func finish(_ key: UUID, usage: (summary: String?, sessionId: String?), error: String?) {
        guard runs[key] != nil else { return }
        if runs[key]?.sessionId == nil, let sid = usage.sessionId { adopt(key, sid) }
        let sid = runs[key]?.sessionId
        outcomes[sid ?? key.uuidString] = (usage.summary, error)
        runs[key] = nil
        if runs.isEmpty { poll?.invalidate(); poll = nil }
        if sid != nil, sid == selectedId { reloadTranscript() }
        reloadList()
        HermesStats.shared.refresh()
    }

    // MARK: Usage + session discovery

    nonisolated static func readUsage(_ url: URL) -> (summary: String?, sessionId: String?) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        func n(_ k: String) -> Int { (json[k] as? NSNumber)?.intValue ?? 0 }
        var parts = ["in \(n("input_tokens").compact)", "cache \(n("cache_read_tokens").compact)",
                     "out \(n("output_tokens").compact)", "\(n("api_calls")) call"]
        if let aux = json["auxiliary"] as? [String: Any], let t = (aux["total_tokens"] as? NSNumber)?.intValue, t > 0 {
            parts.append("aux \(t.compact)")
        }
        if let c = (json["estimated_cost_usd"] as? NSNumber)?.doubleValue, c > 0 { parts.append(c.usd) }
        return (parts.joined(separator: " · "), json["session_id"] as? String)
    }

}
