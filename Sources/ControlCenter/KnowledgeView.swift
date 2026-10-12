import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Knowledge: the 3D knowledge graph (graphify galaxy) plus each agent's SOUL,
/// .env and memories, editable in place.
struct KnowledgePage: View {
    enum Tab: String, CaseIterable { case graph = "Knowledge Graph", soul = "Soul", env = ".env", memory = "Memory" }
    @ObservedObject private var store = KnowledgeStore.shared
    @AppStorage("raphaelKnowledgeTab") private var tabRaw = Tab.graph.rawValue
    @State private var agentId = ""

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .graph }
    private var agent: KAgent? { store.agents.first { $0.id == agentId } ?? store.agents.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "Knowledge", subtitle: "Knowledge graph 3D, SOUL, .env dan memory setiap agent & bot")
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button(t.rawValue) { tabRaw = t.rawValue }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(tab == t ? RTheme.surface : .clear, in: Capsule())
                            .overlay(Capsule().stroke(tab == t ? RTheme.line : .clear))
                            .foregroundStyle(tab == t ? RTheme.violet : RTheme.ink2)
                    }
                }
                .padding(3).background(RTheme.wash, in: Capsule())
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)

            if tab == .graph {
                GraphTab()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    agentList.frame(width: 220)
                    Rectangle().fill(RTheme.line).frame(width: 1)
                    Group {
                        if let agent {
                            switch tab {
                            case .soul: FilesEditor(node: node(agent), files: agent.soulFiles, emptyText: "Agent ini belum punya SOUL.md", key: "soul-\(agent.id)").id("soul-\(agent.id)")
                            case .memory: FilesEditor(node: node(agent), files: agent.memoryFiles, emptyText: "Belum ada memory", key: "mem-\(agent.id)").id("mem-\(agent.id)")
                            case .env: EnvEditor(node: node(agent), path: agent.envPath).id("env-\(agent.id)")
                            case .graph: EmptyView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(RTheme.surface)
                .overlay(Rectangle().fill(RTheme.line).frame(height: 1), alignment: .top)
            }
        }
        .onAppear { if store.agents.isEmpty && !store.loading { store.reload() } }
    }

    private func node(_ a: KAgent) -> RNode { NodeStore.shared.nodes.first { $0.id == a.device } ?? DeviceContext.shared.current }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            RLabel(text: "Agent & bot").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, a in
                if DeviceContext.shared.isAll && (i == 0 || store.agents[i - 1].device != a.device) {
                    Text(node(a).name).font(.system(size: 11, weight: .bold)).foregroundStyle(RTheme.violet)
                        .padding(.horizontal, 10).padding(.top, i == 0 ? 0 : 10)
                }
                Button { agentId = a.id } label: {
                    HStack(spacing: 9) {
                        Image(systemName: a.id == "default" ? "sparkles" : "person.crop.circle").foregroundStyle(RTheme.violet)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 13, weight: agentId == a.id ? .semibold : .regular))
                            Text(a.profile == "default" ? "~/.hermes" : "profiles/\(a.profile)").font(.system(size: 10, design: .monospaced)).foregroundStyle(RTheme.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(agentId == a.id ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if store.loading { ProgressView().controlSize(.small).padding(10) }
            if !store.loading && store.agents.isEmpty {
                Text("Hermes tidak ditemukan di \(DeviceContext.shared.scopeName)").font(.system(size: 12)).foregroundStyle(RTheme.muted).padding(10)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(RTheme.canvas)
    }
}

// MARK: - 3D graph

struct GraphTab: View {
    @ObservedObject private var store = KnowledgeStore.shared
    @AppStorage("raphaelGraphSelected") private var selected = ""
    @State private var query = ""
    @State private var dropping = false
    @State private var cloning = false
    @State private var repoURL = ""

    private var isMerged: Bool { selected.hasPrefix("merged:") }
    private var graph: KGraph? { isMerged ? nil : store.graphs.first { $0.id == selected } }
    private var currentKey: String? { isMerged ? selected : graph?.id ?? store.graphs.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            if !store.ungraphed.isEmpty || store.graphs.contains(where: \.stale) || !store.building.isEmpty {
                BuildGraphsPanel().padding(.horizontal, 28).padding(.bottom, 12)
            }
            if !store.ingesting.isEmpty || (store.buildLog != nil && store.ungraphed.isEmpty && store.building.isEmpty) {
                ingestStatus.padding(.horizontal, 28).padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 14) {
                graphList.frame(width: 250)
                viewer
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
            .overlay { if dropping { dropOverlay.padding(.horizontal, 28).padding(.bottom, 24) } }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadURLs(providers) { store.ingest($0, collection: targetCollection) }
                return true
            }
        }
        .onAppear { if selected.isEmpty { selected = KnowledgeStore.mergedProjects } }
        .onChange(of: store.graphs) { _, graphs in
            guard let p = store.pendingSelect, let g = graphs.first(where: { $0.path == p }) else { return }
            store.pendingSelect = nil
            selected = g.id
            store.render(g)
        }
        .sheet(isPresented: $cloning) { cloneSheet }
    }

    // MARK: Adding knowledge (drop, pick, clone)

    /// Loose documents go into the selected document collection, else "Dokumen".
    private var targetCollection: String {
        if let g = graph, g.category == .docs { return g.name }
        return KnowledgeStore.defaultCollection
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(RTheme.violet.opacity(0.12))
            RoundedRectangle(cornerRadius: 18).strokeBorder(RTheme.violet, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square.fill").font(.system(size: 34)).foregroundStyle(RTheme.violet)
                Text("Lepas untuk memetakan").font(.system(size: 16, weight: .bold)).foregroundStyle(RTheme.navy)
                Text("PDF / Markdown / teks → koleksi \(targetCollection) · folder kode / repo → graph proyek · 0 token")
                    .font(.system(size: 12)).foregroundStyle(RTheme.muted)
            }
            .padding(24).background(RTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false)
    }

    private var addMenu: some View {
        Menu {
            Button("Pilih file atau folder…") { pickFiles() }
            Button("Clone repo dari URL…") { repoURL = ""; cloning = true }
        } label: {
            Label("Tambah", systemImage: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Tambah PDF, Markdown, folder atau repo. Bisa juga drag & drop ke sini.")
    }

    private var ingestStatus: some View {
        RCard(padding: 12) {
            HStack(spacing: 10) {
                if store.ingesting.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RTheme.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Memetakan \(store.ingesting.count)…").font(.system(size: 12, weight: .semibold)).foregroundStyle(RTheme.violet)
                }
                Text(store.buildLog ?? "Membaca dokumen dan menyusun graph secara lokal").font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(RTheme.ink2).lineLimit(2)
                Spacer()
                if store.ingesting.isEmpty {
                    Button { store.buildLog = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                }
            }
        }
    }

    private var cloneSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone repo").font(.system(size: 16, weight: .bold))
            Text("Repo di-clone (shallow) ke folder Raphael lalu dipetakan: kode + README/docs, 0 token.")
                .font(.system(size: 12)).foregroundStyle(RTheme.muted)
            TextField("https://github.com/user/repo", text: $repoURL).textFieldStyle(.roundedBorder).frame(width: 420)
                .onSubmit { startClone() }
            HStack {
                Spacer()
                Button("Batal") { cloning = false }.keyboardShortcut(.cancelAction)
                Button("Clone & petakan") { startClone() }.keyboardShortcut(.defaultAction)
                    .disabled(repoURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func startClone() {
        guard !repoURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.cloneAndBuild(repoURL)
        cloning = false
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "PDF, Markdown, teks, atau folder (repo/proyek atau folder dokumen)"
        panel.prompt = "Petakan"
        if panel.runModal() == .OK { store.ingest(panel.urls, collection: targetCollection) }
    }

    private func loadURLs(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { then(box.urls) } }
    }

    // MARK: Left: categories

    private var graphList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Cari graph…", text: $query).textFieldStyle(.roundedBorder)
                addMenu
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    section("Gabungan", icon: "circle.hexagongrid.fill")
                    mergedRow(KnowledgeStore.mergedProjects, "Semua proyek", "satu galaxy, satu cluster per proyek")
                    mergedRow(KnowledgeStore.mergedAll, "Semua graph", "proyek, repo lain dan memory")
                    ForEach(KCategory.allCases) { cat in
                        let items = store.graphs.filter { $0.category == cat && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                            .sorted { $0.name.lowercased() < $1.name.lowercased() }
                        if !items.isEmpty {
                            section("\(cat.rawValue) · \(items.count)", icon: cat.icon).padding(.top, 10)
                            ForEach(items) { g in graphRow(g) }
                        }
                    }
                    if store.loading { ProgressView().controlSize(.small).padding(8) }
                    Text("Drag PDF, Markdown, folder atau repo ke sini untuk dipetakan otomatis.")
                        .font(.system(size: 10.5)).foregroundStyle(RTheme.muted).padding(.horizontal, 6).padding(.top, 14)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RTheme.line))
    }

    private func section(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(RTheme.violet)
            RLabel(text: title)
        }
        .padding(.horizontal, 6).padding(.bottom, 2)
    }

    private func mergedRow(_ key: String, _ title: String, _ sub: String) -> some View {
        let n = store.mergedSources(key).count
        return row(selected: selected == key, title: title, sub: "\(n) graph · \(sub)", stale: false) { selected = key }
    }

    private func graphRow(_ g: KGraph) -> some View {
        let dev = DeviceContext.shared.isAll && DeviceContext.shared.scope.count > 1
            ? (NodeStore.shared.nodes.first { $0.id == g.device }?.name ?? "") + " · " : ""
        return row(selected: currentKey == g.id, title: g.name, sub: dev + "\(g.nodes.formatted()) node", stale: g.stale) { selected = g.id }
            .contextMenu {
                if let root = g.root {
                    Button("Tampilkan sumber di Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
                    Button("Petakan ulang") { g.category == .docs ? store.mapDocs(name: g.name, root: root) : store.build(root, select: true) }
                }
                if g.category == .docs {
                    Divider()
                    Button("Hapus koleksi (ke Trash)", role: .destructive) { store.deleteCollection(g) }
                }
            }
    }

    private func row(selected: Bool, title: String, sub: String, stale: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                        if stale { Circle().fill(RTheme.amber).frame(width: 6, height: 6).help("Kode berubah sejak graph dibuat") }
                    }
                    Text(sub).font(.system(size: 10)).foregroundStyle(RTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(selected ? RTheme.violet : RTheme.navy)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Right: viewer

    private var viewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMerged ? (selected == KnowledgeStore.mergedAll ? "Semua graph" : "Semua proyek") : graph?.name ?? "—")
                        .font(.system(size: 17, weight: .bold))
                    Text(isMerged ? "Setiap cluster = satu proyek. Garis antar-cluster = proyek yang saling memakai."
                         : groupNote).font(.system(size: 11)).foregroundStyle(RTheme.muted)
                }
                Spacer()
                if !isMerged {
                    Picker("", selection: $store.groupBy) {
                        Text("Per modul").tag("project"); Text("Per komunitas").tag("community"); Text("Otomatis").tag("auto")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    .onChange(of: store.groupBy) { _, _ in if let g = graph ?? store.graphs.first { store.render(g) } }
                }
                if let key = currentKey, store.rendering.contains(key) { ProgressView().controlSize(.small) }
                Button { render() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(RPillButton()).help("Render ulang")
                if let key = currentKey, let html = store.rendered[key] {
                    Button { NSWorkspace.shared.open(html) } label: { Image(systemName: "safari") }.buttonStyle(RPillButton()).help("Buka di browser")
                }
                Button { store.openStudio(graph) } label: { Label("Studio", systemImage: "play.rectangle.on.rectangle") }
                    .buttonStyle(RPillButton(primary: true)).help("Raphael Studio: baca dokumen & presentasi 3D di browser")
            }
            ZStack {
                Color(hex: 0x05070D)
                if let key = currentKey, let html = store.rendered[key] {
                    GalaxyWebView(url: html).id(html.path + "\(store.rendering.contains(key))")
                } else if let key = currentKey, store.rendering.contains(key) {
                    VStack(spacing: 10) { ProgressView(); Text("Menyusun galaxy…").foregroundStyle(.white.opacity(0.7)) }
                } else if currentKey != nil {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent").font(.system(size: 36)).foregroundStyle(RTheme.violet)
                        Button("Render 3D") { render() }.buttonStyle(RPillButton(primary: true))
                    }
                    .onAppear { render() }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(RTheme.violet)
                        Text("Belum ada knowledge graph").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(store.loading ? "Mencari graph di \(DeviceContext.shared.scopeName)…"
                             : !store.ungraphed.isEmpty ? "Klik \"Buat semua\" di atas, atau drag PDF/Markdown/repo ke sini. Dibuat lokal, 0 token."
                             : DeviceContext.shared.scope.contains(where: \.isLocal) ? "Tidak ada project yang ditemukan di ~/Projects."
                             : "Belum ada graph di \(DeviceContext.shared.scopeName). Graph dibuat dari project di Mac; pilih Mac ini atau Semua device.")
                            .foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .padding()
                }
                if let e = store.renderError {
                    VStack { Spacer(); Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.red).padding(10)
                        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 8)).padding() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(RTheme.line))
        }
    }

    private var groupNote: String {
        switch store.groupBy {
        case "project": "Per modul: setiap package/app di dalam proyek jadi satu cluster."
        case "community": "Per komunitas: cluster dari keterhubungan kode (Leiden)."
        default: "Otomatis: per modul kalau proyeknya monorepo, selain itu per komunitas."
        }
    }

    private func render() {
        if isMerged { store.renderMerged(selected) }
        else if let g = graph ?? store.graphs.first { store.render(g) }
    }
}

struct GalaxyWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.setValue(false, forKey: "drawsBackground")
        v.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        if v.url?.path != url.path { v.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
    }
}

// MARK: - SOUL / memory editor

struct FilesEditor: View {
    let node: RNode
    let files: [String]
    let emptyText: String
    let key: String
    @State private var selected: String?
    @State private var busy = false
    @State private var text = ""
    @State private var saved = ""
    @State private var status: String?

    var body: some View {
        if files.isEmpty {
            Text(emptyText).foregroundStyle(RTheme.muted).padding(28)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(files, id: \.self) { f in
                        Button((f as NSString).lastPathComponent) { open(f) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: current == f ? .semibold : .regular, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(current == f ? RTheme.violetSoft : RTheme.canvas, in: Capsule())
                            .foregroundStyle(current == f ? RTheme.violet : RTheme.ink2)
                    }
                    Spacer()
                    RChip(text: "±\((text.count / 4).compact) token", tint: text.count / 4 > 4_000 ? RTheme.amber : RTheme.ink2)
                    if busy { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(.system(size: 11)).foregroundStyle(status.hasPrefix("Gagal") ? RTheme.red : status.hasSuffix("…") ? RTheme.muted : RTheme.green).lineLimit(2).help(status) }
                    Button("Simpan") { save() }.buttonStyle(RPillButton(primary: true)).disabled(text == saved || busy)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(RTheme.line))
                Text("Isi SOUL dan memory dikirim ke model di setiap panggilan: makin ringkas, makin hemat token. Versi sebelumnya disimpan sebagai .raphael.bak.")
                    .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            .padding(20)
            .onAppear { if current.map({ !files.contains($0) }) ?? true { open(files[0]) } }
            .onChange(of: key) { _, _ in open(files[0]) }
        }
    }

    private var current: String? { selected }

    private func open(_ f: String) {
        selected = f
        status = nil
        busy = true
        Task {
            let t = await DeviceContext.readFile(node, f)
            guard selected == f else { return }
            text = t; saved = t; busy = false
        }
    }

    private func save() {
        guard let f = selected else { return }
        let body = text
        busy = true
        Task {
            let ok = await DeviceContext.writeFile(node, f, body)
            busy = false
            if ok { saved = body; status = "Tersimpan" } else { status = "Gagal menyimpan" }
        }
    }
}

// MARK: - .env editor

struct EnvEditor: View {
    let node: RNode
    let path: String
    @State private var lines: [EnvLine] = []
    @State private var original = ""
    @State private var revealed: Set<UUID> = []
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(node.name) · " + path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.muted)
                    Spacer()
                    if let status { Text(status).font(.system(size: 11)).foregroundStyle(status.hasPrefix("Gagal") ? RTheme.red : status.hasSuffix("…") ? RTheme.muted : RTheme.green).lineLimit(2).help(status) }
                    Button(revealed.count == keyed.count && !keyed.isEmpty ? "Sembunyikan semua" : "Tampilkan semua") {
                        revealed = revealed.count == keyed.count ? [] : Set(keyed.map(\.id))
                    }
                    .buttonStyle(RPillButton())
                    Button("Simpan") { save() }.buttonStyle(RPillButton(primary: true)).disabled(EnvLine.render(lines) == original)
                }
                if lines.isEmpty { Text("File .env belum ada. Tambahkan variabel di bawah untuk membuatnya.").foregroundStyle(RTheme.muted) }
                ForEach($lines) { $line in
                    if let key = line.key {
                        HStack(spacing: 10) {
                            Text(key).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 300, alignment: .leading)
                                .lineLimit(1).textSelection(.enabled)
                            Group {
                                if revealed.contains(line.id) {
                                    TextField("", text: $line.value).textFieldStyle(.roundedBorder)
                                } else {
                                    Text(mask(line.value)).foregroundStyle(RTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .font(.system(size: 12, design: .monospaced))
                            Button { toggle(line.id) } label: { Image(systemName: revealed.contains(line.id) ? "eye.slash" : "eye") }
                                .buttonStyle(.plain).foregroundStyle(RTheme.ink2)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.value, forType: .string); status = "\(key) disalin" } label: {
                                Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plain).foregroundStyle(RTheme.ink2)
                            Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(RTheme.red.opacity(0.7))
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                    } else if line.raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                        Text(line.raw).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RTheme.muted).padding(.leading, 10)
                    }
                }
                HStack(spacing: 8) {
                    TextField("NAMA_VARIABEL", text: $newKey).textFieldStyle(.roundedBorder).frame(width: 300)
                    TextField("nilai", text: $newValue).textFieldStyle(.roundedBorder)
                    Button("Tambah") {
                        lines.append(EnvLine(raw: "", key: newKey.trimmingCharacters(in: .whitespaces), value: newValue))
                        newKey = ""; newValue = ""
                    }
                    .buttonStyle(RPillButton()).disabled(newKey.isEmpty)
                }
                // Not monospaced: SF Mono's underscore sits below the field's line box and gets clipped.
                .font(.system(size: 12.5))
                .padding(.top, 6)
                Text("Disimpan langsung ke file dengan izin aslinya (biasanya 600). Salinan sebelumnya: .env.raphael.bak. Restart agent supaya perubahan terbaca.")
                    .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            .padding(20)
        }
        .onAppear(perform: load)
    }

    private var keyed: [EnvLine] { lines.filter { $0.key != nil } }

    private func load() {
        Task {
            let text = await DeviceContext.readFile(node, path)
            original = text
            lines = text.isEmpty ? [] : EnvLine.parse(text)
        }
    }

    private func toggle(_ id: UUID) { if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) } }

    private func mask(_ v: String) -> String {
        if v.isEmpty { return "(kosong)" }
        if v.count <= 6 { return String(repeating: "•", count: v.count) }
        return String(v.prefix(3)) + String(repeating: "•", count: min(18, v.count - 5)) + String(v.suffix(2))
    }

    private func save() {
        let text = EnvLine.render(lines)
        Task {
            status = "Menyimpan…"
            if let err = await DeviceContext.writeFileResult(node, path, text) { status = "Gagal menyimpan: \(err)" } else { original = text; status = "Tersimpan" }
        }
    }
}

/// Projects on this Mac without a knowledge graph (or with an outdated one):
/// graphify indexes code locally with tree-sitter — no LLM, 0 tokens.
struct BuildGraphsPanel: View {
    @ObservedObject private var store = KnowledgeStore.shared
    @State private var expanded = false

    var body: some View {
        RCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(RTheme.violet)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.ungraphed.count) project belum punya graph").font(.system(size: 13, weight: .semibold))
                        Text("Dibuat dari kode secara lokal (tree-sitter), tanpa LLM: 0 token. Disimpan di folder Raphael, repo-mu tidak diubah.")
                            .font(.system(size: 11)).foregroundStyle(RTheme.muted)
                    }
                    Spacer()
                    if !store.building.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("membangun \(store.building.count)…").font(.system(size: 11)).foregroundStyle(RTheme.violet)
                    }
                    let stale = store.graphs.filter(\.stale).count
                    if stale > 0 {
                        Button("Perbarui \(stale) graph lama") { store.refreshStale() }.buttonStyle(RPillButton())
                    }
                    if !store.ungraphed.isEmpty {
                        Button(expanded ? "Tutup" : "Pilih project") { expanded.toggle() }.buttonStyle(RPillButton())
                        Button("Buat semua") { store.buildAll() }.buttonStyle(RPillButton(primary: true))
                            .disabled(!store.building.isEmpty)
                    }
                }
                if expanded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                        ForEach(store.ungraphed) { p in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(RTheme.muted)
                                Text(p.name).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                if store.building.contains(p.path) { ProgressView().controlSize(.mini) }
                                else { Button("Buat") { store.build(p.path) }.buttonStyle(.link).font(.system(size: 12, weight: .semibold)) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                if let log = store.buildLog {
                    Text(log).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.ink2).lineLimit(2)
                }
            }
        }
    }
}

/// Collects dropped file URLs from item-provider callbacks (any thread).
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
}
