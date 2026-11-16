# Phase 9.3 — one Latest across agents, smart attachments, logical projects

2026-11-05. Starting HEAD `fa371a25462c20001a46b87e4f99db04dda0d69e` on
`claude/loving-mccarthy-ossw3q`, with the uncommitted Phase 9.2 and Adaptive
Island Height work of the previous agent (Codex in Xcode) in the tree.

## Preservation

Before any change: `refs/backup/phase9.3-start` (a `git stash create` commit of
every tracked change, staged and unstaged; the working tree was not touched),
plus `~/Projects/prompt-relay-backups/phase9.3-start-*/` holding the staged and
unstaged binary patches, `git status`, HEAD and a tarball of all untracked
files. No reset, clean, history deletion or clipboard clearing.

## Root causes found

1. **Latest never crossed providers.** `loadReadyAnswer` followed a new answer
   only when its provider equalled the selected session's (`sameProvider`), so
   a Claude Code answer never replaced a Codex one in Quick Peek.
2. **Every click pinned forever.** Any manual pick set `sessionPinned` and saved
   it (`selection.pinned`). The owner's real preferences hold such a pin on a
   Codex session in `…/prompt-relay/macos` (read-only check). With it, newer
   answers from other sessions only showed as "New in …".
3. **"Latest" meant latest activity.** A finished session's `last_event_at`
   was used as the answer time; a later tool event made an older answer look newer.
4. **`macos` as its own project.** The Core lists projects by raw `cwd`; Xcode's
   Codex runs in `<repo>/macos`, which appeared as a second project beside
   `prompt-relay` (confirmed on the real store, read-only).
5. Smaller: host `terminal` was titled "CLI"; imported rows said "Imported ·"
   instead of "Imported by you"; the Review Pack's last paragraph addressed
   Claude Code even for other AIs; `0 answers` sessions were labelled "stopped"
   like finished ones; the ready dot was white, with no state for a capture error.

## What changed

**Core (Python, stdlib, 3.9-compatible; never used by the hook):**
- `projects.py`: logical project of a folder. Order: most specific enabled
  project (unless a Git work tree lies strictly inside it, so a broad enabled
  folder never merges repositories) → verified Git root (`.git` dir with
  `HEAD`, or a `gitdir:` file; symlinked `.git` ignored) → workspace marker
  (`Package.swift`, `*.xcodeproj`, …) → the folder. Canonical `realpath` ids.
  Only `stat`/`listdir`; never runs git.
- API v1, additive optional fields: `logical_project {path,name,basis}` on
  `projects` items and session summaries; `last_turn.answered_at`;
  `continues_request` on turns. Raw `project`/`cwds` are unchanged.
- Continuations: a short request such as "продолжи где остановился" or
  "continue" stays the turn's request verbatim; the latest earlier substantive
  request **of the same session** is offered as `continues_request` and in the
  pack as "Earlier task this request continues", labelled, after the request.
  It is secret-scanned like the request. No AI is used.
- Copy with Context: "Source, host and project" (`Codex · Xcode · This Mac`;
  Host Unknown when not recorded), the logical project plus the working folder,
  "Not checked (provenance and verification limits)", "Request for independent
  review". Plain Markdown, no recipient-specific wording.

**App (Swift):**
- Latest = newest completed answer with text, any provider, by `answered_at`
  (fallback: activity time); stable tie order; Stop without text and running
  prompts never qualify; repeated delivery is not a new answer.
- Behavior → **Stay on the session I choose**: off (default for new installs)
  = Follow Latest; a pick holds only while the island is open, newer answers
  show as "New in …", and Latest takes over after close. On = Phase 5 pinning.
  Migration: a saved pin turns the setting on, so the owner's pin is kept, not
  silently changed; Settings shows "Pinned: …" and **Follow Latest**.
  Project and Session has **Jump to Latest** when the selection is not Latest.
- Logical projects: Core rows merge by `logical_project` (`prompt-relay` +
  `macos` → one row; the capture switches in Settings stay per folder); a
  saved `macos` selection maps to its logical row; sessions of a nested
  project of its own (for example the enabled `xcode-smoke`) stay out.
- Project and Session: sessions newest first; provider · host on each row;
  states `working` / `answered` / `no answer` / `API error`; a `Latest` tag;
  `N new` per project; imports show "Imported by you · <AI> · <host> · pasted, not captured".
- Ready indicator: green (the theme's success tone) = an answer with text is
  available, not "task succeeded"; a warning `!` when capture cannot be read.
- Smart attachments: the allowed root is the logical project when it contains
  the working folder. New category **named and verified locally**: a Markdown,
  text, PDF or image file named in the answer, inside the project, that changed
  during the turn (local mtime ≥ request time) is auto-selected and labelled
  "named · changed this turn" (never "created by the agent"). Without a turn
  window it is only offered. Exclusions persist across rediscovery and restart.
- Full Task / Task card: the continuation context, labelled.

Not rewritten: Adaptive Island Height, hooks, adapters, history storage,
handoff persistence, Relay.

## Source adapter contract (future providers)

A provider is added as a registry adapter in `plugin/prompt_relay/adapters.py`
that maps its documented hook JSON to the canonical event, plus a `source`
record. Capabilities are declared, never assumed; absent ones show as
unavailable. Host comes only from configuration (`PROMPT_RELAY_HOST`).

| Capability | Claude Code | Codex | Imported | Future (Gemini CLI, …) |
|---|---|---|---|---|
| Request capture | UserPromptSubmit | UserPromptSubmit | typed by you | per documented hooks only |
| Final answer | Stop `last_assistant_message` | Stop `last_assistant_message` (optional) | pasted by you | — |
| Commands | PostToolUse / PostToolUseFailure | PostToolUse (exit code only when reported) | unavailable | — |
| Files | Edit/Write/SendUserFile | successful apply_patch / Xcode write results | unavailable | — |
| Native session ID | `session_id` | `session_id` (namespaced key) | unavailable | — |
| Native turn ID | `prompt_id` | `turn_id` | unavailable | — |
| Host | configured launcher only, else Unknown | configured launcher only, else Unknown | chosen by you | — |
| Completion notice | Stop (not success) | Stop (not success) | none | — |

Not implemented: Gemini, Grok, ChatGPT adapters, paid APIs, OCR, UI scraping,
private databases of other apps.

## Verification

See the final section of `docs/STATUS.md` (2026-11-05) for exact counts.
