import SwiftUI
import Charts

/// The first screen: which projects need attention, what to do next, then the facts.
struct OverviewPage: View {
    @ObservedObject private var ws = WorkspaceStore.shared
    @ObservedObject private var mon = MonitorStore.shared
    @ObservedObject private var dev = DevStore.shared
    @State private var discovery = false
    @State private var newProject = false

    struct Attention: Identifiable { let id: String; let project: Project; let reasons: [(String, Color)]; let action: String; let tab: String; let score: Int }

    var body: some View {
        let insights = WorkspaceInsights.compute(ws)
        let attention = attentionList()
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "Overview", subtitle: greeting(attention.count))
                Spacer()
                Button { discovery = true } label: { Label("Temukan project", systemImage: "sparkle.magnifyingglass") }.buttonStyle(RPillButton())
                Button { newProject = true } label: { Label("Project baru", systemImage: "plus") }.buttonStyle(RPillButton(primary: true))
            }
            if ws.projects.isEmpty {
                RCard(padding: 22) {
                    EmptyStateView(icon: "sparkles", title: "Mulai dengan project",
                                   message: "Raphael menyatukan task, roadmap, repo, deployment dan kesehatan server per project. Temukan project dari ~/Projects, GitHub, Vercel dan Monitor, atau buat sendiri. Angka di halaman ini baru muncul setelah ada data nyata.",
                                   action: ("Temukan project", { discovery = true }), secondary: ("Project baru", { newProject = true }))
                }
            } else {
                kpis(insights)
                HStack(alignment: .top, spacing: 14) {
                    attentionCard(attention).frame(maxWidth: .infinity)
                    myNext.frame(width: 380)
                }
                HStack(alignment: .top, spacing: 14) {
                    throughput(insights).frame(maxWidth: .infinity)
                    delivery(insights).frame(width: 380)
                }
                HStack(alignment: .top, spacing: 14) {
                    RCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { RLabel(text: "Aktivitas terbaru"); Spacer()
                                Button("Semua") { UserDefaults.standard.set(CCSection.activity.rawValue, forKey: "raphaelCCSection") }.buttonStyle(.link).font(.system(size: 11.5)) }
                            let ev = ws.activity.prefix(10)
                            if ev.isEmpty { Text("Belum ada aktivitas.").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                            ForEach(Array(ev)) { ActivityRow(event: $0).padding(.vertical, 2) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    opsCard.frame(width: 380)
                }
            }
        }
        .sheet(isPresented: $discovery) { DiscoverySheet() }
        .sheet(isPresented: $newProject) { ProjectEditor(project: nil) }
    }

    private func greeting(_ n: Int) -> String {
        ws.projects.isEmpty ? "Belum ada project" : n == 0 ? "Tidak ada project yang butuh perhatian" : "\(n) project perlu perhatian"
    }

    // MARK: KPIs

    private func kpis(_ i: WorkspaceInsights) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            kpi("Project aktif", "\(i.activeProjects)", "tidak paused", RTheme.navy)
            kpi("Task terbuka", "\(i.openTasks)", "\(i.wip) sedang dikerjakan", RTheme.navy)
            kpi("Lewat tenggat", "\(i.overdueTasks)", "task belum selesai", i.overdueTasks > 0 ? RTheme.red : RTheme.green)
            kpi("Terblokir", "\(i.blockedTasks)", "flag / dependensi", i.blockedTasks > 0 ? RTheme.amber : RTheme.green)
            kpi("Milestone berisiko", "\(i.milestonesAtRisk)", "lewat atau mepet", i.milestonesAtRisk > 0 ? RTheme.red : RTheme.green)
            kpi("Siklus rata-rata", i.avgCycleDays.map { String(format: "%.1f hari", $0) } ?? "–",
                i.avgCycleDays == nil ? "belum ada data" : "\(i.cycleSample) task, 90 hari", RTheme.navy)
        }
    }

    private func kpi(_ k: String, _ v: String, _ note: String, _ tint: Color) -> some View {
        RCard(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                RLabel(text: k)
                Text(v).font(.system(size: 22, weight: .heavy)).foregroundStyle(tint == RTheme.red || tint == RTheme.amber ? tint : RTheme.navy).lineLimit(1).minimumScaleFactor(0.7)
                Text(note).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1)
            }
        }
    }

    // MARK: Attention

    private func attentionList() -> [Attention] {
        var out: [Attention] = []
        for p in ws.projects where p.lifecycle != .archived && !p.paused {
            var reasons: [(String, Color)] = []
            var action = "", tab = "Overview", score = 0
            let ts = ws.tasks(of: p.id).filter { $0.status != .done }
            let overdue = ts.filter { $0.isOverdue() }.count
            let blocked = ts.filter { $0.blocked || !ws.blockers(of: $0.id).isEmpty }.count
            let risk = ws.milestones.filter { $0.projectId == p.id && ws.milestoneAtRisk($0) }
            let health = ProjectHealth.report(p.id)
            let ciFail = ws.links(of: p.id, .repo).compactMap { dev.repo($0.ref)?.runs.first { $0.status == "completed" } }.filter { $0.conclusion == "failure" }
            if health.ops == .down || health.ops == .degraded {
                let worst = health.signals.first { $0.health == health.ops }
                reasons.append(("\(health.ops.title): \(worst.map { "\($0.label) · \($0.detail)" } ?? "")", health.ops.color))
                action = "Cek \(worst?.label ?? "resource") di Monitoring"; tab = "Monitoring"; score += health.ops == .down ? 50 : 25
            }
            if !ciFail.isEmpty { reasons.append(("CI gagal: \(ciFail.map(\.name).joined(separator: ", "))", RTheme.red)); if action.isEmpty { action = "Perbaiki build yang gagal"; tab = "Development" }; score += 20 }
            if !risk.isEmpty {
                reasons.append(("Milestone berisiko: \(risk.map(\.title).joined(separator: ", "))", RTheme.red))
                if action.isEmpty { action = "Tinjau cakupan atau tanggal milestone"; tab = "Roadmap" }; score += 15 * risk.count
            }
            if overdue > 0 { reasons.append(("\(overdue) task lewat tenggat", RTheme.red)); if action.isEmpty { action = "Selesaikan atau jadwal ulang task yang lewat"; tab = "Tasks" }; score += 5 * overdue }
            if blocked > 0 { reasons.append(("\(blocked) task terblokir", RTheme.amber)); if action.isEmpty { action = "Lepaskan blokir"; tab = "Board" }; score += 4 * blocked }
            if health.ops == .stale { reasons.append(("Data monitoring usang", RTheme.blue)); score += 2 }
            if let t = p.targetDate, t < Date(), [.idea, .planned, .building].contains(p.lifecycle) {
                reasons.append(("Target project lewat (\(WFormat.date(t)))", RTheme.amber)); if action.isEmpty { action = "Perbarui target atau lifecycle"; tab = "Settings" }; score += 6
            }
            if !reasons.isEmpty { out.append(Attention(id: p.id, project: p, reasons: reasons, action: action, tab: tab, score: score)) }
        }
        return out.sorted { $0.score > $1.score }
    }

    private func attentionCard(_ list: [Attention]) -> some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                RLabel(text: "Perlu perhatian & langkah berikutnya")
                if list.isEmpty {
                    Label("Tidak ada yang mendesak: tidak ada task lewat tenggat, blokir, milestone berisiko, CI gagal atau resource down.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12.5)).foregroundStyle(RTheme.green).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(list.prefix(8)) { a in
                    Button { WorkspaceNav.open(project: a.project.id, tab: a.tab) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(a.project.name).font(.system(size: 13.5, weight: .bold))
                                    LifecycleBadge(lifecycle: a.project.lifecycle)
                                }
                                ForEach(Array(a.reasons.prefix(3).enumerated()), id: \.offset) { _, r in
                                    HStack(spacing: 6) { Circle().fill(r.1).frame(width: 6, height: 6); Text(r.0).font(.system(size: 12)).foregroundStyle(RTheme.ink2).lineLimit(1) }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Berikutnya").font(.system(size: 10)).foregroundStyle(RTheme.muted)
                                Text(a.action).font(.system(size: 12, weight: .semibold)).foregroundStyle(RTheme.violet).multilineTextAlignment(.trailing)
                            }
                            .frame(width: 220, alignment: .trailing)
                        }
                        .padding(10)
                        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var myNext: some View {
        let mine = ws.tasks.filter { $0.assignee == ws.me && $0.status != .done && !$0.archived }
            .sorted { ($0.isOverdue() ? 0 : 1, $0.status == .inProgress ? 0 : 1, $0.dueDate ?? .distantFuture, -$0.priority.rawValue) < ($1.isOverdue() ? 0 : 1, $1.status == .inProgress ? 0 : 1, $1.dueDate ?? .distantFuture, -$1.priority.rawValue) }
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { RLabel(text: "Task saya berikutnya"); Spacer()
                    Button("My Work") { UserDefaults.standard.set(CCSection.mywork.rawValue, forKey: "raphaelCCSection") }.buttonStyle(.link).font(.system(size: 11.5)) }
                if mine.isEmpty { Text("Belum ada task yang ditugaskan ke \(ws.me).").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                ForEach(mine.prefix(7)) { TaskRowLine(task: $0, showProject: true) }
            }
        }
    }

    // MARK: Insights

    private func throughput(_ i: WorkspaceInsights) -> some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { RLabel(text: "Task selesai per minggu · 8 minggu"); Spacer()
                    Text("dari tanggal selesai task").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                if i.weeks.allSatisfy({ $0.completed == 0 }) {
                    Text("Belum ada task yang selesai dalam 8 minggu terakhir.").font(.system(size: 12)).foregroundStyle(RTheme.muted).frame(height: 120)
                } else {
                    Chart(i.weeks, id: \.start) { w in
                        LineMark(x: .value("Minggu", w.start), y: .value("Selesai", w.completed)).foregroundStyle(RTheme.violet).interpolationMethod(.monotone)
                        AreaMark(x: .value("Minggu", w.start), y: .value("Selesai", w.completed))
                            .foregroundStyle(LinearGradient(colors: [RTheme.violet.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                        PointMark(x: .value("Minggu", w.start), y: .value("Selesai", w.completed)).foregroundStyle(RTheme.violet).symbolSize(20)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                    .frame(height: 140)
                }
            }
        }
    }

    private func delivery(_ i: WorkspaceInsights) -> some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                RLabel(text: "Delivery")
                row("Release 30 hari", "\(i.releasesLast30)", "release lokal + GitHub")
                row("CI gagal 28 hari", i.ciFailureRate.map { "\(Int($0 * 100))%" } ?? "–", i.ciRuns == 0 ? "belum ada run tercatat (tautkan repo)" : "dari \(i.ciRuns) run")
                let ci = i.weeks.suffix(4)
                if ci.contains(where: { $0.ciPassed + $0.ciFailed > 0 }) {
                    Chart(Array(ci), id: \.start) { w in
                        BarMark(x: .value("Minggu", w.start, unit: .weekOfYear), y: .value("Run", w.ciPassed)).foregroundStyle(RTheme.green.opacity(0.7))
                        BarMark(x: .value("Minggu", w.start, unit: .weekOfYear), y: .value("Run", w.ciFailed)).foregroundStyle(RTheme.red)
                    }
                    .chartYAxis(.hidden).frame(height: 70)
                }
                row("WIP", "\(i.wip)", "In Progress + Review")
            }
        }
    }

    private func row(_ k: String, _ v: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundStyle(RTheme.muted)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(v).font(.system(size: 15, weight: .bold))
                Text(note).font(.system(size: 10)).foregroundStyle(RTheme.muted)
            }
        }
    }

    private var opsCard: some View {
        let alerts = mon.alerts(for: NodeStore.shared.nodes)
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { RLabel(text: "Operasional"); Spacer()
                    Button("Monitor") { UserDefaults.standard.set(CCSection.monitor.rawValue, forKey: "raphaelCCSection") }.buttonStyle(.link).font(.system(size: 11.5)) }
                let bad = alerts.filter { $0.level == .bad }, warn = alerts.filter { $0.level == .warn }
                Text("\(bad.count) kritis · \(warn.count) peringatan").font(.system(size: 13, weight: .semibold)).foregroundStyle(bad.isEmpty ? RTheme.green : RTheme.red)
                ForEach(alerts.prefix(6)) { a in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: a.icon).foregroundStyle(a.level == .bad ? RTheme.red : a.level == .warn ? RTheme.amber : RTheme.blue).frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.node).font(.system(size: 11.5, weight: .semibold))
                            Text(a.text).font(.system(size: 11.5)).foregroundStyle(RTheme.ink2).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

/// ⌘K: jump to any project, task, milestone or page.
struct CommandPalette: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ws = WorkspaceStore.shared
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Hit: Identifiable { let id: String; let icon: String; let title: String; let subtitle: String; let run: () -> Void }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Hit] = []
        let projects = ws.projects.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.key.lowercased() == q }
        out += projects.prefix(q.isEmpty ? 8 : 12).map { p in
            Hit(id: "p:\(p.id)", icon: "folder", title: p.name, subtitle: "Project · \(p.lifecycle.title)") { WorkspaceNav.open(project: p.id, tab: "Overview") }
        }
        if !q.isEmpty {
            let tasks = ws.tasks.filter { t in !t.archived && (t.title.lowercased().contains(q) || t.code(ws.projects.first { $0.id == t.projectId }).lowercased() == q) }
            out += tasks.prefix(15).map { t in
                let p = ws.projects.first { $0.id == t.projectId }
                return Hit(id: "t:\(t.id)", icon: t.status == .done ? "checkmark.circle" : "circle", title: t.title, subtitle: "\(t.code(p)) · \(p?.name ?? "") · \(t.status.title)") { WorkspaceNav.openTask(t) }
            }
            out += ws.milestones.filter { $0.title.lowercased().contains(q) }.prefix(6).map { m in
                Hit(id: "m:\(m.id)", icon: "diamond", title: m.title, subtitle: "Milestone · \(ws.projects.first { $0.id == m.projectId }?.name ?? "")") { WorkspaceNav.open(project: m.projectId, tab: "Roadmap") }
            }
        }
        out += CCSection.allCases.filter { q.isEmpty || $0.title.lowercased().contains(q) }.map { s in
            Hit(id: "s:\(s.rawValue)", icon: s.icon, title: s.title, subtitle: "Halaman") { UserDefaults.standard.set(s.rawValue, forKey: "raphaelCCSection") }
        }
        return out
    }

    var body: some View {
        let list = hits
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RTheme.muted)
                TextField("Cari project, task (mis. ALT-12), milestone, halaman…", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(index) { list[index].run(); dismiss() } }
                    .onChange(of: query) { _, _ in index = 0 }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            }
            .padding(14)
            Divider().overlay(RTheme.line)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                            Button { h.run(); dismiss() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: h.icon).frame(width: 18).foregroundStyle(RTheme.violet)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(h.title).font(.system(size: 13)).lineLimit(1)
                                        Text(h.subtitle).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    if i == index { Text("↩").font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(i == index ? RTheme.violetSoft : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(i)
                        }
                        if list.isEmpty { Text("Tidak ada hasil").font(.system(size: 12)).foregroundStyle(RTheme.muted).padding(20) }
                    }
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 600, height: 420)
        .background(RTheme.surface)
        .onAppear { focused = true }
    }
}
