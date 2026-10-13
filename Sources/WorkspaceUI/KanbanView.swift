import SwiftUI

/// Filters shared by the board and the task list.
struct TaskFilter: Equatable {
    var query = ""
    var assignee = ""
    var priority: Priority?
    var milestoneId = ""
    var epicId = ""
    var label = ""
    var onlyBlocked = false
    var onlyOverdue = false

    @MainActor
    func matches(_ t: WTask, _ ws: WorkspaceStore) -> Bool {
        (query.isEmpty || t.title.localizedCaseInsensitiveContains(query) || t.description.localizedCaseInsensitiveContains(query)
            || "\(t.number)" == query.trimmingCharacters(in: CharacterSet.letters.union(.punctuationCharacters))) &&
        (assignee.isEmpty || t.assignee == assignee) && (priority == nil || t.priority == priority) &&
        (milestoneId.isEmpty || t.milestoneId == milestoneId) && (epicId.isEmpty || t.epicId == epicId) &&
        (label.isEmpty || t.labels.contains(label)) &&
        (!onlyBlocked || t.blocked || !ws.blockers(of: t.id).isEmpty) && (!onlyOverdue || t.isOverdue())
    }
    var isActive: Bool { self != TaskFilter() }
}

struct TaskFilterBar: View {
    let projectId: String
    @Binding var filter: TaskFilter
    @ObservedObject private var ws = WorkspaceStore.shared
    var body: some View {
        let ts = ws.tasks(of: projectId)
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            TextField("Cari task…", text: $filter.query).textFieldStyle(.roundedBorder).frame(width: 180)
            let people = Array(Set(ts.map(\.assignee).filter { !$0.isEmpty })).sorted()
            Picker("", selection: $filter.assignee) { Text("Semua orang").tag(""); ForEach(people, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            Picker("", selection: Binding(get: { filter.priority?.rawValue ?? -1 }, set: { filter.priority = Priority(rawValue: $0) })) {
                Text("Semua prioritas").tag(-1); ForEach(Priority.allCases) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
            let ms = ws.milestones.filter { $0.projectId == projectId }
            if !ms.isEmpty {
                Picker("", selection: $filter.milestoneId) { Text("Semua milestone").tag(""); ForEach(ms) { Text($0.title).tag($0.id) } }.labelsHidden().fixedSize()
            }
            let es = ws.epics.filter { $0.projectId == projectId }
            if !es.isEmpty {
                Picker("", selection: $filter.epicId) { Text("Semua epic").tag(""); ForEach(es) { Text($0.title).tag($0.id) } }.labelsHidden().fixedSize()
            }
            let labels = Array(Set(ts.flatMap(\.labels))).sorted()
            if !labels.isEmpty {
                Picker("", selection: $filter.label) { Text("Semua label").tag(""); ForEach(labels, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            Toggle("Terblokir", isOn: $filter.onlyBlocked).toggleStyle(.checkbox).fixedSize()
            Toggle("Lewat tenggat", isOn: $filter.onlyOverdue).toggleStyle(.checkbox).fixedSize()
            if filter.isActive { Button("Reset") { filter = TaskFilter() }.buttonStyle(.link) }
        } }
        .font(.system(size: 12))
    }
}

/// Native Kanban: drag between and within columns, quick add, WIP limits, keyboard moves.
struct KanbanBoard: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var filter = TaskFilter()
    @State private var selected: String?
    @State private var detail: String?
    @State private var drafts: [TaskStatus: String] = [:]
    @State private var hovered: TaskStatus?
    @FocusState private var boardFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TaskFilterBar(projectId: projectId, filter: $filter)
                    Button { addTask(.backlog, "Task baru") } label: { Label("Task", systemImage: "plus") }
                        .buttonStyle(RPillButton(primary: true)).keyboardShortcut("n", modifiers: .command).help("Task baru (⌘N)")
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(TaskStatus.allCases) { s in column(s) }
                    }
                    .padding(.bottom, 8)
                }
                Text("Klik kartu untuk memilih · ↩ buka · ⌘← ⌘→ pindah kolom · ⌘↑ ⌘↓ urutan · ⌫ arsipkan · drag untuk memindah")
                    .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .focusable().focused($boardFocused).focusEffectDisabled()
            .onKeyPress(phases: .down) { key in handleKey(key) }
            if let d = detail {
                Rectangle().fill(RTheme.line).frame(width: 1)
                TaskDetailPanel(taskId: d, close: { detail = nil }).frame(width: 420).id(d)
            }
        }
        .onAppear(perform: openRequested)
        .onChange(of: UserDefaults.standard.string(forKey: "raphaelOpenTask")) { _, _ in openRequested() }
    }

    private func openRequested() {
        if let id = UserDefaults.standard.string(forKey: "raphaelOpenTask"), ws.tasks.contains(where: { $0.id == id && $0.projectId == projectId }) {
            UserDefaults.standard.removeObject(forKey: "raphaelOpenTask")
            selected = id; detail = id
        }
    }

    private func items(_ s: TaskStatus) -> [WTask] { ws.column(projectId, s).filter { filter.matches($0, ws) } }

    private func column(_ s: TaskStatus) -> some View {
        let list = items(s)
        let total = ws.column(projectId, s).count
        let limit = ws.projects.first { $0.id == projectId }?.wipLimits[s.rawValue]
        let over = limit.map { total > $0 } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(s.title).font(.system(size: 13, weight: .bold))
                Text(limit.map { "\(total)/\($0)" } ?? "\(total)").font(.system(size: 11.5, weight: over ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(over ? RTheme.red : RTheme.muted)
                    .help(over ? "Melebihi batas WIP" : "Jumlah task")
                Spacer()
                Button { addTask(s, "Task baru") } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(RTheme.muted).help("Task baru di \(s.title)")
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(list) { t in
                        TaskCard(task: t, selected: selected == t.id)
                            .onTapGesture(count: 2) { selected = t.id; detail = t.id }
                            .onTapGesture { selected = t.id; boardFocused = true; if detail != nil { detail = t.id } }
                            .draggable(t.id) { TaskCard(task: t, selected: true).frame(width: 250).opacity(0.9) }
                            .dropDestination(for: String.self) { ids, _ in drop(ids, s, before: t.id) }
                            .contextMenu { taskMenu(t) }
                    }
                    TextField("+ Tambah task", text: Binding(get: { drafts[s] ?? "" }, set: { drafts[s] = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(8).background(RTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { addTask(s, drafts[s] ?? ""); drafts[s] = "" }
                    Color.clear.frame(height: 30)
                }
            }
        }
        .padding(10)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(hovered == s ? RTheme.violetSoft : (over ? RTheme.redSoft : RTheme.wash), in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { ids, _ in drop(ids, s, before: nil) } isTargeted: { hovered = $0 ? s : (hovered == s ? nil : hovered) }
        .accessibilityLabel("Kolom \(s.title), \(total) task")
    }

    private func drop(_ ids: [String], _ s: TaskStatus, before: String?) -> Bool {
        guard let id = ids.first, ws.tasks.contains(where: { $0.id == id && $0.projectId == projectId }) else { return false }
        ws.moveTask(id, to: s, before: before)
        selected = id
        return true
    }

    private func addTask(_ s: TaskStatus, _ title: String) {
        let t = ws.createTask(projectId: projectId, title: title, status: s, assignee: "")
        if let t, title == "Task baru" { selected = t.id; detail = t.id }
    }

    @ViewBuilder private func taskMenu(_ t: WTask) -> some View {
        Button("Buka detail") { selected = t.id; detail = t.id }
        Menu("Pindah ke") { ForEach(TaskStatus.allCases) { s in Button(s.title) { ws.moveTask(t.id, to: s) } } }
        Menu("Prioritas") { ForEach(Priority.allCases) { p in Button(p.title) { var x = t; x.priority = p; ws.updateTask(x) } } }
        Button(t.blocked ? "Tandai tidak terblokir" : "Tandai terblokir") { var x = t; x.blocked.toggle(); ws.updateTask(x) }
        Button(t.assignee == ws.me ? "Lepas dari saya" : "Tugaskan ke saya") { var x = t; x.assignee = t.assignee == ws.me ? "" : ws.me; ws.updateTask(x) }
        Divider()
        Button("Arsipkan") { ws.archiveTask(t.id) }
        Button("Hapus", role: .destructive) { ws.deleteTask(t.id); if detail == t.id { detail = nil } }
    }

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        guard let id = selected, let t = ws.tasks.first(where: { $0.id == id }) else { return .ignored }
        let cols = TaskStatus.allCases
        let ci = cols.firstIndex(of: t.status) ?? 0
        let col = items(t.status)
        let i = col.firstIndex { $0.id == id } ?? 0
        let cmd = key.modifiers.contains(.command)
        switch key.key {
        case .return: detail = id; return .handled
        case .rightArrow where cmd: if ci + 1 < cols.count { ws.moveTask(id, to: cols[ci + 1]) }; return .handled
        case .leftArrow where cmd: if ci > 0 { ws.moveTask(id, to: cols[ci - 1]) }; return .handled
        case .upArrow where cmd: if i > 0 { ws.moveTask(id, to: t.status, before: col[i - 1].id) }; return .handled
        case .downArrow where cmd:
            if i + 2 < col.count { ws.moveTask(id, to: t.status, before: col[i + 2].id) } else if i + 1 < col.count { ws.moveTask(id, to: t.status) }
            return .handled
        case .upArrow: if i > 0 { selected = col[i - 1].id }; return .handled
        case .downArrow: if i + 1 < col.count { selected = col[i + 1].id }; return .handled
        case .rightArrow: if let n = cols.dropFirst(ci + 1).lazy.compactMap({ items($0).first }).first { selected = n.id }; return .handled
        case .leftArrow: if let n = cols.prefix(ci).reversed().lazy.compactMap({ items($0).first }).first { selected = n.id }; return .handled
        case .delete, .deleteForward: ws.archiveTask(id); selected = nil; if detail == id { detail = nil }; return .handled
        case .escape: if detail != nil { detail = nil } else { selected = nil }; return .handled
        default: return .ignored
        }
    }
}

struct TaskCard: View {
    let task: WTask
    var selected = false
    @ObservedObject private var ws = WorkspaceStore.shared

    var body: some View {
        let p = ws.projects.first { $0.id == task.projectId }
        let blockers = ws.blockers(of: task.id)
        let cl = ws.checklist[task.id] ?? []
        let subs = ws.subtasks(of: task.id)
        let gh = ws.externals.first { $0.entity == "task" && $0.entityId == task.id }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                PriorityIcon(priority: task.priority)
                Text(task.code(p)).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
                if gh != nil { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9)).foregroundStyle(RTheme.muted).help(gh!.externalId) }
                Spacer()
                if task.blocked || !blockers.isEmpty {
                    Label(task.blocked ? "Terblokir" : "Menunggu \(blockers.count)", systemImage: "hand.raised.fill")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(RTheme.amber)
                        .help(task.blocked ? (task.blockedReason.isEmpty ? "Ditandai terblokir" : task.blockedReason) : "Menunggu: " + blockers.map { $0.code(p) }.joined(separator: ", "))
                }
            }
            Text(task.title).font(.system(size: 12.5, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !task.labels.isEmpty { LabelChips(labels: task.labels) }
            HStack(spacing: 8) {
                if let d = task.dueDate {
                    Label(WFormat.due(d), systemImage: "calendar").font(.system(size: 10.5, weight: task.isOverdue() ? .semibold : .regular))
                        .foregroundStyle(task.isOverdue() ? RTheme.red : RTheme.muted)
                }
                if !cl.isEmpty { Label("\(cl.filter(\.done).count)/\(cl.count)", systemImage: "checklist").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                if !subs.isEmpty { Label("\(subs.filter { $0.status == .done }.count)/\(subs.count)", systemImage: "list.bullet.indent").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                Spacer()
                if !task.assignee.isEmpty {
                    Text(String(task.assignee.prefix(2)).uppercased()).font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20).background(RTheme.violetSoft, in: Circle()).foregroundStyle(RTheme.violet).help(task.assignee)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? RTheme.violet : (task.isOverdue() ? RTheme.red.opacity(0.4) : RTheme.line), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.code(p)) \(task.title), \(task.status.title)")
    }
}

/// Table view of the same task records.
struct TaskListView: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var filter = TaskFilter()
    @State private var detail: String?
    @State private var sort = "status"
    @State private var showDone = true
    @State private var showArchived = false
    @State private var newTitle = ""
    @State private var tableWidth: CGFloat = 1000
    private var showMilestone: Bool { tableWidth > 860 }
    private var showAssignee: Bool { tableWidth > 720 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TaskFilterBar(projectId: projectId, filter: $filter)
                    Toggle("Done", isOn: $showDone).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
                    Toggle("Arsip", isOn: $showArchived).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize()
                }
                HStack {
                    TextField("Task baru… (↩ untuk menambah)", text: $newTitle).textFieldStyle(.roundedBorder)
                        .onSubmit { if ws.createTask(projectId: projectId, title: newTitle) != nil { newTitle = "" } }
                }
                VStack(spacing: 0) {
                    HStack {
                        head("ID", "number", 64)
                        head("Judul", "title", nil)
                        head("Status", "status", 112)
                        head("Prioritas", "priority", 84)
                        if showAssignee { head("Orang", "assignee", 80) }
                        head("Tenggat", "due", 72)
                        if showMilestone { head("Milestone", "milestone", 120) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider().overlay(RTheme.line)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { t in
                                row(t)
                                ForEach(ws.subtasks(of: t.id).filter { filter.matches($0, ws) }) { s in row(s, indent: true) }
                            }
                        }
                    }
                }
                .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(RTheme.line))
                .background(GeometryReader { g in Color.clear.onAppear { tableWidth = g.size.width }.onChange(of: g.size.width) { _, w in tableWidth = w } })
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(minWidth: 0, maxWidth: .infinity)
            if let d = detail {
                Rectangle().fill(RTheme.line).frame(width: 1)
                TaskDetailPanel(taskId: d, close: { detail = nil }).frame(width: 420).id(d)
            }
        }
        .onAppear {
            if let id = UserDefaults.standard.string(forKey: "raphaelOpenTask"), ws.tasks.contains(where: { $0.id == id }) {
                UserDefaults.standard.removeObject(forKey: "raphaelOpenTask"); detail = id
            }
        }
    }

    private var rows: [WTask] {
        let base = ws.tasks(of: projectId, includeArchived: showArchived).filter { $0.parentId == nil && (showDone || $0.status != .done) && filter.matches($0, ws) }
        let order = TaskStatus.allCases
        return base.sorted { a, b in
            switch sort {
            case "number": return a.number < b.number
            case "title": return a.title.lowercased() < b.title.lowercased()
            case "priority": return (a.priority.rawValue, -a.number) > (b.priority.rawValue, -b.number)
            case "assignee": return (a.assignee, a.number) < (b.assignee, b.number)
            case "due": return (a.dueDate ?? .distantFuture, a.number) < (b.dueDate ?? .distantFuture, b.number)
            case "milestone": return (a.milestoneId ?? "~", a.number) < (b.milestoneId ?? "~", b.number)
            default: return (order.firstIndex(of: a.status)!, a.position) < (order.firstIndex(of: b.status)!, b.position)
            }
        }
    }

    private func head(_ t: String, _ key: String, _ w: CGFloat?) -> some View {
        Button { sort = key } label: {
            HStack(spacing: 3) { Text(t); if sort == key { Image(systemName: "chevron.down").font(.system(size: 8)) } }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
        .frame(minWidth: w ?? 180, maxWidth: w ?? .infinity, alignment: .leading)
        .layoutPriority(w == nil ? 1 : 0)
    }

    private func row(_ t: WTask, indent: Bool = false) -> some View {
        let p = ws.projects.first { $0.id == t.projectId }
        return HStack {
            Text(t.code(p)).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).frame(width: 64, alignment: .leading)
            HStack(spacing: 6) {
                if indent { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(RTheme.muted) }
                Text(t.title).font(.system(size: 12.5)).strikethrough(t.status == .done, color: RTheme.muted).lineLimit(1)
                if t.blocked || !ws.blockers(of: t.id).isEmpty { Image(systemName: "hand.raised.fill").font(.system(size: 9.5)).foregroundStyle(RTheme.amber) }
                if t.archived { RChip(text: "arsip", tint: RTheme.muted) }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Menu {
                ForEach(TaskStatus.allCases) { s in Button(s.title) { ws.moveTask(t.id, to: s) } }
            } label: { Text(t.status.title).font(.system(size: 11.5)).lineLimit(1) }
                .menuStyle(.borderlessButton).menuIndicator(.visible).frame(width: 112, alignment: .leading)
            HStack(spacing: 4) { PriorityIcon(priority: t.priority); Text(t.priority.title).font(.system(size: 11.5)).lineLimit(1) }.frame(width: 84, alignment: .leading)
            if showAssignee { Text(t.assignee.isEmpty ? "–" : t.assignee).font(.system(size: 11.5)).lineLimit(1).frame(width: 80, alignment: .leading) }
            Text(t.dueDate.map(WFormat.due) ?? "–").font(.system(size: 11.5, weight: t.isOverdue() ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(t.isOverdue() ? RTheme.red : RTheme.navy).frame(width: 72, alignment: .leading)
            if showMilestone { Text(ws.milestones.first { $0.id == t.milestoneId }?.title ?? "–").font(.system(size: 11.5)).lineLimit(1).frame(width: 120, alignment: .leading) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(detail == t.id ? RTheme.violetSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture { detail = t.id }
    }
}
