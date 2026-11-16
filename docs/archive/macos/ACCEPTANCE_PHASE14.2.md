# Phase 14.2 — owner acceptance (live, on this Mac)

Compact checklist for this phase's own three fixes. Background: `PHASE14.2.md`.
For Auto Final Screenshot / Screen Recording permission, see
`ACCEPTANCE_PHASE141_PERMISSION.md` (unchanged this phase).

## Verification progress vs. evidence
1. Open any answer with observed commands; open Evidence & Review.
   **Expect:** "Review Checklist" shows a count next to its title ("N checks
   left" / "All checks completed"); each item says **Pending** or
   **Checked by you** under its text, not just an empty/filled box.
2. Tick two of the checklist boxes. **Expect:** the count updates
   immediately, no reopening Quick Peek or restarting; the Answer card's
   Evidence chip's last segment ("N checks left") also updates immediately.
3. Look at the chip's first segments (observed count, any failures).
   **Expect:** unchanged by the ticks — only the checks-left segment moves.
4. If the project has no CI: open the CI item's menu (⋯ instead of a
   checkbox) and choose **Not applicable**. **Expect:** it shows "Not
   applicable", counts toward "checks left" going down, but is never shown
   as a passed CI check.
5. Quit and reopen Prompt Relay, reopen the same answer. **Expect:** your
   ticks (and any Not applicable) are exactly as you left them.

## Command / test / build / unknown
6. Find (or cause) an answer where a plain shell/diagnostic command failed
   but the actual build and tests passed. **Expect:** Copy with Context's
   Commands row and the Evidence chip say "N command(s) failed" — never
   "test failed" or "build failed".
7. Find (or cause) an answer with a real failed build or test.
   **Expect:** the row/chip explicitly says "N build(s) failed" or
   "N test(s) failed", and Observed Work's Failure Inspector shows the
   command, exit code, time, and (if the line had a pipe/`;`/`&&`) the
   caveat that the exit code may not describe the whole line.
8. If a later run of the same command/tool passed: **Expect:** a line
   saying it ran again and exited 0, with "not proof the cause is fixed" —
   never "Recovered" or similar.

## Copy with Context in a compact island
9. On a 14" MacBook (or resize the island to a similar height), open
   Details for an answer with several observed facts (commands, files
   changed, attachments). **Expect:** Copy with Context shows **two**
   complete rows (never half of one), with "+N more" if there are more.
10. Make the island taller/shorter a few times. **Expect:** no row is ever
    half-visible; the Answer card never shrinks to the point of being
    unreadable; the island's overall height behaves as before (hover-resize
    protection from Phase 14.1 still holds — the island does not close
    itself while you move toward a smaller card).
11. Click the "Commands" row (or any row) whole across its width.
    **Expect:** it opens like before (Commands → Failure Inspector).

## Record
| Check | Result |
|---|---|
| Checklist progress updates live (1–3) | |
| Not applicable behaves correctly (4) | |
| Ticks survive quit/reopen (5) | |
| Command-only failure never shown as test/build failure (6) | |
| Real test/build failure named correctly (7) | |
| Two rows visible in Copy with Context on your MacBook (9) | |
| No half-visible rows anywhere (10) | |
