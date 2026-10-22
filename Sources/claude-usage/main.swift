import Foundation
import UsageCore

// Prints the same per-session numbers the app shows.
// Usage: claude-usage [--all] [--root <Claude projects dir>] [--codex-root <Codex home>]

let arguments = Array(CommandLine.arguments.dropFirst())
let showAll = arguments.contains("--all")
var root = UsageStore.defaultRoot
if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
    root = URL(fileURLWithPath: arguments[index + 1])
}

var codexRoot = CodexSource.defaultRoot
if let index = arguments.firstIndex(of: "--codex-root"), index + 1 < arguments.count {
    codexRoot = URL(fileURLWithPath: arguments[index + 1])
}

let store = AllSources(sources: [UsageStore(root: root), CodexSource(root: codexRoot)])
let sessions = store.refresh()
let shown = showAll ? sessions : sessions.filter { $0.state != .idle }

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? String(string.prefix(width)) : string + String(repeating: " ", count: width - string.count)
}

print(pad("AGENT", 7), pad("STATE", 13), pad("SESSION", 10), pad("PROJECT", 20), pad("TOTAL", 8), pad("OUTPUT", 8),
      pad("AVG", 11), pad("RECENT", 11), "TITLE")
for session in shown {
    print(
        pad(session.agent.label, 7),
        pad(session.state.label, 13),
        pad(String(session.id.prefix(8)), 10),
        pad(session.projectName, 20),
        pad(TokenFormat.short((session.tokens + session.subagentTokens).total), 8),
        pad(TokenFormat.short((session.tokens + session.subagentTokens).output), 8),
        pad(TokenFormat.rate(session.averageTokensPerSecond), 11),
        pad(TokenFormat.rate(session.recentTokensPerSecond), 11),
        session.title
    )
}

let startOfDay = Calendar.current.startOfDay(for: Date())
let today = sessions.tokens(since: startOfDay)
print("\n\(shown.count) of \(sessions.count) sessions shown. Today: \(TokenFormat.short(today.total)) tokens, \(TokenFormat.short(today.output)) output.")
if !showAll { print("Pass --all to include idle sessions.") }
