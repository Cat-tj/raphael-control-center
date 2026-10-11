import SwiftUI
import Charts

struct RunPill: View {
    let run: AppRun
    var compact = false
    /// Local projects: "not running" is normal, shown grey.
    var neutral = false
    static func color(_ r: AppRun) -> Color {
        switch r { case .running: RTheme.green; case .issue: RTheme.amber; case .stopped: RTheme.red; case .unknown: RTheme.muted }
    }
    var body: some View {
        let c = neutral && run == .stopped ? RTheme.muted : Self.color(run)
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            if !compact { Text(neutral && run == .stopped ? "Tidak jalan" : run.rawValue) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, compact ? 5 : 8).padding(.vertical, compact ? 5 : 3)
        .background(c.opacity(0.13), in: Capsule())
        .foregroundStyle(c)
        .fixedSize()
    }
}

/// One app in the Aplikasi grid.
struct AppCard: View {
    let app: MApp
    let status: MAppStatus
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RunPill(run: status.run, neutral: app.location == .local)
                    Label(app.kind.rawValue, systemImage: app.kind.icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(RTheme.muted)
                    Spacer()
                    if let n = app.node, app.location == .server { Text(NodeStore.shared.nodes.first { $0.id == n }?.name ?? n).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1)
                }
                HStack(spacing: 14) { ForEach(figures, id: \.0) { f in figure(f.0, f.1, f.2) } }
                spark.frame(height: 26)
                if let issue = status.issues.first {
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(status.run == .stopped ? RTheme.red : RTheme.amber).lineLimit(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(status.run == .stopped && app.location != .local ? RTheme.red.opacity(0.4) : RTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if let u = app.urls.first { return u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "") + (app.urls.count > 1 ? "  +\(app.urls.count - 1)" : "") }
        if let d = app.dir { return d.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        return app.note ?? ""
    }

    private var figures: [(String, String, Color)] {
        var f: [(String, String, Color)] = []
        if let p = app.local, app.kind == .local {
            f.append(("branch", p.branch ?? "–", RTheme.navy))
            f.append(("perubahan", "\(p.dirty)", p.dirty > 0 ? RTheme.amber : RTheme.navy))
            f.append(("port", p.ports.isEmpty ? "–" : p.ports.map(String.init).joined(separator: ","), RTheme.navy))
            if let c = p.lastCommit { f.append(("commit", c.ago, RTheme.navy)) }
            return f
        }
        if let v = app.vercel {
            f.append(("deploy", v.state?.capitalized ?? "–", v.state == "READY" ? RTheme.green : RTheme.amber))
            if let at = v.deployedAt { f.append(("terakhir", at.ago, RTheme.navy)) }
        }
        if let inst = app.n8n, let wf = N8nStore.shared.workflows[inst.id] {
            f.append(("workflow aktif", "\(wf.filter(\.active).count)/\(wf.count)", RTheme.navy))
            let e = wf.reduce(0) { $0 + $1.errors }
            f.append(("error 24j", "\(e)", e > 0 ? RTheme.red : RTheme.navy))
        }
        if let u = status.uptime { f.append(("uptime", String(format: "%.1f%%", u * 100), u < 0.99 ? RTheme.amber : RTheme.navy)) }
        if let l = status.latency { f.append(("respons", "\(l) ms", l > 2000 ? RTheme.amber : RTheme.navy)) }
        if let c = status.cpu { f.append(("CPU", String(format: "%.1f%%", c), RTheme.navy)) }
        if let m = status.mem, m > 0 { f.append(("RAM", ByteCountFormatter.string(fromByteCount: Int64(m), countStyle: .memory), RTheme.navy)) }
        if let s = status.sslDays, f.count < 5 { f.append(("SSL", "\(s) hari", s < 14 ? RTheme.red : RTheme.navy)) }
        return Array(f.prefix(5))
    }

    private func figure(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted).textCase(.uppercase)
            Text(v).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(c).lineLimit(1)
        }
    }

    @ViewBuilder private var spark: some View {
        // Uptime strip: one slot per check (newest right), height = response time.
        let h = Array(app.urls.flatMap { SiteStore.shared.history[$0] ?? [] }.sorted { $0.t < $1.t }.suffix(48))
        if !h.isEmpty {
            let maxMs = Double(max(h.map(\.ms).max() ?? 1, 300))
            GeometryReader { geo in
                let slot = geo.size.width / 48
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(Array(h.enumerated()), id: \.offset) { _, p in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(p.ok ? RTheme.green.opacity(0.65) : RTheme.red)
                            .frame(width: max(slot - 2, 1), height: p.ok ? max(4, geo.size.height * min(Double(p.ms) / maxMs, 1)) : geo.size.height)
                            .frame(width: slot, alignment: .center)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
            }
        } else if app.location == .local, let p = app.local, let c = p.lastCommit {
            Text("commit terakhir: \(p.lastSubject ?? "") · \(c.ago)").font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1)
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            Color.clear
        }
    }
}

/// Everything about one app: status, response time, CPU/RAM of its parts, deployments, actions.
struct AppDetailSheet: View {
    let app: MApp
    @Binding var range: Double
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mon = MonitorStore.shared
    @ObservedObject private var nodes = NodeStore.shared
    @State private var rename = ""

    private var node: RNode? { app.node.flatMap { id in nodes.nodes.first { $0.id == id } } }

    var body: some View {
        let st = AppCatalog.status(app)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: app.kind.icon).font(.system(size: 20)).foregroundStyle(RTheme.violet)
                    .frame(width: 42, height: 42).background(RTheme.violetSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) { Text(app.name).font(.system(size: 20, weight: .bold)); RunPill(run: st.run) }
                    Text([app.kind.rawValue, app.location.rawValue, node?.name].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(RTheme.muted)
                }
                Spacer()
                Picker("", selection: $range) { Text("1j").tag(3600.0); Text("6j").tag(21600.0); Text("24j").tag(86400.0) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Button("Tutup") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider().overlay(RTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    actions
                    if !st.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(st.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(RTheme.amber) }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RTheme.amberSoft, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let note = app.note { Text(note).font(.system(size: 12)).foregroundStyle(RTheme.ink2) }
                    charts
                    components
                    if let v = app.vercel { vercelBlock(v) }
                    if let r = GitHubStore.shared.repo(app.repo) { repoBlock(r) }
                    if let p = app.local { localBlock(p) }
                    if let inst = app.n8n { n8nBlock(inst) }
                    renameBlock
                }
                .padding(20)
            }
        }
        .frame(width: 820, height: 640)
        .background(RTheme.canvas)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            ForEach(app.urls.prefix(3), id: \.self) { u in
                Button { NSWorkspace.shared.open(URL(string: u)!) } label: { Label(URL(string: u)?.host ?? u, systemImage: "safari") }.buttonStyle(RPillButton())
            }
            if let dir = app.dir {
                Button {
                    UserDefaults.standard.set(app.node ?? "", forKey: "raphaelFilesNode")
                    UserDefaults.standard.set(dir, forKey: "raphaelFilesOpenPath")
                    UserDefaults.standard.set(CCSection.files.rawValue, forKey: "raphaelCCSection")
                    dismiss()
                } label: { Label("Buka file", systemImage: "folder") }.buttonStyle(RPillButton())
            }
            if let v = app.vercel { Button { NSWorkspace.shared.open(URL(string: v.dashboardURL)!) } label: { Label("Vercel", systemImage: "triangle.fill") }.buttonStyle(RPillButton()) }
            if let r = GitHubStore.shared.repo(app.repo) ?? app.repo.map({ GHRepo(full: $0, url: "https://github.com/\($0)", isPrivate: false, pushedAt: nil, branch: "", openIssues: 0) }) {
                Button { NSWorkspace.shared.open(URL(string: r.url)!) } label: { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }.buttonStyle(RPillButton())
            }
            if let node, app.location != .local {
                Button { NodeStore.shared.openTerminal(node, at: app.dir) } label: { Label("Terminal", systemImage: "terminal") }.buttonStyle(RPillButton())
            }
            if let p = app.local {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) } label: { Label("Finder", systemImage: "folder") }.buttonStyle(RPillButton())
            }
        }
    }

    // MARK: Charts

    private var cut: Double { Date().timeIntervalSince1970 - range }

    @ViewBuilder private var charts: some View {
        let checks = app.urls.flatMap { u in (SiteStore.shared.history[u] ?? []).map { (u, $0) } }.filter { $0.1.t >= cut }
        let keys = app.containers.map { "\(app.node ?? "")|c:\($0)" } + app.services.map { "\(app.node ?? "")|s:\($0)" }
        let usage = Self.sum(keys.map { (mon.components[$0] ?? []).filter { $0.t >= cut } })
        if !checks.isEmpty || !usage.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if !checks.isEmpty {
                    chartCard("Waktu respons (ms)") {
                        Chart {
                            ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                                LineMark(x: .value("t", Date(timeIntervalSince1970: c.1.t)), y: .value("ms", c.1.ms))
                                    .foregroundStyle(by: .value("URL", URL(string: c.0)?.host ?? c.0)).interpolationMethod(.monotone)
                                if !c.1.ok { PointMark(x: .value("t", Date(timeIntervalSince1970: c.1.t)), y: .value("ms", c.1.ms)).foregroundStyle(RTheme.red) }
                            }
                        }
                        .chartLegend(position: .bottom, alignment: .leading)
                    }
                }
                if !usage.isEmpty {
                    chartCard("CPU % · RAM") {
                        Chart {
                            ForEach(Array(usage.enumerated()), id: \.offset) { _, p in
                                LineMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("CPU", p.cpu)).foregroundStyle(RTheme.violet).interpolationMethod(.monotone)
                            }
                        }
                        Text("RAM sekarang: \(ByteCountFormatter.string(fromByteCount: Int64(usage.last?.mem ?? 0), countStyle: .memory))")
                            .font(.system(size: 11)).foregroundStyle(RTheme.muted)
                    }
                }
            }
        }
    }

    private func chartCard<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { RLabel(text: title); content().frame(height: 150) }
            .padding(14).frame(maxWidth: .infinity).background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
    }

    /// Sums several CPU/RAM series sampled at (about) the same instants.
    static func sum(_ series: [[MPoint]]) -> [MPoint] {
        var buckets: [Int: (cpu: Double, mem: Double)] = [:]
        for s in series { for p in s { let k = Int(p.t / 5); buckets[k, default: (0, 0)].cpu += p.cpu; buckets[k, default: (0, 0)].mem += p.mem } }
        return buckets.keys.sorted().map { MPoint(t: Double($0 * 5), cpu: buckets[$0]!.cpu, mem: buckets[$0]!.mem) }
    }

    // MARK: Components

    @ViewBuilder private var components: some View {
        let d = app.node.flatMap { mon.detail[$0] }
        let containers = app.containers.compactMap { n in d?.containers.first { $0.name == n } }
        let services = app.services.compactMap { u in d?.services.first { $0.unit == u } }
        if !containers.isEmpty || !services.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                RLabel(text: "Komponen")
                ForEach(containers, id: \.self) { c in
                    componentRow(icon: "shippingbox", name: c.name, status: c.status, ok: c.healthy, cpu: c.cpu, mem: c.memBytes, extra: c.restarts > 0 ? "restart \(c.restarts)×" : nil,
                                 rapp: RApp(kind: .docker, name: c.name, project: c.project, state: c.healthy ? "running" : "exited", status: c.status, ports: c.ports))
                }
                ForEach(services, id: \.self) { s in
                    let cpu = mon.components["\(app.node ?? "")|s:\(s.unit)"]?.last?.cpu ?? 0
                    componentRow(icon: "gearshape.2", name: s.unit, status: "\(s.state) (\(s.sub))", ok: s.running, cpu: cpu, mem: s.mem,
                                 extra: s.restarts > 0 ? "restart \(s.restarts)×" : nil,
                                 rapp: s.user ? nil : RApp(kind: .service, name: s.unit, project: "systemd", state: s.state, status: s.sub, ports: []))
                }
                CommandLog(limit: 1)
            }
            .padding(14).background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
        }
    }

    private func componentRow(icon: String, name: String, status: String, ok: Bool, cpu: Double, mem: Double, extra: String?, rapp: RApp?) -> some View {
        HStack(spacing: 10) {
            RStatusDot(color: ok ? RTheme.green : RTheme.red, size: 7)
            Image(systemName: icon).foregroundStyle(RTheme.muted).frame(width: 16)
            Text(name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            Text(status).font(.system(size: 11)).foregroundStyle(ok ? RTheme.muted : RTheme.red).lineLimit(1)
            if let extra { Text(extra).font(.system(size: 10.5)).foregroundStyle(RTheme.amber) }
            Spacer()
            Text(String(format: "%.1f%%", cpu)).font(.system(size: 11.5, design: .monospaced)).frame(width: 56, alignment: .trailing)
            Text(ByteCountFormatter.string(fromByteCount: Int64(mem), countStyle: .memory)).font(.system(size: 11.5, design: .monospaced)).frame(width: 80, alignment: .trailing)
            if let rapp, let node {
                Button("Log") { Task { await NodeStore.shared.logs(rapp, on: node) } }.buttonStyle(.link).font(.system(size: 11.5))
                Button("Restart") { Task { await NodeStore.shared.restart(rapp, on: node); await mon.sample(node) } }.buttonStyle(.link).font(.system(size: 11.5))
            }
        }
    }

    // MARK: Sources

    private func block<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(RTheme.ink2)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
    }

    private func kv(_ k: String, _ v: String, _ c: Color = RTheme.navy) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundStyle(RTheme.muted).frame(width: 130, alignment: .leading); Text(v).font(.system(size: 12)).foregroundStyle(c).lineLimit(2); Spacer() }
    }

    private func vercelBlock(_ v: VProject) -> some View {
        block("Vercel · produksi", "triangle.fill") {
            kv("Status", v.state ?? "–", v.state == "READY" ? RTheme.green : RTheme.amber)
            if let at = v.deployedAt { kv("Deploy", at.formatted(date: .abbreviated, time: .shortened) + " · " + at.ago) }
            if let c = v.commit { kv("Commit", (v.branch.map { "[\($0)] " } ?? "") + c) }
            if !v.domains.isEmpty { kv("Domain", v.domains.joined(separator: ", ")) }
            if let f = v.framework { kv("Framework", f) }
        }
    }

    private func repoBlock(_ r: GHRepo) -> some View {
        block("GitHub · \(r.full)", "chevron.left.forwardslash.chevron.right") {
            kv("CI terakhir", [r.ciName, r.ci].compactMap { $0 }.joined(separator: " · ").isEmpty ? "tidak ada Actions" : [r.ciName, r.ci].compactMap { $0 }.joined(separator: " · "),
               r.ci == "failure" ? RTheme.red : r.ci == "success" ? RTheme.green : RTheme.navy)
            if let p = r.pushedAt { kv("Push terakhir", p.ago) }
            kv("Issue/PR terbuka", "\(r.openIssues)")
            if let u = r.ciURL { Button("Lihat run CI") { NSWorkspace.shared.open(URL(string: u)!) }.buttonStyle(.link).font(.system(size: 12)) }
        }
    }

    private func localBlock(_ p: LocalProject) -> some View {
        block("Project lokal · \(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", "laptopcomputer") {
            kv("Jenis", p.kind)
            kv("Branch", p.branch ?? "bukan git")
            kv("Belum di-commit", "\(p.dirty) file", p.dirty > 0 ? RTheme.amber : RTheme.navy)
            if let s = p.lastSubject { kv("Commit terakhir", s + (p.lastCommit.map { " · " + $0.ago } ?? "")) }
            kv("Berjalan", p.running ? "port \(p.ports.map(String.init).joined(separator: ", ")) · \(p.processes.joined(separator: ", "))" : "tidak ada proses", p.running ? RTheme.green : RTheme.muted)
        }
    }

    private func n8nBlock(_ inst: N8nInstance) -> some View {
        block("n8n · workflow", "point.3.filled.connected.trianglepath.dotted") {
            if let e = N8nStore.shared.errors[inst.id] { Text(e).font(.system(size: 12)).foregroundStyle(RTheme.red) }
            ForEach(N8nStore.shared.workflows[inst.id] ?? []) { w in
                HStack(spacing: 8) {
                    RStatusDot(color: w.errors > 0 ? RTheme.red : w.active ? RTheme.green : RTheme.muted, size: 7)
                    Text(w.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if w.errors > 0 { Text("\(w.errors) error 24j").font(.system(size: 11)).foregroundStyle(RTheme.red) }
                    Text(w.active ? "aktif" : "nonaktif").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                    Button("Buka") { NSWorkspace.shared.open(URL(string: "\(inst.url)/workflow/\(w.id)")!) }.buttonStyle(.link).font(.system(size: 11.5))
                }
            }
        }
    }

    private var renameBlock: some View {
        HStack(spacing: 8) {
            TextField("Ganti nama tampilan", text: $rename).textFieldStyle(.roundedBorder).frame(width: 240)
            Button("Simpan nama") { var o = AppCatalog.overrides; o.names[app.id] = rename; AppCatalog.overrides = o; dismiss() }
                .buttonStyle(RPillButton()).disabled(rename.isEmpty)
            Spacer()
            Button("Sembunyikan dari Monitor") { var o = AppCatalog.overrides; o.hidden.insert(app.id); AppCatalog.overrides = o; dismiss() }
                .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(RTheme.muted)
        }
    }
}

/// Where the monitor reads from: Cloudflare, Vercel, n8n, GitHub, local projects.
struct SourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cf = CloudflareStore.shared
    @ObservedObject private var vercel = VercelStore.shared
    @ObservedObject private var gh = GitHubStore.shared
    @ObservedObject private var n8n = N8nStore.shared
    @ObservedObject private var local = LocalProjectsStore.shared
    @State private var cfToken = ""
    @State private var vToken = ""
    @State private var nName = ""
    @State private var nURL = ""
    @State private var nKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Sumber data").font(.system(size: 18, weight: .bold)); Spacer(); Button("Selesai") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
            Divider().overlay(RTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    source("Cloudflare Analytics", "cloud.fill", state: cfState,
                           help: "Traffic per domain (7 hari). Token: dash.cloudflare.com → API Tokens → template \"Read analytics and logs\".") {
                        HStack {
                            SecureField("Token Cloudflare", text: $cfToken).textFieldStyle(.roundedBorder)
                            Button("Simpan") { cf.setToken(cfToken); cfToken = "" }.buttonStyle(RPillButton(primary: true)).disabled(cfToken.isEmpty)
                            Button("Buat token") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) }.buttonStyle(RPillButton())
                        }
                    }
                    source("Vercel", "triangle.fill", state: vState,
                           help: "Project, status deploy produksi dan domain. Token: vercel.com/account/tokens (scope: semua team).") {
                        HStack {
                            SecureField("Token Vercel", text: $vToken).textFieldStyle(.roundedBorder)
                            Button("Simpan") { vercel.setToken(vToken); vToken = "" }.buttonStyle(RPillButton(primary: true)).disabled(vToken.isEmpty)
                            Button("Buat token") { NSWorkspace.shared.open(URL(string: "https://vercel.com/account/tokens")!) }.buttonStyle(RPillButton())
                        }
                    }
                    source("GitHub", "chevron.left.forwardslash.chevron.right", state: ghState,
                           help: "Repo dan status CI (GitHub Actions), lewat login `gh` di Mac ini.") { EmptyView() }
                    source("n8n", "point.3.filled.connected.trianglepath.dotted", state: n8n.instances.isEmpty ? ("Belum ada", RTheme.muted) : ("\(n8n.instances.count) instance", RTheme.green),
                           help: "Workflow aktif dan error 24 jam. n8n → Settings → n8n API → Create API key.") {
                        ForEach(n8n.instances) { i in
                            HStack {
                                Text(i.name).font(.system(size: 12, weight: .semibold)); Text(verbatim: i.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted)
                                if let e = n8n.errors[i.id] { Text(e).font(.system(size: 11)).foregroundStyle(RTheme.red) }
                                Spacer()
                                Button("Hapus") { n8n.remove(i) }.buttonStyle(.link).font(.system(size: 11.5))
                            }
                        }
                        HStack {
                            TextField("Nama", text: $nName).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("https://xxx.app.n8n.cloud", text: $nURL).textFieldStyle(.roundedBorder)
                            SecureField("API key", text: $nKey).textFieldStyle(.roundedBorder).frame(width: 160)
                            Button("Tambah") { n8n.add(name: nName, url: nURL, key: nKey); nName = ""; nURL = ""; nKey = "" }
                                .buttonStyle(RPillButton(primary: true)).disabled(nURL.isEmpty || nKey.isEmpty)
                        }
                    }
                    source("Project lokal", "laptopcomputer", state: ("\(local.projects.count) project · \(local.projects.filter(\.running).count) berjalan", RTheme.green),
                           help: "Folder di ~/Projects: git, perubahan belum di-commit, dan dev server yang sedang jalan.") { EmptyView() }
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 600)
        .background(RTheme.canvas)
    }

    private var cfState: (String, Color) {
        switch cf.state {
        case .ok: ("\(cf.zones.count) zone terhubung", RTheme.green)
        case .noToken: ("Belum ada token", RTheme.muted)
        case .noPermission: ("Token tanpa izin Analytics", RTheme.amber)
        case .error(let e): (e, RTheme.red)
        default: ("Memuat…", RTheme.muted)
        }
    }
    private var vState: (String, Color) {
        switch vercel.state {
        case .ok: ("\(vercel.projects.count) project", RTheme.green)
        case .noToken: ("Belum ada token", RTheme.muted)
        case .error(let e): (e, RTheme.red)
        default: ("Memuat…", RTheme.muted)
        }
    }
    private var ghState: (String, Color) {
        switch gh.state {
        case .ok: ("\(gh.repos.count) repo", RTheme.green)
        case .noCLI: ("gh belum terpasang", RTheme.amber)
        case .error(let e): (e, RTheme.red)
        default: ("Memuat…", RTheme.muted)
        }
    }

    private func source<C: View>(_ title: String, _ icon: String, state: (String, Color), help: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(RTheme.violet).frame(width: 20)
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
                Text(state.0).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(state.1).lineLimit(1)
            }
            Text(help).font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(14).background(RTheme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
    }
}
