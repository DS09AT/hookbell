# hookbell

Native macOS notifications for command-line tools and AI coding agents.

- Each sender shows up in Notification Center with its own name and icon.
- Click a notification to return to the iTerm2 session, Terminal.app tab, tmux pane or editor
  window it came from.
- You connect Codex, Claude Code, Gemini CLI and the Antigravity CLI with one command.
- hookbell skips subagent turns and keeps one notification per session.
- The whole tool is one Swift file plus a shell script and works offline.

## Install

```bash
git clone https://github.com/DS09AT/hookbell.git ~/.hookbell && ~/.hookbell/hookbell install && ~/.hookbell/hookbell hooks all
```

`install` builds hookbell and links it to `~/.local/bin/hookbell`. If the Xcode Command Line Tools
are missing, it opens their installer, and you run the command again afterwards. `hooks all`
connects the supported agents it finds on your Mac and saves a backup of each file it changes as
`*.hookbell.bak`.

macOS then asks for each agent whether it may send notifications. After you click Allow, a test
notification appears. Restart running agent sessions so they load the hooks. On your first click
on a notification, macOS asks once whether hookbell may control iTerm2 or Terminal, which hookbell
needs to select the tab.

## Uninstall

```bash
~/.hookbell/hookbell uninstall && rm -rf ~/.hookbell
```

macOS keeps the entries in System Settings > Notifications until you delete them there.

## Agents

hookbell titles each notification `<project> · <status>`. It reads the status from a `Status: X`
line or a JSON `status` or `verdict` field in the agent's last answer and otherwise uses Done,
Question, Input needed or Error.

Codex accepts a single `notify` command. If you already use one, `hookbell hooks codex` prints the
line to put there instead.

| Agent | Config file | Notifies when |
|---|---|---|
| `codex` | `~/.codex/config.toml` | a turn ends, except in subagents |
| `claude-code` | `~/.claude/settings.json` | Claude stops, needs a permission or asks a question |
| `gemini` | `~/.gemini/settings.json` | a turn ends, Gemini needs a permission or `ask_user` runs |
| `agy` (Antigravity CLI) | `~/.gemini/config/hooks.json` | the agent stops with nothing left running, or asks a question |

## Click targets

| Terminal | Opens |
|---|---|
| iTerm2 | the session, including its window, tab and split pane |
| Terminal.app | the tab |
| tmux in iTerm2 or Terminal.app | the pane, then the terminal tab that shows it |
| tmux in another terminal | the pane, then the terminal app |
| VS Code, Cursor, Antigravity | the editor window of the project folder |
| Ghostty and other terminals | the terminal app |

## Custom sources

Any script can send notifications through its own source:

```bash
hookbell add backup "Backup" ~/Pictures/backup.png
hookbell send backup --title "nas · DONE" --body "412 GB in 18 min"
```

`--focus` takes `auto` or a `;`-separated list of targets that hookbell tries in order:
`iterm:<session-uuid>`, `tty:<device>`, `tmux:<pane>:<socket>:<tmux-binary>`, `url:<url>` or
`app:<bundle-id>[:<folder>]`.

`send` exits with `0` on success, `1` on a usage error, `2` when notifications are not allowed and
`3` when delivery fails. `hook` exits with `0` even when sending fails, because Claude Code and
Gemini read `2` as a request to block the agent.

| Option | Effect |
|---|---|
| `--title` (required), `--subtitle`, `--body` | Text |
| `--sound NAME\|default\|none` | System sound such as `Hero` or `Glass`; unknown names play `default` |
| `--image PATH` | Picture on the right of the banner |
| `--id KEY` | Replaces the earlier notification with the same key |
| `--focus auto\|none\|TARGETS` | Where a click goes |
| `--dry-run` | Prints `title \| body \| sound \| id \| targets` without sending |

## Commands

```text
hookbell install                       build, update all sources and link the CLI
hookbell hooks <agent...|all>          add sources and register agent hooks
hookbell unhook <agent...|all>         remove agent hooks
hookbell add <source> <name> <icon>    create a source from a PNG, JPG or ICNS icon
hookbell authorize <source>            ask for notification permission again
hookbell remove <source>               delete a source
hookbell list                          show all sources
hookbell send <source> [options]       send a notification
hookbell hook <source> [payload]       turn an agent hook payload into a notification
hookbell uninstall                     remove hooks, sources and the CLI link
hookbell version                       print the version
```

## License

[MIT](LICENSE)
