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
| T9 | Malicious repository config runs code during git metadata collection | `core.fsmonitor=false`, `GIT_OPTIONAL_LOCKS=0`, no pager or prompts, timeout, git only at export time; `.git` checked unchanged in tests |
| T10 | Hook installation damages user settings | PoC installs nothing. Planned installer: validate JSON, back up, merge (never replace), idempotency marker, dry-run diff, reversible uninstall, explicit consent (ADR-002) |
| T11 | Capture of unintended projects | Opt-in allowlist; fails closed on a broken config; refuses `/` and `$HOME` |
| T12 | Denial of service through huge stdin | 64 MiB cap; larger payloads are rejected without storing |
| T13 | Concurrent writes corrupt history | `flock` + single-buffer append + `fsync`; partial lines isolated; tested with 12 parallel writers |
| T14 | Hook from a repository runs Prompt Relay unexpectedly | Claude Code's workspace trust applies. Prompt Relay never writes `.claude/settings.json` into user repos |
| T15 | Clipboard exposure to other apps | Inherent to the clipboard. Copying happens only on an explicit user action. *Planned:* optional "clear after N s" and marking the content as transient/concealed for clipboard managers (NSPasteboard, macOS) |

## 3. Residual risks
- History is stored **unencrypted** (protected by the account, permissions
  and FileVault). Encryption at rest with a Keychain key is future work.
- The secret scan is heuristic: it has false negatives and false positives.
- Python 3.9 on macOS comes from the Xcode CLT. With the default
  `hook-config`, the shebang `/usr/bin/env python3` runs whichever `python3`
  comes first on `PATH`. Use `hook-config --python /usr/bin/python3` to pin
  the interpreter; LOCAL_MAC_VALIDATION does this.
- Payload text is stored verbatim by design. If Claude prints a secret, it is
  in history until deleted.

## 4. Permissions
- No macOS privacy permissions (Accessibility, Screen Recording, Full Disk
  Access) are needed. `pbcopy` needs none.
- The future app should need none either. A sandboxed App Store build would
  need a reachable data directory, which is a decision for Phase 3.

## 5. Hook installation safety (rules for any future installer)
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
| Prompts, responses, raw hook payloads | `events/*.jsonl` | until deleted | `prompt-relay delete --session ID --yes` / `--all --yes`, or remove the data dir |
| Enabled project paths | `config.json` | until changed | `prompt-relay disable <dir>` |
| Diagnostics (timestamp, event, outcome) | `handler.log` (256 KiB × 2) | rotating | delete the file |
