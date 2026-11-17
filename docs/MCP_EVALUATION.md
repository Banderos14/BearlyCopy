# Hooks, local store, or MCP? (Phase 11 evaluation)

Question from the owner: could the Model Context Protocol simplify passing
context between agents, or even replace BearlyCopy's hooks?

Short answer: **MCP can be a useful read-only *output* of BearlyCopy
later. It cannot replace the hooks as the *input*.** Decision: ADR-022.

## The three mechanisms

| | Lifecycle hooks (today) | BearlyCopy's local store (today) | MCP server (possible) |
|---|---|---|---|
| Who starts it | The agent runtime, on every event (UserPromptSubmit, Stop, PostToolUse…) | The app / CLI, when the user acts | The **model**, when it decides to call a tool |
| Sees the final answer | Yes — `last_assistant_message` on `Stop`, verbatim, every turn | Yes, from the hooks | Only if the model passes it as a tool argument |
| Verbatim guarantee | Yes (bytes from the runtime) | Yes (tests enforce it) | No — the model would re-emit text; it can shorten or rephrase |
| Works without the model's cooperation | Yes | Yes | No |
| Cost per turn | ~40–60 ms local process, no tokens | none | Tool-call tokens and latency inside the agent's turn |
| Direction | agent → BearlyCopy | storage | BearlyCopy → agent (read), or agent → BearlyCopy (write) |
| Trust boundary | Runs as the user; Codex asks for hook trust | User's data dir, 0700 | Any MCP client the user connects can call it |

## Can MCP replace passive capture?

No. Passive capture means "every final answer is recorded, exactly, even
when nobody asks". An MCP server is passive in the other sense: it waits to
be called. To record answers through MCP, every agent would need an
instruction to call `save_result` at the end of every turn; it would cost
tokens, could be skipped or reworded by the model, and would break
invariant 2 (verbatim). Hooks already deliver the exact text for free.

## What MCP would add beyond hooks

1. **Pull instead of paste.** Agent B (e.g. a reviewer in another tool)
   could fetch agent A's latest result or Context Pack directly, instead of
   the user copying and pasting. That is the real benefit.
2. **Structured access.** Tools return the same JSON the app uses (API v1),
   so the receiving agent gets request, answer, provenance labels and the
   attachment list without parsing pasted Markdown.
3. **Cross-tool reach.** Any MCP-capable client (Claude Code, Claude
   Desktop, Codex, IDEs) could read it with one configuration entry.

## Can a read-only MCP server sit on the existing Core?

Yes, with no change to capture. The Core's JSON API v1 (`sessions`,
`turns`, `show`, `context`, `projects`) already provides every read the
tools need. A thin stdio server (`prompt-relay mcp`, standard library only,
JSON-RPC over stdin/stdout) would map:

| Tool | Core call | Returns |
|---|---|---|
| `list_projects` | `projects --json` | allowed projects only: name, path hash or path, last answer time |
| `list_conversations(project)` | `sessions --json --project` | provider, host, title, last event, unread |
| `get_latest_result(project?)` | newest final turn via `sessions` + `show` | request, final answer (verbatim), completion state, provenance |
| `get_context_pack(project, conversation, turn?)` | `context` | the exact Copy with Context text the user could copy |
| `get_attachment_metadata(...)` | app attachment index (read) | names, kinds, sizes, provenance — **no file bytes** |

## Safety rules if it is ever built

- **Off by default**, enabled per project in BearlyCopy; a project not on
  the MCP allowlist is invisible (not "forbidden" — absent).
- **Read-only.** No tool writes, deletes, enables capture, or copies to the
  clipboard.
- **No cross-project reads by default.** A call names a project the user
  allowed; "latest across everything" only when the user turns it on.
- **Same secret checks as Copy with Context** (`sensitive.py`); blocked
  packs return the block reason, not the text.
- **No file contents.** Attachment metadata only; window snapshots never
  (they live in the app's memory, not the Core).
- **Audit line** per call in the handler log style (tool, project, time),
  no payload text.
- Stdio transport only (no network listener), so only clients the user
  configured can start it.

## Recommendation

Do not build it for the first beta: setup and release are the bottleneck,
and MCP adds a new trust surface. Revisit after the beta if users ask for
agent-to-agent pull; the design above needs no change to capture or storage.

## Phase 13 update (2026-11-06) — still a design; ADR-027

Checked against the official specification (modelcontextprotocol.io,
"latest" = revision `2026-07-28`, previous `2025-11-25`):

- **Two handshakes.** `2025-11-25` ("legacy"): `initialize` →
  `protocolVersion` negotiation → `notifications/initialized`. `2026-07-28`
  ("modern"): no `initialize`; each request carries version and capabilities
  in `_meta`; unsupported version → error `-32022`. Which one Claude Code and
  Codex send on this Mac is **not verified**.
- **stdio.** The client launches the server; newline-delimited UTF-8
  JSON-RPC; the server writes nothing but MCP messages to stdout, may log to
  stderr, exits when stdin closes. This fits the Core's "one JSON document on
  stdout" discipline.
- **Tools.** `tools/list` (name, description, `inputSchema` object; no-arg
  tools `{"type":"object","additionalProperties":false}`); `tools/call`
  returns `content` (text) and optionally `structuredContent` matching
  `outputSchema`; tool failures as `isError: true`, protocol failures as
  JSON-RPC errors (`-32602`). Annotations are untrusted hints for clients.
- **Security (spec).** Servers MUST validate inputs, enforce access control,
  rate-limit and sanitize outputs; hosts must get user consent before
  exposing data. Handles are names, not capabilities: check access on every
  call.

What Phase 13 added that MCP would reuse: `context-pack --json` (verbatim
sections, manifest without paths or ids, ≤ 20 results, read-only) — the
body of `get_context_pack`.

Phase 14 plan (needs the owner's consent for the live step):
1. `prompt-relay mcp` stdio server (stdlib), tools `list_projects`,
   `list_conversations`, `get_latest_result`, `get_result`,
   `get_context_pack`, `list_attachment_metadata`; no write tools.
2. Allowlist `mcp.json` in the data dir, separate from capture, empty by
   default; a project not on it is absent; access checked on every call.
3. Audit line per call (tool, project hash, time, outcome), no text.
4. Probe which revision the owner's Claude Code / Codex send, with a
   throw-away config passed on the command line (no settings file edited).
5. Connection instructions only (`claude mcp add …` run by the owner); the
   app never writes another tool's configuration.
