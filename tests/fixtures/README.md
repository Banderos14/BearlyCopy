# Hook payload fixtures

All payloads are **synthetic**. None was captured from a real Claude Code run.
`__PROJECT_A__` is replaced with a temporary project directory at test time.

| Files | Source |
|---|---|
| `documented_*.json` | Copied from the examples in the official hooks reference (<https://code.claude.com/docs/en/hooks>, read 2026-10-29). Common fields from the "Common input fields" table were added (`prompt_id`, `scratchpad_dir`, `effort`, `session_title`). |
| `prompt_*.json`, `stop_*.json` | Scenario payloads shaped like the documented ones (minimal, empty, Unicode, Markdown, background task, API error). |
| `corrupt_truncated.json` | Invalid JSON on purpose. |

After the macOS validation (docs/LOCAL_MAC_VALIDATION.md), add **redacted**
real payloads as `real_*.json`. `tests/test_units.py::SchemaConformanceTests`
then picks them up automatically.
