# Security and privacy

## 1. Assets
- Captured prompts and responses: may contain source code, internal plans,
  credentials or personal data.
- The user's Claude Code configuration (`~/.claude/settings.json`, project
  settings) and other installed hooks.
- The user's repositories and the clipboard.

## 2. Threat model
| # | Threat | Mitigation (implemented unless marked) |
|---|---|---|
| T1 | Captured text leaks to the network | No network code at all; enforced by `SourceSafetyTests` and `test_s16` |
| T2 | Captured text ends up in a Git repository | Data dir outside repos by default; `.gitignore` excludes `*.jsonl`; `test_s17` greps the repo for a runtime marker |
| T3 | Other local users read history | Dir 0700, files 0600, enforced on every write |
| T4 | Secrets in text exported to ChatGPT | Copy Context preview plus a secret-pattern scan that blocks without `--allow-sensitive`; findings never echo the value. Copy Response is an explicit verbatim copy and only the user triggers it |
| T5 | Secrets end up in diagnostics | `handler.log` and stderr hold only event names and outcome codes; tested |
| T6 | Hook breaks or steers Claude Code (blocking, injected context, forced continuation) | Exit 0 always; empty stdout; no decisions; bounded time (lock wait ≤3 s, `timeout: 10`); kill switch `PROMPT_RELAY_DISABLE=1` |
| T7 | Command injection from message text | Text is only ever data. No shell (`shell=True` banned), exec-form hook config, no `eval`. Fixtures include `$(rm -rf /)` |
| T8 | Path traversal through `session_id` | Unsafe ids are hashed into the filename; tested with `../`, `/`, dot-files |
| T9 | Repository config runs code during git metadata collection | **Partly mitigated.** `core.fsmonitor=false` (tested: a repo-configured fsmonitor does not run), `maintenance.auto=false` + `gc.auto=0` (tested with trace2: no maintenance/gc child, even when the repo enables auto-maintenance), `GIT_OPTIONAL_LOCKS=0`, no pager or prompts, a timeout, git only at export time, `.git` checked unchanged. **Not mitigated:** `git status` can still run a clean/process *filter* defined in the repo's `.git/config` (verified in the audit). Setting one requires write access to `.git/config`, which already gives code execution on any git command the user or Claude Code runs there. The risk equals running `git status` yourself |
| T10 | Hook installation damages user settings | PoC installs nothing. Planned installer: validate JSON, back up, merge (never replace), idempotency marker, dry-run diff, reversible uninstall, explicit consent (ADR-002) |
| T11 | Capture of unintended projects | Opt-in allowlist; fails closed on a broken config; refuses `/` and `$HOME` |
| T12 | Denial of service through huge stdin | 64 MiB cap; larger payloads are rejected without storing |
| T13 | Concurrent writes corrupt history | `flock` + single-buffer append + `fsync`; partial lines isolated; tested with 12 parallel writers |
| T14 | Hook from a repository runs Prompt Relay unexpectedly | Claude Code's workspace trust applies. Prompt Relay never writes `.claude/settings.json` into user repos |
| T16 | Deletion removes user files outside Prompt Relay, or follows a symlink | Deletion only removes regular, non-symlink files with session-file names directly inside a non-symlink `events/`, re-checked under the file lock (`Store.safe_unlink`); config, logs and foreign files are never touched; tested with symlinked files, a symlinked `events/`, crafted paths and foreign names |
| T17 | Deleting the history of a running session / losing a concurrent event | Sessions active in the last 30 min are kept unless `--force-active`; files changed since planning are kept; a hook waiting on the lock reopens the path after an unlink. Tested with 16 hooks and 3 concurrent deleters |
| T18 | Accidental bulk deletion | Every destructive command previews by default and needs `--yes`; nothing is automatic, even with a retention period set |
| T19 | Symlink planted at a session path redirects hook writes | `O_NOFOLLOW` on open; the hook logs `unsafe_path` and exits 0 |
| T20 | API consumer gets diagnostics mixed into data | `--json` writes one JSON document to stdout and nothing to stderr; warnings and errors are structured; tested on every golden query |
| T21 | Plugin hook breaks or blocks Claude Code (missing Python, stale pin, moved checkout, minimal PATH) | `run-hook` version-checks every candidate including the pin, appends `/usr/bin:/bin` to PATH for its own tools, drains stdin and exits 0 on every failure; the Python entry exits 0 on import errors. Tested |
| T22 | Code injection into the hook through the environment | Handler runs as `python -I -S`: `PYTHONPATH`, `PYTHONSTARTUP`, user site-packages and `sitecustomize` are ignored (tested). The pin file is used only if owned by the user and is version-checked |
| T23 | macOS `/usr/bin/python3` stub opening an install dialog on every prompt | `/usr/bin/python3` is tried only when `xcode-select -p` succeeds |
| T24 | Diagnostics leak secrets from other tools' hook commands or captured text | `doctor` counts foreign hooks per event and never prints their commands; it never prints message text; it never writes files (tested with a NotchBuddy-like command containing a token) |
| T25 | Plugin update or uninstall loses history | History and `python-path` are in the data dir, not in `${CLAUDE_PLUGIN_ROOT}` (changes per version) or `${CLAUDE_PLUGIN_DATA}` (deleted on uninstall). Tested by changing and deleting plugin roots |
| T26 | Double capture from plugin + settings hooks | Fingerprint dedup stores the event once (tested with both running concurrently); `doctor` reports `double_registration` / `events_from_two_sources` |
| T27 | Installing at project scope leaks the plugin to collaborators | Docs instruct user scope; project scope is documented as not wanted |
| T15 | Clipboard exposure to other apps | Inherent to the clipboard. Copying happens only on an explicit user action. *Planned:* optional "clear after N s" and marking the content as transient/concealed for clipboard managers (NSPasteboard, macOS) |

## 3. Residual risks
- History is stored **unencrypted** (protected by the account, permissions
  and FileVault). Encryption at rest with a Keychain key is future work.
- The secret scan is heuristic: it has false negatives and false positives.
- Interpreter: `hook-config` pins the absolute path of the Python that runs
  it (override with `--python`). Hooks therefore never resolve `python3`
  through `PATH`. Nothing assumes `/usr/bin/python3`; without the Xcode CLT
  that path is only an installer stub, and `doctor` reports it. If the pinned
  interpreter or the checkout later disappears or is too old, the entry point
  still exits 0 with a `startup_failed` line on stderr, and capture stops
  silently until `hook-config` is regenerated.
- Copy Context sends absolute local paths (project dir, which contains the
  macOS user name) to ChatGPT when pasted. Visible in the `context` preview.
- Payload text is stored verbatim by design. If Claude prints a secret, it is
  in history until deleted.

## 4. Permissions
- The Core, the hooks and `pbcopy` need no macOS privacy permission.
- The app needs **Screen Recording** only for window snapshots: Capture Final
  Window (Phase 9.4/10) and Auto Final Screenshot (Phase 14, ADR-028). Both are
  off until the user picks a window in macOS's own window picker; without the
  permission everything else works. The app never changes the permission: it
  can open System Settings → Privacy & Security → Screen Recording and re-check
  (Phase 14.1). Snapshots stay in memory, are never uploaded, and reach the
  clipboard, a drag or an export only when the user acts. Debug and Release
  builds have different bundle ids, so macOS keeps a separate grant for each.
- No Accessibility or Full Disk Access is used.
- (Corrected in Phase 15: this section said no permission was needed at all,
  which stopped being true in Phase 9.4.) A sandboxed App Store build would
  need a reachable data directory, which is still undecided.

## 5. Hook installation safety

Phase 2B uses the official plugin mechanism (ADR-008): Claude Code installs
and removes the hooks, and Prompt Relay writes no settings file. The rules
below apply only if a settings-based fallback installer is ever built.
1. Never replace a settings file. Parse it, refuse to act on invalid JSON,
   and merge only our entries.
2. Back up the file with a timestamp before changing it.
3. Make it idempotent: detect existing Prompt Relay entries by the exact
   command path; never add duplicates.
4. Show a dry-run diff and require explicit confirmation for user-level
   (global) settings.
5. Uninstall removes only our entries and leaves the others byte-identical
   where possible.
6. Prefer the plugin mechanism, where Claude Code itself owns install and
   uninstall.

## 6. Data handling summary
| Data | Where | Retention | Deletion |
|---|---|---|---|
| Prompts, responses, raw hook payloads | `events/*.jsonl` | until deleted; optional `retention --days N` used by `prune` (never automatic) | `delete --session ID --yes` / `delete --all --yes` / `prune --yes` (each previews first; active sessions need `--force-active`), or remove the data dir |
| Enabled project paths | `config.json` | until changed | `prompt-relay disable <dir>` |
| Diagnostics (timestamp, event, outcome) | `handler.log` (256 KiB × 2) | rotating | delete the file |
| Result-file snapshots (Phase 9 / 17) | `app/attachments/` + `index.json`, 0600 in a 0700 folder | until removed | "Remove from This Report", or remove the data dir |

### Automatic result files (Phase 17)

When a final answer arrives, Prompt Relay copies eligible files into its own
folder and ticks them for the hand-off. It is a local copy only: nothing is
uploaded, nothing is executed, and a hand-off still happens only when the
user copies or drags.

* **Which files:** ones a tool was seen writing or the agent showed, and
  supported files the answer names that exist in the answer's own project
  (at most six that were not changed in the turn). Types: text documents,
  JSON, HTML, CSV, PDF, images. The project is never walked.
* **Never:** a path outside the answer's project or worktree (each path
  component is opened with `O_NOFOLLOW`, so a symlink cannot lead out);
  hidden files (`.env`, `.npmrc`, …); names that look like credentials
  (`credential`, `secret`, `password`, `token`, `private`, `keychain`,
  `apikey`, `service-account`, `id_rsa`, …); content matching a secret
  pattern — including, since 0.9.0, JSON-form assignments such as
  `"api_key": "…"`; files over the size limits; a file modified after the
  answer arrived. Each skipped file says why on its row; Add remains the
  user's explicit choice.
* **Residual risk:** the secret patterns are heuristics. A secret in an
  unrecognised form inside a file the answer names would be copied into
  Prompt Relay's private folder and ticked. It leaves the Mac only if the
  user hands it over; Copy with Context still scans the text it copies.
  "Attach result files automatically" (off) or "Select attached files for
  handoff" (off) remove the automatic step.

## 7. Release security review (1.0 candidate)

Audit of the repository and its whole history before publication:

- **Secrets**: no tokens, private keys or credentials in the tree or in any
  revision (patterns for AWS, GitHub, OpenAI, Slack, Google keys and PEM
  headers). The only key-shaped strings are fake fixtures in the secret-scan
  tests (`AKIA1234567890ABCDEF`, `AKIAABCDEFGHIJKLMNOP`).
- **Personal data**: no e-mail addresses, phone numbers or captured prompt
  text in the repository. Local acceptance artefacts (screenshots, logs) are
  not part of the published tree (`macos/acceptance/` is ignored).
- **Network**: neither the app (no `URLSession`/sockets) nor the plugin/Core
  (no `socket`, `urllib`, `http`) contains network code. The only outbound
  data path is the clipboard, by user action.
- **Execution**: no `shell=True`, `eval`, `exec` or `os.system` in the Core,
  CLI or scripts; no `sudo` in the install scripts.
- **Dependencies**: the Core is Python standard library only; the app has no
  third-party Swift packages.
- **Hardening**: the app is built with the macOS hardened runtime
  (`codesign --options runtime`); it is not sandboxed because it must read
  the history folder and launch the bundled Python Core. It is signed with a
  development certificate and **not notarized**.
- **Permissions**: Screen Recording is requested only when automatic
  screenshots are turned on; snapshots stay in memory.

### Reporting a vulnerability
Please use GitHub's private vulnerability reporting for this repository
(Security → Report a vulnerability). Do not open a public issue for security
problems. Expect a first reply within a few days.
