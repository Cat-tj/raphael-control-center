import Foundation

/// A project suggested by discovery: resources that verifiably belong together.
struct ProjectCandidate: Identifiable, Hashable {
    struct Resource: Hashable { let kind: ResourceLink.Kind; let ref: String; let label: String; let environment: String }
    let id: String                  // stable: "repo:owner/name" or "app:<monitor app id>"
    var name: String
    var resources: [Resource]
    var evidence: [String]          // why these belong together
    var lifecycleGuess: Lifecycle
    var hints: [String] = []        // uncertain relations, shown but never merged
    var linkedProject: String?      // an existing project already owns one of the resources
    var newResources: [Resource] = []
}

/// Builds candidates from local repos, GitHub, Vercel and the Monitor's app catalog.
/// Grouping uses exact identifiers only (git remote = GitHub repo = Vercel link; Caddy
/// route → container). Similar names are surfaced as hints, never merged.
@MainActor
enum ProjectRegistry {
    static func candidates() -> [ProjectCandidate] {
        let ws = WorkspaceStore.shared
        var byRepo: [String: ProjectCandidate] = [:]

        func repoKey(_ r: String) -> String { r.lowercased() }
        func ensure(_ repo: String, name: String) {
            let k = repoKey(repo)
            if byRepo[k] == nil {
                byRepo[k] = ProjectCandidate(id: "repo:\(k)", name: name, resources: [.init(kind: .repo, ref: repo, label: "", environment: "")],
                                             evidence: [], lifecycleGuess: .idea)
            }
        }

        // GitHub repositories the gh login can see.
        for r in GitHubStore.shared.repos {
            ensure(r.full, name: r.full.components(separatedBy: "/").last ?? r.full)
            byRepo[repoKey(r.full)]?.evidence.append("Repo GitHub \(r.full)")
            if let p = r.pushedAt, Date().timeIntervalSince(p) < 30 * 86400 { byRepo[repoKey(r.full)]?.lifecycleGuess = .building }
        }
        // Local folders: same repo when the git remote says so.
        var orphanLocal: [LocalProject] = []
        for p in LocalProjectsStore.shared.projects {
            guard let repo = p.repo else { orphanLocal.append(p); continue }
            ensure(repo, name: p.name)
            byRepo[repoKey(repo)]?.resources.append(.init(kind: .local, ref: p.path, label: p.name, environment: "development"))
            byRepo[repoKey(repo)]?.evidence.append("~/Projects/\(p.name) → remote \(repo)")
            if let c = p.lastCommit, Date().timeIntervalSince(c) < 30 * 86400, byRepo[repoKey(repo)]?.lifecycleGuess == .idea { byRepo[repoKey(repo)]?.lifecycleGuess = .building }
        }
        // Vercel projects linked to a repo (deployment metadata).
        var orphanVercel: [VProject] = []
        for v in VercelStore.shared.projects {
            guard let repo = v.repo else { orphanVercel.append(v); continue }
            ensure(repo, name: v.name)
            byRepo[repoKey(repo)]?.resources.append(.init(kind: .vercel, ref: v.id, label: v.name, environment: "production"))
            for d in v.domains { byRepo[repoKey(repo)]?.resources.append(.init(kind: .domain, ref: d, label: "", environment: "production")) }
            byRepo[repoKey(repo)]?.evidence.append("Vercel \(v.name) terhubung ke \(repo)")
            if v.state == "READY" { byRepo[repoKey(repo)]?.lifecycleGuess = .live }
        }

        var out = Array(byRepo.values)

        // Server / cloud apps from the Monitor (routing already verified there).
        let monitored = MonitorStore.shared.apps.filter { $0.kind != .local && $0.vercel == nil }
        for a in monitored {
            var res: [ProjectCandidate.Resource] = [.init(kind: .app, ref: a.id, label: a.name, environment: "production")]
            if let n = a.node { res.append(.init(kind: .node, ref: n, label: NodeStore.shared.nodes.first { $0.id == n }?.name ?? n, environment: "production")) }
            for u in a.urls { if let h = URL(string: u)?.host { res.append(.init(kind: .domain, ref: h, label: "", environment: "production")) } }
            if a.kind == .compose, let n = a.node { res.append(.init(kind: .compose, ref: "\(n):\(a.id.components(separatedBy: ":").last ?? a.name)", label: a.name, environment: "production")) }
            for s in a.services { res.append(.init(kind: .service, ref: "\(a.node ?? ""):\(s)", label: s, environment: "production")) }
            if let inst = a.n8n { res.append(.init(kind: .n8n, ref: inst.id, label: inst.name, environment: "production")) }
            let run = MonitorStore.shared.appStatus[a.id]?.run
            var c = ProjectCandidate(id: "app:\(a.id)", name: a.name, resources: res,
                                     evidence: ["Aplikasi \(a.kind.rawValue) di \(a.location.rawValue)" + (a.note.map { " · \($0)" } ?? "")],
                                     lifecycleGuess: run == .running || run == .issue ? .live : .maintenance)
            // Hints only: names that look alike are not proof.
            let base = a.name.lowercased().replacingOccurrences(of: " ", with: "-")
            for other in out where other.name.lowercased().replacingOccurrences(of: " ", with: "-").contains(base) || base.contains(other.name.lowercased()) {
                c.hints.append("Namanya mirip \(other.name): gabungkan manual kalau memang sama")
            }
            out.append(c)
        }
        for p in orphanLocal {
            out.append(ProjectCandidate(id: "local:\(p.path)", name: p.name, resources: [.init(kind: .local, ref: p.path, label: p.name, environment: "development")],
                                        evidence: ["Folder ~/Projects/\(p.name)" + (p.branch == nil ? " (bukan git)" : " (tanpa remote GitHub)")], lifecycleGuess: .idea))
        }
        for v in orphanVercel {
            out.append(ProjectCandidate(id: "vercel:\(v.id)", name: v.name,
                                        resources: [.init(kind: .vercel, ref: v.id, label: v.name, environment: "production")] + v.domains.map { .init(kind: .domain, ref: $0, label: "", environment: "production") },
                                        evidence: ["Project Vercel tanpa repo"], lifecycleGuess: v.state == "READY" ? .live : .building))
        }

        // Dedupe resources, mark what existing projects already own.
        let owned = Dictionary(ws.links.map { ("\($0.kind.rawValue)|\($0.ref.lowercased())", $0.projectId) }, uniquingKeysWith: { a, _ in a })
        return out.map { c in
            var c = c
            var seen = Set<String>()
            c.resources = c.resources.filter { seen.insert("\($0.kind.rawValue)|\($0.ref.lowercased())").inserted }
            let owners = c.resources.compactMap { owned["\($0.kind.rawValue)|\($0.ref.lowercased())"] }
            c.linkedProject = ws.decisions[c.id]?.projectId ?? owners.first
            c.newResources = c.resources.filter { owned["\($0.kind.rawValue)|\($0.ref.lowercased())"] == nil }
            return c
        }
        .sorted { ($0.resources.count, $0.name) > ($1.resources.count, $1.name) }
    }

    /// Accept as a new project (with all its resources).
    @discardableResult
    static func accept(_ c: ProjectCandidate, name: String, portfolioId: String?, lifecycle: Lifecycle) -> Project? {
        let ws = WorkspaceStore.shared
        guard let p = ws.createProject(name: name, portfolioId: portfolioId, lifecycle: lifecycle) else { return nil }
        for r in c.resources { ws.addLink(p.id, kind: r.kind, ref: r.ref, label: r.label, environment: r.environment, source: "discovery") }
        ws.decide(c.id, "accepted", projectId: p.id)
        return p
    }

    /// Add the candidate's resources to an existing project (manual correction).
    static func attach(_ c: ProjectCandidate, to projectId: String) {
        let ws = WorkspaceStore.shared
        for r in c.resources { ws.addLink(projectId, kind: r.kind, ref: r.ref, label: r.label, environment: r.environment, source: "discovery") }
        ws.decide(c.id, "accepted", projectId: projectId)
    }

    static func dismiss(_ c: ProjectCandidate) { WorkspaceStore.shared.decide(c.id, "dismissed", projectId: nil) }
}
