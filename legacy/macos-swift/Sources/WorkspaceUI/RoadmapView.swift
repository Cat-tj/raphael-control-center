import SwiftUI

/// Roadmap over the same task/milestone/epic records the board uses. projectId nil = every project.
struct RoadmapPage: View {
    let projectId: String?
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelRoadmapMonths") private var months = 6
    @State private var offset = -1            // months before today shown at the left edge
    @State private var portfolioId = ""
    @State private var showDone = false
    @State private var showTasks = true
    @State private var editing: Milestone?
    @State private var editingEpic: Epic?
    @State private var newMilestone = ""
    @State private var newEpic = ""
    @State private var newRelease = ""

    private var start: Date {
        let cal = Calendar.current
        let m = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return cal.date(byAdding: .month, value: offset, to: m)!
    }
    private var end: Date { Calendar.current.date(byAdding: .month, value: months, to: start)! }

    private var projects: [Project] {
        if let projectId { return ws.projects.filter { $0.id == projectId } }
        return ws.projects.filter { $0.lifecycle != .archived && (portfolioId.isEmpty || $0.portfolioId == portfolioId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if projectId == nil { RPageTitle(title: "Roadmap", subtitle: "Milestone, epic dan tenggat semua project di satu timeline") }
            toolbar
            timeline
            if let pid = projectId { manage(pid) } else { milestoneList }
        }
        .sheet(item: $editing) { MilestoneEditor(milestone: $0) }
        .sheet(item: $editingEpic) { EpicEditor(epic: $0) }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controls; Spacer(); legendRow }
            VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { controls }; legendRow }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var controls: some View {
        Group {
            Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(RPillButton()).help("Bulan sebelumnya")
            Button("Hari ini") { offset = -1 }.buttonStyle(RPillButton())
            Button { offset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(RPillButton()).help("Bulan berikutnya")
            Picker("", selection: $months) { Text("3 bulan").tag(3); Text("6 bulan").tag(6); Text("12 bulan").tag(12) }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if projectId == nil && !ws.portfolios.isEmpty {
                Picker("", selection: $portfolioId) { Text("Semua portfolio").tag(""); ForEach(ws.portfolios.filter { !$0.archived }) { Text($0.name).tag($0.id) } }
                    .labelsHidden().fixedSize()
            }
            Toggle("Tampilkan selesai", isOn: $showDone).toggleStyle(.checkbox).fixedSize()
            Toggle("Tenggat task", isOn: $showTasks).toggleStyle(.checkbox).fixedSize()
        }
    }

    private var legendRow: some View {
        HStack(spacing: 10) {
            legend("diamond.fill", "Milestone", RTheme.violet)
            legend("rectangle.fill", "Epic", RTheme.blue)
            legend("circle.fill", "Tenggat task", RTheme.muted)
            legend("exclamationmark.triangle.fill", "Terlambat", RTheme.red)
        }
        .fixedSize()
    }

    private func legend(_ icon: String, _ t: String, _ c: Color) -> some View {
        HStack(spacing: 3) { Image(systemName: icon).font(.system(size: 8)).foregroundStyle(c); Text(t).foregroundStyle(RTheme.muted) }.font(.system(size: 10.5))
    }

    // MARK: Timeline

    private var timeline: some View {
        RCard(padding: 0) {
            GeometryReader { geo in
                let labelW: CGFloat = 170
                let w = max(geo.size.width - labelW - 16, 200)
                let span = end.timeIntervalSince(start)
                let x: (Date) -> CGFloat = { d in labelW + CGFloat(d.timeIntervalSince(start) / span) * w }
                ZStack(alignment: .topLeading) {
                    // Month grid.
                    ForEach(0...months, id: \.self) { i in
                        let d = Calendar.current.date(byAdding: .month, value: i, to: start)!
                        Rectangle().fill(RTheme.line).frame(width: 1).offset(x: x(d))
                        if i < months {
                            Text(d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RTheme.muted)
                                .offset(x: x(d) + 6, y: 8)
                        }
                    }
                    if Date() > start && Date() < end {
                        Rectangle().fill(RTheme.red.opacity(0.7)).frame(width: 1.5).offset(x: x(Date()))
                        Text("hari ini").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(RTheme.red).offset(x: x(Date()) + 3, y: 22)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 38)
                        ForEach(rows) { r in
                            ZStack(alignment: .topLeading) {
                                Text(r.label).font(.system(size: r.isProject ? 12.5 : 11.5, weight: r.isProject ? .bold : .regular))
                                    .foregroundStyle(r.isProject ? RTheme.navy : RTheme.ink2).lineLimit(1).frame(width: labelW - 16, alignment: .leading)
                                    .padding(.leading, r.isProject ? 12 : 22).padding(.top, 5)
                                let xs = r.items.compactMap { $0.date.map(x) }.sorted()
                                ForEach(r.items) { item in
                                    let me = item.date.map(x) ?? 0
                                    let room = (xs.first { $0 > me + 1 } ?? labelW + w) - me - 18
                                    mark(item, x: x, clampMin: labelW, clampMax: labelW + w, room: max(room, 0))
                                }
                            }
                            .frame(height: r.isProject ? 26 : 24, alignment: .topLeading)
                            .background(r.isProject ? RTheme.wash.opacity(0.6) : .clear)
                        }
                        if rows.isEmpty {
                            Text("Belum ada milestone, epic atau tenggat di rentang ini. Tambahkan di bawah, atau geser rentangnya.")
                                .font(.system(size: 12)).foregroundStyle(RTheme.muted).padding(16)
                        }
                    }
                }
            }
            .frame(height: CGFloat(48 + rows.reduce(0) { $0 + ($1.isProject ? 26 : 24) } + (rows.isEmpty ? 50 : 10)))
            .clipped()
        }
    }

    struct TLItem: Identifiable {
        enum Kind { case milestone(Milestone), epic(Epic), task(WTask), release(Release) }
        let id: String
        let kind: Kind
        var date: Date? {
            switch kind {
            case .milestone(let m): m.targetDate
            case .release(let r): r.releasedAt ?? r.targetDate
            case .task(let t): t.dueDate
            case .epic: nil
            }
        }
    }
    struct TLRow: Identifiable { let id: String; let label: String; let isProject: Bool; let items: [TLItem] }

    private var rows: [TLRow] {
        var out: [TLRow] = []
        let inRange: (Date?) -> Bool = { d in d.map { $0 >= start && $0 <= end } ?? false }
        for p in projects {
            let ms = ws.milestones.filter { $0.projectId == p.id && (showDone || $0.completedAt == nil) && inRange($0.targetDate) }
            let es = ws.epics.filter { e in e.projectId == p.id && (showDone || !e.done) && (inRange(e.targetDate) || inRange(e.startDate) || (e.startDate.map { $0 < start } ?? false) && (e.targetDate.map { $0 > end } ?? false)) }
            let rs = ws.releases.filter { $0.projectId == p.id && inRange($0.releasedAt ?? $0.targetDate) }
            let ts = showTasks ? ws.tasks(of: p.id).filter { $0.parentId == nil && (showDone || $0.status != .done) && inRange($0.dueDate) } : []
            guard !(ms.isEmpty && es.isEmpty && ts.isEmpty && rs.isEmpty) else { continue }
            out.append(TLRow(id: "p:\(p.id)", label: p.name, isProject: true,
                             items: ms.map { TLItem(id: "m:\($0.id)", kind: .milestone($0)) } + rs.map { TLItem(id: "r:\($0.id)", kind: .release($0)) }))
            for e in es { out.append(TLRow(id: "e:\(e.id)", label: e.title, isProject: false, items: [TLItem(id: "e:\(e.id)", kind: .epic(e))])) }
            if !ts.isEmpty { out.append(TLRow(id: "t:\(p.id)", label: "Tenggat task", isProject: false, items: ts.map { TLItem(id: "t:\($0.id)", kind: .task($0)) })) }
        }
        return out
    }

    @ViewBuilder
    private func mark(_ item: TLItem, x: (Date) -> CGFloat, clampMin: CGFloat, clampMax: CGFloat, room: CGFloat) -> some View {
        switch item.kind {
        case .milestone(let m):
            let late = m.completedAt == nil && (m.targetDate ?? .distantFuture) < Date()
            let risk = ws.milestoneAtRisk(m)
            Button { editing = m } label: {
                HStack(spacing: 3) {
                    Image(systemName: m.completedAt != nil ? "checkmark.diamond.fill" : late ? "exclamationmark.triangle.fill" : "diamond.fill")
                        .font(.system(size: 11)).foregroundStyle(m.completedAt != nil ? RTheme.green : late || risk ? RTheme.red : RTheme.violet)
                    if room > 24 {
                        Text(m.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: min(room, 200), alignment: .leading)
                    }
                }
                .fixedSize(horizontal: room <= 24, vertical: true)
            }
            .buttonStyle(.plain)
            .help("\(m.title) · \(WFormat.date(m.targetDate)) · \(progressText(ws.progress(milestone: m.id)))")
            .offset(x: x(m.targetDate!) - 6, y: 5)
        case .release(let r):
            Label(r.version.isEmpty ? r.name : r.version, systemImage: r.releasedAt != nil ? "shippingbox.fill" : "shippingbox")
                .font(.system(size: 10.5)).foregroundStyle(RTheme.mint).fixedSize()
                .offset(x: x((r.releasedAt ?? r.targetDate)!) - 6, y: 5)
                .help("Release \(r.name) \(r.version)")
        case .epic(let e):
            let s = max(x(e.startDate ?? e.createdAt), clampMin), f = min(x(e.targetDate ?? end), clampMax)
            let late = !e.done && (e.targetDate ?? .distantFuture) < Date()
            let p = ws.progress(epic: e.id)
            Button { editingEpic = e } label: {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill((late ? RTheme.red : RTheme.blue).opacity(0.18))
                    RoundedRectangle(cornerRadius: 4).fill(late ? RTheme.red : RTheme.blue).frame(width: max(0, (f - s) * CGFloat(p.ratio ?? 0)))
                }
                .frame(width: max(f - s, 6), height: 12)
            }
            .buttonStyle(.plain)
            .help("\(e.title) · \(progressText(p))\(e.targetDate.map { " · target \(WFormat.date($0))" } ?? "")")
            .offset(x: s, y: 6)
        case .task(let t):
            Button { WorkspaceNav.openTask(t) } label: {
                Circle().fill(t.isOverdue() ? RTheme.red : t.status == .done ? RTheme.green : RTheme.muted).frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .help("\(t.code(ws.projects.first { $0.id == t.projectId })) \(t.title) · \(WFormat.date(t.dueDate))")
            .offset(x: x(t.dueDate!) - 4, y: 8)
        }
    }

    private func progressText(_ p: (done: Int, total: Int, ratio: Double?)) -> String {
        p.ratio.map { "\(p.done)/\(p.total) task · \(Int($0 * 100))%" } ?? "belum terukur"
    }

    // MARK: Lists

    private var milestoneList: some View {
        let ms = ws.milestones.filter { m in projects.contains { $0.id == m.projectId } && (showDone || m.completedAt == nil) }
            .sorted { ($0.targetDate ?? .distantFuture) < ($1.targetDate ?? .distantFuture) }
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                RLabel(text: "Milestone · \(ms.count)")
                if ms.isEmpty { Text("Belum ada milestone. Buka sebuah project → Roadmap untuk menambahkan.").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                ForEach(ms) { m in milestoneRow(m, showProject: true) }
            }
        }
    }

    private func milestoneRow(_ m: Milestone, showProject: Bool) -> some View {
        let p = ws.progress(milestone: m.id)
        let risk = ws.milestoneAtRisk(m)
        let late = m.completedAt == nil && (m.targetDate ?? .distantFuture) < Date()
        return Button { editing = m } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: m.completedAt != nil ? "checkmark.diamond.fill" : "diamond")
                    .foregroundStyle(m.completedAt != nil ? RTheme.green : risk ? RTheme.red : RTheme.violet).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if risk { RChip(text: late ? "terlambat" : "berisiko", tint: RTheme.red).fixedSize() }
                        Spacer(minLength: 8)
                        Text(WFormat.date(m.targetDate)).font(.system(size: 12)).foregroundStyle(late ? RTheme.red : RTheme.ink2).fixedSize()
                    }
                    HStack(spacing: 10) {
                        ProgressMeter(progress: p, showLabel: false).frame(maxWidth: 220)
                        Text(progressText(p)).font(.system(size: 11)).foregroundStyle(RTheme.muted).fixedSize()
                        if showProject, let name = ws.projects.first(where: { $0.id == m.projectId })?.name {
                            Text(name).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func manage(_ pid: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Milestone")
                    ForEach(ws.milestones.filter { $0.projectId == pid && (showDone || $0.completedAt == nil) }) { m in milestoneRow(m, showProject: false) }
                    HStack {
                        TextField("Milestone baru (mis. Beta, v1.0)", text: $newMilestone).textFieldStyle(.roundedBorder)
                            .onSubmit { if let m = ws.createMilestone(pid, title: newMilestone, targetDate: Date().addingTimeInterval(30 * 86400)) { newMilestone = ""; editing = m } }
                        Button("Tambah") { if let m = ws.createMilestone(pid, title: newMilestone, targetDate: Date().addingTimeInterval(30 * 86400)) { newMilestone = ""; editing = m } }
                            .buttonStyle(RPillButton()).disabled(newMilestone.isEmpty)
                    }
                    Text("Progres milestone = task selesai ÷ task yang ditautkan ke milestone itu.").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                RCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        RLabel(text: "Epic")
                        ForEach(ws.epics.filter { $0.projectId == pid && (showDone || !$0.done) }) { e in
                            Button { editingEpic = e } label: {
                                HStack {
                                    Image(systemName: e.done ? "checkmark.circle.fill" : "rectangle.fill").foregroundStyle(e.done ? RTheme.green : RTheme.blue).font(.system(size: 10))
                                    Text(e.title).font(.system(size: 12.5))
                                    Spacer()
                                    Text(progressText(ws.progress(epic: e.id))).font(.system(size: 11)).foregroundStyle(RTheme.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        HStack {
                            TextField("Epic baru", text: $newEpic).textFieldStyle(.roundedBorder)
                                .onSubmit { if let e = ws.createEpic(pid, title: newEpic) { newEpic = ""; editingEpic = e } }
                            Button("Tambah") { if let e = ws.createEpic(pid, title: newEpic) { newEpic = ""; editingEpic = e } }.buttonStyle(RPillButton()).disabled(newEpic.isEmpty)
                        }
                    }
                }
                RCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        RLabel(text: "Release")
                        ForEach(ws.releases.filter { $0.projectId == pid }) { r in
                            HStack {
                                Image(systemName: r.releasedAt != nil ? "shippingbox.fill" : "shippingbox").foregroundStyle(RTheme.mint)
                                Text("\(r.name)\(r.version.isEmpty ? "" : " · \(r.version)")").font(.system(size: 12.5))
                                Spacer()
                                if r.releasedAt == nil {
                                    Button("Tandai rilis") { var x = r; x.releasedAt = Date(); ws.updateRelease(x) }.buttonStyle(.link).font(.system(size: 11.5))
                                } else { Text(WFormat.date(r.releasedAt)).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                                Button { ws.deleteRelease(r.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(RTheme.muted)
                            }
                        }
                        HStack {
                            TextField("Release baru (mis. v1.2)", text: $newRelease).textFieldStyle(.roundedBorder)
                                .onSubmit { if ws.createRelease(pid, name: newRelease, version: newRelease) != nil { newRelease = "" } }
                            Button("Tambah") { if ws.createRelease(pid, name: newRelease, version: newRelease) != nil { newRelease = "" } }.buttonStyle(RPillButton()).disabled(newRelease.isEmpty)
                        }
                    }
                }
            }
        }
    }
}

struct MilestoneEditor: View {
    let milestone: Milestone
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var draft: Milestone
    init(milestone: Milestone) { self.milestone = milestone; _draft = State(initialValue: milestone) }

    var body: some View {
        let tasks = ws.tasks.filter { $0.milestoneId == milestone.id && !$0.archived }
        let p = ws.progress(milestone: milestone.id)
        VStack(alignment: .leading, spacing: 12) {
            Text("Milestone").font(.system(size: 16, weight: .bold))
            TextField("Judul", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Deskripsi", text: $draft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            OptionalDatePicker(title: "Target", date: $draft.targetDate)
            ProgressMeter(progress: p)
            Toggle("Selesai", isOn: Binding(get: { draft.completedAt != nil }, set: { draft.completedAt = $0 ? Date() : nil })).toggleStyle(.checkbox)
            if p.total > 0 && p.done < p.total && draft.completedAt != nil {
                Text("Masih ada \(p.total - p.done) task terbuka di milestone ini.").font(.system(size: 11.5)).foregroundStyle(RTheme.amber)
            }
            RLabel(text: "Task · \(tasks.count)")
            ScrollView { VStack(alignment: .leading, spacing: 4) { ForEach(tasks) { TaskRowLine(task: $0) } } }.frame(maxHeight: 180)
            HStack {
                Button("Hapus milestone", role: .destructive) { ws.deleteMilestone(milestone.id); dismiss() }.buttonStyle(.link).foregroundStyle(RTheme.red)
                Spacer()
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Simpan") { ws.updateMilestone(draft); dismiss() }.keyboardShortcut(.defaultAction).disabled(draft.title.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}

struct EpicEditor: View {
    let epic: Epic
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var draft: Epic
    init(epic: Epic) { self.epic = epic; _draft = State(initialValue: epic) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Epic").font(.system(size: 16, weight: .bold))
            TextField("Judul", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Deskripsi", text: $draft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            OptionalDatePicker(title: "Mulai", date: $draft.startDate)
            OptionalDatePicker(title: "Target", date: $draft.targetDate)
            ProgressMeter(progress: ws.progress(epic: epic.id))
            Toggle("Selesai", isOn: $draft.done).toggleStyle(.checkbox)
            HStack {
                Button("Hapus epic", role: .destructive) { ws.deleteEpic(epic.id); dismiss() }.buttonStyle(.link).foregroundStyle(RTheme.red)
                Spacer()
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Simpan") { ws.updateEpic(draft); dismiss() }.keyboardShortcut(.defaultAction).disabled(draft.title.isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }
}

// MARK: - My Work

/// Tasks assigned to the owner across every project.
struct MyWorkPage: View {
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelWorkspaceMe") private var me = "Saya"
    @State private var includeUnassigned = false

    var body: some View {
        let active = Set(ws.projects.filter { $0.lifecycle != .archived }.map(\.id))
        let mine = ws.tasks.filter { t in !t.archived && t.status != .done && (t.assignee == me || (includeUnassigned && t.assignee.isEmpty)) && active.contains(t.projectId) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today)!
        let groups: [(String, String, [WTask])] = [
            ("Sedang dikerjakan", "play.circle", mine.filter { $0.status == .inProgress || $0.status == .review }),
            ("Lewat tenggat", "exclamationmark.circle", mine.filter { $0.isOverdue() && $0.status != .inProgress && $0.status != .review }),
            ("Hari ini", "sun.max", mine.filter { $0.dueDate.map { cal.isDate($0, inSameDayAs: today) } ?? false && $0.status != .inProgress && $0.status != .review }),
            ("7 hari ke depan", "calendar", mine.filter { d in d.dueDate.map { $0 > cal.date(byAdding: .day, value: 1, to: today)! && $0 <= weekEnd } ?? false && d.status != .inProgress && d.status != .review }),
            ("Nanti", "calendar.badge.clock", mine.filter { $0.dueDate.map { $0 > weekEnd } ?? false && $0.status != .inProgress && $0.status != .review }),
            ("Tanpa tenggat", "tray", mine.filter { $0.dueDate == nil && $0.status != .inProgress && $0.status != .review }),
        ]
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "My Work", subtitle: "Task yang ditugaskan ke \(me) di semua project")
                Spacer()
                HStack(spacing: 6) {
                    Text("Nama saya").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                    TextField("Saya", text: $me).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                Toggle("Termasuk tanpa orang", isOn: $includeUnassigned).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if mine.isEmpty {
                RCard(padding: 20) {
                    EmptyStateView(icon: "checkmark.circle", title: "Tidak ada task untukmu",
                                   message: "Tugaskan task ke \"\(me)\" dari board (klik kanan → Tugaskan ke saya) atau isi kolom Orang di detail task.")
                }
            }
            ForEach(groups, id: \.0) { g in
                if !g.2.isEmpty {
                    RCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(g.0) · \(g.2.count)", systemImage: g.1).font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(g.0 == "Lewat tenggat" ? RTheme.red : RTheme.navy)
                            ForEach(g.2.sorted { ($0.dueDate ?? .distantFuture, -$0.priority.rawValue) < ($1.dueDate ?? .distantFuture, -$1.priority.rawValue) }) { t in
                                HStack(spacing: 8) {
                                    Button { ws.moveTask(t.id, to: .done) } label: { Image(systemName: "circle") }.buttonStyle(.plain).foregroundStyle(RTheme.muted).help("Tandai selesai")
                                    TaskRowLine(task: t, showProject: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
