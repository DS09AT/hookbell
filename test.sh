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
expect 0 n --title 'Quotes "double" \back\slash $HOME `tick`' --body $'Zeile 1\nZeile 2 · Umlaute äöüß · Emoji 🚀'
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
[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$fail"
