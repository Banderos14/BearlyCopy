# Prompt Relay — project summary

**What it is.** A local-first macOS utility that captures the final answer
of AI coding agents (Claude Code, Codex) through their official lifecycle
hooks and hands it — verbatim, with its request, provenance and result
files — to another AI or a human reviewer in one click. It lives at the
MacBook notch as a Dynamic-Island-style panel.

**Problem.** Developers who plan or review in one AI and implement with
another copy long answers by hand: Markdown breaks, sessions get mixed, and
"all tests pass" becomes an unverified fact. Prompt Relay copies the exact
text and labels what is *Reported by Claude* versus *Confirmed locally*.

**Stack.**
- Core: Python 3.9+ standard library only — hook handler, JSONL store with
  file locks, turn correlation, versioned JSON CLI API (v1, JSON Schema).
- App: Swift 5.10 / SwiftUI + AppKit, Swift Package Manager and Xcode;
  custom `NSPanel` island around the notch, Core Animation character,
  FSEvents live updates, ScreenCaptureKit window picker, NSPasteboard
  with read-back verification.
- Integration: Claude Code plugin (hooks), Codex hook profiles per host.
- Tooling: shell build/install/release scripts, GitHub Actions (Linux
  Python matrix, opt-in macOS).

**Architecture decisions worth discussing** (`docs/DECISIONS.md`, 22 ADRs):
- Capture through hooks, not by scraping UIs or calling AI APIs; the hook
  never writes stdout, always exits 0, does no network I/O (ADR-001…008).
- A provider-neutral event shape behind small adapters, so Codex was added
  without touching the turn logic.
- Plugin-first integration: the app never edits Claude Code settings.
- Window snapshots held only in memory, bounded by count, bytes and age
  (ADR-018).
- First-run setup that reports *delivery*, not configuration — "Connected"
  only after a stored event (ADR-021).
- MCP evaluated and deliberately deferred: it cannot replace passive,
  verbatim capture (ADR-022).

**Measured technical results** (from this repository's own checks; no user
numbers exist):
- Hook latency on an M-series Mac: median ≈ 39 ms, p95 ≈ 47 ms direct;
  ≈ 57 / 62 ms through the plugin launcher (50 synthetic Stops,
  `scripts/check.sh`, Phase 10).
- Idle cost of the installed app: 0.0–0.7 % CPU, ≈ 46 MB footprint
  (Phase 10, `top`).
- Tests: ≈ 215 Python tests (Python 3.9 and 3.14) and ≈ 340 Swift tests
  (XCTest + Swift Testing), including verbatim round-trips (Unicode, NUL,
  >100 KB), 12-process concurrent writers, crash-truncated line recovery,
  "no network constructs" and "captured text never in the repo" guards.
- App size ≈ 10 MB with the bundled Core (no bundled Python, ADR-019).

**Security stance.** Local-first and offline by construction: no network code in
the app or the Core, no third-party dependencies, hook handler that cannot fail
the agent (always exit 0, never stdout), strict file permissions, secret scan
before anything is copied, hardened-runtime build. Audited before release
(see `docs/SECURITY.md` §7).

**Try it in 60 seconds.**
1. Install the app and connect Claude Code (README → Install).
2. Send any prompt in Claude Code. A bear appears at the notch.
3. Hover the notch: Quick Peek shows the latest answer. Click **Details**.
4. **Copy with Context** and paste into another chat: request, answer and
   what was actually observed on the Mac, with *Reported* / *Confirmed*
   labels.
5. Settings → Daily Use shows whether everything is connected.

**Status.** 0.9 pre-release. Source-available (view-only license); the app is
signed with a development certificate and not notarized, so macOS asks you to
confirm the first launch.
