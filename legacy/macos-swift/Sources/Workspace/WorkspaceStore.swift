import Foundation
import Combine

/// Portfolios, projects and their tasks, in workspace.sqlite. Every change is written to
/// the database first (one transaction), then applied in memory; when a write fails the
/// in-memory state is reloaded from the database so the UI never shows unsaved data.
@MainActor
final class WorkspaceStore: ObservableObject {
    /// RAPHAEL_WORKSPACE_DB points a development run at another database file.
    static let defaultPath: String = ProcessInfo.processInfo.environment["RAPHAEL_WORKSPACE_DB"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Raphael/workspace.sqlite").path

    static let shared: WorkspaceStore = WorkspaceStore(path: defaultPath)

    @Published private(set) var portfolios: [Portfolio] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var tasks: [WTask] = []
    @Published private(set) var epics: [Epic] = []
    @Published private(set) var milestones: [Milestone] = []
    @Published private(set) var releases: [Release] = []
    @Published private(set) var checklist: [String: [ChecklistItem]] = [:]     // task id →
    @Published private(set) var dependencies: [TaskDependency] = []
    @Published private(set) var links: [ResourceLink] = []
    @Published private(set) var externals: [ExternalRef] = []
    @Published private(set) var activity: [ActivityEvent] = []                   // newest first, last 2 000
    @Published private(set) var decisions: [String: (decision: String, projectId: String?)] = [:]
    @Published var lastError: String?

    let db: WorkspaceDB?
    /// Name used for "My Work" (tasks assigned to the owner).
    var me: String { UserDefaults.standard.string(forKey: "raphaelWorkspaceMe") ?? "Saya" }

    init(path: String) {
        do {
            let db = try WorkspaceDB(path: path)
            if !db.integrityOK() { _ = try? db.backup(suffix: "corrupt") }
            try db.migrate(WorkspaceSchema.migrations)
            self.db = db
        } catch {
            self.db = nil
            lastError = "\(error)"
        }
        reload()
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: Load

    func reload() {
        guard let db else { return }
        do {
            portfolios = try db.query("SELECT * FROM portfolio ORDER BY archived, sort, name").map(Self.portfolio)
            projects = try db.query("SELECT * FROM project ORDER BY sort, name COLLATE NOCASE").map(Self.project)
            epics = try db.query("SELECT * FROM epic ORDER BY sort, created_at").map(Self.epic)
            milestones = try db.query("SELECT * FROM milestone ORDER BY target_date IS NULL, target_date, created_at").map(Self.milestone)
            releases = try db.query("SELECT * FROM release ORDER BY COALESCE(released_at, target_date) DESC").map(Self.release)
            tasks = try db.query("SELECT * FROM task ORDER BY position").map(Self.task)
            var cl: [String: [ChecklistItem]] = [:]
            for r in try db.query("SELECT * FROM task_checklist ORDER BY position") {
                let i = ChecklistItem(id: r.str("id")!, taskId: r.str("task_id")!, text: r.str("text") ?? "", done: r.bool("done"), position: r.dbl("position") ?? 0)
                cl[i.taskId, default: []].append(i)
            }
            checklist = cl
            dependencies = try db.query("SELECT * FROM task_dependency").map { TaskDependency(taskId: $0.str("task_id")!, dependsOn: $0.str("depends_on")!) }
            links = try db.query("SELECT * FROM resource_link ORDER BY kind, ref").map(Self.link)
            externals = try db.query("SELECT * FROM external_ref").map(Self.external)
            activity = try db.query("SELECT * FROM activity ORDER BY ts DESC LIMIT 2000").map(Self.event)
            var dec: [String: (String, String?)] = [:]
            for r in try db.query("SELECT * FROM registry_decision") { dec[r.str("candidate")!] = (r.str("decision")!, r.str("project_id")) }
            decisions = dec
        } catch {
            lastError = "\(error)"
        }
    }

    /// Runs a write; on failure records the error and reloads from disk.
    @discardableResult
    private func write(_ body: (WorkspaceDB) throws -> Void) -> Bool {
        guard let db else { lastError = "Database tidak tersedia"; return false }
        do {
            try db.transaction { try body(db) }
            return true
        } catch {
            lastError = "\(error)"
            reload()
            return false
        }
    }

    private func json(_ v: some Encodable) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null" }

    private func logEvent(_ db: WorkspaceDB, _ e: ActivityEvent) throws {
        try db.run("INSERT OR IGNORE INTO activity (id, project_id, type, ts, source, title, url, meta) VALUES (?,?,?,?,?,?,?,?)",
                   e.id, e.projectId, e.type, e.ts, e.source, e.title, e.url, json(e.meta))
    }

    private func local(_ projectId: String?, _ type: String, _ title: String, _ meta: [String: String] = [:]) -> ActivityEvent {
        ActivityEvent(id: "raphael:" + Self.newID(), projectId: projectId, type: type, ts: Date(), source: "raphael", title: title, meta: meta)
    }

    // MARK: Portfolios

    @discardableResult
    func createPortfolio(name: String, description: String = "") -> Portfolio? {
        let p = Portfolio(id: Self.newID(), name: name.trimmingCharacters(in: .whitespaces), description: description,
                          sort: (portfolios.map(\.sort).max() ?? 0) + 1)
        guard !p.name.isEmpty else { return nil }
        guard write({ db in
            try db.run("INSERT INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                       p.id, p.name, p.description, p.color, p.archived, p.sort, p.createdAt, p.updatedAt)
        }) else { return nil }
        portfolios.append(p)
        return p
    }

    func updatePortfolio(_ p: Portfolio) {
        var p = p; p.updatedAt = Date()
        guard write({ db in
            try db.run("UPDATE portfolio SET name=?, description=?, color=?, archived=?, sort=?, updated_at=? WHERE id=?",
                       p.name, p.description, p.color, p.archived, p.sort, p.updatedAt, p.id)
        }) else { return }
        if let i = portfolios.firstIndex(where: { $0.id == p.id }) { portfolios[i] = p }
    }

    func setPortfolioArchived(_ id: String, _ archived: Bool) {
        guard var p = portfolios.first(where: { $0.id == id }) else { return }
        p.archived = archived
        updatePortfolio(p)
    }

    // MARK: Projects

    @discardableResult
    func createProject(name: String, portfolioId: String?, lifecycle: Lifecycle = .idea, description: String = "", category: String = "") -> Project? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        var p = Project(id: Self.newID(), portfolioId: portfolioId, name: clean, description: description, category: category, lifecycle: lifecycle)
        p.key = Self.makeKey(clean, taken: Set(projects.map(\.key)))
        p.sort = (projects.filter { $0.lifecycle == lifecycle }.map(\.sort).max() ?? 0) + 1
        let ev = local(p.id, "project.created", "Project \(p.name) dibuat")
        guard write({ db in
            try insertProject(db, p)
            try logEvent(db, ev)
        }) else { return nil }
        projects.append(p)
        activity.insert(ev, at: 0)
        return p
    }

    private func insertProject(_ db: WorkspaceDB, _ p: Project) throws {
        try db.run("""
            INSERT INTO project (id, portfolio_id, name, description, category, labels, lifecycle, paused, priority, favorite, pinned,
              start_date, target_date, key, next_number, sort, wip_limits, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, p.id, p.portfolioId, p.name, p.description, p.category, json(p.labels), p.lifecycle.rawValue, p.paused, p.priority.rawValue,
                   p.favorite, p.pinned, p.startDate, p.targetDate, p.key, p.nextNumber, p.sort, json(p.wipLimits), p.createdAt, p.updatedAt)
    }

    /// "Altora Office" → "AO", "raphael" → "RAP"; unique among projects.
    static func makeKey(_ name: String, taken: Set<String>) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        var base = words.count > 1 ? String(words.prefix(3).compactMap(\.first)) : String((words.first ?? "P").prefix(3))
        if base.isEmpty { base = "P" }
        var key = base, n = 2
        while taken.contains(key) { key = "\(base)\(n)"; n += 1 }
        return key
    }

    func updateProject(_ p: Project) {
        guard let old = projects.first(where: { $0.id == p.id }) else { return }
        var p = p; p.updatedAt = Date()
        var events: [ActivityEvent] = []
        if old.lifecycle != p.lifecycle {
            events.append(local(p.id, "project.lifecycle", "\(p.name): \(old.lifecycle.title) → \(p.lifecycle.title)", ["from": old.lifecycle.rawValue, "to": p.lifecycle.rawValue]))
        }
        guard write({ db in
            try db.run("""
                UPDATE project SET portfolio_id=?, name=?, description=?, category=?, labels=?, lifecycle=?, paused=?, priority=?, favorite=?, pinned=?,
                  start_date=?, target_date=?, key=?, sort=?, wip_limits=?, updated_at=? WHERE id=?
                """, p.portfolioId, p.name, p.description, p.category, json(p.labels), p.lifecycle.rawValue, p.paused, p.priority.rawValue,
                       p.favorite, p.pinned, p.startDate, p.targetDate, p.key, p.sort, json(p.wipLimits), p.updatedAt, p.id)
            for e in events { try logEvent(db, e) }
        }) else { return }
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p }
        activity.insert(contentsOf: events, at: 0)
    }

    /// Portfolio Kanban: drop a project card into a lifecycle column (optionally before another card).
    func moveProject(_ id: String, to lifecycle: Lifecycle, before: String? = nil) {
        guard var p = projects.first(where: { $0.id == id }) else { return }
        let column = projects.filter { $0.lifecycle == lifecycle && $0.id != id }.sorted { $0.sort < $1.sort }
        p.sort = Self.position(in: column.map(\.sort), before: before.flatMap { b in column.firstIndex { $0.id == b } })
        p.lifecycle = lifecycle
        updateProject(p)
    }

    func deleteProject(_ id: String) {
        guard write({ db in try db.run("DELETE FROM project WHERE id=?", id) }) else { return }
        reload()
    }

    // MARK: Ordering

    /// Sort key for inserting at `index` of a column whose items have `positions` (ascending).
    /// nil index = append. Midpoints keep other rows untouched.
    nonisolated static func position(in positions: [Double], before index: Int?) -> Double {
        guard let index, index < positions.count else { return (positions.last ?? 0) + 1024 }
        let next = positions[index]
        let prev = index > 0 ? positions[index - 1] : next - 2048
        return (prev + next) / 2
    }

    // MARK: Tasks

    func tasks(of projectId: String, includeArchived: Bool = false) -> [WTask] {
        tasks.filter { $0.projectId == projectId && (includeArchived || !$0.archived) }
    }

    func column(_ projectId: String, _ status: TaskStatus) -> [WTask] {
        tasks.filter { $0.projectId == projectId && $0.status == status && !$0.archived && $0.parentId == nil }.sorted { $0.position < $1.position }
    }

    @discardableResult
    func createTask(projectId: String, title: String, status: TaskStatus = .backlog, parentId: String? = nil,
                    priority: Priority = .none, assignee: String = "", dueDate: Date? = nil, milestoneId: String? = nil, epicId: String? = nil) -> WTask? {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let number = projects[pIdx].nextNumber
        var t = WTask(id: Self.newID(), number: number, projectId: projectId, epicId: epicId, milestoneId: milestoneId, parentId: parentId,
                      title: clean, status: status, priority: priority, assignee: assignee, dueDate: dueDate)
        t.position = (column(projectId, status).last?.position ?? 0) + 1024
        if status == .inProgress { t.startedAt = Date() }
        if status == .done { t.completedAt = Date() }
        let ev = local(projectId, "task.created", "\(t.code(projects[pIdx])) dibuat: \(clean)", ["task": t.id])
        guard write({ db in
            try insertTask(db, t)
            try db.run("UPDATE project SET next_number = next_number + 1 WHERE id=?", projectId)
            try logEvent(db, ev)
        }) else { return nil }
        projects[pIdx].nextNumber += 1
        tasks.append(t)
        activity.insert(ev, at: 0)
        return t
    }

    private func insertTask(_ db: WorkspaceDB, _ t: WTask) throws {
        try db.run("""
            INSERT INTO task (id, number, project_id, epic_id, milestone_id, parent_id, title, description, status, position, priority, assignee,
              labels, due_date, blocked, blocked_reason, archived, started_at, completed_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, t.id, t.number, t.projectId, t.epicId, t.milestoneId, t.parentId, t.title, t.description, t.status.rawValue, t.position,
                   t.priority.rawValue, t.assignee, json(t.labels), t.dueDate, t.blocked, t.blockedReason, t.archived, t.startedAt, t.completedAt,
                   t.createdAt, t.updatedAt)
    }

    /// Saves every editable field; status changes go through the same rules as moves.
    func updateTask(_ t: WTask) {
        guard let old = tasks.first(where: { $0.id == t.id }) else { return }
        var t = t
        t.updatedAt = Date()
        Self.applyStatusDates(&t, from: old.status)
        let events = statusEvents(old: old, new: t)
        guard write({ db in
            try db.run("""
                UPDATE task SET epic_id=?, milestone_id=?, parent_id=?, title=?, description=?, status=?, position=?, priority=?, assignee=?,
                  labels=?, due_date=?, blocked=?, blocked_reason=?, archived=?, started_at=?, completed_at=?, updated_at=? WHERE id=?
                """, t.epicId, t.milestoneId, t.parentId, t.title, t.description, t.status.rawValue, t.position, t.priority.rawValue, t.assignee,
                       json(t.labels), t.dueDate, t.blocked, t.blockedReason, t.archived, t.startedAt, t.completedAt, t.updatedAt, t.id)
            for e in events { try logEvent(db, e) }
        }) else { return }
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t }
        activity.insert(contentsOf: events, at: 0)
    }

    nonisolated static func applyStatusDates(_ t: inout WTask, from old: TaskStatus) {
        guard t.status != old else { return }
        if t.status == .inProgress, t.startedAt == nil { t.startedAt = Date() }
        if t.status == .done { t.completedAt = t.completedAt ?? Date() } else { t.completedAt = nil }
    }

    private func statusEvents(old: WTask, new t: WTask) -> [ActivityEvent] {
        let proj = projects.first { $0.id == t.projectId }
        var out: [ActivityEvent] = []
        if old.status != t.status {
            out.append(local(t.projectId, t.status == .done ? "task.completed" : "task.status",
                             t.status == .done ? "\(t.code(proj)) selesai: \(t.title)" : "\(t.code(proj)): \(old.status.title) → \(t.status.title)",
                             ["task": t.id, "from": old.status.rawValue, "to": t.status.rawValue]))
        }
        if old.blocked != t.blocked { out.append(local(t.projectId, t.blocked ? "task.blocked" : "task.unblocked", "\(t.code(proj)) \(t.blocked ? "terblokir" : "tidak terblokir lagi")", ["task": t.id])) }
        if !old.archived && t.archived { out.append(local(t.projectId, "task.archived", "\(t.code(proj)) diarsipkan", ["task": t.id])) }
        return out
    }

    /// Drag & drop: move a task into `status`, before `before` (nil = end). Atomic: the task
    /// row (and, when gaps run out, the column's positions) change in one transaction.
    func moveTask(_ id: String, to status: TaskStatus, before: String? = nil) {
        guard let old = tasks.first(where: { $0.id == id }), before != id else { return }
        var col = column(old.projectId, status).filter { $0.id != id }
        let idx = before.flatMap { b in col.firstIndex { $0.id == b } }
        var renumber: [(String, Double)] = []
        var pos = Self.position(in: col.map(\.position), before: idx)
        // Gaps too small to split again: spread the column out evenly.
        let neighbours = idx.map { i in [i > 0 ? col[i - 1].position : nil, col[i].position].compactMap { $0 } } ?? []
        if neighbours.count == 2, abs(neighbours[1] - neighbours[0]) < 1e-6 {
            var t = old; t.status = status
            col.insert(t, at: idx!)
            renumber = col.enumerated().map { ($0.element.id, Double($0.offset + 1) * 1024) }
            pos = renumber.first { $0.0 == id }!.1
        }
        var t = old
        t.status = status
        t.position = pos
        t.updatedAt = Date()
        Self.applyStatusDates(&t, from: old.status)
        let events = statusEvents(old: old, new: t)
        guard write({ db in
            for (rid, p) in renumber where rid != id { try db.run("UPDATE task SET position=? WHERE id=?", p, rid) }
            try db.run("UPDATE task SET status=?, position=?, started_at=?, completed_at=?, updated_at=? WHERE id=?",
                       t.status.rawValue, t.position, t.startedAt, t.completedAt, t.updatedAt, id)
            for e in events { try logEvent(db, e) }
        }) else { return }
        for (rid, p) in renumber { if let i = tasks.firstIndex(where: { $0.id == rid }) { tasks[i].position = p } }
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i] = t }
        activity.insert(contentsOf: events, at: 0)
    }

    func archiveTask(_ id: String, _ archived: Bool = true) {
        guard var t = tasks.first(where: { $0.id == id }) else { return }
        t.archived = archived
        updateTask(t)
    }

    func deleteTask(_ id: String) {
        guard write({ db in try db.run("DELETE FROM task WHERE id=?", id) }) else { return }
        let gone = Set([id] + tasks.filter { $0.parentId == id }.map(\.id))
        tasks.removeAll { gone.contains($0.id) }
        dependencies.removeAll { gone.contains($0.taskId) || gone.contains($0.dependsOn) }
        for g in gone { checklist[g] = nil }
    }

    func subtasks(of id: String) -> [WTask] { tasks.filter { $0.parentId == id && !$0.archived }.sorted { $0.position < $1.position } }

    // MARK: Checklist

    func addChecklistItem(_ taskId: String, _ text: String) {
        let clean = text.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let item = ChecklistItem(id: Self.newID(), taskId: taskId, text: clean, position: (checklist[taskId]?.last?.position ?? 0) + 1)
        guard write({ db in try db.run("INSERT INTO task_checklist (id, task_id, text, done, position) VALUES (?,?,?,?,?)", item.id, taskId, clean, false, item.position) }) else { return }
        checklist[taskId, default: []].append(item)
    }

    func toggleChecklistItem(_ item: ChecklistItem) {
        guard write({ db in try db.run("UPDATE task_checklist SET done=? WHERE id=?", !item.done, item.id) }) else { return }
        if let i = checklist[item.taskId]?.firstIndex(where: { $0.id == item.id }) { checklist[item.taskId]![i].done.toggle() }
    }

    func removeChecklistItem(_ item: ChecklistItem) {
        guard write({ db in try db.run("DELETE FROM task_checklist WHERE id=?", item.id) }) else { return }
        checklist[item.taskId]?.removeAll { $0.id == item.id }
    }

    // MARK: Dependencies

    /// `task` waits for `dependsOn`. Refused when it would create a cycle.
    @discardableResult
    func addDependency(_ task: String, dependsOn: String) -> Bool {
        guard task != dependsOn, !dependencies.contains(TaskDependency(taskId: task, dependsOn: dependsOn)) else { return false }
        if Self.reaches(from: dependsOn, to: task, deps: dependencies) { lastError = "Dependensi ini membuat siklus"; return false }
        guard write({ db in try db.run("INSERT OR IGNORE INTO task_dependency (task_id, depends_on) VALUES (?,?)", task, dependsOn) }) else { return false }
        dependencies.append(TaskDependency(taskId: task, dependsOn: dependsOn))
        return true
    }

    func removeDependency(_ d: TaskDependency) {
        guard write({ db in try db.run("DELETE FROM task_dependency WHERE task_id=? AND depends_on=?", d.taskId, d.dependsOn) }) else { return }
        dependencies.removeAll { $0 == d }
    }

    nonisolated static func reaches(from: String, to: String, deps: [TaskDependency]) -> Bool {
        var stack = [from], seen = Set<String>()
        while let n = stack.popLast() {
            if n == to { return true }
            guard seen.insert(n).inserted else { continue }
            stack += deps.filter { $0.taskId == n }.map(\.dependsOn)
        }
        return false
    }

    /// Open tasks this task waits for.
    func blockers(of id: String) -> [WTask] {
        let ids = Set(dependencies.filter { $0.taskId == id }.map(\.dependsOn))
        return tasks.filter { ids.contains($0.id) && $0.status != .done && !$0.archived }
    }

    // MARK: Epics, milestones, releases

    @discardableResult
    func createEpic(_ projectId: String, title: String, targetDate: Date? = nil) -> Epic? {
        let e = Epic(id: Self.newID(), projectId: projectId, title: title, targetDate: targetDate, sort: Double(epics.count))
        guard !title.isEmpty, write({ db in
            try db.run("INSERT INTO epic (id, project_id, title, description, start_date, target_date, done, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       e.id, projectId, e.title, e.description, e.startDate, e.targetDate, e.done, e.sort, e.createdAt, e.updatedAt)
        }) else { return nil }
        epics.append(e)
        return e
    }

    func updateEpic(_ e: Epic) {
        var e = e; e.updatedAt = Date()
        guard write({ db in
            try db.run("UPDATE epic SET title=?, description=?, start_date=?, target_date=?, done=?, sort=?, updated_at=? WHERE id=?",
                       e.title, e.description, e.startDate, e.targetDate, e.done, e.sort, e.updatedAt, e.id)
        }) else { return }
        if let i = epics.firstIndex(where: { $0.id == e.id }) { epics[i] = e }
    }

    func deleteEpic(_ id: String) {
        guard write({ db in try db.run("DELETE FROM epic WHERE id=?", id) }) else { return }
        epics.removeAll { $0.id == id }
        for i in tasks.indices where tasks[i].epicId == id { tasks[i].epicId = nil }
    }

    @discardableResult
    func createMilestone(_ projectId: String, title: String, targetDate: Date? = nil) -> Milestone? {
        let m = Milestone(id: Self.newID(), projectId: projectId, title: title, targetDate: targetDate)
        guard !title.isEmpty, write({ db in
            try db.run("INSERT INTO milestone (id, project_id, title, description, target_date, completed_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                       m.id, projectId, m.title, m.description, m.targetDate, m.completedAt, m.createdAt, m.updatedAt)
        }) else { return nil }
        milestones.append(m)
        return m
    }

    func updateMilestone(_ m: Milestone) {
        guard let old = milestones.first(where: { $0.id == m.id }) else { return }
        var m = m; m.updatedAt = Date()
        let ev = old.completedAt == nil && m.completedAt != nil ? local(m.projectId, "milestone.completed", "Milestone selesai: \(m.title)", ["milestone": m.id]) : nil
        guard write({ db in
            try db.run("UPDATE milestone SET title=?, description=?, target_date=?, completed_at=?, updated_at=? WHERE id=?",
                       m.title, m.description, m.targetDate, m.completedAt, m.updatedAt, m.id)
            if let ev { try logEvent(db, ev) }
        }) else { return }
        if let i = milestones.firstIndex(where: { $0.id == m.id }) { milestones[i] = m }
        if let ev { activity.insert(ev, at: 0) }
    }

    func deleteMilestone(_ id: String) {
        guard write({ db in try db.run("DELETE FROM milestone WHERE id=?", id) }) else { return }
        milestones.removeAll { $0.id == id }
        for i in tasks.indices where tasks[i].milestoneId == id { tasks[i].milestoneId = nil }
    }

    @discardableResult
    func createRelease(_ projectId: String, name: String, version: String = "", targetDate: Date? = nil) -> Release? {
        let r = Release(id: Self.newID(), projectId: projectId, name: name, version: version, targetDate: targetDate)
        guard !name.isEmpty, write({ db in
            try db.run("INSERT INTO release (id, project_id, name, version, target_date, released_at, notes, created_at) VALUES (?,?,?,?,?,?,?,?)",
                       r.id, projectId, r.name, r.version, r.targetDate, r.releasedAt, r.notes, r.createdAt)
        }) else { return nil }
        releases.insert(r, at: 0)
        return r
    }

    func updateRelease(_ r: Release) {
        guard write({ db in
            try db.run("UPDATE release SET name=?, version=?, target_date=?, released_at=?, notes=? WHERE id=?", r.name, r.version, r.targetDate, r.releasedAt, r.notes, r.id)
        }) else { return }
        if let i = releases.firstIndex(where: { $0.id == r.id }) { releases[i] = r }
    }

    func deleteRelease(_ id: String) {
        guard write({ db in try db.run("DELETE FROM release WHERE id=?", id) }) else { return }
        releases.removeAll { $0.id == id }
    }

    // MARK: Progress (explicit rule)

    /// Done ÷ planned, counting non-archived top-level tasks. nil = nothing planned → unmeasured.
    nonisolated static func progress(_ items: [WTask]) -> (done: Int, total: Int, ratio: Double?) {
        let planned = items.filter { !$0.archived && $0.parentId == nil }
        let done = planned.filter { $0.status == .done }.count
        return (done, planned.count, planned.isEmpty ? nil : Double(done) / Double(planned.count))
    }

    func progress(project id: String) -> (done: Int, total: Int, ratio: Double?) { Self.progress(tasks(of: id)) }
    func progress(milestone id: String) -> (done: Int, total: Int, ratio: Double?) { Self.progress(tasks.filter { $0.milestoneId == id }) }
    func progress(epic id: String) -> (done: Int, total: Int, ratio: Double?) { Self.progress(tasks.filter { $0.epicId == id }) }

    /// Milestone at risk: not completed and past its date, or due within 7 days with less than 70% done.
    func milestoneAtRisk(_ m: Milestone, now: Date = Date()) -> Bool {
        guard m.completedAt == nil, let target = m.targetDate else { return false }
        if target < now { return true }
        let p = progress(milestone: m.id)
        return target.timeIntervalSince(now) < 7 * 86400 && (p.ratio ?? 0) < 0.7
    }

    func nextMilestone(_ projectId: String) -> Milestone? {
        milestones.filter { $0.projectId == projectId && $0.completedAt == nil }
            .sorted { ($0.targetDate ?? .distantFuture) < ($1.targetDate ?? .distantFuture) }.first
    }

    // MARK: Resource links

    @discardableResult
    func addLink(_ projectId: String, kind: ResourceLink.Kind, ref: String, label: String = "", environment: String = "", source: String = "manual") -> ResourceLink? {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        if let existing = links.first(where: { $0.projectId == projectId && $0.kind == kind && $0.ref == ref }) { return existing }
        let l = ResourceLink(id: Self.newID(), projectId: projectId, kind: kind, ref: ref, label: label, environment: environment, source: source)
        guard write({ db in
            try db.run("INSERT OR IGNORE INTO resource_link (id, project_id, kind, ref, label, environment, source, created_at) VALUES (?,?,?,?,?,?,?,?)",
                       l.id, projectId, kind.rawValue, ref, label, environment, source, l.createdAt)
        }) else { return nil }
        links.append(l)
        return l
    }

    func updateLink(_ l: ResourceLink) {
        guard write({ db in try db.run("UPDATE resource_link SET label=?, environment=? WHERE id=?", l.label, l.environment, l.id) }) else { return }
        if let i = links.firstIndex(where: { $0.id == l.id }) { links[i] = l }
    }

    func removeLink(_ id: String) {
        guard write({ db in try db.run("DELETE FROM resource_link WHERE id=?", id) }) else { return }
        links.removeAll { $0.id == id }
    }

    func links(of projectId: String, _ kind: ResourceLink.Kind? = nil) -> [ResourceLink] {
        links.filter { $0.projectId == projectId && (kind == nil || $0.kind == kind) }
    }

    // MARK: External references + activity (sync)

    func external(system: String, id: String) -> ExternalRef? { externals.first { $0.system == system && $0.externalId == id } }

    /// Idempotent: (system, externalId) is unique, so repeated syncs update the same row.
    func upsertExternal(_ r: ExternalRef) {
        guard write({ db in
            try db.run("""
                INSERT INTO external_ref (id, entity, entity_id, system, external_id, url, state, synced_at) VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(system, external_id) DO UPDATE SET url=excluded.url, state=excluded.state, synced_at=excluded.synced_at
                """, r.id, r.entity, r.entityId, r.system, r.externalId, r.url, r.state, r.syncedAt)
        }) else { return }
        if let i = externals.firstIndex(where: { $0.system == r.system && $0.externalId == r.externalId }) {
            externals[i].url = r.url; externals[i].state = r.state; externals[i].syncedAt = r.syncedAt
        } else { externals.append(r) }
    }

    /// Records events whose ids are not stored yet; returns how many were new.
    @discardableResult
    func record(_ events: [ActivityEvent]) -> Int {
        let known = Set(activity.map(\.id))
        let fresh = events.filter { !known.contains($0.id) }
        guard !fresh.isEmpty, let db else { return 0 }
        var inserted: [ActivityEvent] = []
        do {
            try db.transaction {
                for e in fresh {
                    let n = try db.run("INSERT OR IGNORE INTO activity (id, project_id, type, ts, source, title, url, meta) VALUES (?,?,?,?,?,?,?,?)",
                                       e.id, e.projectId, e.type, e.ts, e.source, e.title, e.url, json(e.meta))
                    if n > 0 { inserted.append(e) }
                }
            }
        } catch { lastError = "\(error)"; return 0 }
        activity = (activity + inserted).sorted { $0.ts > $1.ts }
        if activity.count > 2000 { activity.removeLast(activity.count - 2000) }
        return inserted.count
    }

    func events(project: String? = nil, types: Set<String>? = nil, since: Date? = nil) -> [ActivityEvent] {
        activity.filter { (project == nil || $0.projectId == project) && (types == nil || types!.contains($0.type)) && (since == nil || $0.ts >= since!) }
    }

    func syncState(_ key: String) -> String? {
        ((try? db?.query("SELECT value FROM sync_state WHERE key=?", key).first?.str("value")) ?? nil)
    }

    func setSyncState(_ key: String, _ value: String) {
        write { db in
            try db.run("INSERT INTO sync_state (key, value, updated_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
                       key, value, Date())
        }
    }

    // MARK: Discovery decisions

    func decide(_ candidate: String, _ decision: String, projectId: String?) {
        guard write({ db in
            try db.run("INSERT INTO registry_decision (candidate, decision, project_id, updated_at) VALUES (?,?,?,?) ON CONFLICT(candidate) DO UPDATE SET decision=excluded.decision, project_id=excluded.project_id, updated_at=excluded.updated_at",
                       candidate, decision, projectId, Date())
        }) else { return }
        decisions[candidate] = (decision, projectId)
    }

    func undecide(_ candidate: String) {
        guard write({ db in try db.run("DELETE FROM registry_decision WHERE candidate=?", candidate) }) else { return }
        decisions[candidate] = nil
    }

    // MARK: Export / import

    struct Export: Codable {
        var version: Int
        var exportedAt: Date
        var portfolios: [Portfolio]; var projects: [Project]; var epics: [Epic]; var milestones: [Milestone]; var releases: [Release]
        var tasks: [WTask]; var checklist: [ChecklistItem]; var dependencies: [TaskDependency]; var links: [ResourceLink]
        var externals: [ExternalRef]; var activity: [ActivityEvent]
    }

    func exportData() throws -> Data {
        let e = Export(version: db?.userVersion ?? 0, exportedAt: Date(), portfolios: portfolios, projects: projects, epics: epics, milestones: milestones,
                       releases: releases, tasks: tasks, checklist: checklist.values.flatMap { $0 }, dependencies: dependencies, links: links,
                       externals: externals, activity: activity)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return try enc.encode(e)
    }

    /// Merges an export: existing ids are kept, new ones are added (never deletes local data).
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let e = try dec.decode(Export.self, from: data)
        guard let db else { throw WorkspaceDB.DBError.open("tidak tersedia") }
        try? db.backup(suffix: "pre-import")
        var added = 0
        try db.transaction {
            for p in e.portfolios {
                added += try db.run("INSERT OR IGNORE INTO portfolio (id, name, description, color, archived, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                                    p.id, p.name, p.description, p.color, p.archived, p.sort, p.createdAt, p.updatedAt)
            }
            for p in e.projects where (try db.scalar("SELECT COUNT(*) FROM project WHERE id=?", p.id)) == 0 { try insertProject(db, p); added += 1 }
            for x in e.epics {
                added += try db.run("INSERT OR IGNORE INTO epic (id, project_id, title, description, start_date, target_date, done, sort, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                    x.id, x.projectId, x.title, x.description, x.startDate, x.targetDate, x.done, x.sort, x.createdAt, x.updatedAt)
            }
            for m in e.milestones {
                added += try db.run("INSERT OR IGNORE INTO milestone (id, project_id, title, description, target_date, completed_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                                    m.id, m.projectId, m.title, m.description, m.targetDate, m.completedAt, m.createdAt, m.updatedAt)
            }
            for r in e.releases {
                added += try db.run("INSERT OR IGNORE INTO release (id, project_id, name, version, target_date, released_at, notes, created_at) VALUES (?,?,?,?,?,?,?,?)",
                                    r.id, r.projectId, r.name, r.version, r.targetDate, r.releasedAt, r.notes, r.createdAt)
            }
            // Parents before subtasks.
            for t in e.tasks.sorted(by: { ($0.parentId == nil ? 0 : 1) < ($1.parentId == nil ? 0 : 1) })
            where (try db.scalar("SELECT COUNT(*) FROM task WHERE id=?", t.id)) == 0 {
                var t = t
                if (try db.scalar("SELECT COUNT(*) FROM task WHERE project_id=? AND number=?", t.projectId, t.number)) > 0 {
                    t.number = (try db.scalar("SELECT COALESCE(MAX(number),0)+1 FROM task WHERE project_id=?", t.projectId))
                }
                try insertTask(db, t); added += 1
            }
            for c in e.checklist { added += try db.run("INSERT OR IGNORE INTO task_checklist (id, task_id, text, done, position) VALUES (?,?,?,?,?)", c.id, c.taskId, c.text, c.done, c.position) }
            for d in e.dependencies { added += try db.run("INSERT OR IGNORE INTO task_dependency (task_id, depends_on) VALUES (?,?)", d.taskId, d.dependsOn) }
            for l in e.links {
                added += try db.run("INSERT OR IGNORE INTO resource_link (id, project_id, kind, ref, label, environment, source, created_at) VALUES (?,?,?,?,?,?,?,?)",
                                    l.id, l.projectId, l.kind.rawValue, l.ref, l.label, l.environment, l.source, l.createdAt)
            }
            for x in e.externals {
                added += try db.run("INSERT OR IGNORE INTO external_ref (id, entity, entity_id, system, external_id, url, state, synced_at) VALUES (?,?,?,?,?,?,?,?)",
                                    x.id, x.entity, x.entityId, x.system, x.externalId, x.url, x.state, x.syncedAt)
            }
            for a in e.activity { try logEvent(db, a) }
            try db.run("UPDATE project SET next_number = MAX(next_number, (SELECT COALESCE(MAX(number),0)+1 FROM task WHERE task.project_id = project.id))")
        }
        reload()
        return added
    }

    // MARK: Row mapping

    private static func decode<T: Decodable>(_ s: String?, _ fallback: T) -> T {
        s.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) } ?? fallback
    }
    private static func portfolio(_ r: WorkspaceDB.Row) -> Portfolio {
        Portfolio(id: r.str("id")!, name: r.str("name") ?? "", description: r.str("description") ?? "", color: r.str("color") ?? "violet",
                  archived: r.bool("archived"), sort: r.dbl("sort") ?? 0, createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }
    private static func project(_ r: WorkspaceDB.Row) -> Project {
        Project(id: r.str("id")!, portfolioId: r.str("portfolio_id"), name: r.str("name") ?? "", description: r.str("description") ?? "",
                category: r.str("category") ?? "", labels: decode(r.str("labels"), []), lifecycle: Lifecycle(rawValue: r.str("lifecycle") ?? "") ?? .idea,
                paused: r.bool("paused"), priority: Priority(rawValue: r.int("priority") ?? 0) ?? .none, favorite: r.bool("favorite"), pinned: r.bool("pinned"),
                startDate: r.date("start_date"), targetDate: r.date("target_date"), key: r.str("key") ?? "", nextNumber: r.int("next_number") ?? 1,
                sort: r.dbl("sort") ?? 0, wipLimits: decode(r.str("wip_limits"), [:]), createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }
    private static func epic(_ r: WorkspaceDB.Row) -> Epic {
        Epic(id: r.str("id")!, projectId: r.str("project_id")!, title: r.str("title") ?? "", description: r.str("description") ?? "",
             startDate: r.date("start_date"), targetDate: r.date("target_date"), done: r.bool("done"), sort: r.dbl("sort") ?? 0,
             createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }
    private static func milestone(_ r: WorkspaceDB.Row) -> Milestone {
        Milestone(id: r.str("id")!, projectId: r.str("project_id")!, title: r.str("title") ?? "", description: r.str("description") ?? "",
                  targetDate: r.date("target_date"), completedAt: r.date("completed_at"), createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }
    private static func release(_ r: WorkspaceDB.Row) -> Release {
        Release(id: r.str("id")!, projectId: r.str("project_id")!, name: r.str("name") ?? "", version: r.str("version") ?? "",
                targetDate: r.date("target_date"), releasedAt: r.date("released_at"), notes: r.str("notes") ?? "", createdAt: r.date("created_at") ?? Date())
    }
    private static func task(_ r: WorkspaceDB.Row) -> WTask {
        WTask(id: r.str("id")!, number: r.int("number") ?? 0, projectId: r.str("project_id")!, epicId: r.str("epic_id"), milestoneId: r.str("milestone_id"),
              parentId: r.str("parent_id"), title: r.str("title") ?? "", description: r.str("description") ?? "",
              status: TaskStatus(rawValue: r.str("status") ?? "") ?? .backlog, position: r.dbl("position") ?? 0,
              priority: Priority(rawValue: r.int("priority") ?? 0) ?? .none, assignee: r.str("assignee") ?? "", labels: decode(r.str("labels"), []),
              dueDate: r.date("due_date"), blocked: r.bool("blocked"), blockedReason: r.str("blocked_reason") ?? "", archived: r.bool("archived"),
              startedAt: r.date("started_at"), completedAt: r.date("completed_at"), createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }
    private static func link(_ r: WorkspaceDB.Row) -> ResourceLink {
        ResourceLink(id: r.str("id")!, projectId: r.str("project_id")!, kind: ResourceLink.Kind(rawValue: r.str("kind") ?? "") ?? .app,
                     ref: r.str("ref") ?? "", label: r.str("label") ?? "", environment: r.str("environment") ?? "", source: r.str("source") ?? "manual",
                     createdAt: r.date("created_at") ?? Date())
    }
    private static func external(_ r: WorkspaceDB.Row) -> ExternalRef {
        ExternalRef(id: r.str("id")!, entity: r.str("entity") ?? "", entityId: r.str("entity_id") ?? "", system: r.str("system") ?? "",
                    externalId: r.str("external_id") ?? "", url: r.str("url") ?? "", state: r.str("state") ?? "", syncedAt: r.date("synced_at") ?? Date())
    }
    private static func event(_ r: WorkspaceDB.Row) -> ActivityEvent {
        ActivityEvent(id: r.str("id")!, projectId: r.str("project_id"), type: r.str("type") ?? "", ts: r.date("ts") ?? Date(),
                      source: r.str("source") ?? "", title: r.str("title") ?? "", url: r.str("url") ?? "", meta: decode(r.str("meta"), [:]))
    }
}
