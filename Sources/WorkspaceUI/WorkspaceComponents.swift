import SwiftUI

/// Small shared pieces for the portfolio / project screens.

enum WFormat {
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()
    static let short: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
    static func date(_ d: Date?) -> String { d.map { day.string(from: $0) } ?? "–" }
    static func due(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Hari ini" }
        if cal.isDateInTomorrow(d) { return "Besok" }
        if cal.isDateInYesterday(d) { return "Kemarin" }
        return short.string(from: d)
    }
}

extension Lifecycle {
    var color: Color {
        switch self {
        case .idea: RTheme.muted
        case .planned: RTheme.blue
        case .building: RTheme.violet
        case .live: RTheme.green
        case .maintenance: RTheme.amber
        case .archived: RTheme.muted
        }
    }
}

extension Priority {
    var color: Color { [RTheme.muted, RTheme.blue, RTheme.amber, RTheme.orchid, RTheme.red][rawValue] }
    var icon: String { ["minus", "chevron.down", "equal", "chevron.up", "exclamationmark.2"][rawValue] }
}

struct LifecycleBadge: View {
    let lifecycle: Lifecycle
    var paused = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: paused ? "pause.circle.fill" : lifecycle.icon).font(.system(size: 9.5, weight: .semibold))
            Text(paused ? "\(lifecycle.title) · Paused" : lifecycle.title)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background((paused ? RTheme.amber : lifecycle.color).opacity(0.13), in: Capsule())
        .foregroundStyle(paused ? RTheme.amber : lifecycle.color)
        .fixedSize()
        .accessibilityLabel("Lifecycle \(lifecycle.title)\(paused ? ", paused" : "")")
    }
}

struct PriorityIcon: View {
    let priority: Priority
    var body: some View {
        Image(systemName: priority.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(priority.color)
            .frame(width: 14).help("Prioritas \(priority.title)").accessibilityLabel("Prioritas \(priority.title)")
    }
}

struct HealthBadge: View {
    let health: OpsHealth
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: health.icon).font(.system(size: 10))
            if !compact { Text(health.title) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, compact ? 4 : 7).padding(.vertical, 3)
        .background(health.color.opacity(0.13), in: Capsule())
        .foregroundStyle(health.color)
        .fixedSize()
        .help("Operasional: \(health.title)")
        .accessibilityLabel("Kesehatan operasional \(health.title)")
    }
}

/// Done ÷ planned with an explicit "belum terukur" when nothing is planned.
struct ProgressMeter: View {
    let progress: (done: Int, total: Int, ratio: Double?)
    var showLabel = true
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let r = progress.ratio {
                RGauge(value: r, tint: r >= 1 ? RTheme.green : RTheme.violet, height: 5)
                if showLabel { Text("\(progress.done)/\(progress.total) task selesai · \(Int(r * 100))%").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
            } else {
                RGauge(value: 0, tint: RTheme.muted, height: 5)
                if showLabel { Text("Belum terukur · belum ada task").font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LabelChips: View {
    let labels: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(4), id: \.self) { l in
                Text(l).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RTheme.wash, in: Capsule()).foregroundStyle(RTheme.ink2)
            }
            if labels.count > 4 { Text("+\(labels.count - 4)").font(.system(size: 10)).foregroundStyle(RTheme.muted) }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (String, () -> Void)?
    var secondary: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(RTheme.violet)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(RTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 8) {
                if let action { Button(action.0, action: action.1).buttonStyle(RPillButton(primary: true)) }
                if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(RPillButton()) }
            }
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

/// A date field that can be empty.
struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(RTheme.muted).frame(width: 90, alignment: .leading)
            if let d = date {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date).labelsHidden()
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(RTheme.muted).help("Hapus tanggal")
            } else {
                Button("Atur tanggal") { date = Calendar.current.startOfDay(for: Date().addingTimeInterval(7 * 86400)) }.buttonStyle(.link).font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Comma-separated labels editor.
struct LabelsField: View {
    @Binding var labels: [String]
    @State private var text = ""
    var body: some View {
        TextField("label, dipisah koma", text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = labels.joined(separator: ", ") }
            .onSubmit { commit() }
            .onChange(of: text) { _, _ in commit() }
    }
    private func commit() {
        labels = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Opens Projects on a project (and optionally a tab).
@MainActor
enum WorkspaceNav {
    static func open(project id: String, tab: String? = nil) {
        UserDefaults.standard.set(id, forKey: "raphaelProjectSelected")
        if let tab { UserDefaults.standard.set(tab, forKey: "raphaelProjectTab") }
        UserDefaults.standard.set(CCSection.projects.rawValue, forKey: "raphaelCCSection")
    }
    static func openTask(_ task: WTask) {
        UserDefaults.standard.set(task.id, forKey: "raphaelOpenTask")
        open(project: task.projectId, tab: "Board")
    }
}
