import Foundation

// Workspace tests: plain executable (no XCTest needed). scripts/test.sh builds and runs it.

var failures = 0, checks = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("  ✗ \(msg)  (\((file as NSString).lastPathComponent):\(line))") }
}
func section(_ name: String, _ body: () throws -> Void) {
    print("▸ \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw \(error)") }
}
let dir = NSTemporaryDirectory() + "raphael-tests-\(UUID().uuidString)"
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }

MainActor.assumeIsolated {
    let path = dir + "/workspace.sqlite"

    section("schema + CRUD + restart persistence") {
        let s = WorkspaceStore(path: path)
        check(s.lastError == nil, "opens: \(s.lastError ?? "")")
        check(s.db?.userVersion == WorkspaceSchema.migrations.last!.version, "migrated to latest")
        let pf = s.createPortfolio(name: "Altora")!
        let p = s.createProject(name: "Altora Office", portfolioId: pf.id, lifecycle: .building)!
        check(p.key == "AO", "key from initials: \(p.key)")
        let p2 = s.createProject(name: "Altora Open", portfolioId: pf.id)!
        check(p2.key == "AO2", "unique key: \(p2.key)")
        check(s.createProject(name: "   ", portfolioId: nil) == nil, "empty name refused")
        let t1 = s.createTask(projectId: p.id, title: "Login")!
        let t2 = s.createTask(projectId: p.id, title: "Dashboard")!
        let t3 = s.createTask(projectId: p.id, title: "Export")!
        check(t1.number == 1 && t2.number == 2 && t3.number == 3, "sequential task numbers")
        check(s.column(p.id, .backlog).map(\.id) == [t1.id, t2.id, t3.id], "append order")
        s.moveTask(t3.id, to: .backlog, before: t1.id)
        check(s.column(p.id, .backlog).map(\.id) == [t3.id, t1.id, t2.id], "reorder inside column")
        s.moveTask(t1.id, to: .inProgress)
        check(s.tasks.first { $0.id == t1.id }?.startedAt != nil, "startedAt set entering In Progress")
        s.moveTask(t1.id, to: .done)
        check(s.tasks.first { $0.id == t1.id }?.completedAt != nil, "completedAt set entering Done")
        s.moveTask(t1.id, to: .review)
        check(s.tasks.first { $0.id == t1.id }?.completedAt == nil, "completedAt cleared leaving Done")
        s.addChecklistItem(t2.id, "Grafik")
        let sub = s.createTask(projectId: p.id, title: "Sub", parentId: t2.id)!
        check(s.subtasks(of: t2.id).map(\.id) == [sub.id], "subtask")
        check(!s.column(p.id, .backlog).contains { $0.id == sub.id }, "subtasks not on the board")
        let m = s.createMilestone(p.id, title: "Beta", targetDate: Date().addingTimeInterval(86400 * 3))!
        var t2b = s.tasks.first { $0.id == t2.id }!; t2b.milestoneId = m.id; s.updateTask(t2b)
        s.addLink(p.id, kind: .repo, ref: "Cat-tj/altora-office")
        s.addLink(p.id, kind: .repo, ref: "Cat-tj/altora-office")
        check(s.links(of: p.id, .repo).count == 1, "link not duplicated")

        // Restart: a fresh store on the same file sees everything.
        let r = WorkspaceStore(path: path)
        check(r.portfolios.count == 1 && r.projects.count == 2, "portfolios/projects persisted")
        check(r.column(p.id, .backlog).map(\.id) == [t3.id, t2.id], "board order persisted")
        check(r.tasks.first { $0.id == t1.id }?.status == .review, "status persisted")
        check(r.checklist[t2.id]?.first?.text == "Grafik", "checklist persisted")
        check(r.tasks.first { $0.id == t2.id }?.milestoneId == m.id, "milestone link persisted")
        check(r.projects.first { $0.id == p.id }?.nextNumber == 5, "task counter persisted")
        check(r.activity.contains { $0.type == "task.completed" }, "activity persisted")
    }

    section("progress rule + milestone risk") {
        let s = WorkspaceStore(path: dir + "/progress.sqlite")
        let p = s.createProject(name: "P", portfolioId: nil)!
        check(s.progress(project: p.id).ratio == nil, "no tasks → unmeasured")
        let a = s.createTask(projectId: p.id, title: "a")!, b = s.createTask(projectId: p.id, title: "b")!
        _ = s.createTask(projectId: p.id, title: "sub", parentId: a.id)
        s.moveTask(a.id, to: .done)
        let pr = s.progress(project: p.id)
        check(pr.done == 1 && pr.total == 2 && pr.ratio == 0.5, "done ÷ planned top-level tasks: \(pr)")
        s.archiveTask(b.id)
        check(s.progress(project: p.id).ratio == 1, "archived tasks excluded")
        let late = s.createMilestone(p.id, title: "late", targetDate: Date().addingTimeInterval(-86400))!
        check(s.milestoneAtRisk(late), "past target → at risk")
        let far = s.createMilestone(p.id, title: "far", targetDate: Date().addingTimeInterval(86400 * 60))!
        check(!s.milestoneAtRisk(far), "far target → not at risk")
    }

    section("drag & drop: positions, gap exhaustion, no loss/duplication") {
        let s = WorkspaceStore(path: dir + "/dnd.sqlite")
        let p = s.createProject(name: "D", portfolioId: nil)!
        let ids = (1...6).map { s.createTask(projectId: p.id, title: "t\($0)")!.id }
        // Repeatedly insert before the same card until midpoints collapse → column is renumbered.
        for _ in 0..<80 { s.moveTask(ids[5], to: .backlog, before: ids[1]); s.moveTask(ids[4], to: .backlog, before: ids[5]) }
        let col = s.column(p.id, .backlog)
        check(col.count == 6 && Set(col.map(\.id)) == Set(ids), "6 cards, none lost or duplicated")
        check(zip(col, col.dropFirst()).allSatisfy { $0.position < $1.position }, "strictly increasing positions")
        // Rapid cross-column moves.
        for i in 0..<30 { s.moveTask(ids[i % 6], to: TaskStatus.allCases[i % 5], before: nil) }
        let all = TaskStatus.allCases.flatMap { s.column(p.id, $0) }
        check(all.count == 6 && Set(all.map(\.id)).count == 6, "after many moves every card exists once")
        let r = WorkspaceStore(path: dir + "/dnd.sqlite")
        check(TaskStatus.allCases.flatMap { r.column(p.id, $0) }.map(\.id) == all.map(\.id), "same order after restart")
        s.moveTask(ids[0], to: .ready, before: ids[0])
        check(s.tasks.filter { $0.id == ids[0] }.count == 1, "drop on itself is a no-op")
    }

    section("dependencies refuse cycles") {
        let s = WorkspaceStore(path: dir + "/deps.sqlite")
        let p = s.createProject(name: "Q", portfolioId: nil)!
        let a = s.createTask(projectId: p.id, title: "a")!, b = s.createTask(projectId: p.id, title: "b")!, c = s.createTask(projectId: p.id, title: "c")!
        check(s.addDependency(b.id, dependsOn: a.id), "b waits for a")
        check(s.addDependency(c.id, dependsOn: b.id), "c waits for b")
        check(!s.addDependency(a.id, dependsOn: c.id), "a → c would cycle")
        check(!s.addDependency(a.id, dependsOn: a.id), "self dependency refused")
        check(s.blockers(of: c.id).map(\.id) == [b.id], "blockers = open prerequisites")
        s.moveTask(b.id, to: .done)
        check(s.blockers(of: c.id).isEmpty, "done prerequisite no longer blocks")
    }

    section("sync idempotency: activity + external refs") {
        let s = WorkspaceStore(path: dir + "/sync.sqlite")
        let p = s.createProject(name: "S", portfolioId: nil)!
        let before = s.activity.count
        let evs = (1...5).map { ActivityEvent(id: "github:commit:abc\($0)", projectId: p.id, type: "github.commit", ts: Date().addingTimeInterval(Double(-$0)), source: "github", title: "c\($0)") }
        check(s.record(evs) == 5, "first sync inserts 5")
        check(s.record(evs) == 0, "second identical sync inserts 0")
        check(s.record(evs + [ActivityEvent(id: "github:commit:new", projectId: p.id, type: "github.commit", ts: Date(), source: "github", title: "n")]) == 1, "only the new event")
        check(s.activity.count == before + 6, "no duplicate events in memory")
        let r = WorkspaceStore(path: dir + "/sync.sqlite")
        check(r.activity.filter { $0.source == "github" }.count == 6, "no duplicates on disk")
        let t = s.createTask(projectId: p.id, title: "issue")!
        for state in ["open", "open", "closed"] {
            s.upsertExternal(ExternalRef(id: WorkspaceStore.newID(), entity: "task", entityId: t.id, system: "github", externalId: "o/r#1", state: state))
        }
        check(s.externals.filter { $0.externalId == "o/r#1" }.count == 1 && s.external(system: "github", id: "o/r#1")?.state == "closed", "external ref upserted, not duplicated")
        check((try? s.db?.scalar("SELECT COUNT(*) FROM external_ref")) == 1, "one external row on disk")
    }

    section("export / import merge") {
        let a = WorkspaceStore(path: dir + "/exp.sqlite")
        let p = a.createProject(name: "E", portfolioId: a.createPortfolio(name: "X")!.id)!
        let t = a.createTask(projectId: p.id, title: "x")!
        a.addChecklistItem(t.id, "c")
        let data = try a.exportData()
        let b = WorkspaceStore(path: dir + "/imp.sqlite")
        let n = try b.importData(data)
        check(n > 0 && b.projects.count == 1 && b.tasks.count == 1 && b.checklist[t.id]?.count == 1, "import restores records")
        check(((try? b.importData(data)) ?? -1) == 0, "re-import adds nothing")
        check(b.projects.first?.nextNumber == 2, "task counter after import")
    }

    section("migration safety: newer migration, existing data kept, backup taken") {
        let p = dir + "/mig.sqlite"
        let s = WorkspaceStore(path: p)
        _ = s.createProject(name: "Keep", portfolioId: nil)
        let db = try WorkspaceDB(path: p)
        try db.migrate(WorkspaceSchema.migrations + [(version: 99, sql: "ALTER TABLE project ADD COLUMN extra TEXT NOT NULL DEFAULT ''")])
        check(db.userVersion == 99, "additive migration applied")
        check(((try? db.scalar("SELECT COUNT(*) FROM project")) ?? 0) == 1, "data kept")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/backups")) ?? []
        check(backups.contains { $0.contains("pre-v99") }, "backup before migration")
        // A failing migration rolls back and leaves the version untouched.
        do { try db.migrate([(version: 100, sql: "ALTER TABLE nope ADD COLUMN x")]); check(false, "bad migration should throw") } catch {}
        check(db.userVersion == 99, "failed migration rolled back")
        let reopened = WorkspaceStore(path: p)
        check(reopened.projects.count == 1 && reopened.lastError == nil, "store opens a newer schema")
    }

    section("malformed data") {
        let p = dir + "/bad.sqlite"
        try "not a database".write(toFile: p, atomically: true, encoding: .utf8)
        let s = WorkspaceStore(path: p)
        check(s.lastError != nil, "garbage file reported, not crashing")
        check(s.createProject(name: "x", portfolioId: nil) == nil, "writes refused without a database")
        let ok = WorkspaceStore(path: dir + "/json.sqlite")
        check((try? ok.importData(Data("{oops".utf8))) == nil, "bad import JSON throws")
        check(ok.projects.isEmpty, "bad import changed nothing")
    }

    section("insights use stored data only") {
        let s = WorkspaceStore(path: dir + "/ins.sqlite")
        let empty = WorkspaceInsights.compute(s)
        check(empty.activeProjects == 0 && empty.openTasks == 0, "empty workspace → zeros")
        check(empty.avgCycleDays == nil && empty.ciFailureRate == nil, "no data → nil, not fabricated")
        check(empty.weeks.count == 8 && empty.weeks.allSatisfy { $0.completed == 0 }, "8 empty weeks")
        let p = s.createProject(name: "I", portfolioId: nil, lifecycle: .building)!
        _ = s.createProject(name: "Paused", portfolioId: nil, lifecycle: .building).map { var x = $0; x.paused = true; s.updateProject(x) }
        let a = s.createTask(projectId: p.id, title: "a", dueDate: Date().addingTimeInterval(-3 * 86400))!
        let b = s.createTask(projectId: p.id, title: "b")!
        s.moveTask(b.id, to: .inProgress)
        var bb = s.tasks.first { $0.id == b.id }!; bb.startedAt = Date().addingTimeInterval(-2 * 86400); s.updateTask(bb)
        s.moveTask(b.id, to: .done)
        var c = s.createTask(projectId: p.id, title: "c")!; c.blocked = true; s.updateTask(c)
        s.record([ActivityEvent(id: "github:ci:1|\(p.id)", projectId: p.id, type: "ci.failed", ts: Date(), source: "github", title: "x"),
                  ActivityEvent(id: "github:ci:2|\(p.id)", projectId: p.id, type: "ci.passed", ts: Date(), source: "github", title: "y")])
        let i = WorkspaceInsights.compute(s)
        check(i.activeProjects == 1, "paused projects not active: \(i.activeProjects)")
        check(i.openTasks == 2 && i.overdueTasks == 1 && i.blockedTasks == 1, "open/overdue/blocked: \(i.openTasks)/\(i.overdueTasks)/\(i.blockedTasks)")
        check(i.weeks.last?.completed == 1, "completed this week")
        check(i.cycleSample == 1 && abs((i.avgCycleDays ?? 0) - 2) < 0.1, "cycle time from startedAt → completedAt: \(i.avgCycleDays ?? -1)")
        check(i.ciRuns == 2 && i.ciFailureRate == 0.5, "CI failure rate from events")
        _ = a
    }

    section("cron expressions") {
        let tz = 8 * 3600
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: tz)!
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 19, minute: 7))!   // Sunday
        func hm(_ d: Date?) -> String { d.map { let c = cal.dateComponents([.day, .hour, .minute, .weekday], from: $0); return "\(c.day!) \(c.hour!):\(c.minute!) w\(c.weekday!)" } ?? "nil" }
        check(hm(CronExpr("30 2 * * *")!.next(after: base, tzOffset: tz)) == "12 2:30 w2", "daily 02:30 → tomorrow")
        check(hm(CronExpr("30 2 * * *")!.previous(before: base, tzOffset: tz)) == "11 2:30 w1", "previous daily run today")
        check(hm(CronExpr("5-55/10 * * * *")!.next(after: base, tzOffset: tz)) == "11 19:15 w1", "every 10 min from :05")
        check(hm(CronExpr("0 8 * * 1")!.next(after: base, tzOffset: tz)) == "12 8:0 w2", "weekly Monday 08:00")
        check(hm(CronExpr("@hourly")!.next(after: base, tzOffset: tz)) == "11 20:0 w1", "@hourly")
        check(hm(CronExpr("0 0 1 * *")!.next(after: base, tzOffset: tz)) == "1 0:0 w1" || hm(CronExpr("0 0 1 * *")!.next(after: base, tzOffset: tz)).hasPrefix("1 0:0"), "monthly on the 1st")
        check(CronExpr("bad expr") == nil && CronExpr("61 * * * *") == nil, "invalid expressions rejected")
        check(CronExpr("30 2 * * *")!.describe() == "tiap hari 02:30", "describe daily")
        // A daily job whose last run was 2 days ago is "missed"; one that ran this morning is not.
        let stale = MJob.parse(["kind": "cron", "id": "a", "name": "backup", "expr": "30 2 * * *", "last": NSNumber(value: Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970), "status": "ok"], tz: tz)
        check(stale.missed && stale.health == .missed, "missed run detected")
        let failing = MJob.parse(["kind": "cron", "id": "b", "name": "backup", "expr": "30 2 * * *", "status": "failed", "detail": "pg_dump: error"], tz: tz)
        check(failing.health == .failed, "failed status wins")
        let unknown = MJob.parse(["kind": "cron", "id": "c", "name": "x", "expr": "*/5 * * * *"], tz: tz)
        check(unknown.health == .unknown && !unknown.missed, "no run data → unknown, not healthy")
    }

    section("ordering helper") {
        check(WorkspaceStore.position(in: [], before: nil) == 1024, "empty column")
        check(WorkspaceStore.position(in: [1024, 2048], before: 1) == 1536, "midpoint")
        check(WorkspaceStore.position(in: [1024], before: 0) < 1024, "before first")
        check(WorkspaceStore.makeKey("raphael", taken: []) == "RAP", "single-word key")
    }
}

print(failures == 0 ? "✓ \(checks) checks passed" : "✗ \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
