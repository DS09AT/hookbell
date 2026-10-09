#!/bin/bash
# shellcheck disable=SC2016,SC2329  # literal $ and backticks are test data; n is called via expect
# Self-check for hookbell.
#   ./test.sh                 offline: CLI, hook payloads, click targets and hook config lifecycle,
#                             all inside a temporary HOME; sends no notifications (CI-safe)
#   ./test.sh --live SOURCE   additionally posts silent notifications through an authorized SOURCE
set -uo pipefail
cd "$(dirname "$0")" || exit 1
fail=0
T="$(mktemp -d)"
trap 'HOME="$T" ./hookbell uninstall >/dev/null 2>&1; rm -rf "$T"' EXIT

check() {
  local what="$1" got="$2" want="$3"
  what="${what//$'\n'/⏎}"; what="${what:0:100}"
  if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what: got '${got//$'\n'/⏎}', want '${want//$'\n'/⏎}'"; fail=1; fi
}
expect() {
  local want="$1"; shift
  "$@" >/dev/null 2>&1
  check "[$want] ${*:0:6}" "$?" "$want"
}
hb() { HOME="$T" CODEX_HOME="$T/.codex" ./hookbell "$@"; }
json() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$2"; }

# Setup in the temporary HOME
hb install >/dev/null || { echo "FAIL install"; exit 1; }
hb add test "Test" /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns </dev/null >/dev/null

# CLI validation
expect 1 hb send no-such-source --title x
expect 1 hb send ../etc --title x
expect 1 hb send Test --title x
expect 1 hb add test Name /no/icon.png
expect 1 hb hooks nope
expect 1 hb bogus
expect 0 hb list
expect 0 hb version
expect 1 hb send test
expect 1 hb send test --title ""
expect 1 hb send test --title x --nope 1
expect 1 hb send test --title x --body

# Hook payloads -> "title | body | sound | id | targets", or "silent"
hook() {
  local want="$1" payload="$2" got
  if [ "${3:-}" = argv ]; then got="$(hb hook test "$payload" --dry-run --focus none 2>&1 </dev/null)"
  else got="$(printf '%s' "$payload" | hb hook test "" --dry-run --focus none 2>&1)"; fi
  check "hook ${want:0:60}" "$got" "$want"
}
mkdir -p "$T/.codex"
sqlite3 "$T/.codex/state_5.sqlite" "create table threads(id text, thread_source text); insert into threads values('sub','user');"
sqlite3 "$T/.codex/state_12.sqlite" "create table threads(id text, thread_source text); insert into threads values('sub','subagent');"
hook $'repo · DONE | - a\n- b | Hero | test-t1 | ' '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/x/repo","last-assistant-message":"Status: DONE\n\n- a\n- b"}' argv
hook "repo · CLEAN | No findings. | Hero | test-t2 | " '{"type":"agent-turn-complete","thread-id":"t2","cwd":"/x/repo","last-assistant-message":"{\"verdict\":\"CLEAN\",\"summary_en\":\"No findings.\"}"}' argv
hook "silent" '{"type":"agent-turn-complete","thread-id":"sub","cwd":"/x/repo","last-assistant-message":"{}"}' argv
hook "proj · PARTIAL | Open item | Hero | test-s1 | " '{"hook_event_name":"Stop","session_id":"s1","cwd":"/x/proj","last_assistant_message":"```text\nStatus: PARTIAL\n```\nOpen item"}'
hook "proj · Input needed | Claude needs your permission to use Bash | Glass | test-s1 | " '{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/proj","message":"Claude needs your permission to use Bash"}'
hook "proj · Question | Waiting for your answer | Glass | test-s1 | " '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/proj","tool_name":"AskUserQuestion"}'
hook "proj · Done | All done. | Hero | test-g1 | " '{"hook_event_name":"AfterAgent","session_id":"g1","cwd":"/x/proj","prompt_response":"All done."}'
hook "ws · Done | Done. | Hero | test-c1 | " '{"conversationId":"c1","fullyIdle":true,"terminationReason":"NO_TOOL_CALL","error":"","workspacePaths":["/x/ws"]}'
hook "silent" '{"conversationId":"c2","fullyIdle":false,"terminationReason":"NO_TOOL_CALL"}'
hook "silent" '{"conversationId":"c3","fullyIdle":true,"terminationReason":"USER_CANCELED"}'
hook "ws · Error | quota exceeded | Basso | test-c4 | " '{"conversationId":"c4","fullyIdle":true,"error":"quota exceeded","workspacePaths":["/x/ws"]}'
hook "test · Question | Waiting for your answer | Glass | test-c5 | " '{"conversationId":"c5","toolCall":{"name":"ask_question","args":{}}}'
hook "silent" 'not json'
hook "silent" ''

# Click targets detected from the caller's terminal (last field of --dry-run)
targets() { env -u TMUX -u TMUX_PANE -u ITERM_SESSION_ID -u TERM_PROGRAM -u __CFBundleIdentifier "$@" \
  HOME="$T" ./hookbell send test --title x --dry-run | awk -F ' \\| ' '{print $NF}'; }
uuid=00000000-0000-4000-8000-000000000001
mkdir -p "$T/bin" && printf '#!/bin/sh\n' >"$T/bin/tmux" && chmod +x "$T/bin/tmux"
tty_dev="$(ps -o tty= -p $$ | tr -d ' ')"
[[ "$tty_dev" == ttys* ]] && tty_target="tty:/dev/$tty_dev;" || tty_target=""
check "focus iTerm2" "$(targets TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t1p0:$uuid" __CFBundleIdentifier=com.googlecode.iterm2)" "iterm:$uuid;app:com.googlecode.iterm2"
check "focus Terminal.app" "$(targets TERM_PROGRAM=Apple_Terminal __CFBundleIdentifier=com.apple.Terminal)" "${tty_target}app:com.apple.Terminal"
check "focus Ghostty" "$(targets TERM_PROGRAM=ghostty __CFBundleIdentifier=com.mitchellh.ghostty)" "app:com.mitchellh.ghostty"
check "focus tmux in Ghostty" "$(targets TERM_PROGRAM=tmux TMUX=/tmp/tmux-501/default,42,0 TMUX_PANE=%3 PATH="$T/bin:$PATH" __CFBundleIdentifier=com.mitchellh.ghostty)" \
  "tmux:%3:/tmp/tmux-501/default:$T/bin/tmux;app:com.mitchellh.ghostty"
check "focus VS Code uses the payload folder" "$(env -u TMUX -u TMUX_PANE TERM_PROGRAM=vscode __CFBundleIdentifier=com.microsoft.VSCode HOME="$T" \
  ./hookbell hook test '{"conversationId":"c1","fullyIdle":true,"workspacePaths":["/x/ws"]}' --dry-run </dev/null | awk -F ' \\| ' '{print $NF}')" "app:com.microsoft.VSCode:/x/ws"
check "focus none" "$(targets --focus none 2>/dev/null; HOME="$T" ./hookbell send test --title x --focus none --dry-run | awk -F ' \\| ' '{print $NF}')" ""
check "focus explicit list" "$(HOME="$T" ./hookbell send test --title x --focus 'url:https://example.com;app:x' --dry-run | awk -F ' \\| ' '{print $NF}')" "url:https://example.com;app:x"

# Jump targets that must neither hang nor run injected AppleScript
expect 0 hb send test --jump 'iterm:not-a-uuid;tty:/dev/ttys0" & do shell script "touch /tmp/hookbell-pwned;tmux:bogus;app:does.not.exist;bogus'
check "no AppleScript injection" "$([ -e /tmp/hookbell-pwned ] && echo pwned)" ""

# Hook config lifecycle: foreign entries survive, install is idempotent, unhook restores the original
E="$(mktemp -d)"
check "hooks all skips missing tools" "$(HOME="$E" CODEX_HOME="$E/.codex" PATH=/usr/bin:/bin ./hookbell hooks all 2>&1; ls -A "$E")" \
  "hookbell: none of codex claude-code gemini agy is installed"
rm -rf "$E"
mkdir -p "$T/.claude" "$T/.gemini/config" "$T/.gemini/antigravity-cli"
echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]}}' >"$T/.claude/settings.json"
echo '{"hooks":{"enabled":true,"AfterAgent":[{"matcher":"*","hooks":[{"type":"command","command":"other"}]}]}}' >"$T/.gemini/settings.json"
printf 'model = "x"\n\n[tui]\nnotifications = true\n' >"$T/.codex/config.toml"
cp "$T/.claude/settings.json" "$T/claude.orig"; cp "$T/.gemini/settings.json" "$T/gemini.orig"; cp "$T/.codex/config.toml" "$T/codex.orig"
hb hooks all </dev/null >/dev/null && hb hooks all </dev/null >/dev/null
check "claude hooks" "$(json 'sorted(e + ":" + h["command"] for e,v in d["hooks"].items() for x in v for h in x["hooks"])' "$T/.claude/settings.json" | tr -d "'")" \
  '[Notification:"$HOME/.local/bin/hookbell" hook claude-code, PreToolUse:"$HOME/.local/bin/hookbell" hook claude-code, Stop:"$HOME/.local/bin/hookbell" hook claude-code, Stop:other]'
check "claude other keys kept" "$(json 'd["model"]' "$T/.claude/settings.json")" "x"
check "gemini hooks" "$(json 'sorted(e for e,v in d["hooks"].items() if isinstance(v,list) for x in v for h in x["hooks"])' "$T/.gemini/settings.json" | tr -d "'")" \
  "[AfterAgent, AfterAgent, BeforeTool, Notification]"
check "agy hooks" "$(json 'sorted(d["hookbell"])' "$T/.gemini/config/hooks.json" | tr -d "'")" "[PreToolUse, Stop]"
check "codex notify first line" "$(head -1 "$T/.codex/config.toml")" "notify = [\"$T/.local/bin/hookbell\", \"hook\", \"codex\"]"
check "sources created" "$(hb list | awk '{print $1}' | sort | tr '\n' ' ')" "agy claude-code codex gemini test "
hb unhook all >/dev/null
check "claude restored" "$(json 'd' "$T/.claude/settings.json")" "$(json 'd' "$T/claude.orig")"
check "gemini restored" "$(json 'd' "$T/.gemini/settings.json")" "$(json 'd' "$T/gemini.orig")"
check "codex restored" "$(cat "$T/.codex/config.toml")" "$(cat "$T/codex.orig")"
check "agy removed" "$(json '"hookbell" in d' "$T/.gemini/config/hooks.json")" "False"
printf 'notify = ["other"]\n' >"$T/.codex/config.toml"
expect 1 hb hooks codex
check "foreign codex notify kept" "$(cat "$T/.codex/config.toml")" 'notify = ["other"]'
hb uninstall >/dev/null
check "uninstall removes data and link" "$(ls "$T/Library/Application Support/hookbell" "$T/.local/bin/hookbell" 2>/dev/null)" ""

# Live delivery (needs notification permission for SOURCE)
if [ "${1:-}" = --live ]; then
  SOURCE="${2:?usage: ./test.sh --live SOURCE}"
  n() { ./hookbell send "$SOURCE" --sound none --focus none "$@"; }
  expect 0 n --title "hookbell test" --body "plain"
  expect 0 n --title 'Quotes "double" \back\slash $HOME `tick`' --body $'Line 1\nLine 2 · umlauts äöüß · emoji 🚀'
  expect 0 n --title "long" --body "$(printf 'x%.0s' {1..5000})"
  expect 0 n --title "unknown sound" --sound does-not-exist
  expect 0 n --title "missing image" --image /no/such.png
  img="$(mktemp -t hookbell).png"
  sips -s format png -z 64 64 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$img" >/dev/null
  expect 0 n --title "with image" --image "$img"
  check "image original kept" "$([ -f "$img" ] && echo kept)" "kept"
  rm -f "$img"
  expect 0 n --title "replace 1/2" --id hookbell-test
  expect 0 n --title "replace 2/2" --id hookbell-test
  expect 0 ./hookbell hook "$SOURCE" '{"type":"agent-turn-complete","thread-id":"test","cwd":"/x/repo","last-assistant-message":"Status: OK"}'
fi

if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES"; fi
exit "$fail"
