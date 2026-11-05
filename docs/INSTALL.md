# Installing Prompt Relay

Two audiences, two workflows. Users never need Xcode.

## Requirements

- macOS 14 Sonoma or newer (the app uses ScreenCaptureKit's window picker
  from macOS 14). Developed and tested on macOS 27 / Apple Silicon.
- Python 3.9 or newer, from any of: Xcode Command Line Tools
  (`xcode-select --install`), Homebrew (`brew install python`), or
  python.org. Prompt Relay never triggers the Command Line Tools installer by
  itself; if no Python is found, Setup and Settings → Diagnostics say so
  (ADR-019).
- Claude Code and/or Codex, if you want answers captured automatically.

## For users (GitHub Release) — not published yet

When a signed and notarized release exists:

1. Download `Prompt-Relay-<version>.dmg` from the GitHub Releases page and
   check its SHA-256 against the `.sha256` file next to it.
2. Open the DMG and drag **Prompt Relay** to **Applications**.
3. Open it. It lives in the menu bar and at the notch.
4. Follow **Set Up** (opens from the empty island, or Settings → Agents &
   Projects → Set Up Agents): connect an agent, enable a project, send any
   prompt, and wait for "Connected — events observed".

Updating: quit Prompt Relay, replace the app, open it again. History and
settings are kept (they live outside the app). There is no automatic
updater.

Uninstalling: quit, delete the app. Your history stays in
`~/Library/Application Support/PromptRelay` until you delete it. Remove the
Claude Code plugin with `claude plugin uninstall prompt-relay@prompt-relay`
and the Codex hooks with `configure-codex.py … --disable --apply`.

## For developers (from a checkout)

```bash
git clone https://github.com/Banderos14/prompt-relay && cd prompt-relay
scripts/check.sh                       # Python Core tests
(cd macos && swift test)               # Swift tests
scripts/install-local.sh --dry-run     # build + verify + show the plan; changes nothing
scripts/install-local.sh               # same, then asks, installs to ~/Applications and opens it
```

`install-local.sh` in detail:

| Step | What happens |
|---|---|
| Check tools | git, swift, codesign, ditto, shasum, PlistBuddy |
| Build | `scripts/build-macos-app.sh` → `macos/build/Prompt Relay.app` (Release, ad-hoc signed) |
| Verify | signature; app version = bundled Core version; Core digest = recorded digest = this checkout; recorded commit = `HEAD` |
| Plan | new build, installed build, running copies, backup location, undo command |
| Ask | `[y/N]` (or `--yes`) |
| Quit | asks the running Release app to quit normally; if macOS refuses the request, asks before sending TERM; never touches the Debug (Xcode) build |
| Install | copies to a temporary name, verifies, moves the old app to `~/Library/Application Support/PromptRelay-AppBackups/`, moves the new one in place |
| Launch | opens it and checks exactly one Release copy runs from `~/Applications` |

Other commands:

```bash
scripts/install-local.sh --status         # installed build vs checkout, running copies
scripts/install-local.sh --rollback       # restore the newest backup (asks; current app is backed up first)
scripts/install-local.sh --list-backups
```

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
| Codex shows **Trust required** | Hooks defined, never run | Open Codex, review Prompt Relay's hooks in `/hooks` (or accept on next start) |
| **Capture disabled** | No project enabled, or the event came from a folder that is off | Setup → Choose Project… |
| **Waiting for first event** forever | Agent session started before setup | Start a new session in an enabled project |
| About: "the app in ~/Applications is …" | You are running the Xcode build; the installed app is older | `scripts/install-local.sh` |
| About: "A different build was installed here after this one started" | Replaced while running | Quit and reopen |
| Two bears / two islands | Debug and Release both running | Settings → About → Quit the other one |
| `install-local.sh`: "build is from …, checkout is at …" | `--no-build` with an old build | Drop `--no-build` |
| Gatekeeper: "cannot be opened" | Unsigned/ad-hoc build from someone else | Only signed, notarized releases are meant for other Macs |
