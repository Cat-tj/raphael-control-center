import SwiftUI

/// Projects: a project list and the selected project's workspace (tabs share its context).
struct ProjectsPage: View {
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelProjectSelected") private var selected = ""
    @State private var query = ""
    @State private var newProject = false
    @AppStorage("raphaelProjectListHidden") private var listHidden = false

    private var project: Project? { ws.projects.first { $0.id == selected } ?? ws.projects.first { $0.lifecycle != .archived } }

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                projectList.frame(width: 240)
                Rectangle().fill(RTheme.line).frame(width: 1)
            }
            if let p = project {
                ProjectWorkspace(projectId: p.id, listHidden: $listHidden).id(p.id)
                    .frame(minWidth: 0, maxWidth: .infinity).clipped()
            } else {
                EmptyStateView(icon: "folder.badge.plus", title: "Belum ada project",
                               message: "Project menyatukan repo, server, domain, deployment dan task dalam satu konteks.",
                               action: ("Project baru", { newProject = true }),
                               secondary: ("Temukan project", { UserDefaults.standard.set(CCSection.portfolio.rawValue, forKey: "raphaelCCSection") }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $newProject) { ProjectEditor(project: nil) }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Cari project…", text: $query).textFieldStyle(.roundedBorder)
                Button { newProject = true } label: { Image(systemName: "plus") }.buttonStyle(RPillButton()).help("Project baru")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let list = ws.projects.filter { $0.lifecycle != .archived && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    let pinned = list.filter { $0.pinned || $0.favorite }
                    if !pinned.isEmpty { group("Favorit & pin", pinned) }
                    ForEach(ws.portfolios.filter { !$0.archived }) { pf in
                        let items = list.filter { $0.portfolioId == pf.id && !($0.pinned || $0.favorite) }
                        if !items.isEmpty { group(pf.name, items) }
                    }
                    let loose = list.filter { $0.portfolioId == nil && !($0.pinned || $0.favorite) }
                    if !loose.isEmpty { group(ws.portfolios.isEmpty ? "Project" : "Tanpa portfolio", loose) }
                    let archived = ws.projects.filter { $0.lifecycle == .archived && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    if !archived.isEmpty { group("Archived", archived) }
                }
            }
        }
        .padding(12)
        .background(RTheme.surface)
    }

    private func group(_ title: String, _ items: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(RTheme.muted)
                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
            ForEach(items) { p in
                Button { selected = p.id } label: {
                    HStack(spacing: 8) {
                        Circle().fill(p.lifecycle.color).frame(width: 7, height: 7)
                        Text(p.name).font(.system(size: 12.5, weight: project?.id == p.id ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        let open = ws.tasks.filter { $0.projectId == p.id && $0.status != .done && !$0.archived && $0.parentId == nil }.count
                        if open > 0 { Text("\(open)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(project?.id == p.id ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(project?.id == p.id ? RTheme.violet : RTheme.navy)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProjectWorkspace: View {
    enum Tab: String, CaseIterable { case overview = "Overview", board = "Board", tasks = "Tasks", roadmap = "Roadmap", development = "Development",
                                     deployments = "Deployments", monitoring = "Monitoring", activity = "Activity", settings = "Settings" }
    let projectId: String
    @Binding var listHidden: Bool
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelProjectTab") private var tabRaw = Tab.overview.rawValue
    private var tab: Tab { Tab(rawValue: tabRaw) ?? .overview }
    private var project: Project? { ws.projects.first { $0.id == projectId } }

    var body: some View {
        if let p = project {
            VStack(alignment: .leading, spacing: 0) {
                header(p)
                tabBar
                Divider().overlay(RTheme.line)
                Group {
                    switch tab {
                    case .board: KanbanBoard(projectId: p.id)
                    case .tasks: TaskListView(projectId: p.id)
                    default:
                        ScrollView {
                            Group {
                                switch tab {
                                case .overview: ProjectOverview(projectId: p.id)
                                case .roadmap: RoadmapPage(projectId: p.id)
                                case .development: DevelopmentTab(projectId: p.id)
                                case .deployments: DeploymentsTab(projectId: p.id)
                                case .monitoring: MonitoringTab(projectId: p.id)
                                case .activity: ActivityPage(projectId: p.id)
                                case .settings: ProjectSettings(projectId: p.id)
                                default: EmptyView()
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: 1200, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ p: Project) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { listHidden.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                .help(listHidden ? "Tampilkan daftar project" : "Sembunyikan daftar project")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(p.name).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                    Text(p.key).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(RTheme.muted)
                    LifecycleBadge(lifecycle: p.lifecycle, paused: p.paused)
                    let h = ProjectHealth.report(p.id)
                    if h.hasOperationalResources { HealthBadge(health: h.ops) }
                }
                if !p.description.isEmpty { Text(p.description).font(.system(size: 12)).foregroundStyle(RTheme.muted).lineLimit(1) }
            }
            Spacer()
            Button { var x = p; x.favorite.toggle(); ws.updateProject(x) } label: { Image(systemName: p.favorite ? "star.fill" : "star") }
                .buttonStyle(.plain).foregroundStyle(p.favorite ? RTheme.amber : RTheme.muted).help("Favorit")
            Menu {
                ForEach(Lifecycle.allCases) { l in Button(l.title) { ws.moveProject(p.id, to: l) } }
                Divider()
                Button(p.paused ? "Lanjutkan" : "Pause") { var x = p; x.paused.toggle(); ws.updateProject(x) }
            } label: { Label("Lifecycle", systemImage: p.lifecycle.icon) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 10)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tabRaw = t.rawValue } label: {
                        VStack(spacing: 5) {
                            Text(t.rawValue).font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? RTheme.navy : RTheme.muted)
                            Rectangle().fill(tab == t ? RTheme.violet : .clear).frame(height: 2)
                        }
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tab \(t.rawValue)")
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Overview tab

struct ProjectOverview: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @ObservedObject private var mon = MonitorStore.shared

    var body: some View {
        if let p = ws.projects.first(where: { $0.id == projectId }) {
            let ts = ws.tasks(of: p.id).filter { $0.parentId == nil }
            let prog = ws.progress(project: p.id)
            let health = ProjectHealth.report(p.id)
            let next = ws.nextMilestone(p.id)
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    tile("Progres development", prog.ratio.map { "\(Int($0 * 100))%" } ?? "Belum terukur",
                         prog.total > 0 ? "\(prog.done) dari \(prog.total) task selesai" : "belum ada task terencana", prog.ratio == nil ? RTheme.muted : RTheme.violet)
                    tile("Operasional", health.hasOperationalResources ? health.ops.title : "Tidak ada resource",
                         health.lastCollected.map { "dicek " + $0.ago } ?? (health.hasOperationalResources ? "belum ada data" : "tautkan domain/server di Settings"),
                         health.hasOperationalResources ? health.ops.color : RTheme.muted)
                    tile("Task", "\(ts.filter { $0.status == .inProgress }.count) dikerjakan",
                         "\(ts.filter { $0.status != .done }.count) terbuka · \(ts.filter { $0.status == .done }.count) selesai", RTheme.navy)
                    let blocked = ts.filter { $0.status != .done && ($0.blocked || !ws.blockers(of: $0.id).isEmpty) }.count
                    let overdue = ts.filter { $0.isOverdue() }.count
                    tile("Perlu perhatian", "\(blocked) terblokir", "\(overdue) lewat tenggat", blocked + overdue > 0 ? RTheme.amber : RTheme.green)
                }
                HStack(alignment: .top, spacing: 14) {
                    RCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            RLabel(text: "Detail")
                            kv("Kategori", p.category.isEmpty ? "–" : p.category)
                            kv("Prioritas", p.priority.title)
                            kv("Mulai", WFormat.date(p.startDate))
                            kv("Target", WFormat.date(p.targetDate) + (p.targetDate.map { $0 < Date() && p.lifecycle != .live && p.lifecycle != .archived ? " · lewat" : "" } ?? ""))
                            kv("Milestone berikut", next.map { "\($0.title)\($0.targetDate.map { " · " + WFormat.date($0) } ?? "")" } ?? "–")
                            if let next { ProgressMeter(progress: ws.progress(milestone: next.id)) }
                            if !p.labels.isEmpty { LabelChips(labels: p.labels) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    RCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            RLabel(text: "Resource terhubung")
                            let ls = ws.links(of: p.id)
                            if ls.isEmpty {
                                Text("Belum ada. Tautkan repo, domain, server atau Vercel di tab Settings, atau lewat Portfolio → Temukan project.")
                                    .font(.system(size: 12)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(ResourceLink.Kind.allCases, id: \.self) { k in
                                let items = ls.filter { $0.kind == k }
                                if !items.isEmpty {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: k.icon).frame(width: 16).foregroundStyle(RTheme.violet)
                                        Text(k.title).font(.system(size: 11.5)).foregroundStyle(RTheme.muted).frame(width: 110, alignment: .leading)
                                        Text(items.map { $0.label.isEmpty ? $0.ref.replacingOccurrences(of: NSHomeDirectory(), with: "~") : $0.label }.joined(separator: ", "))
                                            .font(.system(size: 12)).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 14) {
                    RCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            RLabel(text: "Sedang dikerjakan")
                            let active = ts.filter { $0.status == .inProgress || $0.status == .review }.sorted { $0.updatedAt > $1.updatedAt }
                            if active.isEmpty { Text("Tidak ada task In Progress / Review.").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                            ForEach(active.prefix(8)) { t in TaskRowLine(task: t) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    RCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            RLabel(text: "Aktivitas terbaru")
                            let ev = ws.events(project: p.id).prefix(8)
                            if ev.isEmpty { Text("Belum ada aktivitas.").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                            ForEach(Array(ev)) { e in ActivityRow(event: e, showProject: false) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                AgentSessionsCard(projectId: p.id, limit: 5)
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ note: String, _ tint: Color) -> some View {
        RCard(padding: 14) {
            VStack(alignment: .leading, spacing: 5) {
                RLabel(text: label)
                Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(tint == RTheme.muted ? RTheme.muted : RTheme.navy).lineLimit(1).minimumScaleFactor(0.7)
                Text(note).font(.system(size: 11)).foregroundStyle(tint == RTheme.navy ? RTheme.muted : tint).lineLimit(1)
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(RTheme.muted).frame(width: 120, alignment: .leading)
            Text(v).font(.system(size: 12.5)).lineLimit(2)
            Spacer()
        }
    }
}

/// One-line task (code, title, status, due) used in lists and cards.
struct TaskRowLine: View {
    let task: WTask
    @ObservedObject private var ws = WorkspaceStore.shared
    var showProject = false
    var body: some View {
        let p = ws.projects.first { $0.id == task.projectId }
        Button { WorkspaceNav.openTask(task) } label: {
            HStack(spacing: 8) {
                PriorityIcon(priority: task.priority)
                Text(task.code(p)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted)
                Text(task.title).font(.system(size: 12.5)).lineLimit(1)
                if task.blocked || !ws.blockers(of: task.id).isEmpty { Image(systemName: "hand.raised.fill").font(.system(size: 9.5)).foregroundStyle(RTheme.amber) }
                Spacer()
                if showProject, let p { Text(p.name).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1) }
                Text(task.status.title).font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                if let d = task.dueDate { Text(WFormat.due(d)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(task.isOverdue() ? RTheme.red : RTheme.muted) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings tab

struct ProjectSettings: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var draft: Project?
    @State private var newKind: ResourceLink.Kind = .repo
    @State private var newRef = ""
    @State private var newEnv = "production"
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    RLabel(text: "Project")
                    if draft != nil { ProjectFields(draft: Binding(get: { draft! }, set: { draft = $0 })) }
                    HStack {
                        TextField("Kode task", text: Binding(get: { draft?.key ?? "" }, set: { draft?.key = String($0.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)) }))
                            .textFieldStyle(.roundedBorder).frame(width: 120).help("Prefix ID task, mis. ALT → ALT-12")
                        Spacer()
                        Button("Simpan") { if let d = draft { ws.updateProject(d) } }.buttonStyle(RPillButton(primary: true))
                            .disabled(draft == ws.projects.first { $0.id == projectId } || (draft?.name.isEmpty ?? true))
                    }
                }
            }
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    RLabel(text: "Resource: repo, domain, server, deployment")
                    Text("Satu project bisa punya banyak repo, environment, service dan deployment. Data Monitor/GitHub/Vercel muncul di tab project sesuai tautan ini.")
                        .font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                    ForEach(ws.links(of: projectId)) { l in
                        HStack(spacing: 8) {
                            Image(systemName: l.kind.icon).frame(width: 16).foregroundStyle(RTheme.violet)
                            Text(l.kind.title).font(.system(size: 11.5)).foregroundStyle(RTheme.muted).frame(width: 120, alignment: .leading)
                            Text(l.ref.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            if !l.label.isEmpty && l.label != l.ref { Text(l.label).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                            Spacer()
                            Picker("", selection: Binding(get: { l.environment }, set: { var x = l; x.environment = $0; ws.updateLink(x) })) {
                                Text("–").tag(""); Text("production").tag("production"); Text("staging").tag("staging"); Text("development").tag("development")
                            }
                            .labelsHidden().frame(width: 120)
                            if l.source == "discovery" { RChip(text: "ditemukan", tint: RTheme.muted) }
                            Button { ws.removeLink(l.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(RTheme.red).help("Lepas tautan")
                        }
                    }
                    HStack(spacing: 8) {
                        Picker("", selection: $newKind) { ForEach(ResourceLink.Kind.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 170)
                        resourceInput
                        Picker("", selection: $newEnv) { Text("–").tag(""); Text("production").tag("production"); Text("staging").tag("staging"); Text("development").tag("development") }
                            .labelsHidden().frame(width: 120)
                        Button("Tautkan") { ws.addLink(projectId, kind: newKind, ref: newRef, environment: newEnv); newRef = "" }
                            .buttonStyle(RPillButton(primary: true)).disabled(newRef.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    RLabel(text: "Board")
                    Text("Batas WIP per kolom (kosong = tanpa batas). Kolom yang melewati batas ditandai.").font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                    HStack(spacing: 12) {
                        ForEach(TaskStatus.allCases.filter { $0 != .done }) { s in
                            HStack(spacing: 4) {
                                Text(s.title).font(.system(size: 12))
                                TextField("–", text: Binding(get: { draft?.wipLimits[s.rawValue].map(String.init) ?? "" },
                                                             set: { v in draft?.wipLimits[s.rawValue] = Int(v).flatMap { $0 > 0 ? $0 : nil } }))
                                    .textFieldStyle(.roundedBorder).frame(width: 44)
                            }
                        }
                        Spacer()
                        Button("Simpan") { if let d = draft { ws.updateProject(d) } }.buttonStyle(RPillButton())
                    }
                }
            }
            RCard(padding: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hapus project").font(.system(size: 13, weight: .semibold))
                        Text("Lebih aman: lifecycle Archived. Hapus permanen menghapus task, milestone dan aktivitas project ini.").font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                    }
                    Spacer()
                    Button("Arsipkan") { ws.moveProject(projectId, to: .archived) }.buttonStyle(RPillButton())
                    Button("Hapus…") { confirmDelete = true }.buttonStyle(RPillButton(primary: true, tint: RTheme.red))
                }
            }
        }
        .onAppear { draft = ws.projects.first { $0.id == projectId } }
        .onChange(of: ws.projects.first { $0.id == projectId }?.updatedAt) { _, _ in draft = ws.projects.first { $0.id == projectId } }
        .confirmationDialog("Hapus project ini permanen?", isPresented: $confirmDelete) {
            Button("Hapus permanen", role: .destructive) { ws.deleteProject(projectId) }
        }
    }

    @ViewBuilder private var resourceInput: some View {
        switch newKind {
        case .node:
            Picker("", selection: $newRef) { Text("Pilih server…").tag(""); ForEach(NodeStore.shared.nodes) { Text($0.name).tag($0.id) } }.labelsHidden()
        case .app:
            Picker("", selection: $newRef) {
                Text("Pilih aplikasi…").tag("")
                ForEach(MonitorStore.shared.apps.filter { $0.kind != .local }) { Text("\($0.name) · \($0.kind.rawValue)").tag($0.id) }
            }.labelsHidden()
        case .repo:
            TextField("owner/repo", text: $newRef).textFieldStyle(.roundedBorder)
        case .vercel:
            Picker("", selection: $newRef) { Text("Pilih project Vercel…").tag(""); ForEach(VercelStore.shared.projects) { Text($0.name).tag($0.id) } }.labelsHidden()
        case .local:
            Picker("", selection: $newRef) { Text("Pilih folder…").tag(""); ForEach(LocalProjectsStore.shared.projects) { Text($0.name).tag($0.path) } }.labelsHidden()
        case .domain:
            TextField("domain.com", text: $newRef).textFieldStyle(.roundedBorder)
        case .job:
            Picker("", selection: $newRef) {
                Text("Pilih job…").tag("")
                ForEach(NodeStore.shared.nodes) { n in
                    ForEach((MonitorStore.shared.detail[n.id]?.jobs ?? []).filter { !$0.system }) { j in Text("\(n.name) · \(j.name)").tag("\(n.id)|\(j.id)") }
                }
            }.labelsHidden()
        default:
            TextField(newKind == .compose || newKind == .service ? "device-id:nama" : "referensi", text: $newRef).textFieldStyle(.roundedBorder)
        }
    }
}
