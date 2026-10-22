# Burnrate

A macOS app that shows how fast your coding agents burn tokens: Claude Code and Codex today,
with a reader per agent so others can be added. It lives in a small translucent window (and the
menu bar), tracks every session on your Mac, and gets you back to a session in one click.

## What it shows

- **Live speed:** output tokens per second over the last minute, with a sparkline.
- **Per session:** name, agent, state, project, tokens, cache hit rate and speed.
  *Working*, *Needs reply*, *Waiting on tool or permission* (a tool call with no result for
  over a minute) or *Idle*.
- **Usage:** input, output (and the thinking part of it), cache write and cache read tokens,
  cache hit rate and each session's share, for today, 7 or 30 days.
- **Search:** fuzzy search over the last 30 days of sessions, by name, folder, first prompt
  or branch.
- **Compact mode:** a small floating strip with just the numbers, for all sessions or the
  latest one.
- **Notifications** when a session starts waiting on you (needs the bundled app).

Limits that agents don't write to local logs (for example Claude plan limits) are shown as
not available rather than guessed.

## Getting back to a session

Click a session to open Terminal running `claude --resume <id>` or `codex resume <id>` in the
session's folder. That is the only route that lands on the exact session: the Claude desktop
app's documented `claude://code/new?folder=` link (**Open Folder in Claude Desktop**) opens a
*new* session in the folder. If a link to an existing session appears, it belongs in
`Sources/UsageCore/SessionLinks.swift`.

## How it works

Claude Code writes every session to `~/.claude/projects/<project>/<session-id>.jsonl`
(or under `$CLAUDE_CONFIG_DIR`). The app reads those files every 30 seconds by default (5, 15, 30 or 60, set in the panel), reading only
what was appended. See [docs/DESIGN.md](docs/DESIGN.md) for the details and the caveats.

Codex sessions are read the same way from `~/.codex/sessions/` (or `$CODEX_HOME`), with names
from Codex's thread list. Each agent has its own reader (`UsageSource`) that turns its logs into
the same session summary, so another agent can be added without touching the UI.

## Run it from source

Requires macOS 14+ and Swift 5.9+ (Xcode 15 or later).

```sh
swift run BurnrateApp           # the app (no notifications when run this way)
swift run burnrate --all        # the same numbers as a table in the terminal
swift test
```

## Build and distribute

```sh
scripts/build-app.sh
```

This produces `dist/Burnrate.app`, plus a `.dmg` and `.zip` to share. It needs full
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
