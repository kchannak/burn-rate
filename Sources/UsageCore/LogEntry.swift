import Foundation

/// One line of a Claude Code session log (`~/.claude/projects/<project>/<session>.jsonl`).
///
/// The format is not a documented API and changes between Claude Code versions, so every
/// field is optional and unknown fields are ignored.
public struct LogEntry: Decodable {
    public var type: String?
    public var sessionId: String?
    public var timestamp: String?
    public var cwd: String?
    public var gitBranch: String?
    public var version: String?
    public var entrypoint: String?
    public var isSidechain: Bool?
    public var isMeta: Bool?
    /// Present on `type == "summary"` lines.
    public var summary: String?
    /// Present on `type == "custom-title"` (the user renamed the session) and `"ai-title"` lines.
    public var customTitle: String?
    public var aiTitle: String?
    public var message: Message?

    public struct Message: Decodable {
        public var id: String?
        public var role: String?
        public var model: String?
        public var usage: Usage?
        public var content: Content?
    }

    public struct Usage: Decodable, Equatable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?
        public var outputTokensDetails: OutputDetails?

        public struct OutputDetails: Decodable, Equatable {
            public var thinkingTokens: Int?

            enum CodingKeys: String, CodingKey {
                case thinkingTokens = "thinking_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokensDetails = "output_tokens_details"
        }

        public var counts: TokenCounts {
            TokenCounts(
                input: inputTokens ?? 0,
                output: outputTokens ?? 0,
                cacheCreation: cacheCreationInputTokens ?? 0,
                cacheRead: cacheReadInputTokens ?? 0,
                thinking: outputTokensDetails?.thinkingTokens ?? 0
            )
        }
    }

    /// `content` is either a plain string (typed prompts) or an array of blocks.
    public enum Content: Decodable {
        case text(String)
        case blocks([Block])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else if let blocks = try? container.decode([Block].self) {
                self = .blocks(blocks)
            } else {
                self = .blocks([])
            }
        }

        public var blockTypes: [String] {
            switch self {
            case .text: return ["text"]
            case .blocks(let blocks): return blocks.compactMap(\.type)
            }
        }

        /// The first human-readable text, if any.
        public var firstText: String? {
            switch self {
            case .text(let string): return string
            case .blocks(let blocks): return blocks.first { $0.type == "text" }?.text
            }
        }
    }

    public struct Block: Decodable {
        public var type: String?
        public var text: String?
    }

    public var date: Date? { timestamp.flatMap(LogTimestamp.parse) }
}

public enum LogTimestamp {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
