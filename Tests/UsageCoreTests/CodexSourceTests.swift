import XCTest
@testable import UsageCore

final class CodexSourceTests: XCTestCase {
    private var root: URL!
    private let base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions/2026/10/22"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ts(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(seconds))
    }

    private func tokenCount(_ at: Double, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        #"{"timestamp":"\#(ts(at))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}}}}"#
    }

    func testReadsRolloutTurnsAsDeltasOfRunningTotals() throws {
        let id = "0199f5a1-1111-7222-8333-444455556666"
        let lines = [
            #"{"timestamp":"\#(ts(0))","type":"session_meta","payload":{"id":"\#(id)","cwd":"/Users/me/app","cli_version":"0.50.0","originator":"codex_cli_rs","git":{"branch":"main"}}}"#,
            #"{"timestamp":"\#(ts(0))","type":"turn_context","payload":{"cwd":"/Users/me/app","model":"gpt-5-codex"}}"#,
            #"{"timestamp":"\#(ts(1))","type":"event_msg","payload":{"type":"user_message","message":"Add a login page\nwith tests"}}"#,
            #"{"timestamp":"\#(ts(3))","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#,
            tokenCount(3, input: 1000, cached: 800, output: 100, reasoning: 40),
            #"{"timestamp":"\#(ts(4))","type":"response_item","payload":{"type":"function_call_output","call_id":"c1"}}"#,
            tokenCount(6, input: 2500, cached: 2000, output: 400, reasoning: 100),
            // Codex repeats the totals when nothing changed; that must not count as a new response.
            tokenCount(6, input: 2500, cached: 2000, output: 400, reasoning: 100),
            #"{"timestamp":"\#(ts(7))","type":"event_msg","payload":{"type":"agent_message","message":"Done"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("sessions/2026/10/22/rollout-2026-10-22T03-14-00-\(id).jsonl"),
            atomically: true, encoding: .utf8)

        let sessions = CodexSource(root: root).refresh(now: base.addingTimeInterval(10))
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.title, "Add a login page")
        XCTAssertEqual(session.projectName, "app")
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertEqual(session.models, ["gpt-5-codex"])
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.tokens.input, 500, "fresh input excludes cached")
        XCTAssertEqual(session.tokens.cacheRead, 2000)
        XCTAssertEqual(session.tokens.output, 400)
        XCTAssertEqual(session.tokens.thinking, 100)
        XCTAssertEqual(session.tokens.total, 2900)
        // First response: 100 output over 2s (prompt at 1s), second: 300 over 2s (tool output at 4s).
        XCTAssertEqual(try XCTUnwrap(session.messages[0].tokensPerSecond), 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(session.messages[1].tokensPerSecond), 150, accuracy: 0.01)
        XCTAssertEqual(session.state, .needsReply)
        XCTAssertEqual(
            SessionLinks.resumeCommand(sessionId: session.id, cwd: session.cwd, agent: session.agent),
            "cd '/Users/me/app' && codex resume '\(id)'")
    }

    func testDesktopAppTurnsStartAtTaskStartedAndSplitCacheWrites() throws {
        let lines = [
            #"{"timestamp":"\#(ts(0))","type":"session_meta","payload":{"id":"d1","cwd":"/Users/me/x","originator":"Codex Desktop"}}"#,
            #"{"timestamp":"\#(ts(0))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"timestamp":"\#(ts(1))","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"timestamp":"\#(ts(1))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Run a test query"}]}}"#,
            #"{"timestamp":"\#(ts(3))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":300,"output_tokens":40,"reasoning_output_tokens":0}}}}"#,
            #"{"timestamp":"\#(ts(3))","type":"event_msg","payload":{"type":"task_complete"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("sessions/2026/10/22/rollout-2026-10-22T03-17-15-d1.jsonl"),
            atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(CodexSource(root: root).refresh(now: base.addingTimeInterval(10)).first)
        XCTAssertEqual(session.title, "Run a test query")
        XCTAssertEqual(session.tokens.input, 100)
        XCTAssertEqual(session.tokens.cacheRead, 600)
        XCTAssertEqual(session.tokens.cacheCreation, 300)
        XCTAssertEqual(try XCTUnwrap(session.messages.first?.tokensPerSecond), 20, accuracy: 0.01)
        XCTAssertEqual(session.state, .needsReply)
    }

    func testMissingCodexFolderGivesNoSessions() {
        XCTAssertTrue(CodexSource(root: root.appendingPathComponent("nope")).refresh(now: base).isEmpty)
    }

    func testTracksTheMostRecentRateLimitSnapshotAcrossSessions() throws {
        func line(_ at: Double, usedPercent: Double, resetsAt: Double) -> String {
            #"""
            {"timestamp":"\#(ts(at))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":\#(usedPercent),"window_minutes":43200,"resets_at":\#(resetsAt)}}}}
            """#
        }
        let resets = base.addingTimeInterval(20 * 24 * 3600).timeIntervalSince1970
        try (line(0, usedPercent: 12.5, resetsAt: resets) + "\n").write(
            to: root.appendingPathComponent("sessions/2026/10/22/rollout-2026-10-22T00-00-00-a1.jsonl"),
            atomically: true, encoding: .utf8)
        try (line(5, usedPercent: 40, resetsAt: resets) + "\n").write(
            to: root.appendingPathComponent("sessions/2026/10/22/rollout-2026-10-22T00-00-05-b2.jsonl"),
            atomically: true, encoding: .utf8)

        let source = CodexSource(root: root)
        _ = source.refresh(now: base.addingTimeInterval(10))

        let limit = try XCTUnwrap(source.latestRateLimit)
        XCTAssertEqual(limit.usedPercent, 40)
        XCTAssertEqual(limit.windowMinutes, 43_200)
        XCTAssertEqual(limit.planType, "plus")
        XCTAssertEqual(limit.resetsAt.timeIntervalSince1970, resets, accuracy: 1)
    }
}
