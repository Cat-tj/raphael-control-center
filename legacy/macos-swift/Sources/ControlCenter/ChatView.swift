import SwiftUI

/// Claude-Code-style chat: history on the left, the transcript with tool calls
/// and subagents in the middle, the token breakdown on the right.
struct ChatPage: View {
    @ObservedObject private var agent = RaphaelAgent.shared
    @State private var draft = ""
    @State private var showInspector = true

    var body: some View {
        HStack(spacing: 0) {
            ChatHistoryList()
                .frame(width: 270)
            Rectangle().fill(RTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(RTheme.line).frame(height: 1)
                TranscriptView()
                composer
            }
            .background(RTheme.surface)
            if showInspector {
                Rectangle().fill(RTheme.line).frame(width: 1)
                TokenInspector().frame(width: 300)
            }
        }
        .onAppear { agent.reloadList(); if agent.selectedId != nil { agent.reloadTranscript() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.transcript.session?.title ?? (agent.running ? "Sesi baru…" : "Chat baru"))
                    .font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let s = agent.transcript.session {
                        RChip(text: s.source, tint: RTheme.ink2)
                        Text(s.model).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted)
                        Text("· \(s.messages) pesan · \(s.toolCalls) tool call").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                    } else {
                        Text("Hermes di \(agent.deviceName(agent.chatDeviceId)) · tools, memory, skills, subagent").font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
                    }
                }
            }
            Spacer()
            if agent.running {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("bekerja…").font(.system(size: 12)).foregroundStyle(RTheme.violet) }
                Button("Stop") { agent.stop() }.buttonStyle(RPillButton())
            }
            Button { agent.reloadTranscript() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(RTheme.muted)
            Button { withAnimation { showInspector.toggle() } } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).foregroundStyle(showInspector ? RTheme.violet : RTheme.muted).help("Rincian token")
        }
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = agent.lastError {
                Text(e).font(.system(size: 11.5)).foregroundStyle(RTheme.red).lineLimit(4)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(agent.selectedId == nil ? "Mulai chat baru dengan Raphael…" : "Lanjutkan sesi ini…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...8).font(.system(size: 13.5))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(canSend ? RTheme.violet : RTheme.violet.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(RTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(RTheme.violet.opacity(0.35)))
            .shadow(color: RTheme.shadow.opacity(0.07), radius: 10, y: 4)
            HStack {
                if agent.selectedId == nil && DeviceContext.shared.hermesNodes.count > 1 {
                    Picker("Kirim ke", selection: $agent.chatDeviceId) {
                        ForEach(DeviceContext.shared.hermesNodes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 170).controlSize(.small)
                }
                Text(agent.selectedId == nil ? "Pesan pertama membuat sesi baru di \(agent.deviceName(agent.chatDeviceId))" : "↩︎ kirim · lanjut di sesi \(agent.selectedId!.prefix(15)) (\(agent.deviceName(agent.chatDeviceId)))")
                Spacer()
                if let u = agent.lastUsage { Text("terakhir: \(u)") }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(RTheme.canvas)
    }

    private var canSend: Bool { !agent.running && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func send() { guard canSend else { return }; let t = draft; draft = ""; agent.send(t) }
}

// MARK: - History

struct ChatHistoryList: View {
    @ObservedObject private var agent = RaphaelAgent.shared
    private let sources = ["", "oneshot", "cli", "desktop", "whatsapp", "webui", "cron"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Riwayat").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { agent.newChat() } label: { Label("Baru", systemImage: "square.and.pencil") }
                    .buttonStyle(RPillButton(primary: true)).controlSize(.small)
            }
            .padding(.top, 30)
            TextField("Cari chat…", text: $agent.search).textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(sources, id: \.self) { s in
                        Button(s.isEmpty ? "Semua" : s) { agent.sourceFilter = s }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(agent.sourceFilter == s ? RTheme.violetSoft : RTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(agent.sourceFilter == s ? .clear : RTheme.line))
                            .foregroundStyle(agent.sourceFilter == s ? RTheme.violet : RTheme.ink2)
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(grouped, id: \.0) { day, rows in
                        RLabel(text: day).padding(.top, 10).padding(.bottom, 2).padding(.horizontal, 8)
                        ForEach(rows) { r in row(r) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(RTheme.canvas)
    }

    private var grouped: [(String, [HermesSessionRow])] {
        let cal = Calendar.current
        var out: [(String, [HermesSessionRow])] = []
        for r in agent.sessions {
            let key = cal.isDateInToday(r.when) ? "Hari ini" : cal.isDateInYesterday(r.when) ? "Kemarin"
                : r.when.formatted(.dateTime.day().month(.abbreviated))
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(r) } else { out.append((key, [r])) }
        }
        return out
    }

    private func row(_ r: HermesSessionRow) -> some View {
        let selected = agent.selectedId == r.id
        return Button { agent.select(r.id, device: r.device) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if agent.isRunning(r.id) { ProgressView().controlSize(.mini).help("Raphael sedang mengerjakan chat ini") }
                    else if r.active && Date().timeIntervalSince(r.when) < 1800 { RStatusDot(color: RTheme.mint, size: 6) }
                    Text(r.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if DeviceContext.shared.isAll { Text(agent.deviceName(r.device)).font(.system(size: 10, weight: .semibold)).foregroundStyle(RTheme.violet) }
                    Text(r.source).font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text("· \(r.totalTokens.compact) tok")
                    Spacer()
                    Text(r.when.formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 10.5)).foregroundStyle(RTheme.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? RTheme.violet.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @ObservedObject private var agent = RaphaelAgent.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if agent.transcript.items.isEmpty && agent.pendingPrompt == nil {
                        emptyState
                    }
                    ForEach(agent.transcript.items) { item in
                        TranscriptItemView(item: item, children: agent.transcript.children, depth: 0).id(item.id)
                    }
                    if let p = agent.pendingPrompt {
                        UserBubble(text: p)
                    }
                    if agent.running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Raphael sedang bekerja… (tool call dan subagent muncul di sini)").font(.system(size: 12.5)).foregroundStyle(RTheme.muted)
                        }
                        .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: agent.transcript.items.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: agent.selectedId) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mau Raphael kerjakan apa?").font(.system(size: 22, weight: .heavy)).tracking(-0.6)
            Text("Agent penuh dengan tools, memory, skills dan subagent. Semua langkahnya tampil di sini, seperti Claude Code.")
                .font(.system(size: 13)).foregroundStyle(RTheme.muted)
            ForEach(["Cek kenapa cron tadi gagal dan perbaiki", "Ringkas status semua server dan aplikasi", "Kenapa token Hermes boros minggu ini?"], id: \.self) { s in
                Button { RaphaelAgent.shared.send(s) } label: {
                    HStack { Image(systemName: "sparkles").foregroundStyle(RTheme.violet); Text(s).foregroundStyle(RTheme.ink2) }
                        .font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RTheme.canvas, in: Capsule()).overlay(Capsule().stroke(RTheme.line))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 60)
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("›").font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(RTheme.violet)
            Text(text).font(.system(size: 13.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RTheme.violetSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TranscriptItemView: View {
    let item: HTranscriptItem
    let children: [HermesSessionRow]
    let depth: Int
    @State private var showReasoning = false

    var body: some View {
        switch item.kind {
        case .user:
            UserBubble(text: item.text)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let r = item.reasoning {
                    Button { showReasoning.toggle() } label: {
                        HStack(spacing: 6) {
                            Text("∴").font(.system(size: 13, weight: .bold))
                            Text("Thinking").font(.system(size: 12, weight: .medium))
                            Image(systemName: showReasoning ? "chevron.down" : "chevron.right").font(.system(size: 9))
                        }
                        .foregroundStyle(RTheme.muted)
                    }
                    .buttonStyle(.plain)
                    if showReasoning {
                        Text(r).font(.system(size: 12)).italic().foregroundStyle(RTheme.muted).textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }
                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(RTheme.navy).frame(width: 7, height: 7).padding(.top, 6)
                        Text(LocalizedStringKey(item.text)).font(.system(size: 13.5)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(item.tools) { call in
                    ToolCallView(call: call, children: children, at: item.at, depth: depth)
                }
            }
        case .system:
            EmptyView()
        }
    }
}

struct ToolCallView: View {
    let call: HToolCall
    let children: [HermesSessionRow]
    let at: Date
    let depth: Int
    @State private var open = false
    @ObservedObject private var agent = RaphaelAgent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(call.result == nil ? RTheme.amber : RTheme.mint).frame(width: 7, height: 7)
                    Text(displayName).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    Text(summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.ink2).lineLimit(1)
                    Spacer(minLength: 6)
                    if call.resultTokens > 0 {
                        Text("\(call.resultTokens.compact) tok").font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(call.resultTokens > 5_000 ? RTheme.red : RTheme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if call.isSubagent {
                subagents
            } else if let result = call.result {
                HStack(alignment: .top, spacing: 6) {
                    Text("⎿").font(.system(size: 12, design: .monospaced)).foregroundStyle(RTheme.muted)
                    Text(open ? String(result.prefix(6000)) : preview(result))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RTheme.muted)
                        .textSelection(.enabled).lineLimit(open ? nil : 2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 15)
            } else {
                Text("⎿  berjalan…").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RTheme.amber).padding(.leading, 15)
            }
            if open && !call.isSubagent {
                Text(call.arguments).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.ink2)
                    .textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 15)
            }
        }
    }

    private var displayName: String {
        switch call.name {
        case "terminal": "Bash"
        case "read_file": "Read"
        case "patch", "write_file": "Edit"
        case "search_files": "Search"
        case "delegate_task": "Subagent"
        case "skill_view": "Skill"
        case "web_search": "WebSearch"
        case "web_extract": "WebFetch"
        default: call.name
        }
    }

    private var args: [String: Any] {
        (call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private var summary: String {
        let a = args
        for k in ["command", "path", "file_path", "query", "pattern", "url", "name", "action", "goal"] {
            if let v = a[k] as? String { return "(\(v.replacingOccurrences(of: "\n", with: " ")))" }
        }
        if let tasks = a["tasks"] as? [[String: Any]] { return "(\(tasks.count) tugas)" }
        return call.arguments.isEmpty ? "" : "(\(call.arguments.prefix(80)))"
    }

    private func preview(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(t.prefix(220))
    }

    /// Subagents spawned by this delegate_task: the child sessions started right after the call.
    @ViewBuilder private var subagents: some View {
        let goals = (args["tasks"] as? [[String: Any]] ?? []).compactMap { $0["goal"] as? String }
        let kids = children.filter { $0.startedAt >= at.addingTimeInterval(-5) }.prefix(max(goals.count, 1))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(kids.enumerated()), id: \.element.id) { i, kid in
                let expanded = agent.children[kid.id] != nil
                VStack(alignment: .leading, spacing: 6) {
                    Button { agent.toggleChild(kid.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.fill").font(.system(size: 11)).foregroundStyle(RTheme.violet)
                            Text(i < goals.count ? goals[i] : kid.title).font(.system(size: 12.5, weight: .medium)).lineLimit(expanded ? 4 : 1)
                            Spacer(minLength: 6)
                            RChip(text: kid.active && Date().timeIntervalSince(kid.when) < 600 ? "berjalan" : "selesai",
                                  tint: kid.active && Date().timeIntervalSince(kid.when) < 600 ? RTheme.amber : RTheme.green)
                            Text("\(kid.toolCalls) tool · \(kid.totalTokens.compact)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(RTheme.muted)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(RTheme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if let t = agent.children[kid.id] {
                        VStack(alignment: .leading, spacing: 10) {
                            if t.items.isEmpty { ProgressView().controlSize(.small) }
                            ForEach(t.items.filter { $0.kind != .user || depth > 0 }) { item in
                                TranscriptItemView(item: item, children: t.children, depth: depth + 1)
                            }
                        }
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Rectangle().fill(RTheme.violet.opacity(0.25)).frame(width: 2) }
                    }
                }
                .padding(10)
                .background(RTheme.violetSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if kids.isEmpty {
                ForEach(goals, id: \.self) { g in
                    Text("⎿ \(g)").font(.system(size: 11.5)).foregroundStyle(RTheme.muted).lineLimit(2)
                }
            }
        }
        .padding(.leading, 15)
    }
}

// MARK: - Token inspector

struct TokenInspector: View {
    @ObservedObject private var agent = RaphaelAgent.shared

    var body: some View {
        let t = agent.transcript
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rincian token").font(.system(size: 15, weight: .bold)).padding(.top, 30)
                if let s = t.session {
                    VStack(alignment: .leading, spacing: 6) {
                        RLabel(text: "Total sesi")
                        Text(s.totalTokens.formatted()).font(.system(size: 26, weight: .heavy)).tracking(-0.8)
                        row("Input baru", s.input)
                        row("Cache read", s.cacheRead)
                        row("Output", s.output)
                        row("Panggilan API", s.apiCalls, raw: true)
                        row("Konteks / panggilan", s.contextPerCall, warn: s.contextPerCall > 50_000)
                        if s.cost > 0 { HStack { Text("Biaya"); Spacer(); Text(s.cost.usd).fontWeight(.semibold) }.font(.system(size: 12)) }
                    }

                    if !t.context.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                RLabel(text: "Isi konteks (estimasi)")
                                Spacer()
                                Text(t.contextTotal.compact).font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted)
                            }
                            RStackBar(parts: t.context.enumerated().map { (Double($1.tokens), RTheme.series($0)) }, height: 9)
                            legend(t.context, total: t.contextTotal)
                        }
                    }
                    if !t.tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            RLabel(text: "Token per tugas (ditagih)")
                            let total = t.tasks.reduce(0) { $0 + $1.tokens }
                            RStackBar(parts: t.tasks.enumerated().map { (Double($1.tokens), RTheme.series($0 + 3)) }, height: 9)
                            legend(t.tasks, total: total, offset: 3)
                        }
                    }
                    if !t.toolUse.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            RLabel(text: "Tool paling makan konteks")
                            let maxT = max(t.toolUse.first?.tokens ?? 1, 1)
                            ForEach(t.toolUse.prefix(8)) { p in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(p.name).font(.system(size: 12, design: .monospaced)); Spacer(); Text(p.tokens.compact).font(.system(size: 11.5, design: .monospaced)) }
                                    RGauge(value: Double(p.tokens) / Double(maxT), tint: RTheme.violet, height: 4)
                                }
                            }
                        }
                    }
                    if !t.children.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            RLabel(text: "Subagent (\(t.children.count))")
                            ForEach(t.children) { c in
                                HStack {
                                    Text(c.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(c.totalTokens.compact).font(.system(size: 11.5, design: .monospaced))
                                }
                            }
                            HStack {
                                Text("Total subagent").font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(t.children.reduce(0) { $0 + $1.totalTokens }.compact).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            }
                        }
                    }
                } else {
                    Text("Pilih sesi untuk melihat ke mana tokennya pergi.").font(.system(size: 12.5)).foregroundStyle(RTheme.muted)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 20)
        }
        .background(RTheme.canvas)
    }

    private func row(_ label: String, _ v: Int, raw: Bool = false, warn: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(RTheme.ink2)
            Spacer()
            Text(raw ? "\(v)" : v.compact).font(.system(size: 12, design: .monospaced)).foregroundStyle(warn ? RTheme.red : RTheme.navy)
        }
        .font(.system(size: 12))
    }

    private func legend(_ parts: [HBreakdownPart], total: Int, offset: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(RTheme.series(i + offset)).frame(width: 9, height: 9)
                    Text(p.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(p.tokens.compact).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(RTheme.ink2)
                    Text(String(format: "%.1f%%", Double(p.tokens) / Double(max(total, 1)) * 100))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(RTheme.muted).frame(width: 46, alignment: .trailing)
                }
            }
        }
    }
}
