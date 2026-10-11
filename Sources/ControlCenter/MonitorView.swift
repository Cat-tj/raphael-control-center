import SwiftUI
import Charts

/// Monitor, in four tabs: Ringkasan (what needs attention), Aplikasi (every app on its
/// own: server, cloud, local), Server (metrics per device) and Traffic (websites).
struct MonitorPage: View {
    enum Tab: String, CaseIterable { case summary = "Ringkasan", apps = "Aplikasi", servers = "Server", traffic = "Traffic" }
    @ObservedObject var mon = MonitorStore.shared
    @ObservedObject var device = DeviceContext.shared
    @ObservedObject var nodes = NodeStore.shared
    @ObservedObject var sites = SiteStore.shared
    @ObservedObject var cf = CloudflareStore.shared
    @ObservedObject var vercel = VercelStore.shared
    @ObservedObject var gh = GitHubStore.shared
    @ObservedObject var local = LocalProjectsStore.shared
    @ObservedObject var n8n = N8nStore.shared
    @AppStorage("raphaelMonitorTab") private var tabRaw = Tab.summary.rawValue
    @AppStorage("raphaelMonitorRange") var range = 3600.0
    @AppStorage("raphaelAppsLocation") private var locFilter = ""
    @State private var runFilter: AppRun?
    @State private var appQuery = ""
    @State private var serverId = ""
    @State private var openApp: MApp?
    @State private var showSources = false
    @State var tokenDraft = ""

    var tab: Tab { Tab(rawValue: tabRaw) ?? .summary }
    var scope: [RNode] { device.scope }

    var body: some View {
        let apps = mon.apps.filter { a in device.isAll || a.node == device.currentId }
        let statuses = mon.appStatus
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 12) {
                RPageTitle(title: "Monitor", subtitle: device.isAll ? "Semua server, aplikasi cloud dan project lokal" : "Resource dan aplikasi di \(device.scopeName)")
                Spacer()
                if tab == .servers || tab == .traffic {
                    Picker("", selection: $range) { Text("1 jam").tag(3600.0); Text("6 jam").tag(21600.0); Text("24 jam").tag(86400.0) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                if !mon.sampling.isEmpty { ProgressView().controlSize(.small) }
                Button { showSources = true } label: { Label("Sumber data", systemImage: "link") }.buttonStyle(RPillButton())
                Button { refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(RPillButton())
            }
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tabRaw = t.rawValue } label: {
                        HStack(spacing: 6) {
                            Text(t.rawValue)
                            if let n = tabBadge(t, apps: apps, statuses: statuses), n > 0 {
                                Text("\(n)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background((t == .summary ? RTheme.red : RTheme.amber).opacity(0.15), in: Capsule())
                                    .foregroundStyle(t == .summary ? RTheme.red : RTheme.amber)
                            }
                        }
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: 9).fill(RTheme.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(RTheme.line))
                            }
                        }
                        .foregroundStyle(tab == t ? RTheme.navy : RTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4).background(RTheme.wash, in: RoundedRectangle(cornerRadius: 12))

            switch tab {
            case .summary: summary(apps, statuses)
            case .apps: appsTab(apps, statuses)
            case .servers: serversTab
            case .traffic: trafficTab
            }
        }
        .onAppear {
            mon.live = true
            mon.rebuildCatalog()
            if cf.state == .idle { cf.refresh() }
            if vercel.state == .idle { vercel.refresh() }
            if gh.state == .idle { gh.refresh() }
            if local.loadedAt == nil { local.refresh() }
            if n8n.workflows.isEmpty { n8n.refreshAll() }
        }
        .onDisappear { mon.live = false }
        .sheet(item: $openApp) { a in AppDetailSheet(app: a, range: $range) }
        .sheet(isPresented: $showSources) { SourcesSheet() }
    }

    private func refreshAll() {
        Task { await mon.sampleAll() }
        sites.checkAll(); cf.refresh(); vercel.refresh(); gh.refresh(); local.refresh(); n8n.refreshAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MonitorStore.shared.rebuildCatalog() }
    }

    private func tabBadge(_ t: Tab, apps: [MApp], statuses: [String: MAppStatus]) -> Int? {
        switch t {
        case .summary: return mon.alerts(for: scope, sites: device.isAll).filter { $0.level == .bad }.count
        case .apps: return apps.filter { $0.location != .local && [.issue, .stopped].contains(statuses[$0.id]?.run ?? .unknown) }.count
        default: return nil
        }
    }

    // MARK: Ringkasan

    private func summary(_ apps: [MApp], _ st: [String: MAppStatus]) -> some View {
        let alerts = mon.alerts(for: scope, sites: device.isAll)
        let watched = apps.filter { $0.location != .local }
        let running = watched.filter { st[$0.id]?.run == .running }.count
        let issues = watched.filter { st[$0.id]?.run == .issue }
        let stopped = watched.filter { st[$0.id]?.run == .stopped }
        let servers = scope.filter { !$0.isLocal || device.selected != nil }
        let online = servers.filter { mon.detail[$0.id]?.error == nil && mon.history[$0.id]?.last != nil }.count
        let reqMin = nodes.nodes.compactMap { mon.detail[$0.id]?.tunnel != nil ? mon.history[$0.id]?.last?.req : nil }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                kpi("Aplikasi berjalan", "\(running)/\(watched.count)",
                    !issues.isEmpty || !stopped.isEmpty ? "\(issues.count) bermasalah · \(stopped.count) mati"
                        : watched.contains { st[$0.id]?.run == .unknown } ? "memeriksa…" : "semua normal",
                    issues.isEmpty && stopped.isEmpty ? RTheme.green : RTheme.amber, "square.stack.3d.up.fill") { tabRaw = Tab.apps.rawValue }
                kpi("Server online", "\(online)/\(servers.count)", servers.count == online ? "semua terjangkau" : "\(servers.count - online) tidak terjangkau",
                    servers.count == online ? RTheme.green : RTheme.red, "server.rack") { tabRaw = Tab.servers.rawValue }
                kpi("Traffic sekarang", String(format: reqMin < 10 ? "%.1f" : "%.0f", reqMin), "request / menit lewat tunnel", RTheme.violet, "chart.line.uptrend.xyaxis") { tabRaw = Tab.traffic.rawValue }
                kpi("Sinyal", "\(alerts.filter { $0.level == .bad }.count) kritis", "\(alerts.filter { $0.level == .warn }.count) peringatan · \(alerts.filter { $0.level == .info }.count) info",
                    alerts.contains { $0.level == .bad } ? RTheme.red : RTheme.green, "bell.badge") {}
            }
            HStack(alignment: .top, spacing: 14) {
                RCard(padding: 16) { groupedAlerts(alerts) }.frame(maxWidth: .infinity)
                RCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { RLabel(text: "Aplikasi yang perlu dicek"); Spacer()
                            Button("Semua aplikasi") { tabRaw = Tab.apps.rawValue }.buttonStyle(.link).font(.system(size: 11.5)) }
                        let list = (stopped + issues).prefix(8)
                        if list.isEmpty { Label("Semua aplikasi berjalan normal", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(RTheme.green).padding(.vertical, 6) }
                        ForEach(Array(list)) { a in
                            Button { openApp = a } label: {
                                HStack(spacing: 10) {
                                    RunPill(run: st[a.id]?.run ?? .unknown, compact: true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                        Text(st[a.id]?.issues.first ?? "").font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(RTheme.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 380)
            }
            RLabel(text: "Server")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(servers) { n in serverTile(n) }
            }
        }
    }

    private func kpi(_ label: String, _ value: String, _ note: String, _ tint: Color, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { RLabel(text: label); Spacer(); Image(systemName: icon).foregroundStyle(tint) }
                    Text(value).font(.system(size: 26, weight: .heavy)).foregroundStyle(RTheme.navy)
                    Text(note).font(.system(size: 11.5)).foregroundStyle(tint == RTheme.green || tint == RTheme.violet ? RTheme.muted : tint).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private static let categories: [(String, String, Set<String>)] = [
        ("Daya & suhu", "bolt.fill", ["thermometer.high", "bolt.trianglebadge.exclamationmark"]),
        ("Resource", "cpu", ["internaldrive", "memorychip", "gauge.high"]),
        ("Layanan", "shippingbox", ["shippingbox", "xmark.octagon", "arrow.clockwise", "bolt.horizontal.circle"]),
        ("Keamanan", "lock.shield", ["lock.shield", "person.badge.shield.checkmark", "restart", "arrow.down.circle"]),
        ("Website & traffic", "globe", ["globe", "lock.trianglebadge.exclamationmark", "network.slash", "chart.line.uptrend.xyaxis"]),
    ]

    private func groupedAlerts(_ alerts: [MAlert]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RLabel(text: "Perlu perhatian")
            if alerts.isEmpty { Label("Tidak ada masalah", systemImage: "checkmark.seal.fill").font(.system(size: 12.5)).foregroundStyle(RTheme.green) }
            ForEach(Self.categories, id: \.0) { cat in
                let list = alerts.filter { cat.2.contains($0.icon) }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(cat.0, systemImage: cat.1).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(RTheme.ink2)
                        ForEach(list) { a in
                            HStack(alignment: .top, spacing: 10) {
                                Text(a.level == .bad ? "Kritis" : a.level == .warn ? "Peringatan" : "Info")
                                    .font(.system(size: 10, weight: .bold)).frame(width: 74)
                                    .padding(.vertical, 2).background(levelColor(a.level).opacity(0.14), in: Capsule()).foregroundStyle(levelColor(a.level))
                                Text(a.node).font(.system(size: 12, weight: .semibold)).frame(width: 140, alignment: .leading).lineLimit(1)
                                Text(a.text).font(.system(size: 12)).foregroundStyle(RTheme.ink2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }
    }

    func levelColor(_ l: MAlert.Level) -> Color { l == .bad ? RTheme.red : l == .warn ? RTheme.amber : RTheme.blue }

    private func serverTile(_ n: RNode) -> some View {
        let d = mon.detail[n.id], s = mon.history[n.id]?.last
        return Button { serverId = n.id; tabRaw = Tab.servers.rawValue } label: {
            RCard(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RStatusDot(color: d?.error != nil ? RTheme.red : s == nil ? RTheme.muted : RTheme.green, size: 8)
                        Text(n.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Spacer()
                        if let t = s?.temp { Text("\(Int(t))°C").font(.system(size: 11, weight: .semibold)).foregroundStyle(t > 75 ? RTheme.red : RTheme.muted) }
                    }
                    if let hw = mon.hardware[n.id] { Text(hw.summary).font(.system(size: 11)).foregroundStyle(RTheme.ink2).lineLimit(1) }
                    if let role = mon.role(n.id) { Text(role).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(2) }
                    if let e = d?.error { Text(e).font(.system(size: 11)).foregroundStyle(RTheme.red).lineLimit(2) }
                    else if let s {
                        bar("CPU", s.cpu, RTheme.violet); bar("RAM", s.mem, RTheme.blue); bar("Disk", s.disk, s.disk > 0.85 ? RTheme.red : RTheme.amber)
                        if let d, !d.containers.isEmpty || !d.services.isEmpty {
                            Text("\(d.containers.filter(\.healthy).count)/\(d.containers.count) container · \(d.services.filter(\.running).count) service")
                                .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                        }
                    } else { Text("Mengambil data…").font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func bar(_ label: String, _ v: Double, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted).frame(width: 34, alignment: .leading)
            RGauge(value: v, tint: tint, height: 5)
            Text("\(Int(v * 100))%").font(.system(size: 10.5, design: .monospaced)).frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: Aplikasi

    private func appsTab(_ apps: [MApp], _ st: [String: MAppStatus]) -> some View {
        let byLoc = apps.filter { locFilter.isEmpty || $0.location.rawValue == locFilter }
        let filtered = byLoc.filter { a in
            (runFilter == nil || st[a.id]?.run == runFilter) &&
            (appQuery.isEmpty || a.name.localizedCaseInsensitiveContains(appQuery) || a.urls.contains { $0.localizedCaseInsensitiveContains(appQuery) })
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $locFilter) {
                    Text("Semua").tag("")
                    ForEach(AppLocation.allCases) { l in Text("\(l.rawValue) · \(apps.filter { $0.location == l }.count)").tag(l.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                ForEach([AppRun.running, .issue, .stopped], id: \.self) { r in
                    let n = byLoc.filter { st[$0.id]?.run == r }.count
                    Button { runFilter = runFilter == r ? nil : r } label: {
                        HStack(spacing: 5) { Circle().fill(RunPill.color(r)).frame(width: 7, height: 7); Text("\(r.rawValue) \(n)").lineLimit(1) }
                            .fixedSize()
                            .font(.system(size: 12, weight: runFilter == r ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(runFilter == r ? RunPill.color(r).opacity(0.15) : RTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(runFilter == r ? RunPill.color(r).opacity(0.5) : RTheme.line))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                TextField("Cari aplikasi…", text: $appQuery).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 220)
            }
            ForEach(AppLocation.allCases) { loc in
                let list = filtered.filter { $0.location == loc }
                    .sorted { (Self.order(st[$0.id]?.run), $0.name.lowercased()) < (Self.order(st[$1.id]?.run), $1.name.lowercased()) }
                if !list.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: loc.icon).foregroundStyle(RTheme.violet)
                        Text(loc.rawValue).font(.system(size: 14, weight: .bold))
                        Text("\(list.count)").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                        Text(loc == .server ? "self-hosted di RasPi/VPS" : loc == .cloud ? "Vercel, n8n, website eksternal" : "project di ~/Projects Mac ini")
                            .font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                    }
                    .padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(list) { a in AppCard(app: a, status: st[a.id] ?? MAppStatus()) { openApp = a } }
                    }
                    if loc == .cloud && (locFilter.isEmpty || locFilter == loc.rawValue) && !gh.repos.isEmpty { reposBlock }
                }
            }
            if filtered.isEmpty { Text("Tidak ada aplikasi yang cocok.").font(.system(size: 12.5)).foregroundStyle(RTheme.muted).padding(.vertical, 20) }
        }
    }

    static func order(_ r: AppRun?) -> Int { r == .stopped ? 0 : r == .issue ? 1 : r == .running ? 2 : 3 }

    private var reposBlock: some View {
        RCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(RTheme.violet); RLabel(text: "Repo GitHub · CI terakhir"); Spacer()
                    if let at = gh.loadedAt { Text(at.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) } }
                ForEach(gh.repos.prefix(14)) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.ci == "success" ? "checkmark.circle.fill" : r.ci == "failure" ? "xmark.circle.fill" : r.ci == nil ? "circle.dotted" : "clock.fill")
                            .foregroundStyle(r.ci == "success" ? RTheme.green : r.ci == "failure" ? RTheme.red : RTheme.muted)
                        Button(r.full) { NSWorkspace.shared.open(URL(string: r.url)!) }.buttonStyle(.link).font(.system(size: 12.5))
                        if r.isPrivate { RChip(text: "private", tint: RTheme.muted) }
                        Spacer()
                        if let n = r.ciName { Text(n).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1) }
                        Text(r.pushedAt.map { "push " + $0.ago } ?? "").font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 130, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Server

    private var serversTab: some View {
        let list = scope
        let sel = list.first { $0.id == serverId } ?? list.first
        return HStack(alignment: .top, spacing: 14) {
            if list.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(list) { n in
                        let s = mon.history[n.id]?.last, d = mon.detail[n.id]
                        Button { serverId = n.id } label: {
                            HStack(spacing: 8) {
                                RStatusDot(color: d?.error != nil ? RTheme.red : s == nil ? RTheme.muted : RTheme.green, size: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.name).font(.system(size: 12.5, weight: sel?.id == n.id ? .semibold : .regular)).lineLimit(1)
                                    if let hw = mon.hardware[n.id] { Text(hw.summary).font(.system(size: 10.5)).foregroundStyle(RTheme.ink2).lineLimit(1) }
                                    Text(s.map { "CPU \(Int($0.cpu * 100))% · RAM \(Int($0.mem * 100))%" } ?? (d?.error ?? "…"))
                                        .font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(sel?.id == n.id ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8).frame(width: 230)
                .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(RTheme.line))
            }
            if let sel { nodeCard(sel).frame(maxWidth: .infinity) }
        }
    }

    // MARK: Traffic

    private var trafficTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            trafficCard
            if device.isAll { websitesCard }
        }
    }

    private func hwItem(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RLabel(text: k)
            Text(v).font(.system(size: 12.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func points(_ id: String) -> [MSample] {
        let cut = Date().timeIntervalSince1970 - range
        return (mon.history[id] ?? []).filter { $0.t >= cut }
    }

    func nodeCard(_ n: RNode) -> some View {
        let d = mon.detail[n.id], pts = points(n.id), last = mon.history[n.id]?.last
        return RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    RStatusDot(color: d?.error != nil ? RTheme.red : last == nil ? RTheme.muted : RTheme.green, size: 9)
                    Text(n.name).font(.system(size: 16, weight: .bold))
                    if let d, d.uptime > 0 { RChip(text: "up " + Self.duration(d.uptime), tint: RTheme.muted) }
                    if let d, d.memTotalGB > 0 { Text("\(d.cores) core · \(String(format: "%.1f", d.memTotalGB)) GB RAM").font(.system(size: 11.5)).foregroundStyle(RTheme.muted) }
                    Spacer()
                    if mon.sampling.contains(n.id) { ProgressView().controlSize(.mini) }
                    if let at = d?.at { Text("diperbarui " + at.ago).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
                }
                if let hw = mon.hardware[n.id] {
                    HStack(alignment: .top, spacing: 18) {
                        hwItem("Perangkat", hw.model.replacingOccurrences(of: " Plus", with: "+"))
                        hwItem("Prosesor", hw.cpu.isEmpty ? "–" : hw.cpu)
                        hwItem("Sistem", hw.os.isEmpty ? "–" : hw.os)
                        hwItem("Penyimpanan", hw.storage.isEmpty ? "–" : hw.storage.joined(separator: " + "))
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                }
                if let role = mon.role(n.id) { Label(role, systemImage: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(RTheme.ink2) }
                if let e = d?.error {
                    Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.red)
                } else if last == nil {
                    Text("Mengambil data pertama…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        metric("CPU", last.map { "\(Int($0.cpu * 100))%" } ?? "–", pts.map { ($0.t, $0.cpu * 100) }, RTheme.violet, max: 100)
                        metric("RAM", last.map { "\(Int($0.mem * 100))%" } ?? "–", pts.map { ($0.t, $0.mem * 100) }, RTheme.blue, max: 100,
                               note: last.flatMap { $0.swap > 0.05 ? "swap \(Int($0.swap * 100))%" : nil })
                        metric("Disk /", last.map { "\(Int($0.disk * 100))%" } ?? "–", pts.map { ($0.t, $0.disk * 100) }, RTheme.amber, max: 100)
                        metric("Network", last.map { "↓\(Self.rate($0.rx)) ↑\(Self.rate($0.tx))" } ?? "–", pts.map { ($0.t, ($0.rx + $0.tx) / 1024) }, RTheme.mint, max: nil)
                        if let t = last?.temp {
                            metric("Suhu", "\(Int(t))°C", pts.compactMap { p in p.temp.map { (p.t, $0) } }, t > 75 ? RTheme.red : RTheme.orchid, max: nil,
                                   note: d?.throttled.map { $0 == "0x0" ? "daya normal" : Self.throttleText($0) })
                        } else {
                            metric("Load", last.map { String(format: "%.2f", $0.load) } ?? "–", pts.map { ($0.t, $0.load) }, RTheme.orchid, max: nil,
                                   note: d.map { "\($0.cores) core" })
                        }
                    }
                    if let d { details(n, d) }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ series: [(Double, Double)], _ tint: Color, max: Double?, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RLabel(text: label)
            Text(value).font(.system(size: 17, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("t", Date(timeIntervalSince1970: p.0)), y: .value("v", p.1))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", Date(timeIntervalSince1970: p.0)), y: .value("v", p.1))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...(max ?? Swift.max(series.map(\.1).max() ?? 1, 0.001) * 1.15))
            .frame(height: 38)
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
        }
        .padding(10)
        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func details(_ n: RNode, _ d: MDetail) -> some View {
        Divider().overlay(RTheme.line)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                RLabel(text: "Proses teratas · CPU")
                ForEach(d.topCPU, id: \.self) { p in procRow(p.name, String(format: "%.1f%%", p.cpu), String(format: "%.1f%% RAM", p.mem)) }
                RLabel(text: "Proses teratas · RAM").padding(.top, 8)
                ForEach(d.topMem, id: \.self) { p in procRow(p.name, String(format: "%.1f%%", p.mem), "pid \(p.pid)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                RLabel(text: "Disk")
                ForEach(d.disks, id: \.self) { disk in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(disk.mount).font(.system(size: 12, design: .monospaced)); Spacer()
                            Text("\(Int(disk.used * 100))% dari \(Int(disk.totalGB)) GB").font(.system(size: 11.5)).foregroundStyle(RTheme.muted) }
                        RGauge(value: disk.used, tint: disk.used > 0.85 ? RTheme.red : RTheme.amber)
                    }
                }
                RLabel(text: "Keamanan & sistem").padding(.top, 8)
                securityRow("Update paket", d.updates.map { "\($0) tertunda" + ((d.securityUpdates ?? 0) > 0 ? " · \(d.securityUpdates!) keamanan" : "") } ?? "–", (d.securityUpdates ?? 0) > 0)
                securityRow("Login SSH gagal 24 jam", d.sshFails.map(String.init) ?? "–", (d.sshFails ?? 0) > 20)
                securityRow("Perlu reboot", d.rebootRequired ? "ya" : "tidak", d.rebootRequired)
                securityRow("Service gagal", d.failed.isEmpty ? "tidak ada" : d.failed.joined(separator: ", "), !d.failed.isEmpty)
                if let th = d.throttled { securityRow("Daya / throttling", th == "0x0" ? "normal" : Self.throttleText(th), th != "0x0") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !d.containers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                RLabel(text: "Container · \(d.containers.count)")
                HStack {
                    Text("Nama").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: 170, alignment: .leading)
                    Text("CPU").frame(width: 60, alignment: .trailing)
                    Text("RAM").frame(width: 90, alignment: .trailing)
                    Text("Net I/O").frame(width: 140, alignment: .trailing)
                    Text("Restart").frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
                ForEach(d.containers, id: \.self) { c in
                    HStack {
                        HStack(spacing: 6) { RStatusDot(color: c.healthy ? RTheme.green : RTheme.red, size: 6); Text(c.name).lineLimit(1) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(c.status).foregroundStyle(c.healthy ? RTheme.ink2 : RTheme.red).lineLimit(1).frame(width: 170, alignment: .leading)
                        Text(String(format: "%.1f%%", c.cpu)).frame(width: 60, alignment: .trailing)
                        Text(c.mem).frame(width: 90, alignment: .trailing)
                        Text(c.net).lineLimit(1).frame(width: 140, alignment: .trailing)
                        Text("\(c.restarts)").foregroundStyle(c.restarts > 3 ? RTheme.amber : RTheme.ink2).frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                }
            }
        }
    }

    private func procRow(_ name: String, _ v: String, _ sub: String) -> some View {
        HStack {
            Text(name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(sub).font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 56, alignment: .trailing)
        }
    }

    private func securityRow(_ k: String, _ v: String, _ bad: Bool) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(RTheme.ink2)
            Spacer()
            Text(v).font(.system(size: 12, weight: .semibold)).foregroundStyle(bad ? RTheme.amber : RTheme.navy).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Website traffic

    private var trafficCard: some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RLabel(text: "Traffic website")
                    Spacer()
                    if cf.state == .loading { ProgressView().controlSize(.mini) }
                }
                ForEach(NodeStore.shared.nodes.filter { mon.detail[$0.id]?.tunnel != nil && (device.isAll || scope.contains($0)) }) { n in
                    tunnelBlock(n, mon.detail[n.id]!.tunnel!)
                }
                cloudflareBlock
            }
        }
    }

    private func tunnelBlock(_ n: RNode, _ t: MTunnel) -> some View {
        let pts = points(n.id).compactMap { p in p.req.map { (p.t, $0) } }
        let now = mon.history[n.id]?.last?.req ?? 0
        let byClass = Dictionary(grouping: t.codes, by: { String($0.key.prefix(1)) }).mapValues { $0.reduce(0) { $0 + $1.value } }
        let total = max(1, t.codes.values.reduce(0, +))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.fill").foregroundStyle(RTheme.amber)
                Text("Cloudflare Tunnel · \(n.name)").font(.system(size: 13, weight: .semibold))
                RChip(text: t.connections >= 1 ? "\(Int(t.connections)) koneksi aktif" : "terputus", tint: t.connections >= 1 ? RTheme.green : RTheme.red)
                Spacer()
                Text(t.hosts.filter { !$0.hasPrefix("www.") }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    RLabel(text: "Request / menit")
                    Text(String(format: now < 10 ? "%.1f" : "%.0f", now)).font(.system(size: 26, weight: .heavy)).foregroundStyle(RTheme.accentGradient)
                    Chart {
                        ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                            AreaMark(x: .value("t", Date(timeIntervalSince1970: p.0)), y: .value("req", p.1))
                                .foregroundStyle(LinearGradient(colors: [RTheme.violet.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("t", Date(timeIntervalSince1970: p.0)), y: .value("req", p.1)).foregroundStyle(RTheme.violet).interpolationMethod(.monotone)
                        }
                    }
                    .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel() } }
                    .frame(height: 110)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    RLabel(text: "Sejak tunnel jalan")
                    Text("\(Int(t.total).formatted()) request").font(.system(size: 15, weight: .bold))
                    RStackBar(parts: [(byClass["2"] ?? 0, RTheme.green), (byClass["3"] ?? 0, RTheme.blue), (byClass["4"] ?? 0, RTheme.amber), (byClass["5"] ?? 0, RTheme.red)], height: 10)
                    ForEach([("2xx sukses", "2", RTheme.green), ("3xx redirect/cache", "3", RTheme.blue), ("4xx tidak ditemukan/ditolak", "4", RTheme.amber), ("5xx error server", "5", RTheme.red)], id: \.1) { label, k, c in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
                            Text(label).font(.system(size: 11.5))
                            Spacer()
                            Text("\(Int(byClass[k] ?? 0).formatted()) · \(Int((byClass[k] ?? 0) / total * 100))%").font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    if t.errors > 0 { Text("\(Int(t.errors)) request gagal diteruskan ke server").font(.system(size: 11)).foregroundStyle(RTheme.amber) }
                }
                .frame(width: 300)
            }
        }
    }


    @ViewBuilder private var cloudflareBlock: some View {
        Divider().overlay(RTheme.line)
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(RTheme.amber)
            Text("Cloudflare Analytics · 7 hari").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let at = cf.loadedAt { Text(at.ago).font(.system(size: 11)).foregroundStyle(RTheme.muted) }
        }
        switch cf.state {
        case .noToken, .noPermission:
            VStack(alignment: .leading, spacing: 8) {
                Text(cf.state == .noToken ? "Belum ada token Cloudflare." : "Token Cloudflare yang ada (di Hermes) tidak punya izin Analytics.")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Buat token di dash.cloudflare.com → My Profile → API Tokens → Create Token → template \"Read analytics and logs\" (Zone · Analytics · Read, semua zone). Tempel di sini; disimpan di Keychain.")
                    .font(.system(size: 12)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Token Cloudflare (Analytics: Read)", text: $tokenDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    Button("Simpan") { cf.setToken(tokenDraft); tokenDraft = "" }.buttonStyle(RPillButton(primary: true)).disabled(tokenDraft.isEmpty)
                    Button("Buka Cloudflare") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) }.buttonStyle(RPillButton())
                }
            }
        case .error(let e):
            Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.red)
        case .loading where cf.zones.isEmpty:
            Text("Memuat…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
        default:
            ForEach(cf.zones) { z in zoneRow(z) }
        }
    }

    private func zoneRow(_ z: CFZone) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(z.name).font(.system(size: 13, weight: .bold))
                Text("\(z.requests.compact) request · \(z.visitors.compact) pengunjung").font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(z.bytes), countStyle: .file)) · cache \(Int(z.cachedRatio * 100))%" + (z.threats > 0 ? " · \(z.threats) ancaman" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(z.threats > 0 ? RTheme.amber : RTheme.muted)
            }
            .frame(width: 230, alignment: .leading)
            Chart {
                ForEach(z.days) { d in
                    LineMark(x: .value("Hari", String(d.date.suffix(5))), y: .value("Request", d.requests)).foregroundStyle(by: .value("Jenis", "Request")).interpolationMethod(.monotone)
                    LineMark(x: .value("Hari", String(d.date.suffix(5))), y: .value("Request", d.visitors)).foregroundStyle(by: .value("Jenis", "Pengunjung")).interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Request": RTheme.violet, "Pengunjung": RTheme.mint])
            .chartLegend(.hidden)
            .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel { if let i = v.as(Int.self) { Text(i.compact) } } } }
            .frame(height: 80)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(z.countries.prefix(4), id: \.0) { c in
                    HStack { Text(c.0).font(.system(size: 11)); Spacer(); Text(c.1.compact).font(.system(size: 11, design: .monospaced)) }
                }
            }
            .frame(width: 130)
        }
        .padding(.vertical, 4)
    }

    // MARK: Websites

    private var websitesCard: some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                RLabel(text: "Website · uptime, waktu respons, SSL")
                ForEach(sites.sites) { s in
                    let st = sites.status[s.url], h = sites.history[s.url] ?? []
                    let up = h.isEmpty ? nil : Double(h.filter(\.ok).count) / Double(h.count)
                    let exp = SiteStore.certExpiry(for: s.url)
                    HStack(spacing: 12) {
                        RStatusDot(color: st == nil ? RTheme.muted : st!.ok ? RTheme.green : RTheme.red, size: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 12.5, weight: .semibold))
                            Text(verbatim: s.url).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1)
                        }
                        .frame(width: 260, alignment: .leading)
                        Chart {
                            ForEach(Array(h.suffix(120).enumerated()), id: \.offset) { _, p in
                                BarMark(x: .value("t", Date(timeIntervalSince1970: p.t)), y: .value("ms", p.ms))
                                    .foregroundStyle(p.ok ? RTheme.green.opacity(0.7) : RTheme.red)
                            }
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 26)
                        Text(st.map { "\($0.latencyMs) ms" } ?? "–").font(.system(size: 11.5, design: .monospaced)).frame(width: 70, alignment: .trailing)
                        Text(up.map { String(format: "%.1f%% up", $0 * 100) } ?? "–").font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle((up ?? 1) < 0.99 ? RTheme.amber : RTheme.ink2).frame(width: 80, alignment: .trailing)
                        Group {
                            if let exp {
                                let days = Int(exp.timeIntervalSinceNow / 86400)
                                Label("\(days) hari", systemImage: "lock.fill").foregroundStyle(days < 14 ? RTheme.red : RTheme.green)
                            } else { Text(s.url.hasPrefix("https") ? "SSL –" : "tanpa SSL").foregroundStyle(RTheme.muted) }
                        }
                        .font(.system(size: 11.5)).frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Formatting

    static func rate(_ bps: Double) -> String {
        bps >= 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576) : bps >= 1024 ? String(format: "%.0f KB/s", bps / 1024) : String(format: "%.0f B/s", bps)
    }

    static func duration(_ s: Double) -> String {
        let d = Int(s) / 86400, h = Int(s) % 86400 / 3600
        return d > 0 ? "\(d)h \(h)j" : "\(h)j \(Int(s) % 3600 / 60)m"
    }

    /// vcgencmd get_throttled bits, in words.
    static func throttleText(_ hex: String) -> String {
        guard let v = Int(hex.dropFirst(2), radix: 16) else { return hex }
        var now: [String] = [], past: [String] = []
        if v & 0x1 != 0 { now.append("undervoltage") }
        if v & 0x2 != 0 { now.append("frekuensi dibatasi") }
        if v & 0x4 != 0 { now.append("throttled") }
        if v & 0x8 != 0 { now.append("batas suhu") }
        if v & 0x10000 != 0 { past.append("undervoltage") }
        if v & 0x40000 != 0 { past.append("throttled") }
        if v & 0x80000 != 0 { past.append("batas suhu") }
        return (now.isEmpty ? "" : "sekarang: " + now.joined(separator: ", ")) + (past.isEmpty ? "" : (now.isEmpty ? "" : " · ") + "pernah: " + past.joined(separator: ", "))
    }
}
