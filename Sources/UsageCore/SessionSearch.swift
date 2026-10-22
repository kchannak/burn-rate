import Foundation

/// Fuzzy matching of sessions by name, project folder, first prompt and branch.
///
/// Every word in the query has to match one of those fields, either as a substring or as
/// letters in order ("trkusg" matches "track-claude-usage"). Substring matches, matches at
/// the start of a word and matches in the session name score higher.
public enum SessionSearch {
    /// Sessions that match `query`, best first; ties go to the most recently active.
    public static func rank(_ sessions: [SessionSummary], query: String) -> [SessionSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return sessions }
        return sessions
            .compactMap { session in score(session, words: words).map { (session, $0) } }
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1
                    : ($0.0.lastActivity ?? .distantPast) > ($1.0.lastActivity ?? .distantPast)
            }
            .map(\.0)
    }

    static func score(_ session: SessionSummary, words: [String]) -> Int? {
        let fields: [(String, Int)] = [
            (session.title, 3),
            (session.projectName, 2),
            (session.firstPrompt ?? "", 1),
            (session.gitBranch ?? "", 1),
        ].map { ($0.0.lowercased(), $0.1) }

        var total = 0
        for word in words {
            let best = fields.compactMap { field, weight in match(word, in: field).map { $0 * weight } }.max()
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// Scores one query word against one field, or nil when it doesn't match.
    static func match(_ word: String, in field: String) -> Int? {
        guard !word.isEmpty, !field.isEmpty else { return nil }
        if let range = field.range(of: word) {
            let atWordStart = range.lowerBound == field.startIndex
                || !field[field.index(before: range.lowerBound)].isLetter
            return 100 + (atWordStart ? 50 : 0)
        }
        // Letters in order, penalised by the gaps between them.
        var gaps = 0
        var index = field.startIndex
        var started = false
        for character in word {
            var skipped = 0
            while index < field.endIndex, field[index] != character {
                index = field.index(after: index)
                skipped += 1
            }
            guard index < field.endIndex else { return nil }
            if started { gaps += skipped }
            started = true
            index = field.index(after: index)
        }
        return max(10, 60 - gaps * 2)
    }
}
