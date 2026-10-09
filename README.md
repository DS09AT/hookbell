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
Callers can fall back to `osascript` on `2`/`3`.

## Hooked tools

| Source | Hook config | Adapter | Events |
|---|---|---|---|
| `codex` | `~/.codex/config.toml` (`notify`) | `~/.codex/notify.py` | turn complete (subagent turns filtered) |
| `claude-code` | `~/.claude/settings.json` | `~/.claude/notify.sh` | Stop, permission/idle prompt, AskUserQuestion |
| `agy` | `~/.gemini/config/hooks.json` | `~/.gemini/antigravity-cli/notify.py` | Stop (only when fully idle), `ask_question`/`notify_user` |
| `gemini` | `~/.gemini/settings.json` | `~/.gemini/notify.sh` | AfterAgent, Notification, `ask_user` |

Every adapter sends one notification per session (`--id`) and falls back to `osascript` or stays silent if agent-notify fails.

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
