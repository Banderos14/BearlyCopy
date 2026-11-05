# Multi-agent workspace: identity model (Phase 11 proposal)

Not implemented. This records how Prompt Relay should tell agents apart
when one person uses several accounts of the same provider (Claude
Personal / Claude Work, Codex Personal / Codex Work, other local agents),
so today's data stays compatible.

## Entities

```
Provider ─► Profile ─► Host ─► Project ─► Conversation ─► Result
claude_code  "work"     xcode    logical    native session   final answer of a
codex        "personal" terminal project    id + key         user task (turn)
```

| Entity | What it is | Identifier | Source of truth |
|---|---|---|---|
| Provider | The agent product | `claude_code`, `codex`, … (`adapters.PROVIDERS`) | hook adapter |
| Profile | One configuration home of that provider (≈ account) | `profile_id` = stable hash of the *path* of its config home, plus a user-given label | where the hook was installed (see below) |
| Host | The app running the agent | `xcode`, `terminal`, `claude_desktop`, `vscode`, … | `PROMPT_RELAY_HOST` / `CLAUDE_CODE_ENTRYPOINT` |
| Project | Logical project | `logical_project` path (Phase 9.3) | Core |
| Conversation | One agent session | existing `session_key` (+ `native_session_id`) | Core |
| Result | Final answer of one user task | `(session_key, turn index)` | Core |

## How to know the profile without reading credentials

Never read tokens, `auth.json`, keychain items or account e-mails. A profile
is identified by **where its configuration lives**, which is already known
when the hook is set up:

- Claude Code: `CLAUDE_CONFIG_DIR` (default `~/.claude`). The plugin
  launcher can pass the directory it was installed under; the hook records
  `profile_home_hash = sha256(realpath(config dir))[:12]`.
- Codex: `CODEX_HOME` (default `~/.codex`; Xcode uses
  `~/Library/Developer/Xcode/CodingAssistant/codex`). The hook command
  written by `configure-codex.py` can carry `PROMPT_RELAY_PROFILE=<hash>`.
- The user names profiles in Prompt Relay ("Work", "Personal"); the label
  is local UI state, never sent to the agent.

Two profiles of one provider stay separate because their config homes
differ. Same provider is never a reason to merge (invariant 3 applies to
profiles as it does to sessions). Unknown profile = `default`, labelled as
such, never guessed.

## Storage compatibility

- `source` metadata (Phase 9) gains an optional `profile` field; old
  sessions read as `default`. No migration rewrites history.
- Session keys do not change; a profile is a filter, not part of the key.

## Two navigation modes

**By Project** (today's default): Project → conversations from every
profile and host, each row labelled `Codex · Work · Xcode`. Best for "what
happened in this repo".

**By Agent**: Provider → Profile → Host → projects → conversations. Best for
"what did my work Claude do today". Same data, a different grouping in
Project and Session; Latest stays global unless the user filters.

## Implementation order (future)

1. Core: optional `profile` in `source`, set from an allowlisted env var.
2. Setup: one row per detected config home (existence checks only).
3. App: profile chip in the source line; By Agent grouping.
4. Labels: user-editable names stored in app preferences.
