import XCTest
@testable import UsageCore

final class UsageStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-tests-\(UUID().uuidString)")
            .appendingPathComponent("-Users-me-proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Fixture helpers

    private func ts(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(seconds))
    }

    // Close to the real clock, because the store skips files whose modification date is old.
    private let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func user(_ session: String, _ at: Double, prompt: String? = nil, sidechain: Bool = false) -> String {
        let content = prompt.map { "\"\($0)\"" } ?? #"[{"type":"tool_result","tool_use_id":"t","content":"ok"}]"#
        return #"{"type":"user","sessionId":"\#(session)","timestamp":"\#(ts(at))","cwd":"/Users/me/proj","gitBranch":"main","isSidechain":\#(sidechain),"message":{"role":"user","content":\#(content)}}"#
    }

    private func assistant(_ session: String, _ at: Double, id: String, block: String = "text",
                           output: Int = 100, input: Int = 5, cacheRead: Int = 1000,
                           sidechain: Bool = false) -> String {
        #"{"type":"assistant","sessionId":"\#(session)","timestamp":"\#(ts(at))","cwd":"/Users/me/proj","isSidechain":\#(sidechain),"message":{"id":"\#(id)","role":"assistant","model":"claude-test","content":[{"type":"\#(block)","text":"hi"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":10,"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    private func write(_ lines: [String], to name: String, append: Bool = false) throws {
        let url = root.appendingPathComponent(name)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    // MARK: Tests

    func testDeduplicatesSplitAssistantLinesAndTimesResponses() throws {
        try write([
            user("s1", 0, prompt: "Fix the login bug\\nand add a test"),
            assistant("s1", 2, id: "m1", block: "thinking", output: 200),
            assistant("s1", 4, id: "m1", block: "tool_use", output: 200),
            user("s1", 5),
            assistant("s1", 6, id: "m2", output: 50),
        ], to: "s1.jsonl")

        let store = UsageStore(root: root.deletingLastPathComponent())
        let sessions = store.refresh(now: base.addingTimeInterval(10))
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.title, "Fix the login bug")
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.tokens.output, 250)
        XCTAssertEqual(session.tokens.input, 10)
        XCTAssertEqual(session.tokens.cacheRead, 2000)
        XCTAssertEqual(session.tokens.cacheCreation, 20)
        // m1: 200 tokens over 4s, m2: 50 tokens over 1s.
        XCTAssertEqual(try XCTUnwrap(session.messages[0].tokensPerSecond), 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(session.messages[1].tokensPerSecond), 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(session.averageTokensPerSecond), 50, accuracy: 0.01)
        XCTAssertEqual(session.state, .needsReply)
        XCTAssertEqual(session.models, ["claude-test"])
        XCTAssertEqual(session.projectName, "proj")
    }

    func testPicksUpAppendedLinesAndHoldsBackPartialLine() throws {
        try write([user("s1", 0, prompt: "hello")], to: "s1.jsonl")
        let store = UsageStore(root: root.deletingLastPathComponent())
        XCTAssertEqual(store.refresh(now: base.addingTimeInterval(1)).first?.state, .working)

        // A line without its trailing newline is still being written.
        let url = root.appendingPathComponent("s1.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistant("s1", 3, id: "m1", output: 30).utf8))
        try handle.close()
        XCTAssertEqual(store.refresh(now: base.addingTimeInterval(4)).first?.messages.count, 0)

        try write([""], to: "s1.jsonl", append: true)
        let session = try XCTUnwrap(store.refresh(now: base.addingTimeInterval(4)).first)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.tokens.output, 30)
    }

    func testTracksConcurrentSessionsSeparately() throws {
        try write([user("a", 0, prompt: "task a"), assistant("a", 2, id: "ma", block: "tool_use")], to: "a.jsonl")
        try write([user("b", 1, prompt: "task b"), assistant("b", 3, id: "mb")], to: "b.jsonl")

        let store = UsageStore(root: root.deletingLastPathComponent())
        let sessions = store.refresh(now: base.addingTimeInterval(5))

        XCTAssertEqual(sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(sessions.first { $0.id == "a" }?.state, .working)
        XCTAssertEqual(sessions.first { $0.id == "b" }?.state, .needsReply)
        XCTAssertEqual(sessions.tokens(since: base).output, 200)
    }

    func testStateTransitionsWithTime() {
        let t = base
        XCTAssertEqual(SessionAccumulator.state(.assistantToolUse(t), now: t.addingTimeInterval(30), activeWindow: 3600), .working)
        XCTAssertEqual(SessionAccumulator.state(.assistantToolUse(t), now: t.addingTimeInterval(120), activeWindow: 3600), .waitingOnTool)
        XCTAssertEqual(SessionAccumulator.state(.assistantText(t), now: t.addingTimeInterval(7200), activeWindow: 3600), .idle)
        XCTAssertEqual(SessionAccumulator.state(.prompt(t), now: t.addingTimeInterval(3600), activeWindow: 3600), .idle)
    }

    func testSubagentLogsCountTowardsParentSession() throws {
        try write([user("p", 0, prompt: "parent"), assistant("p", 1, id: "m1")], to: "p.jsonl")
        let subagents = root.appendingPathComponent("p/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try write([
            user("p", 2, prompt: "sub task", sidechain: true),
            assistant("p", 3, id: "m2", output: 40, sidechain: true),
        ], to: "p/subagents/agent-1.jsonl")

        let store = UsageStore(root: root.deletingLastPathComponent())
        let session = try XCTUnwrap(store.refresh(now: base.addingTimeInterval(4)).first)

        XCTAssertEqual(session.title, "parent")
        XCTAssertEqual(session.tokens.output, 100)
        XCTAssertEqual(session.subagentTokens.output, 40)
        XCTAssertEqual(session.logFiles.count, 2)
    }

    func testResumedSessionDoesNotDoubleCountReplayedMessages() throws {
        try write([user("old", 0, prompt: "first"), assistant("old", 1, id: "m1")], to: "old.jsonl")
        try write([
            user("new", 0, prompt: "first"), assistant("new", 1, id: "m1"),
            user("new", 10, prompt: "more"), assistant("new", 11, id: "m2"),
        ], to: "new.jsonl")

        let store = UsageStore(root: root.deletingLastPathComponent())
        let sessions = store.refresh(now: base.addingTimeInterval(12))

        XCTAssertEqual(sessions.tokens(since: base).output, 200)
    }

    func testResumeCommandQuotesPaths() {
        XCTAssertEqual(
            SessionLinks.resumeCommand(sessionId: "abc", cwd: "/Users/me/it's here"),
            #"cd '/Users/me/it'\''s here' && claude --resume 'abc'"#
        )
        XCTAssertEqual(
            SessionLinks.desktopCodeURL(cwd: "/Users/me/my proj")?.absoluteString,
            "claude://code/new?folder=/Users/me/my%20proj"
        )
    }

    func testPromptTitleSkipsWrappedCommands() {
        XCTAssertNil(SessionAccumulator.promptTitle("<command-name>/clear</command-name>"))
        XCTAssertEqual(SessionAccumulator.promptTitle("  short  "), "short")
        XCTAssertEqual(SessionAccumulator.promptTitle(String(repeating: "x", count: 100))?.count, 80)
    }

    func testNamedSessionKeepsFirstPromptAndPrefersCustomTitle() throws {
        try write([
            user("s1", 0, prompt: "Explore the usage tracking repo"),
            assistant("s1", 2, id: "m1"),
            #"{"type":"ai-title","aiTitle":"Usage repo tour","sessionId":"s1"}"#,
            #"{"type":"custom-title","customTitle":"Tracker work","sessionId":"s1"}"#,
        ], to: "s1.jsonl")

        let session = try XCTUnwrap(UsageStore(root: root.deletingLastPathComponent())
            .refresh(now: base.addingTimeInterval(10)).first)
        XCTAssertEqual(session.title, "Tracker work")
        XCTAssertEqual(session.firstPrompt, "Explore the usage tracking repo")
    }

    func testReadsThinkingTokensAndCacheHitRate() throws {
        try write([
            user("s1", 0, prompt: "Think hard"),
            #"{"type":"assistant","sessionId":"s1","timestamp":"\#(ts(2))","message":{"id":"m1","role":"assistant","model":"claude-test","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":300,"cache_creation_input_tokens":90,"cache_read_input_tokens":900,"output_tokens_details":{"thinking_tokens":120}}}}"#,
        ], to: "s1.jsonl")

        let session = try XCTUnwrap(UsageStore(root: root.deletingLastPathComponent())
            .refresh(now: base.addingTimeInterval(10)).first)
        XCTAssertEqual(session.tokens.thinking, 120)
        XCTAssertEqual(session.tokens.output, 300)
        XCTAssertEqual(session.tokens.total, 1300, "thinking is part of output, not added again")
        XCTAssertEqual(try XCTUnwrap(session.tokens.cacheHitRate), 0.9, accuracy: 0.0001)
    }

    func testFuzzySearchRanksNameMatchesFirstAndMatchesLettersInOrder() throws {
        try write([user("a", 0, prompt: "Fix the login bug"), assistant("a", 1, id: "a1")], to: "a.jsonl")
        try write([user("b", 0, prompt: "Write docs about login"), assistant("b", 2, id: "b1")], to: "b.jsonl")
        try write([user("c", 0, prompt: "Plot a chart"), assistant("c", 3, id: "c1")], to: "c.jsonl")
        let sessions = UsageStore(root: root.deletingLastPathComponent()).refresh(now: base.addingTimeInterval(10))

        XCTAssertEqual(SessionSearch.rank(sessions, query: "login").map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(SessionSearch.rank(sessions, query: "fix login").map(\.id), ["a"])
        XCTAssertEqual(SessionSearch.rank(sessions, query: "pltchrt").map(\.id), ["c"])
        XCTAssertEqual(SessionSearch.rank(sessions, query: "proj chart").map(\.id), ["c"], "project folder counts")
        XCTAssertTrue(SessionSearch.rank(sessions, query: "zzz").isEmpty)
        XCTAssertEqual(SessionSearch.rank(sessions, query: "  ").count, 3)
    }
}
