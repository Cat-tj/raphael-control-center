import Foundation
import SwiftUI

/// Operational health of a project, from the resources linked to it. Development progress
/// is separate (a live site says nothing about how much work is left).
enum OpsHealth: Int, Comparable {
    case healthy = 0, unknown, stale, degraded, down
    static func < (a: OpsHealth, b: OpsHealth) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self { case .healthy: "Sehat"; case .unknown: "Belum diketahui"; case .stale: "Data usang"; case .degraded: "Terganggu"; case .down: "Down" }
    }
    var color: Color {
        switch self { case .healthy: RTheme.green; case .unknown: RTheme.muted; case .stale: RTheme.blue; case .degraded: RTheme.amber; case .down: RTheme.red }
    }
    var icon: String {
        switch self { case .healthy: "checkmark.circle.fill"; case .unknown: "questionmark.circle"; case .stale: "clock.badge.exclamationmark"; case .degraded: "exclamationmark.triangle.fill"; case .down: "xmark.octagon.fill" }
    }
}

struct HealthSignal: Identifiable {
    var id: String { kind.rawValue + ref }
    let kind: ResourceLink.Kind
    let ref: String
    let label: String
    let health: OpsHealth
    let detail: String
    let collectedAt: Date?
}

struct ProjectHealthReport {
    var ops: OpsHealth
    var signals: [HealthSignal]
    var lastCollected: Date?
    var hasOperationalResources: Bool
}

@MainActor
enum ProjectHealth {
    static let staleAfter: TimeInterval = 600

    static func report(_ projectId: String) -> ProjectHealthReport {
        let ws = WorkspaceStore.shared, mon = MonitorStore.shared, sites = SiteStore.shared
        var out: [HealthSignal] = []
        func fresh(_ d: Date?) -> Bool { d.map { Date().timeIntervalSince($0) < staleAfter } ?? false }

        for l in ws.links(of: projectId) {
            switch l.kind {
            case .domain:
                let url = sites.status.keys.first { URL(string: $0)?.host?.lowercased() == l.ref.lowercased() } ?? "https://\(l.ref)"
                if let st = sites.status[url] {
                    let h: OpsHealth = !fresh(st.checkedAt) ? .stale : !st.ok ? .down : st.latencyMs > 2500 ? .degraded : .healthy
                    var detail = st.ok ? "HTTP \(st.code) · \(st.latencyMs) ms" : (st.error ?? "HTTP \(st.code)")
                    if let exp = SiteStore.certExpiry(for: url) {
                        let days = Int(exp.timeIntervalSinceNow / 86400)
                        detail += " · SSL \(days) hari"
                        if days < 14 && h == .healthy { out.append(HealthSignal(kind: .domain, ref: l.ref + "#ssl", label: l.ref, health: .degraded, detail: "SSL habis \(days) hari lagi", collectedAt: st.checkedAt)) }
                    }
                    out.append(HealthSignal(kind: .domain, ref: l.ref, label: l.ref, health: h, detail: detail, collectedAt: st.checkedAt))
                } else {
                    out.append(HealthSignal(kind: .domain, ref: l.ref, label: l.ref, health: .unknown, detail: "Belum dicek", collectedAt: nil))
                }
            case .app:
                let at = mon.apps.first { $0.id == l.ref }.flatMap { $0.node }.flatMap { mon.detail[$0]?.at } ?? (mon.apps.contains { $0.id == l.ref } ? Date() : nil)
                if let st = mon.appStatus[l.ref] {
                    let h: OpsHealth = st.run == .running ? .healthy : st.run == .issue ? .degraded : st.run == .stopped ? .down : .unknown
                    out.append(HealthSignal(kind: .app, ref: l.ref, label: l.label.isEmpty ? l.ref : l.label, health: fresh(at) || h == .unknown ? h : .stale,
                                            detail: st.issues.first ?? st.run.rawValue, collectedAt: at))
                } else {
                    out.append(HealthSignal(kind: .app, ref: l.ref, label: l.label.isEmpty ? l.ref : l.label, health: .unknown, detail: "Tidak ditemukan di Monitor", collectedAt: nil))
                }
            case .node:
                let d = mon.detail[l.ref]
                let h: OpsHealth = d == nil ? .unknown : d?.error != nil ? .down : !fresh(d?.at) ? .stale : .healthy
                let s = mon.history[l.ref]?.last
                out.append(HealthSignal(kind: .node, ref: l.ref, label: l.label.isEmpty ? l.ref : l.label, health: h,
                                        detail: d?.error ?? s.map { "CPU \(Int($0.cpu * 100))% · RAM \(Int($0.mem * 100))% · disk \(Int($0.disk * 100))%" } ?? "Belum ada data",
                                        collectedAt: d?.at))
            case .compose, .service:
                let parts = l.ref.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let d = mon.detail[parts[0]] else {
                    out.append(HealthSignal(kind: l.kind, ref: l.ref, label: l.label, health: .unknown, detail: "Belum ada data", collectedAt: nil)); continue
                }
                if l.kind == .compose {
                    let cs = d.containers.filter { $0.project == parts[1] || $0.name == parts[1] }
                    let bad = cs.filter { !$0.healthy }
                    let h: OpsHealth = cs.isEmpty ? .unknown : !fresh(d.at) ? .stale : bad.count == cs.count ? .down : !bad.isEmpty ? .degraded : cs.contains { $0.restarts > 3 } ? .degraded : .healthy
                    out.append(HealthSignal(kind: .compose, ref: l.ref, label: l.label.isEmpty ? parts[1] : l.label, health: h,
                                            detail: cs.isEmpty ? "Container tidak ditemukan" : "\(cs.count - bad.count)/\(cs.count) container sehat", collectedAt: d.at))
                } else {
                    let sv = d.services.first { $0.unit == parts[1] || $0.name == parts[1] }
                    let h: OpsHealth = sv == nil ? .unknown : !fresh(d.at) ? .stale : sv!.running ? .healthy : .down
                    out.append(HealthSignal(kind: .service, ref: l.ref, label: l.label.isEmpty ? parts[1] : l.label, health: h,
                                            detail: sv.map { "\($0.state) (\($0.sub))" } ?? "Service tidak ditemukan", collectedAt: d.at))
                }
            case .vercel:
                if let v = VercelStore.shared.projects.first(where: { $0.id == l.ref }) {
                    let h: OpsHealth = v.state == "READY" ? .healthy : v.state == "ERROR" ? .down : v.state == nil ? .unknown : .degraded
                    out.append(HealthSignal(kind: .vercel, ref: l.ref, label: v.name, health: h, detail: "Deploy produksi: \(v.state ?? "–")", collectedAt: VercelStore.shared.loadedAt))
                } else {
                    out.append(HealthSignal(kind: .vercel, ref: l.ref, label: l.label, health: .unknown,
                                            detail: VercelStore.shared.hasToken ? "Project tidak terlihat oleh token" : "Vercel belum terhubung", collectedAt: nil))
                }
            case .n8n:
                if let e = N8nStore.shared.errors[l.ref] {
                    out.append(HealthSignal(kind: .n8n, ref: l.ref, label: l.label, health: .down, detail: e, collectedAt: nil))
                } else if let wf = N8nStore.shared.workflows[l.ref] {
                    let failing = wf.filter { $0.errors > 0 }.count
                    out.append(HealthSignal(kind: .n8n, ref: l.ref, label: l.label, health: failing > 0 ? .degraded : .healthy, detail: "\(wf.filter(\.active).count) workflow aktif · \(failing) error 24j", collectedAt: Date()))
                } else {
                    out.append(HealthSignal(kind: .n8n, ref: l.ref, label: l.label, health: .unknown, detail: "Belum ada data", collectedAt: nil))
                }
            case .job:
                let parts = l.ref.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let d = mon.detail[parts[0]], let job = d.jobs.first(where: { $0.id == parts[1] }) else {
                    out.append(HealthSignal(kind: .job, ref: l.ref, label: l.label, health: .unknown, detail: "Job tidak ditemukan", collectedAt: nil)); continue
                }
                let h: OpsHealth = !fresh(d.at) ? .stale : job.health == .failed ? .down : job.health == .missed ? .degraded : job.health == .ok || job.health == .running || job.health == .scheduled ? .healthy : .unknown
                out.append(HealthSignal(kind: .job, ref: l.ref, label: job.name, health: h,
                                        detail: "\(job.health.rawValue) · \(job.scheduleText)\(job.last.map { " · terakhir " + $0.ago } ?? "")\(job.detail.isEmpty ? "" : " · " + job.detail)", collectedAt: d.at))
            case .repo, .local, .githubProject:
                continue      // development, not operations
            }
        }
        let ops = out.isEmpty ? OpsHealth.unknown : aggregate(out.map(\.health))
        return ProjectHealthReport(ops: ops, signals: out.sorted { $0.health > $1.health }, lastCollected: out.compactMap(\.collectedAt).max(), hasOperationalResources: !out.isEmpty)
    }

    /// Worst signal wins; "healthy" needs at least one healthy signal and nothing worse.
    nonisolated static func aggregate(_ hs: [OpsHealth]) -> OpsHealth {
        guard !hs.isEmpty else { return .unknown }
        if hs.allSatisfy({ $0 == .down }) { return .down }
        if hs.contains(.down) || hs.contains(.degraded) { return .degraded }
        if hs.contains(.stale) { return .stale }
        if hs.contains(.unknown) { return .unknown }        // partly unmeasured is not "healthy"
        return .healthy
    }
}
