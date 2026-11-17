# Multi-agent workspace: identity model

**Implemented in Phase 12** (`plugin/prompt_relay/profiles.py`, ADR-023,
`macos/PHASE12.md`). Proposed in Phase 11; the sections below describe
what was built. Differences from the proposal: the profile id is
`cc-default` / `cx-default` for the default folder (no hash), the profile
lives in the record envelope (the payload stays verbatim), and a
non-default Claude Code folder scopes the session key so equal native ids
never share a history.

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
  the profile id (`cc-default`, or `cc-` + 16 hex of SHA-256 over the folder's real path).
- Codex: `CODEX_HOME` (default `~/.codex`; Xcode uses
  `~/Library/Developer/Xcode/CodingAssistant/codex`). The hook command
  runs inside Codex's environment, so `CODEX_HOME` is read directly (`cx-…`); no extra variable is needed.
- The user names profiles in BearlyCopy ("Work", "Personal"); the label
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

## As built (Phase 12)

1. Core: `agent_profile` in the record envelope from `CLAUDE_CONFIG_DIR` /
   `CODEX_HOME` (relative or empty values = default). Older Codex records
   map through `installation_id`; older Claude Code records have none
   (Unassigned).
2. App: By Project / By Agent in Project and Session (two columns:
   provider · profile → conversations under project headers); the profile
   appears in rows only when more than one profile of a provider exists.
3. Labels: Settings → Agents & Projects → Agent profiles; local only;
   removing a name keeps all history.
4. Not built: Setup rows per detected config folder (Setup still checks
   the default locations only), explicit re-assignment of Unassigned
   conversations to a profile.
