# Phase 14 — owner acceptance (live, on this Mac)

Everything below needs a person at the Mac. Prompt Relay has not installed
anything: do step 0 only if you agree.

0. **Install the checked build (with your consent).**
   `scripts/install-local.sh --dry-run`, then `scripts/install-local.sh`
   (backs up 0.4.1; `--rollback` restores it). Quit the Xcode Debug copy
   first so only one island runs. Plugin update is a separate decision.

## Island and layout
1. Open Quick Peek by hover, then Details (14" display, default scaling).
   **Expect:** Copy with Context shows whole rows only, "+N more" when some
   are below; the Answer ends on a whole line; nothing under the footer.
2. Switch Copy with Context ↔ Answer / Attachments / Preview / Context Pack
   several times, then **Quick Peek** (narrower). **Expect:** the island never
   closes by itself; its size changes smoothly.
3. Click a control near the bottom of a tall view that leads to a shorter
   one; keep the mouse still for 10 s. **Expect:** stays open. Move up onto
   the island: stays open. Move sideways out: closes (normal delay).
4. Move out quickly and back in. **Expect:** no flicker, no double open.
5. Start a Drag (attachment or Context Pack) from the hover-opened island
   without clicking it first; drop, then try Esc. **Expect:** first press
   drags, Esc cancels, the island stays as it was.
6. Open the window picker (Capture Window…). **Expect:** the island steps
   aside and returns with its state.

## Automatic final screenshots
7. Settings → Clipboard & Handoff → *Automatic final screenshots* on.
8. Open a Claude Desktop conversation in Prompt Relay → *Link Window for
   Open Conversation…* → pick Claude's window. If macOS asks for screen
   capture consent, allow it.
9. Ask Claude something short; wait for the final answer.
   **Expect:** within ~2 s the answer's Attachments list
   "Auto screenshot Claude Desktop …png · auto screenshot · in memory",
   unchecked. Note whether it shows the last lines (report it either way).
10. Preview it; tick it; Copy with Context and a Context Pack. **Expect:**
    it goes along only when ticked, as an image, not a file.
11. Quit and reopen Prompt Relay. **Expect:** no PNG under
    `~/Library/Application Support/PromptRelay/app/` (`find … -name '*.png'`
    shows none from today), the screenshot is gone, the link must be made again.
12. A second answer in the same conversation. **Expect:** one screenshot on
    the new answer, none added to the old one.
13. Two agents at once (Claude Desktop + Codex/Xcode), each linked.
    **Expect:** each answer gets its own window; never the other one's.
14. Two Claude conversations active in the same project and app.
    **Expect:** "Window association required", no screenshot; *Link Window…*
    from that answer fixes the next one.
15. System Settings → Privacy & Security → Screen & System Audio Recording:
    turn Prompt Relay off; get another answer. **Expect:** "Permission
    required", no crash, text unaffected.
16. A question or plan approval from Claude. **Expect:** no screenshot.
17. Linked window on an external display / minimized / closed.
    **Expect:** captured / "not available" / link dropped — report which.
18. ChatGPT web and desktop, if available: paste Copy with Context and drop
    an auto screenshot. Report what each accepts.

## Cannot be guaranteed by Prompt Relay
- That the screenshot shows the final text (Claude Desktop may still draw).
- Which conversation a single Claude Desktop window shows at that moment.
- Whether the receiving app accepts dropped image data or pasted files.
- Capture of minimized windows (macOS decides; reported as unavailable).
