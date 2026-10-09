#!/bin/bash
# Self-check for agent-notify. Posts a few silent notifications to SOURCE (default: codex).
# Usage: ./test.sh [source]
set -uo pipefail
cd "$(dirname "$0")"
SOURCE="${1:-codex}"
fail=0

expect() {
  local want="$1"; shift
  "$@" >/dev/null 2>&1
  local got=$?
  local what="${*:2}"
  what="${what//$'\n'/ }"
  if [ "$got" -eq "$want" ]; then echo "ok   [$got] ${what:0:90}"; else echo "FAIL [$got, want $want] ${what:0:90}"; fail=1; fi
}

n() { ./agent-notify send "$SOURCE" --sound none --focus none "$@"; }

# CLI validation
expect 1 ./agent-notify send no-such-source --title x
expect 1 ./agent-notify send ../etc --title x
expect 1 ./agent-notify send Codex --title x
expect 1 ./agent-notify add "$SOURCE" Name /no/icon.png
expect 1 ./agent-notify bogus
expect 0 ./agent-notify list

# Binary validation
expect 1 n
expect 1 n --title ""
expect 1 n --title x --nope 1
expect 1 n --title x --body

# Delivery (needs notification permission for SOURCE)
expect 0 n --title "agent-notify test" --body "plain"
expect 0 n --title 'Quotes "double" \back\slash $HOME `tick`' --body $'Line 1\nLine 2 · umlauts äöüß · emoji 🚀'
expect 0 n --title "long" --body "$(printf 'x%.0s' {1..5000})"
expect 0 n --title "unknown sound" --sound does-not-exist
expect 0 n --title "missing image" --image /no/such.png
img="$(mktemp -t agent-notify).png"
sips -s format png -z 64 64 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$img" >/dev/null
expect 0 n --title "with image" --image "$img"
[ -f "$img" ] && echo "ok   image original kept" || { echo "FAIL image original moved"; fail=1; }
rm -f "$img"
expect 0 n --title "replace 1/2" --id agent-notify-test
expect 0 n --title "replace 2/2" --id agent-notify-test

# Focus targets that must not hang or crash
expect 0 ./agent-notify send "$SOURCE" --jump iterm:not-a-uuid
expect 0 ./agent-notify send "$SOURCE" --jump 'iterm:00000000-0000-0000-0000-000000000000" & do shell script "touch /tmp/pwned'
expect 0 ./agent-notify send "$SOURCE" --jump app:does.not.exist
expect 0 ./agent-notify send "$SOURCE" --jump bogus

[ ! -e /tmp/pwned ] || { echo "FAIL AppleScript injection"; fail=1; }

# Hook payload mapping: title | body | sound | id, or "silent"
hook() {
  local want="$1" payload="$2" got
  if [ "${3:-}" = argv ]; then
    got="$(./agent-notify hook "$SOURCE" "$payload" --dry-run 2>&1 </dev/null)"
  else
    got="$(printf '%s' "$payload" | ./agent-notify hook "$SOURCE" "" --dry-run 2>&1)"
  fi
  if [ "$got" = "$want" ]; then echo "ok   hook → ${want//$'\n'/⏎}"; else echo "FAIL hook: got '${got//$'\n'/⏎}', want '${want//$'\n'/⏎}'"; fail=1; fi
}
S="$SOURCE"
hook $'repo · ERLEDIGT | - a\n- b | Hero | '"$S-t1" '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/x/repo","last-assistant-message":"Status: ERLEDIGT\n\n- a\n- b"}' argv
hook "repo · CLEAN | No findings. | Hero | $S-t2" '{"type":"agent-turn-complete","thread-id":"t2","cwd":"/x/repo","last-assistant-message":"{\"verdict\":\"CLEAN\",\"summary\":\"No findings.\"}"}' argv
sub="$(sqlite3 "$HOME/.codex/state_5.sqlite" "select id from threads where thread_source='subagent' limit 1" 2>/dev/null)"
[ -z "$sub" ] || hook "silent" '{"type":"agent-turn-complete","thread-id":"'"$sub"'","cwd":"/x/repo","last-assistant-message":"{}"}' argv
hook "proj · TEILWEISE | Open item | Hero | $S-s1" '{"hook_event_name":"Stop","session_id":"s1","cwd":"/x/proj","last_assistant_message":"```text\nStatus: TEILWEISE\n```\nOpen item"}'
hook "proj · Input needed | Claude needs your permission to use Bash | Glass | $S-s1" '{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/proj","message":"Claude needs your permission to use Bash"}'
hook "proj · Question | Waiting for your answer | Glass | $S-s1" '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/proj","tool_name":"AskUserQuestion"}'
hook "proj · Done | All done. | Hero | $S-g1" '{"hook_event_name":"AfterAgent","session_id":"g1","cwd":"/x/proj","prompt_response":"All done."}'
hook "ws · Done | Done. | Hero | $S-c1" '{"conversationId":"c1","fullyIdle":true,"terminationReason":"NO_TOOL_CALL","error":"","workspacePaths":["/x/ws"]}'
hook "silent" '{"conversationId":"c2","fullyIdle":false,"terminationReason":"NO_TOOL_CALL"}'
hook "silent" '{"conversationId":"c3","fullyIdle":true,"terminationReason":"USER_CANCELED"}'
hook "ws · Error | quota exceeded | Basso | $S-c4" '{"conversationId":"c4","fullyIdle":true,"error":"quota exceeded","workspacePaths":["/x/ws"]}'
hook "$S · Question | Waiting for your answer | Glass | $S-c5" '{"conversationId":"c5","toolCall":{"name":"ask_question","args":{}}}'
hook "silent" 'not json'
hook "silent" ''
expect 0 ./agent-notify hook "$SOURCE" '{"type":"agent-turn-complete","thread-id":"test","cwd":"/x/repo","last-assistant-message":"Status: OK"}'
[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$fail"
