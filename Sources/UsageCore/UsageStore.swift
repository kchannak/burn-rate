import Foundation

/// Watches Claude Code's session logs and keeps per-session usage up to date.
///
/// Not thread-safe: call `refresh` from one serial queue.
public final class UsageStore {
    public struct Options {
        /// Log files not modified within this window are skipped entirely.
        public var maxFileAge: TimeInterval = 30 * 24 * 3600
        /// How long a finished turn keeps a session in `needsReply` before it counts as idle.
        public var activeWindow: TimeInterval = 2 * 3600

        public init() {}
    }

    /// `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`.
    public static var defaultRoot: URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            return URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    public let root: URL
    public var options: Options

    private var tailers: [URL: JSONLTailer] = [:]
    private var knownSizes: [URL: Int] = [:]
    private var sessions: [String: SessionAccumulator] = [:]
    private var messageOwner: [String: String] = [:]
    private let decoder = JSONDecoder()

    public init(root: URL = UsageStore.defaultRoot, options: Options = Options()) {
        self.root = root
        self.options = options
    }

    /// Reads whatever was appended since the last call and returns every session, most recent first.
    @discardableResult
    public func refresh(now: Date = Date()) -> [SessionSummary] {
        for file in changedLogFiles(now: now) {
            readNewLines(from: file)
        }
        return sessions.values
            .map { $0.summary(now: now, activeWindow: options.activeWindow) }
            .filter { !$0.messages.isEmpty || $0.state != .idle }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private func changedLogFiles(now: Date) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var changed: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            if let modified = values.contentModificationDate,
               now.timeIntervalSince(modified) > options.maxFileAge,
               tailers[url] == nil {
                continue
            }
            if knownSizes[url] != size {
                knownSizes[url] = size
                changed.append(url)
            }
        }
        return changed
    }

    private func readNewLines(from file: URL) {
        let tailer = tailers[file] ?? JSONLTailer(url: file)
        tailers[file] = tailer
        guard let read = try? tailer.readNewLines() else { return }
        if read.wasReset {
            // Logs are append-only in practice; if one was rewritten, rebuild from scratch.
            resetAll()
            return
        }
        // Subagent logs live in `<session>/subagents/` and carry the parent's session id,
        // so the file name is only a fallback.
        let fallbackId = file.deletingPathExtension().lastPathComponent
        for line in read.lines {
            guard let entry = try? decoder.decode(LogEntry.self, from: line) else { continue }
            let sessionId = entry.sessionId ?? fallbackId
            let session = sessions[sessionId] ?? SessionAccumulator(id: sessionId)
            sessions[sessionId] = session
            session.ingest(entry, file: file) { messageId in
                if let owner = messageOwner[messageId] { return owner != sessionId }
                messageOwner[messageId] = sessionId
                return false
            }
        }
    }

    private func resetAll() {
        tailers.removeAll()
        knownSizes.removeAll()
        sessions.removeAll()
        messageOwner.removeAll()
    }
}

public extension Array where Element == SessionSummary {
    /// Tokens from responses that finished at or after `date`, across all sessions.
    func tokens(since date: Date) -> TokenCounts {
        var total = TokenCounts.zero
        for session in self {
            for message in session.messages where message.lastSeen >= date {
                total += message.tokens
            }
        }
        return total
    }
}
