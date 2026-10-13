import SwiftUI
import Charts

struct OmniRoutePage: View {
    @ObservedObject private var store = OmniRouteStore.shared
    @State private var keyDraft = ""
    @State private var costRange = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "OmniRoute", subtitle: "Router LLM Raphael: topology provider, quota akun, dan biaya")
                Spacer()
                if DeviceContext.shared.isAll {
                    Picker("", selection: $store.selected) {
                        ForEach(store.instances) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                } else {
                    RChip(text: DeviceContext.shared.scopeName, tint: RTheme.violet)
                }
                if let inst = store.instances.first(where: { $0.id == store.selected }), let url = URL(string: inst.dashboardURL) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Buka dashboard", systemImage: "arrow.up.right.square") }
                        .buttonStyle(RPillButton(primary: true)).help(inst.dashboardURL)
                }
                Button { store.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(RPillButton())
            }

            if let inst = store.instances.first(where: { $0.id == store.selected }) {
                let snap = store.snapshots[inst.id]
                if store.loading.contains(inst.id) && snap == nil {
                    ProgressView("Memuat \(inst.baseURL)…")
                } else if let snap, snap.reachable {
                    content(snap, inst)
                } else {
                    RCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(snap?.error ?? "Belum dimuat").foregroundStyle(RTheme.red)
                            Text(inst.baseURL).font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.muted)
                            HStack {
                                SecureField("API key OmniRoute untuk \(inst.name)", text: $keyDraft).textFieldStyle(.roundedBorder).frame(width: 340)
                                Button("Simpan ke Keychain") { store.setKey(keyDraft, for: inst); keyDraft = "" }
                                    .buttonStyle(RPillButton(primary: true)).disabled(keyDraft.isEmpty)
                                Button("Coba lagi") { store.refresh(inst) }.buttonStyle(RPillButton())
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if store.snapshots.isEmpty { store.refreshAll() } }
    }

    @ViewBuilder private func content(_ s: ORSnapshot, _ inst: ORInstance) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            RStat(label: "Biaya total", value: s.totalCost.usd, note: s.since.map { "sejak \($0.formatted(date: .abbreviated, time: .omitted))" })
            RStat(label: "Biaya 7 hari", value: s.weekCost.usd, note: "hari ini \(s.todayCost.usd)")
            RStat(label: "Token total", value: s.totalTokens.compact, note: "7 hari \(s.weekTokens.compact)")
            RStat(label: "Request", value: s.totalRequests.compact, note: "sukses \(String(format: "%.1f", s.successRate))%")
            RStat(label: "Latensi rata-rata", value: "\(s.avgLatencyMs / 1000)s", tint: s.avgLatencyMs > 20_000 ? RTheme.amber : RTheme.navy)
            RStat(label: "Provider", value: "\(s.healthy)/\(s.healthy + s.degraded + s.down)",
                  note: "\(s.degraded) degraded · \(s.down) down", tint: s.down > 0 ? RTheme.red : RTheme.green)
        }

        RCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RLabel(text: "Provider topology")
                    Spacer()
                    if !s.lastProvider.isEmpty { RChip(text: "terakhir dipakai: \(s.label(s.lastProvider))", tint: RTheme.violet) }
                    if !s.errorProvider.isEmpty { RChip(text: "error terakhir: \(s.label(s.errorProvider))", tint: RTheme.red) }
                }
                TopologyView(snap: s, instance: inst)
            }
        }

        RCard {
            VStack(alignment: .leading, spacing: 12) {
                RLabel(text: "Quota akun provider")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(s.quotas) { q in quotaCard(q, s) }
                }
            }
        }

        HStack(alignment: .top, spacing: 14) {
            RCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        RLabel(text: "Biaya per hari")
                        Spacer()
                        Picker("", selection: $costRange) { Text("7h").tag(7); Text("14h").tag(14); Text("30h").tag(30) }
                            .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                    }
                    Chart(s.days.suffix(costRange)) { d in
                        BarMark(x: .value("Tanggal", String(d.date.suffix(5))), y: .value("USD", d.cost))
                            .foregroundStyle(RTheme.accentGradient).cornerRadius(4)
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel { if let d = v.as(Double.self) { Text(d.usd) } } } }
                    .frame(height: 200)
                }
            }
            RCard {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Biaya per provider")
                    breakdown(s.byProvider.prefix(8).map { ($0.name, $0.cost, $0.tokens) })
                }
            }
            .frame(maxWidth: 380)
        }

        HStack(alignment: .top, spacing: 14) {
            RCard {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Model terboros")
                    ForEach(s.byModel.prefix(10)) { m in
                        HStack {
                            Text(m.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(m.detail).font(.system(size: 11)).foregroundStyle(RTheme.muted)
                            Spacer()
                            Text("\(m.requests) req").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                            Text(m.tokens.compact).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .trailing)
                            Text(m.cost.usd).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            RCard {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Per akun")
                    breakdown(s.byAccount.prefix(8).map { ($0.name, $0.cost, $0.tokens) })
                }
            }
            .frame(maxWidth: 380)
        }
    }

    private func breakdown(_ rows: [(String, Double, Int)]) -> some View {
        let maxCost = max(rows.map(\.1).max() ?? 1, 0.0001)
        let maxTok = max(rows.map(\.2).max() ?? 1, 1)
        return ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(r.0).font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    Text(r.2.compact).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted)
                    Text(r.1.usd).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 60, alignment: .trailing)
                }
                RGauge(value: r.1 > 0 ? r.1 / maxCost : Double(r.2) / Double(maxTok), tint: RTheme.series(i), height: 4)
            }
        }
    }

    private func quotaCard(_ q: ORAccountQuota, _ s: ORSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.label(q.provider)).font(.system(size: 13, weight: .bold))
                if let plan = q.plan { RChip(text: plan, tint: RTheme.violet) }
                Spacer()
                let conn = s.connections.first { $0.id == q.id }
                if let conn { RChip(text: conn.active ? conn.testStatus : "nonaktif", tint: conn.active && conn.testStatus == "active" ? RTheme.green : RTheme.red) }
            }
            Text(q.account).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(1)
            if q.windows.isEmpty {
                Text(q.message ?? "Tidak ada data quota").font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(q.windows.prefix(4)) { w in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(w.label).font(.system(size: 12))
                        Spacer()
                        if let r = w.resetAt { Text("reset \(r.ago)").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                        Text("\(Int(100 - w.remainingPct))%").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    let used = (100 - w.remainingPct) / 100
                    RGauge(value: used, tint: used > 0.9 ? RTheme.red : used > 0.7 ? RTheme.amber : RTheme.blue)
                }
            }
        }
        .padding(14)
        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTheme.line))
    }
}

/// Clients → OmniRoute → providers → accounts, with links coloured by health.
struct TopologyView: View {
    let snap: ORSnapshot
    let instance: ORInstance
    private let rowH: CGFloat = 54

    private var providers: [String] {
        var seen: [String] = snap.metrics.map(\.provider)
        for c in snap.connections where !seen.contains(c.provider) { seen.append(c.provider) }
        return seen
    }

    var body: some View {
        let rows = providers
        let height = max(CGFloat(rows.count) * rowH, 200)
        GeometryReader { g in
            let w = g.size.width
            let clientX: CGFloat = 90, hubX = w * 0.34, provX = w * 0.52
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    let hub = CGPoint(x: hubX, y: height / 2)
                    for (i, client) in clients.enumerated() {
                        let p = CGPoint(x: clientX + 70, y: clientY(i, height))
                        var path = Path(); path.move(to: p)
                        path.addCurve(to: CGPoint(x: hub.x - 60, y: hub.y), control1: CGPoint(x: p.x + 50, y: p.y), control2: CGPoint(x: hub.x - 110, y: hub.y))
                        ctx.stroke(path, with: .color(RTheme.violet.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: client.dashed ? [4, 4] : []))
                    }
                    for (i, prov) in rows.enumerated() {
                        let y = CGFloat(i) * rowH + rowH / 2
                        var path = Path(); path.move(to: CGPoint(x: hub.x + 60, y: hub.y))
                        path.addCurve(to: CGPoint(x: provX, y: y), control1: CGPoint(x: hub.x + 120, y: hub.y), control2: CGPoint(x: provX - 70, y: y))
                        let m = snap.metrics.first { $0.provider == prov }
                        let color = color(for: m?.state ?? "idle")
                        let width = m.map { max(1.2, min(5, log10(Double(max($0.requests, 1))) * 1.4)) } ?? 1
                        ctx.stroke(path, with: .color(color.opacity(prov == snap.lastProvider ? 0.95 : 0.5)), lineWidth: width)
                    }
                }
                ForEach(Array(clients.enumerated()), id: \.offset) { i, c in
                    nodeBox(c.name, c.sub, icon: c.icon, tint: RTheme.ink2)
                        .frame(width: 150).position(x: clientX, y: clientY(i, height))
                }
                VStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 18, weight: .semibold))
                    Text("OmniRoute").font(.system(size: 13, weight: .heavy))
                    Text(instance.baseURL.replacingOccurrences(of: "http://", with: "")).font(.system(size: 9.5, design: .monospaced)).opacity(0.8)
                    Text("\(snap.modelCount) model").font(.system(size: 10)).opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(LinearGradient(colors: [Color(hex: 0x10224F), Color(hex: 0x2B2A7A)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: RTheme.violet.opacity(0.35), radius: 14, y: 6)
                .position(x: hubX, y: height / 2)

                ForEach(Array(rows.enumerated()), id: \.offset) { i, prov in
                    providerRow(prov).frame(width: w - provX - 4, height: rowH - 8, alignment: .leading)
                        .position(x: provX + (w - provX) / 2, y: CGFloat(i) * rowH + rowH / 2)
                }
            }
        }
        .frame(height: height)
    }

    private struct Client { let name: String; let sub: String; let icon: String; let dashed: Bool }
    private var clients: [Client] {
        [Client(name: "Raphael", sub: "Hermes agent", icon: "sparkles", dashed: false),
         Client(name: "Raphael.app", sub: "quick chat", icon: "menubar.rectangle", dashed: true),
         Client(name: "Cron & gateway", sub: "WhatsApp · webui", icon: "clock", dashed: true)]
    }
    private func clientY(_ i: Int, _ h: CGFloat) -> CGFloat { h / 2 + CGFloat(i - 1) * 64 }

    private func color(for state: String) -> Color {
        switch state {
        case "healthy": RTheme.mint
        case "degraded": RTheme.amber
        case "down": RTheme.red
        default: RTheme.muted.opacity(0.5)
        }
    }

    private func nodeBox(_ title: String, _ sub: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(RTheme.violet)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(sub).font(.system(size: 10)).foregroundStyle(RTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RTheme.line))
    }

    private func providerRow(_ prov: String) -> some View {
        let m = snap.metrics.first { $0.provider == prov }
        let conns = snap.connections.filter { $0.provider == prov }
        return HStack(spacing: 8) {
            RStatusDot(color: color(for: m?.state ?? "idle"), size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.label(prov)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(conns.prefix(3)) { c in
                        Text(c.name.count > 18 ? String(c.name.prefix(16)) + "…" : c.name)
                            .font(.system(size: 9.5)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background((c.active ? RTheme.violetSoft : RTheme.redSoft), in: Capsule())
                            .foregroundStyle(c.active ? RTheme.violet : RTheme.red)
                    }
                    if conns.count > 3 { Text("+\(conns.count - 3)").font(.system(size: 9.5)).foregroundStyle(RTheme.muted) }
                }
            }
            Spacer(minLength: 4)
            if let m {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(m.requests.compact) req · \(Int(m.successRate))%").font(.system(size: 10.5, design: .monospaced))
                    Text("\(m.avgLatencyMs / 1000)s · \(m.lastRequestAt?.ago ?? "-")").font(.system(size: 10)).foregroundStyle(RTheme.muted)
                }
            } else {
                Text("belum ada request").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            }
        }
        .padding(.horizontal, 10)
        .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(prov == snap.lastProvider ? RTheme.violet.opacity(0.6) : RTheme.line))
    }
}
