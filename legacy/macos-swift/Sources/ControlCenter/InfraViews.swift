import SwiftUI

// MARK: - Infrastruktur: nodes + Tailscale + command runner

struct InfraPage: View {
    @ObservedObject private var store = NodeStore.shared
    @ObservedObject private var ts = TailscaleStore.shared
    @State private var target = "mac"
    @State private var command = ""
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                RPageTitle(title: DeviceContext.shared.isAll ? "Infrastruktur" : DeviceContext.shared.scopeName,
                           subtitle: DeviceContext.shared.isAll ? "Mac, RasPi dan VPS lewat SSH key · konektivitas Tailscale"
                                                                : "Kesehatan, aksi dan konektivitas Tailscale device ini")
                Spacer()
                Button { store.refreshAll(); ts.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(RPillButton())
                Button { adding = true } label: { Label("Tambah node", systemImage: "plus") }
                    .buttonStyle(RPillButton(primary: true))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                ForEach(DeviceContext.shared.scope) { NodeCard(node: $0) }
            }

            if DeviceContext.shared.scope.contains(where: { DeviceContext.shared.has("tailscale", $0) }) || DeviceContext.shared.isAll {
                TailscaleCard()
            }

            RCard {
                VStack(alignment: .leading, spacing: 12) {
                    RLabel(text: "Jalankan perintah")
                    HStack {
                        Picker("", selection: $target) { ForEach(DeviceContext.shared.scope) { Text($0.name).tag($0.id) } }
                            .labelsHidden().frame(width: 190)
                            .onAppear { if let s = DeviceContext.shared.selected { target = s.id } }
                        TextField("docker ps · df -h · sudo -n systemctl restart nginx", text: $command)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .onSubmit(run)
                        Button("Jalankan", action: run).buttonStyle(RPillButton(primary: true, tint: RTheme.navy))
                            .disabled(command.isEmpty)
                    }
                    CommandLog(limit: 8)
                }
            }
        }
        .sheet(isPresented: $adding) { AddNodeSheet() }
    }

    private func run() {
        guard let n = store.nodes.first(where: { $0.id == target }), !command.isEmpty else { return }
        let c = command; command = ""
        Task { await store.runCommand(n, c) }
    }
}

struct CommandLog: View {
    @ObservedObject private var store = NodeStore.shared
    var limit = 6
    var body: some View {
        ForEach(store.log.prefix(limit)) { r in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: r.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.exitCode == 0 ? RTheme.mint : RTheme.red)
                    Text("\(r.node) $ \(r.command)").font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(r.at.formatted(date: .omitted, time: .standard)).font(.system(size: 11)).foregroundStyle(RTheme.muted)
                }
                if !r.output.isEmpty {
                    ScrollView {
                        Text(r.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(10).background(Color(hex: 0x0F172A), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color(hex: 0xE2E8F0))
                }
            }
        }
    }
}

struct NodeCard: View {
    let node: RNode
    @ObservedObject private var store = NodeStore.shared
    @ObservedObject private var ts = TailscaleStore.shared

    var body: some View {
        let s = store.status[node.id]
        RCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(RTheme.violet)
                        .frame(width: 34, height: 34).background(RTheme.violetSoft, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.system(size: 14, weight: .semibold))
                        if let hw = MonitorStore.shared.hardware[node.id] {
                            Text(hw.summary).font(.system(size: 11.5)).foregroundStyle(RTheme.ink2).lineLimit(1)
                        }
                        Text(node.isLocal ? "lokal" : node.ssh + (node.jump != nil ? " via jump" : ""))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1)
                    }
                    Spacer()
                    if store.busy.contains(node.id) { ProgressView().controlSize(.small) }
                    healthChip(s)
                }
                if let e = s?.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(RTheme.red).fixedSize(horizontal: false, vertical: true)
                } else if let s, s.checkedAt != nil {
                    metric("CPU", String(format: "load %.2f · %d core", s.load.first ?? 0, s.cores), s.loadPerCore / 1.5)
                    metric("RAM", "\(Int(s.memUsed * 100))% dari \(Self.gb(s.memTotalKB))", s.memUsed)
                    metric("Disk", "\(Int(s.diskUsed * 100))% dari \(Self.gb(s.diskTotalKB))", s.diskUsed)
                    HStack(spacing: 6) {
                        RChip(text: "up \(uptime(s.uptime))", tint: RTheme.ink2)
                        if let t = s.tempC { RChip(text: "\(Int(t))°C", tint: t > 75 ? RTheme.red : RTheme.ink2) }
                        RChip(text: "\(s.apps.count) app", tint: s.appsDown > 0 ? RTheme.red : RTheme.green)
                        if let l = s.latencyMs { RChip(text: "\(l) ms", tint: RTheme.ink2) }
                        if tailscaleOnline { RChip(text: "tailscale", tint: RTheme.blue) }
                    }
                } else {
                    Text("Memeriksa…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                }
                HStack(spacing: 8) {
                    Button { Task { await store.probe(node) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(RPillButton()).help("Refresh")
                    Button { store.openTerminal(node) } label: { Label("Terminal", systemImage: "terminal") }
                        .buttonStyle(RPillButton())
                    Menu {
                        Button("Update paket") {
                            Task { await store.runCommand(node, node.isLocal ? "brew update && brew upgrade"
                                : "sudo -n apt-get update && sudo -n apt-get -y upgrade", label: "update paket") }
                        }
                        Button("Bersihkan Docker") { Task { await store.runCommand(node, "docker system prune -f", label: "docker prune") } }
                        if !node.isLocal {
                            Divider()
                            Button("Reboot") { Task { await store.reboot(node) } }
                            Button("Shutdown") { Task { await store.shutdown(node) } }
                            Divider()
                            Button("Hapus dari daftar", role: .destructive) { store.remove(node) }
                        }
                    } label: { Label("Aksi", systemImage: "bolt.fill") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private var tailscaleOnline: Bool {
        let host = node.host
        return ts.peers.contains { $0.online && ($0.ip == host || $0.name == host || $0.dnsName.hasPrefix(host)) }
    }

    @ViewBuilder private func healthChip(_ s: NodeStatus?) -> some View {
        switch s?.health ?? .unknown {
        case .ok: RChip(text: "Sehat", tint: RTheme.green)
        case .warn: RChip(text: "Perlu dicek", tint: RTheme.amber)
        case .down: RChip(text: "Offline", tint: RTheme.red)
        case .unknown: RChip(text: "…", tint: RTheme.muted)
        }
    }

    private var icon: String {
        switch node.kind {
        case "mac": "laptopcomputer"
        case "raspi": "cpu"
        case "vps": "cloud"
        default: "server.rack"
        }
    }

    static func gb(_ kb: Int) -> String {
        let g = Double(kb) / 1_048_576
        return g >= 10 ? String(format: "%.0f GB", g) : String(format: "%.1f GB", g)
    }

    private func metric(_ label: String, _ detail: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(RTheme.ink2)
            }
            RGauge(value: v, tint: v >= 0.9 ? RTheme.red : v >= 0.7 ? RTheme.amber : RTheme.mint)
        }
    }

    private func uptime(_ t: TimeInterval) -> String {
        let d = Int(t) / 86400, h = Int(t) % 86400 / 3600, m = Int(t) % 3600 / 60
        return d > 0 ? "\(d)h \(h)j" : h > 0 ? "\(h)j \(m)m" : "\(m)m"
    }
}

struct TailscaleCard: View {
    @ObservedObject private var ts = TailscaleStore.shared
    var body: some View {
        RCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RLabel(text: "Tailscale")
                    if !ts.tailnet.isEmpty { RChip(text: ts.tailnet, tint: RTheme.blue) }
                    RChip(text: ts.backend.isEmpty ? "…" : ts.backend, tint: ts.backend == "Running" ? RTheme.green : RTheme.red)
                    Spacer()
                    Text("\(ts.onlineCount) dari \(ts.peers.count) perangkat online").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                    Button { ts.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.violet)
                }
                if let e = ts.error { Text(e).font(.system(size: 12)).foregroundStyle(RTheme.red) }
                ForEach(ts.peers) { p in
                    HStack(spacing: 10) {
                        RStatusDot(color: p.online ? RTheme.mint : RTheme.muted.opacity(0.5), size: 7)
                        Image(systemName: osIcon(p.os)).foregroundStyle(RTheme.ink2).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name + (p.isSelf ? " (Mac ini)" : "")).font(.system(size: 13, weight: .medium))
                            Text(p.dnsName).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).lineLimit(1)
                        }
                        Spacer()
                        Text(p.ip).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RTheme.ink2).textSelection(.enabled)
                        if !p.isSelf {
                            if p.online {
                                RChip(text: p.direct ? "direct" : (p.relay.isEmpty ? "relay" : "relay \(p.relay)"),
                                      tint: p.direct ? RTheme.green : RTheme.amber)
                            } else {
                                Text(p.lastSeen.map { "terakhir \($0.ago)" } ?? "offline").font(.system(size: 11)).foregroundStyle(RTheme.muted)
                            }
                            if let ping = ts.pings[p.id] {
                                Text(ping).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
                            }
                            Button("Ping") { ts.ping(p) }.buttonStyle(RPillButton()).controlSize(.small).disabled(!p.online)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func osIcon(_ os: String) -> String {
        switch os.lowercased() {
        case "macos": "laptopcomputer"
        case "linux": "cpu"
        case "windows": "pc"
        case "ios": "iphone"
        case "android": "smartphone"
        default: "desktopcomputer"
        }
    }
}

struct AddNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ssh = ""
    @State private var jump = ""
    @State private var kind = "vps"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tambah node").font(.system(size: 20, weight: .heavy))
            TextField("Nama (mis. VPS Altora)", text: $name)
            TextField("SSH target: user@host atau alias ~/.ssh/config", text: $ssh)
            TextField("Jump host (opsional), mis. user@jump-host", text: $jump)
            Picker("Jenis", selection: $kind) {
                Text("VPS").tag("vps"); Text("RasPi").tag("raspi"); Text("Server").tag("server")
            }
            .pickerStyle(.segmented)
            Text("Pakai SSH key. Kalau belum: jalankan `ssh-copy-id \(ssh.isEmpty ? "user@host" : ssh)` sekali di Terminal.")
                .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            HStack {
                Spacer()
                Button("Batal") { dismiss() }.buttonStyle(RPillButton())
                Button("Tambah") {
                    NodeStore.shared.add(RNode(id: UUID().uuidString, name: name.isEmpty ? ssh : name, kind: kind, ssh: ssh,
                                               jump: jump.isEmpty ? nil : jump))
                    dismiss()
                }
                .buttonStyle(RPillButton(primary: true)).disabled(ssh.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 460)
    }
}

// MARK: - Aplikasi & Website

struct AppsPage: View {
    @ObservedObject private var nodes = NodeStore.shared
    @ObservedObject private var sites = SiteStore.shared
    @State private var newName = ""
    @State private var newURL = ""
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "Aplikasi & Website", subtitle: DeviceContext.shared.isAll
                           ? "Container Docker, service systemd dan website di setiap server"
                           : "Container dan service di \(DeviceContext.shared.scopeName)")
                Spacer()
                TextField("Cari aplikasi…", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { nodes.refreshAll(); sites.checkAll() } label: { Label("Cek ulang", systemImage: "arrow.clockwise") }
                    .buttonStyle(RPillButton())
            }

            websites

            ForEach(DeviceContext.shared.scope) { n in
                let s = nodes.status[n.id]
                let apps = (s?.apps ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.project.localizedCaseInsensitiveContains(filter) }
                if !apps.isEmpty {
                    RCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                RStatusDot(color: RTheme.health(s?.health ?? .unknown), size: 7)
                                Text(n.name).font(.system(size: 15, weight: .bold))
                                Text(n.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted)
                                Spacer()
                                let up = apps.filter { $0.health == .ok }.count
                                RChip(text: "\(up)/\(apps.count) jalan", tint: up == apps.count ? RTheme.green : RTheme.red)
                            }
                            let groups = Dictionary(grouping: apps, by: \.project).sorted { $0.key < $1.key }
                            ForEach(groups, id: \.key) { project, list in
                                VStack(alignment: .leading, spacing: 4) {
                                    RLabel(text: project)
                                    ForEach(list) { a in AppRow(app: a, node: n) }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }
            if nodes.allApps.filter({ pair in DeviceContext.shared.scope.contains { $0.id == pair.node.id } }).isEmpty {
                Text("Belum ada data aplikasi. Node sedang diperiksa, atau belum terjangkau.").foregroundStyle(RTheme.muted)
            }
            RCard { VStack(alignment: .leading, spacing: 10) { RLabel(text: "Output aksi terakhir"); CommandLog(limit: 3) } }
        }
    }

    private var websites: some View {
        RCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RLabel(text: "Website")
                    Spacer()
                    TextField("Nama", text: $newName).textFieldStyle(.roundedBorder).frame(width: 130)
                    TextField("https://…", text: $newURL).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("Tambah") { sites.add(name: newName, url: newURL); newName = ""; newURL = "" }
                        .buttonStyle(RPillButton(primary: true)).disabled(newURL.isEmpty)
                }
                if DeviceContext.shared.isAll {
                    ForEach(sites.sites) { site in siteRow(name: site.name, url: site.url, removable: site) }
                }
                let scopeIds = Set(DeviceContext.shared.scope.map(\.id))
                let disc = sites.discovered.filter { scopeIds.contains($0.node.id) && (filter.isEmpty || $0.app.name.localizedCaseInsensitiveContains(filter)) }
                if !disc.isEmpty {
                    RLabel(text: "Port terbuka yang terdeteksi").padding(.top, 6)
                    ForEach(disc, id: \.url) { d in siteRow(name: "\(d.node.name) · \(d.app.name)", url: d.url, removable: nil) }
                }
            }
        }
    }

    private func siteRow(name: String, url: String, removable: RSite?) -> some View {
        let st = sites.status[url]
        return HStack(spacing: 10) {
            RStatusDot(color: st == nil ? RTheme.muted.opacity(0.5) : st!.ok ? RTheme.mint : RTheme.red, size: 7)
            Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Button(url) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                .buttonStyle(.link).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
            Spacer()
            if let st {
                Text(st.error.map { String($0.prefix(60)) } ?? "HTTP \(st.code)").font(.system(size: 11.5))
                    .foregroundStyle(st.ok ? RTheme.ink2 : RTheme.red).lineLimit(1)
                Text("\(st.latencyMs) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).frame(width: 64, alignment: .trailing)
            } else {
                Text("belum dicek").font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            Button { sites.check(url) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.violet)
            if let removable {
                Button { sites.remove(removable) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppRow: View {
    let app: RApp
    let node: RNode
    @ObservedObject private var store = NodeStore.shared

    var body: some View {
        HStack(spacing: 10) {
            RStatusDot(color: app.isCompletedJob ? RTheme.muted.opacity(0.5) : RTheme.health(app.health), size: 6)
            Image(systemName: app.kind == .docker ? "shippingbox" : "gearshape").font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 14)
            Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            ForEach(app.ports, id: \.self) { p in
                Button {
                    let scheme = [443, 8443].contains(p) ? "https" : "http"
                    if let u = URL(string: "\(scheme)://\(node.host):\(p)") { NSWorkspace.shared.open(u) }
                } label: { Text(verbatim: ":\(p)") }
                .buttonStyle(.link).font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            Text(app.isCompletedJob ? "selesai (job)" : app.status).font(.system(size: 11.5))
                .foregroundStyle(app.health == .ok ? RTheme.muted : RTheme.red).lineLimit(1)
            Menu {
                Button("Restart") { Task { await store.restart(app, on: node) } }
                if app.health == .ok { Button("Stop") { Task { await store.stop(app, on: node) } } }
                else { Button("Start") { Task { await store.start(app, on: node) } } }
                Button("Lihat log") { Task { await store.logs(app, on: node) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(app.health == .ok ? Color.clear : RTheme.redSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
