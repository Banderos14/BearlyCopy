# Product UX Specification (Phase 4)

Prompt Relay exists for one loop:

1. You give Claude Code a task. 2. Claude Code works and writes a final
report. 3. Prompt Relay captures that report (hooks, plugin). 4. The notch
shows it. 5. One click copies the original report or a Review Pack. 6. You
paste it yourself into ChatGPT for an independent review, and go back to work.

No AI calls, no server, no account, no automation of ChatGPT. Everything
works offline on captured local data. Pasting is always the user's action.

## 1. One surface

The **island** is the interface. It lives in the MacBook notch; on a display
without a notch the same island floats centered below the menu bar. Every
normal task happens inside it; there are no regular windows. The menu-bar
item is a small fallback menu that opens the island on a view.

One `AppModel`, one selection (`currentRef`: a local turn or an import), one
navigation state (`AppModel.route` with Back).

## 2. States

| State | How | Shows | Size |
|---|---|---|---|
| **Resting** | default | Relay the bear in the left ear; a mint dot in the right ear when an answer is new. With the mascot off and nothing new, nothing outside the camera housing | 237 × 32 (ears) or the notch |
| **Quick Peek** | hover 0.15 s | project, source, task (one line, if linked), the opening of the answer, **Copy Response**, **Review Pack**, ⌄ | 460 wide, height of its content |
| **Expanded** | click, ⌃⌥⌘P, ⌄, menu bar | Home, or a view opened from it | 460 wide, height of its content, ≤ 600 pt and ≤ 72 % of the display; long content scrolls inside with a fade |

Rules: every state is exactly as tall as its content (no empty area, the
window is the island); hover never takes keyboard focus; the expanded island
does, and only Esc on Home, a click on the notch, ⌃⌥⌘P or clicking another
app and leaving closes it; nothing closes it while a menu, the folder picker
or the secrets alert is open; Reduce Motion uses short fades.

## 3. Visual system

- The band level with the camera is pure black (it continues the hardware).
  Content sits on deep graphite cards (`white 0.115`), code on a darker well.
- Text at three readable levels (94 %, 70 %, 52 % white); captions in small
  caps; SF Symbols; native typography; 14 pt card radius, 26 pt island
  radius; 18 pt side insets; nothing within 16 pt of a rounded corner.
- One white primary button (**Copy Response**); secondary actions are
  graphite capsules. One restrained accent, mint, only for meaningful states
  (new answer, capture on, copied); amber for warnings, coral for errors.
- No system-blue selection: rows use a soft white highlight; switches are
  mint/graphite.

## 4. Home: four questions at a glance

1. **Which project?** — first row: the project name with ⌄ (opens Projects)
   and the source on the right: "Claude Code · this Mac" or "Cloud ·
   imported by you", plus "capture off" or "tasks still running" when true.
   The band shows "New answer" (mint) or how long ago.
2. **What did I ask?** — the Task card: two lines of the request, ⌄ to see
   up to 12. Linked by `prompt_id` → shown plainly; linked by order → tagged
   "inferred from order"; an import's task → "entered by you"; otherwise
   "Unavailable: …" with the reason. Never invented.
3. **What did Claude answer?** — the Response card: "N characters", ‹ n/m ›
   for earlier answers of the session, the opening of the answer rendered
   from Markdown (headings, lists, code, links), fading out, and **View full
   report ›**. API errors and missing answers say so instead.
4. **Which button?** — **Copy Response** (white): the complete original
   text. **Review Pack**: the task, the complete answer and what Prompt
   Relay knows, for an independent review. 📎 adds images. After a copy one
   line says exactly what went to the clipboard.

Footer: **Copies**, **History**, **Import** on the left; ⚙ Settings and ⏻
Quit (asks "Quit?" on the first click) in the bottom-right corner.

## 5. UX inventory

Every visible control, what it does, its data and where it belongs.
"Removed" lists what Phase 4 consolidated.

| Control | Where | Does | Data | Missing data | Belongs |
|---|---|---|---|---|---|
| Resting ears / bear | notch | click: open Expanded; hover: Quick Peek | `hasUnseenAnswer`, mascot state | bear hidden when off | resting |
| ⌄ (peek) | Quick Peek | open Expanded on Home | — | — | peek |
| Project name ⌄ | Home row 1 | open Projects | selected project or import's project | "Prompt Relay" | primary |
| Source label | Home row 1 | none (fact) | local turn / import | — | primary |
| Task ⌄ | Task card | show more of the request | `turn.request`, import task | "Unavailable: …" | primary |
| ‹ n/m › | Response card | older / newer answer of the session | turns | hidden with one answer | primary |
| Response preview / View full report | Response card | open Full Report | full text (`show`) or import | blocker text | primary |
| Copy Response | Home, Peek, Full Report | copy the complete text, read back | `show` / import | disabled with the reason | primary |
| Review Pack | Home, Peek, Full Report | copy the pack; secrets → confirm | Core `context` / app pack | disabled | primary |
| 📎 | Home | pick images for this report | NSOpenPanel | disabled without a report | primary |
| Image thumbnail | Home | menu: Copy Image, Show in Finder, Remove; drag | attachment store | "Missing" | primary |
| Copy Text + Images | Home (with images) | text + image items | store | — | primary |
| Copies | Home footer | open Recent Copies | copy history | empty state | secondary |
| History | Home footer | open History | all sessions, imports, pins | "No reports yet" | secondary |
| Import | Home footer | open Import | — | — | secondary |
| ⚙ | Home footer | open Settings (the only route besides the menu bar) | — | orange dot if several builds run | secondary |
| ⏻ | Home footer | first click "Quit?", second quits | — | — | secondary |
| Back | every view | previous view (Esc, ⌘[) | `backRoute` | — | views |
| Project row | Projects | show that project's newest answer | Core projects + added folders | — | Projects |
| Capture switch | Projects | `prompt-relay enable/disable` | Core | disabled, "Via parent" when inherited | Projects |
| Add Project… | Projects | folder picker, capture off | path only | — | Projects |
| Copy Again | Recent Copies | fetch and copy the same thing again | reference → Core / import | "No longer in history" | Copies |
| Search | History | imports in full, captured previews | cached turns | "No reports match" | History |
| Pin / copy icons | History rows | pin to top; copy that complete response | references | disabled for API errors | History |
| Paste Report from Clipboard | Import | reads the clipboard once | NSPasteboard | "The clipboard has no text" | Import |
| Import Report | Import | save verbatim, dedup, show on Home | app store | disabled while empty | Import |
| Formatted / Plain Text | Full Report | rendered or exact text | full text | — | Full Report |
| Settings rows | Settings | see §8 | settings, `doctor` | "Checking…" | Settings |

**Removed or consolidated in Phase 4:** the ⋯ menu (its Settings and
Projects items duplicated ⚙ and the project picker; Quit moved to ⏻), the
"Recent answers" view (it showed the same sessions as History under another
name; replaced by Recent Copies, which records what you copied), "All
Responses" (renamed **History** and given search, pins and imports),
"Full Response" (renamed **Full Report**; it now always shows the complete
text and scrolls), the main window, the old menu-bar panel, the status
window and the Settings window (all moved into the island), the "Debug
build" badge on Home (Debug builds show only a different menu-bar icon and
name), session IDs and character counts on the main line (kept in the
Response card and History).

## 6. Views inside the island

- **Projects** — one card: ✓ for the shown project, "New" tag, "N sessions ·
  last …, N cloud imports", a capture switch per row; Add Project…. Capture
  starts off for new folders; turning it off keeps history.
- **Recent Copies** — the last five copies made in Prompt Relay: kind
  (Response / Review Pack), project, session or import, time, **Copy
  Again**. References only; the text is fetched again; a removed report says
  "No longer in history". A pack that needed "Copy Anyway" is not kept.
- **History** — search on top; Pinned; Cloud imports (right-click: Delete
  Import); then every captured session grouped by project, the open session
  listing its answers. Each row: open, pin, copy the complete response.
- **Import** — explanation; Paste Report from Clipboard (once, on click);
  preview and exact character count; optional task, project and cloud
  session ID; Import Report. The text cannot be edited here.
- **Full Report** — source and size; Formatted (Markdown blocks; code blocks
  scroll sideways) or Plain Text (the exact, selectable text); Copy
  Response and Review Pack. Always the complete text.
- **Settings** — §8.

## 7. Copy, Review Pack and provenance

1. Copy Response copies the complete original text, never a preview,
   excerpt or rendered Markdown, and never summarizes, truncates, reorders
   or normalizes it. The clipboard is read back.
2. Copy never hides, marks or deletes a report.
3. "Stopped" means Claude stopped. Nothing says "done", "success" or "tests
   passed"; Claude's claims stay inside its answer and are labeled
   *Reported by Claude* / *Not verified* in the Review Pack.
4. Review Pack: project; source; session; timestamps; the request only when
   reliably linked (otherwise *Unavailable* or *Supplied by you*); the full
   answer in a longer fence; git branch, HEAD and changes from the Core's
   read-only collector with the collection time (local only; *Unavailable*
   for imports); attachments by name only; tests and CI *Not verified*; a
   request for an independent review. Likely secrets → confirmation first.
5. Imports are always labeled "Cloud · imported by you" and never presented
   as captured or verified.
6. A new answer is selected automatically unless you are looking at another
   project, session, answer or an import; following resumes when the island
   closes.

## 8. Settings (one route: ⚙)

Notch (open on hover; display; make room for other notch apps),
Appearance (Relay the bear; motion), Notifications (project name only),
Capture (→ Projects), Privacy (what is stored where; clear Recent Copies),
Diagnostics (Core and Python, Claude Code plugin, last capture, Check
Again, copyable install commands), About (version, source code link, other
builds running with "Quit …"). Each row has one line explaining it in plain
words; Core and Python appear only under Diagnostics.

## 9. Cloud reports and attachments

Cloud sessions run on Anthropic's servers; the hooks on this Mac cannot see
them and no documented interface returns their messages (details:
MACOS_APP.md §6). The supported path is the explicit **Import**.
`--teleport` is never run (it changes the repository).

Attachments are images the user adds with 📎: copied into Prompt Relay's
private folder with name, type, size, SHA-256 and provenance ("Added by you
from a file on this Mac"). Nothing scans folders or follows paths mentioned
in a report. Missing files are labeled "Missing". Images are never inside
the copied text; "Copy Text + Images" is best effort until a real paste test
in ChatGPT confirms it; Copy Image and drag-and-drop are the dependable
paths.

## 10. Mascot

Relay, an original bear cub in vector (SwiftUI Canvas). Idle with
occasional blinks; eyes follow the pointer within the island only; curious
when an answer is captured, pleased after a copy, concerned after a failure;
no flashing; Reduce Motion stops blinking and eye movement; Settings turns
it off. Details: MACOS_APP.md §7.

## 11. Debug and Release

See MACOS_APP.md §1: one build at a time, a distinct name and icon for the
Debug build, the Release build steps aside at the notch while Debug runs,
and a warning with a user-initiated "Quit …" only when both run.

## 12. Future scope

ChatGPT API or any automatic AI-to-AI exchange; automatic cloud capture
(only if Anthropic documents an interface for it); other agents; system
clipboard monitoring; cloud storage; telemetry; public release and
notarization.
