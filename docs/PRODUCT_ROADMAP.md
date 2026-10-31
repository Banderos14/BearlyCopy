# Product roadmap (proposal, 2026-10-31)

Prompt Relay's job: help a developer **understand what an AI coding agent just
did** and **hand the result to another assistant** without retyping, with
honest provenance. Everything below is judged against that job. Nothing here
is approved; each item needs the owner's decision.

Sources were read on 2026-10-31 (READMEs and public pages; no market
figures are claimed). Where third-party summaries disagreed with each other,
the item is marked *to verify*.

## What already exists (Phase 6)

Claude Code plugin hooks (UserPromptSubmit, Stop, StopFailure, PostToolUse,
PostToolUseFailure) · project → session → answer, sessions never mixed ·
request origin (user / pasted / automatic) · Copy Answer · Copy for Review
(request, answer once, observed commands with exit codes, changed files, Git
state, attachment list, provenance labels, secret scan before copy) · step 2
file hand-off (copy / drag / Finder, bound to one answer and one file set) ·
typed attachments, mockup states · Import Saved Result · History with search
and pins · Clipboard (last 5 copies, last 5 images for 24 h) · notch island
with Quick Peek / Details / Full Report · Relay · themes.

## Competitors and neighbours: what they do well

| Product | Relevant strengths | Source |
|---|---|---|
| Vibe Notch | Notch overlay when Claude needs attention; **approve/deny tool permissions from the notch**; live sessions with chat history; Apache-2.0 | [github.com/farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch) |
| Agent Island | Claude Code, Codex, Cursor and others; working / waiting / stalled per session; quota and cost; reads transcripts; Sparkle updates with EdDSA; MIT; macOS + Windows | [agent-island.dev](https://agent-island.dev/) |
| agent-handoff | Moves a whole Codex/Claude Code session to the other agent; checksummed zip with secret-scan report; optional end-to-end encrypted link; Apache-2.0 | [github.com/DavidDingXu/agent-handoff](https://github.com/DavidDingXu/agent-handoff) |
| session-handover | Markdown handover from local transcripts: goal, actions, files, git diff stats, errors, next steps; PreCompact/SessionEnd hooks; stdlib Python; MIT | [github.com/hahahahahahahahah6/session-handover](https://github.com/hahahahahahahahah6/session-handover) |
| showagent | Continue a session in another agent (Claude Code, Codex, Gemini CLI, OpenCode…); preview before writing; secrets redacted; MCP server; MIT | [github.com/aytzey/showagent](https://github.com/aytzey/showagent) |
| Boring Notch / Atoll | Notch shelf for files, smooth expansion, Homebrew cask (boring.notch), macOS 14+; GPL-3.0 | [boring.notch](https://github.com/TheBoredTeam/boring.notch), [Atoll](https://github.com/Atoll-Labs/Atoll) |
| Maccy | Keyboard-first clipboard history, pinning, ignores concealed/transient types; Homebrew; MIT | [github.com/p0deje/Maccy](https://github.com/p0deje/Maccy) |

**Where Prompt Relay is different.** The others either *monitor* agents
(Agent Island, Vibe Notch) or *move whole sessions* between agents
(agent-handoff, showagent, session-handover). None of the pages read builds
a **reviewable result package for a second opinion** with per-fact
provenance (*Confirmed locally* vs *Reported by Claude*), byte-exact answer
copy, observed exit codes and a guarded file hand-off. That is the niche to
keep. Session handover is adjacent; we should not try to resume sessions in
other agents.

## Feature table

| Feature | Existing | Proposed | User Value | Complexity | Dependencies | Priority |
|---|---|---|---|---|---|---|
| LICENSE, README for strangers, CONTRIBUTING, troubleshooting | none (plugin says `UNLICENSED`) | MIT or Apache-2.0 (owner's choice); install, permissions, uninstall, privacy | Required to publish | S | owner decision | **Before release** |
| Signed, notarized build + updates | ad-hoc signed Xcode build | Developer ID + notarization; Sparkle with EdDSA (as Agent Island) or Homebrew cask (as Maccy, boring.notch) | People can install and trust it | M | Apple Developer account | **Before release** |
| First-run setup | `doctor`, manual `claude plugin` | Guided: install plugin via `claude plugin` with consent, choose projects, show what is stored | Fewer broken installs | M | ADR-008 rules | **Before release** |
| Coexistence with other notch apps | yield to Coucou etc. | Test with Vibe Notch, Agent Island, boring.notch; document | No fights over the notch | S | — | **Before release** |
| Package heading | neutral since the visual pass ("# Copy with Context: …") | — | Consistent naming across assistants | done | — | done |
| Smart Handoff Preview | Preview of the real package (same builder, same snapshot copied); secrets still confirmed | Highlight the secret findings' lines inside the preview | Know exactly what leaves the Mac | S–M | none (same formatter) | Post-MVP (high) |
| Export Markdown / Export with Attachments | copy only | Save the package as `.md` + a folder with the chosen files | Archive, attach to issues, mail | S | ReviewPack | Post-MVP |
| Attention notifications | "answer ready" notification | Notify when Claude waits for the user (Notification hook), worded as facts | Fewer idle agents | S | Claude Code `Notification` hook (documented) | Post-MVP |
| Multi-session switcher | project/session picker | Keyboard switcher (⌃⌥⌘P then 1…9) across running sessions | Faster with several agents | S | — | Post-MVP |
| Codex adapter | — | Adapter that maps Codex `hooks.json` events (SessionStart, UserPromptSubmit, Stop; tool events in later versions) to the same JSONL events; labelled *experimental* | Same review flow for Codex users | M | Codex hooks are experimental, schema varies by version (*to verify* against developers.openai.com/codex/hooks) | Experimental |
| Gemini CLI adapter | — | Map `BeforeAgent` / `AfterAgent` (documented) to request/answer | Same for Gemini CLI | M | [geminicli.com/docs/hooks](https://geminicli.com/docs/hooks/) | Experimental |
| Adapter interface | Claude Code only | One `SourceAdapter` per tool: install/uninstall instructions, event mapping into existing Core events, `source=` field, doctor checks; Core storage unchanged | Adds tools without touching the store | M | the two adapters above | Experimental |
| Clipboard: attach to answer, without a session | Attach to Current Answer, works without Claude Code | Keyboard shortcut to open Clipboard → Images; pin an image | Faster screenshot workflow | S | — | Post-MVP |
| Permission approvals from the notch | — | — | Vibe Notch does this; it changes Prompt Relay from observer to controller (security-relevant) | L | security review | **Do not add** (for now) |
| Session transfer to another agent | — | — | agent-handoff and showagent cover it well | L | transcripts (we never read them) | **Do not add** |
| Usage / quota / cost tracking | — | — | Agent Island covers it; needs tokens or transcripts | M | — | **Do not add** |
| Music, calendar, weather, system stats, HUD | — | — | Off-topic for the AI result workflow | — | — | **Do not add** |
| Transcript reading | never (invariant 1) | — | Would break the privacy promise | — | — | **Do not add** |
| AI summaries of answers | never | — | Would break "verbatim"; needs an API | — | — | **Do not add** |

S ≈ a day, M ≈ several days, L ≈ a phase.

## Before a public release (in order)
1. License decision and LICENSE file; README for new users; CONTRIBUTING;
   troubleshooting (hooks not firing, two builds running, notch app conflicts).
2. Relay: drawn in code (no image assets), so no third-party asset rights;
   confirm the bear's design is the owner's to license.
3. Developer ID signing, notarization, an update path (Sparkle or Homebrew).
4. Guided first run (plugin install with consent; nothing written to
   Claude Code settings by Prompt Relay itself, ADR-008).
5. Neutral package heading in the Core (one string, golden tests).
6. Supported macOS: 14+ (current deployment target); test on 14 and the latest.

## After MVP
Smart Handoff Preview · Export Markdown / with attachments · attention
notifications · keyboard session switcher · Clipboard shortcut.

## Experimental
Codex and Gemini CLI adapters behind an "experimental sources" switch, each
with its documented events only, labelled as such in every package
("Source: Codex CLI (experimental adapter)").

## Naming of the review copy (evaluated briefly)
| Name | For | Against |
|---|---|---|
| **Copy for Review** (chosen) | Says the purpose, any assistant | "Review" may read as code review only |
| Copy for AI | Short | Vague; every copy goes to some AI |
| Copy with Context | Accurate | Does not say *why* |
| Copy Report | Simple | Confused with the answer itself |

## Compatibility and security notes (for a later, separate pass)
- Tooltips, previews and the package are drawn inside the island; no extra
  windows. PDF preview uses PDFKit (read-only); HTML is never rendered.
- Text previews read only Prompt Relay's own stored copies (≤ 1 MB, UTF-8).
- The package builder is shared by copy and Preview, so the secret scan and
  provenance rules cannot diverge; a security review should still cover the
  Core's `context` output and the attachment store.
- Other notch apps (Vibe Notch, Agent Island, boring.notch): coexistence
  still to be tested on a real Mac.
