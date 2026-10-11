import SwiftUI

/// Monitor → Jobs: every scheduled job per device with its last result and next run.
struct JobsTab: View {
    let scope: [RNode]
    @ObservedObject private var mon = MonitorStore.shared
    @ObservedObject private var ws = WorkspaceStore.shared
    @AppStorage("raphaelJobsShowSystem") private var showSystem = false
    @State private var query = ""
    @State private var open: Set<String> = []
    @State private var onlyProblems = false

    var body: some View {
        let all = scope.flatMap { n in (mon.detail[n.id]?.jobs ?? []).map { (n, $0) } }
        let visible = all.filter { (showSystem || !$0.1.system || $0.1.health == .failed) && (!onlyProblems || [.failed, .missed].contains($0.1.health))
            && (query.isEmpty || $0.1.name.localizedCaseInsensitiveContains(query) || $0.1.command.localizedCaseInsensitiveContains(query)) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                let failed = all.filter { $0.1.health == .failed }.count, missed = all.filter { $0.1.health == .missed && !$0.1.system }.count
                Label("\(failed) gagal", systemImage: "clock.badge.xmark").foregroundStyle(failed > 0 ? RTheme.red : RTheme.muted)
                Label("\(missed) terlewat", systemImage: "clock.badge.exclamationmark").foregroundStyle(missed > 0 ? RTheme.amber : RTheme.muted)
                Text("\(all.filter { !$0.1.system }.count) job aplikasi · \(all.filter(\.1.system).count) job sistem").foregroundStyle(RTheme.muted)
                Spacer()
                TextField("Cari job…", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("Hanya bermasalah", isOn: $onlyProblems).toggleStyle(.checkbox).fixedSize()
                Toggle("Job sistem", isOn: $showSystem).toggleStyle(.checkbox).fixedSize().help("Housekeeping distro: logrotate, apt, e2scrub, sysstat…")
            }
            .font(.system(size: 12))
            if all.isEmpty {
                RCard(padding: 20) {
                    EmptyStateView(icon: "clock", title: "Belum ada data job",
                                   message: "Raphael membaca crontab, /etc/cron.d, systemd timer, launchd agent terjadwal dan cron Hermes di setiap device saat sampling.")
                }
            }
            ForEach(scope) { n in
                let jobs = visible.filter { $0.0.id == n.id }.map(\.1).sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
                if !jobs.isEmpty {
                    RCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(n.name).font(.system(size: 14, weight: .bold))
                                if let at = mon.detail[n.id]?.at { Text("diperbarui " + at.ago).font(.system(size: 10.5)).foregroundStyle(RTheme.muted) }
                                Spacer()
                            }
                            .padding(.bottom, 8)
                            HStack {
                                Text("Job").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Jadwal").frame(width: 170, alignment: .leading)
                                Text("Terakhir").frame(width: 110, alignment: .leading)
                                Text("Berikutnya").frame(width: 110, alignment: .leading)
                                Text("Status").frame(width: 110, alignment: .leading)
                            }
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(RTheme.muted).padding(.vertical, 4)
                            ForEach(jobs) { j in row(n, j); Divider().overlay(RTheme.line) }
                        }
                    }
                }
            }
            Text("Status cron dibaca dari journal (`CMD`), lalu dari file log bila baris cron menulis ke log (baris terakhir berisi error/failed → Gagal). Timer: hasil systemd. launchd: exit code terakhir. Hermes: status job & riwayat eksekusi. \"Terlewat\" = jadwal menunjukkan job harusnya sudah jalan setelah run terakhir.")
                .font(.system(size: 10.5)).foregroundStyle(RTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rank(_ j: MJob) -> Int { [.failed: 0, .missed: 1, .running: 2, .unknown: 3, .scheduled: 4, .ok: 5, .disabled: 6][j.health] ?? 9 }

    private func color(_ h: MJob.Health) -> Color {
        switch h { case .ok: RTheme.green; case .failed: RTheme.red; case .missed: RTheme.amber; case .running, .scheduled: RTheme.blue; case .disabled, .unknown: RTheme.muted }
    }

    private func row(_ n: RNode, _ j: MJob) -> some View {
        let key = n.id + "|" + j.id
        let expanded = open.contains(key)
        let linked = ws.links.filter { $0.kind == .job && $0.ref == key }
        return VStack(alignment: .leading, spacing: 6) {
            Button { if expanded { open.remove(key) } else { open.insert(key) } } label: {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: j.kind.icon).foregroundStyle(RTheme.violet).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(j.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                if j.system { RChip(text: "sistem", tint: RTheme.muted) }
                                ForEach(linked) { l in if let p = ws.projects.first(where: { $0.id == l.projectId }) { RChip(text: p.name, tint: RTheme.violet) } }
                            }
                            Text(j.detail.isEmpty ? j.command : j.detail).font(.system(size: 10.5, design: j.detail.isEmpty ? .monospaced : .default))
                                .foregroundStyle(j.health == .failed && !j.detail.isEmpty ? RTheme.red : RTheme.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(j.scheduleText).font(.system(size: 11.5)).lineLimit(1).frame(width: 170, alignment: .leading)
                    Text(j.last?.ago ?? "–").font(.system(size: 11.5)).foregroundStyle(RTheme.ink2).lineLimit(1).frame(width: 110, alignment: .leading)
                    Text(j.next.map { $0 > Date() ? Self.relative($0) : "lewat " + $0.ago } ?? "–").font(.system(size: 11.5))
                        .foregroundStyle(j.next.map { $0 < Date().addingTimeInterval(-900) } ?? false ? RTheme.amber : RTheme.ink2).lineLimit(1).frame(width: 110, alignment: .leading)
                    HStack(spacing: 5) { Circle().fill(color(j.health)).frame(width: 7, height: 7); Text(j.health.rawValue) }
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color(j.health)).frame(width: 110, alignment: .leading)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { details(n, j, key) }
        }
    }

    private func details(_ n: RNode, _ j: MJob, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            kv("Jenis", j.kind.title + (j.source.isEmpty ? "" : " · \(j.source)") + (j.user.isEmpty ? "" : " · user \(j.user)"))
            if !j.expr.isEmpty { kv("Ekspresi", j.expr + (j.expectedLast.map { " · seharusnya terakhir \(WFormat.date($0)) \($0.formatted(date: .omitted, time: .shortened))" } ?? "")) }
            if !j.command.isEmpty { kv("Perintah", j.command, mono: true) }
            if !j.workdir.isEmpty { kv("Folder", j.workdir, mono: true) }
            if let log = j.log { kv("Log", log + (j.logModified.map { " · diubah \($0.ago)" } ?? ""), mono: true) }
            if j.failureStreak > 0 { kv("Gagal beruntun", "\(j.failureStreak)×") }
            if !j.history.isEmpty {
                RLabel(text: "Eksekusi terakhir")
                ForEach(Array(j.history.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 8) {
                        Circle().fill(r.status == "failed" || r.status == "error" ? RTheme.red : r.status == "running" ? RTheme.blue : RTheme.green).frame(width: 6, height: 6)
                        Text(r.started.map { "\(WFormat.date($0)) \($0.formatted(date: .omitted, time: .shortened))" } ?? "–").font(.system(size: 11, design: .monospaced)).frame(width: 150, alignment: .leading)
                        Text(r.status).font(.system(size: 11)).frame(width: 60, alignment: .leading)
                        if let s = r.started, let f = r.finished { Text(MonitorPage.duration(f.timeIntervalSince(s))).font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 60, alignment: .leading) }
                        Text(r.error).font(.system(size: 11)).foregroundStyle(RTheme.red).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 8) {
                if let log = j.log {
                    Button("Buka log di File") {
                        UserDefaults.standard.set(n.id, forKey: "raphaelFilesNode")
                        UserDefaults.standard.set((log as NSString).deletingLastPathComponent, forKey: "raphaelFilesOpenPath")
                        UserDefaults.standard.set(CCSection.files.rawValue, forKey: "raphaelCCSection")
                    }.buttonStyle(RPillButton())
                }
                Menu("Tautkan ke project…") {
                    ForEach(ws.projects.filter { $0.lifecycle != .archived }) { p in
                        Button(p.name) { ws.addLink(p.id, kind: .job, ref: key, label: j.name, environment: "production") }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(ws.projects.isEmpty)
                Spacer()
            }
        }
        .padding(10)
        .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 6)
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundStyle(RTheme.muted).frame(width: 100, alignment: .leading)
            Text(v).font(.system(size: 11.5, design: mono ? .monospaced : .default)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    static func relative(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s < 3600 { return "\(Int(s / 60)) menit lagi" }
        if s < 86400 { return "\(Int(s / 3600)) jam lagi" }
        return "\(Int(s / 86400)) hari lagi"
    }
}
