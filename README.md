# agent-notify

Native macOS notifications for any local tool. Each sender ("source") gets its own
small app bundle, so Notification Center shows that source's name and logo on the left.
A click jumps back to where the notification came from (iTerm2 session, editor window, URL).

No daemon, no network, no dependencies beyond the Xcode command line tools.

## Setup

```bash
./agent-notify install                                   # build, link to ~/.local/bin
agent-notify add codex "Codex" /path/to/logo.png         # PNG/JPG/ICNS, square 1024 px works best
```

`add` asks macOS for notification permission and waits for your answer. The first click
on a notification asks once whether that source may control iTerm2.

## Send

```bash
agent-notify send codex --title "my-repo · DONE" --body "3 commits pushed"
```

| Option | Meaning |
|---|---|
| `--title` (required), `--subtitle`, `--body` | Text |
| `--sound NAME\|default\|none` | macOS system sound name (`Hero`, `Glass`, …); unknown names fall back to `default` |
| `--image PATH` | Picture shown on the right of the banner; the file is copied, not moved |
| `--id KEY` | Same key replaces the previous notification instead of stacking |
| `--focus auto\|none\|TARGET` | Click target, default `auto` |

Click targets: `iterm:<session-uuid>`, `url:<url>`, `app:<bundle-id>[:<folder>]`.
`auto` uses the iTerm2 session (`ITERM_SESSION_ID`), the VS Code-like editor window for the
current folder (`TERM_PROGRAM=vscode`), or the calling app (`__CFBundleIdentifier`).

Exit codes: `0` ok · `1` usage · `2` notifications not allowed · `3` delivery failed.

## Hooks

Tools call agent-notify directly; it reads their hook payload and builds the notification
(`<repo> · <status>`, one per session via `--id`). No wrapper scripts.

```bash
agent-notify hook <source> [PAYLOAD]    # PAYLOAD as argument (Codex) or JSON on stdin (others)
agent-notify hook <source> "" --dry-run # print title | body | sound | id instead of sending
```

| Source | Hook config | Command | Events |
|---|---|---|---|
| `codex` | `~/.codex/config.toml` (`notify`) | `agent-notify hook codex` | turn complete; subagent turns stay silent |
| `claude-code` | `~/.claude/settings.json` | `"$HOME/.local/bin/agent-notify" hook claude-code` | Stop, Notification, PreToolUse `AskUserQuestion` |
| `agy` | `~/.gemini/config/hooks.json` | `"$HOME/.local/bin/agent-notify" hook agy` | Stop (silent while busy or cancelled), PreToolUse `ask_question\|notify_user` |
| `gemini` | `~/.gemini/settings.json` | `"$HOME/.local/bin/agent-notify" hook gemini` | AfterAgent, Notification, BeforeTool `ask_user` |

A final answer's `Status: X` line (or a JSON `Status`/`verdict`) becomes the title status.
Hook mode always exits `0`, because Claude Code and Gemini read exit code `2` as "block".

## Manage

```bash
agent-notify list
agent-notify authorize <source>    # ask for permission again
agent-notify remove <source>
./agent-notify install             # after changing main.swift: rebuilds and updates all sources
./test.sh [source]                 # self-check, posts a few silent notifications
```

Bundles live in `~/Library/Application Support/AgentNotify/Sources/`. They are ad-hoc signed;
the build is deterministic, so permissions survive `install` until `main.swift` changes. After a
code change macOS asks once more per source whether it may control iTerm2.
