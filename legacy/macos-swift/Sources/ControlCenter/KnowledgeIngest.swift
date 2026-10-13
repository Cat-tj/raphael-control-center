import AppKit
import PDFKit

/// Dropping things on the knowledge graph: PDFs and notes become a document
/// graph, folders with code become a project graph, git URLs are cloned first.
/// Everything is mapped on this Mac without an LLM (0 token).
extension KnowledgeStore {
    static let docExtensions: Set<String> = ["pdf", "md", "markdown", "mdx", "txt", "rst", "png", "jpg", "jpeg", "gif", "webp", "svg", "heic"]
    static let defaultCollection = "Dokumen"

    nonisolated static var libraryDir: URL { graphsDir.appendingPathComponent("library") }
    nonisolated static var reposDir: URL { NodeStore.supportDir.appendingPathComponent("repos") }
    nonisolated static var galaxyPython: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("graphify-galaxy/.venv/bin/python").path
    }

    /// Maps dropped files and folders. Loose documents are copied into `collection`
    /// so the graph survives the originals being moved.
    func ingest(_ urls: [URL], collection: String = KnowledgeStore.defaultCollection) {
        var loose: [URL] = []
        var skipped: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if Self.looksLikeCode(url) { build(url.path, select: true) }
                else { mapDocs(name: url.lastPathComponent, root: url.path) }
            } else if Self.docExtensions.contains(url.pathExtension.lowercased()) {
                loose.append(url)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            buildLog = "Dilewati (bukan PDF/Markdown/teks/gambar atau folder): " + skipped.joined(separator: ", ")
        }
        guard !loose.isEmpty else { return }
        let files = Self.libraryDir.appendingPathComponent(Self.folderName(collection)).appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for url in loose {
            var dest = files.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                if FileManager.default.contentsEqual(atPath: dest.path, andPath: url.path) { continue }
                let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                var i = 2
                repeat { dest = files.appendingPathComponent("\(stem) \(i).\(ext)"); i += 1 } while FileManager.default.fileExists(atPath: dest.path)
            }
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        mapDocs(name: collection, root: files.path)
    }

    /// Builds (or rebuilds) a document graph for every PDF/Markdown/text under `root`.
    func mapDocs(name: String, root: String) {
        let key = "docs:" + root
        guard !ingesting.contains(key) else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.galaxyPython) else {
            buildLog = "graphify-galaxy belum terpasang di ~/graphify-galaxy"; return
        }
        ingesting.append(key)
        let out = Self.libraryDir.appendingPathComponent(Self.folderName(name))
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? root.write(to: out.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        Task {
            let text = out.appendingPathComponent("text")
            await Task.detached { Self.extractPDFText(under: URL(fileURLWithPath: root), into: text) }.value
            let r = await Self.docmap([root], out: out, pdfText: text)
            ingesting.removeAll { $0 == key }
            let summary = r.output.split(separator: "\n").last { $0.hasPrefix("[docmap]") }
            buildLog = "\(name): " + (summary.map { String($0.split(separator: "→").first ?? $0).replacingOccurrences(of: "[docmap] ", with: "") }
                                      ?? String(r.output.suffix(300)))
            let graph = out.appendingPathComponent("graphify-out/graph.json")
            if r.exitCode == 0 {
                if let old = graphs.first(where: { $0.path == graph.path }) {
                    try? FileManager.default.removeItem(at: Self.htmlURL(for: old)); rendered[old.id] = nil
                }
                pendingSelect = graph.path
            }
            if ingesting.isEmpty && building.isEmpty { reload() }
        }
    }

    /// Clones a git repository (shallow) into Raphael's folder, or pulls it when it is
    /// already there, then builds its graph.
    func cloneAndBuild(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.range(of: #"^(https://|git@)[\w.@:/\-~]+$"#, options: .regularExpression) != nil else {
            buildLog = "URL repo tidak valid. Contoh: https://github.com/user/repo"; return
        }
        var name = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repo"
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let dest = Self.reposDir.appendingPathComponent(Self.folderName(name))
        let key = "clone:" + url
        guard !ingesting.contains(key) else { return }
        ingesting.append(key)
        try? FileManager.default.createDirectory(at: Self.reposDir, withIntermediateDirectories: true)
        Task {
            let exists = FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path)
            let r = exists
                ? await NodeStore.runProcess("/usr/bin/git", ["-C", dest.path, "pull", "--ff-only", "--depth", "1"], timeout: 600)
                : await NodeStore.runProcess("/usr/bin/git", ["clone", "--depth", "1", "--", url, dest.path], timeout: 900)
            ingesting.removeAll { $0 == key }
            if r.exitCode == 0 || exists {
                build(dest.path, select: true)
            } else {
                buildLog = "\(name): clone gagal · " + String(r.output.suffix(240))
            }
        }
    }

    /// Removes a document collection Raphael made (its copied files and graph).
    func deleteCollection(_ g: KGraph) {
        guard g.category == .docs else { return }
        let dir = URL(fileURLWithPath: g.path).deletingLastPathComponent().deletingLastPathComponent()
        guard dir.path.hasPrefix(Self.libraryDir.path) else { return }
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: Self.htmlURL(for: g))
        rendered[g.id] = nil
        reload()
    }

    // MARK: Raphael Studio (web: documents + 3D presentations)

    nonisolated static let studioPort = 7337
    nonisolated(unsafe) static var studioProcess: Process?

    /// Opens Raphael Studio in the browser on `graph` (starting the local server when needed).
    func openStudio(_ graph: KGraph? = nil) {
        var url = "http://127.0.0.1:\(Self.studioPort)/"
        if let g = graph, g.device == "mac" || NodeStore.shared.nodes.first(where: { $0.id == g.device })?.isLocal == true {
            let kind = g.category == .docs ? "docs" : "project"
            url += "#c=" + Self.studioSlug("\(kind)-\(g.name)")
        }
        Task {
            if !(await Self.studioRunning()) {
                guard FileManager.default.isExecutableFile(atPath: Self.galaxyPython) else {
                    buildLog = "graphify-galaxy belum terpasang di ~/graphify-galaxy"; return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.galaxyPython)
                p.arguments = ["-m", "graphify.studio", "--port", String(Self.studioPort), "--tailscale"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = NodeStore.toolPath; env["GRAPHIFY_NO_AUTO_REFRESH"] = "1"
                p.environment = env
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run(); Self.studioProcess = p } catch { buildLog = "Studio gagal start: \(error.localizedDescription)"; return }
                for _ in 0..<30 where !(await Self.studioRunning()) { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    nonisolated static func studioRunning() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(studioPort)/api/collections")!)
        req.timeoutInterval = 0.6
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Same ids as graphify/studio.py `slug()`.
    nonisolated static func studioSlug(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return t.isEmpty ? "x" : String(t.prefix(80))
    }

    /// Display-safe folder name (keeps spaces and case, drops path characters).
    nonisolated static func folderName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"[/:\\]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return t.isEmpty ? "Dokumen" : String(t.prefix(80))
    }

    nonisolated static func docmap(_ inputs: [String], out: URL, merge: URL? = nil, pdfText: URL? = nil) async -> (output: String, exitCode: Int32) {
        var args = ["GRAPHIFY_NO_AUTO_REFRESH=1", galaxyPython, "-m", "graphify.docmap"] + inputs + ["--out", out.path]
        if let merge { args += ["--merge", merge.path] }
        if let pdfText { args += ["--pdf-text", pdfText.path] }
        return await NodeStore.runProcess("/usr/bin/env", args, timeout: 600)
    }

    /// A folder is a code project when it is a git repo, has a package manifest, or
    /// holds more source files than documents.
    nonisolated static func looksLikeCode(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let manifests = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py", "Package.swift",
                         "pom.xml", "build.gradle", "composer.json", "Gemfile", "requirements.txt", "project.yml", "Makefile"]
        if manifests.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { return true }
        let code: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt", "c", "h", "cpp", "cs",
                                 "rb", "php", "vue", "svelte", "dart", "scala", "lua", "sh", "sql"]
        var nCode = 0, nDocs = 0, seen = 0
        let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL, seen < 4000 {
            seen += 1
            if ["node_modules", "build", "dist", "Pods", "target"].contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            if code.contains(ext) { nCode += 1 } else if docExtensions.contains(ext) { nDocs += 1 }
        }
        return nCode > max(3, nDocs)
    }

    /// PDF text with PDFKit (pages separated by form feeds), cached next to the graph.
    nonisolated static func extractPDFText(under root: URL, into dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var count = 0
        while let url = e?.nextObject() as? URL, count < 500 {
            if ["node_modules", ".git", "graphify-out"].contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            count += 1
            let side = dir.appendingPathComponent(url.lastPathComponent + ".txt")
            let srcDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if let d = (try? fm.attributesOfItem(atPath: side.path))?[.modificationDate] as? Date, d >= srcDate { continue }
            guard let doc = PDFDocument(url: url) else { continue }
            let text = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }.joined(separator: "\u{0C}")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? text.write(to: side, atomically: true, encoding: .utf8)
            }
        }
    }
}
