# Phase 15 — Master owner acceptance checklist (MVP)

One list for a real MacBook. It **adds to** the existing owner checklists and
does not replace or edit them — their own Record sections stay authoritative
for what was already observed:
[ACCEPTANCE_PHASE14](../macos/ACCEPTANCE_PHASE14.md) ·
[ACCEPTANCE_PHASE141_PERMISSION](../macos/ACCEPTANCE_PHASE141_PERMISSION.md) ·
[ACCEPTANCE_PHASE14.2](../macos/ACCEPTANCE_PHASE14.2.md) ·
[ACCEPTANCE_0.6.0](../macos/ACCEPTANCE_0.6.0.md).

Nothing below was tested by Claude with a real mouse, real System Settings
toggles or a real ChatGPT paste. **Every status starts as "Not tested".**
Status values: Pass / Fail / Blocked / Not tested.

## 0. Before you start (needs your consent; Claude did not do this)
- Source: branch `phase/15-mvp-readiness` (0.6.0). Installed today: app 0.4.1,
  plugin 0.4.1. To test 0.6.0 + Phase 15 you either run the **Xcode Debug**
  build from `~/Projects/prompt-relay-phase15/macos/PromptRelay.xcworkspace`
  (scheme "Prompt Relay"), or install with `scripts/install-local.sh` (it
  shows a dry run, backs up 0.4.1, and supports `--rollback`) and update the
  plugin with `claude plugin update` (see ACCEPTANCE_0.6.0 "Before").
- Quit other running copies first (Debug from DerivedData and the installed
  app both run today) so you know which one you are looking at — Settings →
  About shows commit and location.

| # | Check | Preconditions | Steps | Expected | Status | Notes |
|---|---|---|---|---|---|---|
| 1 | Launch | one copy running | open the app | notch island appears; Settings → About shows 0.6.0 and the expected commit | Not tested | |
| 2 | Settings | — | open Settings, visit each section | every row readable, nothing clipped, changes stick after reopening | Not tested | |
| 3 | Project opt-in | a project not yet enabled | ask Claude something there; then enable it in Projects and ask again | first answer **not** captured; second captured | Not tested | |
| 4 | Real final capture | enabled project, plugin 0.6.0 | ask Claude Code a task with a long Markdown answer | Answer shows the full text; Copy Response pastes it byte-for-byte | Not tested | |
| 5 | Session attribution | two Claude conversations in one project | answer in A, then in B | each answer under its own conversation; never mixed | Not tested | |
| 6 | Project attribution | two enabled projects | answer in each | each under its own project | Not tested | |
| 7 | Multiple active sessions | 2–3 running at once | watch the notch while they work | Latest follows newest *final* answer; no status leaks between them | Not tested | |
| 8 | Working ↔ Needs input | a task that triggers a question, plan approval or permission | wait for the prompt, answer it | amber "Needs input" while waiting; back to working after your answer; no screenshot taken for the question | Not tested | |
| 9 | Expand / collapse | — | hover → Quick Peek → Details → move away | opens on hover, closes on a real exit, no flicker | Not tested | |
| 10 | Hover and resize | Details open | click a tab low in a tall view that leads to a shorter one; rest in the vacated strip | island stays open while you are on it or in the short strip; a click in the strip reaches the app below | Not tested | |
| 11 | First-press Drag | island opened by hover | drag an attachment straight away | drag starts on the first press | Not tested | |
| 12 | Long answer | 100 KB+ answer | scroll Answer, View Full Report | no half-visible last line; all text reachable | Not tested | |
| 13 | Copy Response | — | Copy Response; paste in TextEdit | identical text (Cyrillic, emoji, code fences intact); no claim it was delivered anywhere | Not tested | |
| 14 | Copy with Context | answer with commands | Copy with Context; paste in TextEdit | request, full answer, observed commands with exit codes; pipe caveat where relevant; a secret warning appears first if a secret-like string is present | Not tested | |
| 15 | Manual image attachments | — | 📎 → choose an image → Add | appears in Attachments, checked = will be sent; Copy with Images works | Not tested | |
| 16 | Automatic final screenshots | Settings → Automatic final screenshots on; window linked | finish an answer; also try with the window **minimized** and on another Space | one screenshot per final answer; record whether a minimized window keeps its link (risk R1 in the audit) | Not tested | |
| 17 | Screen Recording denied | permission off for this build | link a window, finish an answer | "Auto screenshot needs permission" with Open Settings / Check Again; no repeated system prompts | Not tested | |
| 18 | Correct privacy pane | as 17 | Open Screen Recording Settings | System Settings opens at Privacy & Security → Screen (& System Audio) Recording | Not tested | |
| 19 | Check Again | as 17 | toggle on, Check Again | clears, or says Restart required — never "granted" while capture still fails | Not tested | |
| 20 | Restart required | as 19 if shown | Quit Prompt Relay, reopen | permission works; history intact | Not tested | |
| 21 | Debug vs Release permissions | grant Debug only | try Release | Release still asks; the two never confused | Not tested | |
| 22 | Re-link after restart | linked window | quit and reopen | link is gone (by design, ADR-028); app asks to link again; no fake link shown | Not tested | |
| 23 | Manual review progress | answer with a checklist | tick two items, untick one | "N checks left" updates at once; Evidence's own "not verified" count does not change | Not tested | |
| 24 | Review persistence | as 23 | close island, switch project, quit/reopen | ticks and Not applicable still there for that answer only | Not tested | |
| 25 | CI Not applicable | CI item visible | ⋯ → Not applicable | counted as resolved; never shown as "CI passed" | Not tested | |
| 26 | Command / test / build distinctions | answers containing: a failed grep, a real failed build, `swift build 2>&1 \| grep error` on a clean build, `swift build && swift test` failing in the test step | read the chip, the Commands row, Quick Peek and Failure Inspector | "1 likely not an error" (no red alarm, no "run the build" checklist item), "1 build failed", "1 build unclear", "1 build unclear" — and Failure Inspector never says "the build did not succeed" for the unclear ones (**Phase 15/15.1 wording**) | Not tested | |
| 27 | Failure Inspector | an answer with a failure and a later passing rerun | open Failure Inspector | the failure stays listed; the rerun line says exit 0 is "not proof that the cause is fixed" | Not tested | |
| 28 | Unknown / unverified claims | an answer saying "all done" with no tests/builds | Evidence & Review | "Task outcome unknown…" listed under Not verified | Not tested | |
| 29 | Manual paste into ChatGPT | ChatGPT (web or app) open | paste Copy Response, then Copy with Context | text arrives complete; Prompt Relay never says it was delivered | Not tested | |
| 30 | Text + image handoff | an image chosen | Copy with Images / drag; paste/drop into ChatGPT | text and image both arrive (depends on ChatGPT) | Not tested | |
| 31 | History after restart | some answers | quit, reopen | all answers, imports, attachments (not auto screenshots — memory only) still there | Not tested | |
| 32 | Plugin or Core unavailable | temporarily disable the plugin in Claude Code, or rename the app's Python | open the app; run a Claude task | app says it cannot read history / capture inactive; Claude Code itself unaffected | Not tested | |
| 33 | File picker selection | an answer open | 📎 / Files…; note any highlighted file; press Cancel; reopen and Add a different file | a highlighted file is macOS remembering your last choice; Cancel attaches nothing; Add attaches only what you chose, to the answer that was open; checked box = "send" | Not tested | |
| 34 | Piped test that "passes" | ask Claude to run `swift test 2>&1 \| tee test.log` (or `pytest \| tail -20`) | read Evidence & Review, Quick Peek and the Commands row | no "test command exited 0" fact; "…exited 0 through a pipe…: the test result is unknown"; "1 unclear" / "1 result unclear"; with `set -o pipefail;` in front, an exit 0 is counted as passed (Phase 15.1) | Not tested | |

## Record
Date, build (commit from About), Mac model/display, and per failing row: what
you saw and a screenshot if you want. Do not paste captured private text here.
