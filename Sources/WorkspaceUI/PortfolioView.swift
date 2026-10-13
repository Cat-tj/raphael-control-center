import SwiftUI

/// Portfolio: every project, as a grid, a list or a lifecycle Kanban.
struct PortfolioPage: View {
    enum Mode: String, CaseIterable { case grid = "Grid", list = "List", kanban = "Kanban" }
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelPortfolioSelected") private var portfolioId = ""      // "" all, "none" unassigned
    @AppStorage("raphaelPortfolioMode") private var modeRaw = Mode.grid.rawValue
    @State private var query = ""
    @State private var category = ""
    @State private var label = ""
    @State private var showPaused = true
    @State private var favoritesOnly = false
    @State private var showArchived = false
    @State private var editingPortfolio: Portfolio?
    @State private var newPortfolio = false
    @State private var newProject = false
    @State private var discovery = false
    @State private var confirmDelete: Project?

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .grid }
    private var portfolio: Portfolio? { ws.portfolios.first { $0.id == portfolioId } }

    private var scoped: [Project] {
        ws.projects.filter { p in
            (portfolioId.isEmpty || (portfolioId == "none" ? p.portfolioId == nil : p.portfolioId == portfolioId)) &&
            (query.isEmpty || p.name.localizedCaseInsensitiveContains(query) || p.description.localizedCaseInsensitiveContains(query)
                || p.labels.contains { $0.localizedCaseInsensitiveContains(query) }) &&
            (category.isEmpty || p.category == category) && (label.isEmpty || p.labels.contains(label)) &&
            (showPaused || !p.paused) && (!favoritesOnly || p.favorite)
        }
    }
    private var visible: [Project] {
        scoped.filter { mode == .kanban || showArchived || $0.lifecycle != .archived }
            .sorted { ($0.pinned ? 0 : 1, $0.favorite ? 0 : 1, -$0.priority.rawValue, $0.name.lowercased()) < ($1.pinned ? 0 : 1, $1.favorite ? 0 : 1, -$1.priority.rawValue, $1.name.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            if ws.projects.isEmpty {
                RCard(padding: 20) {
                    EmptyStateView(icon: "square.grid.2x2", title: "Belum ada project",
                                   message: "Buat project sendiri, atau biarkan Raphael menemukan project dari ~/Projects, GitHub, Vercel dan aplikasi yang dipantau di Monitor. Kamu yang memutuskan mana yang digabung.",
                                   action: ("Temukan project", { discovery = true }), secondary: ("Project baru", { newProject = true }))
                }
                Spacer()
            } else if visible.isEmpty {
                RCard(padding: 20) { EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "Tidak ada yang cocok", message: "Ubah filter atau pilih portfolio lain.") }
                Spacer()
            } else {
                switch mode {
                case .grid:
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                            ForEach(visible) { p in ProjectCard(project: p).contextMenu { projectMenu(p) } }
                        }
                        .padding(.bottom, 20)
                    }
                case .list:
                    ProjectTable(projects: visible, menu: { AnyView(projectMenu($0)) })
                case .kanban:
                    PortfolioKanban(projects: visible, showArchived: $showArchived, menu: { AnyView(projectMenu($0)) })
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .sheet(isPresented: $newPortfolio) { PortfolioEditor(portfolio: nil) }
        .sheet(item: $editingPortfolio) { PortfolioEditor(portfolio: $0) }
        .sheet(isPresented: $newProject) { ProjectEditor(project: nil, portfolioId: portfolioId.isEmpty || portfolioId == "none" ? nil : portfolioId) }
        .sheet(isPresented: $discovery) { DiscoverySheet(portfolioId: portfolioId.isEmpty || portfolioId == "none" ? nil : portfolioId) }
        .confirmationDialog("Hapus project \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Hapus permanen beserta task-nya", role: .destructive) { if let p = confirmDelete { ws.deleteProject(p.id) }; confirmDelete = nil }
        } message: { Text("Lebih aman: pindahkan ke lifecycle Archived. Hapus permanen tidak bisa dibatalkan (kecuali dari backup/export).") }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    Button("Semua project") { portfolioId = "" }
                    Button("Tanpa portfolio") { portfolioId = "none" }
                    Divider()
                    ForEach(ws.portfolios.filter { !$0.archived }) { p in Button(p.name) { portfolioId = p.id } }
                    let archived = ws.portfolios.filter(\.archived)
                    if !archived.isEmpty {
                        Divider()
                        Menu("Diarsipkan") { ForEach(archived) { p in Button(p.name) { portfolioId = p.id } } }
                    }
                    Divider()
                    Button("Portfolio baru…") { newPortfolio = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(portfolio?.name ?? (portfolioId == "none" ? "Tanpa portfolio" : "Portfolio")).font(.system(size: 26, weight: .heavy)).tracking(-0.6)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(RTheme.muted)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                HStack(spacing: 10) {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(RTheme.muted)
                    if WorkspaceSync.enabled { WorkspaceSyncBadge() }
                }
            }
            Spacer()
            if let p = portfolio {
                Button { editingPortfolio = p } label: { Image(systemName: "pencil") }.buttonStyle(RPillButton()).help("Ubah portfolio")
                Button { ws.setPortfolioArchived(p.id, !p.archived) } label: { Label(p.archived ? "Pulihkan" : "Arsipkan", systemImage: p.archived ? "tray.and.arrow.up" : "archivebox") }
                    .buttonStyle(RPillButton())
            }
            Button { discovery = true } label: { Label("Temukan project", systemImage: "sparkle.magnifyingglass") }.buttonStyle(RPillButton())
            Button { newProject = true } label: { Label("Project baru", systemImage: "plus") }.buttonStyle(RPillButton(primary: true))
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private var subtitle: String {
        let ps = scoped.filter { $0.lifecycle != .archived }
        if let p = portfolio, !p.description.isEmpty { return p.description + " · \(ps.count) project" }
        let live = ps.filter { $0.lifecycle == .live }.count, building = ps.filter { $0.lifecycle == .building }.count
        return "\(ps.count) project aktif · \(building) building · \(live) live"
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $modeRaw) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField("Cari project, label…", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            let cats = Array(Set(ws.projects.map(\.category).filter { !$0.isEmpty })).sorted()
            if !cats.isEmpty {
                Picker("", selection: $category) { Text("Semua kategori").tag(""); ForEach(cats, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            let labels = Array(Set(ws.projects.flatMap(\.labels))).sorted()
            if !labels.isEmpty {
                Picker("", selection: $label) { Text("Semua label").tag(""); ForEach(labels, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            Toggle("Favorit", isOn: $favoritesOnly).toggleStyle(.checkbox)
            Toggle("Paused", isOn: $showPaused).toggleStyle(.checkbox)
            if mode != .kanban { Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox) }
            Spacer()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func projectMenu(_ p: Project) -> some View {
        Button("Buka") { WorkspaceNav.open(project: p.id) }
        Divider()
        Button(p.pinned ? "Lepas pin" : "Pin") { var x = p; x.pinned.toggle(); ws.updateProject(x) }
        Button(p.favorite ? "Hapus dari favorit" : "Favorit") { var x = p; x.favorite.toggle(); ws.updateProject(x) }
        Button(p.paused ? "Lanjutkan (unpause)" : "Pause") { var x = p; x.paused.toggle(); ws.updateProject(x) }
        Menu("Lifecycle") { ForEach(Lifecycle.allCases) { l in Button(l.title) { ws.moveProject(p.id, to: l) } } }
        Menu("Prioritas") { ForEach(Priority.allCases) { pr in Button(pr.title) { var x = p; x.priority = pr; ws.updateProject(x) } } }
        Menu("Pindah ke portfolio") {
            Button("Tanpa portfolio") { var x = p; x.portfolioId = nil; ws.updateProject(x) }
            ForEach(ws.portfolios.filter { !$0.archived }) { pf in Button(pf.name) { var x = p; x.portfolioId = pf.id; ws.updateProject(x) } }
        }
        Divider()
        if p.lifecycle != .archived { Button("Arsipkan") { ws.moveProject(p.id, to: .archived) } }
        else { Button("Pulihkan ke Maintenance") { ws.moveProject(p.id, to: .maintenance) } }
        Button("Hapus…", role: .destructive) { confirmDelete = p }
    }
}

// MARK: - Cards

/// Facts a project card/row shows (computed from the store; no estimates).
@MainActor
struct ProjectFacts {
    let open: Int, blocked: Int, overdue: Int
    let progress: (done: Int, total: Int, ratio: Double?)
    let next: Milestone?
    let health: ProjectHealthReport
    let lastActivity: Date?

    init(_ p: Project) {
        let ws = WorkspaceStore.shared
        let ts = ws.tasks(of: p.id)
        open = ts.filter { $0.status != .done }.count
        blocked = ts.filter { $0.status != .done && ($0.blocked || !ws.blockers(of: $0.id).isEmpty) }.count
        overdue = ts.filter { $0.isOverdue() }.count
        progress = ws.progress(project: p.id)
        next = ws.nextMilestone(p.id)
        health = ProjectHealth.report(p.id)
        lastActivity = ws.activity.first { $0.projectId == p.id }?.ts
    }
}

struct ProjectCard: View {
    let project: Project
    var body: some View {
        let f = ProjectFacts(project)
        Button { WorkspaceNav.open(project: project.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    LifecycleBadge(lifecycle: project.lifecycle, paused: project.paused)
                    if f.health.hasOperationalResources { HealthBadge(health: f.health.ops) }
                    Spacer()
                    if project.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(RTheme.muted) }
                    if project.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(RTheme.amber) }
                    if project.priority != .none { PriorityIcon(priority: project.priority) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(project.description.isEmpty ? (project.category.isEmpty ? project.key : project.category) : project.description)
                        .font(.system(size: 11.5)).foregroundStyle(RTheme.muted).lineLimit(2)
                }
                ProgressMeter(progress: f.progress)
                HStack(spacing: 12) {
                    fact("\(f.open)", "terbuka", RTheme.navy)
                    if f.blocked > 0 { fact("\(f.blocked)", "terblokir", RTheme.amber) }
                    if f.overdue > 0 { fact("\(f.overdue)", "lewat tenggat", RTheme.red) }
                    Spacer()
                }
                if let m = f.next {
                    Label("\(m.title)\(m.targetDate.map { " · " + WFormat.due($0) } ?? "")", systemImage: "flag")
                        .font(.system(size: 11)).foregroundStyle(WorkspaceStore.shared.milestoneAtRisk(m) ? RTheme.red : RTheme.ink2).lineLimit(1)
                }
                HStack {
                    LabelChips(labels: project.labels)
                    Spacer()
                    if let a = f.lastActivity { Text(a.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project \(project.name)")
    }

    private func fact(_ v: String, _ k: String, _ c: Color) -> some View {
        HStack(spacing: 3) { Text(v).font(.system(size: 12.5, weight: .bold)).foregroundStyle(c); Text(k).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
    }
}

struct ProjectTable: View {
    let projects: [Project]
    let menu: (Project) -> AnyView
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Lifecycle").frame(width: 130, alignment: .leading)
                Text("Operasional").frame(width: 120, alignment: .leading)
                Text("Progres").frame(width: 130, alignment: .leading)
                Text("Terbuka").frame(width: 60, alignment: .trailing)
                Text("Milestone berikut").frame(width: 170, alignment: .leading)
                Text("Target").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider().overlay(RTheme.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(projects) { p in
                        let f = ProjectFacts(p)
                        Button { WorkspaceNav.open(project: p.id) } label: {
                            HStack {
                                HStack(spacing: 6) {
                                    if p.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(RTheme.amber) }
                                    PriorityIcon(priority: p.priority)
                                    Text(p.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                    if !p.category.isEmpty { Text(p.category).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                LifecycleBadge(lifecycle: p.lifecycle, paused: p.paused).frame(width: 130, alignment: .leading)
                                Group { if f.health.hasOperationalResources { HealthBadge(health: f.health.ops) } else { Text("–").foregroundStyle(RTheme.muted) } }
                                    .frame(width: 120, alignment: .leading)
                                ProgressMeter(progress: f.progress, showLabel: false).frame(width: 90).padding(.trailing, 40)
                                Text("\(f.open)").frame(width: 60, alignment: .trailing)
                                Text(f.next?.title ?? "–").lineLimit(1).frame(width: 170, alignment: .leading)
                                Text(p.targetDate.map(WFormat.due) ?? "–").frame(width: 80, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(p) }
                        Divider().overlay(RTheme.line)
                    }
                }
            }
        }
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
    }
}

/// Lifecycle columns; dropping a card persists the new lifecycle (and its order).
struct PortfolioKanban: View {
    let projects: [Project]
    @Binding var showArchived: Bool
    let menu: (Project) -> AnyView
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var target: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Lifecycle.allCases.filter { showArchived || $0 != .archived }) { l in column(l) }
                if !showArchived {
                    Button { showArchived = true } label: { Label("Archived", systemImage: "archivebox").font(.system(size: 12)) }
                        .buttonStyle(RPillButton()).padding(.top, 6)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func column(_ l: Lifecycle) -> some View {
        let items = projects.filter { $0.lifecycle == l }.sorted { $0.sort < $1.sort }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: l.icon).foregroundStyle(l.color)
                Text(l.title).font(.system(size: 13, weight: .bold))
                Text("\(items.count)").font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(items) { p in
                        MiniProjectCard(project: p)
                            .draggable(p.id) { MiniProjectCard(project: p).frame(width: 240).opacity(0.85) }
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, id != p.id, ws.projects.contains(where: { $0.id == id }) else { return false }
                                ws.moveProject(id, to: l, before: p.id); return true
                            }
                            .contextMenu { menu(p) }
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(target == l.rawValue ? RTheme.violetSoft : RTheme.wash, in: RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, ws.projects.contains(where: { $0.id == id }) else { return false }
            ws.moveProject(id, to: l); return true
        } isTargeted: { target = $0 ? l.rawValue : (target == l.rawValue ? nil : target) }
        .accessibilityLabel("Kolom \(l.title), \(items.count) project")
    }
}

struct MiniProjectCard: View {
    let project: Project
    var body: some View {
        let f = ProjectFacts(project)
        Button { WorkspaceNav.open(project: project.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if project.paused { Image(systemName: "pause.circle.fill").foregroundStyle(RTheme.amber).font(.system(size: 11)) }
                    if project.priority != .none { PriorityIcon(priority: project.priority) }
                }
                ProgressMeter(progress: f.progress, showLabel: false)
                HStack(spacing: 8) {
                    if f.health.hasOperationalResources { HealthBadge(health: f.health.ops, compact: true) }
                    Text("\(f.open) terbuka").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                    if f.overdue > 0 { Text("\(f.overdue) lewat").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(RTheme.red) }
                    Spacer()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editors

struct PortfolioEditor: View {
    let portfolio: Portfolio?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(portfolio == nil ? "Portfolio baru" : "Ubah portfolio").font(.system(size: 16, weight: .bold))
            TextField("Nama (mis. Altora, Klien, Eksperimen)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Deskripsi", text: $description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Spacer()
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(portfolio == nil ? "Buat" : "Simpan") {
                    if var p = portfolio { p.name = name; p.description = description; WorkspaceStore.shared.updatePortfolio(p) }
                    else if let p = WorkspaceStore.shared.createPortfolio(name: name, description: description) {
                        UserDefaults.standard.set(p.id, forKey: "raphaelPortfolioSelected")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { name = portfolio?.name ?? ""; description = portfolio?.description ?? "" }
    }
}

struct ProjectEditor: View {
    let project: Project?
    var portfolioId: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var draft = Project(id: "", portfolioId: nil, name: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project == nil ? "Project baru" : "Ubah project").font(.system(size: 16, weight: .bold))
            ProjectFields(draft: $draft)
            HStack {
                Spacer()
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Buat project" : "Simpan") {
                    if project != nil { ws.updateProject(draft) }
                    else if var p = ws.createProject(name: draft.name, portfolioId: draft.portfolioId, lifecycle: draft.lifecycle,
                                                     description: draft.description, category: draft.category) {
                        p.priority = draft.priority; p.labels = draft.labels; p.startDate = draft.startDate; p.targetDate = draft.targetDate
                        ws.updateProject(p)
                        WorkspaceNav.open(project: p.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { draft = project ?? Project(id: "", portfolioId: portfolioId, name: "") }
    }
}

/// The editable fields of a project (shared by the editor and the Settings tab).
struct ProjectFields: View {
    @Binding var draft: Project
    @ObservedObject private var ws = WorkspaceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Nama project", text: $draft.name).textFieldStyle(.roundedBorder)
            TextField("Deskripsi", text: $draft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack {
                TextField("Kategori (mis. SaaS, Website, Internal)", text: $draft.category).textFieldStyle(.roundedBorder)
                Picker("Portfolio", selection: Binding(get: { draft.portfolioId ?? "" }, set: { draft.portfolioId = $0.isEmpty ? nil : $0 })) {
                    Text("Tanpa portfolio").tag("")
                    ForEach(ws.portfolios) { Text($0.name).tag($0.id) }
                }
                .frame(width: 200)
            }
            HStack {
                Picker("Lifecycle", selection: $draft.lifecycle) { ForEach(Lifecycle.allCases) { Text($0.title).tag($0) } }.frame(width: 200)
                Picker("Prioritas", selection: $draft.priority) { ForEach(Priority.allCases) { Text($0.title).tag($0) } }.frame(width: 170)
                Toggle("Paused", isOn: $draft.paused).toggleStyle(.checkbox)
            }
            LabelsField(labels: $draft.labels)
            OptionalDatePicker(title: "Mulai", date: $draft.startDate)
            OptionalDatePicker(title: "Target", date: $draft.targetDate)
        }
        .font(.system(size: 12.5))
    }
}
