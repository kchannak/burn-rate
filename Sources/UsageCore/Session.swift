import Foundation

/// One model response (one API request), merged across the several log lines Claude Code
/// writes for it (one line per content block, each repeating the same `usage`).
public struct MessageStat: Identifiable, Sendable {
    public let id: String
    public var model: String?
    public var tokens: TokenCounts
    /// When the entry that prompted this response (a prompt or a tool result) was logged.
    public var requestStart: Date?
    public var firstSeen: Date
    public var lastSeen: Date
    public var isSidechain: Bool

    /// Wall-clock time from the prompting entry to the last block of the response.
    /// This includes time to first token, so the derived speed is an end-to-end figure.
    public var duration: TimeInterval? {
        guard let requestStart else { return nil }
        let seconds = lastSeen.timeIntervalSince(requestStart)
        return seconds > 0 ? seconds : nil
    }

    public var tokensPerSecond: Double? {
        guard let duration, duration >= 0.5, tokens.output > 0 else { return nil }
        return Double(tokens.output) / duration
    }
}

public enum SessionState: String, Sendable, CaseIterable {
    /// Claude is producing a response or running a tool.
    case working
    /// Claude finished its turn with text and is waiting for the user.
    case needsReply
    /// The last thing logged is a tool call with no result for a while: usually a permission
    /// prompt waiting for the user, sometimes just a slow command.
    case waitingOnTool
    /// Nothing recent.
    case idle

    public var label: String {
        switch self {
        case .working: return "Working"
        case .needsReply: return "Needs reply"
        case .waitingOnTool: return "Waiting on tool or permission"
        case .idle: return "Idle"
        }
    }
}

public struct SessionSummary: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var cwd: String?
    public var gitBranch: String?
    public var entrypoint: String?
    public var version: String?
    public var models: [String]
    public var startedAt: Date?
    public var lastActivity: Date?
    public var tokens: TokenCounts
    public var subagentTokens: TokenCounts
    public var messages: [MessageStat]
    public var state: SessionState
    public var logFiles: [URL]

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Output tokens divided by generation time, across every timed response.
    public var averageTokensPerSecond: Double? { Self.rate(messages) }

    /// The same figure over the last five timed responses.
    public var recentTokensPerSecond: Double? {
        Self.rate(Array(messages.filter { $0.tokensPerSecond != nil }.suffix(5)))
    }

    static func rate(_ messages: [MessageStat]) -> Double? {
        var output = 0
        var seconds: TimeInterval = 0
        for message in messages {
            guard message.tokensPerSecond != nil, let duration = message.duration else { continue }
            output += message.tokens.output
            seconds += duration
        }
        return seconds > 0 ? Double(output) / seconds : nil
    }
}

/// Builds up one session from log entries as they arrive.
final class SessionAccumulator {
    enum LastEvent {
        case prompt(Date)
        case assistantText(Date)
        case assistantToolUse(Date)
    }

    let id: String
    var title: String?
    var summaryTitle: String?
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var version: String?
    var startedAt: Date?
    var lastActivity: Date?
    var messages: [String: MessageStat] = [:]
    var lastEvent: LastEvent?
    var logFiles: Set<URL> = []
    /// Most recent prompting entry per log stream, used as the start time of the next response.
    private var lastTrigger: [String: Date] = [:]

    init(id: String) {
        self.id = id
    }

    /// - Parameters:
    ///   - stream: identifies the log file (and chain within it) the entry came from, so
    ///     subagents writing in parallel don't skew each other's timings.
    ///   - isOwnedElsewhere: returns true when a message id was already counted in another
    ///     session (resumed sessions can replay earlier messages into a new file).
    func ingest(_ entry: LogEntry, file: URL, isOwnedElsewhere: (String) -> Bool) {
        logFiles.insert(file)
        let isSidechain = entry.isSidechain ?? false
        let stream = file.path + (isSidechain ? "#side" : "")
        let date = entry.date

        if entry.type == "summary", let summary = entry.summary, !summary.isEmpty {
            summaryTitle = summary
        }

        guard let date, entry.type == "user" || entry.type == "assistant" else { return }

        if !isSidechain {
            cwd = entry.cwd ?? cwd
            gitBranch = entry.gitBranch ?? gitBranch
            entrypoint = entry.entrypoint ?? entrypoint
            version = entry.version ?? version
        }
        if startedAt.map({ date < $0 }) ?? true { startedAt = date }
        if lastActivity.map({ date > $0 }) ?? true { lastActivity = date }

        if entry.type == "user" {
            lastTrigger[stream] = date
            if !isSidechain {
                lastEvent = .prompt(date)
                if title == nil, entry.isMeta != true, let text = entry.message?.content?.firstText {
                    title = Self.promptTitle(text)
                }
            }
            return
        }

        // Assistant line.
        guard let message = entry.message else { return }
        if !isSidechain {
            let types = message.content?.blockTypes ?? []
            lastEvent = types.contains("tool_use") ? .assistantToolUse(date) : .assistantText(date)
        }
        guard let messageId = message.id, let usage = message.usage else { return }

        if var existing = messages[messageId] {
            existing.tokens = usage.counts
            existing.lastSeen = max(existing.lastSeen, date)
            messages[messageId] = existing
        } else {
            guard !isOwnedElsewhere(messageId) else { return }
            messages[messageId] = MessageStat(
                id: messageId,
                model: message.model,
                tokens: usage.counts,
                requestStart: lastTrigger[stream],
                firstSeen: date,
                lastSeen: date,
                isSidechain: isSidechain
            )
        }
    }

    /// Turns a typed prompt into a one-line title, skipping wrapped command/system text.
    static func promptTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return firstLine.count > 80 ? String(firstLine.prefix(79)) + "…" : firstLine
    }

    func summary(now: Date, activeWindow: TimeInterval) -> SessionSummary {
        let sorted = messages.values.sorted { $0.firstSeen < $1.firstSeen }
        var tokens = TokenCounts.zero
        var subagentTokens = TokenCounts.zero
        var models: [String] = []
        for message in sorted {
            if message.isSidechain {
                subagentTokens += message.tokens
            } else {
                tokens += message.tokens
            }
            if let model = message.model, !model.hasPrefix("<"), !models.contains(model) {
                models.append(model)
            }
        }

        return SessionSummary(
            id: id,
            title: summaryTitle ?? title ?? URL(fileURLWithPath: cwd ?? id).lastPathComponent,
            cwd: cwd,
            gitBranch: gitBranch,
            entrypoint: entrypoint,
            version: version,
            models: models,
            startedAt: startedAt,
            lastActivity: lastActivity,
            tokens: tokens,
            subagentTokens: subagentTokens,
            messages: sorted,
            state: Self.state(lastEvent, now: now, activeWindow: activeWindow),
            logFiles: logFiles.sorted { $0.path < $1.path }
        )
    }

    static func state(_ event: LastEvent?, now: Date, activeWindow: TimeInterval) -> SessionState {
        switch event {
        case nil:
            return .idle
        case .prompt(let date):
            // A response normally starts streaming well within this; past it the turn was
            // most likely interrupted.
            return now.timeIntervalSince(date) < 10 * 60 ? .working : .idle
        case .assistantToolUse(let date):
            let age = now.timeIntervalSince(date)
            if age < 60 { return .working }
            return age < activeWindow ? .waitingOnTool : .idle
        case .assistantText(let date):
            return now.timeIntervalSince(date) < activeWindow ? .needsReply : .idle
        }
    }
}
