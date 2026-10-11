import SwiftUI
import UniformTypeIdentifiers

/// Files on any device: browse, preview/edit text, open, download, upload (drop), new
/// folder, rename and delete (to a trash folder, never a hard delete).
struct FilesPage: View {
    @ObservedObject private var device = DeviceContext.shared
    @ObservedObject private var nodes = NodeStore.shared
    @AppStorage("raphaelFilesNode") private var nodeId = ""
    @State private var path = ""
    @State private var pathDraft = ""
    @State private var listing: FilesStore.Listing?
    @State private var loading = false
    @State private var sudo = false
    @State private var showHidden = false
    @State private var filter = ""
    @State private var selection: Set<String> = []
    @State private var preview: RFile?
    @State private var text: String?
    @State private var savedText: String?
    @State private var previewNote: String?
    @State private var image: NSImage?
    @State private var busy: String?
    @State private var status: String?
    @State private var dropping = false
    @State private var renaming: RFile?
    @State private var newName = ""
    @State private var confirmDelete: [RFile] = []
    @State private var sortKey = "name"

    private var node: RNode {
        if let sel = device.selected { return sel }
        return nodes.nodes.first { $0.id == nodeId } ?? nodes.nodes.first { $0.id == DeviceContext.primaryHermesId } ?? device.current
    }

    private var items: [RFile] {
        var list = (listing?.items ?? []).filter { (showHidden || !$0.name.hasPrefix(".")) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
        list.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            switch sortKey {
            case "size": return $0.size > $1.size
            case "date": return $0.modified > $1.modified
            default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            HStack(alignment: .top, spacing: 14) {
                fileList
                previewPane.frame(width: 420)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .onAppear {
            // Opened from an app ("Buka file"): jump to its folder.
            if let p = UserDefaults.standard.string(forKey: "raphaelFilesOpenPath") {
                UserDefaults.standard.removeObject(forKey: "raphaelFilesOpenPath"); go(p)
            } else if listing == nil { go("~") }
        }
        .onChange(of: device.currentId) { _, _ in go("~") }
        .sheet(item: $renaming) { f in renameSheet(f) }
        .confirmationDialog("Hapus \(confirmDelete.count) item?", isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Pindahkan ke sampah", role: .destructive) { let f = confirmDelete; confirmDelete = []; run("Menghapus…") { await FilesStore.trash(node, f) } }
        } message: {
            Text(node.isLocal ? "Item dipindah ke Trash Mac." : "Item dipindah ke ~/.raphael-trash di \(node.name), jadi masih bisa dikembalikan.")
        }
    }

    // MARK: Header + toolbar

    private var header: some View {
        HStack(alignment: .bottom) {
            RPageTitle(title: "File", subtitle: "Jelajahi, edit, download dan upload file di \(node.name)")
            Spacer()
            if device.isAll {
                Picker("", selection: Binding(get: { node.id }, set: { nodeId = $0; go("~") })) {
                    ForEach(nodes.nodes) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 220)
            } else {
                RChip(text: device.scopeName, tint: RTheme.violet)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { go(((listing?.path ?? path) as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(RPillButton()).help("Folder induk")
            Menu {
                Button("Home") { go("~") }
                Button("/ (root)") { go("/") }
                Divider()
                ForEach(bookmarks, id: \.self) { b in Button(b) { go(b) } }
            } label: { Label("Lokasi", systemImage: "bookmark") }
                .menuStyle(.borderlessButton).fixedSize()
            TextField("Path", text: $pathDraft).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .onSubmit { go(pathDraft) }
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 140)
            Toggle("Tersembunyi", isOn: $showHidden).toggleStyle(.checkbox).font(.system(size: 12))
            if !node.isLocal {
                Toggle("sudo", isOn: $sudo).toggleStyle(.checkbox).font(.system(size: 12))
                    .onChange(of: sudo) { _, _ in reload() }.help("Baca sebagai root (sudo -n)")
            }
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(RPillButton()).help("Muat ulang")
            Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(RPillButton()).help("Folder baru")
            Button { pickUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }.buttonStyle(RPillButton(primary: true))
            Button { NodeStore.shared.openTerminal(node, at: listing?.path) } label: { Image(systemName: "terminal") }
                .buttonStyle(RPillButton()).help("Buka Terminal di folder ini")
        }
    }

    private var bookmarks: [String] {
        node.isLocal
            ? ["~/Projects", "~/Downloads", "~/Desktop", "~/.hermes", "~/Library/Application Support/Raphael"]
            : ["~/.hermes", "~/sites", "/etc", "/etc/caddy", "/etc/nginx", "/var/log", "/srv", "/opt", "~/.cloudflared", "~/.raphael-trash"]
    }

    // MARK: List

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                sortHeader("Nama", "name").frame(maxWidth: .infinity, alignment: .leading)
                sortHeader("Ukuran", "size").frame(width: 80, alignment: .trailing)
                sortHeader("Diubah", "date").frame(width: 130, alignment: .trailing)
                Text("Izin · pemilik").frame(width: 150, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(RTheme.line)
            ZStack {
                if loading && listing == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let e = listing?.error {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 26)).foregroundStyle(RTheme.amber)
                        Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.ink2).multilineTextAlignment(.center)
                        if !sudo && !node.isLocal && e.lowercased().contains("permission") {
                            Button("Coba dengan sudo") { sudo = true }.buttonStyle(RPillButton(primary: true))
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { f in row(f) }
                            if items.isEmpty { Text("Folder kosong").font(.system(size: 12)).foregroundStyle(RTheme.muted).padding(30) }
                        }
                    }
                }
                if dropping {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(RTheme.violet, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(RTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(Text("Lepas untuk upload ke \(listing?.path ?? path)").font(.system(size: 13, weight: .semibold)).foregroundStyle(RTheme.violet))
                        .padding(8).allowsHitTesting(false)
                }
            }
            Divider().overlay(RTheme.line)
            HStack(spacing: 8) {
                if let busy { ProgressView().controlSize(.mini); Text(busy).foregroundStyle(RTheme.violet) }
                else if let status { Text(status).foregroundStyle(RTheme.ink2).lineLimit(1) }
                Spacer()
                Text("\(items.count) item" + (selection.count > 1 ? " · \(selection.count) dipilih" : "")).foregroundStyle(RTheme.muted)
            }
            .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTheme.line))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            collect(providers) { urls in
                let dir = listing?.path ?? path
                run("Upload \(urls.count) item…") { await FilesStore.upload(node, urls, to: dir) }
            }
            return true
        }
    }

    private func sortHeader(_ title: String, _ key: String) -> some View {
        Button { sortKey = key } label: {
            HStack(spacing: 3) { Text(title); if sortKey == key { Image(systemName: "chevron.down").font(.system(size: 8)) } }
        }
        .buttonStyle(.plain)
    }

    private func row(_ f: RFile) -> some View {
        let sel = selection.contains(f.id) || preview?.id == f.id
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: f.icon).frame(width: 18).foregroundStyle(f.isDir ? RTheme.violet : RTheme.muted)
                Text(f.name).font(.system(size: 12.5)).lineLimit(1)
                if f.isLink { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(RTheme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(f.isDir ? "–" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)).frame(width: 80, alignment: .trailing)
            Text(f.modified.formatted(date: .abbreviated, time: .shortened)).frame(width: 130, alignment: .trailing)
            Text("\(f.mode) \(f.owner)").lineLimit(1).frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(RTheme.navy)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(sel ? RTheme.violetSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { f.isDir ? go(f.path) : openFile(f) }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggle(f) })
        .onTapGesture { selection = [f.id]; if !f.isDir { show(f) } }
        .contextMenu {
            if f.isDir { Button("Buka folder") { go(f.path) } } else { Button("Buka di Mac") { openFile(f) } }
            Button("Download ke Downloads") { download(f) }
            Button("Salin path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.path, forType: .string) }
            Divider()
            Button("Ganti nama…") { newName = f.name; renaming = f }
            Button("Hapus…", role: .destructive) {
                let chosen = items.filter { selection.contains($0.id) }
                confirmDelete = chosen.contains(f) ? chosen : [f]
            }
        }
    }

    private func toggle(_ f: RFile) { if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) } }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = preview {
                HStack(spacing: 8) {
                    Image(systemName: f.icon).foregroundStyle(RTheme.violet)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text("\(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)) · \(f.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(RTheme.muted)
                    }
                    Spacer()
                    if text != nil && text != savedText {
                        Button("Simpan") { saveText(f) }.buttonStyle(RPillButton(primary: true)).keyboardShortcut("s", modifiers: .command)
                    }
                    Button { openFile(f) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(RPillButton()).help("Buka di Mac")
                    Button { download(f) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(RPillButton()).help("Download")
                }
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                } else if text != nil {
                    TextEditor(text: Binding(get: { text ?? "" }, set: { text = $0 }))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                    if sudo && !node.isLocal { Text("Dibaca dengan sudo: menyimpan memakai user biasa dan bisa ditolak.").font(.system(size: 10.5)).foregroundStyle(RTheme.amber) }
                } else if let note = previewNote {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.questionmark").font(.system(size: 28)).foregroundStyle(RTheme.muted)
                        Text(note).font(.system(size: 12)).foregroundStyle(RTheme.muted).multilineTextAlignment(.center)
                        Button("Buka di Mac") { openFile(f) }.buttonStyle(RPillButton(primary: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(RTheme.violet)
                    Text("Pilih file untuk melihat isinya").font(.system(size: 13, weight: .semibold))
                    Text("Teks bisa diedit langsung (⌘S, versi lama disimpan sebagai .raphael.bak). Drag file dari Finder ke daftar untuk upload.")
                        .font(.system(size: 11.5)).foregroundStyle(RTheme.muted).multilineTextAlignment(.center)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTheme.line))
    }

    private func show(_ f: RFile) {
        preview = f; text = nil; savedText = nil; previewNote = nil; image = nil
        let n = node, useSudo = sudo
        Task {
            if f.isImage && f.ext != "svg" {
                if n.isLocal { image = NSImage(contentsOfFile: f.path); if image == nil { previewNote = "Gambar tidak bisa dibaca" }; return }
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Raphael/files/\(n.id)/preview")
                try? FileManager.default.removeItem(at: cache)
                let (url, err) = await FilesStore.download(n, f, to: cache)
                guard preview?.id == f.id else { return }
                if let url, let img = NSImage(contentsOf: url) { image = img } else { previewNote = err ?? "Gambar tidak bisa dibaca" }
                return
            }
            let r = await FilesStore.readText(n, f.path, sudo: useSudo)
            guard preview?.id == f.id else { return }
            if let t = r.text { text = t; savedText = t } else { previewNote = r.error }
        }
    }

    // MARK: Actions

    private func go(_ p: String) {
        let target = p.isEmpty ? "~" : p
        path = target; loading = true; preview = nil; selection = []
        let n = node, useSudo = sudo
        Task {
            let l = await FilesStore.list(n, target, sudo: useSudo)
            guard node.id == n.id else { return }
            listing = l; pathDraft = l.path; path = l.path; loading = false
        }
    }

    private func reload() { go(listing?.path ?? path) }

    private func run(_ label: String, _ op: @escaping () async -> String?) {
        busy = label
        Task {
            let err = await op()
            busy = nil
            status = err.map { "Gagal: \($0)" } ?? "Selesai · \(Date().formatted(date: .omitted, time: .shortened))"
            reload()
        }
    }

    private func openFile(_ f: RFile) {
        busy = "Membuka \(f.name)…"
        let n = node
        Task { let e = await FilesStore.open(n, f); busy = nil; status = e.map { "Gagal: \($0)" } }
    }

    private func download(_ f: RFile) {
        busy = "Download \(f.name)…"
        let n = node
        Task {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let (url, err) = await FilesStore.download(n, f, to: downloads)
            busy = nil
            if let url { status = "Tersimpan di Downloads/\(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { status = "Gagal: \(err ?? "")" }
        }
    }

    private func saveText(_ f: RFile) {
        guard let t = text else { return }
        busy = "Menyimpan…"
        let n = node
        Task {
            let ok = await FilesStore.save(n, f.path, t)
            busy = nil
            if ok { savedText = t; status = "Tersimpan · cadangan di \(f.name).raphael.bak" } else { status = "Gagal menyimpan (izin?)" }
        }
    }

    private func newFolder() {
        let alert = NSAlert()
        alert.messageText = "Folder baru"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Nama folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Buat"); alert.addButton(withTitle: "Batal")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty, !field.stringValue.contains("/") else { return }
        let target = ((listing?.path ?? path) as NSString).appendingPathComponent(field.stringValue)
        run("Membuat folder…") { await FilesStore.mkdir(node, target) }
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload ke \(node.name):\(listing?.path ?? path)"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, dir = listing?.path ?? path
        run("Upload \(urls.count) item…") { await FilesStore.upload(node, urls, to: dir) }
    }

    private func renameSheet(_ f: RFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ganti nama").font(.system(size: 15, weight: .bold))
            TextField("Nama baru", text: $newName).textFieldStyle(.roundedBorder).frame(width: 340)
            HStack {
                Spacer()
                Button("Batal") { renaming = nil }.keyboardShortcut(.cancelAction)
                Button("Simpan") {
                    let to = ((f.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
                    renaming = nil
                    run("Mengganti nama…") { await FilesStore.rename(node, f.path, to) }
                }
                .keyboardShortcut(.defaultAction).disabled(newName.isEmpty || newName.contains("/") || newName == f.name)
            }
        }
        .padding(20)
    }

    private func collect(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = DropBox()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { if !box.urls.isEmpty { then(box.urls) } } }
    }
}

private final class DropBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
}
