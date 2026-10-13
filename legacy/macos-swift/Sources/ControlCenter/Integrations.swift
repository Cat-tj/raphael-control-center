import Foundation

// MARK: - Vercel

struct VProject: Identifiable, Hashable {
    let id: String
    let name: String
    let team: String?
    let teamSlug: String?
    let framework: String?
    let repo: String?                 // "owner/name" when linked to GitHub
    let state: String?                // READY, ERROR, BUILDING, QUEUED, CANCELED
    let deployedAt: Date?
    let url: String?
    let domains: [String]
    let commit: String?
    let branch: String?
    var dashboardURL: String { "https://vercel.com/\(teamSlug ?? "dashboard")/\(name)" }
}

/// Vercel projects and their production deployment. Token: Keychain "vercel-token"
/// (vercel.com/account/tokens); every team the token can see is included.
@MainActor
final class VercelStore: ObservableObject {
    static let shared = VercelStore()
    enum State: Equatable { case idle, loading, ok, noToken, error(String) }
    @Published private(set) var projects: [VProject] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var loadedAt: Date?
    static let keychainKey = "vercel-token"

    var hasToken: Bool { !(KeychainStore.shared.get(Self.keychainKey) ?? "").isEmpty }

    func setToken(_ t: String) {
        KeychainStore.shared.set(Self.keychainKey, value: t.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh()
    }

    func refresh() {
        guard state != .loading else { return }
        guard let token = KeychainStore.shared.get(Self.keychainKey), !token.isEmpty else { state = .noToken; return }
        state = .loading
        Task {
            do { projects = try await Self.load(token); state = .ok; loadedAt = Date() }
            catch { state = .error(error.localizedDescription) }
        }
    }

    private static func get(_ token: String, _ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.vercel.com" + path)!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
            let msg = (j["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            throw NSError(domain: "Vercel", code: code, userInfo: [NSLocalizedDescriptionKey: "Vercel: \(msg)"])
        }
        return j
    }

    static func load(_ token: String) async throws -> [VProject] {
        let teams = (try? await get(token, "/v2/teams?limit=50"))?["teams"] as? [[String: Any]] ?? []
        var scopes: [(id: String?, slug: String?)] = [(nil, nil)]
        scopes += teams.compactMap { t in (t["id"] as? String).map { ($0, t["slug"] as? String) } }
        var out: [VProject] = []
        for scope in scopes {
            guard let j = try? await get(token, "/v9/projects?limit=100" + (scope.id.map { "&teamId=\($0)" } ?? "")) else { continue }
            for p in j["projects"] as? [[String: Any]] ?? [] {
                let prod = (p["targets"] as? [String: Any])?["production"] as? [String: Any]
                let link = p["link"] as? [String: Any]
                let meta = prod?["meta"] as? [String: Any]
                let repo = (link?["org"] as? String).flatMap { org in (link?["repo"] as? String).map { "\(org)/\($0)" } }
                out.append(VProject(id: p["id"] as? String ?? UUID().uuidString, name: p["name"] as? String ?? "?", team: scope.id, teamSlug: scope.slug,
                                    framework: p["framework"] as? String, repo: repo, state: prod?["readyState"] as? String,
                                    deployedAt: (prod?["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                                    url: (prod?["url"] as? String).map { "https://" + $0 },
                                    domains: (prod?["alias"] as? [String] ?? []).filter { !$0.hasSuffix(".vercel.app") || ($0.components(separatedBy: "-").count < 3) },
                                    commit: meta?["githubCommitMessage"] as? String, branch: meta?["githubCommitRef"] as? String))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - GitHub (through the gh CLI login on this Mac)

struct GHRepo: Identifiable, Hashable {
    var id: String { full }
    let full: String
    let url: String
    let isPrivate: Bool
    let pushedAt: Date?
    let branch: String
    let openIssues: Int
    var ci: String?                    // success, failure, in_progress, …
    var ciName: String?
    var ciAt: Date?
    var ciURL: String?
}

@MainActor
final class GitHubStore: ObservableObject {
    static let shared = GitHubStore()
    enum State: Equatable { case idle, loading, ok, noCLI, error(String) }
    @Published private(set) var repos: [GHRepo] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var loadedAt: Date?

    nonisolated static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard state != .loading else { return }
        guard let gh = Self.gh else { state = .noCLI; return }
        state = .loading
        Task {
            let r = await NodeStore.runProcess(gh, ["api", "user/repos?sort=pushed&per_page=40&affiliation=owner,collaborator,organization_member"], timeout: 30)
            guard r.exitCode == 0, let arr = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [[String: Any]] else {
                state = .error(String(r.output.suffix(200))); return
            }
            let iso = ISO8601DateFormatter()
            var list = arr.map { a in
                GHRepo(full: a["full_name"] as? String ?? "?", url: a["html_url"] as? String ?? "", isPrivate: a["private"] as? Bool ?? false,
                       pushedAt: (a["pushed_at"] as? String).flatMap(iso.date), branch: a["default_branch"] as? String ?? "main",
                       openIssues: (a["open_issues_count"] as? NSNumber)?.intValue ?? 0)
            }
            // Latest Actions run of the most recently pushed repos.
            await withTaskGroup(of: (Int, [String: Any]?).self) { g in
                for (i, repo) in list.prefix(20).enumerated() {
                    g.addTask {
                        let r = await NodeStore.runProcess(gh, ["api", "repos/\(repo.full)/actions/runs?per_page=1"], timeout: 20)
                        let j = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
                        return (i, (j?["workflow_runs"] as? [[String: Any]])?.first)
                    }
                }
                for await (i, run) in g {
                    guard let run else { continue }
                    let status = run["status"] as? String
                    list[i].ci = status == "completed" ? (run["conclusion"] as? String) : status
                    list[i].ciName = run["name"] as? String
                    list[i].ciAt = (run["created_at"] as? String).flatMap(iso.date)
                    list[i].ciURL = run["html_url"] as? String
                }
            }
            repos = list
            state = .ok
            loadedAt = Date()
        }
    }

    func repo(_ full: String?) -> GHRepo? {
        guard let full else { return nil }
        return repos.first { $0.full.lowercased() == full.lowercased() }
    }
}

// MARK: - Local projects (this Mac)

struct LocalProject: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let kind: String              // node, swift, python, rust, go, flutter, static, folder
    let branch: String?
    let dirty: Int
    let lastCommit: Date?
    let lastSubject: String?
    let repo: String?             // owner/name from the GitHub remote
    let ports: [Int]              // dev servers listening from inside the folder
    let processes: [String]
    var running: Bool { !ports.isEmpty || !processes.isEmpty }
}

@MainActor
final class LocalProjectsStore: ObservableObject {
    static let shared = LocalProjectsStore()
    @Published private(set) var projects: [LocalProject] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedAt: Date?

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let r = await NodeStore.runProcess("/usr/bin/python3", ["-I", "-c", Self.script, NSHomeDirectory() + "/Projects"], timeout: 60)
            loading = false
            guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
                  let arr = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return }
            projects = arr.map { p in
                LocalProject(name: p["name"] as? String ?? "?", path: p["path"] as? String ?? "", kind: p["kind"] as? String ?? "folder",
                             branch: p["branch"] as? String, dirty: (p["dirty"] as? NSNumber)?.intValue ?? 0,
                             lastCommit: (p["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                             lastSubject: p["subject"] as? String, repo: p["repo"] as? String,
                             ports: (p["ports"] as? [NSNumber])?.map(\.intValue) ?? [], processes: p["procs"] as? [String] ?? [])
            }
            loadedAt = Date()
        }
    }

    /// git state of every ~/Projects folder + which listening processes run from inside it.
    static let script = #"""
import json, os, re, subprocess, sys
root = sys.argv[1]
def sh(a, cwd=None, t=6):
    try: return subprocess.run(a, cwd=cwd, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""
# listening pids -> ports, then their working directories
pids = {}
cur = None
for l in sh(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], t=10).splitlines():
    if l.startswith("p"): cur = l[1:]; pids.setdefault(cur, {"ports": set(), "cmd": ""})
    elif l.startswith("c") and cur: pids[cur]["cmd"] = l[1:]
    elif l.startswith("n") and cur:
        m = re.search(r":(\d+)$", l)
        if m: pids[cur]["ports"].add(int(m.group(1)))
cwd = {}
if pids:
    cur = None
    for l in sh(["/usr/sbin/lsof", "-a", "-d", "cwd", "-p", ",".join(pids), "-Fpn"], t=10).splitlines():
        if l.startswith("p"): cur = l[1:]
        elif l.startswith("n") and cur: cwd[cur] = l[1:]
out = []
for name in sorted(os.listdir(root)):
    p = os.path.join(root, name)
    if name.startswith(".") or not os.path.isdir(p): continue
    f = set(os.listdir(p))
    kind = ("node" if "package.json" in f else "swift" if ("Package.swift" in f or any(x.endswith(".xcodeproj") for x in f) or "project.yml" in f)
            else "flutter" if "pubspec.yaml" in f else "python" if f & {"pyproject.toml", "requirements.txt", "setup.py"}
            else "rust" if "Cargo.toml" in f else "go" if "go.mod" in f else "static" if "index.html" in f else "folder")
    d = {"name": name, "path": p, "kind": kind, "dirty": 0, "ports": [], "procs": []}
    if os.path.isdir(os.path.join(p, ".git")):
        d["branch"] = sh(["git", "rev-parse", "--abbrev-ref", "HEAD"], p).strip() or None
        d["dirty"] = len([l for l in sh(["git", "status", "--porcelain"], p).splitlines() if l.strip()])
        log = sh(["git", "log", "-1", "--format=%ct|%s"], p).strip()
        if "|" in log: d["ts"], d["subject"] = int(log.split("|", 1)[0]), log.split("|", 1)[1][:120]
        m = re.search(r"github\.com[:/]([^/]+/[^/\s]+?)(?:\.git)?$", sh(["git", "remote", "get-url", "origin"], p).strip())
        if m: d["repo"] = m.group(1)
    for pid, info in pids.items():
        c = cwd.get(pid, "")
        if c == p or c.startswith(p + "/"):
            d["ports"] += sorted(info["ports"]); d["procs"].append(info["cmd"])
    d["ports"] = sorted(set(d["ports"])); d["procs"] = sorted(set(d["procs"]))
    out.append(d)
print(json.dumps(out))
"""#
}

// MARK: - n8n

struct N8nInstance: Identifiable, Codable, Hashable { var id: String; var name: String; var url: String }
struct N8nWorkflow: Identifiable, Hashable { let id: String; let name: String; let active: Bool; let updatedAt: Date?; var errors: Int = 0; var lastError: Date? }

/// n8n instances (self-hosted or n8n Cloud) added by hand: URL + API key (Keychain "n8n-key-<id>").
@MainActor
final class N8nStore: ObservableObject {
    static let shared = N8nStore()
    @Published var instances: [N8nInstance] = []
    @Published private(set) var workflows: [String: [N8nWorkflow]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    static var configURL: URL { NodeStore.supportDir.appendingPathComponent("n8n.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.configURL), let s = try? JSONDecoder().decode([N8nInstance].self, from: d) { instances = s }
    }

    func add(name: String, url: String, key: String) {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http") { u = "https://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        let inst = N8nInstance(id: UUID().uuidString.prefix(8).lowercased(), name: name.isEmpty ? (URL(string: u)?.host ?? u) : name, url: u)
        instances.append(inst)
        KeychainStore.shared.set("n8n-key-\(inst.id)", value: key.trimmingCharacters(in: .whitespacesAndNewlines))
        save(); refresh(inst)
    }

    func remove(_ inst: N8nInstance) {
        instances.removeAll { $0.id == inst.id }; KeychainStore.shared.remove("n8n-key-\(inst.id)"); workflows[inst.id] = nil; save()
    }

    private func save() { try? JSONEncoder().encode(instances).write(to: Self.configURL, options: .atomic) }

    func refreshAll() { instances.forEach(refresh) }

    func refresh(_ inst: N8nInstance) {
        let key = KeychainStore.shared.get("n8n-key-\(inst.id)") ?? ""
        Task {
            func get(_ path: String) async throws -> [String: Any] {
                var req = URLRequest(url: URL(string: inst.url + path)!, timeoutInterval: 20)
                req.setValue(key, forHTTPHeaderField: "X-N8N-API-KEY")
                let (data, resp) = try await SiteStore.session.data(for: req)
                if let c = (resp as? HTTPURLResponse)?.statusCode, c >= 400 { throw NSError(domain: "n8n", code: c, userInfo: [NSLocalizedDescriptionKey: "n8n: HTTP \(c)"]) }
                return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            do {
                let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let wf = try await get("/api/v1/workflows?limit=250")
                var list = (wf["data"] as? [[String: Any]] ?? []).map { w in
                    N8nWorkflow(id: "\(w["id"] ?? "")", name: w["name"] as? String ?? "?", active: w["active"] as? Bool ?? false,
                                updatedAt: (w["updatedAt"] as? String).flatMap(iso.date))
                }
                let ex = (try? await get("/api/v1/executions?status=error&limit=100")) ?? [:]
                for e in ex["data"] as? [[String: Any]] ?? [] {
                    let wid = "\(e["workflowId"] ?? "")"
                    guard let i = list.firstIndex(where: { $0.id == wid }) else { continue }
                    let at = (e["startedAt"] as? String).flatMap(iso.date)
                    if let at, Date().timeIntervalSince(at) < 86400 { list[i].errors += 1 }
                    if list[i].lastError == nil { list[i].lastError = at }
                }
                workflows[inst.id] = list.sorted { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }
                errors[inst.id] = nil
            } catch {
                errors[inst.id] = error.localizedDescription
            }
        }
    }
}
