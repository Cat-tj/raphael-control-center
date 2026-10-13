import SwiftUI

/// The dedicated task panel. Text fields save on ↩ / when focus leaves; pickers save at once.
struct TaskDetailPanel: View {
    let taskId: String
    let close: () -> Void
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var title = ""
    @State private var desc = ""
    @State private var assignee = ""
    @State private var reason = ""
    @State private var newCheck = ""
    @State private var newSub = ""
    @State private var linkText = ""
    @State private var confirmDelete = false
    @FocusState private var focus: String?

    private var task: WTask? { ws.tasks.first { $0.id == taskId } }

    var body: some View {
        if let t = task {
            let p = ws.projects.first { $0.id == t.projectId }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(t.code(p)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(RTheme.muted)
                        .textSelection(.enabled).help("ID tetap: \(t.id)")
                    if t.archived { RChip(text: "diarsipkan", tint: RTheme.muted) }
                    Spacer()
                    Menu {
                        Button(t.archived ? "Pulihkan dari arsip" : "Arsipkan") { ws.archiveTask(t.id, !t.archived) }
                        Button("Salin ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.code(p), forType: .string) }
                        Divider()
                        Button("Hapus permanen…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(RTheme.muted).keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider().overlay(RTheme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Judul", text: $title, axis: .vertical).textFieldStyle(.plain).font(.system(size: 16, weight: .bold))
                            .focused($focus, equals: "title").onSubmit { save { $0.title = title } }
                        fields(t)
                        section("Deskripsi") {
                            TextEditor(text: $desc).font(.system(size: 12.5)).frame(minHeight: 90).scrollContentBackground(.hidden)
                                .padding(6).background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                                .focused($focus, equals: "desc")
                            if desc != t.description { Button("Simpan deskripsi") { save { $0.description = desc } }.buttonStyle(RPillButton()) }
                        }
                        checklistSection(t)
                        subtaskSection(t)
                        dependencySection(t)
                        githubSection(t)
                        historySection(t, p)
                        Text("Dibuat \(WFormat.date(t.createdAt)) · diubah \(t.updatedAt.ago)" + (t.startedAt.map { " · mulai \(WFormat.date($0))" } ?? "") + (t.completedAt.map { " · selesai \(WFormat.date($0))" } ?? ""))
                            .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                    }
                    .padding(16)
                }
            }
            .background(RTheme.surface)
            .onAppear { load(t) }
            .onChange(of: focus) { old, _ in
                if old == "title", title != t.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { save { $0.title = title } }
                if old == "desc", desc != t.description { save { $0.description = desc } }
                if old == "assignee", assignee != t.assignee { save { $0.assignee = assignee } }
                if old == "reason", reason != t.blockedReason { save { $0.blockedReason = reason } }
            }
            .confirmationDialog("Hapus \(t.code(p)) permanen?", isPresented: $confirmDelete) {
                Button("Hapus beserta subtask", role: .destructive) { ws.deleteTask(t.id); close() }
            } message: { Text("Arsipkan kalau masih ingin menyimpan riwayatnya.") }
        } else {
            EmptyStateView(icon: "questionmark.square.dashed", title: "Task tidak ditemukan", message: "Mungkin sudah dihapus.", action: ("Tutup", close))
        }
    }

    private func load(_ t: WTask) { title = t.title; desc = t.description; assignee = t.assignee; reason = t.blockedReason }

    private func save(_ change: (inout WTask) -> Void) {
        guard var t = task else { return }
        change(&t)
        ws.updateTask(t)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { RLabel(text: title); content() }
    }

    // MARK: Fields

    private func fields(_ t: WTask) -> some View {
        let epics = ws.epics.filter { $0.projectId == t.projectId }
        let ms = ws.milestones.filter { $0.projectId == t.projectId }
        return VStack(alignment: .leading, spacing: 8) {
            row("Status") {
                Picker("", selection: Binding(get: { t.status }, set: { s in ws.moveTask(t.id, to: s) })) { ForEach(TaskStatus.allCases) { Text($0.title).tag($0) } }.labelsHidden()
            }
            row("Prioritas") {
                Picker("", selection: Binding(get: { t.priority }, set: { v in save { $0.priority = v } })) { ForEach(Priority.allCases) { Text($0.title).tag($0) } }.labelsHidden()
            }
            row("Orang") {
                HStack {
                    TextField("tanpa", text: $assignee).textFieldStyle(.roundedBorder).focused($focus, equals: "assignee").onSubmit { save { $0.assignee = assignee } }
                    Button("Saya") { assignee = ws.me; save { $0.assignee = ws.me } }.buttonStyle(.link).font(.system(size: 11.5))
                }
            }
            row("Tenggat") { OptionalDatePicker(title: "", date: Binding(get: { t.dueDate }, set: { v in save { $0.dueDate = v } })) }
            row("Label") { LabelsField(labels: Binding(get: { t.labels }, set: { v in if v != t.labels { save { $0.labels = v } } })) }
            row("Epic") {
                Picker("", selection: Binding(get: { t.epicId ?? "" }, set: { v in save { $0.epicId = v.isEmpty ? nil : v } })) {
                    Text("–").tag(""); ForEach(epics) { Text($0.title).tag($0.id) }
                }.labelsHidden()
            }
            row("Milestone") {
                Picker("", selection: Binding(get: { t.milestoneId ?? "" }, set: { v in save { $0.milestoneId = v.isEmpty ? nil : v } })) {
                    Text("–").tag(""); ForEach(ms) { Text($0.title).tag($0.id) }
                }.labelsHidden()
            }
            row("Terblokir") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Ditandai terblokir", isOn: Binding(get: { t.blocked }, set: { v in save { $0.blocked = v } })).toggleStyle(.checkbox)
                    if t.blocked { TextField("Alasan", text: $reason).textFieldStyle(.roundedBorder).focused($focus, equals: "reason").onSubmit { save { $0.blockedReason = reason } } }
                }
            }
            if let parent = t.parentId.flatMap({ id in ws.tasks.first { $0.id == id } }) {
                row("Induk") { TaskRowLine(task: parent) }
            }
        }
        .font(.system(size: 12.5))
    }

    private func row<C: View>(_ k: String, @ViewBuilder _ v: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).font(.system(size: 12)).foregroundStyle(RTheme.muted).frame(width: 78, alignment: .leading)
            v()
        }
    }

    // MARK: Checklist / subtasks / dependencies

    private func checklistSection(_ t: WTask) -> some View {
        let items = ws.checklist[t.id] ?? []
        return section("Checklist\(items.isEmpty ? "" : " · \(items.filter(\.done).count)/\(items.count)")") {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Button { ws.toggleChecklistItem(item) } label: { Image(systemName: item.done ? "checkmark.square.fill" : "square") }
                        .buttonStyle(.plain).foregroundStyle(item.done ? RTheme.green : RTheme.muted)
                    Text(item.text).font(.system(size: 12.5)).strikethrough(item.done, color: RTheme.muted)
                    Spacer()
                    Button { ws.removeChecklistItem(item) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(RTheme.muted)
                }
            }
            TextField("+ Item checklist", text: $newCheck).textFieldStyle(.roundedBorder).onSubmit { ws.addChecklistItem(t.id, newCheck); newCheck = "" }
        }
    }

    private func subtaskSection(_ t: WTask) -> some View {
        let subs = ws.subtasks(of: t.id)
        return section("Subtask\(subs.isEmpty ? "" : " · \(subs.filter { $0.status == .done }.count)/\(subs.count)")") {
            ForEach(subs) { s in
                HStack(spacing: 8) {
                    Button { ws.moveTask(s.id, to: s.status == .done ? .backlog : .done) } label: { Image(systemName: s.status == .done ? "checkmark.circle.fill" : "circle") }
                        .buttonStyle(.plain).foregroundStyle(s.status == .done ? RTheme.green : RTheme.muted)
                    TaskRowLine(task: s)
                }
            }
            if t.parentId == nil {
                TextField("+ Subtask", text: $newSub).textFieldStyle(.roundedBorder)
                    .onSubmit { _ = ws.createTask(projectId: t.projectId, title: newSub, parentId: t.id); newSub = "" }
            }
        }
    }

    private func dependencySection(_ t: WTask) -> some View {
        let waitsFor = ws.dependencies.filter { $0.taskId == t.id }
        let blocks = ws.dependencies.filter { $0.dependsOn == t.id }
        let candidates = ws.tasks(of: t.projectId).filter { $0.id != t.id && !waitsFor.map(\.dependsOn).contains($0.id) }
        return section("Dependensi") {
            ForEach(waitsFor, id: \.self) { d in
                if let other = ws.tasks.first(where: { $0.id == d.dependsOn }) {
                    HStack(spacing: 6) {
                        Text("Menunggu").font(.system(size: 11)).foregroundStyle(other.status == .done ? RTheme.green : RTheme.amber).frame(width: 64, alignment: .leading)
                        TaskRowLine(task: other)
                        Button { ws.removeDependency(d) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(RTheme.muted)
                    }
                }
            }
            ForEach(blocks, id: \.self) { d in
                if let other = ws.tasks.first(where: { $0.id == d.taskId }) {
                    HStack(spacing: 6) { Text("Menahan").font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 64, alignment: .leading); TaskRowLine(task: other) }
                }
            }
            Menu("+ Menunggu task…") {
                ForEach(candidates.prefix(60)) { c in Button("\(c.code(ws.projects.first { $0.id == c.projectId })) \(c.title)") { ws.addDependency(t.id, dependsOn: c.id) } }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12)).disabled(candidates.isEmpty)
        }
    }

    // MARK: GitHub links

    private func githubSection(_ t: WTask) -> some View {
        let refs = ws.externals.filter { $0.entity == "task" && $0.entityId == t.id }
        return section("GitHub") {
            ForEach(refs) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.system == "github-commit" ? "point.topleft.down.to.point.bottomright.curvepath" : r.externalId.contains("/pull/") ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                        .foregroundStyle(RTheme.violet)
                    Button(r.externalId) { if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } }.buttonStyle(.link).font(.system(size: 12)).lineLimit(1)
                    if !r.state.isEmpty { RChip(text: r.state, tint: r.state == "closed" || r.state == "merged" ? RTheme.green : RTheme.blue) }
                    Spacer()
                    Text("sync " + r.syncedAt.ago).font(.system(size: 10)).foregroundStyle(RTheme.muted)
                }
            }
            HStack {
                TextField("owner/repo#12, URL issue/PR, atau SHA commit", text: $linkText).textFieldStyle(.roundedBorder).onSubmit { addLink(t) }
                Button("Tautkan") { addLink(t) }.buttonStyle(RPillButton()).disabled(linkText.isEmpty)
            }
            Text("Issue yang tersinkron dari GitHub tertaut otomatis; tautan manual hanya dibaca, tidak mengubah GitHub.").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
        }
    }

    private func addLink(_ t: WTask) {
        guard let parsed = GitHubRef.parse(linkText, defaultRepo: ws.links(of: t.projectId, .repo).first?.ref) else { ws.lastError = "Format tidak dikenali: \(linkText)"; return }
        if let existing = ws.external(system: parsed.system, id: parsed.id), existing.entityId != t.id {
            ws.lastError = "\(parsed.id) sudah tertaut ke task lain"; return
        }
        ws.upsertExternal(ExternalRef(id: WorkspaceStore.newID(), entity: "task", entityId: t.id, system: parsed.system, externalId: parsed.id, url: parsed.url, state: ""))
        linkText = ""
    }

    private func historySection(_ t: WTask, _ p: Project?) -> some View {
        let ev = ws.activity.filter { $0.meta["task"] == t.id }.prefix(20)
        return section("Riwayat") {
            if ev.isEmpty { Text("Belum ada riwayat.").font(.system(size: 11.5)).foregroundStyle(RTheme.muted) }
            ForEach(Array(ev)) { e in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(RTheme.violet.opacity(0.5)).frame(width: 6, height: 6).padding(.top, 5)
                    Text(e.title).font(.system(size: 11.5)).foregroundStyle(RTheme.ink2)
                    Spacer()
                    Text(e.ts.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                }
            }
        }
    }
}

/// Parses "owner/repo#12", issue/PR URLs and commit SHAs/URLs.
enum GitHubRef {
    static func parse(_ raw: String, defaultRepo: String?) -> (system: String, id: String, url: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = s.range(of: #"github\.com/([^/]+/[^/]+)/(issues|pull)/(\d+)"#, options: .regularExpression) {
            let parts = s[m].split(separator: "/")
            let repo = "\(parts[1])/\(parts[2])", kind = parts[3], n = parts[4]
            return ("github", "\(repo)#\(n)", "https://github.com/\(repo)/\(kind)/\(n)")
        }
        if let m = s.range(of: #"github\.com/([^/]+/[^/]+)/commit/([0-9a-f]{7,40})"#, options: .regularExpression) {
            let parts = s[m].split(separator: "/")
            return ("github-commit", "\(parts[1])/\(parts[2])@\(parts[4].prefix(12))", "https://" + s[m])
        }
        if let m = s.range(of: #"^([\w.-]+/[\w.-]+)#(\d+)$"#, options: .regularExpression) {
            let v = String(s[m]); let repo = v.components(separatedBy: "#")[0], n = v.components(separatedBy: "#")[1]
            return ("github", v, "https://github.com/\(repo)/issues/\(n)")
        }
        if s.range(of: #"^#?\d+$"#, options: .regularExpression) != nil, let repo = defaultRepo {
            let n = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return ("github", "\(repo)#\(n)", "https://github.com/\(repo)/issues/\(n)")
        }
        if s.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil, let repo = defaultRepo {
            return ("github-commit", "\(repo)@\(s.prefix(12))", "https://github.com/\(repo)/commit/\(s)")
        }
        return nil
    }
}
