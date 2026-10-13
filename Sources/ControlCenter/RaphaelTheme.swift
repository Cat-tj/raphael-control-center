import SwiftUI
import AppKit

/// Raphael Control Center look, taken from altora.id: near-white canvas, navy
/// text, violet used only as an accent (selection, primary action, links),
/// green for health, lilac hairlines, soft navy shadows, pill buttons and
/// small monospaced uppercase labels. The window is pinned to the light appearance.
enum RTheme {
    // Text
    static let navy   = Color(light: 0x10224F, dark: 0xE8EBF7)
    static let ink2   = Color(light: 0x3A4668, dark: 0xB9C0D6)
    static let muted  = Color(light: 0x7A8399, dark: 0x8790AA)
    // Accents
    static let violet = Color(light: 0x7C5CE8, dark: 0x9D86F5)
    static let orchid = Color(light: 0xC05BC8, dark: 0xD77ADF)
    static let green  = Color(light: 0x0E7A57, dark: 0x1F9D72)
    static let mint   = Color(light: 0x12A374, dark: 0x34D399)
    static let amber  = Color(light: 0xD98A0B, dark: 0xF5B13D)
    static let red    = Color(light: 0xD8434F, dark: 0xF4707A)
    static let blue   = Color(light: 0x3B82F6, dark: 0x6EA4FA)
    // Surfaces
    static let canvas  = Color(light: 0xFBF9FE, dark: 0x0D0F1C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x161A2D)
    static let line    = Color(light: 0xE9E6F2, dark: 0x272C46)
    static let wash    = Color(light: 0xF4F1FB, dark: 0x1D2139)
    static let violetSoft = Color(light: 0xEEE9FD, dark: 0x2B2552)
    static let greenSoft  = Color(light: 0xE3F4EC, dark: 0x13362B)
    static let redSoft    = Color(light: 0xFCE8EA, dark: 0x3A1A22)
    static let amberSoft  = Color(light: 0xFBF0DB, dark: 0x3A2C12)
    static let shadow     = Color(light: 0x262054, dark: 0x000000)

    static let accentGradient = LinearGradient(colors: [violet, orchid], startPoint: .leading, endPoint: .trailing)

    static func health(_ h: NodeHealth) -> Color {
        switch h {
        case .ok: mint
        case .warn: amber
        case .down: red
        case .unknown: Color(hex: 0xC3C7D4)
        }
    }

    /// Stable categorical colours for charts (providers, tools, tasks).
    static let series: [Color] = [violet, mint, blue, orchid, amber, Color(hex: 0x0EA5B7), red, Color(hex: 0x6366F1), Color(hex: 0x84CC16)]
    static func series(_ i: Int) -> Color { series[abs(i) % series.count] }
}

extension Color {
    /// Adapts to the window's appearance (light/dark).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// White card, lilac hairline, soft navy shadow (altora.id card).
struct RCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RTheme.line, lineWidth: 1))
            .shadow(color: RTheme.shadow.opacity(0.10), radius: 14, y: 6)
    }
}

/// Small monospaced uppercase label, as on altora.id ("TRANSACTION ACTIVITY · LAST 14 DAYS").
struct RLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(RTheme.muted)
    }
}
typealias RSectionTitle = RLabel

struct RPageTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .heavy)).tracking(-0.8).foregroundStyle(RTheme.navy)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(RTheme.muted) }
        }
    }
}

struct RStatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 3).scaleEffect(1.6))
    }
}

/// Status chip: tinted background, coloured text.
struct RChip: View {
    let text: String
    var tint: Color = RTheme.violet
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

/// Pill button styles: green primary (altora CTA) and white secondary.
struct RPillButton: ButtonStyle {
    var primary = false
    var tint: Color = RTheme.green
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(primary ? .white : RTheme.navy)
            .background(primary ? AnyShapeStyle(tint) : AnyShapeStyle(RTheme.surface), in: Capsule())
            .overlay(Capsule().stroke(primary ? .clear : RTheme.line))
            .shadow(color: primary ? tint.opacity(0.35) : RTheme.shadow.opacity(0.05), radius: primary ? 8 : 3, y: primary ? 5 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Thin horizontal gauge, 0…1.
struct RGauge: View {
    let value: Double
    var tint: Color = RTheme.violet
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(RTheme.line.opacity(0.7))
                Capsule().fill(tint).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Segmented bar (like a context-window breakdown).
struct RStackBar: View {
    let parts: [(value: Double, color: Color)]
    var total: Double? = nil
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            let sum = total ?? max(parts.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.value > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(p.color)
                            .frame(width: max(2, (g.size.width - CGFloat(parts.count) * 2) * p.value / sum))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .background(RTheme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: height)
    }
}

/// KPI tile.
struct RStat: View {
    let label: String
    let value: String
    var note: String? = nil
    var tint: Color = RTheme.navy
    var body: some View {
        RCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                RLabel(text: label)
                Text(value).font(.system(size: 24, weight: .heavy)).tracking(-0.6).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(RTheme.muted).lineLimit(2) }
            }
        }
    }
}

extension Int {
    /// 1234 → "1.2K", 3_400_000 → "3.4M".
    var compact: String {
        let v = Double(self)
        if abs(v) >= 1_000_000_000 { return String(format: "%.2fB", v / 1e9) }
        if abs(v) >= 1_000_000 { return String(format: "%.1fM", v / 1e6) }
        if abs(v) >= 1_000 { return String(format: "%.1fK", v / 1e3) }
        return "\(self)"
    }
}

extension Double {
    var usd: String { self >= 100 ? String(format: "$%.0f", self) : String(format: "$%.2f", self) }
}

extension Date {
    var ago: String { formatted(.relative(presentation: .numeric)) }
}
