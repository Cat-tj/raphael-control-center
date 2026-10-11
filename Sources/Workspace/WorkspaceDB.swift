import Foundation
import SQLite3

/// A thin, synchronous SQLite wrapper for the local workspace database
/// (portfolios, projects, tasks…). One connection, used from the main actor.
/// Foreign keys on, WAL journal, every multi-row change inside a transaction.
final class WorkspaceDB {
    enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String, String), step(String, String), migration(Int, String)
        var description: String {
            switch self {
            case .open(let m): "Tidak bisa membuka database: \(m)"
            case .prepare(let sql, let m): "SQL tidak valid (\(m)): \(sql.prefix(120))"
            case .step(let sql, let m): "Gagal menjalankan (\(m)): \(sql.prefix(120))"
            case .migration(let v, let m): "Migrasi v\(v) gagal: \(m)"
            }
        }
    }

    let path: String
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DBError.open(db.map { String(cString: sqlite3_errmsg($0)) } ?? "?")
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close(db) }

    var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "?" }

    // MARK: Statements

    typealias Row = [String: Any?]

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError.step(sql, m)
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw DBError.prepare(sql, lastError) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil, is NSNull: sqlite3_bind_null(stmt, idx)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_text(stmt, idx, "\(a!)", -1, Self.transient)
            }
        }
        return stmt
    }

    /// INSERT / UPDATE / DELETE. Returns the number of changed rows.
    @discardableResult
    func run(_ sql: String, _ args: Any?...) throws -> Int { try run(sql, args: args) }

    @discardableResult
    func run(_ sql: String, args: [Any?]) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(sql, lastError) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: Any?...) throws -> [Row] { try query(sql, args: args) }

    func query(_ sql: String, args: [Any?]) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(sql, lastError) }
            var row: Row = [:]
            for c in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_NULL: row[name] = .some(nil)
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, c)
                    row[name] = sqlite3_column_blob(stmt, c).map { Data(bytes: $0, count: Int(bytes)) }
                default: row[name] = sqlite3_column_text(stmt, c).map { String(cString: $0) }
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalar(_ sql: String, _ args: Any?...) throws -> Int {
        (try query(sql, args: args).first?.values.first ?? nil) as? Int ?? 0
    }

    /// Runs `body` in one transaction; any throw rolls everything back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Schema versioning

    var userVersion: Int { (try? scalar("PRAGMA user_version")) ?? 0 }

    /// Applies migrations newer than PRAGMA user_version, each in its own transaction.
    /// A file copy is taken before the first pending migration.
    func migrate(_ migrations: [(version: Int, sql: String)]) throws {
        let current = userVersion
        let pending = migrations.filter { $0.version > current }.sorted { $0.version < $1.version }
        guard !pending.isEmpty else { return }
        if current > 0 { try? backup(suffix: "pre-v\(pending[0].version)") }
        for m in pending {
            do {
                try transaction {
                    try exec(m.sql)
                    try exec("PRAGMA user_version = \(m.version)")
                }
            } catch {
                throw DBError.migration(m.version, "\(error)")
            }
        }
    }

    /// Consistent online copy next to the database (sqlite3 backup API).
    @discardableResult
    func backup(suffix: String) throws -> String {
        let dir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("backups")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let dest = (dir as NSString).appendingPathComponent("workspace-\(stamp)-\(suffix).sqlite")
        var out: OpaquePointer?
        guard sqlite3_open(dest, &out) == SQLITE_OK else { throw DBError.open(dest) }
        defer { sqlite3_close(out) }
        guard let b = sqlite3_backup_init(out, "main", db, "main") else { throw DBError.step("backup", lastError) }
        sqlite3_backup_step(b, -1)
        sqlite3_backup_finish(b)
        // Keep the newest 10 backups.
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("workspace-") }.sorted()
        for f in files.dropLast(10) { try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(f)) }
        return dest
    }

    func integrityOK() -> Bool { ((try? query("PRAGMA integrity_check").first?["integrity_check"]) ?? nil) as? String == "ok" }
}

extension Dictionary where Key == String, Value == Any? {
    func str(_ k: String) -> String? { (self[k] ?? nil) as? String }
    func int(_ k: String) -> Int? { (self[k] ?? nil) as? Int }
    func dbl(_ k: String) -> Double? { ((self[k] ?? nil) as? Double) ?? ((self[k] ?? nil) as? Int).map(Double.init) }
    func date(_ k: String) -> Date? { dbl(k).map { Date(timeIntervalSince1970: $0) } }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}
