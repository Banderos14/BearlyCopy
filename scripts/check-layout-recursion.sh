#!/bin/sh
# Runs the island's UI tests under lldb with a breakpoint on AppKit's
# _NSDetectedLayoutRecursion ("It's not legal to call -layoutSubtreeIfNeeded
# on a view which is already being laid out"). AppKit logs that warning only
# once per process, so the log cannot show where it comes from; the
# breakpoint fires every time. Prints each hit's Prompt Relay frames and
# exits 1 if there is any. macOS only; read-only (tests use fakes).
set -eu
cd "$(dirname "$0")/../macos"
swift build --build-tests >/dev/null
XCTEST=$(xcrun --find xctest)
BUNDLE="$PWD/.build/out/Products/Debug/PromptRelayKitTests.xctest"
[ -d "$BUNDLE" ] || BUNDLE=$(find .build -path "*Debug*/PromptRelayKitTests.xctest" -maxdepth 5 | head -1)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cmds" <<'LLDB'
settings set target.process.stop-on-exec false
breakpoint set -n _NSDetectedLayoutRecursion
breakpoint command add 1
bt 30
continue
DONE
process launch
quit
LLDB
CLASSES="NotchControllerTests IslandLayoutTests IslandTests DailyUseTests IslandNavigationTests AttachmentHandoffTests TypedAttachmentTests"
FILTER=$(for c in $CLASSES; do printf 'PromptRelayKitTests.%s,' "$c"; done | sed 's/,$//')
lldb -b -s "$TMP/cmds" -- "$XCTEST" -XCTest "$FILTER" "$BUNDLE" > "$TMP/out" 2>&1 || true
HITS=$(grep -c "stop reason = breakpoint" "$TMP/out" || true)
grep -E "Executed [0-9]+ tests" "$TMP/out" | tail -1
echo "layout recursion breakpoint hits: $HITS"
if [ "$HITS" != "0" ]; then
  grep -A30 "stop reason = breakpoint" "$TMP/out" | grep "PromptRelay" | head -20
  exit 1
fi
