# Claude Usage Tracker

A macOS menu bar app that tracks Claude Code usage per session: tokens, generation speed, and
which sessions are waiting for you. When several sessions run at once, each one gets its own row,
and one click takes you back to it.

## What it shows

- **Per session:** input, cache write, cache read and output tokens (subagents counted
  separately), the models used, and speed in output tokens per second, both the average and
  the last five responses.
- **State:** *Working*, *Needs reply* (Claude finished its turn), *Waiting on tool or
  permission* (a tool call has had no result for over a minute, usually a permission prompt),
  or *Idle*.
- **Totals:** tokens today, active sessions, and the combined live speed of working sessions,
  in the menu bar and in a summary bar.
- **Notifications** when a session starts waiting on you (optional; needs the bundled app).
- **A chart** of speed per response for the selected session.

## Getting back to a session

Double-click a row (or use **Resume in Terminal**) to open Terminal running
`claude --resume <session-id>` in the session's folder. That is the only route that lands on
the exact session.

**Open Folder in Claude Desktop** uses the desktop app's documented `claude://code/new?folder=`
link. It opens a *new* Claude Code session in the same folder, because the desktop app has no
documented link to an existing Claude Code session yet. If one appears, it belongs in
`Sources/UsageCore/SessionLinks.swift`.

## How it works

Claude Code writes every session to `~/.claude/projects/<project>/<session-id>.jsonl`
(or under `$CLAUDE_CONFIG_DIR`). The app reads those files every 20 seconds by default (2, 5, 20 or 60, set in the panel), reading only
what was appended. See [docs/DESIGN.md](docs/DESIGN.md) for the details and the caveats.

Codex sessions are read the same way from `~/.codex/sessions/` (or `$CODEX_HOME`), with names
from Codex's thread list. Each agent has its own reader (`UsageSource`) that turns its logs into
the same session summary, so another agent can be added without touching the UI.

## Run it from source

Requires macOS 14+ and Swift 5.9+ (Xcode 15 or later).

```sh
swift run ClaudeUsageTracker     # the app (no notifications when run this way)
swift run claude-usage --all     # the same numbers as a table in the terminal
swift test
```

## Build and distribute

```sh
scripts/build-app.sh
```

This produces `dist/Claude Usage.app`, plus a `.dmg` and `.zip` to share. It needs full
Xcode, not just the command line tools, for the universal (Apple silicon + Intel) build.

Without signing credentials the build is ad-hoc signed. Others can run it, but macOS will block
the first launch: they right-click the app, choose **Open**, then confirm.

To ship a build that opens without warnings you need an Apple Developer account ($99/year):

1. Create a **Developer ID Application** certificate and install it in your keychain.
2. Create an app-specific password for your Apple ID at appleid.apple.com.
3. Build with:
   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx \
   VERSION=0.1.0 scripts/build-app.sh
   ```

### Releases from GitHub

Pushing a tag such as `v0.1.0` runs `.github/workflows/release.yml`, which tests, builds and
attaches the `.dmg` and `.zip` to a GitHub release. To have it sign and notarize, add these
repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | `base64 -i cert.p12` of the Developer ID certificate exported from Keychain Access |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set when exporting it |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | as above |

Without them the release still publishes, with the ad-hoc signed build.

Every push and pull request also runs the tests and builds the app (`.github/workflows/ci.yml`).
