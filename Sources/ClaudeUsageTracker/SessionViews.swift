import Charts
import SwiftUI
import UsageCore

// MARK: Main window

struct SessionsWindow: View {
    @EnvironmentObject private var model: TrackerModel
    @State private var selection: SessionSummary.ID?
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActivity, order: .reverse)]

    private var rows: [SessionRow] {
        model.visibleSessions.map(SessionRow.init).sorted(using: sortOrder)
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SummaryBar()
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("State", value: \.stateOrder) { row in
                        StateBadge(state: row.session.state)
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("Session", value: \.session.title) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.session.title).lineLimit(1)
                            Text(row.session.projectName + (row.session.gitBranch.map { " · \($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 220, ideal: 320)
                    TableColumn("Total", value: \.totalTokens) { row in
                        Text(TokenFormat.short(row.totalTokens)).monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Output", value: \.outputTokens) { row in
                        Text(TokenFormat.short(row.outputTokens)).monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Recent speed", value: \.recentRate) { row in
                        Text(TokenFormat.rate(row.session.recentTokensPerSecond)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Avg speed", value: \.averageRate) { row in
                        Text(TokenFormat.rate(row.session.averageTokensPerSecond)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Last activity", value: \.lastActivity) { row in
                        Text(row.lastActivity, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    .width(100)
                }
                .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
                    if let session = model.session(id: ids.first) {
                        SessionMenuItems(session: session)
                    }
                } primaryAction: { ids in
                    if let session = model.session(id: ids.first) {
                        SessionActions.resumeInTerminal(session)
                    }
                }
            }
            .frame(minHeight: 220)

            Group {
                if let session = model.session(id: selection) {
                    SessionDetail(session: session)
                } else {
                    Text("Select a session to see its responses. Double-click to resume it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)
        }
        .toolbar {
            Toggle("Show idle sessions", isOn: $model.showIdle)
            Toggle("Notify when Claude waits", isOn: $model.notifyOnNeedsReply)
        }
    }
}

/// Flattens a session into sortable values for the table.
struct SessionRow: Identifiable {
    let session: SessionSummary
    var id: String { session.id }
    var totalTokens: Int { (session.tokens + session.subagentTokens).total }
    var outputTokens: Int { (session.tokens + session.subagentTokens).output }
    var recentRate: Double { session.recentTokensPerSecond ?? 0 }
    var averageRate: Double { session.averageTokensPerSecond ?? 0 }
    var lastActivity: Date { session.lastActivity ?? .distantPast }
    var stateOrder: Int { SessionState.allCases.firstIndex(of: session.state) ?? 0 }
}

private struct SummaryBar: View {
    @EnvironmentObject private var model: TrackerModel

    var body: some View {
        let today = model.tokensToday
        HStack(spacing: 24) {
            Stat(title: "Active sessions", value: "\(model.activeSessions.count)")
            Stat(title: "Waiting on you", value: "\(model.needsAttentionCount)")
            Stat(title: "Live speed", value: TokenFormat.rate(model.liveTokensPerSecond))
            Stat(title: "Tokens today", value: TokenFormat.short(today.total))
            Stat(title: "Output today", value: TokenFormat.short(today.output))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StateBadge: View {
    let state: SessionState

    var body: some View {
        Label(state.label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var symbol: String {
        switch state {
        case .working: return "bolt.fill"
        case .needsReply: return "bubble.left.fill"
        case .waitingOnTool: return "hand.raised.fill"
        case .idle: return "moon.zzz"
        }
    }

    private var color: Color {
        switch state {
        case .working: return .green
        case .needsReply: return .orange
        case .waitingOnTool: return .yellow
        case .idle: return .secondary
        }
    }
}

struct SessionMenuItems: View {
    let session: SessionSummary

    var body: some View {
        Button("Resume in Terminal") { SessionActions.resumeInTerminal(session) }
        Button("Open Folder in Claude Desktop") { SessionActions.openInClaudeDesktop(session) }
        Divider()
        Button("Copy Resume Command") { SessionActions.copyResumeCommand(session) }
        Button("Copy Session ID") { SessionActions.copySessionId(session) }
        Button("Reveal Log in Finder") { SessionActions.revealLog(session) }
    }
}

// MARK: Detail

struct SessionDetail: View {
    let session: SessionSummary

    private var timed: [MessageStat] { session.messages.filter { $0.tokensPerSecond != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(2)
                    Text([session.cwd, session.models.joined(separator: ", "), session.entrypoint]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Resume in Terminal") { SessionActions.resumeInTerminal(session) }
                    .keyboardShortcut(.defaultAction)
                Menu("More") { SessionMenuItems(session: session) }
                    .fixedSize()
            }

            HStack(spacing: 24) {
                Stat(title: "Input", value: TokenFormat.short(session.tokens.input))
                Stat(title: "Cache write", value: TokenFormat.short(session.tokens.cacheCreation))
                Stat(title: "Cache read", value: TokenFormat.short(session.tokens.cacheRead))
                Stat(title: "Output", value: TokenFormat.short(session.tokens.output))
                Stat(title: "Subagents", value: TokenFormat.short(session.subagentTokens.total))
                Stat(title: "Responses", value: "\(session.messages.count)")
            }

            if timed.isEmpty {
                Text("No timed responses yet.").foregroundStyle(.secondary)
            } else {
                Chart(timed) { message in
                    PointMark(
                        x: .value("Time", message.lastSeen),
                        y: .value("Tokens per second", message.tokensPerSecond ?? 0)
                    )
                    .foregroundStyle(by: .value("Source", message.isSidechain ? "Subagent" : "Main"))
                    .symbolSize(Double(min(max(message.tokens.output, 20), 400)) / 2)
                }
                .chartYAxisLabel("tok/s")
                .frame(minHeight: 140)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Menu bar

struct MenuBarView: View {
    @EnvironmentObject private var model: TrackerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tokens today: \(TokenFormat.short(model.tokensToday.total))")
                Spacer()
                Text(TokenFormat.rate(model.liveTokensPerSecond)).monospacedDigit()
            }
            .font(.headline)

            Divider()

            if model.activeSessions.isEmpty {
                Text("No active Claude Code sessions.").foregroundStyle(.secondary)
            } else {
                ForEach(model.activeSessions) { session in
                    MenuBarSessionRow(session: session)
                }
            }

            Divider()

            HStack {
                Button("Open Tracker") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "sessions")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

private struct MenuBarSessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 6) {
                    StateBadge(state: session.state)
                    Text("· \(session.projectName) · \(TokenFormat.short((session.tokens + session.subagentTokens).total))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            Spacer()
            Text(TokenFormat.rate(session.recentTokensPerSecond))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                SessionActions.resumeInTerminal(session)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Resume in Terminal")
        }
        .contextMenu { SessionMenuItems(session: session) }
    }
}
