# Design

## Goals

1. Show token usage per Claude Code session, and in total.
2. Show how fast tokens are being generated.
3. Keep sessions that run at the same time apart.
4. Make it one click to get back to a session that needs a response.
5. Be easy to build and hand to other people.

## Data source

Claude Code appends one JSON object per line to
`~/.claude/projects/<encoded cwd>/<session id>.jsonl`. Subagent transcripts go to
`<session id>/subagents/*.jsonl` and carry the parent's `sessionId`. The format is internal to
Claude Code and changes between versions, so `LogEntry` decodes only the fields used here and
treats all of them as optional.

The lines that matter:

| `type` | Used for |
| --- | --- |
| `user` | A typed prompt (`content` is a string) or a tool result (`content` holds `tool_result` blocks). Marks the start of the next model response. The first typed, non-meta prompt becomes the session title. |
| `assistant` | One content block of a model response. `message.id` identifies the response and `message.usage` its tokens. A response with several blocks is written as several lines **with the same id and the same usage**, so lines are merged by `message.id` and counted once. |
| `summary` | A title Claude Code generated for the session, preferred when present. |

Other line types (`attachment`, `queue-operation`, `system`, …) are ignored.

## Numbers

- **Tokens** come straight from `usage`: `input_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `output_tokens`. *Total* is the sum of all four.
- **Speed** of one response is `output_tokens / (time of its last line − time of the line that
  prompted it)`. That is end-to-end speed including time to first token, not the pure streaming
  rate, which the logs don't record. Responses under half a second are ignored.
  Session *average* = all timed output tokens / all timed seconds; *recent* = the same over the
  last five timed responses. The menu bar's *live* figure adds up the recent speed of every
  session currently in the Working state.
- **Resumed sessions** can replay earlier messages into a new file. Each `message.id` is
  counted for the first session that reports it, so totals don't double.

## State

Derived from the last main-chain `user`/`assistant` line:

| Last line | Age | State |
| --- | --- | --- |
| prompt or tool result | < 10 min | Working |
| assistant tool call | < 1 min | Working |
| assistant tool call | < 2 h | Waiting on tool or permission |
| assistant text | < 2 h | Needs reply |
| anything older | | Idle |

These are inferences from timing. A long-running command shows as *Waiting on tool or
permission* after a minute, and a turn interrupted with Esc can look like *Working* for up to
ten minutes.

## Updating

`UsageStore.refresh()` runs every two seconds on a background queue. It lists `.jsonl` files,
skips those whose size hasn't changed and those not modified in seven days, and for the rest
reads only the bytes appended since last time (`JSONLTailer`). A partial last line is held
until its newline arrives. If a file ever shrinks, everything is rebuilt.

## Getting back to a session

- `claude --resume <id>` in the session's folder resumes that exact session. The app writes a
  `.command` script and opens it, which starts Terminal without needing Automation permission.
- The Claude desktop app documents `claude://code/new?folder=<path>` (a new Claude Code session
  in a folder) and `claude://claude.ai/chat/<id>` (an existing claude.ai chat). It documents no
  link to an existing Claude Code session, so "Open in Claude Desktop" can only open the folder.
  Sessions started from the desktop app still appear in the tracker if they write to the same
  `~/.claude/projects` directory; their `entrypoint` field is shown in the detail pane.

## Layout

```
Sources/UsageCore/          parsing and aggregation (Foundation only)
Sources/ClaudeUsageTracker/ SwiftUI app: menu bar extra, sessions window, actions
Sources/claude-usage/       CLI that prints the same numbers
Tests/UsageCoreTests/       XCTest against generated log fixtures
scripts/build-app.sh        .app bundle, signing, notarization, .dmg and .zip
.github/workflows/          CI on every push, signed releases on tags
```

## Not done yet

- claude.ai and desktop-app chat conversations: they are stored server-side, not in local
  logs, so they aren't tracked.
- Cost in dollars (needs a per-model price table).
- Clicking a notification doesn't yet select its session.
- An app icon.
