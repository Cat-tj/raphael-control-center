import SwiftUI
import Charts

/// Microsoft Clarity numbers, read from Raphael Web (`/api/clarity`). The server holds the
/// token and spends Clarity's 10 daily calls; the Mac only reads what it already fetched.
@MainActor
final class ClarityStore: ObservableObject {
    static let shared = ClarityStore()

    struct Issue { let key: String; let label: String; let tip: String; let sessions: Double?; let pct: Double? }
    struct Page: Identifiable { var id: String { url }; let url: String; let sessions, scroll, active, dead, rage, quickback: Double? }
    struct Day: Identifiable { var id: String { date }; let date: String; let sessions: Double }
    struct Item: Identifiable { var id: String { name }; let name: String; let sessions: Double? }

    enum Phase: Equatable { case idle, noWeb, loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state = "idle"
    @Published private(set) var site: String?
    @Published private(set) var at: Date?
    @Published private(set) var error: String?
    @Published private(set) var tried: [String] = []
    @Published private(set) var used = 0
    @Published private(set) var limit = 10
    @Published private(set) var everyHours = 6.0
    @Published private(set) var totals: [String: Any] = [:]
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var pages: [Page] = []
    @Published private(set) var history: [Day] = []
    @Published private(set) var lists: [(String, [Item])] = []
    @Published var notice: String?
    private var loadedAt: Date?

    private var base: String? {
        let b = MonitorStore.webURL
        return b.isEmpty ? nil : (b.hasSuffix("/") ? String(b.dropLast()) : b)
    }

    func loadIfStale() { if loadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { Task { await load() } } }

    func load() async {
        guard let base, let url = URL(string: base + "/api/clarity") else { phase = .noWeb; return }
        if phase != .loaded { phase = .loading }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            apply(j)
            loadedAt = Date()
            phase = .loaded
        } catch {
            phase = .failed("Raphael Web tidak menjawab (\(error.localizedDescription))")
        }
    }

    /// Asks Raphael Web to fetch Clarity now; it refuses inside 15 minutes or when today's calls are spent.
    func refresh() async {
        guard let base, let url = URL(string: base + "/api/clarity") else { phase = .noWeb; return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Raphael")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 202 {
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                notice = j?["error"] as? String ?? "HTTP \(code)"
                return
            }
            notice = "Memuat Clarity…"
            try? await Task.sleep(for: .seconds(8))
            notice = nil
            await load()
        } catch {
            notice = error.localizedDescription
        }
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

    private func apply(_ j: [String: Any]) {
        state = j["state"] as? String ?? "idle"
        site = j["site"] as? String
        at = Self.num(j["at"]).map { Date(timeIntervalSince1970: $0) }
        error = j["error"] as? String
        tried = (j["tried"] as? [[String: Any]] ?? []).map { "\($0["source"] as? String ?? ""): \($0["result"] as? String ?? "")" }
        used = Int(Self.num(j["used"]) ?? 0)
        limit = Int(Self.num(j["limit"]) ?? 10)
        everyHours = Self.num(j["everyHours"]) ?? 6
        let t = j["totals"] as? [String: Any] ?? [:]
        totals = t
        issues = [("deadClicks", "Dead click", "Klik pada sesuatu yang tidak bisa diklik"),
                  ("rageClicks", "Rage click", "Klik berulang karena frustrasi"),
                  ("quickbacks", "Quick back", "Langsung kembali setelah membuka halaman"),
                  ("excessiveScroll", "Scroll berlebihan", "Scroll naik-turun mencari sesuatu"),
                  ("scriptErrors", "Error script", "Error JavaScript di halaman"),
                  ("errorClicks", "Klik error", "Klik yang memicu error")].compactMap { k, l, tip in
            guard let x = t[k] as? [String: Any] else { return nil }
            let s = Self.num(x["sessions"]), p = Self.num(x["pct"])
            return s == nil && p == nil ? nil : Issue(key: k, label: l, tip: tip, sessions: s, pct: p)
        }
        pages = (j["pages"] as? [[String: Any]] ?? []).compactMap { p in
            guard let u = p["url"] as? String else { return nil }
            return Page(url: u, sessions: Self.num(p["sessions"]), scroll: Self.num(p["scrollDepth"]), active: Self.num(p["activeTime"]),
                        dead: Self.num(p["deadClicks"]), rage: Self.num(p["rageClicks"]), quickback: Self.num(p["quickbacks"]))
        }
        history = (j["history"] as? [[String: Any]] ?? []).compactMap { h in
            guard let d = h["date"] as? String, let s = Self.num(h["sessions"]) else { return nil }
            return Day(date: d, sessions: s)
        }
        let l = j["lists"] as? [String: Any] ?? [:]
        lists = [("devices", "Perangkat"), ("referrers", "Datang dari"), ("countries", "Negara"), ("browsers", "Browser")].compactMap { k, title in
            let items = (l[k] as? [[String: Any]] ?? []).compactMap { x -> Item? in
                guard let n = x["name"] as? String else { return nil }
                return Item(name: n, sessions: Self.num(x["sessions"]))
            }
            return items.isEmpty ? nil : (title, Array(items.prefix(6)))
        }
    }

    func total(_ k: String) -> Double? { Self.num(totals[k]) }
}

struct ClarityCard: View {
    @ObservedObject private var store = ClarityStore.shared

    var body: some View {
        RCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                header
                switch store.phase {
                case .noWeb:
                    Text("Clarity dibaca lewat Raphael Web. Isi alamat Raphael Web di Monitor → Sumber data.")
                        .font(.system(size: 12)).foregroundStyle(RTheme.muted)
                case .failed(let e):
                    Text(e).font(.system(size: 12)).foregroundStyle(RTheme.red)
                case .idle, .loading where store.state == "idle":
                    Text("Memuat…").font(.system(size: 12)).foregroundStyle(RTheme.muted)
                default:
                    content
                }
                if let n = store.notice { Text(n).font(.system(size: 11.5)).foregroundStyle(RTheme.amber) }
            }
        }
        .onAppear { store.loadIfStale() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cursorarrow.rays").foregroundStyle(RTheme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("Perilaku pengunjung · Clarity" + (store.site.map { " · \($0)" } ?? "")).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            Spacer()
            if store.phase == .loading { ProgressView().controlSize(.mini) }
            Button("Muat ulang") { Task { await store.refresh() } }.buttonStyle(RPillButton())
            Link("Buka Clarity ↗", destination: URL(string: "https://clarity.microsoft.com/projects")!)
                .font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(RTheme.navy).overlay(Capsule().stroke(RTheme.line))
        }
    }

    private var subtitle: String {
        var parts = ["24 jam terakhir"]
        if let at = store.at { parts.append("dimuat \(at.ago)") }
        parts.append("\(store.used)/\(store.limit) permintaan hari ini")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if store.state == "noToken" || (store.state == "idle" && store.totals.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.state == "noToken" ? "Belum ada token Clarity." : "Menunggu pemuatan pertama…").font(.system(size: 12.5, weight: .semibold))
                Text("Di clarity.microsoft.com → project → Settings → Data Export → Generate new API token. Simpan di .env Hermes pada perangkat Raphael Web sebagai CLARITY_API_TOKEN (Knowledge → .env), lalu klik Muat ulang. Clarity hanya mengizinkan \(store.limit) permintaan per hari, jadi Raphael memuat tiap \(Int(store.everyHours)) jam.")
                    .font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if store.state != "ok" {
                VStack(alignment: .leading, spacing: 3) {
                    Text((store.error ?? store.state) + (store.at.map { " · angka di bawah dari \($0.ago)" } ?? ""))
                        .font(.system(size: 11.5)).foregroundStyle(RTheme.amber)
                    ForEach(store.tried, id: \.self) { Text("• \($0)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted) }
                }
            }
            kpis
            if !store.issues.isEmpty {
                HStack(spacing: 6) {
                    ForEach(store.issues, id: \.key) { i in
                        RChip(text: "\(i.label) · \(Self.count(i.sessions)) sesi" + (i.pct.map { " (\(Self.pct($0)))" } ?? ""),
                              tint: i.key == "rageClicks" || i.key == "scriptErrors" ? RTheme.red : RTheme.amber).help(i.tip)
                    }
                }
            }
            if store.history.count > 1 { historyChart }
            if !store.pages.isEmpty { pageTable }
            if !store.lists.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(store.lists, id: \.0) { title, items in
                        VStack(alignment: .leading, spacing: 3) {
                            RLabel(text: title)
                            ForEach(items) { x in
                                HStack { Text(x.name).lineLimit(1); Spacer(); Text(Self.count(x.sessions)).monospacedDigit() }.font(.system(size: 11.5))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("Klik kontak (WhatsApp, email, telepon, form) tidak ikut diekspor Clarity. Lihat di Clarity → Recordings atau Dashboard → filter Custom events: kontak_whatsapp, kontak_email, kontak_telepon, buka_halaman_kontak, kirim_form.")
                .font(.system(size: 11)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kpis: some View {
        HStack(alignment: .top, spacing: 12) {
            kpi("Sesi", Self.count(store.total("sessions")), store.total("bots").map { "\(Self.count($0)) sesi bot" }, RTheme.violet)
            kpi("Pengguna unik", Self.count(store.total("users")), store.total("pagesPerSession").map { String(format: "%.1f halaman / sesi", $0) }, RTheme.navy)
            kpi("Scroll rata-rata", store.total("scrollDepth").map(Self.pct) ?? "–", "seberapa jauh halaman dibaca", RTheme.mint)
            kpi("Waktu aktif", Self.duration(store.total("activeTime")), store.total("totalTime").map { "total \(Self.duration($0))" }, RTheme.blue)
        }
    }

    private func kpi(_ title: String, _ value: String, _ note: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RLabel(text: title)
            Text(value).font(.system(size: 24, weight: .heavy)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(12).background(RTheme.wash.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            RLabel(text: "Sesi per hari · riwayat Raphael")
            Chart(store.history) { d in
                BarMark(x: .value("Hari", String(d.date.suffix(5))), y: .value("Sesi", d.sessions)).foregroundStyle(RTheme.violet).cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel() } }
            .frame(height: 110)
        }
    }

    private var pageTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            RLabel(text: "Halaman")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(["Halaman", "Sesi", "Scroll", "Aktif", "Dead", "Rage", "Quick back"], id: \.self) {
                        Text($0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(RTheme.muted)
                    }
                }
                ForEach(store.pages.prefix(15)) { p in
                    GridRow {
                        Text(Self.path(p.url)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 320, alignment: .leading).help(p.url)
                        Text(Self.count(p.sessions)); Text(p.scroll.map(Self.pct) ?? "–"); Text(Self.duration(p.active))
                        Text(Self.count(p.dead)); Text(Self.count(p.rage)); Text(Self.count(p.quickback))
                    }
                    .font(.system(size: 11.5)).monospacedDigit()
                }
            }
        }
    }

    static func count(_ v: Double?) -> String { v.map { Int($0.rounded()).formatted() } ?? "–" }
    static func pct(_ v: Double) -> String { String(format: v < 10 ? "%.1f%%" : "%.0f%%", v) }
    static func duration(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v >= 60 ? "\(Int(v) / 60) mnt \(Int(v.rounded()) % 60) dtk" : "\(Int(v.rounded())) dtk"
    }
    static func path(_ u: String) -> String {
        guard let c = URLComponents(string: u), !c.path.isEmpty || c.query != nil else { return u.isEmpty ? "–" : u }
        return (c.path.isEmpty ? "/" : c.path) + (c.query.map { "?\($0)" } ?? "")
    }
}
