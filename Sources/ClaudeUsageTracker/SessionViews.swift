import AppKit
import Charts
import SwiftUI
import UsageCore

// MARK: Palette

/// One accent for live values; everything else is gray on near-black.
enum Meter {
    static let accent = Color(red: 0.36, green: 0.92, blue: 0.78)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.28)
    static let rule = Color.white.opacity(0.10)
    static let background = LinearGradient(
        colors: [Color(white: 0.085), Color(white: 0.045)],
        startPoint: .top, endPoint: .bottom
    )

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Tiny letterspaced uppercase label.
private struct MicroLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Meter.mono(9, .medium))
            .tracking(1.4)
            .foregroundStyle(Meter.faint)
    }
}

/// Blurred desktop behind a dark tint, so the numbers stay readable while the window is see-through.
struct GlassBackground: View {
    /// True for the standalone window; false inside the menu bar dropdown, which macOS pins in place.
    var inWindow: Bool
    @AppStorage("glassOpacity") private var tint = 0.45

    var body: some View {
        ZStack {
            VisualEffect()
            Meter.background.opacity(tint)
            if inWindow { DragArea() }
        }
        .background { if inWindow { WindowTransparency() } }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Lets the blur show through the window and hides the title bar chrome.
private struct WindowTransparency: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }

    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Keeps the window above other windows while `floating` is on.
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}

/// Fills the panel behind its content, so dragging any empty spot moves the window.
private struct DragArea: NSViewRepresentable {
    final class Area: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// A collapsible section: click the header to open or close it. The choice is remembered.
private struct Fold<Content: View>: View {
    let title: String
    @AppStorage private var open: Bool
    let content: Content

    init(_ title: String, key: String, open: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        _open = AppStorage(wrappedValue: open, key)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Meter.rule).frame(height: 1)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack {
                    MicroLabel(title)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Meter.faint)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content.padding(.bottom, 12)
            }
        }
    }
}

// MARK: Panel

/// The whole app: a compact meter, used both as the window and the menu bar dropdown.
struct MeterPanel: View {
    @EnvironmentObject private var model: TrackerModel
    @AppStorage("contextWindow") private var contextWindow = 200_000
    @AppStorage("usageScope") private var usageScope = UsageScope.today.rawValue
    @State private var query = ""
    @AppStorage("compact") private var compact = false
    @AppStorage("compactScope") private var compactScope = "all"
    var showsQuit = false
    @Environment(\.openWindow) private var openWindow

    private var sessions: [SessionSummary] {
        let order: [SessionState] = [.needsReply, .waitingOnTool, .working, .idle]
        return model.visibleSessions.sorted {
            let a = order.firstIndex(of: $0.state) ?? 0, b = order.firstIndex(of: $1.state) ?? 0
            return a != b ? a < b : ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// The last responses across every session, oldest first, for the sparkline.
    private var recentResponses: [MessageStat] {
        let timed = model.sessions.flatMap(\.messages).filter { $0.tokensPerSecond != nil }
        return Array(timed.sorted { $0.lastSeen < $1.lastSeen }.suffix(40))
    }

    /// Responses that finished in the last 60 seconds, across all sessions.
    private var lastMinute: [MessageStat] {
        let cutoff = Date().addingTimeInterval(-60)
        return model.sessions.flatMap(\.messages).filter { $0.lastSeen >= cutoff }
    }

    private var outputPerSecond: Double {
        Double(lastMinute.reduce(0) { $0 + $1.tokens.output }) / 60
    }

    private var byModel: [(model: String, rate: Double)] {
        Dictionary(grouping: lastMinute, by: { $0.model ?? "unknown" })
            .map { ($0.key, Double($0.value.reduce(0) { $0 + $1.tokens.output }) / 60) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .background(GlassBackground(inWindow: !showsQuit))
        .background(WindowLevel(floating: compact && !showsQuit))
        .environment(\.colorScheme, .dark)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow.padding(.bottom, 12)
            hero.padding(.bottom, 4)
            Sparkline(responses: recentResponses).frame(height: 36).padding(.bottom, 12)
            statusRow.padding(.bottom, 12)
            if model.agentsSeen.count > 1 {
                agentPicker.padding(.bottom, 12)
            }
            Fold("Sessions", key: "fold.sessions", open: true) { sessionList }
            Fold("Usage", key: "fold.usage", open: true) { usageSection }
            Fold("Models & limits", key: "fold.models") { topRow }
            Fold("Last minute", key: "fold.minute") {
                VStack(alignment: .leading, spacing: 16) { stats; modelList }
            }
            Fold("Context & mix", key: "fold.context") { usagePies }
            Fold("About this data", key: "fold.about") { footer }
        }
        .padding(16)
        .frame(width: 340, alignment: .topLeading)
    }

    private var agentPicker: some View {
        Picker("", selection: $model.agentFilter) {
            Text("All agents").tag("all")
            ForEach(model.agentsSeen, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    // MARK: Compact mode

    private func modeButton(_ symbol: String, _ help: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { compact.toggle() }
        } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Meter.dim)
        .help(help)
    }

    /// Just the numbers: today's totals across all sessions, or the most recent session.
    private var compactBody: some View {
        let latest = model.sessions.max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        let showLatest = compactScope == "latest"
        let tokens = showLatest ? latest.map { $0.tokens + $0.subagentTokens } ?? .zero : model.tokensToday
        let rate = showLatest ? latest?.recentTokensPerSecond : outputPerSecond
        let pct = { (value: Double?) in value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Picker("", selection: $compactScope) {
                    Text("All today").tag("all")
                    Text("Latest").tag("latest")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 130)
                Spacer()
                modeButton("arrow.up.left.and.arrow.down.right", "Show the full panel")
            }
            if showLatest {
                HStack(spacing: 6) {
                    if let latest { Circle().fill(latest.state.tint).frame(width: 6, height: 6) }
                    Text(latest?.title ?? "No sessions yet")
                        .font(.system(size: 11)).foregroundStyle(Meter.dim).lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                compactFigure(rate.map { String(format: "%.0f", $0) } ?? "–", showLatest ? "tok/s" : "tok/s · 60s", accent: true)
                compactFigure(TokenFormat.short(tokens.total), "tokens")
                compactFigure(pct(tokens.cacheHitRate), "cache hit")
            }
            HStack(alignment: .top, spacing: 0) {
                compactFigure(TokenFormat.short(tokens.output), "output")
                compactFigure(TokenFormat.short(tokens.thinking), "thinking")
                if showLatest {
                    compactFigure(latest?.state.label.lowercased() ?? "–", "state")
                } else {
                    compactFigure("\(model.activeSessions.count)", "active")
                }
            }
            if let refreshed = model.lastRefresh {
                Text("updated \(refreshed.formatted(date: .omitted, time: .shortened)) · every \(Int(model.refreshInterval))s")
                    .font(Meter.mono(9)).foregroundStyle(Meter.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 250, alignment: .topLeading)
    }

    private func compactFigure(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(accent ? Meter.accent : Meter.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(Meter.mono(8)).foregroundStyle(Meter.faint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Meter.accent).frame(width: 6, height: 6)
            Text("CLAUDE USAGE").font(Meter.mono(11, .semibold)).tracking(2).foregroundStyle(Meter.text)
            Spacer()
            MicroLabel("local")
            modeButton("arrow.down.right.and.arrow.up.left", "Shrink to a compact summary")
                .padding(.leading, 4)
            if showsQuit {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "sessions")
                } label: {
                    Image(systemName: "macwindow").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Meter.dim)
                .padding(.leading, 4)
                .help("Open as a window you can move anywhere")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Meter.dim)
                .padding(.leading, 6)
                .help("Quit")
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(format: "%.1f", outputPerSecond))
                .font(.system(size: 52, weight: .regular, design: .rounded))
                .foregroundStyle(Meter.accent)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 3) {
                Text("output tok/s").font(.system(size: 13, weight: .medium)).foregroundStyle(Meter.text)
                Text("60-second average").font(.system(size: 11)).foregroundStyle(Meter.dim)
            }
        }
    }

    private var statusRow: some View {
        let working = model.sessions.filter { $0.state == .working }.count
        let pending = model.sessions.filter { $0.state == .waitingOnTool }.count
        let waiting = model.sessions.filter { $0.state == .needsReply }.count
        var headline = "\(working) open turn\(working == 1 ? "" : "s")"
        if pending > 0 { headline += " · \(pending) tool pending" }
        if waiting > 0 { headline += " · \(waiting) waiting on you" }
        let latest = model.sessions.filter { $0.state != .idle }
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.system(size: 14, weight: .medium)).foregroundStyle(Meter.text)
                Text(latest?.title ?? "All quiet")
                    .font(.system(size: 11)).foregroundStyle(Meter.dim).lineLimit(1)
            }
            Spacer()
        }
    }

    private var stats: some View {
        let t = lastMinute.reduce(TokenCounts.zero) { $0 + $1.tokens }
        return HStack(alignment: .top, spacing: 0) {
            stat("Input / 60s", TokenFormat.short(t.input + t.cacheCreation + t.cacheRead))
            stat("Cached / 60s", TokenFormat.short(t.cacheRead))
            stat("Today", TokenFormat.short(model.tokensToday.total))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(label)
            Text(value).font(Meter.mono(22, .semibold)).foregroundStyle(Meter.text).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel("Output by model · last 60s")
            if byModel.isEmpty {
                Text("No output in the last minute").font(.system(size: 12)).foregroundStyle(Meter.dim)
            } else {
                ForEach(byModel, id: \.model) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.model).font(.system(size: 14, weight: .medium)).foregroundStyle(Meter.text)
                        Spacer()
                        Text(String(format: "%.1f/s", row.rate))
                            .font(Meter.mono(14)).foregroundStyle(Meter.accent).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Pie charts

    /// The session whose context we show: the most recently active one that isn't idle.
    private var focusSession: SessionSummary? {
        let live = model.sessions.filter { $0.state != .idle }
        return (live.isEmpty ? model.sessions : live)
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
    }

    /// Tokens in the context of the session's latest main-chain request (measured).
    private func contextUsed(_ session: SessionSummary) -> Int {
        guard let last = session.messages.filter({ !$0.isSidechain }).max(by: { $0.lastSeen < $1.lastSeen }) else { return 0 }
        return last.tokens.input + last.tokens.cacheRead + last.tokens.cacheCreation
    }

    private var usagePies: some View {
        let today = model.tokensToday
        let mix: [(String, Int, Color)] = [
            ("Cache read", today.cacheRead, .white.opacity(0.35)),
            ("Cache write", today.cacheCreation, .white.opacity(0.2)),
            ("Input", today.input, .white.opacity(0.55)),
            ("Output", today.output, Meter.accent),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                if let session = focusSession {
                    let used = contextUsed(session)
                    let free = max(contextWindow - used, 0)
                    Donut(
                        title: "Context",
                        center: "\(Int((Double(used) / Double(contextWindow) * 100).rounded()))%",
                        slices: [("Used", used, used > contextWindow * 8 / 10 ? Color.orange : Meter.accent),
                                 ("Free", free, Color.white.opacity(0.08))],
                        caption: "\(TokenFormat.short(used)) of \(TokenFormat.short(contextWindow))"
                    )
                }
                Donut(
                    title: "Today's mix",
                    center: TokenFormat.short(today.total),
                    slices: mix,
                    caption: "no limit applies"
                )
            }
            Button {
                contextWindow = contextWindow == 200_000 ? 1_000_000 : 200_000
            } label: {
                Text("Context window: \(TokenFormat.short(contextWindow)) (your setting, click to switch; not in logs)")
                    .font(.system(size: 10)).foregroundStyle(Meter.faint)
            }
            .buttonStyle(.plain)
        }
    }

    private func missing(_ name: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11)).foregroundStyle(Meter.dim)
            Spacer()
            Text("not visible in logs").font(Meter.mono(10)).foregroundStyle(Meter.faint)
        }
    }

    // MARK: Top row: limits and model usage

    private static let modelColors: [Color] = [Meter.accent, .blue, .purple, .orange, .pink]

    /// Tokens per model since midnight (measured).
    private var modelUsageToday: [(String, Int, Color)] {
        let start = Calendar.current.startOfDay(for: Date())
        let grouped = Dictionary(grouping: model.sessions.flatMap(\.messages).filter { $0.lastSeen >= start },
                                 by: { $0.model ?? "unknown" })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.tokens.total }) }
            .sorted { $0.1 > $1.1 }
        return grouped.enumerated().map { ($1.0, $1.1, Self.modelColors[$0 % Self.modelColors.count]) }
    }

    private var topRow: some View {
        let models = modelUsageToday
        let total = max(models.reduce(0) { $0 + $1.1 }, 1)
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 6) {
                Chart(models.isEmpty ? [("none", 1, Color.white.opacity(0.08))] : models, id: \.0) { slice in
                    SectorMark(angle: .value(slice.0, slice.1), innerRadius: .ratio(0.7), angularInset: 1)
                        .foregroundStyle(slice.2)
                }
                .chartLegend(.hidden)
                .frame(width: 76, height: 76)
                MicroLabel("Model usage today")
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(models.prefix(4), id: \.0) { entry in
                    HStack(spacing: 6) {
                        Circle().fill(entry.2).frame(width: 6, height: 6)
                        Text(entry.0).font(.system(size: 11)).foregroundStyle(Meter.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int((Double(entry.1) / Double(total) * 100).rounded()))%")
                            .font(Meter.mono(11)).foregroundStyle(Meter.dim)
                    }
                }
                if models.isEmpty {
                    Text("No usage today").font(.system(size: 11)).foregroundStyle(Meter.dim)
                }
                Rectangle().fill(Meter.rule).frame(height: 1).padding(.vertical, 2)
                limitRow("Context", focusSession.map { "\(Int((Double(contextUsed($0)) / Double(contextWindow) * 100).rounded()))%" })
                limitRow("Session limit", nil)
                limitRow("Weekly limit", nil)
            }
        }
    }

    private func limitRow(_ name: String, _ value: String?) -> some View {
        HStack {
            Text(name).font(.system(size: 11)).foregroundStyle(Meter.dim)
            Spacer()
            if let value {
                Text(value).font(Meter.mono(11)).foregroundStyle(Meter.accent)
            } else {
                Text("not in logs").font(Meter.mono(10)).foregroundStyle(Meter.faint)
            }
        }
    }

    /// What the list shows: search results over every loaded session, or the usual list.
    private var listedSessions: [SessionSummary] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? sessions
            : Array(SessionSearch.rank(model.sessions, query: query).prefix(30))
    }

    private var sessionList: some View {
        let listed = listedSessions
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Meter.faint)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Meter.text)
                if searching {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Meter.faint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                MicroLabel(searching ? "\(listed.count) match\(listed.count == 1 ? "" : "es") · last 30 days"
                           : model.showIdle ? "All sessions · last 30 days" : "Active sessions")
                Spacer()
                if !searching {
                    Button(model.showIdle ? "Hide idle" : "Show idle") { model.showIdle.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Meter.faint)
                }
            }
            if listed.isEmpty {
                Text(searching ? "No sessions match" : "No active sessions")
                    .font(.system(size: 12)).foregroundStyle(Meter.dim)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(listed) { MeterRow(session: $0) }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: listed.count <= 5)
            }
        }
    }

    // MARK: Usage breakdown

    private var scope: UsageScope { UsageScope(rawValue: usageScope) ?? .today }

    /// Per-session tokens from responses inside the selected window, largest first.
    private var usageBySession: [(session: SessionSummary, tokens: TokenCounts, model: String?, last: Date)] {
        let start = scope.start
        return model.sessions.compactMap { session in
            let inWindow = session.messages.filter { $0.lastSeen >= start }
            guard let last = inWindow.map(\.lastSeen).max() else { return nil }
            let tokens = inWindow.reduce(TokenCounts.zero) { $0 + $1.tokens }
            let model = Dictionary(grouping: inWindow, by: { $0.model ?? "" })
                .max { $0.value.count < $1.value.count }?.key
            return (session, tokens, model?.isEmpty == false ? model : nil, last)
        }
        .sorted { $0.tokens.total > $1.tokens.total }
    }

    private var usageSection: some View {
        let rows = usageBySession
        let total = rows.reduce(TokenCounts.zero) { $0 + $1.tokens }
        let parts: [(String, Int, Color)] = [
            ("Input", total.input, .indigo),
            ("Output", total.output, Meter.accent),
            ("Cache write", total.cacheCreation, .orange),
            ("Cache read", total.cacheRead, .blue),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $usageScope) {
                ForEach(UsageScope.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            HStack(alignment: .top, spacing: 0) {
                stat("Sessions", "\(rows.count)")
                stat("Tokens", TokenFormat.short(total.total))
                stat("Cache hit", total.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            }

            StackedBar(parts: parts).frame(height: 6)

            VStack(spacing: 6) {
                ForEach(parts, id: \.0) { part in
                    breakdownRow(part.0, part.1, part.2)
                    if part.0 == "Output" {
                        breakdownRow("  of which thinking", total.thinking, nil)
                    }
                }
            }

            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        MicroLabel("By session")
                        Spacer()
                        MicroLabel("Tokens").frame(width: 52, alignment: .trailing)
                        MicroLabel("Hit").frame(width: 36, alignment: .trailing)
                        MicroLabel("Share").frame(width: 42, alignment: .trailing)
                    }
                    ForEach(rows.prefix(8), id: \.session.id) { row in
                        shareRow(row.session, row.tokens, row.model, row.last, of: total.total)
                    }
                }
            }
        }
    }

    private func breakdownRow(_ label: String, _ value: Int, _ color: Color?) -> some View {
        HStack(spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            } else {
                Color.clear.frame(width: 7, height: 7)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(color == nil ? Meter.faint : Meter.dim)
            Spacer()
            Text(TokenFormat.short(value)).font(Meter.mono(11))
                .foregroundStyle(color == nil ? Meter.dim : Meter.text).monospacedDigit()
        }
    }

    private func shareRow(_ session: SessionSummary, _ tokens: TokenCounts, _ model: String?, _ last: Date,
                          of total: Int) -> some View {
        let share = total > 0 ? Double(tokens.total) / Double(total) : 0
        return Button {
            SessionActions.resumeInTerminal(session)
        } label: {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Meter.text).lineLimit(1)
                    Text([model.map(ModelName.short), RelativeDateTimeFormatter.short.localizedString(for: last, relativeTo: Date())]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(Meter.faint).lineLimit(1)
                    GeometryReader { proxy in
                        Capsule().fill(Meter.accent.opacity(0.6))
                            .frame(width: max(2, proxy.size.width * share), height: 2)
                    }
                    .frame(height: 2)
                }
                Text(TokenFormat.short(tokens.total)).frame(width: 52, alignment: .trailing)
                Text(tokens.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–").frame(width: 36, alignment: .trailing)
                Text("\(Int((share * 100).rounded()))%").frame(width: 42, alignment: .trailing)
            }
            .font(Meter.mono(11))
            .foregroundStyle(Meter.dim)
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Resume in Terminal")
        .contextMenu { SessionMenuItems(session: session) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Refresh every").font(.system(size: 11)).foregroundStyle(Meter.dim)
                Spacer()
                Picker("", selection: $model.refreshInterval) {
                    ForEach([2.0, 5, 20, 60], id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 150)
            }
            .padding(.bottom, 6)
            Text("Local logs connected · \(model.sessions.count) sessions watched")
                .font(.system(size: 11)).foregroundStyle(Meter.accent.opacity(0.75))
            Text("Cloud + standalone API: not connected")
                .font(.system(size: 11)).foregroundStyle(Meter.dim)
            Text("Output counts arrive in batches and include time to first token. This is observed throughput, not generation speed. Click a session to resume it.")
                .font(.system(size: 10)).foregroundStyle(Meter.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
}

enum UsageScope: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    var start: Date {
        let today = Calendar.current.startOfDay(for: Date())
        switch self {
        case .today: return today
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }
}

enum ModelName {
    /// "claude-opus-5-5" -> "Opus 5.5"
    static func short(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        return ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }
}

/// One thin bar split by share.
private struct StackedBar: View {
    let parts: [(String, Int, Color)]

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.1 }, 1)
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                    Rectangle().fill(part.2)
                        .frame(width: max(1, proxy.size.width * CGFloat(part.1) / CGFloat(total) - 1))
                }
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }
}

private struct Donut: View {
    let title: String
    let center: String
    let slices: [(String, Int, Color)]
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            Chart(slices, id: \.0) { slice in
                SectorMark(angle: .value(slice.0, max(slice.1, 0)), innerRadius: .ratio(0.72), angularInset: 1)
                    .foregroundStyle(slice.2)
            }
            .chartLegend(.hidden)
            .frame(width: 90, height: 90)
            .overlay {
                Text(center).font(Meter.mono(15, .semibold)).foregroundStyle(Meter.text)
            }
            VStack(spacing: 2) {
                MicroLabel(title)
                Text(caption).font(.system(size: 10)).foregroundStyle(Meter.dim)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MeterRow: View {
    let session: SessionSummary
    @State private var hovering = false

    private var qualifier: String {
        var parts = [session.state.label.lowercased(), session.projectName]
        if session.agent != .claude { parts.insert(session.agent.label.lowercased(), at: 0) }
        if let last = session.lastActivity {
            parts.append(RelativeDateTimeFormatter.short.localizedString(for: last, relativeTo: Date()))
        }
        parts.append(TokenFormat.short((session.tokens + session.subagentTokens).total))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            SessionActions.resumeInTerminal(session)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if session.state == .needsReply || session.state == .waitingOnTool {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                        }
                        Text(session.title).lineLimit(1).foregroundStyle(Meter.text)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Text(qualifier).font(Meter.mono(10)).foregroundStyle(Meter.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(session.recentTokensPerSecond.map { "\(Int($0))" } ?? "–")
                    .font(Meter.mono(13))
                    .foregroundStyle(session.state == .working ? Meter.accent : Meter.dim)
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(hovering ? Color.white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help("Resume in Terminal")
        .contextMenu { SessionMenuItems(session: session) }
    }
}

/// Stepped line of per-response speed, no axes.
private struct Sparkline: View {
    let responses: [MessageStat]

    var body: some View {
        if responses.count < 2 {
            Rectangle().fill(Meter.rule).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            Chart(Array(responses.enumerated()), id: \.offset) { index, message in
                AreaMark(x: .value("n", index), y: .value("tok/s", message.tokensPerSecond ?? 0))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(LinearGradient(
                        colors: [Meter.accent.opacity(0.22), Meter.accent.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("n", index), y: .value("tok/s", message.tokensPerSecond ?? 0))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Meter.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }
}

extension RelativeDateTimeFormatter {
    static let short: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct SessionMenuItems: View {
    let session: SessionSummary

    var body: some View {
        Button("Resume in Terminal") { SessionActions.resumeInTerminal(session) }
        if session.agent == .claude {
            Button("Open Folder in Claude Desktop") { SessionActions.openInClaudeDesktop(session) }
        }
        Divider()
        Button("Copy Resume Command") { SessionActions.copyResumeCommand(session) }
        Button("Copy Session ID") { SessionActions.copySessionId(session) }
        Button("Reveal Log in Finder") { SessionActions.revealLog(session) }
    }
}

extension SessionState {
    var tint: Color {
        switch self {
        case .working: return Meter.accent
        case .needsReply: return .orange
        case .waitingOnTool: return .yellow
        case .idle: return .gray
        }
    }
}
