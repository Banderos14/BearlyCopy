#!/usr/bin/env bash
# Run the latest Debug build of Prompt Relay from THIS checkout, safely.
#
#   scripts/run-latest-debug.sh            dry run: show what runs now and what would happen
#   scripts/run-latest-debug.sh --build    also build the Debug app (nothing is quit or started)
#   scripts/run-latest-debug.sh --switch   build, quit the running Debug copy normally, start the new one
#       add --quit-release                 also quit the installed Release copy normally
#
# Safety (Phase 15.2):
# - Never force-quits (no kill, no -9): it asks a copy to Quit like the menu
#   does and waits up to 15 s; if it does not quit, it stops and says so.
# - Never touches ~/Applications/Prompt Relay.app, the Claude Code plugin,
#   your history (~/Library/Application Support/PromptRelay) or System Settings.
# - The build goes to macos/build/xcode-debug inside this checkout (ignored by Git).
# - macOS may ask once whether Terminal may control "Prompt Relay" (that is
#   how a normal Quit is sent). If you decline, quit it from its menu-bar icon
#   or Settings → About instead and run --switch again.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=dry; quit_release=0
for arg in "$@"; do
    case "$arg" in
        --build) mode=build ;;
        --switch) mode=switch ;;
        --quit-release) quit_release=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

release_id=io.github.banderos14.PromptRelay
debug_id=io.github.banderos14.PromptRelay.debug
derived="macos/build/xcode-debug"
new_app="$derived/Build/Products/Debug/Prompt Relay.app"
head=$(git rev-parse --short HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }

# Running copies: one line each — kind, version, commit, location.
running_copies() {
    ps -axo pid=,command= | while read -r pid cmd; do
        case "$cmd" in
            *"Prompt Relay.app/Contents/MacOS/"*|*"PromptRelay.app/Contents/MacOS/"*) ;;
            *) continue ;;
        esac
        app="${cmd%%/Contents/MacOS/*}"
        id=$(plist "$app" CFBundleIdentifier)
        case "$id" in "$release_id") kind=Release ;; "$debug_id") kind=Debug ;; *) continue ;; esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$(plist "$app" CFBundleShortVersionString)" "$(plist "$app" PRGitCommit)" "$pid" "$app"
    done
}

echo "== This checkout: branch $branch, commit $head"
echo "== Prompt Relay copies running now:"
copies=$(running_copies)
if [ -z "$copies" ]; then echo "   none"; else
    printf '%s\n' "$copies" | while IFS=$'\t' read -r kind ver commit pid app; do
        echo "   $kind $ver · commit $commit · $(echo "$app" | sed "s|$HOME|~|")"
    done
fi
echo "== The new Debug build: $new_app (commit $head once built)"

if [ "$mode" = dry ]; then
    echo
    echo "Dry run — nothing was built, quit or started. Next:"
    echo "   scripts/run-latest-debug.sh --build    # build only"
    echo "   scripts/run-latest-debug.sh --switch   # build, quit the old Debug copy normally, start the new one"
    echo "The installed Release app is left running unless you add --quit-release;"
    echo "it steps aside at the notch while a Debug copy runs."
    exit 0
fi

echo "== Building Debug (takes a minute or two)…"
mkdir -p "$derived"
if ! xcodebuild -workspace macos/PromptRelay.xcworkspace -scheme "Prompt Relay" -configuration Debug \
        -derivedDataPath "$derived" build >"$derived.log" 2>&1; then
    echo "Build failed. Nothing was quit or started. Log: $derived.log" >&2
    exit 1
fi
built=$(plist "$new_app" PRGitCommit)
echo "   built: $(plist "$new_app" CFBundleShortVersionString), commit $built"
[ "$mode" = build ] && { echo "Build only — nothing was quit or started."; exit 0; }

quit_id() {   # Ask every copy with this bundle id to quit normally; wait up to 15 s.
    local id=$1 name=$2
    [ -n "$(running_copies | awk -F'\t' -v k="$name" '$1==k')" ] || return 0
    echo "== Asking $name to quit (normal Quit)…"
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        [ -z "$(running_copies | awk -F'\t' -v k="$name" '$1==k')" ] && { echo "   $name quit."; return 0; }
        sleep 0.5
    done
    echo "$name is still running. Quit it from its menu-bar icon (or Settings → About), then run --switch again." >&2
    echo "Nothing else was changed." >&2
    exit 1
}

quit_id "$debug_id" Debug
[ "$quit_release" = 1 ] && quit_id "$release_id" Release

echo "== Starting the new Debug build…"
open "$new_app"
for _ in $(seq 1 20); do
    line=$(running_copies | awk -F'\t' '$1=="Debug"')
    [ -n "$line" ] && break
    sleep 0.5
done
if [ -z "${line:-}" ]; then echo "The new copy did not start. Open it yourself: open \"$new_app\"" >&2; exit 1; fi
running_commit=$(printf '%s' "$line" | cut -f3)
echo "   running: Debug, commit $running_commit"
if [ "$running_commit" = "$head" ]; then
    echo "OK — Settings → About should say: Build Debug (Xcode), Commit $head."
else
    echo "Warning: the running Debug copy reports commit $running_commit, expected $head." >&2
fi
echo
echo "Screenshots: a rebuilt Debug app may count as new for macOS Screen Recording."
echo "If auto screenshots say Permission required although \"Prompt Relay Dev\" is switched on,"
echo "switch it off and on again in System Settings, then use Check Again (or quit and reopen)."
