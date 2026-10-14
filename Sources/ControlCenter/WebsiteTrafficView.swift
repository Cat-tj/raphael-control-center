import SwiftUI
import Charts

/// Cloudflare zone analytics. Visitors are daily unique IPs; country shading is
/// based on requests, which includes bots and other automated traffic.
struct WebsiteTrafficView: View {
    let zones: [CFZone]
    let unavailableReason: String?
    let snapshotNote: String?
    @State private var zoneID = ""
    @State private var selectedCountry: String?
    @State private var hoveredCountry: String?

    private var zone: CFZone? { zones.first { $0.id == zoneID } ?? zones.first }
    private var dataZone: CFZone? { zone.flatMap { $0.days.isEmpty ? nil : $0 } }
    private let world = TrafficWorldData.shared

    init(zones: [CFZone], unavailableReason: String? = nil, snapshotNote: String? = nil) {
        self.zones = zones
        self.unavailableReason = unavailableReason
        self.snapshotNote = snapshotNote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if zone != nil {
                    Picker("Website", selection: Binding(get: { self.zone?.id ?? "" }, set: { zoneID = $0 })) {
                        ForEach(zones) { Text($0.name).tag($0.id) }
                    }
                    .frame(minWidth: 180, maxWidth: 340)
                } else {
                    Picker("Website", selection: .constant("")) { Text("Menunggu data Cloudflare").tag("") }
                        .disabled(true).frame(minWidth: 180, maxWidth: 340)
                }
                Spacer()
                RChip(text: "7 hari kalender · UTC", tint: RTheme.violet)
            }
            if let notice = snapshotNote ?? unavailableReason ?? (dataZone == nil ? "Cloudflare belum mengirim data harian untuk website ini." : nil) {
                Label(notice, systemImage: snapshotNote != nil ? "clock.arrow.circlepath" : "chart.bar.xaxis")
                    .font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            metrics(dataZone)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    dailyChart(dataZone, visitors: true).frame(minWidth: 240)
                    dailyChart(dataZone, visitors: false).frame(minWidth: 240)
                }
                VStack(spacing: 16) { dailyChart(dataZone, visitors: true); dailyChart(dataZone, visitors: false) }
            }
            Divider().overlay(RTheme.line)
            HStack(alignment: .firstTextBaseline) {
                Text("Asal traffic").font(.system(size: 14, weight: .bold)).foregroundStyle(RTheme.navy)
                Spacer()
                Text(dataZone.map { "\($0.countries.count) lokasi · berdasarkan request" } ?? "Data lokasi belum tersedia")
                    .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            TrafficOriginsLayout { map(dataZone); countryList(dataZone) }
            Text("IP unik dihitung per hari; IP yang sama dapat muncul lagi pada hari lain. Asal negara mengikuti IP request dan dapat mencakup bot, crawler, atau VPN.")
                .font(.system(size: 11)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: zone?.id) { _, _ in selectedCountry = nil; hoveredCountry = nil }
        .onChange(of: dataZone == nil) { _, _ in selectedCountry = nil; hoveredCountry = nil }
    }

    private func metrics(_ zone: CFZone?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { metricCards(zone) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) { metricCards(zone) }
            }
            if let zone {
                HStack(spacing: 16) {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(zone.bytes), countStyle: .file)) data")
                    Text("Cache \(Int(zone.cachedRatio * 100))%")
                    if zone.threats > 0 { Text("\(zone.threats.formatted()) ancaman").foregroundStyle(RTheme.amber) }
                }
                .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
        }
    }

    @ViewBuilder private func metricCards(_ zone: CFZone?) -> some View {
        metric("IP unik · hari terakhir", zone?.latestDay?.visitors.formatted() ?? "–",
               zone?.latestDay.map { "\($0.date) · dapat mencakup bot" } ?? "Data belum tersedia", RTheme.mint)
        metric("Total IP unik harian", zone?.visitors.formatted() ?? "–", zone.map { "Jumlah \($0.days.count) hari · bukan orang unik 7 hari" } ?? "Data belum tersedia", RTheme.navy)
        metric("Request · 7 hari", zone?.requests.formatted() ?? "–", "Seluruh request melalui Cloudflare", RTheme.violet)
        metric("Page view · 7 hari", zone?.pageViews.formatted() ?? "–", "Respons halaman HTML", RTheme.blue)
    }

    private func metric(_ title: String, _ value: String, _ note: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RLabel(text: title)
            Text(value).font(.system(size: 25, weight: .heavy)).monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.system(size: 10.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 126, maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(12).background(RTheme.wash.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func dailyChart(_ zone: CFZone?, visitors: Bool) -> some View {
        if let zone { availableDailyChart(zone, visitors: visitors) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                RLabel(text: visitors ? "IP unik per hari" : "Request per hari")
                Label("Belum ada data harian", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(RTheme.wash.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func availableDailyChart(_ zone: CFZone, visitors: Bool) -> some View {
        let tint = visitors ? RTheme.mint : RTheme.violet
        let maximum = max(1, zone.days.map { visitors ? $0.visitors : $0.requests }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                RLabel(text: visitors ? "IP unik per hari" : "Request per hari")
                Spacer()
            }
            Chart(zone.days) { day in
                AreaMark(x: .value("Hari", day.date), y: .value(visitors ? "IP unik" : "Request", visitors ? day.visitors : day.requests))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Hari", day.date), y: .value(visitors ? "IP unik" : "Request", visitors ? day.visitors : day.requests))
                    .foregroundStyle(tint)
                PointMark(x: .value("Hari", day.date), y: .value(visitors ? "IP unik" : "Request", visitors ? day.visitors : day.requests))
                    .foregroundStyle(tint).symbolSize(18)
                    .accessibilityLabel(day.date)
                    .accessibilityValue("\((visitors ? day.visitors : day.requests).formatted()) \(visitors ? "IP unik" : "request")")
            }
            .chartYScale(domain: 0...maximum)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(RTheme.line)
                    AxisValueLabel { if let number = value.as(Int.self) { Text(number.compact) } }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel { if let date = value.as(String.self) { Text(String(date.suffix(5))) } }
                }
            }
            .frame(height: 130)
            .accessibilityLabel(visitors ? "Tren IP unik harian website" : "Tren request harian website")
            .help(visitors ? "IP unik untuk tiap hari UTC; IP yang sama dapat terhitung pada hari berbeda. Sumbu terpisah dari request."
                  : "Jumlah request website untuk tiap hari UTC, termasuk traffic otomatis. Hari terakhir dapat belum lengkap.")
        }
        .frame(maxWidth: .infinity)
    }

    private func map(_ zone: CFZone?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if world.countries.isEmpty {
                Label("Peta belum tersedia. Jumlah request per lokasi tetap ada di daftar.", systemImage: "map")
                    .font(.system(size: 12)).foregroundStyle(RTheme.muted).padding(20)
                    .frame(maxWidth: .infinity, minHeight: 200).background(RTheme.wash, in: RoundedRectangle(cornerRadius: 10))
            } else {
                TrafficWorldMap(countries: world.countries, requests: Dictionary(uniqueKeysWithValues: zone?.countries ?? []),
                                selected: $selectedCountry, hovered: $hoveredCountry)
                    .aspectRatio(360.0 / 145.0, contentMode: .fit)
                    .background(RTheme.wash.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(zone != nil)
            }
            HStack(spacing: 6) {
                if zone != nil {
                    Text("Request rendah").font(.system(size: 10))
                    LinearGradient(colors: [RTheme.violet.opacity(0.22), RTheme.violet], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 78, height: 6).clipShape(Capsule())
                    Text("tinggi").font(.system(size: 10))
                    Text("· log").font(.system(size: 10))
                } else { Text("Peta netral · belum ada data lokasi").font(.system(size: 10.5)) }
                Spacer()
                if selectedCountry != nil {
                    Button("Hapus pilihan") { selectedCountry = nil }.buttonStyle(.link).font(.system(size: 10.5))
                }
            }
            .foregroundStyle(RTheme.muted)
            .help("Warna memakai skala logaritmik supaya negara dengan request lebih sedikit tetap terlihat. Jumlah dan persentase tepat ada di daftar.")
            if let zone, let code = hoveredCountry ?? selectedCountry {
                let count = zone.countries.first { $0.0 == code }?.1 ?? 0
                Text("\(countryName(code)) · \(count.formatted()) request · \(share(count, zone))")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(RTheme.navy)
            } else {
                Text(zone != nil ? "Arahkan pointer atau klik negara untuk melihat jumlah request." : "Negara akan disorot setelah data request Cloudflare tersedia.")
                    .font(.system(size: 11)).foregroundStyle(RTheme.muted)
            }
            if !world.source.name.isEmpty {
                Text("Peta: \(world.source.name) · \(world.source.license)").font(.system(size: 9.5)).foregroundStyle(RTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func countryList(_ zone: CFZone?) -> some View {
        if let zone { availableCountryList(zone) }
        else {
            VStack(alignment: .leading, spacing: 10) {
                RLabel(text: "Negara / lokasi")
                Text("–").font(.system(size: 25, weight: .heavy)).foregroundStyle(RTheme.muted)
                Text("Asal request belum tersedia. Tidak ada negara yang disorot sampai data diterima.")
                    .font(.system(size: 11.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func availableCountryList(_ zone: CFZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RLabel(text: "Negara / lokasi")
                Spacer()
                Text("Request · %").font(.system(size: 10, design: .monospaced)).foregroundStyle(RTheme.muted)
            }
            if zone.countries.isEmpty {
                Text("Belum ada rincian lokasi dari Cloudflare.").font(.system(size: 11.5)).foregroundStyle(RTheme.muted)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(zone.countries, id: \.0) { code, count in
                        Button { selectedCountry = selectedCountry == code ? nil : code } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(world.codes.contains(code) ? RTheme.violet : RTheme.muted).frame(width: 7, height: 7).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(countryName(code)).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text(world.codes.contains(code) ? code : "\(code) · tidak dipetakan").font(.system(size: 9.5)).foregroundStyle(RTheme.muted)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(count.formatted()).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                    Text(share(count, zone)).font(.system(size: 9.5)).foregroundStyle(RTheme.muted)
                                }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(selectedCountry == code || hoveredCountry == code ? RTheme.violetSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle()).foregroundStyle(RTheme.navy)
                        }
                        .buttonStyle(.plain)
                        .onHover { on in hoveredCountry = on ? code : nil }
                        .help("\(countryName(code)): \(count.formatted()) request, \(share(count, zone)) dari semua request website")
                    }
                    if zone.requests > zone.countryRequests {
                        HStack {
                            Text("Tanpa rincian negara").font(.system(size: 11))
                            Spacer()
                            Text((zone.requests - zone.countryRequests).formatted()).font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(RTheme.muted).padding(7)
                    }
                }
            }
            .frame(height: min(270, max(60, CGFloat(zone.countries.count + (zone.requests > zone.countryRequests ? 1 : 0)) * 40)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countryName(_ code: String) -> String {
        if ["XX", "?", "ZZ", ""].contains(code) { return "Lokasi tidak diketahui" }
        if code == "T1" { return "Jaringan Tor" }
        return Locale(identifier: "id_ID").localizedString(forRegionCode: code)
            ?? world.countries.first { $0.code == code }?.name ?? code
    }

    private func share(_ count: Int, _ zone: CFZone) -> String {
        let percentage = zone.requests > 0 ? Double(count) / Double(zone.requests) * 100 : 0
        return percentage > 0 && percentage < 0.1 ? "<0,1%" : String(format: "%.1f%%", percentage)
    }
}

/// Gives the map a real width before measuring its aspect ratio. Measuring a
/// flexible Canvas with ViewThatFits otherwise picks a tiny intrinsic size.
private struct TrafficOriginsLayout: Layout {
    private let spacing: CGFloat = 20
    private let listWidth: CGFloat = 255

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700, horizontal = width >= 660
        let mapWidth = horizontal ? width - listWidth - spacing : width
        let mapSize = subviews[0].sizeThatFits(ProposedViewSize(width: mapWidth, height: nil))
        let listSize = subviews[1].sizeThatFits(ProposedViewSize(width: horizontal ? listWidth : width, height: nil))
        return CGSize(width: width, height: horizontal ? max(mapSize.height, listSize.height) : mapSize.height + spacing + listSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = bounds.width >= 660, mapWidth = horizontal ? bounds.width - listWidth - spacing : bounds.width
        let mapSize = subviews[0].sizeThatFits(ProposedViewSize(width: mapWidth, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: mapWidth, height: mapSize.height))
        subviews[1].place(at: CGPoint(x: horizontal ? bounds.minX + mapWidth + spacing : bounds.minX,
                                     y: horizontal ? bounds.minY : bounds.minY + mapSize.height + spacing), anchor: .topLeading,
                          proposal: ProposedViewSize(width: horizontal ? listWidth : bounds.width, height: nil))
    }
}

private struct TrafficWorldData: Decodable {
    struct Source: Decodable { let name: String; let url: String; let license: String }
    let version: Int
    let source: Source
    let countries: [TrafficWorldCountry]
    private(set) var codes: Set<String> = []

    private enum CodingKeys: String, CodingKey { case version, source, countries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        source = try c.decode(Source.self, forKey: .source)
        countries = try c.decode([TrafficWorldCountry].self, forKey: .countries)
        codes = Set(countries.map(\.code))
    }
    init(version: Int, source: Source, countries: [TrafficWorldCountry]) {
        self.version = version; self.source = source; self.countries = countries
    }
    static let shared: TrafficWorldData = {
        if let url = Bundle.main.url(forResource: "WorldCountries", withExtension: "json"),
           let data = try? Data(contentsOf: url), let world = try? JSONDecoder().decode(TrafficWorldData.self, from: data) { return world }
        return TrafficWorldData(version: 1, source: Source(name: "", url: "", license: ""), countries: [])
    }()
}

private struct TrafficWorldCountry: Decodable {
    let code: String
    let name: String
    /// The outline in a 1×1 box, built once at load; drawing and hit-testing only scale it.
    let unitPath: Path
    let unitBounds: CGRect

    private enum CodingKeys: String, CodingKey { case code, name, rings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        unitPath = Self.unitPath(try c.decode([[[Double]]].self, forKey: .rings))
        unitBounds = unitPath.boundingRect
    }

    func path(in size: CGSize) -> Path { unitPath.applying(CGAffineTransform(scaleX: size.width, y: size.height)) }

    func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let unit = CGPoint(x: point.x / size.width, y: point.y / size.height)
        return unitBounds.contains(unit) && unitPath.contains(unit, eoFill: true)
    }

    /// Unwrap dateline-crossing rings, then draw their wrapped copies. This keeps
    /// islands near ±180° from drawing a polygon across the whole world.
    private static func unitPath(_ rings: [[[Double]]]) -> Path {
        var path = Path()
        for ring in rings where ring.count > 2 {
            var points: [(Double, Double)] = [], previous: Double?
            for coordinate in ring where coordinate.count >= 2 {
                var longitude = coordinate[0]
                if let previous {
                    while longitude - previous > 180 { longitude -= 360 }
                    while longitude - previous < -180 { longitude += 360 }
                }
                points.append((longitude, coordinate[1])); previous = longitude
            }
            for shift in [-360.0, 0.0, 360.0] {
                for (index, point) in points.enumerated() {
                    let position = CGPoint(x: (point.0 + shift + 180) / 360, y: (85 - min(85, max(-60, point.1))) / 145)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                path.closeSubpath()
            }
        }
        return path
    }
}

private struct TrafficWorldMap: View {
    let countries: [TrafficWorldCountry]
    let requests: [String: Int]
    @Binding var selected: String?
    @Binding var hovered: String?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                let maximum = max(1, requests.values.max() ?? 1)
                for country in countries {
                    let count = requests[country.code] ?? 0, focused = country.code == selected || country.code == hovered
                    let intensity = count > 0 ? 0.22 + 0.70 * log1p(Double(count)) / log1p(Double(maximum)) : 0
                    let path = country.path(in: size)
                    let fill = focused ? RTheme.amber : count > 0 ? RTheme.violet.opacity(intensity) : RTheme.line
                    context.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                    context.stroke(path, with: .color(focused ? RTheme.amber : RTheme.surface), lineWidth: focused ? 1.3 : 0.55)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = country(at: point, size: geometry.size)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { event in
                let code = country(at: event.location, size: geometry.size)
                selected = selected == code ? nil : code
            })
            .accessibilityLabel("Peta dunia asal request website")
            .accessibilityValue("\(requests.keys.filter { code in countries.contains { $0.code == code } }.count) negara disorot dengan skala warna logaritmik. Jumlah dan persentase request tersedia pada daftar negara.")
        }
    }

    private func country(at point: CGPoint, size: CGSize) -> String? {
        countries.first { $0.contains(point, in: size) }?.code
    }
}
