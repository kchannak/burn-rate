import Foundation

/// Ways to get from the tracker back to a session.
///
/// Claude's documented links can open the Claude desktop app on a new Claude Code session in a
/// folder (`claude://code/new?folder=`) or open an existing claude.ai chat by id, but there is no
/// documented link that opens a specific existing Claude Code session. The exact way back to a
/// session is `claude --resume <id>` in its working directory.
public enum SessionLinks {
    /// Shell command that resumes the session in a terminal.
    public static func resumeCommand(sessionId: String, cwd: String?, agent: Agent = .claude) -> String {
        let resume: String
        switch agent {
        case .claude: resume = "claude --resume \(shellQuote(sessionId))"
        case .codex: resume = "codex resume \(shellQuote(sessionId))"
        }
        guard let cwd, !cwd.isEmpty else { return resume }
        return "cd \(shellQuote(cwd)) && \(resume)"
    }

    /// Opens the Claude desktop app on a new Claude Code session in the session's folder.
    public static func desktopCodeURL(cwd: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        if let cwd, !cwd.isEmpty {
            components.queryItems = [URLQueryItem(name: "folder", value: cwd)]
        }
        return components.url
    }

    /// Opens an existing claude.ai chat in the Claude desktop app.
    public static func desktopChatURL(conversationId: String) -> URL? {
        URL(string: "claude://claude.ai/chat/\(conversationId)")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
