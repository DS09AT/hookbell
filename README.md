# hookbell

Native macOS notifications for AI coding agents and any other command-line tool. Every sender
gets its own name and logo in Notification Center, and a click takes you back to the exact
terminal tab, tmux pane or editor window the notification came from.

- **One app per source.** Codex, Claude Code, Gemini CLI, Antigravity or your own scripts show
  up with their own icon on the left, like real apps, not as "Script Editor".
- **Click to jump back.** iTerm2 session, Terminal.app tab, tmux pane or the editor window of
  the project folder.
- **Agent hooks built in.** `hookbell hook <tool>` reads the agent's hook payload directly: no
  wrapper scripts. Subagent turns and background work stay silent, one notification per session
  replaces the previous one instead of stacking up.
- **Small and local.** One Swift file plus one shell script, no daemon, no network, no
  dependencies besides the Xcode Command Line Tools. A notification takes about 20–30 ms.

## Install

Run this in a terminal, or paste it into your AI agent (Claude Code, Codex, Gemini CLI,
Antigravity) and ask it to run it:

```bash
git clone https://github.com/DS09AT/hookbell.git ~/.hookbell && ~/.hookbell/hookbell install && ~/.hookbell/hookbell hooks all
```

Then click **Allow** in the macOS prompt for each tool and restart running agent sessions. The
command prints exactly that when it is done.

What happens:

- `install` builds hookbell and links it to `~/.local/bin/hookbell`. If the Xcode Command Line
  Tools are missing, it opens their installer; run the command again afterwards.
- `hooks all` sets up every supported AI tool it finds on your Mac (Codex, Claude Code, Gemini
  CLI, Antigravity CLI). Your other hooks and settings stay untouched, and every changed file
  keeps a backup as `*.hookbell.bak`. As soon as you allow notifications for a tool, a
  confirmation notification shows up.
- On the first click on a notification, macOS asks once per tool whether it may control iTerm2
  or Terminal; allow it so the click can select the right tab.

Developed and tested on macOS 27 with Apple silicon; other versions are untested.

### Uninstall

```bash
~/.hookbell/hookbell uninstall && rm -rf ~/.hookbell
```

This removes the hooks, all sources and the CLI link. macOS keeps the notification entries in
System Settings > Notifications until you remove them there.

## Where a click takes you

| Running in | Click jumps to |
|---|---|
| iTerm2 | the exact session (window, tab and split pane) |
| Terminal.app | the exact tab |
| tmux inside iTerm2 or Terminal.app | the pane, then the terminal tab that shows it |
| tmux inside another terminal | the pane, then the terminal app |
| Ghostty and other terminals | the terminal app |
| VS Code, Cursor, Antigravity terminals | the editor window of the project folder |

Ghostty has no scripting interface yet, so hookbell can only bring the app to the front.

## Agents

| Tool | Config | Notifies on |
|---|---|---|
| `codex` | `~/.codex/config.toml` (`notify`) | turn complete; subagent turns stay silent |
| `claude-code` | `~/.claude/settings.json` | Stop, Notification, `AskUserQuestion` |
| `gemini` | `~/.gemini/settings.json` | AfterAgent, Notification, `ask_user` |
| `agy` (Antigravity CLI) | `~/.gemini/config/hooks.json` | Stop (not while busy or cancelled), `ask_question`, `notify_user` |

The title is `<project> · <status>`. The status comes from a `Status: X` line in the agent's
final answer (or a JSON `status`/`verdict`), otherwise it is `Done`, `Question`, `Input needed`
or `Error`. Codex runs only one `notify` command; if you already have one, `hookbell hooks codex`
prints the line to use instead.

`hookbell unhook <tool|all>` removes the hooks again.

## Notifications from anything else

```bash
hookbell add backup "Backup" ~/Pictures/backup.png      # once per sender
hookbell send backup --title "nas · DONE" --body "412 GB in 18 min"
make test; hookbell send build --title "tests · exit $?" --sound Glass
```

| Option | Meaning |
|---|---|
| `--title` (required), `--subtitle`, `--body` | Text |
| `--sound NAME\|default\|none` | macOS system sound (`Hero`, `Glass`, …); unknown names fall back to `default` |
| `--image PATH` | Picture on the right of the banner; the file is copied, not moved |
| `--id KEY` | A notification with the same key replaces the previous one |
| `--focus auto\|none\|TARGETS` | Click targets, default `auto` (detected from your terminal) |
| `--dry-run` | Print `title \| body \| sound \| id \| targets` instead of sending |

`TARGETS` is a `;`-separated list tried in order until one focuses a window:
`iterm:<session-uuid>`, `tty:<device>`, `tmux:<pane>:<socket>:<tmux-binary>`, `url:<url>`,
`app:<bundle-id>[:<folder>]`.

Exit codes: `0` ok · `1` usage · `2` notifications not allowed · `3` delivery failed.
In hook mode hookbell always exits `0`, because Claude Code and Gemini read exit code `2` as
"block".

## Commands

```text
hookbell install                         build, update all sources, link the CLI
hookbell hooks <tool...|all>             add sources and register agent hooks
hookbell unhook <tool...|all>            remove agent hooks
hookbell add <source> <name> <icon>      create a source (PNG, JPG or ICNS; square 1024 px works best)
hookbell authorize <source>              ask for notification permission again
hookbell remove <source> | list          manage sources
hookbell send <source> ... | hook ...    send a notification / handle a hook payload
hookbell uninstall                       remove hooks, sources and the CLI link
hookbell version
```

## How it works

Notification Center always shows the icon of the app that posts a notification. hookbell
therefore generates one tiny app bundle per source in
`~/Library/Application Support/hookbell/Sources/`, each with its own bundle id
(`local.hookbell.<source>`), name and icon, all running the same binary. When you click a
notification, macOS starts that bundle again and it focuses the stored targets via AppleScript
(iTerm2, Terminal.app), `tmux` or Launch Services.

The bundles are built and ad-hoc signed on your Mac, so no Apple Developer account,
notarization or Gatekeeper exception is needed. After a change to `main.swift`, macOS asks once
more per source whether it may control your terminal.

## Development

```bash
./test.sh                 # offline checks in a temporary HOME; also run by CI
./test.sh --live codex    # additionally posts silent notifications through an authorized source
```

## License

[MIT](LICENSE)
