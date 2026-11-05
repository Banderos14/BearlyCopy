#!/usr/bin/env bash
# Install the current checkout as "~/Applications/Prompt Relay.app" — the
# developer's way to run the newest Release build without Xcode (Phase 11).
#
#   scripts/install-local.sh --dry-run     build and verify, show the plan, change nothing
#   scripts/install-local.sh               build, verify, ask, then install and launch
#   scripts/install-local.sh --yes         same without the question (you consent up front)
#   scripts/install-local.sh --no-build    install macos/build/Prompt Relay.app as it is
#   scripts/install-local.sh --status      what is installed, what runs, what the checkout is
#   scripts/install-local.sh --rollback    put the newest backup back (asks first)
#   scripts/install-local.sh --list-backups
#
# What it touches, and nothing else:
#   ~/Applications/Prompt Relay.app                       replaced (old copy kept as a backup)
#   ~/Library/Application Support/PromptRelay-AppBackups/  backups of replaced apps
# It never touches history, settings or integrations
# (~/Library/Application Support/PromptRelay, the app's preferences, Claude
# Code / Codex configuration, hooks or trust records). Running copies of the
# installed Release app are asked to quit normally, only after you agree;
# the Debug (Xcode) build is never quit — it is only reported.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(pwd)

release_id="io.github.banderos14.PromptRelay"
debug_id="io.github.banderos14.PromptRelay.debug"
dest_dir="${PROMPT_RELAY_INSTALL_DIR:-$HOME/Applications}"
dest="$dest_dir/Prompt Relay.app"
backups="${PROMPT_RELAY_BACKUP_DIR:-$HOME/Library/Application Support/PromptRelay-AppBackups}"
built="$repo/macos/build/Prompt Relay.app"
data_dir="$HOME/Library/Application Support/PromptRelay"

mode=install; dry=0; yes=0; build=1; launch=1
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        --yes|-y) yes=1 ;;
        --no-build) build=0 ;;
        --no-launch) launch=0 ;;
        --status) mode=status ;;
        --rollback) mode=rollback ;;
        --list-backups) mode=list ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'install-local: %s\n' "$*" >&2; exit 1; }

# Safety: never operate on the data dir or anything outside the two places above.
case "$dest" in "$data_dir"*) die "refusing: destination inside the data dir" ;; esac
case "$backups" in "$data_dir"|"$data_dir/"*) die "refusing: backups inside the data dir" ;; esac

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || echo "-"; }

describe() { # app path → one line
    if [ -d "$1" ]; then
        printf '%s · commit %s%s · built %s' "$(plist_get "$1" CFBundleShortVersionString)" \
            "$(plist_get "$1" PRGitCommit)" \
            "$([ "$(plist_get "$1" PRGitDirty)" = yes ] && echo ' (uncommitted changes)')" \
            "$(plist_get "$1" PRBuildDate)"
    else
        printf 'not installed'
    fi
}

pids_of() { # bundle id → PIDs of every running copy (LaunchServices, any location)
    local asn
    for asn in $(lsappinfo find "bundleid=$1" 2>/dev/null); do
        lsappinfo info -only pid "$asn" 2>/dev/null | grep -Eo 'pid"? ?= ?[0-9]+' | grep -Eo '[0-9]+$'
    done
}

exe_of() { /bin/ps -o comm= -p "$1" 2>/dev/null || true; }

all_release_pids() { pids_of "$release_id"; }

installed_release_pids() { # release copies running from $dest
    local pid
    for pid in $(pids_of "$release_id"); do
        case "$(exe_of "$pid")" in "$dest/Contents/MacOS/"*) echo "$pid" ;; esac
    done
}

confirm() {
    [ "$yes" = 1 ] && return 0
    [ -t 0 ] || die "not a terminal: re-run with --yes to agree up front, or --dry-run"
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) say "Nothing changed."; exit 0 ;; esac
}

quit_installed() {
    local pids
    pids=$(all_release_pids | tr '\n' ' ')
    [ -n "${pids// /}" ] || return 0
    say "== asking Prompt Relay (PID $pids) to quit"
    # A normal quit request (NSApplication terminate), never a kill.
    osascript -e "tell application id \"$release_id\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(all_release_pids)" ] && return 0
        sleep 1
    done
    # The quit request can be refused by macOS (Automation permission for
    # this terminal) or by the app. Ask before the plain TERM signal.
    if [ "$yes" = 1 ] || { [ -t 0 ] && printf 'Still running. Send it a normal TERM signal? [y/N] ' && read -r a && [ "$a" = y -o "$a" = Y ]; }; then
        kill -TERM $(all_release_pids) 2>/dev/null || true
        for _ in 1 2 3 4 5; do [ -z "$(all_release_pids)" ] && return 0; sleep 1; done
    fi
    die "Prompt Relay is still running (PID $(all_release_pids | tr '\n' ' ')). Quit it from its menu, then run this again. Nothing was replaced."
}

verify_bundle() { # app → checks, dies on failure
    local app=$1 head version core_version digest_repo digest_app
    [ -x "$app/Contents/MacOS/PromptRelay" ] || die "no executable in $app"
    codesign --verify --strict "$app" || die "code signature of $app does not verify"
    version=$(plist_get "$app" CFBundleShortVersionString)
    core_version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$app/Contents/Resources/core/plugin/prompt_relay/__init__.py")
    [ "$version" = "$core_version" ] || die "app version $version differs from its bundled Core $core_version"
    digest_app=$(scripts/core-digest.sh "$app/Contents/Resources/core")
    [ "$digest_app" = "$(plist_get "$app" PRCoreDigest)" ] || die "bundled Core does not match the digest recorded at build time"
    if [ "$mode" = install ]; then
        head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
        digest_repo=$(scripts/core-digest.sh "$repo")
        [ "$(plist_get "$app" PRGitCommit)" = "$head" ] || die "build is from $(plist_get "$app" PRGitCommit), checkout is at $head — rebuild (drop --no-build)"
        [ "$digest_app" = "$digest_repo" ] || die "bundled Core differs from this checkout's Core — rebuild"
    fi
    say "   verified: signature, version $version = Core $core_version, Core digest ${digest_app:0:12}…"
}

show_running() {
    local r d
    r=$(all_release_pids | tr '\n' ' ')
    d=$(pids_of "$debug_id" | tr '\n' ' ')
    say "Running:    Release ${r:-none}   Debug (Xcode) ${d:-none}"
}

swap_in() { # source app → installs at $dest, keeping the old one as a backup
    local src=$1 stamp backup tmp
    stamp=$(date +%Y%m%d-%H%M%S)
    tmp="$dest_dir/.Prompt Relay.app.installing-$stamp"
    mkdir -p "$dest_dir" "$backups"
    chmod 700 "$backups"
    ditto "$src" "$tmp"
    codesign --verify --strict "$tmp" || { rm -rf "$tmp"; die "copied app does not verify; nothing replaced"; }
    if [ -d "$dest" ]; then
        backup="$backups/Prompt Relay $(plist_get "$dest" CFBundleShortVersionString)-$(plist_get "$dest" PRGitCommit)-$stamp.app"
        mv "$dest" "$backup"
        say "== previous app kept: $backup"
    fi
    mv "$tmp" "$dest"
    say "== installed $dest"
}

launch_and_check() {
    [ "$launch" = 1 ] || { say "== not launched (--no-launch)"; return 0; }
    open "$dest"
    local pids=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pids=$(installed_release_pids | tr '\n' ' ')
        [ -n "${pids// /}" ] && break
        sleep 1
    done
    local count others
    count=$(printf '%s\n' $pids | grep -c . || true)
    others=$(all_release_pids | tr '\n' ' ')
    if [ "$count" = 1 ] && [ "$(printf '%s' "$others" | tr -d ' ')" = "$(printf '%s' "$pids" | tr -d ' ')" ]; then
        say "== running: one Release copy, PID $pids, from $dest"
    elif [ "$count" = 0 ]; then
        die "the app did not start within 10 s; open it from $dest and check Console"
    else
        say "!! more than one Release copy runs: $others — quit the extra ones from their menu"
    fi
    local dbg
    dbg=$(pids_of "$debug_id" | tr '\n' ' ')
    [ -z "${dbg// /}" ] || say "note: the Debug build from Xcode is running too (PID $dbg); the Release app steps aside at the notch while it runs. Stop it in Xcode to use the installed app."
}

case "$mode" in
status)
    say "Checkout:   $(git rev-parse --short HEAD)$([ -n "$(git status --porcelain --untracked-files=no -- macos/Sources bin plugin)" ] && echo ' + uncommitted changes') · Core $(sed -n 's/^__version__ = "\(.*\)"/\1/p' plugin/prompt_relay/__init__.py)"
    say "Installed:  $(describe "$dest")  ($dest)"
    show_running
    if [ -d "$dest" ] && [ "$(plist_get "$dest" PRGitCommit)" != "$(git rev-parse --short HEAD)" ]; then
        say "The installed app is not built from the current checkout. Update: scripts/install-local.sh --dry-run, then without --dry-run."
    fi
    exit 0 ;;
list)
    ls -1d "$backups"/*.app 2>/dev/null || say "no backups in $backups"
    exit 0 ;;
rollback)
    latest=$(ls -1td "$backups"/*.app 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || die "no backup to roll back to in $backups"
    say "Installed now: $(describe "$dest")"
    say "Roll back to:  $(describe "$latest")"
    say "               $latest"
    show_running
    verify_bundle "$latest"
    if [ "$dry" = 1 ]; then say "Dry run: nothing changed."; exit 0; fi
    confirm "Quit the running Release app (if any), keep the current app as a backup and restore this one?"
    quit_installed
    swap_in "$latest"
    rm -rf "$latest"   # it is now the installed app; the replaced one became a new backup
    launch_and_check
    exit 0 ;;
esac

# install
for tool in git swift codesign ditto shasum /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool (install Xcode or the Command Line Tools)"
done
if [ -n "$(git status --porcelain --untracked-files=no -- macos/Sources bin plugin)" ]; then
    say "note: the checkout has uncommitted changes in macos/Sources, bin or plugin; the build will be marked so in About."
fi

if [ "$build" = 1 ]; then
    scripts/build-macos-app.sh
else
    [ -d "$built" ] || die "no build at $built (drop --no-build)"
fi

say ""
say "== plan"
say "New build:  $(describe "$built")"
verify_bundle "$built"
say "Installed:  $(describe "$dest")"
show_running
say "Keeps:      history, settings and integrations ($data_dir, app preferences, Claude/Codex config) — untouched"
[ -d "$dest" ] && say "Backup to:  $backups/"
say "Then:       install to $dest$([ "$launch" = 1 ] && echo ', open it, check one copy runs')"
say "Undo:       scripts/install-local.sh --rollback"

if [ "$dry" = 1 ]; then say ""; say "Dry run: nothing changed."; exit 0; fi
confirm "Quit the running Release app (if any) and install this build?"
quit_installed
swap_in "$built"
launch_and_check
