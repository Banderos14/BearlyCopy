# Hook payload fixtures

All payloads are **synthetic** except `real_*.json`, which were captured on
the Mac in Phase 1.5 and redacted (user name → `USER`, sandbox project dir →
`__PROJECT_A__`; the texts are test prompts written for the validation).
`__PROJECT_A__` is replaced with a temporary project directory at test time.

| Files | Source |
|---|---|
| `documented_*.json` | Copied from the examples in the official hooks reference (<https://code.claude.com/docs/en/hooks>, read 2026-10-29). Common fields from the "Common input fields" table were added (`prompt_id`, `scratchpad_dir`, `effort`, `session_title`). |
| `prompt_*.json`, `stop_*.json` | Scenario payloads shaped like the documented ones (minimal, empty, Unicode, Markdown, background task, API error). |
| `corrupt_truncated.json` | Invalid JSON on purpose. |
| `real_desktop_*_1.json` | Claude Desktop 4.29.0 (Claude Code 2.1.309), local Code session, 2026-10-29: one UserPromptSubmit + its Stop. |
| `real_cli_user_prompt_submit_1.json` | Claude Code CLI 2.1.268 (`claude -p --settings`), 2026-10-29. The request then failed authentication, so no Stop exists. |

Add further **redacted** real payloads as `real_*.json`;
`tests/test_units.py::SchemaConformanceTests` picks them up automatically.
