import XCTest
@testable import UsageCore

final class QuotaTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func claudeMessage(_ secondsFromBase: Double, tokens: Int) -> MessageStat {
        MessageStat(
            id: UUID().uuidString, model: "claude-sonnet-5-5", tokens: TokenCounts(input: tokens),
            requestStart: nil, firstSeen: base.addingTimeInterval(secondsFromBase),
            lastSeen: base.addingTimeInterval(secondsFromBase), isSidechain: false
        )
    }

    private func session(_ messages: [MessageStat]) -> SessionSummary {
        var summary = SessionSummary(
            id: UUID().uuidString, title: "t", models: [], tokens: .zero, subagentTokens: .zero,
            messages: messages, state: .idle, logFiles: []
        )
        summary.agent = .claude
        return summary
    }

    func testNoBudgetMeansNoForecast() {
        let sessions = [session([claudeMessage(0, tokens: 100)])]
        XCTAssertNil(ClaudeQuota.forecast(sessions: sessions, budgetTokens: 0, now: base))
    }

    func testNoMessagesMeansNoForecast() {
        XCTAssertNil(ClaudeQuota.forecast(sessions: [session([])], budgetTokens: 1000, now: base))
    }

    func testEarlyInWindowIsLowConfidenceWithNoProjection() {
        let sessions = [session([claudeMessage(0, tokens: 50)])]
        let forecast = try! XCTUnwrap(ClaudeQuota.forecast(sessions: sessions, budgetTokens: 1000, now: base.addingTimeInterval(60)))
        XCTAssertTrue(forecast.lowConfidence)
        XCTAssertNil(forecast.projectedPercent)
        XCTAssertFalse(forecast.likelyToExceed, "a low-confidence forecast is never reported as a confident overrun")
    }

    func testProjectsLinearlyToWindowEndOnceSampleIsLongEnough() {
        // 1000 of a 2000-token budget used after 1 hour of a 5-hour window -> on pace for 200%.
        let sessions = [session([claudeMessage(0, tokens: 1000)])]
        let now = base.addingTimeInterval(3600)
        let forecast = try! XCTUnwrap(ClaudeQuota.forecast(sessions: sessions, budgetTokens: 2000, now: now))
        XCTAssertFalse(forecast.lowConfidence)
        XCTAssertEqual(forecast.usedPercent, 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(forecast.projectedPercent), 250, accuracy: 0.01)
        XCTAssertTrue(forecast.likelyToExceed)
    }

    func testActivityGapOfFiveHoursStartsANewWindow() {
        let sessions = [session([
            claudeMessage(0, tokens: 5000),
            claudeMessage(2 * 3600, tokens: 5000),
            // 5+ hour gap from the last message: a new window starts here.
            claudeMessage(9 * 3600, tokens: 100),
        ])]
        let now = base.addingTimeInterval(9 * 3600 + 60)
        let forecast = try! XCTUnwrap(ClaudeQuota.forecast(sessions: sessions, budgetTokens: 1_000_000, now: now))
        XCTAssertEqual(forecast.windowStart, base.addingTimeInterval(9 * 3600))
        XCTAssertEqual(forecast.usedPercent, 100.0 / 1_000_000 * 100, accuracy: 0.0001)
    }

    func testWindowAlreadyClosedWithNoNewActivityReportsInactive() {
        let sessions = [session([claudeMessage(0, tokens: 500)])]
        let now = base.addingTimeInterval(6 * 3600)
        let forecast = try! XCTUnwrap(ClaudeQuota.forecast(sessions: sessions, budgetTokens: 1000, now: now))
        XCTAssertFalse(forecast.isWindowActive)
        XCTAssertNil(forecast.projectedPercent)
    }

    func testCodexForecastProjectsFromItsRealWindow() {
        let resetsAt = base.addingTimeInterval(30 * 24 * 3600)
        let limit = CodexRateLimit(usedPercent: 10, windowMinutes: 30 * 24 * 60, resetsAt: resetsAt, planType: "plus")
        // Three days into a 30-day window (well past the 5% minimum) at 10% used -> on pace for 100%.
        let forecast = CodexQuotaForecast.forecast(limit, now: base.addingTimeInterval(3 * 24 * 3600))
        XCTAssertFalse(forecast.lowConfidence)
        XCTAssertEqual(try! XCTUnwrap(forecast.projectedPercent), 100, accuracy: 0.01)
        XCTAssertEqual(forecast.planType, "plus")
    }

    func testCodexForecastIsLowConfidenceJustAfterTheWindowStarts() {
        let resetsAt = base.addingTimeInterval(30 * 24 * 3600)
        let limit = CodexRateLimit(usedPercent: 1, windowMinutes: 30 * 24 * 60, resetsAt: resetsAt, planType: "free")
        let forecast = CodexQuotaForecast.forecast(limit, now: base.addingTimeInterval(3600))
        XCTAssertTrue(forecast.lowConfidence)
        XCTAssertNil(forecast.projectedPercent)
    }
}
