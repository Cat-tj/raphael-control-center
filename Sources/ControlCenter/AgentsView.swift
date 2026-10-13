import SwiftUI
import Charts

struct AgentsPage: View {
    @ObservedObject private var stats = HermesStats.shared

    var body: some View {
        let s = stats.snapshot
        let w = s.week
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                RPageTitle(title: "Agents & Token", subtitle: (s.devices.isEmpty ? "Tidak ada Hermes" : "Hermes di " + s.devices.joined(separator: " + ")) + " · berapa token terpakai dan untuk apa")
                Spacer()
                if stats.loading { ProgressView().controlSize(.small) }
                Button { stats.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(RPillButton())
            }

            RCard(padding: 20) {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        RLabel(text: "Total token terpakai · sepanjang waktu")
                        Text(s.allTimeTotal.formatted()).font(.system(size: 36, weight: .heavy)).tracking(-1.2)
                            .foregroundStyle(RTheme.accentGradient)
                        Text("\(s.allTime.sessions.formatted()) sesi · \(s.allTime.calls.formatted()) panggilan API")
                            .font(.system(size: 12)).foregroundStyle(RTheme.muted)
                    }
                    Spacer()
                    total("Hari ini", s.today.tokens, "\(s.today.calls) call")
                    total("7 hari", s.weekTotal, "\(w.calls) call")
                    total("Input baru", s.allTime.input, "semua waktu")
                    total("Cache read", s.allTime.cacheRead, "konteks diulang")
                    total("Output", s.allTime.output, "jawaban")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                RStat(label: "Konteks / panggilan", value: s.avgContextPerCall.compact,
                      note: s.avgContextPerCall > 50_000 ? "terlalu besar · target < 30K" : "sehat",
                      tint: s.avgContextPerCall > 50_000 ? RTheme.red : RTheme.green)
                RStat(label: "System prompt + memory", value: "±\(s.systemPromptTokens.compact)",
                      note: "dikirim di setiap panggilan", tint: s.systemPromptTokens > 10_000 ? RTheme.amber : RTheme.navy)
                RStat(label: "Rasio cache", value: w.input + w.cacheRead > 0 ? "\(Int(Double(w.cacheRead) / Double(w.input + w.cacheRead) * 100))%" : "–",
                      note: "makin tinggi makin murah")
                RStat(label: "state.db", value: ByteCountFormatter.string(fromByteCount: s.dbBytes, countStyle: .file),
                      note: s.dbBytes > 1_000_000_000 ? "terlalu besar, perlu vacuum/arsip" : nil,
                      tint: s.dbBytes > 1_000_000_000 ? RTheme.red : RTheme.navy)
            }

            RCard {
                VStack(alignment: .leading, spacing: 10) {
                    RLabel(text: "Token per hari · 7 hari")
                    Chart {
                        ForEach(s.days) { d in
                            AreaMark(x: .value("Hari", String(d.day.suffix(5))), y: .value("Token", d.total))
                                .foregroundStyle(LinearGradient(colors: [RTheme.violet.opacity(0.16), RTheme.violet.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                        ForEach(series(s.days), id: \.id) { p in
                            LineMark(x: .value("Hari", p.day), y: .value("Token", p.value))
                                .foregroundStyle(by: .value("Jenis", p.kind))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: p.kind == "Total" ? 2.6 : 1.8))
                            PointMark(x: .value("Hari", p.day), y: .value("Token", p.value))
                                .foregroundStyle(by: .value("Jenis", p.kind)).symbolSize(p.kind == "Total" ? 36 : 18)
                        }
                    }
                    .chartForegroundStyleScale(["Total": RTheme.violet, "Cache read": RTheme.orchid, "Input baru": RTheme.blue, "Output": RTheme.mint])
                    .chartLegend(position: .top, alignment: .leading)
                    .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(RTheme.line); AxisValueLabel { if let i = v.as(Int.self) { Text(i.compact) } } } }
                    .frame(height: 210)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                bucketCard("Untuk apa · 7 hari", s.tasks, rename: taskName)
                bucketCard("Dari mana · 7 hari", s.sources, rename: { $0 })
                bucketCard("Model · 7 hari", s.models, rename: { $0 })
            }

            RCard {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Sesi paling boros · 7 hari")
                    HStack {
                        Text("Sesi").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Sumber").frame(width: 80, alignment: .leading)
                        Text("Call").frame(width: 50, alignment: .trailing)
                        Text("Konteks/call").frame(width: 90, alignment: .trailing)
                        Text("Total").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted)
                    ForEach(s.heaviest) { r in
                        Button {
                            UserDefaults.standard.set(CCSection.chat.rawValue, forKey: "raphaelCCSection")
                            RaphaelAgent.shared.select(r.id, device: r.device.isEmpty ? nil : r.device)
                        } label: {
                            HStack {
                                Text(r.title).font(.system(size: 12.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(r.source).font(.system(size: 11.5)).foregroundStyle(RTheme.muted).frame(width: 80, alignment: .leading)
                                Text("\(r.apiCalls)").frame(width: 50, alignment: .trailing)
                                Text(r.contextPerCall.compact).foregroundStyle(r.contextPerCall > 50_000 ? RTheme.red : RTheme.ink2)
                                    .frame(width: 90, alignment: .trailing)
                                Text(r.totalTokens.compact).fontWeight(.semibold).frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(RTheme.line)
                    }
                }
            }

            RCard {
                VStack(alignment: .leading, spacing: 8) {
                    RLabel(text: "Saran hemat token")
                    ForEach(tips(s), id: \.self) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb.fill").foregroundStyle(RTheme.amber).font(.system(size: 11))
                            Text(t).font(.system(size: 12.5)).foregroundStyle(RTheme.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private struct SeriesPoint { let id: String; let day: String; let kind: String; let value: Int }
    private func series(_ days: [HermesDay]) -> [SeriesPoint] {
        days.flatMap { d -> [SeriesPoint] in
            let day = String(d.day.suffix(5))
            return [("Total", d.total), ("Cache read", d.cacheRead), ("Input baru", d.input), ("Output", d.output)]
                .map { SeriesPoint(id: "\(day)-\($0.0)", day: day, kind: $0.0, value: $0.1) }
        }
    }

    private func taskName(_ t: String) -> String {
        switch t {
        case "chat": "Chat utama"
        case "background_review": "Background review"
        case "compression": "Kompresi konteks"
        case "title_generation": "Bikin judul"
        case "vision": "Vision"
        default: t
        }
    }

    private func total(_ label: String, _ v: Int, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            RLabel(text: label)
            Text(v.compact).font(.system(size: 20, weight: .heavy))
            Text(note).font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
        }
    }

    private func bucketCard(_ title: String, _ rows: [HermesBucket], rename: @escaping (String) -> String) -> some View {
        RCard {
            VStack(alignment: .leading, spacing: 8) {
                RLabel(text: title)
                let total = max(1, rows.reduce(0) { $0 + $1.tokens })
                RStackBar(parts: rows.enumerated().map { (Double($1.tokens), RTheme.series($0)) }, height: 10)
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(RTheme.series(i)).frame(width: 9, height: 9)
                        Text(rename(r.name)).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(r.tokens.compact).font(.system(size: 12, design: .monospaced))
                        Text("\(Int(Double(r.tokens) / Double(total) * 100))%").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RTheme.muted).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func tips(_ s: HermesSnapshot) -> [String] {
        var out: [String] = []
        if let cron = s.sources.first(where: { $0.name == "cron" }), s.weekTotal > 0, Double(cron.tokens) / Double(s.weekTotal) > 0.4 {
            out.append("Cron memakai \(Int(Double(cron.tokens) / Double(s.weekTotal) * 100))% token minggu ini (\(cron.sessions) sesi). Kurangi frekuensi job atau jalankan dengan toolset/skill minimal.")
        }
        if s.systemPromptTokens > 10_000 {
            out.append("System prompt + memory ±\(s.systemPromptTokens.compact) token terkirim di setiap panggilan. Pangkas SOUL.md/memory dan muat skill hanya saat dibutuhkan.")
        }
        if s.avgContextPerCall > 50_000 {
            out.append("Rata-rata konteks \(s.avgContextPerCall.compact) per panggilan. Aktifkan kompresi lebih awal dan potong output tool yang panjang (read_file, terminal, skill_view).")
        }
        if let review = s.tasks.first(where: { $0.name == "background_review" }), review.tokens > 1_000_000 {
            out.append("Background review memakan \(review.tokens.compact) token minggu ini. Pertimbangkan model lebih kecil atau frekuensi lebih jarang.")
        }
        if s.dbBytes > 1_000_000_000 { out.append("state.db sudah besar. Arsipkan sesi lama dan VACUUM supaya Hermes tetap cepat.") }
        if out.isEmpty { out.append("Pemakaian token terlihat sehat.") }
        return out
    }
}
