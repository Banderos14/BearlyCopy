# Next-chat prompts (after Phase 15)

## 1. For a new Claude Code session (paste as the first message)

```
You are continuing Prompt Relay, a local-first macOS bridge between Claude
Code and ChatGPT (Python Core + Claude Code plugin + native Swift notch app).

1. Repository: ~/Projects/prompt-relay (main checkout, branch
   claude/loving-mccarthy-ossw3q, holds the owner's staged
   macos/acceptance/phase9.1/xcode-smoke/REPORT.md and ~344 untracked
   acceptance files — never add, reset, clean or commit them) and the
   Phase 15 worktree ~/Projects/prompt-relay-phase15
   (branch phase/15-mvp-readiness). Work in a worktree or on a branch from
   develop; never commit to main; never force-push.
2. Read, in order: CLAUDE.md, docs/PHASE15_HANDOFF.md, docs/STATUS.md (top
   entry), docs/PHASE15_AUDIT.md, docs/PHASE15_GIT_RECOVERY.md,
   docs/PHASE15_MVP_ACCEPTANCE.md.
3. Verify: `git -C ~/Projects/prompt-relay-phase15 log --oneline -5`,
   `git branch -a -vv`, `git ls-remote origin`; confirm develop and whether
   phase/15-mvp-readiness was merged into develop. Do not trust SHAs in docs
   without checking.
4. Tests: `PYTHONS="/usr/local/bin/python3 /usr/bin/python3" scripts/check.sh`,
   `(cd macos && swift test)`, xcodebuild -workspace
   macos/PromptRelay.xcworkspace -scheme "Prompt Relay" -configuration
   Debug|Release -derivedDataPath <scratch> build.
5. Next task: whatever docs/STATUS.md "Next agreed stage" says. As of
   2026-11-07 that is the owner's acceptance of 0.6.0 + Phase 15
   (installing the app or plugin needs the owner's explicit consent), then a
   Phase 16 chosen by the owner from PHASE15_HANDOFF.md §H.
6. Never install, release, tag, merge into main, delete branches, change
   macOS permissions or touch ~/.claude settings without explicit approval.
   Report Auto / Mac / Mock / Owner / Not verified separately.
```

## 2. For a new ChatGPT conversation (paste as context)

**Prompt Relay** is the owner's own macOS utility. Claude Code does
development work; official Claude Code hooks call a small Python Core that
stores Claude's final answer **verbatim** (only in projects the owner
enabled) in local JSONL files. A native Swift app shows it in a notch
"island" and offers **Copy Response** and **Copy with Context** (request,
full answer, commands Claude ran with exit codes, files changed, git state,
chosen attachments). The owner pastes that **manually** into ChatGPT for an
independent review. There is no AI API, no ChatGPT/browser automation, no
backend, no telemetry; everything is local and user-initiated.

Boundaries you must not assume away: Stop means "Claude stopped", not
"task succeeded"; StopFailure is an API error, not an answer; what Claude
says is *Reported by Claude*, only locally observed facts are *Confirmed
locally*; a later passing run never proves an earlier failure was fixed;
sessions and projects are never mixed; Screen Recording is used only for
window snapshots the user links, kept in memory.

History: Phases 0–4 built the Core, plugin, JSON API, app and island;
5–8 added observed commands, Evidence Check, Review Checklist, Failure
Inspector, themes; 9–11 multi-agent, final-only answers, in-memory window
snapshots, install script; 12–13 agent profiles, Results Inbox, Needs Input,
Context Packs (0.4.1 installed, 0.5.0); 14–14.2 layout fixes, automatic
final screenshots, permission recovery, review progress vs evidence,
command/test/build failure breakdown (0.6.0, not installed). **Phase 15**
(2026-11-07): Git recovery (private bundle backup, new `develop` =
`17844fe` pushed), independent audit; fixed review marks vanishing past 200
answers, `swift build | grep` shown as "build failed" (now "build unclear";
grep no-match now "likely not an error"), a wrong security doc, two
warnings; strengthened four weak tests. Branch `phase/15-mvp-readiness`.

Testing: Python 249+15 on 3.9 and 3.14, XCTest and Swift Testing suites,
Xcode Debug/Release builds — all automated on the owner's Mac (exact counts
in docs/PHASE15_TEST_RESULTS.md). **Not verified:** anything needing a real
mouse, System Settings toggles, real Claude Desktop timing, or a real paste
into ChatGPT. Installed app and plugin are still 0.4.1.

Next: the owner runs docs/PHASE15_MVP_ACCEPTANCE.md (33 checks) after
installing 0.6.0 + Phase 15 with consent; then picks Phase 16 (candidates:
fix any acceptance failures, minimized-window screenshot risk, version bump,
picker polish, signing/notarization, MCP read-only). Do not assume any of
these is done, approved, or that GitHub `main` contains current code (it
holds only the initial commit).
