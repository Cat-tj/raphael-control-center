import SwiftUI
import Charts

enum CCSection: String, CaseIterable, Identifiable {
    case dashboard, infra, monitor, apps, files, omniroute, agents, knowledge, chat
    var id: String { rawValue }

    /// URL host → section (old names kept: overview, nodes).
    init(urlHost: String) {
        switch urlHost {
        case "overview", "dashboard", "control": self = .dashboard
        case "nodes", "infra", "tailscale": self = .infra
        case "apps", "websites": self = .apps
        case "monitor", "traffic", "metrics": self = .monitor
        case "files", "file": self = .files
        case "omniroute", "providers", "cost": self = .omniroute
        case "agents", "tokens": self = .agents
        case "chat": self = .chat
        case "knowledge", "graph", "soul", "env": self = .knowledge
        default: self = .dashboard
        }
    }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .infra: "Infrastruktur"
        case .apps: "Aplikasi & Website"
        case .monitor: "Monitor"
        case .files: "File"
        case .omniroute: "OmniRoute"
        case .agents: "Agents & Token"
        case .knowledge: "Knowledge"
        case .chat: "Chat Raphael"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .infra: "server.rack"
        case .apps: "app.connected.to.app.below.fill"
        case .monitor: "waveform.path.ecg.rectangle"
        case .files: "folder"
        case .omniroute: "point.3.connected.trianglepath.dotted"
        case .agents: "chart.xyaxis.line"
        case .knowledge: "brain"
        case .chat: "bubble.left.and.text.bubble.right"
        }
    }
}

struct ControlCenterView: View {
    @AppStorage("raphaelCCSection") private var sectionRaw = CCSection.dashboard.rawValue
    @ObservedObject private var nodes = NodeStore.shared
    @ObservedObject private var stats = HermesStats.shared
    @ObservedObject private var agent = RaphaelAgent.shared
    @ObservedObject private var omni = OmniRouteStore.shared
    @ObservedObject private var sites = SiteStore.shared
    @ObservedObject private var device = DeviceContext.shared

    private var section: CCSection { CCSection(rawValue: sectionRaw) ?? .dashboard }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(RTheme.line).frame(width: 1)
            Group {
                if section == .chat {
                    ChatPage()
                } else if section == .knowledge {
                    KnowledgePage()
                } else if section == .files {
                    FilesPage()
                } else {
                    ScrollView {
                        Group {
                            switch section {
                            case .dashboard: DashboardPage(go: { sectionRaw = $0.rawValue })
                            case .infra: InfraPage()
                            case .apps: AppsPage()
                            case .monitor: MonitorPage()
                            case .omniroute: OmniRoutePage()
                            case .agents: AgentsPage()
                            case .chat, .knowledge, .files: EmptyView()
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 26)
                        .frame(maxWidth: 1280, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(RTheme.canvas)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onChange(of: device.currentId) { _, _ in if unavailable(section) != nil { sectionRaw = CCSection.dashboard.rawValue } }
        .foregroundStyle(RTheme.navy)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Group {
                    if let logo = NSImage(named: "AltoraLogo") { Image(nsImage: logo).resizable().interpolation(.high) }
                    else { Image(systemName: "triangle.fill").foregroundStyle(RTheme.navy) }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("RAPHAEL").font(.system(size: 15, weight: .heavy)).tracking(0.6)
                    Text("Control Center").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                }
            }
            .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 22)

            ForEach(CCSection.allCases) { s in
                let why = unavailable(s)
                Button { sectionRaw = s.rawValue } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.icon).font(.system(size: 13)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.title)
                            if let why { Text(why).font(.system(size: 9.5)).foregroundStyle(RTheme.muted) }
                        }
                        Spacer()
                        if why == nil { badge(for: s) }
                    }
                    .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                    .padding(.horizontal, 12).padding(.vertical, why == nil ? 8 : 5)
                    .background(section == s ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(section == s ? RTheme.violet : RTheme.ink2)
                    .opacity(why == nil ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(why != nil)
            }
            Spacer()
            DeviceSwitcher()
            AppearancePicker()
                .padding(.top, 6).padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .frame(width: 232)
        .background(RTheme.surface)
    }

    /// Why a section does not apply to the chosen device (nil = available).
    private func unavailable(_ s: CCSection) -> String? {
        guard let dev = device.selected else { return nil }
        switch s {
        case .agents, .chat: return device.has("hermes", dev) ? nil : "Hermes tidak terpasang"
        case .omniroute: return device.has("omniroute", dev) ? nil : "OmniRoute tidak terpasang"
        case .knowledge:
            return device.has("hermes", dev) || dev.isLocal ? nil : "Tidak ada Hermes/graph"
        default: return nil
        }
    }

    @ViewBuilder private func badge(for s: CCSection) -> some View {
        switch s {
        case .infra:
            let n = device.scope.filter { [.down, .warn].contains(nodes.status[$0.id]?.health ?? .unknown) }.count
            if n > 0 { count(n, RTheme.amber) }
        case .apps:
            let ids = Set(device.scope.map(\.id))
            let down = nodes.allApps.filter { ids.contains($0.node.id) && $0.app.health != .ok }.count
                + (device.isAll ? sites.sites.filter { sites.status[$0.url].map { !$0.ok } ?? false }.count : 0)
            if down > 0 { count(down, RTheme.red) }
        case .omniroute:
            if let s = omni.current, s.down > 0 { count(s.down, RTheme.red) }
        case .chat:
            if agent.anyRunning { ProgressView().controlSize(.mini) }
        case .monitor:
            let bad = MonitorStore.shared.alerts(for: device.scope, sites: device.isAll).filter { $0.level == .bad }.count
            if bad > 0 { count(bad, RTheme.red) }
        default: EmptyView()
        }
    }

    private func count(_ n: Int, _ c: Color) -> some View {
        Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.12), in: Capsule())
    }
}

// MARK: - Dashboard (compact)

struct DashboardPage: View {
    let go: (CCSection) -> Void
    @ObservedObject private var nodes = NodeStore.shared
    @ObservedObject private var stats = HermesStats.shared
    @ObservedObject private var omni = OmniRouteStore.shared
    @ObservedObject private var ts = TailscaleStore.shared
    @ObservedObject private var sites = SiteStore.shared
    @State private var quick = ""

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 11 ? "Selamat pagi" : h < 15 ? "Selamat siang" : h < 19 ? "Selamat sore" : "Selamat malam"
    }

    var body: some View {
        let snap = stats.snapshot
        let ctx = DeviceContext.shared
        let scope = ctx.scope
        let ids = Set(scope.map(\.id))
        let showOR = scope.contains { ctx.has("omniroute", $0) }
        let showHermes = !ctx.hermesNodes.isEmpty
        let or = showOR ? omni.current : nil
        let online = scope.filter { [.ok, .warn].contains(nodes.status[$0.id]?.health ?? .unknown) }.count
        let apps = nodes.allApps.filter { ids.contains($0.node.id) }
        let appsUp = apps.filter { $0.app.health == .ok }.count
        let siteUp = sites.sites.filter { sites.status[$0.url]?.ok ?? false }.count

        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    RLabel(text: "Raphael · \(DeviceContext.shared.current.name)")
                    HStack(spacing: 0) {
                        Text("\(greeting), ").font(.system(size: 30, weight: .heavy)).tracking(-1)
                        Text("\(firstName).").font(.system(size: 30, weight: .heavy)).tracking(-1)
                            .foregroundStyle(RTheme.accentGradient)
                    }
                    Text(Date().formatted(date: .complete, time: .shortened)).font(.system(size: 13)).foregroundStyle(RTheme.muted)
                }
                Spacer()
                Button { refreshAll() } label: { Label("Refresh semua", systemImage: "arrow.clockwise") }
                    .buttonStyle(RPillButton())
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(RTheme.violet)
                TextField("Minta sesuatu ke Raphael…", text: $quick).textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit(send)
                Button("Kirim", action: send).buttonStyle(RPillButton(primary: true))
                    .disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .background(RTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(RTheme.line))
            .shadow(color: RTheme.shadow.opacity(0.08), radius: 12, y: 6)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                if ctx.isAll {
                    RStat(label: "Node online", value: "\(online)/\(scope.count)",
                          tint: online == scope.count ? RTheme.green : RTheme.amber)
                } else if let dev = ctx.selected, let s = nodes.status[dev.id] {
                    RStat(label: "Status", value: s.error == nil ? (s.health == .ok ? "Sehat" : "Perlu dicek") : "Offline",
                          note: s.error == nil ? "CPU \(Int(min(s.loadPerCore, 9.99) * 100))% · RAM \(Int(s.memUsed * 100))%" : nil,
                          tint: RTheme.health(s.health))
                } else {
                    RStat(label: "Status", value: "…")
                }
                RStat(label: "Aplikasi jalan", value: apps.isEmpty ? "–" : "\(appsUp)/\(apps.count)",
                      tint: appsUp == apps.count ? RTheme.green : RTheme.red)
                if ctx.isAll {
                    RStat(label: "Website up", value: "\(siteUp)/\(sites.sites.count)",
                          tint: siteUp == sites.sites.count ? RTheme.green : RTheme.red)
                } else if let dev = ctx.selected, let s = nodes.status[dev.id] {
                    RStat(label: "Disk", value: "\(Int(s.diskUsed * 100))%", note: s.tempC.map { "suhu \(Int($0))°C" },
                          tint: s.diskUsed > 0.9 ? RTheme.red : RTheme.navy)
                }
                RStat(label: "Tailscale", value: "\(ts.onlineCount)/\(ts.peers.count)", note: ts.backend.isEmpty ? nil : ts.backend)
                RStat(label: "Token hari ini", value: showHermes ? snap.today.tokens.compact : "–",
                      note: showHermes ? "\(snap.today.calls) panggilan API" : "tidak ada Hermes")
                RStat(label: "Biaya hari ini", value: or.map { $0.todayCost.usd } ?? "–",
                      note: or.map { "7 hari \($0.weekCost.usd)" } ?? (showOR ? nil : "tidak ada OmniRoute"))
            }

            HStack(alignment: .top, spacing: 14) {
                RCard {
                    VStack(alignment: .leading, spacing: 12) {
                        header(ctx.isAll ? "Nodes" : "Aplikasi di \(ctx.scopeName)", ctx.isAll ? .infra : .apps)
                        if !ctx.isAll {
                            ForEach(apps.prefix(10), id: \.app.id) { pair in
                                HStack(spacing: 8) {
                                    RStatusDot(color: RTheme.health(pair.app.health), size: 6)
                                    Text(pair.app.name).font(.system(size: 12.5)).lineLimit(1)
                                    Spacer()
                                    Text(pair.app.isCompletedJob ? "selesai" : pair.app.status).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
                                }
                            }
                            if apps.isEmpty { Text("Tidak ada container/service yang terdeteksi").font(.system(size: 12)).foregroundStyle(RTheme.muted) }
                        }
                        ForEach(ctx.isAll ? nodes.nodes : []) { n in
                            let s = nodes.status[n.id]
                            HStack(spacing: 10) {
                                RStatusDot(color: RTheme.health(s?.health ?? .unknown), size: 7)
                                Text(n.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                if let s, s.error == nil, s.checkedAt != nil {
                                    miniGauge("CPU", min(s.loadPerCore, 1))
                                    miniGauge("RAM", s.memUsed)
                                    miniGauge("DSK", s.diskUsed)
                                    Text("\(s.apps.count) app").font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 44, alignment: .trailing)
                                } else {
                                    Text(s?.error == nil ? "memeriksa…" : "offline").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                                }
                            }
                        }
                    }
                }
                RCard {
                    VStack(alignment: .leading, spacing: 12) {
                        header("Perlu perhatian", .apps)
                        let issues = attention()
                        if issues.isEmpty {
                            HStack { Image(systemName: "checkmark.seal.fill").foregroundStyle(RTheme.mint); Text("Tidak ada masalah").foregroundStyle(RTheme.muted) }
                                .font(.system(size: 13))
                        }
                        ForEach(issues.prefix(8), id: \.self) { i in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RTheme.amber).font(.system(size: 11))
                                Text(i).font(.system(size: 12.5)).foregroundStyle(RTheme.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                if showHermes { RCard {
                    VStack(alignment: .leading, spacing: 10) {
                        header("Token Hermes · 7 hari", .agents)
                        Chart(snap.days) { d in
                            AreaMark(x: .value("Hari", String(d.day.suffix(5))), y: .value("Token", d.total))
                                .foregroundStyle(LinearGradient(colors: [RTheme.violet.opacity(0.25), RTheme.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Hari", String(d.day.suffix(5))), y: .value("Token", d.total))
                                .foregroundStyle(RTheme.violet).interpolationMethod(.monotone)
                        }
                        .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel { if let i = v.as(Int.self) { Text(i.compact) } } } }
                        .frame(height: 130)
                        HStack {
                            Text("Total \(snap.weekTotal.compact)").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("±\(snap.avgContextPerCall.compact) konteks / panggilan").font(.system(size: 11))
                                .foregroundStyle(snap.avgContextPerCall > 50_000 ? RTheme.red : RTheme.muted)
                        }
                    }
                } }
                if showOR { RCard {
                    VStack(alignment: .leading, spacing: 10) {
                        header("OmniRoute providers", .omniroute)
                        if let or, or.reachable {
                            ForEach(or.metrics.prefix(6)) { m in
                                HStack(spacing: 8) {
                                    RStatusDot(color: m.state == "healthy" ? RTheme.mint : m.state == "degraded" ? RTheme.amber : RTheme.red, size: 6)
                                    Text(or.label(m.provider)).font(.system(size: 12.5)).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(m.successRate))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted)
                                    Text(m.lastRequestAt?.ago ?? "").font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 90, alignment: .trailing)
                                }
                            }
                        } else {
                            Text(or?.error ?? "Memuat…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                        }
                    }
                } }
                if showHermes { RCard {
                    VStack(alignment: .leading, spacing: 10) {
                        header("Aktivitas Raphael", .chat)
                        ForEach(snap.recent.prefix(6)) { r in
                            HStack(spacing: 8) {
                                RStatusDot(color: r.active && Date().timeIntervalSince(r.when) < 1800 ? RTheme.mint : RTheme.muted.opacity(0.4), size: 6)
                                Text(r.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                RChip(text: r.source, tint: RTheme.ink2)
                            }
                        }
                    }
                } }
            }
        }
    }

    private func attention() -> [String] {
        var out: [String] = []
        let ctx = DeviceContext.shared
        for n in ctx.scope {
            guard let s = nodes.status[n.id] else { continue }
            if let e = s.error { out.append("\(n.name): \(e)") }
            for a in s.apps where a.health != .ok { out.append("\(n.name) · \(a.name): \(a.status)") }
            if s.diskUsed > 0.9 { out.append("\(n.name): disk \(Int(s.diskUsed * 100))%") }
            if let t = s.tempC, t > 75 { out.append("\(n.name): suhu \(Int(t))°C") }
        }
        if ctx.isAll {
            for site in sites.sites { if let st = sites.status[site.url], !st.ok { out.append("\(site.name): \(st.error ?? "HTTP \(st.code)")") } }
        }
        if ctx.scope.contains(where: { ctx.has("omniroute", $0) }), let or = omni.current {
            for c in or.connections where c.testStatus == "banned" || c.lastError != nil && c.active {
                out.append("OmniRoute \(c.provider) · \(c.name): \(c.lastError ?? c.testStatus)")
            }
            for q in or.quotas { for w in q.windows where w.remainingPct < 10 { out.append("Quota \(q.provider) \(q.account) \(w.label): sisa \(Int(w.remainingPct))%") } }
        }
        if !ctx.hermesNodes.isEmpty, stats.snapshot.dbBytes > 1_000_000_000 { out.append("Hermes state.db \(ByteCountFormatter.string(fromByteCount: stats.snapshot.dbBytes, countStyle: .file)): perlu dirapikan") }
        return out
    }

    private func header(_ title: String, _ dest: CCSection) -> some View {
        HStack {
            RLabel(text: title)
            Spacer()
            Button { go(dest) } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(RTheme.violet)
        }
    }

    private func miniGauge(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
            RGauge(value: v, tint: v > 0.9 ? RTheme.red : v > 0.7 ? RTheme.amber : RTheme.mint, height: 4).frame(width: 40)
        }
    }

    private func send() {
        let t = quick; quick = ""
        RaphaelAgent.shared.newChat()
        RaphaelAgent.shared.send(t)
        go(.chat)
    }

    private func refreshAll() {
        NodeStore.shared.refreshAll()
        HermesStats.shared.refresh()
        OmniRouteStore.shared.refreshAll()
        TailscaleStore.shared.refresh()
        SiteStore.shared.checkAll()
    }
}

// MARK: - Device switcher (sidebar bottom)

/// Picks the device the Control Center looks at: Hermes (tokens, chat, history),
/// Knowledge, OmniRoute and Tailscale are read from it. Infrastruktur and
/// Aplikasi always show the whole fleet.
struct DeviceSwitcher: View {
    @ObservedObject private var device = DeviceContext.shared
    @ObservedObject private var nodes = NodeStore.shared
    @State private var open = false

    var body: some View {
        let cur = device.current
        let all = device.isAll
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: all ? "square.stack.3d.up.fill" : Self.icon(cur.kind)).font(.system(size: 14)).foregroundStyle(RTheme.violet)
                    .frame(width: 32, height: 32).background(RTheme.violetSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    RLabel(text: "Device")
                    HStack(spacing: 6) {
                        if !all { RStatusDot(color: RTheme.health(nodes.status[cur.id]?.health ?? .unknown), size: 6) }
                        Text(all ? "Semua device" : cur.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(RTheme.navy).lineLimit(1)
                    }
                    Text(all ? "\(nodes.nodes.count) device" : device.endpointCache?.model ?? (cur.isLocal ? "lokal" : cur.ssh))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(RTheme.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(open ? RTheme.violet.opacity(0.5) : RTheme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ganti device yang dilihat")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                RLabel(text: "Scope").padding(.horizontal, 8).padding(.bottom, 4)
                Button {
                    open = false
                    ControlCenterWindow.switchDevice(to: DeviceContext.allId)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill").frame(width: 18).foregroundStyle(RTheme.violet)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Semua device").font(.system(size: 13, weight: all ? .semibold : .regular))
                            Text("ringkasan seluruh armada").font(.system(size: 10)).foregroundStyle(RTheme.muted)
                        }
                        Spacer()
                        if all { Image(systemName: "checkmark").foregroundStyle(RTheme.violet).font(.system(size: 11, weight: .bold)) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(all ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.vertical, 4)
                ForEach(nodes.nodes) { n in
                    let s = nodes.status[n.id]
                    Button {
                        open = false
                        ControlCenterWindow.switchDevice(to: n.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Self.icon(n.kind)).frame(width: 18).foregroundStyle(RTheme.violet)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.name).font(.system(size: 13, weight: !all && n.id == cur.id ? .semibold : .regular))
                                if let hw = MonitorStore.shared.hardware[n.id] {
                                    Text(hw.summary).font(.system(size: 10.5)).foregroundStyle(RTheme.ink2).lineLimit(1)
                                }
                                Text(s?.error != nil ? "offline" : capsLine(n))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1)
                            }
                            Spacer()
                            RStatusDot(color: RTheme.health(s?.health ?? .unknown), size: 6)
                            if !all && n.id == cur.id { Image(systemName: "checkmark").foregroundStyle(RTheme.violet).font(.system(size: 11, weight: .bold)) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(!all && n.id == cur.id ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Semua halaman hanya menampilkan device yang dipilih. Menu yang tidak ada di device itu dinonaktifkan.")
                    .font(.system(size: 10.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.top, 6)
            }
            .padding(10).frame(width: 300)
            .foregroundStyle(RTheme.navy)
        }
    }

    private func capsLine(_ n: RNode) -> String {
        let caps = ["hermes", "omniroute", "docker", "tailscale"].filter { device.has($0, n) }
        return caps.isEmpty ? (n.isLocal ? "lokal" : n.ssh) : caps.joined(separator: " · ")
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "mac": "laptopcomputer"
        case "raspi": "cpu"
        case "vps": "cloud"
        default: "server.rack"
        }
    }
}

/// Ikuti sistem / Terang / Gelap for the Control Center window.
struct AppearancePicker: View {
    @AppStorage("raphaelAppearance") private var mode = "system"
    var body: some View {
        HStack(spacing: 2) {
            ForEach([("system", "circle.lefthalf.filled", "Ikuti sistem"), ("light", "sun.max.fill", "Terang"), ("dark", "moon.fill", "Gelap")], id: \.0) { m in
                Button {
                    mode = m.0
                    ControlCenterWindow.applyAppearance()
                } label: {
                    Image(systemName: m.1).font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(mode == m.0 ? RTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(mode == m.0 ? RTheme.violet : RTheme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.2)
            }
        }
        .padding(3)
        .background(RTheme.wash, in: RoundedRectangle(cornerRadius: 9))
    }
}
