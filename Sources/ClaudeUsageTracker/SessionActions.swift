import AppKit
import Foundation
import UsageCore

/// Jumps from the tracker back to a session.
enum SessionActions {
    /// Opens Terminal running `claude --resume <id>` in the session's folder.
    ///
    /// Writes a small `.command` script and hands it to Launch Services, which avoids needing
    /// Automation permission to script Terminal.
    static func resumeInTerminal(_ session: SessionSummary) {
        let command = SessionLinks.resumeCommand(sessionId: session.id, cwd: session.cwd)
        let script = """
        #!/bin/zsh -l
        \(command)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(session.id.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    /// Opens the Claude desktop app on a new Claude Code session in the same folder.
    static func openInClaudeDesktop(_ session: SessionSummary) {
        guard let url = SessionLinks.desktopCodeURL(cwd: session.cwd) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyResumeCommand(_ session: SessionSummary) {
        copy(SessionLinks.resumeCommand(sessionId: session.id, cwd: session.cwd))
    }

    static func copySessionId(_ session: SessionSummary) {
        copy(session.id)
    }

    static func revealLog(_ session: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting(session.logFiles)
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
