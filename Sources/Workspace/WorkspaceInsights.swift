import Foundation

/// Portfolio metrics from stored records only. Every figure states its rule; nothing is
/// estimated, and a metric without data is nil (shown as "belum ada data").
struct WorkspaceInsights {
    struct Week: Hashable { let start: Date; let completed: Int; let ciPassed: Int; let ciFailed: Int }
    var activeProjects = 0                 // lifecycle planned/building/live/maintenance, not paused
    var openTasks = 0                      // not done, not archived, top-level and subtasks
    var overdueTasks = 0
    var blockedTasks = 0                   // flagged blocked, or waiting on an open dependency
    var wip = 0                            // In Progress + Review
    var milestonesAtRisk = 0
    var weeks: [Week] = []                 // last 8 weeks, oldest first
    var avgCycleDays: Double?              // In Progress start → Done, tasks completed in the last 90 days
    var cycleSample = 0
    var releasesLast30 = 0
    var ciFailureRate: Double?             // failed ÷ (passed + failed), last 28 days
    var ciRuns = 0

    @MainActor
    static func compute(_ ws: WorkspaceStore, projects scope: Set<String>? = nil, now: Date = Date()) -> WorkspaceInsights {
        var r = WorkspaceInsights()
        let inScope: (String) -> Bool = { scope == nil || scope!.contains($0) }
        let projects = ws.projects.filter { inScope($0.id) }
        r.activeProjects = projects.filter { [.planned, .building, .live, .maintenance].contains($0.lifecycle) && !$0.paused }.count
        let live = Set(projects.filter { $0.lifecycle != .archived }.map(\.id))
        let tasks = ws.tasks.filter { live.contains($0.projectId) && !$0.archived }
        let open = tasks.filter { $0.status != .done }
        r.openTasks = open.count
        r.overdueTasks = open.filter { $0.isOverdue(now) }.count
        r.blockedTasks = open.filter { $0.blocked || !ws.blockers(of: $0.id).isEmpty }.count
        r.wip = open.filter { $0.status == .inProgress || $0.status == .review }.count
        r.milestonesAtRisk = ws.milestones.filter { live.contains($0.projectId) && ws.milestoneAtRisk($0, now: now) }.count

        let cal = Calendar(identifier: .iso8601)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let events = ws.activity.filter { $0.projectId.map(live.contains) ?? false }
        for i in (0..<8).reversed() {
            let start = cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek)!
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)!
            let done = tasks.filter { t in t.completedAt.map { $0 >= start && $0 < end } ?? false }.count
            let ev = events.filter { $0.ts >= start && $0.ts < end }
            r.weeks.append(Week(start: start, completed: done, ciPassed: ev.filter { $0.type == "ci.passed" }.count, ciFailed: ev.filter { $0.type == "ci.failed" }.count))
        }
        let cycles = tasks.compactMap { t -> Double? in
            guard let s = t.startedAt, let d = t.completedAt, d > s, now.timeIntervalSince(d) < 90 * 86400 else { return nil }
            return d.timeIntervalSince(s) / 86400
        }
        r.cycleSample = cycles.count
        r.avgCycleDays = cycles.isEmpty ? nil : cycles.reduce(0, +) / Double(cycles.count)
        let since30 = now.addingTimeInterval(-30 * 86400)
        r.releasesLast30 = ws.releases.filter { live.contains($0.projectId) && ($0.releasedAt.map { $0 >= since30 } ?? false) }.count
            + events.filter { $0.type == "release.published" && $0.ts >= since30 }.count
        let since28 = now.addingTimeInterval(-28 * 86400)
        let ci = events.filter { ($0.type == "ci.passed" || $0.type == "ci.failed") && $0.ts >= since28 }
        r.ciRuns = ci.count
        r.ciFailureRate = ci.isEmpty ? nil : Double(ci.filter { $0.type == "ci.failed" }.count) / Double(ci.count)
        return r
    }
}
