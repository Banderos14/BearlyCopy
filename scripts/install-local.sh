#!/usr/bin/env bash
# Install or update BearlyCopy from this checkout as a normal Mac app that
# you open from Applications — no Xcode needed to use it (Phases 11, 16).
#
#   scripts/install-local.sh --status      what is installed, what runs, what this checkout is
#   scripts/install-local.sh --dry-run     build and verify, show the plan, change nothing
#   scripts/install-local.sh               build, check, verify, ask, then install, launch and verify
#   scripts/install-local.sh --rollback    put the newest backup back (asks first)
#   scripts/install-local.sh --list-backups
#   scripts/install-local.sh --tidy        move stray old copies out of Applications into the backups (asks)
#
# Options:
#   --yes             agree up front (no questions; still never force-quits)
#   --quit-debug      also ask a running Debug build ("BearlyCopy Dev") to quit normally,
#                     so the installed app is the one at the notch (asked when interactive)
#   --system          install into /Applications instead of ~/Applications (one location only)
#   --sign IDENTITY   sign with this code-signing identity instead of ad-hoc, e.g.
#                     --sign "Apple Development" (keeps Screen Recording permission across updates)
#   --no-build        install macos/build/BearlyCopy.app as it is: built from HEAD, or from an
#                     earlier commit when only files outside the app's sources changed since
#   --no-launch       install without opening the app
#   --skip-checks     skip the pre-install Core smoke test (not recommended)
#
# What it touches, and nothing else:
#   ~/Applications/BearlyCopy.app (or /Applications with --system)  replaced, old copy kept as a backup
#   ~/Library/Application Support/PromptRelay-AppBackups/              backups (never deleted by this script)
# If anything fails before the new app is in place, the installed app is
# untouched (and reopened if it had been quit). If the new app does not
# start, the previous one is put back and opened, and the failed one is kept
# in the backups marked "(failed launch)".
#
# It never touches history, settings or integrations
# (~/Library/Application Support/PromptRelay, the app's preferences, Claude
# Code / Codex configuration, plugins, hooks or trust records). It never
# pulls or downloads code. Running copies are asked to quit normally (like
# Quit in the menu), only after you agree; nothing is ever force-quit.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(pwd)

release_id="${PROMPT_RELAY_RELEASE_ID:-io.github.banderos14.PromptRelay}"
debug_id="${PROMPT_RELAY_DEBUG_ID:-io.github.banderos14.PromptRelay.debug}"
user_apps="$HOME/Applications"
system_apps="/Applications"
backups="${PROMPT_RELAY_BACKUP_DIR:-$HOME/Library/Application Support/PromptRelay-AppBackups}"
built="${PROMPT_RELAY_BUILT_APP:-$repo/macos/build/BearlyCopy.app}"
data_dir="$HOME/Library/Application Support/PromptRelay"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mode=install; dry=0; yes=0; build=1; launch=1; checks=1; quit_debug=0; location=user
sign_identity="${PROMPT_RELAY_SIGN_IDENTITY:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --yes|-y) yes=1 ;;
        --no-build) build=0 ;;
        --no-launch) launch=0 ;;
        --skip-checks) checks=0 ;;
        --quit-debug) quit_debug=1 ;;
        --system) location=system ;;
        --sign) shift; [ $# -gt 0 ] || { echo "--sign needs an identity" >&2; exit 2; }; sign_identity=$1 ;;
        --status) mode=status ;;
        --rollback) mode=rollback ;;
        --list-backups) mode=list ;;
        --tidy) mode=tidy ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "${PROMPT_RELAY_INSTALL_DIR:-}" ]; then dest_dir=$PROMPT_RELAY_INSTALL_DIR
elif [ "$location" = system ]; then dest_dir=$system_apps
else dest_dir=$user_apps; fi
dest="$dest_dir/BearlyCopy.app"
# The other Applications folder, where a second installed copy would compete.
if [ -n "${PROMPT_RELAY_INSTALL_DIR:-}" ]; then other_dir="${PROMPT_RELAY_OTHER_DIR:-}"
elif [ "$location" = system ]; then other_dir=$user_apps
else other_dir=$system_apps; fi

say() { printf '%s\n' "$*"; }
die() { printf 'install-local: %s\n' "$*" >&2; exit 1; }
tilde() { printf '%s' "${1/#$HOME/~}"; }

# Safety: never operate on the data dir; never keep backups where macOS lists apps.
case "$dest" in "$data_dir"|"$data_dir/"*) die "refusing: destination inside the data dir" ;; esac
case "$backups" in "$data_dir"|"$data_dir/"*) die "refusing: backups inside the data dir" ;; esac
case "$backups" in "$dest_dir"|"$dest_dir/"*) die "refusing: backups inside an Applications folder (macOS would list them as apps)" ;; esac

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || echo "-"; }
# For use in file names: only [A-Za-z0-9._-], at most 40 characters.
safe() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-40; }

signing_of() { # app → "ad-hoc signed" / "signed: <authority>"
    local info
    info=$(codesign -dv --verbose=2 "$1" 2>&1 || true)
    case "$info" in
        *"Signature=adhoc"*) printf 'ad-hoc signed' ;;
        *Authority=*) printf 'signed: %s' "$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)" ;;
        *) printf 'signature unknown' ;;
    esac
}

describe() { # app path → one line
    if [ -d "$1" ]; then
        printf '%s · commit %s%s · built %s · %s' "$(plist_get "$1" CFBundleShortVersionString)" \
            "$(plist_get "$1" PRGitCommit)" \
            "$([ "$(plist_get "$1" PRGitDirty)" = yes ] && echo ' (uncommitted changes)')" \
            "$(plist_get "$1" PRBuildDate)" "$(signing_of "$1")"
    else
        printf 'not installed'
    fi
}

pids_of() { # bundle id → PIDs of every running copy (LaunchServices, any location)
    [ "${PROMPT_RELAY_TEST_NO_PROCESSES:-0}" = 1 ] && return 0
    local asn
    for asn in $(lsappinfo find "bundleid=$1" 2>/dev/null); do
        lsappinfo info -only pid "$asn" 2>/dev/null | grep -Eo 'pid"? ?= ?[0-9]+' | grep -Eo '[0-9]+$' || true
    done
}

exe_of() { /bin/ps -o comm= -p "$1" 2>/dev/null || true; }
all_release_pids() { pids_of "$release_id"; }
debug_pids() { pids_of "$debug_id"; }

installed_release_pids() { # release copies running from $dest
    local pid
    for pid in $(pids_of "$release_id"); do
        case "$(exe_of "$pid")" in "$dest/Contents/MacOS/"*) echo "$pid" ;; esac
    done
}

# Other BearlyCopy bundles in the Applications folders (old copies,
# renamed backups): macOS lists each in Spotlight and Launchpad, and opening
# one starts an outdated app.
strays() {
    local dir app
    for dir in "$dest_dir" "$other_dir"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        for app in "$dir"/*.app; do
            [ -d "$app" ] || continue
            [ "$app" = "$dest" ] && continue
            case "$(plist_get "$app" CFBundleIdentifier)" in "$release_id"|"$debug_id") printf '%s\n' "$app" ;; esac
        done
    done
}

confirm() { # question → returns on yes; exits on no
    [ "$yes" = 1 ] && return 0
    [ -t 0 ] || die "not a terminal: re-run with --yes to agree up front, or --dry-run"
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) say "Nothing changed."; exit 0 ;; esac
}

ask() { # question [default-with-yes] → 0 yes / 1 no, never exits
    if [ "$yes" = 1 ]; then [ "${2:-0}" = 1 ]; return; fi
    [ -t 0 ] || return 1
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

quit_id() { # bundle id, name → asks every copy to quit normally; dies if one does not
    local id=$1 name=$2 pids
    pids=$(pids_of "$id" | tr '\n' ' ')
    [ -n "${pids// /}" ] || return 0
    say "== asking $name (PID ${pids% }) to quit normally"
    # A normal quit request (like Quit in its menu), never a kill.
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        [ -z "$(pids_of "$id")" ] && { say "   $name quit."; return 0; }
        sleep 0.5
    done
    die "$name is still running (PID $(pids_of "$id" | tr '\n' ' ')). Quit it yourself: its menu-bar icon → Quit BearlyCopy (or Settings → About), then run this again. If macOS asked whether Terminal may control BearlyCopy and you declined, that is why. Nothing was replaced."
}

verify_bundle() { # app [1: must match this checkout] → checks, dies on failure
    local app=$1 against=${2:-0} head version core_version digest_repo digest_app icon
    [ -d "$app/Contents" ] || die "not an app bundle: $app"
    [ "$(plist_get "$app" CFBundleIdentifier)" = "$release_id" ] \
        || die "$app has bundle id $(plist_get "$app" CFBundleIdentifier), not the Release id $release_id (a Debug build is never installed)"
    [ -x "$app/Contents/MacOS/$(plist_get "$app" CFBundleExecutable)" ] || die "no executable in $app"
    codesign --verify --strict "$app" 2>/dev/null || die "the code signature of $app does not verify (damaged or modified bundle)"
    version=$(plist_get "$app" CFBundleShortVersionString)
    core_version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$app/Contents/Resources/core/plugin/prompt_relay/__init__.py" 2>/dev/null || true)
    [ "$version" = "$core_version" ] || die "app version $version differs from its bundled Core ${core_version:-(missing)}"
    digest_app=$(scripts/core-digest.sh "$app/Contents/Resources/core" 2>/dev/null) || die "the bundled Core in $app is incomplete"
    [ "$digest_app" = "$(plist_get "$app" PRCoreDigest)" ] || die "the bundled Core does not match the digest recorded at build time"
    icon=$(plist_get "$app" CFBundleIconFile)
    [ "$icon" != "-" ] || die "$app names no application icon (CFBundleIconFile)"
    case "$icon" in *.icns) ;; *) icon="$icon.icns" ;; esac
    [ -s "$app/Contents/Resources/$icon" ] || die "$app names the icon $icon but does not contain it"
    if [ "$against" = 1 ]; then
        check_source "$app"
        digest_repo=$(scripts/core-digest.sh "$repo")
        [ "$digest_app" = "$digest_repo" ] || die "the bundled Core differs from this checkout's Core — rebuild"
    fi
    say "   verified: Release bundle id, signature ($(signing_of "$app")), version $version = Core $core_version, Core digest ${digest_app:0:12}…, icon $icon"
}

# Everything the app bundle is built from. A build from an earlier commit is
# still this checkout's app when none of these changed since (for example
# only docs/ did), the build was clean and the working tree is clean here.
build_inputs="macos/Sources macos/Resources macos/Package.swift bin plugin scripts/build-macos-app.sh scripts/core-digest.sh"

check_source() { # app → dies unless the bundle is built from this checkout's app sources
    local app=$1 built_commit head full
    built_commit=$(plist_get "$app" PRGitCommit)
    head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ "$built_commit" = "$head" ]; then
        say "   source: built from $head = this checkout"
        return 0
    fi
    full=$(git rev-parse --verify -q "${built_commit}^{commit}" 2>/dev/null || true)
    [ -n "$full" ] && git merge-base --is-ancestor "$full" HEAD 2>/dev/null \
        || die "the build is from $built_commit, which is not in this checkout's history (HEAD $head) — rebuild (drop --no-build)"
    [ "$(plist_get "$app" PRGitDirty)" != yes ] || die "the build is from $built_commit with uncommitted changes, the checkout is at $head — rebuild (drop --no-build)"
    # shellcheck disable=SC2086
    [ -z "$(git status --porcelain -- $build_inputs)" ] || die "this checkout has uncommitted changes in the app's sources — commit them and rebuild"
    # shellcheck disable=SC2086
    if ! git diff --quiet "$full" HEAD -- $build_inputs; then
        die "the build is from $built_commit; the app's sources changed since (HEAD $head) — rebuild (drop --no-build)"
    fi
    say "   source: built from $built_commit; HEAD $head differs only outside the app's sources ($(git diff --name-only "$full" HEAD | sed 's|/.*||' | sort -u | tr '\n' ' '))"
}

# The bundled Core, run from the bundle with an isolated, temporary data
# folder: a captured request and answer (Cyrillic, emoji, a code fence, 3000
# more characters) must come back byte for byte. Never reads or writes your
# real history.
smoke_core() { # app → dies on failure
    local app=$1 tmp cli python="" candidate
    cli="$app/Contents/Resources/core/bin/prompt-relay"
    for candidate in "$(head -1 "$data_dir/python-path" 2>/dev/null || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
                     /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/bin/python3; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        if "$candidate" -I -S -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            python=$candidate; break
        fi
    done
    [ -n "$python" ] || die "no Python 3.9+ found for the bundled Core (the app needs one too)"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/proj"
    if ! PROMPT_RELAY_HOME="$tmp/data" "$python" "$cli" enable "$tmp/proj" >/dev/null 2>&1; then
        rm -rf "$tmp"; die "bundled Core smoke test: enable failed"
    fi
    if ! "$python" -I - "$python" "$cli" "$tmp" <<'EOF'
import json, os, subprocess, sys
python, cli, tmp = sys.argv[1:4]
env = dict(os.environ, PROMPT_RELAY_HOME=tmp + "/data")
answer = "Готово ✅\n\n```swift\nlet x = 1\n```\n" + "x" * 3000
def hook(event):
    p = subprocess.run([python, cli, "hook"], input=json.dumps(event).encode(), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0 or p.stdout:
        sys.exit("hook exited %d or wrote to stdout" % p.returncode)
base = {"session_id": "smoke", "cwd": tmp + "/proj"}
hook(dict(base, hook_event_name="UserPromptSubmit", prompt="Проверка 🐻", prompt_id="1"))
hook(dict(base, hook_event_name="Stop", prompt_id="1", last_assistant_message=answer))
out = subprocess.run([python, cli, "show", "--session", "smoke", "--json"], env=env,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if out.returncode != 0:
    sys.exit("show failed: " + out.stderr.decode("utf-8", "replace")[:300])
text = json.dumps(json.loads(out.stdout.decode("utf-8")), ensure_ascii=False)
if json.dumps(answer, ensure_ascii=False) not in text or json.dumps("Проверка 🐻", ensure_ascii=False) not in text:
    sys.exit("the request or answer did not come back verbatim")
print("   smoke test: the bundled Core captured a request and a %d-character answer and returned both verbatim (isolated data folder)" % len(answer))
EOF
    then rm -rf "$tmp"; die "bundled Core smoke test failed (see above)"; fi
    rm -rf "$tmp"
}

show_running() {
    local r d
    r=$(all_release_pids | tr '\n' ' ')
    d=$(debug_pids | tr '\n' ' ')
    say "Running:    Release ${r:-none}   Debug (\"BearlyCopy Dev\") ${d:-none}"
}

# Launch Services: Finder, Spotlight and Launchpad find the app and its icon.
register() { if [ "${PROMPT_RELAY_TEST_NO_LSREGISTER:-0}" != 1 ] && [ -x "$lsregister" ]; then "$lsregister" -f "$1" >/dev/null 2>&1 || true; fi; }
unregister() { if [ "${PROMPT_RELAY_TEST_NO_LSREGISTER:-0}" != 1 ] && [ -x "$lsregister" ]; then "$lsregister" -u "$1" >/dev/null 2>&1 || true; fi; }

backup_name() { # app, stamp → path in $backups
    printf '%s/BearlyCopy %s-%s-%s.app' "$backups" "$(safe "$(plist_get "$1" CFBundleShortVersionString)")" \
        "$(safe "$(plist_get "$1" PRGitCommit)")" "$2"
}

# Install in three steps, so the installed app is untouched (and still
# running) until a verified copy is ready next to it:
#   stage_copy     copy the new app beside the destination and verify the copy
#   replace_staged move the old app to the backups, the copy in; put back on failure
#   launch_and_check / recover_after_launch_failure
staged=""
backup=""
previous_was_running=0

stage_copy() { # source app → $staged
    local src=$1
    mkdir -p "$dest_dir" "$backups" || die "cannot create $dest_dir or $backups"
    chmod 700 "$backups"
    [ -w "$dest_dir" ] || die "$dest_dir is not writable by you$([ "$dest_dir" = "$system_apps" ] && echo ' (an administrator account is needed for /Applications; or install in ~/Applications without --system)')"
    staged="$dest_dir/.BearlyCopy.app.installing-$(date +%Y%m%d-%H%M%S)"
    if [ "${PROMPT_RELAY_TEST_FAIL_COPY:-0}" = 1 ] || ! ditto "$src" "$staged"; then
        rm -rf "$staged"; staged=""; die "copying the new app failed (disk full?); nothing was quit or replaced"
    fi
    if ! codesign --verify --strict "$staged" 2>/dev/null \
       || [ "$(scripts/core-digest.sh "$staged/Contents/Resources/core" 2>/dev/null || true)" != "$(plist_get "$src" PRCoreDigest)" ]; then
        rm -rf "$staged"; staged=""; die "the copied app does not verify; nothing was quit or replaced"
    fi
    say "== new app copied next to the installed one and verified"
}

reopen_previous() { # after a failure: start the old app again if it was running
    if [ "$previous_was_running" = 1 ] && [ "$launch" = 1 ] && [ -d "$dest" ]; then
        if [ "${PROMPT_RELAY_TEST_SIMULATE_LAUNCH:-}" = "" ]; then open "$dest" >/dev/null 2>&1 || true; fi
        say "   the previous app was opened again"
    fi
}

replace_staged() { # moves the old app to the backups and $staged into place
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    backup=""
    if [ -d "$dest" ]; then
        backup=$(backup_name "$dest" "$stamp")
        if ! mv "$dest" "$backup"; then
            rm -rf "$staged"; staged=""; reopen_previous
            die "could not move the installed app aside; nothing replaced"
        fi
        unregister "$backup"
    fi
    if [ "${PROMPT_RELAY_TEST_FAIL_SWAP:-0}" = 1 ] || ! mv "$staged" "$dest"; then
        # Put the old app back exactly where it was.
        if [ -n "$backup" ] && [ ! -e "$dest" ]; then mv "$backup" "$dest"; backup=""; fi
        rm -rf "$staged"; staged=""
        reopen_previous
        die "installing failed; the previous app was put back at $dest"
    fi
    staged=""
    [ -z "$backup" ] || say "== previous app kept: $(tilde "$backup")"
    register "$dest"
    say "== installed $(tilde "$dest")"
}

# Did the installed app start and keep running? Returns 1 (does not exit) on failure.
launch_problem=""
launched_ok() { # expected commit
    local expected=$1 pids="" commit
    launch_problem=""
    case "${PROMPT_RELAY_TEST_SIMULATE_LAUNCH:-}" in
        ok) return 0 ;;
        fail) launch_problem="the app did not start within 15 s (simulated)"; return 1 ;;
    esac
    open "$dest" || { launch_problem="macOS could not open it"; return 1; }
    for _ in $(seq 1 30); do
        pids=$(installed_release_pids | tr '\n' ' ')
        [ -n "${pids// /}" ] && break
        sleep 0.5
    done
    [ -n "${pids// /}" ] || { launch_problem="the app did not start within 15 s"; return 1; }
    sleep 3   # still running a few seconds later (did not crash at start)
    pids=$(installed_release_pids | tr '\n' ' ')
    [ -n "${pids// /}" ] || { launch_problem="the app started but quit within 3 s"; return 1; }
    commit=$(plist_get "$dest" PRGitCommit)
    [ "$commit" = "$expected" ] || { launch_problem="the app at $dest reports commit $commit, expected $expected"; return 1; }
    return 0
}

report_running() {
    local pids count others dbg commit
    commit=$(plist_get "$dest" PRGitCommit)
    if [ -n "${PROMPT_RELAY_TEST_SIMULATE_LAUNCH:-}" ]; then
        say "== running (simulated): $(tilde "$dest"), commit $commit"; return 0
    fi
    pids=$(installed_release_pids | tr '\n' ' ')
    count=$(printf '%s\n' $pids | grep -c . || true)
    others=$(all_release_pids | tr '\n' ' ')
    if [ "$count" = 1 ] && [ "$(printf '%s' "$others" | tr -d ' ')" = "$(printf '%s' "$pids" | tr -d ' ')" ]; then
        say "== running: one Release copy, PID ${pids// /}, from $(tilde "$dest"), version $(plist_get "$dest" CFBundleShortVersionString), commit $commit"
    else
        say "!! more than one Release copy runs (PIDs $others) — quit the extra ones from their menu-bar icon"
    fi
    dbg=$(debug_pids | tr '\n' ' ')
    [ -z "${dbg// /}" ] || say "note: the Debug build (\"BearlyCopy Dev\", PID ${dbg// /}) is running too; the installed app steps aside at the notch while it runs. Quit the Debug copy from its hammer menu-bar icon to use the installed app."
    say "Check: BearlyCopy's menu-bar icon → Settings → About: Release, version $(plist_get "$dest" CFBundleShortVersionString), commit $commit."
}

launch_and_check() { # expected commit → verified launch, or automatic recovery
    local expected=$1 failed stamp
    [ "$launch" = 1 ] || { say "== not launched (--no-launch). Open it from $(tilde "$dest_dir")."; return 0; }
    if launched_ok "$expected"; then report_running; return 0; fi
    say "!! the new app failed: $launch_problem"
    if [ -z "$backup" ] || [ ! -d "$backup" ]; then
        die "$launch_problem. There was no previous app to restore. Open $(tilde "$dest") yourself to see the problem; nothing else was changed."
    fi
    # Automatic recovery: quit the new copy if it runs, keep it as a backup
    # marked "(failed launch)", put the previous app back and open it.
    quit_id "$release_id" "the new BearlyCopy"
    stamp=$(date +%Y%m%d-%H%M%S)
    failed="$backups/BearlyCopy $(safe "$(plist_get "$dest" CFBundleShortVersionString)")-$(safe "$(plist_get "$dest" PRGitCommit)")-$stamp (failed launch).app"
    mv "$dest" "$failed" || die "$launch_problem; could not move it aside. Restore by hand: scripts/install-local.sh --rollback"
    unregister "$failed"
    mv "$backup" "$dest" || die "$launch_problem; the previous app is still at $(tilde "$backup") — move it back to $(tilde "$dest_dir")"
    register "$dest"
    say "== the previous app ($(plist_get "$dest" CFBundleShortVersionString), commit $(plist_get "$dest" PRGitCommit)) is installed again; the failed one is kept at $(tilde "$failed")"
    if launched_ok "$(plist_get "$dest" PRGitCommit)"; then report_running
    else say "!! the previous app did not start either: $launch_problem"; fi
    die "the new version did not start ($launch_problem); the previous version was restored"
}

# One installer at a time (not for read-only modes).
lock="${TMPDIR:-/tmp}/prompt-relay-install.lock"
if [ "$mode" != status ] && [ "$mode" != list ] && [ "$dry" = 0 ]; then
    mkdir "$lock" 2>/dev/null || die "another install-local.sh is running (if not, remove $lock)"
    trap '[ -z "$staged" ] || rm -rf "$staged"; rmdir "$lock" 2>/dev/null || true' EXIT
fi

case "$mode" in
status)
    say "Checkout:   $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)$([ -n "$(git status --porcelain --untracked-files=no -- macos/Sources macos/Resources bin plugin)" ] && echo ' + uncommitted changes') · version $(sed -n 's/^__version__ = "\(.*\)"/\1/p' plugin/prompt_relay/__init__.py)"
    say "Installed:  $(describe "$dest")"
    say "            $(tilde "$dest")"
    if [ -n "$other_dir" ] && [ -d "$other_dir/BearlyCopy.app" ]; then
        say "Also:       $(describe "$other_dir/BearlyCopy.app") — $(tilde "$other_dir/BearlyCopy.app")"
    fi
    show_running
    s=$(strays)
    if [ -n "$s" ]; then
        say "Old copies in Applications (Spotlight and Launchpad list them; opening one starts an old version):"
        printf '%s\n' "$s" | while IFS= read -r app; do say "            $(plist_get "$app" CFBundleShortVersionString) — $(tilde "$app")"; done
        say "            Move them to the backups with: scripts/install-local.sh --tidy"
    fi
    if [ -d "$dest" ] && [ "$(plist_get "$dest" PRGitCommit)" != "$(git rev-parse --short HEAD)" ]; then
        say "The installed app is not built from this checkout. Update: scripts/install-local.sh --dry-run, then without --dry-run."
    fi
    exit 0 ;;
list)
    ls -1d "$backups"/*.app 2>/dev/null || say "no backups in $backups"
    exit 0 ;;
tidy)
    s=$(strays)
    [ -n "$s" ] || { say "No stray BearlyCopy copies in the Applications folders."; exit 0; }
    say "These copies would be moved (not deleted) to $(tilde "$backups")/:"
    printf '%s\n' "$s" | while IFS= read -r app; do say "   $(plist_get "$app" CFBundleShortVersionString) — $(tilde "$app")"; done
    [ "$dry" = 0 ] || { say "Dry run: nothing changed."; exit 0; }
    confirm "Move them?"
    mkdir -p "$backups"; chmod 700 "$backups"
    printf '%s\n' "$s" | while IFS= read -r app; do
        if [ "${PROMPT_RELAY_TEST_NO_PROCESSES:-0}" != 1 ] && /bin/ps -axo comm= | grep -qF "$app/Contents/MacOS/"; then
            say "   skipped (running — quit it first): $(tilde "$app")"; continue
        fi
        target="$backups/$(basename "${app%.app}") (moved $(date +%Y%m%d-%H%M%S)).app"
        mv "$app" "$target" && unregister "$target" && say "   moved: $(tilde "$target")"
    done
    exit 0 ;;
rollback)
    # The most recently replaced app: backups are named "… <version>-<commit>-
    # <YYYYmmdd-HHMMSS>.app" with the time they were replaced, so the newest
    # stamp is the version installed just before the current one. Folder
    # times are not used (a moved bundle keeps its old time). Copies marked
    # "(moved …)" or "(failed launch)" are never chosen automatically.
    latest=$(find "$backups" -maxdepth 1 -type d -name 'BearlyCopy *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].app' 2>/dev/null \
        | sed -E 's/^(.*-([0-9]{8}-[0-9]{6})\.app)$/\2	\1/' | sort -r | head -1 | cut -f2- || true)
    [ -n "$latest" ] || die "no backup to roll back to in $backups"
    say "Installed now: $(describe "$dest")"
    say "Roll back to:  $(describe "$latest")"
    say "               $(tilde "$latest")"
    show_running
    verify_bundle "$latest" 0
    if [ "$dry" = 1 ]; then say "Dry run: nothing changed."; exit 0; fi
    confirm "Quit the running Release app (if any), keep the current app as a backup and restore this one?"
    stage_copy "$latest"     # a verified copy; the backup itself is kept
    [ -z "$(all_release_pids)" ] || previous_was_running=1
    quit_id "$release_id" "BearlyCopy"
    replace_staged
    launch_and_check "$(plist_get "$dest" PRGitCommit)"
    say "Backups are all kept. Running --rollback again swaps back to the version you just replaced."
    exit 0 ;;
esac

# install
for tool in git swift codesign ditto shasum /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool (install Xcode or the Command Line Tools)"
done
say "== source: branch $(git rev-parse --abbrev-ref HEAD), commit $(git rev-parse --short HEAD) — $(git log -1 --format=%s | cut -c1-70)"
if [ -n "$(git status --porcelain --untracked-files=no -- macos/Sources macos/Resources bin plugin)" ]; then
    say "note: the checkout has uncommitted changes in macos/Sources, macos/Resources, bin or plugin; About will say so."
fi

if [ "$build" = 1 ]; then
    if [ "${PROMPT_RELAY_TEST_FAIL_BUILD:-0}" = 1 ] || ! PROMPT_RELAY_SIGN_IDENTITY="$sign_identity" scripts/build-macos-app.sh; then
        die "the build failed; nothing was installed or quit"
    fi
else
    [ -d "$built" ] || die "no build at $built (drop --no-build)"
fi

say ""
say "== pre-install checks"
verify_bundle "$built" 1
if [ "$checks" = 1 ]; then smoke_core "$built"; else say "   smoke test skipped (--skip-checks)"; fi

say ""
say "== plan"
say "New build:  $(describe "$built")"
say "Installed:  $(describe "$dest")"
say "            $(tilde "$dest")"
show_running
s=$(strays)
[ -z "$s" ] || say "Note:       $(printf '%s\n' "$s" | wc -l | tr -d ' ') old BearlyCopy copies are in Applications; see --status and --tidy"
if [ -n "$other_dir" ] && [ -d "$other_dir/BearlyCopy.app" ]; then
    say "Note:       another installed copy is in $(tilde "$other_dir") — open only one; --tidy moves it to the backups"
fi
say "Keeps:      history, settings and integrations ($(tilde "$data_dir"), app preferences, Claude/Codex config, plugin) — untouched"
[ ! -d "$dest" ] || say "Backup to:  $(tilde "$backups")/"
say "Then:       quit the running Release app normally, install to $(tilde "$dest")$([ "$launch" = 1 ] && echo ', open it, verify the running copy')"
say "Undo:       scripts/install-local.sh --rollback"
if [ "$(signing_of "$built")" = "ad-hoc signed" ]; then
    say "Signing:    ad-hoc — macOS may ask for Screen Recording again after this update. --sign \"Apple Development\" keeps it."
fi

if [ "$dry" = 1 ]; then say ""; say "Dry run: nothing changed."; exit 0; fi
confirm "Quit the running Release app (if any) and install this build?"
if [ -n "$(debug_pids)" ]; then
    if [ "$quit_debug" = 1 ] || ask "A Debug build (\"BearlyCopy Dev\") is running and would keep the notch. Ask it to quit normally too?"; then
        quit_id "$debug_id" "BearlyCopy Dev (Debug)"
    fi
fi
stage_copy "$built"
[ -z "$(all_release_pids)" ] || previous_was_running=1
quit_id "$release_id" "BearlyCopy"
replace_staged
launch_and_check "$(plist_get "$built" PRGitCommit)"
