# Installing BearlyCopy

Two audiences, two workflows. Users never need Xcode.

## Requirements

- macOS 14 Sonoma or newer (the app uses ScreenCaptureKit's window picker
  from macOS 14). Developed and tested on macOS 27 / Apple Silicon.
- Python 3.9 or newer, from any of: Xcode Command Line Tools
  (`xcode-select --install`), Homebrew (`brew install python`), or
  python.org. BearlyCopy never triggers the Command Line Tools installer by
  itself; if no Python is found, Setup and Settings → Diagnostics say so
  (ADR-019).
- Claude Code and/or Codex, if you want answers captured automatically.

## For users (GitHub Release) — not published yet

When a signed and notarized release exists:

1. Download `BearlyCopy-<version>.dmg` from the GitHub Releases page and
   check its SHA-256 against the `.sha256` file next to it.
2. Open the DMG and drag **BearlyCopy** to **Applications**.
3. Open it. It lives in the menu bar and at the notch.
4. Follow **Set Up** (opens from the empty island, or Settings → Agents &
   Projects → Set Up Agents): connect an agent, enable a project, send any
   prompt, and wait for "Connected — events observed".

Updating: quit BearlyCopy, replace the app, open it again. History and
settings are kept (they live outside the app). There is no automatic
updater.

Uninstalling: quit, delete the app. Your history stays in
`~/Library/Application Support/PromptRelay` until you delete it. Remove the
Claude Code plugin with `claude plugin uninstall prompt-relay@prompt-relay`
and the Codex hooks with `configure-codex.py … --disable --apply`.

## For developers (from a checkout)

```bash
git clone https://github.com/Banderos14/BearlyCopy && cd prompt-relay
scripts/check.sh                       # Python Core tests
(cd macos && swift test)               # Swift tests
scripts/install-local.sh --dry-run     # build + verify + show the plan; changes nothing
scripts/install-local.sh               # same, then asks, installs to ~/Applications and opens it
```

`install-local.sh` in detail (Phase 16):

| Step | What happens |
|---|---|
| Source | prints the branch, commit and subject it builds from; never pulls or downloads |
| Build | `scripts/build-macos-app.sh` → `macos/build/BearlyCopy.app` (Release, ad-hoc signed, or `--sign "Apple Development"`). A failed build changes nothing |
| Source | `--no-build`: the build must be from `HEAD`, or from an earlier commit when nothing the app is built from (`macos/Sources`, `macos/Resources`, `macos/Package.swift`, `bin`, `plugin`, the build scripts) changed since and the checkout is clean there |
| Verify | Release bundle id (a Debug build is refused); signature; app version = bundled Core version; Core digest = recorded digest = this checkout; recorded commit = `HEAD`; the bear icon is bundled and named in Info.plist |
| Smoke test | runs the **bundled** Core with a temporary data folder: a request and an answer (Cyrillic, emoji, a code fence, 3000 characters) must come back verbatim; your history is not touched |
| Plan | new build, installed build (version, commit, signing), running copies, stray old copies in Applications, backup location, undo command |
| Ask | `[y/N]` (or `--yes`). A running Debug build ("BearlyCopy Dev") would keep the notch: asked separately whether to quit it (`--quit-debug`) |
| Quit | asks running copies to quit normally (like Quit in the menu) and waits 15 s; if one does not quit, stops and says how to quit it — never kills |
| Stage | copies the new app next to the installed one and verifies the copy — **before** anything is quit. A failed copy changes nothing |
| Install | moves the old app to `~/Library/Application Support/PromptRelay-AppBackups/` (named with version, commit and the time it was replaced) and the copy in place. If that move fails, the old app is put back (and reopened if it had been running). Registers the app with Launch Services (Finder, Spotlight, Launchpad, icon) |
| Launch | opens it; succeeds only when one Release copy runs **from the installed path**, is still running 3 s later, and reports the expected commit. If it does not, the previous app is **put back and opened automatically**; the failed one is kept as "… (failed launch).app" |

Other commands:

```bash
scripts/install-local.sh --status         # installed build vs checkout, running copies, stray old copies
scripts/install-local.sh --rollback       # restore the most recently replaced version (asks; current app becomes a backup; no backup is deleted)
scripts/install-local.sh --list-backups
scripts/install-local.sh --tidy           # move old copies (e.g. "BearlyCopy.before-….app") out of Applications into the backups (asks)
scripts/install-local.sh --system         # install into /Applications instead of ~/Applications (admin account)
```

Or double-click **`scripts/Update BearlyCopy.command`** in Finder: it shows
`--status`, asks, then runs the same installer (which asks again before
replacing anything).

**Where it installs.** `~/Applications/BearlyCopy.app` — your own
Applications folder: no administrator password, found by Spotlight and
Launchpad, shown in Finder under your home folder → Applications (add it to
the Finder sidebar if you like). `--system` installs in `/Applications`
instead; keep only one of the two (`--status` warns, `--tidy` moves the other).

**Signing.** The default is an ad-hoc signature, which changes with every
build: macOS then treats each update as a new app for Screen Recording, so the
permission has to be switched off and on again after an update.
`--sign "Apple Development"` uses your own development certificate (if you
have one: `security find-identity -v -p codesigning`); its signature
requirement stays the same across builds, so the permission is kept. Neither
is notarized; both are for this Mac only.

Never touched: `~/Library/Application Support/PromptRelay` (history),
the app's preferences, Claude Code or Codex configuration, hooks, trust.

### Xcode

`macos/PromptRelay.xcworkspace` builds the **Debug** app
(`io.github.banderos14.PromptRelay.debug`), which has its own preferences and
runs side by side with the installed Release app. While it runs, the Release
app steps aside at the notch. Settings → About shows which build you are
looking at, its commit, and whether the installed app is older.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Python 3.9 or newer: Not found" | No Python, or only the CLT stub | Install one (see Requirements), then Check Again |
| Agent shows **Configuration required** | Plugin or hooks not installed | Setup → Copy Commands, run them, Check Again |
| Codex shows **Trust required** | Hooks defined, never run | Open Codex, review BearlyCopy's hooks in `/hooks` (or accept on next start) |
| **Capture disabled** | No project enabled, or the event came from a folder that is off | Setup → Choose Project… |
| **Waiting for first event** forever | Agent session started before setup | Start a new session in an enabled project |
| About: "the app in ~/Applications is …" | You are running the Xcode build; the installed app is older | `scripts/install-local.sh` |
| About: "A different build was installed here after this one started" | Replaced while running | Quit and reopen |
| Two bears / two islands | Debug and Release both running | Settings → About → Quit the other one |
| `install-local.sh`: "build is from …, checkout is at …" | `--no-build` with an old build | Drop `--no-build` |
| Gatekeeper: "cannot be opened" | Unsigned/ad-hoc build from someone else | Only signed, notarized releases are meant for other Macs |
