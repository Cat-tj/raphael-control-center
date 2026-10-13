import SwiftUI

// MARK: - Development

struct DevelopmentTab: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @ObservedObject private var dev = DevStore.shared
    @State private var ghProjects: [GHProjectV2] = []
    @State private var ghProjectsError: String?
    @State private var syncing = false
    @State private var syncMessage: String?

    var body: some View {
        let repos = ws.links(of: projectId, .repo)
        VStack(alignment: .leading, spacing: 16) {
            if repos.isEmpty {
                RCard(padding: 18) {
                    EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: "Belum ada repository",
                                   message: "Tautkan satu atau lebih repo GitHub di tab Settings (owner/repo). Commit, issue, PR, CI dan release akan muncul di sini.")
                }
            }
            ForEach(repos) { l in repoCard(l.ref) }
            syncCard(repos)
        }
        .onAppear { for l in repos where dev.repo(l.ref)?.fetchedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true { dev.refresh(repo: l.ref) } }
    }

    private func repoCard(_ repo: String) -> some View {
        let d = dev.repo(repo)
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(RTheme.violet)
                    Button(repo) { NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)")!) }.buttonStyle(.link).font(.system(size: 14, weight: .bold))
                    if let d, !d.defaultBranch.isEmpty { RChip(text: d.defaultBranch, tint: RTheme.muted) }
                    if d?.isPrivate == true { RChip(text: "private", tint: RTheme.muted) }
                    Spacer()
                    if dev.loading.contains(repo.lowercased()) { ProgressView().controlSize(.mini) }
                    if let at = d?.fetchedAt { Text("diambil " + at.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                    Button { dev.refresh(repo: repo) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                }
                if let e = d?.error {
                    Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RTheme.amber)
                } else if let d, d.fetchedAt != nil {
                    let openIssues = d.issues.filter { !$0.isPR && $0.state == "open" }, closedIssues = d.issues.filter { !$0.isPR && $0.state == "closed" }
                    let openPRs = d.pulls.filter { $0.state == "open" }, merged = d.pulls.filter(\.merged)
                    let lastRun = d.runs.first { $0.status == "completed" }
                    HStack(spacing: 18) {
                        stat("Push terakhir", d.pushedAt?.ago ?? "–")
                        stat("Issue", "\(openIssues.count) terbuka · \(closedIssues.count) ditutup")
                        stat("PR", "\(openPRs.count) terbuka · \(merged.count) merged")
                        stat("CI terakhir", lastRun.map { ($0.conclusion ?? $0.status) + " · " + ($0.createdAt?.ago ?? "") } ?? "tidak ada Actions",
                             lastRun?.conclusion == "failure" ? RTheme.red : lastRun?.conclusion == "success" ? RTheme.green : RTheme.navy)
                        stat("Branch", "\(d.branches.count)")
                    }
                    HStack(alignment: .top, spacing: 14) {
                        list("Commit terbaru") {
                            ForEach(d.commits.prefix(8), id: \.sha) { c in
                                linkRow(String(c.sha.prefix(7)), c.message, c.date?.ago ?? "", c.url, mono: true)
                            }
                        }
                        list("Pull request") {
                            if d.pulls.isEmpty { empty("Belum ada PR") }
                            ForEach(d.pulls.prefix(8), id: \.number) { p in
                                linkRow("#\(p.number)", p.title, p.merged ? "merged" : p.state == "open" ? (p.draft ? "draft" : p.review ?? "open") : "closed", p.url,
                                        tint: p.merged ? RTheme.violet : p.review == "changes requested" ? RTheme.red : p.review == "approved" ? RTheme.green : RTheme.muted)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        list("Issue terbuka") {
                            if openIssues.isEmpty { empty("Tidak ada issue terbuka") }
                            ForEach(openIssues.prefix(8), id: \.number) { i in
                                let linked = ws.external(system: "github", id: "\(repo)#\(i.number)") != nil
                                linkRow("#\(i.number)", i.title, linked ? "task ✓" : (i.milestoneTitle ?? ""), i.url, tint: linked ? RTheme.green : RTheme.muted)
                            }
                        }
                        list("GitHub Actions") {
                            if d.runs.isEmpty { empty("Tidak ada workflow run") }
                            ForEach(d.runs.prefix(8), id: \.id) { r in
                                linkRow(r.conclusion == "success" ? "✓" : r.conclusion == "failure" ? "✗" : "•", "\(r.name) · \(r.branch)",
                                        r.createdAt?.ago ?? "", r.url, tint: r.conclusion == "failure" ? RTheme.red : r.conclusion == "success" ? RTheme.green : RTheme.amber)
                            }
                        }
                    }
                    if !d.releases.isEmpty || !d.milestones.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            list("Release") {
                                if d.releases.isEmpty { empty("Belum ada release") }
                                ForEach(d.releases.prefix(5), id: \.tag) { r in linkRow(r.tag, r.name, r.date?.ago ?? "", r.url) }
                            }
                            list("Milestone GitHub") {
                                if d.milestones.isEmpty { empty("Tidak ada milestone") }
                                ForEach(d.milestones.prefix(5), id: \.number) { m in
                                    linkRow(m.state == "open" ? "◇" : "◆", m.title, "\(m.closed)/\(m.open + m.closed)" + (m.due.map { " · " + WFormat.due($0) } ?? ""), m.url)
                                }
                            }
                        }
                    }
                } else {
                    Text("Memuat…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                }
            }
        }
    }

    private func syncCard(_ repos: [ResourceLink]) -> some View {
        let last = ws.syncState("issueSync:last:\(projectId)")?.components(separatedBy: "|")
        let ghLinks = ws.links(of: projectId, .githubProject)
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                RLabel(text: "Sinkronisasi (hanya membaca dari GitHub)")
                Toggle("Jadikan issue GitHub dari repo di atas sebagai task", isOn: Binding(get: { IssueSync.enabled(projectId) }, set: { IssueSync.setEnabled(projectId, $0) }))
                    .toggleStyle(.checkbox).disabled(repos.isEmpty)
                Text("Satu issue = satu task (dicatat dengan ID eksternal, jadi sync berulang tidak menduplikasi). Judul dan status buka/tutup mengikuti GitHub; field lain tetap milikmu. Task yang kamu hapus tidak dibuat ulang. Perubahan di Raphael tidak dikirim ke GitHub.")
                    .font(.system(size: 11)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let last, last.count >= 4 { Text("Terakhir: \(last[1]) · \(last[2]) baru · \(last[3]) diperbarui · \(ISO8601DateFormatter().date(from: last[0])?.ago ?? "")").font(.system(size: 11)).foregroundStyle(RTheme.ink2) }
                Divider().overlay(RTheme.line)
                HStack {
                    Text("GitHub Projects (v2)").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button("Muat daftar project") {
                        Task { let r = await ProjectsV2Sync.list(); ghProjects = r.0; ghProjectsError = r.1 }
                    }.buttonStyle(RPillButton())
                }
                if let e = ghProjectsError { Text(e).font(.system(size: 11.5)).foregroundStyle(RTheme.amber).textSelection(.enabled) }
                ForEach(ghLinks) { l in
                    HStack {
                        Image(systemName: "rectangle.split.3x1").foregroundStyle(RTheme.violet)
                        Text(l.label.isEmpty ? l.ref : l.label).font(.system(size: 12.5))
                        Spacer()
                        if let s = ws.syncState("projectsV2:last:\(projectId)") { Text(s.hasPrefix("error") ? s : "sync " + (ISO8601DateFormatter().date(from: s.components(separatedBy: "|")[0])?.ago ?? "")).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                        Button(syncing ? "Menyinkron…" : "Sinkron sekarang") {
                            syncing = true
                            Task { syncMessage = await ProjectsV2Sync.sync(githubProject: l.ref, into: projectId); syncing = false }
                        }
                        .buttonStyle(RPillButton(primary: true)).disabled(syncing)
                        Button { ws.removeLink(l.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(RTheme.red)
                    }
                }
                ForEach(ghProjects.filter { gp in !ghLinks.contains { $0.ref == gp.id } }) { gp in
                    HStack {
                        Text("\(gp.owner) / \(gp.title)").font(.system(size: 12))
                        Spacer()
                        Button("Tautkan ke project ini") { ws.addLink(projectId, kind: .githubProject, ref: gp.id, label: "\(gp.owner)/\(gp.title)") }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
                if let m = syncMessage { Text(m).font(.system(size: 11.5)).foregroundStyle(RTheme.green) }
                Text("Status kolom GitHub dipetakan ke Backlog/Ready/In Progress/Review/Done menurut namanya. Sinkronisasi dua arah belum diaktifkan.")
                    .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            }
        }
    }

    private func stat(_ k: String, _ v: String, _ c: Color = RTheme.navy) -> some View {
        VStack(alignment: .leading, spacing: 2) { RLabel(text: k); Text(v).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(c).lineLimit(1) }
    }
    private func list<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { RLabel(text: title); c() }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func empty(_ t: String) -> some View { Text(t).font(.system(size: 11.5)).foregroundStyle(RTheme.muted) }
    private func linkRow(_ tag: String, _ title: String, _ trailing: String, _ url: String, mono: Bool = false, tint: Color = RTheme.muted) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 6) {
                Text(tag).font(.system(size: 10.5, design: mono ? .monospaced : .default)).foregroundStyle(tint).frame(minWidth: 26, alignment: .leading)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(trailing).font(.system(size: 10.5)).foregroundStyle(tint).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Deployments

struct DeploymentsTab: View {
    let projectId: String
    @ObservedObject private var ws = WorkspaceStore.shared
    @ObservedObject private var dev = DevStore.shared
    @ObservedObject private var mon = MonitorStore.shared

    var body: some View {
        let vercel = ws.links(of: projectId, .vercel)
        let servers = ws.links(of: projectId).filter { [.app, .compose, .service].contains($0.kind) }
        VStack(alignment: .leading, spacing: 16) {
            environments
            if vercel.isEmpty && servers.isEmpty {
                RCard(padding: 18) {
                    EmptyStateView(icon: "shippingbox", title: "Belum ada deployment",
                                   message: "Tautkan project Vercel atau aplikasi server (Docker/service dari Monitor) di Settings.")
                }
            }
            ForEach(vercel) { l in
                RCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "triangle.fill").foregroundStyle(RTheme.navy)
                            Text(VercelStore.shared.projects.first { $0.id == l.ref }?.name ?? l.label).font(.system(size: 14, weight: .bold))
                            Spacer()
                            Button { dev.refreshDeployments(l.ref) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                        }
                        if let e = dev.deployErrors[l.ref] { Text(e).font(.system(size: 12)).foregroundStyle(RTheme.amber) }
                        let list = dev.deployments[l.ref] ?? []
                        if list.isEmpty && dev.deployErrors[l.ref] == nil { Text("Memuat…").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                        ForEach(list.prefix(12), id: \.uid) { d in
                            HStack(spacing: 10) {
                                RStatusDot(color: d.state == "READY" ? RTheme.green : d.state == "ERROR" ? RTheme.red : RTheme.amber, size: 7)
                                Text(d.state.capitalized).font(.system(size: 11.5, weight: .semibold)).frame(width: 74, alignment: .leading)
                                RChip(text: d.target, tint: d.target == "production" ? RTheme.violet : RTheme.muted)
                                Text(d.commit ?? d.url).font(.system(size: 12)).lineLimit(1)
                                if let b = d.branch { Text(b).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted) }
                                Spacer()
                                if let c = d.createdAt, let r = d.readyAt { Text("\(Int(r.timeIntervalSince(c)))s build").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                                Text(d.createdAt?.ago ?? "").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                                Button { NSWorkspace.shared.open(URL(string: d.url)!) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                            }
                        }
                    }
                }
                .onAppear { if dev.deployments[l.ref] == nil { dev.refreshDeployments(l.ref) } }
            }
            if !servers.isEmpty {
                RCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        RLabel(text: "Deployment server (dari Monitor)")
                        ForEach(servers) { l in
                            let app = mon.apps.first { $0.id == l.ref }
                            HStack(spacing: 10) {
                                Image(systemName: l.kind.icon).foregroundStyle(RTheme.violet).frame(width: 16)
                                Text(app?.name ?? l.label).font(.system(size: 12.5, weight: .semibold))
                                if !l.environment.isEmpty { RChip(text: l.environment, tint: RTheme.muted) }
                                Text(serverDetail(l, app)).font(.system(size: 11.5)).foregroundStyle(RTheme.muted).lineLimit(1)
                                Spacer()
                            }
                        }
                        Text("Server tidak mencatat riwayat deploy; yang tampil adalah status container/service saat ini (uptime sejak start).")
                            .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                    }
                }
            }
        }
    }

    private func serverDetail(_ l: ResourceLink, _ app: MApp?) -> String {
        guard let app, let node = app.node, let d = mon.detail[node] else { return "belum ada data" }
        let cs = d.containers.filter { app.containers.contains($0.name) }
        if !cs.isEmpty { return cs.map { "\($0.name): \($0.status)" }.joined(separator: " · ") }
        let ss = d.services.filter { app.services.contains($0.unit) }
        return ss.map { "\($0.unit): \($0.state)" }.joined(separator: " · ")
    }

    private var environments: some View {
        let ls = ws.links(of: projectId).filter { !$0.environment.isEmpty }
        let envs = Array(Set(ls.map(\.environment))).sorted { ["production", "staging", "development"].firstIndex(of: $0) ?? 9 < ["production", "staging", "development"].firstIndex(of: $1) ?? 9 }
        return Group {
            if !envs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(envs, id: \.self) { env in
                        let items = ls.filter { $0.environment == env }
                        let report = ProjectHealth.report(projectId)
                        let hs = report.signals.filter { s in items.contains { $0.kind == s.kind && $0.ref == s.ref } }.map(\.health)
                        RCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(env.capitalized).font(.system(size: 13, weight: .bold)); Spacer(); if !hs.isEmpty { HealthBadge(health: ProjectHealth.aggregate(hs)) } }
                                ForEach(items) { l in Label(l.label.isEmpty ? l.ref : l.label, systemImage: l.kind.icon).font(.system(size: 11.5)).foregroundStyle(RTheme.ink2).lineLimit(1) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Monitoring

struct MonitoringTab: View {
    let projectId: String
    @ObservedObject private var mon = MonitorStore.shared
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var openApp: MApp?
    @State private var range = 3600.0

    var body: some View {
        let r = ProjectHealth.report(projectId)
        let apps = ws.links(of: projectId, .app).compactMap { l in mon.apps.first { $0.id == l.ref } }
        VStack(alignment: .leading, spacing: 16) {
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        RLabel(text: "Kesehatan operasional")
                        HealthBadge(health: r.ops)
                        Spacer()
                        Text(r.lastCollected.map { "data terakhir " + $0.ago } ?? "belum ada data").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                    }
                    if !r.hasOperationalResources {
                        Text("Tidak ada resource operasional tertaut. Status \"Belum diketahui\" bukan berarti sehat. Tautkan domain, server atau aplikasi di Settings.")
                            .font(.system(size: 12)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(r.signals) { s in
                        HStack(spacing: 10) {
                            Image(systemName: s.health.icon).foregroundStyle(s.health.color).frame(width: 16)
                            Image(systemName: s.kind.icon).foregroundStyle(RTheme.muted).frame(width: 16)
                            Text(s.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).frame(width: 200, alignment: .leading)
                            Text(s.detail).font(.system(size: 12)).foregroundStyle(RTheme.ink2).lineLimit(1)
                            Spacer()
                            Text(s.health.title).font(.system(size: 11)).foregroundStyle(s.health.color)
                            Text(s.collectedAt?.ago ?? "–").font(.system(size: 10.5)).foregroundStyle(RTheme.muted).frame(width: 100, alignment: .trailing)
                        }
                    }
                    Text("Sehat = semua resource sehat dan datanya < 10 menit. Data lebih lama = \"Data usang\"; tanpa data = \"Belum diketahui\".")
                        .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                }
            }
            if !apps.isEmpty {
                RLabel(text: "Aplikasi tertaut")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(apps) { a in AppCard(app: a, status: mon.appStatus[a.id] ?? MAppStatus()) { openApp = a } }
                }
            }
            let incidents = ws.events(project: projectId, types: ["site.down", "service.down", "service.degraded", "service.recovered", "deploy.failed", "ci.failed"]).prefix(10)
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    RLabel(text: "Insiden terbaru")
                    if incidents.isEmpty { Text("Tidak ada insiden tercatat.").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                    ForEach(Array(incidents)) { ActivityRow(event: $0, showProject: false) }
                }
            }
        }
        .sheet(item: $openApp) { AppDetailSheet(app: $0, range: $range) }
    }
}

// MARK: - Activity

struct ActivityPage: View {
    let projectId: String?
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var group = "all"
    @State private var days = 30
    @State private var project = ""

    @ViewBuilder private func activityFilters(_ all: Bool) -> some View {
        Picker("", selection: $group) { ForEach(Self.groups, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
        Picker("", selection: $days) { Text("7 hari").tag(7); Text("30 hari").tag(30); Text("90 hari").tag(90); Text("1 tahun").tag(365) }.labelsHidden().fixedSize()
        if projectId == nil {
            Picker("", selection: $project) { Text("Semua project").tag(""); ForEach(ws.projects) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
        }
    }

    private func activityMeta(_ n: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(n) kejadian").font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize()
            Button { DevStore.shared.refreshLinked() } label: { Label("Sinkron", systemImage: "arrow.clockwise") }.buttonStyle(RPillButton()).fixedSize()
        }
    }

    static let groups: [(String, String, Set<String>?)] = [
        ("all", "Semua", nil),
        ("tasks", "Task", ["task.created", "task.status", "task.completed", "task.blocked", "task.unblocked", "task.archived", "milestone.completed", "project.created", "project.lifecycle"]),
        ("code", "Kode", ["github.commit", "issue.opened", "issue.closed", "pr.opened", "pr.merged", "release.published"]),
        ("ci", "CI & deploy", ["ci.passed", "ci.failed", "deploy.started", "deploy.completed", "deploy.failed", "deploy.canceled"]),
        ("ops", "Operasional", ["site.down", "service.down", "service.degraded", "service.recovered"]),
        ("agents", "Agent", ["agent.session"]),
    ]

    var body: some View {
        let types = Self.groups.first { $0.0 == group }?.2
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        let pid = projectId ?? (project.isEmpty ? nil : project)
        let list = ws.events(project: pid, types: types, since: since)
        VStack(alignment: .leading, spacing: 14) {
            if projectId == nil { RPageTitle(title: "Activity", subtitle: "Semua kejadian dari task, GitHub, CI/deploy, Monitor dan agent, berurutan") }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { activityFilters(pid == nil); Spacer(); activityMeta(list.count) }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { activityFilters(pid == nil) }; activityMeta(list.count) }
            }
            .font(.system(size: 12))
            RCard(padding: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        EmptyStateView(icon: "clock.arrow.circlepath", title: "Belum ada aktivitas",
                                       message: "Aktivitas muncul saat task berubah, dan dari repo/Vercel/aplikasi yang ditautkan ke project.")
                    }
                    let byDay = Dictionary(grouping: list.prefix(400)) { Calendar.current.startOfDay(for: $0.ts) }
                    ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                        Text(day.formatted(date: .complete, time: .omitted)).font(.system(size: 11, weight: .semibold)).foregroundStyle(RTheme.muted)
                            .padding(.top, 10).padding(.bottom, 4)
                        ForEach(byDay[day]!.sorted { $0.ts > $1.ts }) { e in ActivityRow(event: e, showProject: pid == nil).padding(.vertical, 3) }
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    var showProject = true
    @ObservedObject private var ws = WorkspaceStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.icon(event.type)).font(.system(size: 11)).foregroundStyle(Self.color(event.type)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12.5)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(event.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(RTheme.muted)
                    if showProject, let p = ws.projects.first(where: { $0.id == event.projectId }) {
                        Button(p.name) { WorkspaceNav.open(project: p.id, tab: "Activity") }.buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
            }
            Spacer()
            Text(event.ts.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            if !event.url.isEmpty, let u = URL(string: event.url) {
                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).foregroundStyle(RTheme.muted).help("Buka di sumbernya")
            }
        }
    }

    static func icon(_ t: String) -> String {
        switch t {
        case "task.created": "plus.circle"
        case "task.completed", "milestone.completed": "checkmark.circle.fill"
        case "task.status": "arrow.right.circle"
        case "task.blocked": "hand.raised.fill"
        case "github.commit": "point.topleft.down.to.point.bottomright.curvepath"
        case "issue.opened", "issue.closed": "smallcircle.filled.circle"
        case "pr.opened", "pr.merged": "arrow.triangle.pull"
        case "ci.passed": "checkmark.seal.fill"
        case "ci.failed": "xmark.seal.fill"
        case "deploy.completed", "deploy.started": "shippingbox"
        case "deploy.failed": "shippingbox.and.arrow.backward"
        case "release.published": "tag"
        case "site.down", "service.down": "bolt.horizontal.circle.fill"
        case "service.recovered": "heart.circle.fill"
        case "agent.session": "sparkles"
        case "project.lifecycle", "project.created": "folder"
        default: "circle"
        }
    }
    static func color(_ t: String) -> Color {
        switch t {
        case "ci.failed", "deploy.failed", "site.down", "service.down": RTheme.red
        case "task.completed", "ci.passed", "deploy.completed", "service.recovered", "milestone.completed", "pr.merged": RTheme.green
        case "task.blocked", "service.degraded": RTheme.amber
        case "agent.session": RTheme.orchid
        default: RTheme.violet
        }
    }
}

// MARK: - Agent sessions

struct AgentSessionsCard: View {
    let projectId: String
    var limit = 10
    @ObservedObject private var agents = AgentActivity.shared

    var body: some View {
        let list = agents.sessions(for: projectId)
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RLabel(text: "Sesi agent (Hermes, Codex)")
                    Spacer()
                    if let at = agents.loadedAt { Text("dibaca " + at.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                    Button { Task { await agents.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
                }
                if list.isEmpty {
                    Text(agents.loadedAt == nil ? "Membaca sesi…" : "Tidak ada sesi agent yang bekerja di folder/repo project ini (60 hari terakhir). Sesi dikaitkan lewat folder lokal & repo yang ditautkan.")
                        .font(.system(size: 12)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(list.prefix(limit)) { s in
                    HStack(spacing: 10) {
                        RStatusDot(color: s.active ? RTheme.green : RTheme.muted, size: 7)
                        Text(s.agent).font(.system(size: 11, weight: .semibold)).frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.system(size: 12.5)).lineLimit(1)
                            Text([s.runtime, s.model, s.branch.map { "⎇ \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1)
                        }
                        Spacer()
                        if let t = s.tokens { Text("\(t.compact) tok").font(.system(size: 11, design: .monospaced)) }
                        if let c = s.costUSD, c > 0 { Text(c.usd).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted) }
                        if let d = s.duration { Text(MonitorPage.duration(d)).font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 60, alignment: .trailing) }
                        Text(s.active ? "aktif" : (s.lastActivity ?? s.startedAt)?.ago ?? "").font(.system(size: 10.5)).foregroundStyle(s.active ? RTheme.green : RTheme.muted).frame(width: 100, alignment: .trailing)
                    }
                }
            }
        }
        .task { if agents.loadedAt == nil { await agents.refresh() } }
    }
}
