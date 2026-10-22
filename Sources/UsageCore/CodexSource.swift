import Foundation
import SQLite3

/// Something that reads one agent's local logs and reports its sessions.
public protocol UsageSource: AnyObject {
    var agent: Agent { get }
    /// Reads whatever changed since the last call and returns every session it knows about.
    func refresh(now: Date) -> [SessionSummary]
}

extension UsageStore: UsageSource {
    public var agent: Agent { .claude }
}

/// Every agent's sessions in one list, most recent first.
public final class AllSources {
    public let sources: [UsageSource]

    public init(sources: [UsageSource] = [UsageStore(), CodexSource()]) {
        self.sources = sources
    }

    public func refresh(now: Date = Date()) -> [SessionSummary] {
        sources.flatMap { $0.refresh(now: now) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }
}

/// Reads Codex sessions from `~/.codex` (or `$CODEX_HOME`).
///
/// Codex writes one "rollout" JSONL file per session under `sessions/YYYY/MM/DD/`. Its first
/// line is `session_meta` (id, cwd); `token_count` events carry running totals of input, cached
/// input, output and reasoning tokens. Like Claude Code's logs this is an internal format, so
/// every field is optional. Session names come from the `threads` table in `state_*.sqlite`
/// when it exists.
///
/// Not thread-safe: call `refresh` from one serial queue.
public final class CodexSource: UsageSource {
    public let agent = Agent.codex
    public let root: URL
    public var maxFileAge: TimeInterval = 30 * 24 * 3600
    public var activeWindow: TimeInterval = 2 * 3600

    private var tailers: [URL: JSONLTailer] = [:]
    private var knownSizes: [URL: Int] = [:]
    private var sessions: [URL: CodexSession] = [:]

    public static var defaultRoot: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public init(root: URL = CodexSource.defaultRoot) {
        self.root = root
    }

    public func refresh(now: Date = Date()) -> [SessionSummary] {
        let threads = ThreadIndex.read(root: root)
        var files = Set(rolloutFiles(now: now))
        files.formUnion(threads.values.compactMap(\.rolloutPath).filter { FileManager.default.fileExists(atPath: $0.path) })

        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard knownSizes[file] != size else { continue }
            knownSizes[file] = size
            read(file)
        }
        return sessions.values.compactMap { session in
            guard var summary = session.summary(now: now, activeWindow: activeWindow) else { return nil }
            if let thread = threads[summary.id] {
                if let name = thread.name { summary.title = name }
                if summary.models.isEmpty, let model = thread.model { summary.models = [model] }
            }
            return summary
        }
    }

    private func rolloutFiles(now: Date) -> [URL] {
        var found: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: keys
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                if let modified, now.timeIntervalSince(modified) > maxFileAge, tailers[url] == nil { continue }
                found.append(url)
            }
        }
        return found
    }

    private func read(_ file: URL) {
        let tailer = tailers[file] ?? JSONLTailer(url: file)
        tailers[file] = tailer
        guard let read = try? tailer.readNewLines() else { return }
        if read.wasReset { sessions[file] = nil }
        let session = sessions[file] ?? CodexSession(file: file)
        sessions[file] = session
        for line in read.lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            session.ingest(object)
        }
    }
}

/// One Codex rollout file, built up line by line.
final class CodexSession {
    let file: URL
    var id: String
    var cwd: String?
    var gitBranch: String?
    var version: String?
    var originator: String?
    var model: String?
    var firstPrompt: String?
    var startedAt: Date?
    var lastActivity: Date?
    var messages: [MessageStat] = []
    var lastEvent: SessionAccumulator.LastEvent?
    private var lastTrigger: Date?
    private var previousTotal: CodexUsage?

    init(file: URL) {
        self.file = file
        // rollout-2026-10-22T03-14-00-<uuid>.jsonl; replaced by session_meta's id when present.
        let name = file.deletingPathExtension().lastPathComponent
        self.id = name.count > 36 ? String(name.suffix(36)) : name
    }

    func ingest(_ line: [String: Any]) {
        let type = line["type"] as? String
        let payload = line["payload"] as? [String: Any] ?? [:]
        let date = (line["timestamp"] as? String).flatMap(LogTimestamp.parse)
        if let date {
            if startedAt.map({ date < $0 }) ?? true { startedAt = date }
            if lastActivity.map({ date > $0 }) ?? true { lastActivity = date }
        }

        switch (type, payload["type"] as? String) {
        case ("session_meta", _):
            if let id = payload["id"] as? String { self.id = id }
            cwd = payload["cwd"] as? String ?? cwd
            version = payload["cli_version"] as? String ?? version
            originator = payload["originator"] as? String ?? originator
            gitBranch = (payload["git"] as? [String: Any])?["branch"] as? String ?? gitBranch
        case ("turn_context", _):
            cwd = payload["cwd"] as? String ?? cwd
            model = payload["model"] as? String ?? model
        case ("event_msg", "task_started"):
            // The Codex desktop app logs a turn start but no `user_message` event.
            if let date { lastTrigger = date; lastEvent = .prompt(date) }
        case ("response_item", "message") where payload["role"] as? String == "user":
            // Codex wraps context in tags (`<environment_context>`); promptTitle skips those.
            if firstPrompt == nil,
               let text = (payload["content"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).first {
                firstPrompt = SessionAccumulator.promptTitle(text)
            }
        case ("event_msg", "user_message"):
            if firstPrompt == nil, let text = payload["message"] as? String {
                firstPrompt = SessionAccumulator.promptTitle(text)
            }
            if let date { lastTrigger = date; lastEvent = .prompt(date) }
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
            if let date { lastEvent = .assistantToolUse(date) }
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            if let date { lastTrigger = date; lastEvent = .prompt(date) }
        case ("event_msg", "agent_message"), ("event_msg", "task_complete"):
            if let date { lastEvent = .assistantText(date) }
        case ("event_msg", "token_count"):
            recordUsage(payload, at: date)
        default:
            break
        }
    }

    /// `token_count` repeats running totals, so each response is the difference from the last one.
    private func recordUsage(_ payload: [String: Any], at date: Date?) {
        guard let info = payload["info"] as? [String: Any],
              let total = CodexUsage(info["total_token_usage"]) else { return }
        let delta = total - (previousTotal ?? .zero)
        previousTotal = total
        guard delta.total > 0, let date else { return }
        messages.append(MessageStat(
            id: "\(id)#\(messages.count)",
            model: model,
            tokens: delta.counts,
            requestStart: lastTrigger,
            firstSeen: date,
            lastSeen: date,
            isSidechain: false
        ))
        lastTrigger = date
    }

    func summary(now: Date, activeWindow: TimeInterval) -> SessionSummary? {
        guard !messages.isEmpty || lastEvent != nil else { return nil }
        let tokens = messages.reduce(TokenCounts.zero) { $0 + $1.tokens }
        var summary = SessionSummary(
            id: id,
            title: firstPrompt ?? URL(fileURLWithPath: cwd ?? id).lastPathComponent,
            firstPrompt: firstPrompt,
            cwd: cwd,
            gitBranch: gitBranch,
            entrypoint: originator,
            version: version,
            models: model.map { [$0] } ?? [],
            startedAt: startedAt,
            lastActivity: lastActivity,
            tokens: tokens,
            subagentTokens: .zero,
            messages: messages,
            state: SessionAccumulator.state(lastEvent, now: now, activeWindow: activeWindow),
            logFiles: [file]
        )
        summary.agent = .codex
        return summary
    }
}

/// Codex's token counts. Its `input_tokens` includes cached input and cache writes, and `output_tokens`
/// includes reasoning, so they are split to match `TokenCounts`.
struct CodexUsage {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0

    static let zero = CodexUsage()

    init() {}

    init?(_ value: Any?) {
        guard let usage = value as? [String: Any] else { return nil }
        input = usage["input_tokens"] as? Int ?? 0
        cached = usage["cached_input_tokens"] as? Int ?? 0
        cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
        output = usage["output_tokens"] as? Int ?? 0
        reasoning = usage["reasoning_output_tokens"] as? Int ?? 0
    }

    var total: Int { input + output }

    var counts: TokenCounts {
        TokenCounts(input: max(input - cached - cacheWrite, 0), output: output, cacheCreation: cacheWrite, cacheRead: cached,
                    thinking: reasoning)
    }

    static func - (lhs: CodexUsage, rhs: CodexUsage) -> CodexUsage {
        var result = CodexUsage()
        result.input = max(lhs.input - rhs.input, 0)
        result.cached = max(lhs.cached - rhs.cached, 0)
        result.cacheWrite = max(lhs.cacheWrite - rhs.cacheWrite, 0)
        result.output = max(lhs.output - rhs.output, 0)
        result.reasoning = max(lhs.reasoning - rhs.reasoning, 0)
        return result
    }
}

/// Names and log paths of Codex threads, from the app's `state_*.sqlite` (read-only).
enum ThreadIndex {
    struct Thread {
        var name: String?
        var model: String?
        var rolloutPath: URL?
    }

    static func read(root: URL) -> [String: Thread] {
        let databases = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let latest = databases.last else { return [:] }

        var db: OpaquePointer?
        let path = root.appendingPathComponent(latest).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        // Column names differ between versions, so ask for the row as a whole and pick by name.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM threads", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            columns[String(cString: sqlite3_column_name(statement, index))] = index
        }
        func text(_ name: String) -> String? {
            guard let index = columns[name], let value = sqlite3_column_text(statement, index) else { return nil }
            let string = String(cString: value)
            return string.isEmpty ? nil : string
        }

        var threads: [String: Thread] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text("id") else { continue }
            threads[id] = Thread(
                name: text("name") ?? text("title"),
                model: text("model"),
                rolloutPath: text("rollout_path").map { URL(fileURLWithPath: $0) }
            )
        }
        return threads
    }
}
