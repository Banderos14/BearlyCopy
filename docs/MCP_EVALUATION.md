# Hooks, local store, or MCP? (Phase 11 evaluation)

Question from the owner: could the Model Context Protocol simplify passing
context between agents, or even replace Prompt Relay's hooks?

Short answer: **MCP can be a useful read-only *output* of Prompt Relay
later. It cannot replace the hooks as the *input*.** Decision: ADR-022.

## The three mechanisms

| | Lifecycle hooks (today) | Prompt Relay's local store (today) | MCP server (possible) |
|---|---|---|---|
| Who starts it | The agent runtime, on every event (UserPromptSubmit, Stop, PostToolUse…) | The app / CLI, when the user acts | The **model**, when it decides to call a tool |
| Sees the final answer | Yes — `last_assistant_message` on `Stop`, verbatim, every turn | Yes, from the hooks | Only if the model passes it as a tool argument |
| Verbatim guarantee | Yes (bytes from the runtime) | Yes (tests enforce it) | No — the model would re-emit text; it can shorten or rephrase |
| Works without the model's cooperation | Yes | Yes | No |
| Cost per turn | ~40–60 ms local process, no tokens | none | Tool-call tokens and latency inside the agent's turn |
| Direction | agent → Prompt Relay | storage | Prompt Relay → agent (read), or agent → Prompt Relay (write) |
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

- **Off by default**, enabled per project in Prompt Relay; a project not on
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
