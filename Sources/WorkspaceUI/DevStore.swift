import Foundation

// GitHub development data per linked repository (through the gh CLI), Vercel deployments,
// read-only issue / GitHub Projects (v2) sync into tasks, and activity events from them.

struct GHCommit: Hashable { let sha: String; let message: String; let author: String; let date: Date?; let url: String }
struct GHIssue: Hashable {
    let number: Int; let title: String; let state: String; let isPR: Bool; let labels: [String]; let assignees: [String]
    let milestone: Int?; let milestoneTitle: String?; let url: String; let createdAt: Date?; let closedAt: Date?; let updatedAt: Date?; let body: String
}
struct GHPull: Hashable {
    let number: Int; let title: String; let state: String; let merged: Bool; let draft: Bool; let url: String
    let author: String; let createdAt: Date?; let mergedAt: Date?; let updatedAt: Date?; var review: String?
}
struct GHRun: Hashable { let id: Int; let name: String; let status: String; let conclusion: String?; let branch: String; let event: String; let createdAt: Date?; let url: String }
struct GHRelease: Hashable { let tag: String; let name: String; let date: Date?; let url: String; let prerelease: Bool }
struct GHMilestone: Hashable { let number: Int; let title: String; let state: String; let due: Date?; let open: Int; let closed: Int; let url: String }

struct RepoDev {
    var repo: String
    var fetchedAt: Date?
    var error: String?
    var defaultBranch = ""
    var pushedAt: Date?
    var isPrivate = false
    var branches: [String] = []
    var commits: [GHCommit] = []
    var issues: [GHIssue] = []
    var pulls: [GHPull] = []
    var runs: [GHRun] = []
    var releases: [GHRelease] = []
    var milestones: [GHMilestone] = []
}

struct VDeployment: Hashable { let uid: String; let state: String; let target: String; let url: String; let createdAt: Date?; let readyAt: Date?; let commit: String?; let branch: String? }

@MainActor
final class DevStore: ObservableObject {
    static let shared = DevStore()
    @Published private(set) var repos: [String: RepoDev] = [:]           // lowercased owner/name →
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var deployments: [String: [VDeployment]] = [:]   // vercel project id →
    @Published private(set) var deployErrors: [String: String] = [:]
    @Published private(set) var projectsV2Error: String?
    @Published private(set) var lastSync: [String: String] = [:]
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { @MainActor in DevStore.shared.refreshLinked() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { DevStore.shared.refreshLinked() }
    }

    func repo(_ r: String) -> RepoDev? { repos[r.lowercased()] }

    /// Every repo / Vercel project linked to any project, then events + syncs.
    func refreshLinked() {
        let ws = WorkspaceStore.shared
        for r in Set(ws.links.filter { $0.kind == .repo }.map(\.ref)) { refresh(repo: r) }
        for v in Set(ws.links.filter { $0.kind == .vercel }.map(\.ref)) { refreshDeployments(v) }
        Task { await AgentActivity.shared.refresh() }
        MonitorTransitions.record()
    }

    // MARK: GitHub

    nonisolated private static func gh(_ args: [String]) async -> (Any?, String?) {
        guard let gh = GitHubStore.gh else { return (nil, "gh CLI belum terpasang") }
        let r = await NodeStore.runProcess(gh, ["api"] + args, timeout: 30)
        guard r.exitCode == 0 else {
            let msg = r.output.split(separator: "\n").first.map(String.init) ?? "gh api gagal"
            return (nil, msg.contains("404") || msg.contains("Not Found") ? "Repo tidak ditemukan atau tidak bisa diakses" : msg)
        }
        return (try? JSONSerialization.jsonObject(with: Data(r.output.utf8)), nil)
    }

    nonisolated private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    nonisolated private static func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }

    func refresh(repo: String) {
        let key = repo.lowercased()
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task {
            let r = await Self.fetch(repo)
            repos[key] = r
            loading.remove(key)
            if r.error == nil {
                recordEvents(r)
                IssueSync.run(for: r)
            }
        }
    }

    nonisolated static func fetch(_ repo: String) async -> RepoDev {
        var d = RepoDev(repo: repo)
        async let info = gh(["repos/\(repo)"])
        async let commits = gh(["repos/\(repo)/commits?per_page=20"])
        async let issues = gh(["repos/\(repo)/issues?state=all&per_page=60&sort=updated"])
        async let pulls = gh(["repos/\(repo)/pulls?state=all&per_page=25&sort=updated&direction=desc"])
        async let runs = gh(["repos/\(repo)/actions/runs?per_page=20"])
        async let releases = gh(["repos/\(repo)/releases?per_page=10"])
        async let milestones = gh(["repos/\(repo)/milestones?state=all&per_page=30"])
        async let branches = gh(["repos/\(repo)/branches?per_page=40"])
        let (i, ie) = await info
        guard let j = i as? [String: Any] else { d.error = ie ?? "Tidak bisa membaca repo"; d.fetchedAt = Date(); return d }
        d.defaultBranch = j["default_branch"] as? String ?? ""
        d.pushedAt = date(j["pushed_at"])
        d.isPrivate = j["private"] as? Bool ?? false
        d.commits = ((await commits).0 as? [[String: Any]] ?? []).map { c in
            let commit = c["commit"] as? [String: Any]
            return GHCommit(sha: c["sha"] as? String ?? "", message: (commit?["message"] as? String ?? "").components(separatedBy: "\n").first ?? "",
                            author: ((c["author"] as? [String: Any])?["login"] as? String) ?? ((commit?["author"] as? [String: Any])?["name"] as? String ?? ""),
                            date: date((commit?["author"] as? [String: Any])?["date"]), url: c["html_url"] as? String ?? "")
        }
        d.issues = ((await issues).0 as? [[String: Any]] ?? []).map { x in
            let m = x["milestone"] as? [String: Any]
            return GHIssue(number: x["number"] as? Int ?? 0, title: x["title"] as? String ?? "", state: x["state"] as? String ?? "",
                           isPR: x["pull_request"] != nil, labels: (x["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                           assignees: (x["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String },
                           milestone: m?["number"] as? Int, milestoneTitle: m?["title"] as? String, url: x["html_url"] as? String ?? "",
                           createdAt: date(x["created_at"]), closedAt: date(x["closed_at"]), updatedAt: date(x["updated_at"]),
                           body: String((x["body"] as? String ?? "").prefix(4000)))
        }
        var prs = ((await pulls).0 as? [[String: Any]] ?? []).map { x in
            GHPull(number: x["number"] as? Int ?? 0, title: x["title"] as? String ?? "", state: x["state"] as? String ?? "",
                   merged: x["merged_at"] is String, draft: x["draft"] as? Bool ?? false, url: x["html_url"] as? String ?? "",
                   author: (x["user"] as? [String: Any])?["login"] as? String ?? "", createdAt: date(x["created_at"]),
                   mergedAt: date(x["merged_at"]), updatedAt: date(x["updated_at"]))
        }
        // Review state of open PRs (latest review per reviewer).
        for i in prs.indices where prs[i].state == "open" {
            let (rv, _) = await gh(["repos/\(repo)/pulls/\(prs[i].number)/reviews?per_page=50"])
            var latest: [String: String] = [:]
            for r in rv as? [[String: Any]] ?? [] { if let who = (r["user"] as? [String: Any])?["login"] as? String, let s = r["state"] as? String, s != "COMMENTED" { latest[who] = s } }
            prs[i].review = latest.values.contains("CHANGES_REQUESTED") ? "changes requested" : latest.values.contains("APPROVED") ? "approved" : latest.isEmpty ? "menunggu review" : "direview"
        }
        d.pulls = prs
        d.runs = (((await runs).0 as? [String: Any])?["workflow_runs"] as? [[String: Any]] ?? []).map { x in
            GHRun(id: x["id"] as? Int ?? 0, name: x["name"] as? String ?? "", status: x["status"] as? String ?? "", conclusion: x["conclusion"] as? String,
                  branch: x["head_branch"] as? String ?? "", event: x["event"] as? String ?? "", createdAt: date(x["created_at"]), url: x["html_url"] as? String ?? "")
        }
        d.releases = ((await releases).0 as? [[String: Any]] ?? []).map { x in
            GHRelease(tag: x["tag_name"] as? String ?? "", name: x["name"] as? String ?? "", date: date(x["published_at"]), url: x["html_url"] as? String ?? "",
                      prerelease: x["prerelease"] as? Bool ?? false)
        }
        d.milestones = ((await milestones).0 as? [[String: Any]] ?? []).map { x in
            GHMilestone(number: x["number"] as? Int ?? 0, title: x["title"] as? String ?? "", state: x["state"] as? String ?? "", due: date(x["due_on"]),
                        open: x["open_issues"] as? Int ?? 0, closed: x["closed_issues"] as? Int ?? 0, url: x["html_url"] as? String ?? "")
        }
        d.branches = ((await branches).0 as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        d.fetchedAt = Date()
        return d
    }

    /// Stable ids → repeated refreshes never duplicate events.
    private func recordEvents(_ r: RepoDev) {
        let ws = WorkspaceStore.shared
        let projects = ws.links.filter { $0.kind == .repo && $0.ref.lowercased() == r.repo.lowercased() }.map(\.projectId)
        guard !projects.isEmpty else { return }
        var ev: [ActivityEvent] = []
        for pid in Set(projects) {
            func add(_ id: String, _ type: String, _ ts: Date?, _ title: String, _ url: String, _ meta: [String: String] = [:]) {
                guard let ts else { return }
                ev.append(ActivityEvent(id: "github:\(id)|\(pid)", projectId: pid, type: type, ts: ts, source: "github", title: title, url: url, meta: meta.merging(["repo": r.repo]) { a, _ in a }))
            }
            for c in r.commits { add("commit:\(r.repo)@\(c.sha)", "github.commit", c.date, "\(c.author): \(c.message)", c.url, ["sha": String(c.sha.prefix(7))]) }
            for i in r.issues where !i.isPR {
                add("issue:\(r.repo)#\(i.number):opened", "issue.opened", i.createdAt, "Issue #\(i.number) dibuka: \(i.title)", i.url)
                if i.state == "closed" { add("issue:\(r.repo)#\(i.number):closed", "issue.closed", i.closedAt, "Issue #\(i.number) ditutup: \(i.title)", i.url) }
            }
            for p in r.pulls {
                add("pr:\(r.repo)#\(p.number):opened", "pr.opened", p.createdAt, "PR #\(p.number) dibuka: \(p.title)", p.url)
                if p.merged { add("pr:\(r.repo)#\(p.number):merged", "pr.merged", p.mergedAt, "PR #\(p.number) di-merge: \(p.title)", p.url) }
            }
            for run in r.runs where run.status == "completed" {
                let ok = run.conclusion == "success"
                guard ok || run.conclusion == "failure" else { continue }
                add("ci:\(r.repo):\(run.id)", ok ? "ci.passed" : "ci.failed", run.createdAt, "CI \(ok ? "lulus" : "gagal"): \(run.name) · \(run.branch)", run.url)
            }
            for rel in r.releases { add("release:\(r.repo):\(rel.tag)", "release.published", rel.date, "Release \(rel.tag)\(rel.name.isEmpty || rel.name == rel.tag ? "" : " · \(rel.name)")", rel.url) }
        }
        ws.record(ev)
        lastSync["github:\(r.repo.lowercased())"] = Date().formatted(date: .omitted, time: .shortened)
    }

    // MARK: Vercel

    func refreshDeployments(_ projectId: String) {
        guard let token = KeychainStore.shared.get(VercelStore.keychainKey), !token.isEmpty else { deployErrors[projectId] = "Vercel belum terhubung (Monitor → Sumber data)"; return }
        let team = VercelStore.shared.projects.first { $0.id == projectId }?.team
        Task {
            var req = URLRequest(url: URL(string: "https://api.vercel.com/v6/deployments?projectId=\(projectId)&limit=20" + (team.map { "&teamId=\($0)" } ?? ""))!, timeoutInterval: 20)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                deployErrors[projectId] = "Gagal membaca deployment Vercel"; return
            }
            let list = (j["deployments"] as? [[String: Any]] ?? []).map { d -> VDeployment in
                let meta = d["meta"] as? [String: Any]
                return VDeployment(uid: d["uid"] as? String ?? "", state: d["state"] as? String ?? d["readyState"] as? String ?? "", target: d["target"] as? String ?? "preview",
                                   url: (d["url"] as? String).map { "https://" + $0 } ?? "", createdAt: (d["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                                   readyAt: (d["ready"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                                   commit: meta?["githubCommitMessage"] as? String, branch: meta?["githubCommitRef"] as? String)
            }
            deployments[projectId] = list
            deployErrors[projectId] = nil
            let ws = WorkspaceStore.shared
            var ev: [ActivityEvent] = []
            for pid in Set(ws.links.filter { $0.kind == .vercel && $0.ref == projectId }.map(\.projectId)) {
                for d in list {
                    let type = d.state == "READY" ? "deploy.completed" : d.state == "ERROR" ? "deploy.failed" : d.state == "CANCELED" ? "deploy.canceled" : "deploy.started"
                    ev.append(ActivityEvent(id: "vercel:\(d.uid):\(type)|\(pid)", projectId: pid, type: type, ts: d.readyAt ?? d.createdAt ?? Date(), source: "vercel",
                                            title: "Deploy \(d.target) \(d.state.lowercased())\(d.commit.map { ": \($0)" } ?? "")", url: d.url, meta: ["target": d.target]))
                }
            }
            ws.record(ev)
        }
    }
}

// MARK: - Read-only issue sync

/// Mirrors GitHub issues of linked repos into tasks, one-way, for projects that turn it on.
/// (system, external id) is unique, so an issue maps to at most one task; a task the owner
/// deleted is not recreated. Only title and open/closed state flow in; local edits to other
/// fields stay. Two-way sync is deliberately not implemented.
@MainActor
enum IssueSync {
    static func enabled(_ projectId: String) -> Bool { WorkspaceStore.shared.syncState("issueSync:\(projectId)") == "on" }
    static func setEnabled(_ projectId: String, _ on: Bool) {
        WorkspaceStore.shared.setSyncState("issueSync:\(projectId)", on ? "on" : "off")
        if on { for l in WorkspaceStore.shared.links(of: projectId, .repo) { if let r = DevStore.shared.repo(l.ref) { run(for: r) } else { DevStore.shared.refresh(repo: l.ref) } } }
    }

    static func run(for r: RepoDev) {
        let ws = WorkspaceStore.shared
        for pid in Set(ws.links.filter { $0.kind == .repo && $0.ref.lowercased() == r.repo.lowercased() }.map(\.projectId)) where enabled(pid) {
            var created = 0, updated = 0
            // GitHub milestones → project milestones (by external id).
            var milestoneMap: [Int: String] = [:]
            for m in r.milestones {
                let ext = "\(r.repo)/milestone/\(m.number)"
                if let ref = ws.external(system: "github", id: ext), ws.milestones.contains(where: { $0.id == ref.entityId }) {
                    milestoneMap[m.number] = ref.entityId
                    if var local = ws.milestones.first(where: { $0.id == ref.entityId }), ref.state != m.state {
                        if m.state == "closed" && local.completedAt == nil { local.completedAt = Date(); ws.updateMilestone(local) }
                        ws.upsertExternal(ExternalRef(id: ref.id, entity: "milestone", entityId: ref.entityId, system: "github", externalId: ext, url: m.url, state: m.state))
                    }
                } else if ws.external(system: "github", id: ext) == nil, let local = ws.createMilestone(pid, title: m.title, targetDate: m.due) {
                    if m.state == "closed" { var x = local; x.completedAt = Date(); ws.updateMilestone(x) }
                    ws.upsertExternal(ExternalRef(id: WorkspaceStore.newID(), entity: "milestone", entityId: local.id, system: "github", externalId: ext, url: m.url, state: m.state))
                    milestoneMap[m.number] = local.id
                }
            }
            for i in r.issues where !i.isPR {
                let ext = "\(r.repo)#\(i.number)"
                if let ref = ws.external(system: "github", id: ext) {
                    guard ref.entity == "task", var t = ws.tasks.first(where: { $0.id == ref.entityId }) else { continue }    // deleted locally: respect it
                    var changed = false
                    if t.title != i.title { t.title = i.title; changed = true }
                    if i.state == "closed" && t.status != .done && ref.state != "closed" { t.status = .done; changed = true }
                    if i.state == "open" && ref.state == "closed" && t.status == .done { t.status = .backlog; changed = true }
                    if changed { ws.updateTask(t); updated += 1 }
                    if ref.state != i.state { ws.upsertExternal(ExternalRef(id: ref.id, entity: "task", entityId: t.id, system: "github", externalId: ext, url: i.url, state: i.state)) }
                } else {
                    guard let t = ws.createTask(projectId: pid, title: i.title, status: i.state == "closed" ? .done : .backlog,
                                                assignee: i.assignees.first ?? "", milestoneId: i.milestone.flatMap { milestoneMap[$0] }) else { continue }
                    var x = t; x.labels = i.labels; x.description = i.body; ws.updateTask(x)
                    ws.upsertExternal(ExternalRef(id: WorkspaceStore.newID(), entity: "task", entityId: t.id, system: "github", externalId: ext, url: i.url, state: i.state))
                    created += 1
                }
            }
            ws.setSyncState("issueSync:last:\(pid)", "\(ISO8601DateFormatter().string(from: Date()))|\(r.repo)|+\(created)|~\(updated)")
        }
    }
}

// MARK: - GitHub Projects (v2), read-only

struct GHProjectV2: Identifiable, Hashable { let id: String; let title: String; let number: Int; let url: String; let owner: String }

@MainActor
enum ProjectsV2Sync {
    /// Projects visible to the gh login (needs the read:project scope).
    static func list() async -> ([GHProjectV2], String?) {
        let q = "query { viewer { login projectsV2(first: 30) { nodes { id title number url } } organizations(first: 20) { nodes { login projectsV2(first: 20) { nodes { id title number url } } } } } }"
        guard let gh = GitHubStore.gh else { return ([], "gh CLI belum terpasang") }
        let r = await NodeStore.runProcess(gh, ["api", "graphql", "-f", "query=\(q)"], timeout: 30)
        guard r.exitCode == 0, let j = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any] else {
            return ([], r.output.contains("read:project") || r.output.contains("INSUFFICIENT_SCOPES")
                    ? "Login gh belum punya izin project. Jalankan: gh auth refresh -s read:project" : String(r.output.prefix(200)))
        }
        if let errs = j["errors"] as? [[String: Any]], !errs.isEmpty {
            let m = errs.compactMap { $0["message"] as? String }.joined(separator: "; ")
            if (j["data"] as? [String: Any])?["viewer"] == nil { return ([], m.contains("scope") ? "Login gh belum punya izin project. Jalankan: gh auth refresh -s read:project" : m) }
        }
        let viewer = (j["data"] as? [String: Any])?["viewer"] as? [String: Any]
        let me = viewer?["login"] as? String ?? ""
        func parse(_ v: Any?, _ owner: String) -> [GHProjectV2] {
            ((v as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { n in
                guard let id = n["id"] as? String else { return nil }
                return GHProjectV2(id: id, title: n["title"] as? String ?? "", number: n["number"] as? Int ?? 0, url: n["url"] as? String ?? "", owner: owner)
            }
        }
        var out = parse(viewer?["projectsV2"], me)
        for o in (viewer?["organizations"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] { out += parse(o["projectsV2"], o["login"] as? String ?? "") }
        return (out, nil)
    }

    static func statusMap(_ name: String) -> TaskStatus? {
        let n = name.lowercased()
        if n.contains("done") || n.contains("closed") || n.contains("complete") || n.contains("selesai") { return .done }
        if n.contains("review") || n.contains("qa") { return .review }
        if n.contains("progress") || n.contains("doing") || n.contains("wip") { return .inProgress }
        if n.contains("ready") || n.contains("todo") || n.contains("to do") || n.contains("next") { return .ready }
        if n.contains("backlog") || n.contains("triage") || n.contains("icebox") || n.contains("new") { return .backlog }
        return nil
    }

    /// Pulls one GitHub project's items into a Raphael project. Issues reuse the same external
    /// id as issue sync (owner/repo#n), so the two adapters never create the same task twice.
    @discardableResult
    static func sync(githubProject id: String, into projectId: String) async -> String {
        let ws = WorkspaceStore.shared
        guard let gh = GitHubStore.gh else { return "gh CLI belum terpasang" }
        let q = """
        query($id: ID!) { node(id: $id) { ... on ProjectV2 { title items(first: 100) { nodes { id
          fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          content { __typename ... on Issue { number title state url repository { nameWithOwner } }
                    ... on PullRequest { number title state url repository { nameWithOwner } }
                    ... on DraftIssue { title } } } } } } }
        """
        let r = await NodeStore.runProcess(gh, ["api", "graphql", "-f", "query=\(q)", "-F", "id=\(id)"], timeout: 40)
        guard r.exitCode == 0, let j = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let node = (j["data"] as? [String: Any])?["node"] as? [String: Any] else {
            let msg = r.output.contains("scope") ? "Jalankan: gh auth refresh -s read:project" : String(r.output.prefix(200))
            ws.setSyncState("projectsV2:last:\(projectId)", "error|\(msg)")
            return msg
        }
        var created = 0, updated = 0
        for item in ((node["items"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []) {
            guard let itemId = item["id"] as? String, let content = item["content"] as? [String: Any] else { continue }
            let statusName = (item["fieldValueByName"] as? [String: Any])?["name"] as? String ?? ""
            let kind = content["__typename"] as? String ?? ""
            let title = content["title"] as? String ?? "(tanpa judul)"
            let ext: String, url: String, system: String
            if kind == "DraftIssue" { ext = itemId; url = ""; system = "github-project" }
            else {
                let repo = (content["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "?"
                ext = "\(repo)#\(content["number"] as? Int ?? 0)"; url = content["url"] as? String ?? ""; system = "github"
            }
            let mapped = statusMap(statusName) ?? ((content["state"] as? String) == "CLOSED" || (content["state"] as? String) == "MERGED" ? .done : nil)
            if let ref = ws.external(system: system, id: ext) {
                guard ref.entity == "task", var t = ws.tasks.first(where: { $0.id == ref.entityId }) else { continue }
                var changed = false
                if t.title != title { t.title = title; changed = true }
                if let m = mapped, ref.state != statusName, t.status != m { t.status = m; changed = true }   // only when GitHub's status changed
                if changed { ws.updateTask(t); updated += 1 }
                ws.upsertExternal(ExternalRef(id: ref.id, entity: "task", entityId: t.id, system: system, externalId: ext, url: url, state: statusName))
            } else if let t = ws.createTask(projectId: projectId, title: title, status: mapped ?? .backlog) {
                ws.upsertExternal(ExternalRef(id: WorkspaceStore.newID(), entity: "task", entityId: t.id, system: system, externalId: ext, url: url, state: statusName))
                created += 1
            }
        }
        let summary = "\(ISO8601DateFormatter().string(from: Date()))|+\(created)|~\(updated)"
        ws.setSyncState("projectsV2:last:\(projectId)", summary)
        return "Sinkron: \(created) baru, \(updated) diperbarui"
    }
}

// MARK: - Monitor transitions → activity

@MainActor
enum MonitorTransitions {
    /// Down / recovered events for resources linked to projects (state kept in sync_state).
    static func record() {
        let ws = WorkspaceStore.shared
        let previous: [String: String] = (ws.syncState("monitor:states").flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }) ?? [:]
        var now = previous
        var ev: [ActivityEvent] = []
        for p in ws.projects where p.lifecycle != .archived {
            for s in ProjectHealth.report(p.id).signals where s.health != .unknown && s.health != .stale {
                let key = "\(p.id)|\(s.kind.rawValue)|\(s.ref)"
                let state = s.health == .down ? "down" : s.health == .degraded ? "degraded" : "ok"
                if let old = previous[key], old != state {
                    let ts = Date()
                    let type = state == "down" ? (s.kind == .domain ? "site.down" : "service.down") : old == "down" && state == "ok" ? "service.recovered" : state == "degraded" ? "service.degraded" : "service.recovered"
                    ev.append(ActivityEvent(id: "monitor:\(key):\(state):\(Int(ts.timeIntervalSince1970))", projectId: p.id, type: type, ts: ts, source: "monitor",
                                            title: "\(s.label): \(state == "down" ? "tidak tersedia" : state == "degraded" ? "terganggu" : "pulih") · \(s.detail)", meta: ["resource": s.ref]))
                }
                now[key] = state
            }
        }
        if !ev.isEmpty { ws.record(ev) }
        if now != previous, let d = try? JSONEncoder().encode(now), let s = String(data: d, encoding: .utf8) { ws.setSyncState("monitor:states", s) }
    }
}
