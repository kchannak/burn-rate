import Foundation

/// Codex's own rate-limit snapshot, read straight from its session logs: a real plan quota,
/// not an estimate.
public struct CodexRateLimit: Equatable, Sendable {
    /// Percent of the plan's limit used so far in the current window, as Codex reports it.
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date
    public var planType: String?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date, planType: String?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.planType = planType
    }
}

/// A forecast for one agent's current quota window: how much is used, and - when the sample
/// is long enough to extrapolate from - a linear projection to the window's reset.
///
/// For Codex this is built from a real plan quota. For Claude, where no plan-limit data is
/// available locally, it is measured against a budget the user sets themselves, over a window
/// inferred from activity rather than read from a server.
public struct QuotaForecast: Equatable, Sendable {
    public var agent: Agent
    public var windowStart: Date
    public var windowEnd: Date
    /// Percent of budget/limit used so far in the window, measured, not projected.
    public var usedPercent: Double
    /// Percent of budget/limit the current pace would reach by `windowEnd`, linearly
    /// extrapolated from usage so far. `nil` when the sample is too short to extrapolate.
    public var projectedPercent: Double?
    /// True when the sample backing `projectedPercent` is too short (or `projectedPercent`
    /// itself is nil) to state a projection with any confidence. The UI should say so rather
    /// than present a number as settled.
    public var lowConfidence: Bool
    public var planType: String?
    /// False once the window has elapsed with no further activity to start a new one.
    public var isWindowActive: Bool

    public init(
        agent: Agent, windowStart: Date, windowEnd: Date, usedPercent: Double,
        projectedPercent: Double?, lowConfidence: Bool, planType: String?, isWindowActive: Bool
    ) {
        self.agent = agent
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.usedPercent = usedPercent
        self.projectedPercent = projectedPercent
        self.lowConfidence = lowConfidence
        self.planType = planType
        self.isWindowActive = isWindowActive
    }

    /// A confident projection landing at or past 100% of budget.
    public var likelyToExceed: Bool {
        guard !lowConfidence, let projectedPercent else { return false }
        return projectedPercent >= 100
    }
}

/// Claude's local logs carry no plan-limit figures, so this measures usage against a budget
/// the user sets themselves, over a window inferred from activity: any gap of 5+ hours starts
/// a new window at the next message, mirroring (as closely as can be inferred without server
/// data) how Anthropic's own 5-hour session limit resets.
public enum ClaudeQuota {
    public static let windowDuration: TimeInterval = 5 * 3600
    /// Below this much elapsed time in the window, a linear projection is mostly noise.
    private static let minSampleSeconds: TimeInterval = 15 * 60

    public static func forecast(sessions: [SessionSummary], budgetTokens: Int, now: Date) -> QuotaForecast? {
        guard budgetTokens > 0 else { return nil }
        let events = sessions.filter { $0.agent == .claude }
            .flatMap(\.messages)
            .filter { $0.tokens.total > 0 }
            .sorted { $0.firstSeen < $1.firstSeen }
        guard !events.isEmpty else { return nil }

        // Walk forward, starting a new window whenever a message lands 5+ hours after the
        // current window's start - so continued activity never pushes a window past 5 hours.
        var windowStart = events[0].firstSeen
        var windowTokens = 0
        for event in events {
            if event.firstSeen >= windowStart.addingTimeInterval(windowDuration) {
                windowStart = event.firstSeen
                windowTokens = 0
            }
            windowTokens += event.tokens.total
        }

        let windowEnd = windowStart.addingTimeInterval(windowDuration)
        guard now < windowEnd else {
            // The inferred window already closed and nothing has started the next one.
            return QuotaForecast(
                agent: .claude, windowStart: windowStart, windowEnd: windowEnd, usedPercent: 0,
                projectedPercent: nil, lowConfidence: true, planType: nil, isWindowActive: false
            )
        }

        let elapsed = now.timeIntervalSince(windowStart)
        let usedPercent = Double(windowTokens) / Double(budgetTokens) * 100
        let lowConfidence = elapsed < minSampleSeconds
        let projectedPercent = elapsed > 60 ? usedPercent * (windowDuration / elapsed) : nil

        return QuotaForecast(
            agent: .claude, windowStart: windowStart, windowEnd: windowEnd, usedPercent: usedPercent,
            projectedPercent: projectedPercent, lowConfidence: lowConfidence, planType: nil, isWindowActive: true
        )
    }
}

/// Codex's own rate-limit window, read directly from its logs. The window's real boundaries
/// are known, so this only has to decide when there's enough elapsed time to extrapolate.
public enum CodexQuotaForecast {
    /// Don't project off less than this share of a (typically 30-day) window.
    private static let minElapsedFraction: Double = 0.05

    public static func forecast(_ limit: CodexRateLimit, now: Date) -> QuotaForecast {
        let windowDuration = TimeInterval(limit.windowMinutes * 60)
        let windowStart = limit.resetsAt.addingTimeInterval(-windowDuration)
        let isActive = now < limit.resetsAt
        var projectedPercent: Double?
        var lowConfidence = true
        if isActive {
            let elapsed = now.timeIntervalSince(windowStart)
            if elapsed > 0 {
                let fraction = elapsed / windowDuration
                lowConfidence = fraction < minElapsedFraction
                if !lowConfidence {
                    projectedPercent = limit.usedPercent * (windowDuration / elapsed)
                }
            }
        }
        return QuotaForecast(
            agent: .codex, windowStart: windowStart, windowEnd: limit.resetsAt, usedPercent: limit.usedPercent,
            projectedPercent: projectedPercent, lowConfidence: lowConfidence, planType: limit.planType,
            isWindowActive: isActive
        )
    }
}
