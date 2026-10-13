import Foundation

/// A scheduled job on a device: cron entry, systemd timer, launchd agent or Hermes cron job.
struct MJob: Identifiable, Hashable {
    enum Kind: String { case cron, timer, launchd, hermes
        var title: String { ["cron": "Cron", "timer": "systemd timer", "launchd": "launchd", "hermes": "Hermes cron"][rawValue]! }
        var icon: String { ["cron": "clock", "timer": "timer", "launchd": "gearshape.arrow.triangle.2.circlepath", "hermes": "sparkles"][rawValue]! }
    }
    struct Run: Hashable { let started: Date?; let finished: Date?; let status: String; let error: String }

    let id: String
    let kind: Kind
    let name: String
    let expr: String              // cron expression (cron / Hermes)
    let schedule: String          // human description when there is no expression
    let command: String
    let user: String
    let source: String
    let enabled: Bool
    let system: Bool              // distro housekeeping, hidden by default
    var next: Date?
    var last: Date?
    let status: String            // ok, failed, running, "" (unknown)
    let detail: String
    let log: String?
    let logModified: Date?
    let failureStreak: Int
    let workdir: String
    let history: [Run]
    let tzOffset: Int             // device UTC offset (s), for cron math

    /// Expected last run per the schedule (cron expressions only).
    var expectedLast: Date? { CronExpr(expr)?.previous(before: Date(), tzOffset: tzOffset) }

    /// Ran later than expected: the schedule says it should have run since the last recorded run.
    var missed: Bool {
        guard enabled else { return false }
        // Timers / Hermes report their next run: still in the past 15 min later = it did not run.
        if kind != .cron, let n = next, n < Date().addingTimeInterval(-900) { return true }
        guard let exp = expectedLast, Date().timeIntervalSince(exp) > 600, let last else { return false }
        return exp.timeIntervalSince(last) > 300
    }

    var health: Health {
        if !enabled { return .disabled }
        if status == "failed" || failureStreak > 0 { return .failed }
        if status == "running" { return .running }
        if missed { return .missed }
        if status == "ok" { return .ok }
        if last == nil, kind != .cron, let n = next, n > Date() { return .scheduled }     // reported by the scheduler itself
        return .unknown
    }
    enum Health: String { case ok = "OK", failed = "Gagal", missed = "Terlewat", running = "Berjalan", scheduled = "Terjadwal", disabled = "Nonaktif", unknown = "Belum diketahui" }

    var scheduleText: String {
        if !schedule.isEmpty { return schedule }
        if let c = CronExpr(expr) { return c.describe() }
        return expr.isEmpty ? "–" : expr
    }

    static func parse(_ j: [String: Any], tz: Int) -> MJob {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        func date(_ k: String) -> Date? {
            if let n = j[k] as? NSNumber, n.doubleValue > 0 { return Date(timeIntervalSince1970: n.doubleValue) }
            if let s = j[k + "ISO"] as? String ?? j[k] as? String { return iso.date(from: s) ?? iso2.date(from: s) }
            return nil
        }
        let kind = Kind(rawValue: j["kind"] as? String ?? "") ?? .cron
        let expr = j["expr"] as? String ?? ""
        var job = MJob(id: j["id"] as? String ?? UUID().uuidString, kind: kind, name: j["name"] as? String ?? "?", expr: expr,
                       schedule: j["schedule"] as? String ?? "", command: j["command"] as? String ?? "", user: j["user"] as? String ?? (j["profile"] as? String ?? ""),
                       source: j["source"] as? String ?? (j["unit"] as? String ?? ""), enabled: j["enabled"] as? Bool ?? true, system: j["system"] as? Bool ?? false,
                       next: date("next"), last: date("last"), status: j["status"] as? String ?? "", detail: (j["detail"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                       log: j["log"] as? String, logModified: (j["logModified"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                       failureStreak: (j["failureStreak"] as? NSNumber)?.intValue ?? 0, workdir: j["workdir"] as? String ?? "",
                       history: ((j["history"] as? [[Any]]) ?? []).map { r in
                           Run(started: (r.first as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) },
                               finished: (r.count > 1 ? r[1] as? String : nil).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) },
                               status: r.count > 2 ? (r[2] as? String ?? "") : "", error: r.count > 3 ? (r[3] as? String ?? "") : "")
                       }, tzOffset: tz)
        // A cron line logging to a file: the log's mtime is a good "last run" when the journal is unavailable.
        if job.last == nil, let m = job.logModified { job.last = m }
        if job.next == nil, let c = CronExpr(expr) { job.next = c.next(after: Date(), tzOffset: tz) }
        if job.last == nil, kind == .hermes, let r = job.history.first { job.last = r.started }
        return job
    }
}

/// Five-field cron expressions (plus @hourly/@daily/@weekly/@monthly/@yearly), evaluated in
/// the device's UTC offset.
struct CronExpr {
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let anyDay: Bool, anyWeekday: Bool
    let source: String

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let macros = ["@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"]
        if let m = macros[s] { s = m }
        let f = s.split(separator: " ").map(String.init)
        guard f.count == 5,
              let mi = Self.field(f[0], 0, 59), let h = Self.field(f[1], 0, 23), let d = Self.field(f[2], 1, 31),
              let mo = Self.field(f[3], 1, 12, names: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]),
              let w = Self.field(f[4], 0, 7, names: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]) else { return nil }
        minutes = mi; hours = h; days = d; months = mo; weekdays = Set(w.map { $0 == 7 ? 0 : $0 })
        anyDay = f[2] == "*"; anyWeekday = f[4] == "*"
        source = raw
    }

    static func field(_ f: String, _ lo: Int, _ hi: Int, names: [String] = []) -> Set<Int>? {
        var out = Set<Int>()
        for part in f.lowercased().split(separator: ",") {
            let stepParts = part.split(separator: "/")
            let step = stepParts.count > 1 ? Int(stepParts[1]) ?? 0 : 1
            guard step > 0 else { return nil }
            func num(_ t: Substring) -> Int? { Int(t) ?? names.firstIndex(of: String(t)).map { $0 + (lo == 1 ? 1 : 0) } }
            var a = lo, b = hi
            let range = stepParts[0]
            if range != "*" {
                let ends = range.split(separator: "-")
                guard let x = num(ends[0]) else { return nil }
                a = x; b = ends.count > 1 ? (num(ends[1]) ?? x) : (stepParts.count > 1 ? hi : x)
            }
            guard a >= lo, b <= hi, a <= b else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out
    }

    private func matchesDay(_ c: DateComponents) -> Bool {
        let dom = days.contains(c.day!), dow = weekdays.contains((c.weekday! + 6) % 7)
        if anyDay && anyWeekday { return true }
        if anyDay { return dow }
        if anyWeekday { return dom }
        return dom || dow           // cron: either field matches when both are restricted
    }

    private func calendar(_ tz: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tz) ?? .current
        return cal
    }

    private static func minuteFloor(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }
    private static func hourStart(_ d: Date, _ cal: Calendar) -> Date { cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: d))! }

    /// First matching minute strictly after `date`.
    func next(after date: Date, tzOffset tz: Int) -> Date? {
        let cal = calendar(tz)
        var t = Self.minuteFloor(date).addingTimeInterval(60)
        for _ in 0..<(366 * 24 * 60) {
            let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: t)
            if !months.contains(c.month!) || !matchesDay(c) { t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t))!; continue }
            if !hours.contains(c.hour!) { t = Self.hourStart(t, cal).addingTimeInterval(3600); continue }
            if minutes.contains(c.minute!) { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    /// Last matching minute at or before `date`.
    func previous(before date: Date, tzOffset tz: Int) -> Date? {
        let cal = calendar(tz)
        var t = Self.minuteFloor(date)
        for _ in 0..<(400 * 24 * 60) {
            let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: t)
            if !months.contains(c.month!) || !matchesDay(c) { t = cal.startOfDay(for: t).addingTimeInterval(-60); continue }
            if !hours.contains(c.hour!) { t = Self.hourStart(t, cal).addingTimeInterval(-60); continue }
            if minutes.contains(c.minute!) { return t }
            t = t.addingTimeInterval(-60)
        }
        return nil
    }

    func describe() -> String {
        let f = source.split(separator: " ").map(String.init)
        guard f.count == 5 else { return source }
        if minutes.count == 60 && hours.count == 24 { return "tiap menit" }
        if hours.count == 24 && anyDay && anyWeekday && months.count == 12 {
            return minutes.count == 1 ? "tiap jam, menit \(minutes.first!)" : "tiap \(60 / max(minutes.count, 1)) menit"
        }
        let time = hours.count == 1 && minutes.count == 1 ? String(format: "%02d:%02d", hours.first!, minutes.first!) : nil
        if let time, anyDay, anyWeekday, months.count == 12 { return "tiap hari \(time)" }
        if let time, anyDay, !anyWeekday, weekdays.count == 1 { return "tiap \(["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"][weekdays.first!]) \(time)" }
        if let time, !anyDay, anyWeekday, days.count == 1 { return "tiap tanggal \(days.first!) \(time)" }
        return source
    }
}
