# Phase 14.1 — Screen Recording permission recovery (owner, live)

Short checklist for the one new fix: a recovery flow for "Auto screenshot
needs permission", from the Attachments card itself. Background: `PHASE14.md`
§6, `docs/DECISIONS.md` ADR-028 update.

## Setup
Two copies running at once, as usual on this Mac: the Xcode Debug build and
the installed Release app. Do **not** quit either for this check — the point
is to see them tracked separately.

1. In System Settings → Privacy & Security → Screen Recording, make sure
   **neither** "Prompt Relay" nor "Prompt Relay" (Debug) is currently on.
2. In the Debug build, link a window (Settings → Automatic final screenshots
   → Link Window for Open Conversation…) and get a real final answer, or use
   *Capture Now…*. **Expect:** Attachments shows "Permission required" with
   two buttons, **Open Screen Recording Settings** and **Check Again** — no
   long paragraph, just the short status line above them.
3. Click **Open Screen Recording Settings**. **Expect:** System Settings
   opens directly at Privacy & Security → Screen Recording (not just the app,
   not a different pane). Report which pane actually opened and on what
   macOS version.
4. Without touching the toggle yet, click **Check Again**. **Expect:** status
   stays "Permission required" — opening Settings alone must never read as
   granted.
5. Turn the toggle on for **Prompt Relay (Debug)** only (leave the Release
   one off, or confirm it isn't listed yet).
6. Click **Check Again** in the Debug build. **Expect:** either it clears
   (capture already works), or it now says **"Restart required"** with
   **Quit Prompt Relay** + **Check Again** — report which, since this is the
   one macOS version detail that couldn't be verified without your hands.
7. If "Restart required" appeared: quit the Debug build from Xcode (Stop),
   relaunch it, open the same conversation. **Expect:** your history and
   settings are still there (they live in the Core's data on disk, not in
   the app's memory) — but the **window link itself is not**: links are
   memory only and never survive a restart of Prompt Relay (ADR-028), so
   Automatic final screenshots shows "Window not linked" until you use
   *Link Window for Open Conversation…* again. Confirm that re-linking and
   then getting a real final answer takes a normal automatic screenshot.
8. In the **Release** app (still never granted), repeat step 2 (link a
   window, get a final answer). **Expect:** still "Permission required" —
   granting Debug must never be read as granting Release.
9. Grant Release too, repeat Check Again / restart there as needed.
   **Expect:** both copies now auto-capture independently.
10. Deny access again for one copy (toggle off in System Settings) and get
    another final answer there. **Expect:** "Permission required" again, no
    crash, no repeated system prompt — only this card's own two buttons.

## Record
| Step | Result |
|---|---|
| Pane that actually opened (3) | |
| "Restart required" appeared, or cleared immediately (6) | |
| History/settings intact after quit & reopen (7) | |
| Release stayed blocked while only Debug was granted (8) | |
