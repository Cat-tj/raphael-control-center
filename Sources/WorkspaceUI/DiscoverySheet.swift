import SwiftUI

/// Project discovery: suggestions from local repos, GitHub, Vercel and the Monitor, grouped
/// only by verified identifiers. Every decision is the owner's and persists.
struct DiscoverySheet: View {
    var portfolioId: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceStore.shared
    @ObservedObject private var gh = GitHubStore.shared
    @ObservedObject private var local = LocalProjectsStore.shared
    @ObservedObject private var vercel = VercelStore.shared
    @State private var candidates: [ProjectCandidate] = []
    @State private var names: [String: String] = [:]
    @State private var lifecycles: [String: Lifecycle] = [:]
    @State private var showDismissed = false
    @State private var showLinked = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temukan project").font(.system(size: 18, weight: .bold))
                    Text("Digabung hanya bila terbukti satu project: remote git yang sama, Vercel yang terhubung ke repo, atau routing yang diverifikasi Monitor. Nama yang mirip hanya jadi saran.")
                        .font(.system(size: 12)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if gh.state == .loading || local.loading || vercel.state == .loading { ProgressView().controlSize(.small) }
                Button { refreshSources() } label: { Label("Pindai ulang", systemImage: "arrow.clockwise") }.buttonStyle(RPillButton())
                Button("Selesai") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            HStack(spacing: 10) {
                TextField("Cari…", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Toggle("Tampilkan yang sudah terhubung", isOn: $showLinked).toggleStyle(.checkbox)
                Toggle("Tampilkan yang diabaikan", isOn: $showDismissed).toggleStyle(.checkbox)
                Spacer()
                Text(sourceLine).font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            .font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 10)
            Divider().overlay(RTheme.line)
            ScrollView {
                LazyVStack(spacing: 10) {
                    let list = filtered
                    if list.isEmpty {
                        EmptyStateView(icon: "sparkle.magnifyingglass", title: candidates.isEmpty ? "Belum ada kandidat" : "Semua kandidat sudah ditangani",
                                       message: candidates.isEmpty ? "Raphael membaca ~/Projects, repo GitHub (login gh), Vercel (token) dan aplikasi di Monitor. Hubungkan sumber di Monitor → Sumber data, lalu pindai ulang."
                                                                   : "Centang \"Tampilkan yang diabaikan\" untuk memulihkan saran.")
                    }
                    ForEach(list) { c in row(c) }
                }
                .padding(20)
            }
        }
        .frame(width: 860, height: 640)
        .background(RTheme.canvas)
        .onAppear { reload(); if gh.repos.isEmpty || local.projects.isEmpty { refreshSources() } }
        .onChange(of: gh.repos.count) { _, _ in reload() }
        .onChange(of: local.projects.count) { _, _ in reload() }
        .onChange(of: vercel.projects.count) { _, _ in reload() }
    }

    private var sourceLine: String {
        "\(local.projects.count) folder · \(gh.repos.count) repo · \(vercel.projects.count) Vercel · \(MonitorStore.shared.apps.filter { $0.kind != .local }.count) aplikasi"
    }

    private var filtered: [ProjectCandidate] {
        candidates.filter { c in
            let decision = ws.decisions[c.id]?.decision
            if decision == "dismissed" && !showDismissed { return false }
            if (decision == "accepted" || (c.linkedProject != nil && c.newResources.isEmpty)) && !showLinked { return false }
            return query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || c.resources.contains { $0.ref.localizedCaseInsensitiveContains(query) }
        }
    }

    private func reload() {
        candidates = ProjectRegistry.candidates()
        for c in candidates where names[c.id] == nil { names[c.id] = c.name; lifecycles[c.id] = c.lifecycleGuess }
    }

    private func refreshSources() {
        gh.refresh(); local.refresh(); vercel.refresh(); MonitorStore.shared.rebuildCatalog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reload() }
    }

    private func row(_ c: ProjectCandidate) -> some View {
        let decision = ws.decisions[c.id]?.decision
        let linked = c.linkedProject.flatMap { id in ws.projects.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Nama", text: Binding(get: { names[c.id] ?? c.name }, set: { names[c.id] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 13.5, weight: .semibold)).frame(width: 260)
                Picker("", selection: Binding(get: { lifecycles[c.id] ?? c.lifecycleGuess }, set: { lifecycles[c.id] = $0 })) {
                    ForEach(Lifecycle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 130).help("Tebakan lifecycle: ubah bila perlu")
                if let linked { RChip(text: "terhubung ke \(linked.name)", tint: RTheme.green) }
                if decision == "dismissed" { RChip(text: "diabaikan", tint: RTheme.muted) }
                Spacer()
                if decision == "dismissed" {
                    Button("Pulihkan") { ws.undecide(c.id) }.buttonStyle(RPillButton())
                } else {
                    if let linked, !c.newResources.isEmpty {
                        Button("Tambah \(c.newResources.count) resource ke \(linked.name)") { ProjectRegistry.attach(c, to: linked.id) }.buttonStyle(RPillButton(primary: true))
                    } else if linked == nil {
                        Button("Buat project") {
                            ProjectRegistry.accept(c, name: names[c.id] ?? c.name, portfolioId: portfolioId, lifecycle: lifecycles[c.id] ?? c.lifecycleGuess)
                        }
                        .buttonStyle(RPillButton(primary: true))
                    }
                    Menu("Gabung ke…") {
                        ForEach(ws.projects.filter { $0.lifecycle != .archived }) { p in Button(p.name) { ProjectRegistry.attach(c, to: p.id) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize().disabled(ws.projects.isEmpty)
                    if linked == nil { Button("Abaikan") { ProjectRegistry.dismiss(c) }.buttonStyle(.link).font(.system(size: 12)) }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(c.resources, id: \.self) { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.kind.icon).frame(width: 16).foregroundStyle(RTheme.violet)
                            Text(r.kind.title).font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 110, alignment: .leading)
                            Text(r.label.isEmpty || r.label == r.ref ? r.ref.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "\(r.label) · \(r.ref.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                                .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                            if !r.environment.isEmpty { Text(r.environment).font(.system(size: 10)).foregroundStyle(RTheme.muted) }
                            if c.linkedProject != nil && c.newResources.contains(r) { RChip(text: "baru", tint: RTheme.violet) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(c.evidence, id: \.self) { Label($0, systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(RTheme.ink2) }
                    ForEach(c.hints, id: \.self) { Label($0, systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(RTheme.amber) }
                }
                .frame(width: 300, alignment: .leading)
            }
        }
        .padding(14)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RTheme.line))
        .opacity(decision == "dismissed" ? 0.6 : 1)
    }
}
