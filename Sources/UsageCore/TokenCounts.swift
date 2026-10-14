import Foundation

public struct TokenCounts: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    /// Every token billed for the request: fresh input, cache writes, cache reads and output.
    public var total: Int { input + output + cacheCreation + cacheRead }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

public enum TokenFormat {
    /// 950, 12.3K, 4.56M
    public static func short(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fK", v / 1_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(value)"
        }
    }

    public static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f tok/s", value)
    }
}
