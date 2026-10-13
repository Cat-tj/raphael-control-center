import Foundation
import SwiftUI

/// Keeps workspace.sqlite in step with Raphael Web, which holds the shared copy.
///
/// - Every committed local change (the write statements WorkspaceDB captured) goes into an outbox
///   persisted on disk and is sent in order to `/api/ws/apply`; offline changes wait there.
/// - Raphael Web counts every change (`rev`). When its revision moves and the outbox is empty,
///   the Mac pulls the whole workspace (`/api/ws/dump`) and replaces its local copy.
/// - First connection: an empty Raphael Web is seeded from this Mac; otherwise the server wins
///   (the local file is backed up first).
@MainActor
final class WorkspaceSync: ObservableObject {
    static let shared = WorkspaceSync()

    enum Status: Equatable { case off, syncing, synced, offline(String), error(String) }
    @Published private(set) var status: Status = .off
    @Published private(set) var pending = 0
    @Published private(set) var lastSync: Date?

    private var outbox: [[WorkspaceDB.Statement]] = []
    private var rev: Int { get { UserDefaults.standard.integer(forKey: "raphaelWorkspaceRev") } set { UserDefaults.standard.set(newValue, forKey: "raphaelWorkspaceRev") } }
    private var seeded: Bool { get { UserDefaults.standard.bool(forKey: "raphaelWorkspaceSeeded") } set { UserDefaults.standard.set(newValue, forKey: "raphaelWorkspaceSeeded") } }
    private var timer: Timer?
    private var busy = false
    private static var outboxURL: URL { NodeStore.supportDir.appendingPathComponent("workspace-outbox.json") }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "raphaelWorkspaceSync") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "raphaelWorkspaceSync"); Task { @MainActor in WorkspaceSync.shared.configure() } }
    }

    private var base: String? {
        let u = MonitorStore.webURL
        return Self.enabled && !u.isEmpty ? (u.hasSuffix("/") ? String(u.dropLast()) : u) : nil
    }

    private init() {
        if let data = try? Data(contentsOf: Self.outboxURL), let saved = try? JSONDecoder().decode([[WorkspaceDB.Statement]].self, from: data) { outbox = saved }
        pending = outbox.reduce(0) { $0 + $1.count }
    }

    /// Hooks the store's database and starts the 15 s loop (or stops it when sync is off).
    func configure() {
        let db = WorkspaceStore.shared.db
        timer?.invalidate()
        guard base != nil, let db else {
            db?.onCommit = nil
            status = .off
            return
        }
        db.onCommit = { [weak self] statements in
            MainActor.assumeIsolated { self?.enqueue(statements) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { @MainActor in await WorkspaceSync.shared.cycle() } }
        Task { await cycle() }
    }

    func syncNow() { Task { await cycle() } }

    private func enqueue(_ statements: [WorkspaceDB.Statement]) {
        outbox.append(statements)
        saveOutbox()
        Task { await cycle() }
    }

    private func saveOutbox() {
        pending = outbox.reduce(0) { $0 + $1.count }
        if let data = try? JSONEncoder().encode(outbox) { try? data.write(to: Self.outboxURL, options: .atomic) }
    }

    // MARK: Loop

    private func cycle() async {
        guard let base, !busy else { return }
        busy = true
        defer { busy = false }
        if pending > 0 || status == .off { status = .syncing }
        do {
            if !seeded { try await firstConnection(base) }
            // 1. Push: oldest batch first; a rejected batch is dropped and the server copy pulled.
            while let batch = outbox.first {
                let r = try await post(base + "/api/ws/apply", ["baseRev": rev, "statements": batch.map(Self.json)])
                if let err = r["error"] as? String {
                    outbox.removeFirst(); saveOutbox()
                    WorkspaceStore.shared.lastError = "Perubahan ditolak Raphael Web (\(err)); memuat ulang data dari server."
                    try await pull(base)
                    continue
                }
                outbox.removeFirst(); saveOutbox()
                let newRev = (r["rev"] as? Int) ?? rev
                if (r["clean"] as? Bool) == true { rev = newRev } else { try await pull(base) }
            }
            // 2. Pull when something changed elsewhere.
            let remote = try await get(base + "/api/ws/rev")["rev"] as? Int ?? rev
            if remote != rev { try await pull(base) }
            status = .synced
            lastSync = Date()
        } catch let e as URLError {
            status = .offline(e.code == .notConnectedToInternet || e.code == .cannotConnectToHost || e.code == .timedOut ? "Raphael Web tidak terjangkau" : e.localizedDescription)
        } catch {
            status = .error("\(error)")
        }
    }

    private func firstConnection(_ base: String) async throws {
        guard let db = WorkspaceStore.shared.db else { return }
        let dump = try await get(base + "/api/ws/dump")
        let tables = dump["tables"] as? [String: [[String: Any]]] ?? [:]
        let remoteEmpty = ["portfolio", "project", "task"].allSatisfy { (tables[$0] ?? []).isEmpty }
        let local = try db.dumpAll()
        let localEmpty = ["portfolio", "project", "task"].allSatisfy { (local[$0] ?? []).isEmpty }
        if remoteEmpty && !localEmpty {
            // Seed the server from this Mac (parents before children; foreign keys are deferred there anyway).
            let order = ["portfolio", "project", "epic", "milestone", "release", "task", "task_checklist", "task_dependency",
                         "resource_link", "external_ref", "activity", "sync_state", "registry_decision"]
            var batch: [WorkspaceDB.Statement] = []
            for t in order + local.keys.filter({ !order.contains($0) }).sorted() {
                for row in local[t] ?? [] {
                    let keys = row.keys.sorted()
                    batch.append(.init(sql: "INSERT OR IGNORE INTO \"\(t)\" (" + keys.map { "\"\($0)\"" }.joined(separator: ",") + ") VALUES ("
                                       + keys.map { _ in "?" }.joined(separator: ",") + ")", args: keys.map { WorkspaceDB.value(row[$0] ?? nil) }))
                }
            }
            if !batch.isEmpty { outbox.insert(batch, at: 0); saveOutbox() }
        } else {
            if !localEmpty { _ = try? db.backup(suffix: "pre-sync") }
            try apply(dump)
        }
        seeded = true
    }

    private func pull(_ base: String) async throws {
        guard outbox.isEmpty else { return }            // local changes first, then pull
        try apply(try await get(base + "/api/ws/dump"))
    }

    private func apply(_ dump: [String: Any]) throws {
        guard let db = WorkspaceStore.shared.db else { return }
        let tables = (dump["tables"] as? [String: [[String: Any]]] ?? [:]).mapValues { rows in
            rows.map { row in row.mapValues { v -> Any? in
                switch v {
                case is NSNull: return nil
                case let n as NSNumber:
                    if CFNumberIsFloatType(n) { return n.doubleValue }
                    return n.intValue
                default: return v
                }
            } }
        }
        try db.replaceAll(tables)
        rev = dump["rev"] as? Int ?? rev
        WorkspaceStore.shared.reload()
        lastSync = Date()
    }

    // MARK: HTTP

    private static func json(_ s: WorkspaceDB.Statement) -> [String: Any] {
        ["sql": s.sql, "args": s.args.map { v -> Any in
            switch v { case .null: NSNull(); case .int(let i): i; case .double(let d): d; case .text(let t): t }
        }]
    }

    private func get(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 10))
        return try Self.decode(data, resp)
    }

    private func post(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Raphael")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 400 { return ["error": j["error"] as? String ?? "HTTP 400"] }     // rejected batch
        guard code == 200 else { throw URLError(.badServerResponse) }
        return j
    }

    private static func decode(_ data: Data, _ resp: URLResponse) throws -> [String: Any] {
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return j
    }
}

/// "Tersinkron · 2 menit lalu" / "3 perubahan menunggu" / error, with a sync-now button.
struct WorkspaceSyncBadge: View {
    @ObservedObject private var sync = WorkspaceSync.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11.5)).foregroundStyle(color).lineLimit(1)
            if sync.status != .off {
                Button { sync.syncNow() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.plain).foregroundStyle(RTheme.muted).help("Sinkronkan sekarang")
            }
        }
        .fixedSize()
    }

    private var text: String {
        switch sync.status {
        case .off: "Workspace lokal (tidak disinkron)"
        case .syncing: sync.pending > 0 ? "Mengirim \(sync.pending) perubahan…" : "Menyinkron…"
        case .synced: "Tersinkron dengan Raphael Web" + (sync.lastSync.map { " · " + $0.ago } ?? "")
        case .offline(let m): sync.pending > 0 ? "\(m) · \(sync.pending) perubahan menunggu" : m
        case .error(let m): "Sinkron gagal: \(m)"
        }
    }
    private var icon: String {
        switch sync.status {
        case .off: "internaldrive"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .offline: "icloud.slash"
        case .error: "exclamationmark.icloud"
        }
    }
    private var color: Color {
        switch sync.status {
        case .off: RTheme.muted
        case .syncing: RTheme.blue
        case .synced: RTheme.green
        case .offline: RTheme.amber
        case .error: RTheme.red
        }
    }
}
