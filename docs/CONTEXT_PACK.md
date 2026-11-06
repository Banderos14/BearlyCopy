# Context Pack — format and hand-off (Phase 13)

A Context Pack carries one or more results (Claude Code, Codex, imported
reports) to another AI as **one Markdown document**, each result in its own
section with its own source and provenance. It never merges, summarises or
rewrites a result, and one agent's words never confirm another's.

Format: `prompt-relay-context-pack`, **version 1**. Versioned on its own,
independently of the app (0.4.1), the Core and JSON API v1. ADR-026.

## 1. Who builds what

| Part | Built by | From |
|---|---|---|
| Section of a local result (source, request, final response, observed work, Git state, Not checked) | Core `context-pack` | the same functions as Copy with Context (`export.py`), one heading level deeper |
| Section of an imported report | app (`ReviewPack.importedSections`) | the import as pasted, one level deeper |
| Attachments of each result, with availability | app | `ReportStore` (selected attachments only) |
| Frame: title, labels, Contents, warnings, result headings, review instructions | Core `context_pack.render_pack` **and** app `ContextPackComposer` | same text; `Phase13Tests` asserts the app's document equals the Core's for local results without attachments |
| Manifest | Core per result + app (attachments, imports, receiver) | facts only |

`prompt-relay context-pack --result SESSION_KEY:TURN [...] [--instructions
TEXT | --instructions-file PATH|-] [--json]` is read-only. At most 20
results; a result listed twice is a usage error; `--result external`
reserves a position the app fills (an import), so the Core numbers its
sections and "same Git reading as Result k" correctly. Git is read once per
project folder.

## 2. Markdown layout

```
# Context Pack: N AI results for an independent check
Prepared by Prompt Relay at <time>. No AI service was used. Format: prompt-relay-context-pack v1.

Provenance labels: [Confirmed locally] …; [Reported by Claude] …; [Reported by Codex] …;
[Supplied by you] …; [Not verified] …; [Unavailable] …

Each result below is a separate section with its own source. …

## Contents
1. Claude Code · Default · Claude Desktop — project prompt-relay — “Fix the cache” — answered <time>
2. Codex · Default · Terminal — project prompt-relay — …
- Warning: these results come from 2 different projects (…). …   (only when they do)

## Result 1 of 2 — Claude Code · Default · Claude Desktop · prompt-relay
### Source, host and project
### Original user request          (or: Request (source not established) / earlier user request + automated message)
### Claude final response          (verbatim, inside a fence longer than any it contains)
### Observed during this turn [Confirmed locally]
### Files Claude changed …
### Git state (read-only, collected at export time …)
### Attachments (n files, sent separately)    (app; missing ones only under Availability)
#### Availability (checked when this pack was prepared)
### Not checked (provenance and verification limits)

## Result 2 of 2 — Codex · …
…

## Review instructions                     [Supplied by you], verbatim in a fence
   — or —
## Review request                          [Prompt Relay standard text], labelled as such

## Manifest (machine-readable)             optional (“Add manifest”), fenced JSON
```

Rules:
- The final response and the request are byte-for-byte the captured text
  (tests: CRLF, combining characters, emoji, nested fences, headings inside
  answers).
- A turn started by an automated message (`<task-notification>`,
  `<agent-message>`, …) never shows that message as the user's request.
- Each result's provider decides its label (`Reported by Claude` /
  `Reported by Codex`); imports use `Reported by agent` + `Supplied by you`.
- The user's profile name (Settings) replaces the neutral one in headings.

## 3. Manifest

No absolute paths, no session ids, no request/response/instructions text.
Results are named by `result_id` = `r-` + 16 hex of SHA-256 over
`session_key#turn` (imports: `import#<id>`). Per result: position, kind
(`local_capture` / `user_import`), provider, profile, host, project, turn,
answered_at, status, completion, link, request {included, provenance,
origin, characters}, response {provenance `reported_by_agent`, characters},
observed counts, attachments {name, kind, bytes, availability `file` /
`memory_only` / `missing`, origin}. Pack: prepared_at, prepared_by,
`ai_service_used: false`, destination, warnings, limits.

## 4. Hand-off

1. **Copy Text** — the exact Markdown, read back from the pasteboard. Likely
   secrets (`sensitive.py` per result, `SecretScanner` for imports) wait for
   "Copy Anyway".
2. **Copy Files** — available files as file URLs (hand-off copies in their
   own folder `handoff-pack/`, so a single-result hand-off is not disturbed)
   plus window snapshots as image data (no file); replaces the text on the
   clipboard. **Drag** carries the same through the Phase 12.2 drag source.
3. **Export…** — folder the user picks: `context-pack.md`, `manifest.json`,
   `files/` (the only place a snapshot becomes a file). Refused with likely
   secrets.

Phase 14: **auto screenshots** (ADR-028) are window snapshots like the
others — image data in memory — but start unchecked unless the user turns
on "Include auto screenshots in handoff"; an unchecked one is not in the
text, the manifest, Copy Files, Drag or Export. Their origin line says
"auto screenshot of the window the user linked to this agent, taken by
Prompt Relay after the final answer; it may not show the answer's last
lines". Format v1 is unchanged.

A change to results, order, instructions, receiver, manifest option or
chosen attachments marks the prepared pack stale; nothing stale is copied,
dragged or exported.

Limits: 20 results. Over 100,000 characters: warning (long pastes may be cut
or refused — not verified per app). Over 2,000,000: no clipboard copy, Export
instead. A 4 MB string copies and reads back in < 1 s here, so the limit is
about chats, not the pasteboard.

## 5. Receivers (`HandoffDestination`)

ChatGPT, Claude, Gemini, Codex, any AI chat. Receivers, not capture sources.
Text and Markdown (as plain-text source) are a standard paste. Image data,
file URLs and several files at once are **not verified** for any receiver;
for Codex in a terminal, image paste is not possible and a dropped file
becomes its path. The choice changes guidance only. Prompt Relay never
pastes, presses Send, reads another app or drives a browser.

## 6. Handoff History

`<data dir>/app/handoff-history.json` (next to `handoffs.json`), newest
first, at most 100: time, receiver, result references with a short label,
file and temporary-image counts, characters, and the steps the user took —
Prepared, Text copied, Files copied, Drag started, Exported. Never
"delivered". No text, no instructions, no images. Delete one or all; the
results are untouched. **Prepare Again** rebuilds from the Core. The draft
(results, instructions, receiver) is kept in `context-pack-draft.json`, so a
restart between preparing and handing over only needs Prepare again — the
pack text itself is never stored.
