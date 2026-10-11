import Foundation

/// One Hermes agent/bot on the current device: the default home (~/.hermes,
/// "Raphael") or a profile under ~/.hermes/profiles/<name>. Each has its own
/// SOUL, .env and memories. Paths are device paths.
struct KAgent: Identifiable, Hashable {
    var id: String { "\(device):\(home)" }
    let device: String
    let profile: String
    let name: String
    let home: String
    var soulFiles: [String] = []
    var memoryFiles: [String] = []

    var envPath: String { home + "/.env" }
}

/// One line of a .env file; comments and blanks are kept so saving never reorders the file.
struct EnvLine: Identifiable, Hashable {
    let id = UUID()
    var raw: String
    var key: String?
    var value: String
    /// Value as read from disk; untouched lines are written back byte-for-byte.
    var origValue: String? = nil

    static func parse(_ text: String) -> [EnvLine] {
        text.components(separatedBy: "\n").map { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return EnvLine(raw: raw, key: nil, value: "") }
            var k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            if k.hasPrefix("export ") { k = String(k.dropFirst(7)) }
            var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            return EnvLine(raw: raw, key: k, value: v, origValue: v)
        }
    }

    static func render(_ lines: [EnvLine]) -> String {
        lines.map { l in
            guard let k = l.key, l.value != l.origValue else { return l.raw }
            let needsQuotes = l.value.contains(" ") || l.value.contains("#")
            return "\(k)=\(needsQuotes ? "\"\(l.value)\"" : l.value)"
        }.joined(separator: "\n")
    }
}

struct KGraph: Identifiable, Hashable {
    var id: String { "\(device):\(path)" }
    let device: String
    let name: String
    let path: String       // graph.json on the device
    let nodes: Int
    let edges: Int
    /// Source folder (for per-project grouping and refreshing), when known.
    var root: String? = nil
    var modified: Date? = nil
    /// Source changed after the graph was built.
    var stale = false

    var category: KCategory {
        if path.contains("/Raphael/graphs/library/") { return .docs }
        guard let root else { return .system }
        return root.contains("/Projects/") ? .project : .repo
    }
}

/// How the graph list is organised.
enum KCategory: String, CaseIterable, Identifiable {
    case project = "Proyek", repo = "Repo lain", docs = "Dokumen", system = "Sistem & Memory"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .project: "folder.fill"
        case .repo: "shippingbox.fill"
        case .docs: "doc.richtext.fill"
        case .system: "brain"
        }
    }
}

/// A project folder on this Mac without a graph yet.
struct KProject: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

@MainActor
final class KnowledgeStore: ObservableObject {
    static let shared = KnowledgeStore()
    @Published var agents: [KAgent] = []
    @Published var graphs: [KGraph] = []
    @Published var rendered: [String: URL] = [:]     // graph id → galaxy html
    @Published var rendering: Set<String> = []
    @Published var renderError: String?
    @Published var loading = false
    @Published var ungraphed: [KProject] = []
    @Published var building: Set<String> = []
    @Published var buildLog: String?
    /// Drops/clones being mapped right now (shown as progress rows).
    @Published var ingesting: [String] = []
    /// graph.json to select (and render) as soon as it shows up after a build.
    @Published var pendingSelect: String?
    private var reloadGen = 0

    /// How the galaxy groups nodes: "auto", "project" (one hub per sub-project) or "community".
    @Published var groupBy: String = UserDefaults.standard.string(forKey: "raphaelGraphGroupBy") ?? "auto" {
        didSet { UserDefaults.standard.set(groupBy, forKey: "raphaelGraphGroupBy") }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: .raphaelDeviceChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in KnowledgeStore.shared.reload() }
        }
    }

    nonisolated static var galaxyCLI: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("graphify-galaxy/.venv/bin/graphify").path
    }
    nonisolated static var graphsDir: URL {
        let d = NodeStore.supportDir.appendingPathComponent("graphs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Lists agents and graphs on every device in scope, plus this Mac's projects without a graph.
    /// Results show up per device as they arrive (a slow SSH host doesn't hold back the Mac),
    /// and a newer reload always wins over an older one still running.
    func reload() {
        let nodes = DeviceContext.shared.scope, scopeId = DeviceContext.shared.currentId
        reloadGen += 1
        let gen = reloadGen
        loading = true
        Task {
            var allAgents: [KAgent] = [], allGraphs: [KGraph] = []
            var first = true
            await withTaskGroup(of: (agents: [KAgent], graphs: [KGraph]).self) { group in
                for n in nodes { group.addTask { await Self.discover(n) } }
                for await r in group {
                    allAgents += r.agents; allGraphs += r.graphs
                    guard gen == reloadGen, DeviceContext.shared.currentId == scopeId else { continue }
                    publish(allAgents, allGraphs, nodes: nodes, replace: first)
                    first = false
                }
            }
            guard gen == reloadGen, DeviceContext.shared.currentId == scopeId else { return }
            publish(allAgents, allGraphs, nodes: nodes, replace: true)
            loading = false
        }
    }

    private func publish(_ foundAgents: [KAgent], _ found: [KGraph], nodes: [RNode], replace: Bool) {
        // While other devices are still answering, keep their previous rows.
        let answered = Set(found.map(\.device) + foundAgents.map(\.device))
        var allAgents = foundAgents + (replace ? [] : agents.filter { !answered.contains($0.device) })
        var allGraphs = found + (replace ? [] : graphs.filter { !answered.contains($0.device) })
        // One graph per project: a Raphael-built graph and the repo's own graphify-out
        // describe the same folder, keep the most recent.
        var newest: [String: KGraph] = [:]
        var unrooted: [KGraph] = []
        for g in allGraphs {
            guard let root = g.root else { unrooted.append(g); continue }
            let key = "\(g.device):\(root)"
            if let cur = newest[key], (cur.modified ?? .distantPast) >= (g.modified ?? .distantPast) { continue }
            newest[key] = g
        }
        allGraphs = unrooted + Array(newest.values)
        let order = nodes.map(\.id)
        allAgents.sort { (order.firstIndex(of: $0.device) ?? 0, $0.profile == "default" ? 0 : 1, $0.name) < (order.firstIndex(of: $1.device) ?? 0, $1.profile == "default" ? 0 : 1, $1.name) }
        allGraphs.sort { ($0.nodes == 0 ? 1 : 0, $0.name.lowercased()) < ($1.nodes == 0 ? 1 : 0, $1.name.lowercased()) }
        agents = allAgents
        graphs = allGraphs
        ungraphed = nodes.contains { $0.isLocal } ? Self.ungraphedProjects(known: allGraphs) : []
        for g in allGraphs where rendered[g.id] == nil {
            let html = Self.htmlURL(for: g)
            if FileManager.default.fileExists(atPath: html.path) { rendered[g.id] = html }
        }
    }

    // MARK: Building graphs (code only, local AST, 0 tokens)

    nonisolated static var projectsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects") }
    nonisolated static var builtDir: URL { graphsDir.appendingPathComponent("projects") }

    /// Folders in ~/Projects with neither their own graphify-out nor one built by Raphael.
    nonisolated static func ungraphedProjects(known: [KGraph]) -> [KProject] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let knownRoots = Set(known.compactMap(\.root))
        return names.compactMap { name in
            let path = projectsDir.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !knownRoots.contains(path) else { return nil }
            return KProject(name: name, path: path)
        }
    }

    /// Builds (or refreshes) a project's graph with `graphify extract --code-only`, written
    /// under Raphael's support folder so the project itself stays untouched.
    func build(_ projectPath: String, select: Bool = false) {
        guard !building.contains(projectPath) else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.galaxyCLI) else {
            buildLog = "graphify-galaxy belum terpasang di ~/graphify-galaxy"; return
        }
        building.insert(projectPath)
        let name = (projectPath as NSString).lastPathComponent
        let out = Self.builtDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? projectPath.write(to: out.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        Task {
            let r = await NodeStore.runProcess("/usr/bin/env", ["GRAPHIFY_NO_AUTO_REFRESH=1", Self.galaxyCLI, "extract", projectPath,
                                                                "--code-only", "--no-viz", "--out", out.path], timeout: 900)
            let graph = out.appendingPathComponent("graphify-out/graph.json")
            var line = String(r.output.split(separator: "\n").last { $0.contains("graph.json") } ?? Substring(r.output.suffix(200)))
                .replacingOccurrences(of: "[graphify extract] ", with: "")
            // The repo's README/docs join the code graph, tied to the symbols they name.
            if FileManager.default.fileExists(atPath: graph.path) {
                let d = await Self.docmap([projectPath], out: out, merge: graph)
                if d.exitCode == 0, let summary = d.output.split(separator: "\n").last(where: { $0.hasPrefix("[docmap]") }),
                   let n = summary.split(separator: ",").first(where: { $0.contains("dokumen") }) {
                    line += " ·" + n.replacingOccurrences(of: "[docmap]", with: "")
                }
                if select { pendingSelect = graph.path }
            }
            building.remove(projectPath)
            buildLog = "\(name): " + line
            // Drop a stale render so the next open shows the new graph.
            if let old = graphs.first(where: { $0.root == projectPath }) {
                try? FileManager.default.removeItem(at: Self.htmlURL(for: old)); rendered[old.id] = nil
            }
            if building.isEmpty { reload() }
        }
    }

    func buildAll() { ungraphed.forEach { build($0.path) } }

    // MARK: Merged galaxy ("semua jadi satu")

    static let mergedProjects = "merged:project"
    static let mergedAll = "merged:all"

    func mergedSources(_ key: String) -> [KGraph] {
        graphs.filter { $0.nodes > 0 && (key == Self.mergedAll || $0.category == .project) }
    }

    /// Merges several graphs into one (node ids and files prefixed with the project
    /// name) and renders it with one hub per project.
    func renderMerged(_ key: String) {
        guard !rendering.contains(key) else { return }
        let sources = mergedSources(key)
        guard !sources.isEmpty else { return }
        rendering.insert(key)
        renderError = nil
        let out = Self.graphsDir.appendingPathComponent("\(key.replacingOccurrences(of: ":", with: "-"))-3d.html")
        let dir = Self.graphsDir.appendingPathComponent(key.replacingOccurrences(of: ":", with: "-") + "/graphify-out")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let merged = dir.appendingPathComponent("graph.json")
        let names = Dictionary(grouping: sources, by: \.name)
        Task {
            // Local copies of remote graphs, then "name=path" pairs for the merge script.
            var pairs: [String] = []
            for g in sources {
                var path = g.path
                if let node = NodeStore.shared.nodes.first(where: { $0.id == g.device }), !node.isLocal {
                    let text = await DeviceContext.readFile(node, g.path)
                    let copy = Self.graphsDir.appendingPathComponent("\(g.device)-\(g.name).json")
                    try? text.write(to: copy, atomically: true, encoding: .utf8)
                    path = copy.path
                }
                let label = (names[g.name]?.count ?? 1) > 1 ? "\(g.name) (\(NodeStore.shared.nodes.first { $0.id == g.device }?.name ?? g.device))" : g.name
                pairs.append("\(label)=\(path)")
            }
            let py = #"""
            import json, sys
            out, nodes, links, first = sys.argv[1], [], [], None
            for pair in sys.argv[2:]:
                name, path = pair.split('=', 1)
                try: g = json.load(open(path))
                except Exception: continue
                first = first or g
                for n in g.get('nodes', []):
                    m = dict(n); m.pop('community', None)
                    m['id'] = f"{name}::{n['id']}"
                    m['source_file'] = f"{name}/{n.get('source_file') or '_'}"
                    nodes.append(m)
                for e in g.get('links', g.get('edges', [])):
                    f = dict(e)
                    for k in ('source', 'target', '_src', '_tgt'):
                        if k in f: f[k] = f"{name}::{f[k]}"
                    links.append(f)
            json.dump({'directed': (first or {}).get('directed', False), 'multigraph': (first or {}).get('multigraph', False),
                       'graph': {}, 'nodes': nodes, 'links': links}, open(out, 'w'))
            print(len(nodes), len(links))
            """#
            let m = await NodeStore.runProcess("/usr/bin/python3", ["-I", "-c", py, merged.path] + pairs, timeout: 300)
            let r = await NodeStore.runProcess("/usr/bin/env", ["GRAPHIFY_NO_AUTO_REFRESH=1", Self.galaxyCLI, "export", "galaxy",
                                                                "--graph", merged.path, "--output", out.path,
                                                                "--group-by", "project", "--node-limit", "12000"], timeout: 300)
            rendering.remove(key)
            if r.exitCode == 0, FileManager.default.fileExists(atPath: out.path) {
                rendered[key] = out
            } else {
                renderError = String((m.output + r.output).suffix(400))
            }
        }
    }
    func refreshStale() {
        for g in graphs where g.stale {
            guard let root = g.root else { continue }
            if g.category == .docs { mapDocs(name: g.name, root: root) } else { build(root) }
        }
    }

    /// One listing pass on the device: agents (home + profiles) with their SOUL and
    /// memory files, and every graphify graph.json.
    nonisolated static func discover(_ node: RNode) async -> (agents: [KAgent], graphs: [KGraph]) {
        let home = node.isLocal ? NodeStore.shellQuote(DeviceContext.hermesHome(node)) : "\"$HOME/.hermes\""
        let script = """
        H=\(home)
        for d in "$H" "$H"/profiles/*; do
          [ -d "$d" ] || continue
          echo "A|$d"
          for f in "$d"/SOUL*.md; do [ -f "$f" ] && echo "S|$f"; done
          for f in "$d"/memories/*.md "$d"/agent-memory/*.md; do [ -f "$f" ] && echo "M|$f"; done
        done
        for g in "$H"/agent-memory/graphify-out/graph.json "$HOME"/.graphify/global-graph.json "$HOME"/Projects/*/graphify-out/graph.json "$HOME"/*/graphify-out/graph.json "$HOME/Library/Application Support/Raphael/graphs/projects"/*/graphify-out/graph.json "$HOME/Library/Application Support/Raphael/graphs/library"/*/graphify-out/graph.json; do
          [ -f "$g" ] && echo "G|$g"
        done
        true
        """
        let r = await DeviceContext.run(node, script, timeout: 30)
        var agents: [KAgent] = []
        var graphPaths: [String] = []
        for line in r.output.split(separator: "\n").map(String.init) {
            let kind = line.prefix(2), path = String(line.dropFirst(2))
            switch kind {
            case "A|":
                let isDefault = !path.contains("/profiles/")
                let id = isDefault ? "default" : (path as NSString).lastPathComponent
                agents.append(KAgent(device: node.id, profile: id, name: isDefault ? "Raphael" : id.capitalized, home: path))
            case "S|": if !agents.isEmpty { agents[agents.count - 1].soulFiles.append(path) }
            case "M|": if !agents.isEmpty { agents[agents.count - 1].memoryFiles.append(path) }
            case "G|": if !graphPaths.contains(path) { graphPaths.append(path) }
            default: break
            }
        }
        var graphs: [KGraph] = []
        if !graphPaths.isEmpty {
            let py = """
            import json, os, sys
            for p in sys.argv[1:]:
                try:
                    d = json.load(open(p)); print(p, len(d.get('nodes', [])), len(d.get('links', d.get('edges', []))), int(os.path.getmtime(p)), sep='|')
                except Exception: print(p, 0, 0, 0, sep='|')
            """
            let args = graphPaths.map(NodeStore.shellQuote).joined(separator: " ")
            let s = await DeviceContext.run(node, "python3 - \(args) <<'RAPHAEL_PY'\n\(py)\nRAPHAEL_PY", timeout: 60)
            for line in s.output.split(separator: "\n") {
                let f = line.split(separator: "|").map(String.init)
                guard f.count == 4 else { continue }
                var g = KGraph(device: node.id, name: graphName(f[0]), path: f[0], nodes: Int(f[1]) ?? 0, edges: Int(f[2]) ?? 0,
                               modified: Date(timeIntervalSince1970: Double(f[3]) ?? 0))
                g.root = graphRoot(f[0])
                if node.isLocal, let root = g.root, let built = g.modified { g.stale = sourceNewer(than: built, in: root) }
                graphs.append(g)
            }
        }
        return (agents, graphs)
    }

    /// The source folder a graph describes: the parent of graphify-out, or the
    /// ~/Projects/<name> folder for graphs Raphael built.
    nonisolated static func graphRoot(_ path: String) -> String? {
        if path.contains("/agent-memory/") || path.hasSuffix("global-graph.json") { return nil }
        if path.contains("/Raphael/graphs/projects/") || path.contains("/Raphael/graphs/library/") {
            // build() records the source folder next to the graph.
            let dir = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            if let root = try? String(contentsOfFile: dir + "/root.txt", encoding: .utf8) {
                return root.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if path.contains("/Raphael/graphs/library/") { return nil }
            return projectsDir.appendingPathComponent(graphName(path)).path
        }
        return ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    /// True when any tracked-looking source file changed after `date` (cheap scan, skips heavy folders).
    nonisolated static func sourceNewer(than date: Date, in root: String) -> Bool {
        let skip: Set<String> = ["node_modules", ".git", "graphify-out", "build", "dist", ".next", ".venv", "Pods", ".build", "target"]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let url as URL in e {
            if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            seen += 1
            if seen > 20_000 { break }
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > date.addingTimeInterval(60) {
                return true
            }
        }
        return false
    }

    nonisolated static func graphName(_ path: String) -> String {
        if path.contains("/agent-memory/") { return "Memory Raphael" }
        if path.hasSuffix("global-graph.json") { return "Global graph" }
        let parts = path.split(separator: "/")
        if let i = parts.firstIndex(of: "graphify-out"), i > 0 { return String(parts[i - 1]) }
        return (path as NSString).lastPathComponent
    }

    // MARK: Local files (used by DeviceContext for this Mac)

    nonisolated static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Writes with a rolling `.raphael.bak` copy of the previous version and the original permissions.
    @discardableResult
    nonisolated static func write(_ text: String, to url: URL) -> Bool {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        let bak = URL(fileURLWithPath: url.path + ".raphael.bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
            return true
        } catch { return false }
    }

    // MARK: 3D graph

    nonisolated static func htmlURL(for g: KGraph) -> URL {
        let slug = "\(g.device)-\(g.name)".lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        return graphsDir.appendingPathComponent("\(slug)-3d.html")
    }

    /// Renders the glowing 3D galaxy with the upgraded graphify (~/graphify-galaxy) on this Mac;
    /// a remote graph.json is copied over first.
    func render(_ g: KGraph) {
        guard !rendering.contains(g.id) else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.galaxyCLI) else {
            renderError = "graphify-galaxy belum terpasang di ~/graphify-galaxy"
            return
        }
        rendering.insert(g.id)
        renderError = nil
        let out = Self.htmlURL(for: g)
        let node = NodeStore.shared.nodes.first { $0.id == g.device } ?? DeviceContext.shared.current
        let group = groupBy
        Task {
            var graphPath = g.path
            if !node.isLocal {
                let text = await DeviceContext.readFile(node, g.path)
                let dir = Self.graphsDir.appendingPathComponent("\(g.device)-\(g.name)/graphify-out")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("graph.json")
                try? text.write(to: file, atomically: true, encoding: .utf8)
                graphPath = file.path
            }
            // GRAPHIFY_NO_AUTO_REFRESH: never let graphify rewrite the agents' skill files.
            var args = ["GRAPHIFY_NO_AUTO_REFRESH=1", Self.galaxyCLI, "export", "galaxy",
                        "--graph", graphPath, "--output", out.path, "--group-by", group]
            if node.isLocal, let root = g.root { args += ["--root", root] }
            let r = await NodeStore.runProcess("/usr/bin/env", args, timeout: 180)
            rendering.remove(g.id)
            if FileManager.default.fileExists(atPath: out.path), r.exitCode == 0 {
                rendered[g.id] = out
            } else {
                renderError = String(r.output.suffix(400))
            }
        }
    }
}
