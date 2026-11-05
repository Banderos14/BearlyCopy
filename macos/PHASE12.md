# Phase 12 — Multi-Agent Workspace, Results Inbox, daily workflow

2026-11-05. Start: HEAD `3287bc3` on `claude/loving-mccarthy-ossw3q` (as
expected). Running at the start and left untouched: the installed Release
`~/Applications/Prompt Relay.app` (0.3.0, PID 9710) and an Xcode Debug build
(PID 54554). No new build was installed, nothing was quit or launched, no
hook, plugin, trust record, login item, Claude Code or Codex setting was
changed. The staged `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and
every untracked `macos/acceptance/` item were left as found (start snapshot:
`macos/acceptance/phase12/start-status.txt`, `start-staged.patch`). No push,
merge or release.

Legend: **Verified with tests** (automated, on this Mac) · **Verified
offscreen** (real SwiftUI views rendered into an offscreen window, no live
GUI) · **Measured** · **Requires owner** (live GUI, real agents, consent) ·
**Not implemented**.

Open acceptance items carried over from Phase 11, **still open** (not
claimed here): the real ScreenCaptureKit picker and in-memory snapshot
hand-off; Set Up with real agents reaching Connected; Xcode Debug and the
installed Release running at the same time; the external security review that
returned HTTP 429; Codex setup without a source checkout for a public release.

---

## 1. Core architecture changes

| Piece | Change |
|---|---|
| `plugin/prompt_relay/profiles.py` (new) | Local agent profile from the hook's own environment: `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, else the provider's default folder. Id `cc-default` / `cx-default`, otherwise prefix + 16 hex of SHA-256 over the folder's real path; display hint `~/<folder>` (never a user name). Allowlist validator for the read side. |
| `hook.py` | Writes `agent_profile` into the **record envelope**; the agent's payload stays byte-for-byte as received (invariant 2 — the first attempt put it in the payload, `SchemaConformanceTests` caught it, it was moved). A non-default Claude Code folder scopes the stored key: `session_id` → `<id>.<12 hex>`, `native_session_id` keeps the agent's id. |
| `events.py` | Reads `profile`, `native_session_id`; a scoped record is read under its envelope key. |
| `api.py` | `session_summary` gains `profile`, `native_session_id`. New `results_data`: final results of every session, newest `answered_at` first, stable ties, `total` + `limit`, filters project / provider / profile (`unassigned` included). One result per user task: intermediate Stops never; a background follow-up is named by the request that started the work chain (`request.own = false`). |
| `cli.py` | New read-only command `results [--project] [--provider] [--profile] [--limit 1..10000] [--json]`. |
| Schema, golden files | `profile`, `result_summary`, `results_data`; 12 golden files gained only the `profile` block (additive, reviewed). |

No change to capture rules, the hook contract (stdout empty, exit 0, no
network, no git, no transcripts), correlation, export or Copy with Context.

## 2. How profiles are identified — and the limits

- **Source:** only the agent's documented config-folder variable in the hook
  environment. No credentials, tokens, `auth.json`, keychain, cookies or
  e-mail addresses are read; subscription plans are not detected.
- **A profile is a folder, not an account.** If someone signs in to another
  account inside the same folder, hooks cannot tell, and Prompt Relay shows
  one profile. The UI says so (Settings → Agents & Projects → Agent
  profiles, and the tooltip of each By Agent row).
- **Names** ("Work", "Personal") are local labels in the app's preferences,
  never sent anywhere, never treated as verified identity. Removing a name
  keeps every conversation (tested).
- **Equal native session ids** from two folders never share a history: the
  non-default Claude Code folder's key is scoped; Codex keys already include
  `CODEX_HOME`. Session ids are never used alone as a global identity.
- **Defaults:** a relative or empty variable is not evidence of a folder →
  default profile. Naming the default folder explicitly is still the
  default profile.
- **Not observed live:** a real hook run with a non-default
  `CLAUDE_CONFIG_DIR` (expected from Claude Code's environment inheritance;
  recorded as such in `docs/HOOKS_RESEARCH.md`). Whether Claude Desktop sets
  its own `CLAUDE_CONFIG_DIR` is unknown — if it does, Desktop sessions form
  their own profile, which is correct, not a mix-up. **Requires owner.**

## 3. Compatibility with existing history

- **No migration rewrites a file.** Old records are read as they are.
- Claude Code records without a profile → **Unassigned** (their own group in
  By Agent; never guessed into Default).
- Codex records from before Phase 12 map through their stored
  `installation_id` to exactly the profile id a new record gets (tested), so
  old and new Codex · Xcode conversations land in one profile.
- Default Claude Code keys are unchanged, so all existing conversations,
  pins, read states and hand-offs keep their keys.
- Known edge: a Claude Code session already running with a non-default
  `CLAUDE_CONFIG_DIR` while the plugin updates continues under a new
  (scoped) key; its earlier turns stay in the old conversation (ADR-023).
- Re-running is idempotent: reading twice gives the same result; hook
  redelivery is still dropped by the store.

## 4. By Project and By Agent

Project and Session has a small **By Project ⌄ / By Agent** menu (kept
across launches; By Project stays the default) next to the existing agent
filter.

- **By Project** (unchanged): logical project → conversations from every
  provider, profile and host. Once more than one profile of a provider
  exists, each row's line names its profile ("claude-work · Claude Desktop ·
  9 hr ago · 1 answer").
- **By Agent**: left column = one row per provider · profile ("Default /
  Claude Code", "claude-work / Claude Code", "Unassigned", "Xcode / Codex")
  with new-answer and conversation counts; right column = that profile's
  conversations under small project headers, with the same expandable
  conversation rows (final answers only). Provider → Profile → Project →
  Conversation in two columns instead of a four-level tree in a narrow
  island.
- Both group the same `allSessions`; By Project's ordering logic was moved
  into a shared helper so both sort alike (newest final answer first).

## 5. Results Inbox

Inbox icon (tray, green dot when something is unread) in the Details footer,
⌘I inside the island, the menu-bar item, and an optional global shortcut.

- One list of **final results of every agent**, newest real answer first,
  from the Core's `results` (one process call instead of one `turns` call per
  session). Intermediate Stops are never listed; a turn the harness started
  after background work is shown under the user's original request; a
  background wait that expired is listed as "completion unknown".
- Row: unread dot · request (display text) · time · "Latest" when it is ·
  agent line ("Claude · claude-work · Claude Desktop") · project ·
  conversation · paperclip with attachments + changed files.
- Filters: All / Unread (n), All Agents / one profile. **Mark All as Read**
  affects only the rows shown. "Show More" loads the next 300.
- Click → that exact result opens on Home with Answer, Copy Answer, Copy
  with Context, attachments and Preview (Copy with Context goes to the Core
  for that session and turn — tested).
- Empty, loading and error (with Try Again) states.
- Loaded **only while the Inbox or Go To is on screen**; never by the
  compact notch or Home (tested: 0 Core calls in idle).

## 6. Unread results

- Per result (`ReportRef.key` → `answers.seenReports`), the same rule the
  notch and Project and Session already used: newer than the first-run
  baseline and not opened. Persisted; survives restarts (tested).
- Opening one result marks only that one. Opening the island on Latest marks
  only Latest (Phase 10 rule, kept). Claude Personal, Claude Work and Codex
  keep their own states (tested).
- Counts appear in the Inbox (Unread n), By Project ("2 new"), By Agent
  ("1 new") and Go To. The notch keeps one small green dot without a number.
- Four states are kept apart (documented in `AppModel+Workspace.swift`):
  newest received (`readyAnswer`), viewed (`seenAnswers`), chosen
  conversation (`selectedSessionKey` / pin), newest result of a project
  (`latestResult(inProject:)`).

## 7. Quick Switcher (Go To)

⌘K inside the island (or the menu-bar item / optional global shortcut).
Search field with ↑ ↓ ↩, scopes All · Unread · Agents · Projects ·
Conversations. Empty query: Latest, unread results, agent profiles, projects,
recent conversations; with a query: matches in names, titles, folder hints,
session ids and loaded result previews. Return opens: a result (marked read),
a profile (By Agent with that profile), a project, or a conversation. Uses
loaded data only; no new storage.

## 8. Shortcuts

| Where | Keys | Notes |
|---|---|---|
| Global (existing) | ⌃⌥⌘P open/close Prompt Relay | unchanged |
| Global (new, **off by default**) | ⌃⌥⌘I Results Inbox · ⌃⌥⌘K Go To · ⌃⌥⌘N next unread | Settings → General → Keyboard shortcuts: each switch, plus the modifier set (⌃⌥⌘, ⌃⇧⌘, ⌥⇧⌘). Carbon hot keys: no Accessibility permission, only the registered combination is seen. A combination macOS refuses (another app has it) is reported in Settings, not silently missing. |
| In the open island (new) | ⌘K Go To · ⌘I Inbox · ⌘J next unread | the panel has the keyboard only while open |
| In the open island (unchanged) | ⇧⌘C Copy Answer · ⌥⌘C Copy with Context · ⌘[ Back · ⌘, Settings · Esc back/close · ← → answers · ↩ copy | |

Tests use an inert hot-key handle: no real global key was registered by the
test suite.

## 9. Open at Login

Settings → General → "Open at login": `SMAppService.mainApp` (system login
items), **off by default**, on only by the user; off unregisters the same
item. Offered only for the installed Release copy (`~/Applications` or
`/Applications`); a Debug build or a copy elsewhere shows why it is
unavailable, so a DerivedData build can never become a login item. "Requires
approval" shows a button to System Settings → Login Items; errors are shown,
not retried. One instance: macOS starts one copy at login; opening the app
again brings that copy forward (LaunchServices); Debug and Release keep
separate bundle IDs. ADR-024.

**Not verified live:** registering changes the owner's login items and the
installed app was not replaced in this phase. **Requires owner** (installed
build from this commit; ad-hoc signing may require approval).

## 10. Evidence UI

Evidence & Review now opens with one card, **What can be trusted?**:
- **Confirmed locally** — commands and exit codes, files changed, stored
  materials (a failed command is a confirmed fact, flagged red);
- **Reported by the agent** — what the answer claims, never a fact;
- **Needs verification** — claims without matching evidence, missing
  materials, and the Review Checklist (ticks are the user's own).

The three previous sections (Evidence Check, Artifact Completeness, Review
Checklist) are unchanged under **Details**, including "Unavailable" facts
(e.g. CI not connected). Pure model `TrustSummary`; a test checks that every
non-"unavailable" item of the three sources appears exactly once and that a
claim is never in Confirmed. Copy with Context text is untouched.

## 11. Tests and performance

(See §12 for what ran live.)

| Check | Result |
|---|---|
| Python `tests/test_phase12.py` (11): profile ids and hints without user names; relative/empty variables; two Claude profiles in one project with equal native ids → two conversations, each with its own answer; payload verbatim + envelope profile; pre-Phase 12 records → Unassigned, nothing rewritten; Codex profile from `CODEX_HOME` and from older `installation_id`; forged profile fields rejected; Codex + Claude in one list newest first; filters, limit/total; intermediate Stop + redelivery → one result; usage errors; 3,000 results | **Verified with tests** |
| `scripts/check.sh`, Python 3.14.0 and 3.9.6 | 211 + 15 tests each, OK (1 skipped: Linux-only launcher case); hook latency median 40.5 ms, p95 47.8 ms; plugin launcher median 57.7 ms |
| Swift `Phase12Tests` (19): profiles apart with equal titles/ids; labels persist, removing a name keeps history; Unassigned; results decoding; Inbox all agents newest first, intermediate excluded, profile filter; read state independent across agents and restarts; Mark All as Read only rows shown; next unread order; Copy with Context of the Inbox result; no `results` call in idle/Home; error → retry; Follow Latest never replaces the answer being read, moves on at close; pin survives other agents; Quick Switcher kinds and activation; workspace mode persisted; 3,000 results (filter, grouping, search timing); shortcuts off by default, refused combination reported, modifiers re-register; Open at Login (Debug/not installed unavailable, on/off, approval, error); TrustSummary; layout of Inbox, Go To, By Agent, By Project, Evidence at 268 and 448 pt + Details height unchanged afterwards | **Verified with tests**, layout **Verified offscreen** |
| Full Swift suite | see §11a |
| Core `results` vs `sessions`, isolated synthetic history, median of 5 (machine busy running `swift test` at the same time) | 200: 195 vs 186 ms · 1,000: 213 vs 222 ms · 3,000: 290–301 vs 267 ms — **Measured**. One `results` call replaces up to one `turns` call per session (50 sessions ≈ 50 processes before). |
| App-side, 3,000 results in memory (Swift test, Debug build) | Inbox filter, By Agent grouping and Go To search each well under their 250/250/500 ms bounds — **Verified with tests** |
| Idle load | Inbox/Go To load nothing unless on screen (tested); no new timers or observers; FSEvents path unchanged |

### 11a. Full suite runs (all on this Mac, macOS 27.0, Xcode 27.1, arm64; logs in `macos/acceptance/phase12/`, not committed)

| Run | Result | Exit |
|---|---|---|
| `swift test`, run 1 (all Phase 12 code, before the new test file) | XCTest 271, 16 skipped, 0 failures; Swift Testing 70/70 | 0 |
| `swift test --filter Phase12` during development | 3 expectation errors in my own tests (they assumed opening the island did not mark Latest read — it does, Phase 10 rule; and one wording check), fixed in the tests; then a timing flake when the layout test wrote PNGs in a parallel suite — fixed by serializing the Phase 12 suite; 3 × 3 green runs afterwards | 0 |
| `swift test`, final | XCTest **271**, 16 skipped (env-gated by design), **0 failures**; Swift Testing **89/89**; `~/Library/Preferences` PromptRelay files 11,331 → 11,331 | 0 |
| `swift test --filter Phase12` after the last fix (Inbox no longer applies the hidden agent filter of other screens; found in self-review, regression check added) | 19/19 | 0 |
| `scripts/check.sh` (Python 3.14.0 and 3.9.6) | 211 + 15 each, OK, 1 skipped | 0 |
| `xcodebuild` Debug and Release, scheme "Prompt Relay", isolated DerivedData | BUILD SUCCEEDED both; Release stamp `6365809`, dirty `yes`, 0.3.0; `codesign --verify --deep` OK; not launched | 0 / 0 |
| Skipped XCTests (16) | env-gated visual dumps, audits, real paste, real dialog, perf — not run | — |

## 12. Live app vs tests only

**Nothing in Phase 12 was exercised in the live GUI.** No build was installed
or launched (the installed 0.3.0 and the running Debug build were left alone).

| Area | Status |
|---|---|
| Core profiles, scoping, `results` | Verified with tests (real CLI processes, isolated data dirs) |
| Inbox, read state, Follow Latest, Go To, By Agent, labels | Verified with tests (FakeCore) |
| New screens' layout, Details height | Verified offscreen (renders in `macos/acceptance/phase12/visuals/`, not committed) |
| Real Claude Code with a second `CLAUDE_CONFIG_DIR`; Codex CLI + Xcode side by side | **Requires owner** |
| Real global hot keys, conflicts with other apps | **Requires owner** |
| Open at Login registration and login | **Requires owner** |
| Collapsed notch, Quick Peek, Clipboard, Persistent Handoff, auto-capture window, external displays, Reduce Motion with the new screens | Existing suites pass (offscreen/mocks); live feel **Requires owner** |

### Owner scenario (≈ 20 min, after installing this commit with `scripts/install-local.sh`)

1. Terminal A: `claude` (default). Terminal B: `CLAUDE_CONFIG_DIR=~/.claude-work claude` with the plugin installed there too (`claude plugin install …` inside that profile). Ask both a small question in the same enabled project.
2. Results Inbox: two rows, "Claude · Default" and "Claude · claude-work"; open one → only it loses the dot.
3. Settings → Agents & Projects → Agent profiles: name them "Personal" / "Work"; Inbox and By Agent show the names.
4. Run Codex in Xcode in another project; By Agent shows "Xcode / Codex"; Inbox lists it on top.
5. While reading the Claude answer, let Codex finish: the answer stays, "New in …" appears; close the island → it opens on Codex next time.
6. ⌘K → type part of a conversation title → ↩.
7. Settings → General → Keyboard shortcuts → turn on Go To → ⌃⌥⌘K from another app.
8. Settings → General → Open at login → On; check System Settings → Login Items; log out/in once; Off removes it.
9. `prompt-relay sessions --json` shows `profile.basis: config_dir` for terminal B — record in HOOKS_RESEARCH.

## 13. Git

- Branch `claude/loving-mccarthy-ossw3q`; start `3287bc3`.
- `6365809` — Core: profiles, envelope scoping, `results`, schema, golden
  files, JSON_API, `tests/test_phase12.py`.
- `4a0ebb3` — App: workspace, Inbox, Go To, shortcuts, Open at Login,
  trust card, `Phase12Tests`.
- The docs commit that adds this file (PHASE12, STATUS, ADR-023/024,
  MULTI_AGENT_MODEL, HOOKS_RESEARCH) follows; see `git log`.
- Commits were made with explicit paths: the previously staged
  `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` is still staged and not
  committed; untracked `macos/acceptance/` items (incl. new
  `macos/acceptance/phase12/` logs and renders) left uncommitted.
- No push, merge, install, release or notarization. The Xcode builds of this
  phase went to a scratch DerivedData folder and were not launched.

## 14. Before a GitHub beta

1. Owner live checks of §12 (profiles with a real second config folder,
   hot keys, login item) and the carried-over Phase 11 items.
2. Version: the Core and app still say 0.3.0 although `results` and profiles
   are new — decide 0.4.0 before a public build (install script checks that
   both match).
3. Setup per detected config folder (today Setup checks default locations
   only) and an explicit "assign Unassigned conversations to a profile"
   action — both left out on purpose (no guessing).
4. License, Developer ID, notarization, Codex setup without a checkout,
   public marketplace (unchanged from Phase 11).

## 15. Proposal: Phase 13 — Universal Handoff (not started)

Goal: one hand-off from any result to any destination, with the same
verbatim guarantees.

1. **Destinations model** — "paste into ChatGPT/Claude.ai/Gemini/another
   agent" as named targets with what each accepts (text, image data, file
   URLs), measured on this Mac; Copy with Context picks the right
   pasteboard types per target instead of one generic write.
2. **Multi-result hand-off** — select several Inbox results (e.g. Claude's
   plan + Codex's implementation) into one labelled Context Pack, never
   merging their texts, each with its provenance and profile.
3. **Read-only MCP output** (ADR-022 design): `get_latest_result`,
   `get_context_pack`, `list_conversations` per allowed project, off by
   default, audit line per call — agent-to-agent pull without the
   clipboard.
4. **Hand-off history** — what was handed where (destination label, time,
   files), never the destination's content.
5. **Live acceptance first**: close Phase 11/12 owner checks before
   building on them.

---

## 16. Acceptance pass (2026-11-05, after `7b49608`)

**Fixed.** The Results Inbox listed a background wait that expired with no
continuation ("completion unknown") among finished results, with only a small
tag — and it could carry the "Latest" label. Now (`88a1e73`):
- **Finished**: final answers (an answer the user moved on from while work
  still ran stays here, tagged "work was running": the agent did end its
  turn).
- **Needs attention**: completion unknown — a separate section under All and
  an **Attention (n)** filter; a one-line explanation; no unread dot, never
  counted as new, never "Latest", not offered as a result in Go To. History
  and diagnostics are kept: the row still opens the last message, observed
  work and copies. A wait that has not expired is not listed at all.

**Verified with tests on the final code** (`88a1e73`, logs in
`macos/acceptance/phase12/`, not committed):

| Check | Result |
|---|---|
| `swift test` | XCTest 271, 16 skipped (env-gated), 0 failures; Swift Testing **90/90** (20 Phase 12); `~/Library/Preferences` test files 11,331 → 11,331 |
| `scripts/check.sh`, Python 3.14.0 and 3.9.6 | 212 + 15 each, OK, 1 skipped (Linux-only launcher case); hook median 40.7 ms |
| `xcodebuild` Debug / Release (isolated DerivedData) | BUILD SUCCEEDED; Release stamp `88a1e73`, not dirty |
| `git diff --check` (working tree and `3287bc3..HEAD`) | clean |
| Profiles kept apart, names persist, removing a name keeps history | Swift tests |
| Old Claude Code conversations stay Unassigned, nothing rewritten | Python (real CLI) + Swift |
| Independent unread state across agents and restarts | Swift |
| Copy with Context of an Inbox result = that session and turn | Swift (FakeCore call) + **new** Python test through the real Core: a non-default profile's `context` / `copy-context` contains its own answer, never the other profile's |
| `install-local.sh --status` | installed 0.3.0 `3287bc3`; running Release PID 9710, Debug (Xcode) PID 55979 |
| `install-local.sh --list-backups` | one backup: `Prompt Relay 0.3.0-6c004a2-20261105-211139.app` |
| `install-local.sh --dry-run` | built + verified `88a1e73` (signature, 0.3.0 = Core 0.3.0, Core digest `ede637c0…`); plan: back up `3287bc3`, install, open, check one copy; **nothing changed** |

**Not done (needs the owner):** the real install (consent), and every live
check below.

### Manual checks (≈ 25 min, after install)

| # | Area | Do | Expect |
|---|---|---|---|
| 1 | Inbox | Two agents finish; open one row | only that row loses its dot; Unread (n) drops by one; Details shows that answer |
| 2 | Inbox | Ask an agent to run long tests in the background and stop it | after 2 h without a follow-up the row is under **Needs attention**, never with a green dot |
| 3 | Inbox | Copy with Context from a row opened in the Inbox; paste | text names that project, agent and request |
| 4 | By Agent | Project and Session → By Agent | one row per profile (Default / named / Unassigned / Xcode); counts match; menu choice kept after relaunch |
| 5 | Profiles | Second Claude profile: `CLAUDE_CONFIG_DIR=~/.claude-work claude` (plugin installed in that profile), one question | new row "claude-work"; `prompt-relay sessions --json` shows `profile.basis: config_dir` (record in HOOKS_RESEARCH) |
| 6 | Go To | ⌘K, type part of a title, ↑↓, ↩ | opens it; Esc returns |
| 7 | In-island keys | ⌘I, ⌘J, ⌘[ , Esc | Inbox, next unread, Back, close |
| 8 | Global shortcuts | Settings → General → Keyboard shortcuts → turn on Go To; press ⌃⌥⌘K in another app; try another modifier set | island opens on Go To; a taken combination shows the warning; off = key does nothing |
| 9 | Open at Login | Settings → General → Open at login → On; System Settings → General → Login Items; log out/in; then Off | listed (approve if asked); one copy starts; Off removes it |
| 10 | Snapshots (Phase 11 §4, still open) | Capture Final Window → pick a window → Copy Files → paste into a browser chat; quit/reopen | picker + consent shown; image pastes; nothing written to disk; gone after restart |

### When to raise 0.3.0 → 0.4.0 (proposal)

Raise **before the install used for live checks**, in one small commit:
Core `__version__`, `plugin.json`, Xcode `MARKETING_VERSION` (the install
script refuses a mismatch). Reasons: (1) Claude Code keeps the plugin in a
folder per version, so the new hook code (profiles in the envelope) reaches
Claude Code only with a new version and `claude plugin update` — with 0.3.0
the live profile check (#5) would test the old hook; (2) the Core gained a
command and fields (additive; JSON `api_version` stays 1) and the app's About
and the backups should tell 0.3.0 and 0.4.0 apart. Not a release: no tag, no
push. If the owner prefers, 0.4.0 can instead be the closing commit after the
live checks — then #5 must wait for it.

### Can Phase 12 be closed?

Code-side acceptance: yes — all automated checks green on `88a1e73`, the
Inbox defect fixed. Formal closure needs the owner: consent to install, the
version decision, and manual checks 1–9 (10 belongs to Phase 11).

## 17. Version 0.4.0 and code closure (2026-11-05)

`7db1e4b`: Core `__version__`, `plugin.json`, Xcode `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` → **0.4.0**; JSON `api_version` stays **1**
(additive changes only). A new test pins Core = plugin.json = Xcode and
API v1. Texts like "needs the plugin 0.3.0 or later" are minimum versions
for tool hooks and stay. `docs/PLUGIN.md` §1b, `docs/JSON_API.md` updated.

| Check at `7db1e4b` | Result |
|---|---|
| Targeted: version test, `test_api` (schema + golden), `test_plugin`, macOS integrations; Swift Phase11 (About/version), CoreIntegration, Decoding, CoreClient, Phase 12 | all pass |
| `scripts/check.sh` Python 3.14.0 / 3.9.6 | 213 + 15 each, OK (1 skipped, Linux-only) |
| `swift test` | XCTest 271, 16 skipped, 0 failures; Swift Testing 90/90; prefs files 11,331 → 11,331 |
| `xcodebuild` Debug / Release | BUILD SUCCEEDED; Release 0.4.0, `7db1e4b`, not dirty |
| `claude plugin validate plugin` and `.` (read-only) | passed |
| `install-local.sh --dry-run` | 0.4.0 = Core 0.4.0, Core digest `5719914b…` = checkout, commit = HEAD; backup target and rollback shown; nothing changed |

### The active Claude Code plugin (read-only findings)

- Installed: `prompt-relay@prompt-relay` **0.3.0**, user scope, from
  `~/.claude/plugins/cache/prompt-relay/prompt-relay/0.3.0` (0.2.0 also
  cached). That copy has no `profiles.py`: **today's hook does not record
  profiles** — live check #5 needs the update.
- Marketplace `prompt-relay`: source type `directory`, path = this checkout.
  Claude Code 2.1.268.
- `~/.claude/settings.json`: no Prompt Relay hooks (plugin only); other
  tools' hooks exist (counts only, not read further).

**Safe update (owner runs it, after consent; not done):**
1. Keep the checkout clean at a committed 0.4.0 — the directory marketplace
   copies the working tree as it is at that moment.
2. `claude plugin marketplace update prompt-relay`
3. `claude plugin update prompt-relay@prompt-relay` → new cache folder
   `…/0.4.0`; `installed_plugins.json` points to it.
4. Restart Claude Code sessions (Desktop: quit and reopen) — running
   sessions keep the old hook until then.
5. Check: `bin/prompt-relay doctor` (plugin record 0.4.0, launcher found);
   after one answer, `bin/prompt-relay sessions --json` shows `profile`.

What it touches: only `~/.claude/plugins/` (marketplace timestamp,
`installed_plugins.json`, the new cache folder). It does not change
`settings.json`, other tools' hooks, trust records or credentials; Codex
hooks are separate and unaffected. Same hook events and matchers as 0.3.0.
Undo: the 0.3.0 cache folder stays; to go back, check out a 0.3.0 commit and
run steps 2–3, or `claude plugin uninstall prompt-relay@prompt-relay` and
install again. History in the data dir is never touched; records without a
profile simply read as Unassigned.

### App install (prepared, not done)

`scripts/install-local.sh` (builds the current HEAD, verifies, asks, backs
up `~/Applications/Prompt Relay.app` 0.3.0 `3287bc3` to
`~/Library/Application Support/PromptRelay-AppBackups/`, quits only the
Release copy after a second yes, installs, opens, checks one copy). The
Debug build from Xcode is never quit. Undo: `scripts/install-local.sh
--rollback`.

### Short manual checks (after app install + plugin update)

1. **Inbox** (⌘I): answers from two agents → open one; only it loses the dot.
   A background task left unfinished > 2 h appears under *Attention*, without
   a dot. Copy with Context from an Inbox row → paste → that agent's request
   and answer.
2. **By Agent**: Project and Session → *By Agent* menu → rows per profile;
   a second Claude profile (`CLAUDE_CONFIG_DIR=~/.claude-work claude`, plugin
   installed there) appears as its own row; name it in Settings → Agents &
   Projects → Agent profiles.
3. **Go To** (⌘K): type part of a title, ↑↓, ↩; Esc returns.
4. **Keys**: ⌘I, ⌘J, ⌘[, Esc in the island; Settings → General → Keyboard
   shortcuts → turn on Go To, press ⌃⌥⌘K in another app; turn off → nothing.
5. **Open at Login**: Settings → General → On → System Settings → Login
   Items lists it (approve if asked) → log out/in → one copy → Off removes it.
6. **In-memory screenshot** (Phase 11): Answer → paperclip → Capture Final
   Window → pick a window (consent dialog first time) → Copy Files → paste
   into a browser chat → quit/reopen: the image is gone, no PNG in the data
   dir.

### Status

- **Verified (this Mac, automated):** everything in the tables above and
  §16; layout of the new screens offscreen.
- **Not verified:** anything in the live GUI; the real plugin update and a
  hook run with a non-default `CLAUDE_CONFIG_DIR`; global hot keys against
  other apps; login item; snapshot picker (Phase 11).
- **Phase 12 is closed on the code side** at `7db1e4b` (+ this report).
  Formal closure waits for the owner's install, plugin update and the six
  checks. Phase 13 not started.

## 18. 0.4.0 installed for live acceptance (2026-11-05, owner consent)

- **App** (`install-local.sh --yes`): backup
  `PromptRelay-AppBackups/Prompt Relay 0.3.0-3287bc3-20261105-232654.app`
  (plus the older `0.3.0-6c004a2`); the Release copy quit normally; running
  now: `~/Applications/Prompt Relay.app`, PID 2877, 0.4.0, commit `e75cdd5`
  (clean), bundled Core 0.4.0, Core digest `5719914b…`, signature valid.
  Undo: `scripts/install-local.sh --rollback`.
- **Plugin audit before updating**: the marketplace copies the whole
  `plugin/` folder as it is on disk. Acceptance files, logs, user data and the
  staged REPORT.md are outside it; no symlinks or secrets were found inside
  (the only match is the secret *detector* in `sensitive.py`). The only extra
  files were ignored `__pycache__` bytecode, and the old "0.3.0" cache had
  copied them. That cache was also **older than the 0.3.0 source**: it was
  copied on 2026-10-29, before `adapters.py`/`projects.py` existed.
- **Plugin update**: removed only `plugin/**/__pycache__`, checked the tree
  was clean at `e75cdd5`, then `claude plugin marketplace update
  prompt-relay` and `claude plugin update prompt-relay@prompt-relay` →
  record 0.4.0, cache `…/0.4.0`, **27 files, byte-identical to `HEAD:plugin`,
  nothing extra**; `~/.claude/settings.json` hash unchanged; no Prompt
  Relay hooks in settings; 0.2.0/0.3.0 caches kept.
- **Smoke test of the installed hook** (its own launcher, isolated temp data
  dir, `CLAUDE_CONFIG_DIR=~/.claude-work`): exit 0, empty stdout, profile
  `cc-614bf41e47cd9d4b` / `config_dir` / `~/.claude-work`, key scoped;
  temp dir removed.
- **Still open**: Claude Code sessions use the new hook only after a
  restart; the Xcode Debug copy (PID 55979) was still running — the owner
  stops it in Xcode. Live checks: §17 list.
