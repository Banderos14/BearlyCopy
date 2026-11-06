# Phase 13 — Universal Handoff, multi-result Context Packs

2026-11-06. Start: HEAD `7ebc6a5` (Phase 12.2), app/Core/plugin 0.4.1.
Nothing installed, pushed, merged, tagged or released; staged
`macos/acceptance/phase9.1/xcode-smoke/REPORT.md` and every untracked
acceptance file left as they were; no hooks, trust records, Claude/Codex
settings or other apps' data touched.

Categories: **Automated passed** · **Offscreen render** · **Requires owner**
· **Not implemented**.

## 0. Preflight

| Check | Result |
|---|---|
| HEAD / branch | `7ebc6a5` on `claude/loving-mccarthy-ossw3q` |
| Phase 12.2 drag fix in HEAD (`acceptsFirstMouse`, `shouldDelayWindowOrdering`, 3 pt threshold, one session per press, reset on end) | present (`Notch/DetailsViews.swift`) |
| Installed app | 0.4.1 `0dffa80` (**without** Phase 12.2) at `~/Applications` |
| Running copies at start | Release (PID 62216) **and** an Xcode Debug copy (PID 55979) |
| Phase 12.2 owner checks (real cross-app drag, in-memory screenshot drag, SwiftUI attachment rows, Deny / cancelled question / two sessions, full screenshot paste into ChatGPT) | **still open** — not run in this phase |

Phase 12.2's claimed test counts were not reused; this phase's own runs are
in §8.

## 1. What was there (audit)

- Copy with Context = Core `context` text + app attachments section
  (`ReviewPack.render`), two-step hand-off (`HandoffStep`, persisted in
  `handoffs.json`), Copy Files / Drag through `FileDragSource` (files as
  URLs, window snapshots as image data, ADR-018), Export Bundle.
- Result identity: `session_key#turn`; a non-default profile already scopes
  the session key (ADR-023), so equal native ids never collide.
- `ReportStore.handoffFiles` wipes and refills one `handoff/` folder per
  call — a second hand-off would have removed the first one's files (fixed
  for packs: own folder `handoff-pack/`).

## 2. What was built

**Core** (`context_pack.py`, `cli.py context-pack`, schema
`context_pack_data`): `render_context` split into its sections (output
byte-identical: golden tests); each result rendered by those sections one
heading level deeper; order kept; duplicates and > 20 refused; Git read once
per project; `external` slots for imports; manifest without paths, session
ids or text; per-result secret findings. `docs/CONTEXT_PACK.md`, ADR-026.

**App**:
- Inbox: `+` / `✓` on every row and in the context menu; a bar "N chosen ·
  Create Context Pack". Details ⋯: Add to / Remove from Context Pack,
  Context Pack…, Handoff History….
- Context Pack view: numbered results (provider · profile · host · project),
  move up/down, remove, open the source; warnings for mixed projects and for
  equal session ids across profiles; optional Review instructions (the
  user's words, labelled as theirs); receiver; "Add manifest"; Prepare.
- Prepared: characters, files (temporary / missing), long-paste warning,
  1 · Copy Text, 2 · Copy Files, Drag, Preview, Export…, Copy Manifest; one
  progress line ("Text copied 09:02 · Files: not handed over yet … Delivery
  not verified"). Secrets: inline "Copy Anyway" / Cancel; Export refused.
- Preview: per result source, provenance split (Confirmed locally /
  Reported by agent / Not verified), attachment availability, Open; the
  exact text (Formatted / Markdown Source).
- Handoff History: prepared packs, steps, receiver, counts; Prepare Again,
  delete one, Clear All.
- Draft (results, instructions, receiver) survives a restart; the prepared
  text is never stored.

## 3. Workflow

Inbox → `+` on the Claude design, the Codex implementation, the Claude
review → **Create Context Pack** → reorder, write "Check the implementation
and find bugs", pick ChatGPT → **Prepare** → **Preview** (optional) →
**1 · Copy Text** → paste in ChatGPT → **2 · Copy Files** (or **Drag**) →
paste/drop → Send yourself. History shows Prepared → Text copied → Files
copied, "destination not verified".

## 4. Text and images; NSPasteboard and drag limits

| Fact | Status |
|---|---|
| Text copy is byte-exact (read back by unicode scalars) | Automated passed |
| Copy Files: file URLs + one image-data item per snapshot, no file URL for snapshots, no PNG written | Automated passed (private pasteboard, real `ReportStore`) |
| Copy Files replaces the text on the clipboard (one pasteboard) — hence two steps | by design; shown in the UI |
| Drag from the non-key island on the first press; again after Esc | Automated passed (real `NotchPanel.sendEvent`, session recorded not started) |
| Export is the only place a snapshot becomes a file | Automated passed |
| Text + several images in **one** paste into ChatGPT / Claude / Gemini | **not verified**; not claimed. Receivers: text/Markdown "standard paste", images/files "not verified", Codex image paste "not possible" (terminal) |
| Real paste/drop into any AI app | **Requires owner** |
| macOS or the receiver may keep copied data (pasteboard history, uploads) | outside Prompt Relay; no guarantee given |

## 5. Provenance

Each result section keeps Copy with Context's labels. Codex sections say
"Reported by Codex", Claude "Reported by Claude", imports "Reported by
agent" + "Supplied by you". Automated turns show the earlier user request
and the automated message separately (test). The user's instructions are a
separate `## Review instructions` section, `[Supplied by you]`; without
them, `## Review request` labelled "[Prompt Relay standard text]". Missing
attachments are listed under Availability, never offered.

## 5a. Limits (measured)

| Pack | Core build | Size |
|---|---|---|
| 1 result (55 kB answer) | 80 ms | 59 k chars |
| 5 results | 101 ms | 292 k chars |
| 20 results | 180 ms | 1.17 M chars |

Clipboard: a 4 MB string copies and reads back in < 0.5 s. Limits chosen:
20 results; warning above 100,000 characters (chat paste limits are not
verified); no clipboard copy above 2,000,000 (Export). The Inbox loads
nothing new: `packRows` reads the already loaded results; the Core is called
only on Prepare (one `context-pack` call, plus `show` per result when
"auto-select result files" is on, as for Copy with Context). The 3,000-result
`results` test still passes.

## 6. MCP

Not implemented — ADR-027. Spec checked (latest `2026-07-28`, legacy
`2025-11-25`, different handshakes); which revision the owner's clients use
is unknown, and a real connection needs their consent to change Claude/Codex
configuration. `context-pack` is the body of a future `get_context_pack`.
Plan: `docs/MCP_EVALUATION.md` "Phase 13 update".

## 7. Fixed during the phase

- A prepared pack ending with the instructions' code fence was taken for a
  pack with a manifest and shown as stale (Copy refused). Found in the
  offscreen render; `includesManifest` flag + regression assertion.
- Pack Copy/Drag steps were below the fold; now pinned under the scrolling
  part (render checked).
- Pack files no longer share the single hand-off's folder.

## 8. Test and build results

Logs: `macos/acceptance/phase13/` (untracked, like earlier phases).

| Run | Result |
|---|---|
| Python 3.14.0 `scripts/check.sh` | 249 tests OK (1 skipped: root-only permission test) + 15 integration OK |
| Python 3.9.6 (`/usr/bin/python3`) | 249 OK (1 skipped) + 15 OK |
| Hook latency (50 runs) | median 38.9 ms; plugin launcher median 55.9 ms |
| Swift XCTest (`swift test`) | 290 executed, **0 failures**, 16 skipped |
| Swift Testing | 102 tests in 21 suites passed |
| Phase 13 Swift tests | 12/12 (in the 290) |
| Phase 13 Python tests | 17/17 (in the 249) |
| Xcode Debug / Release (`xcodebuild … build`) | BUILD SUCCEEDED / BUILD SUCCEEDED |
| Offscreen renders | `phase13-inbox/contextPack/contextPackPreview/handoffHistory.png` |

The 16 skips are the opt-in render/audit tests (PROMPT_RELAY_SNAPSHOT_DIR,
live-history and real-handoff opt-ins), the real-pasteboard interop kit,
the real open-panel test and the CPU measurement — the same set as Phase
12.2; none is a Phase 13 test. Xcode warnings: one pre-existing unused value
(`IslandViews.swift:1926`) and the AppIntents metadata note.

Not verified anywhere: a real paste or drop into ChatGPT, Claude, Gemini or
Codex; the FakeCore and private pasteboards prove nothing about receivers.

## 9. Owner checks (Requires owner)

Before accepting Phase 13 (both need the current build installed — only
with your consent):
1. Phase 12.2 open items (real first-press drag into another app, drag of an
   in-memory screenshot, SwiftUI attachment rows, Permission Deny /
   cancelled question / two sessions, full screenshot paste into ChatGPT).
2. Context Pack of Claude + Codex results → Copy Text → paste into ChatGPT
   (web and desktop) and Claude: text complete, Markdown fences intact.
3. Copy Files after the paste: do several images / files arrive? Same with
   Drag. Note per receiver; update `HandoffDestination.support` only from
   these observations.
4. A pack with a window snapshot: Copy Files / Drag into ChatGPT, then quit
   Prompt Relay and confirm no PNG remains in its data folder.
5. Restart between Prepare and Copy: draft is back, Prepare again works.
6. Inbox, Go To, By Agent, unread dots and Needs Input unchanged in daily use.

## 9a. Version

Proposal (not applied): **0.5.0** for app, Core and plugin together — Phase
13 adds a Core command and a user-facing feature. The hook code is
unchanged, but the Core ships inside the plugin and the release checks
require Core = plugin = app version, so the plugin moves too (a plugin
update without behaviour change for the hooks). API stays v1 (additive).
Applied on 2026-11-06 at the owner's request: `e245bfe` (see
`ACCEPTANCE_0.5.0.md` for install and live checks).

## 10. Until the GitHub beta

Owner checks above; real paste/drop matrix per receiver; Developer ID
signing and notarization (no certificate on this Mac); decide 0.5.0; MCP
(Phase 14) or not before beta; README/INSTALL screenshots of the pack flow.
