"""Observed tool results (ADR-013): PostToolUse and PostToolUseFailure.

The hook reduces each payload to the few fields Prompt Relay may keep before
anything is stored. The raw payload of these two events never reaches disk:
it can hold full file contents (Write/Edit ``originalFile``,
``structuredPatch``), command output and secrets.

Kept: ids, tool name, duration, outcome; for Bash the command (short and
secret-free only), the exit code from a first line ``Exit code N``, a kind
(test / build / git / other), the background flag, and for a failed test or
build run its last lines after a secret scan; for edits the path; for
SendUserFile the shown paths; for Artifact what the tool returned about the
published page (title, URL, version, audience, source path).

An exit code describes one command (with a pipe: its last process). Nothing
here says that a task succeeded.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional

from prompt_relay.sensitive import scan

TOOL_EVENTS = ("PostToolUse", "PostToolUseFailure")
EDIT_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
MAX_COMMAND_BYTES = 1024
TAIL_LINES = 12
TAIL_BYTES = 2048

_EXIT_RE = re.compile(r"^Exit code (-?\d+)\s*$")
_ENV_PREFIX = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+")

# Prefixes of the command that actually runs (after ``cd X &&`` and leading
# VAR=value assignments). Order matters: the first match wins.
KIND_PREFIXES = (
    ("test", ("pytest", "python -m pytest", "python3 -m pytest", "python -m unittest", "python3 -m unittest",
              "swift test", "xcodebuild test", "npm test", "npm run test", "pnpm test", "pnpm run test",
              "yarn test", "go test", "cargo test", "scripts/check.sh", "./scripts/check.sh", "make test")),
    ("build", ("swift build", "xcodebuild", "npm run build", "pnpm build", "pnpm run build", "yarn build",
               "cargo build", "go build", "make", "scripts/build", "./scripts/build")),
    ("git", ("git ",)),
)


def command_kind(command: str) -> str:
    """test / build / git / other, by the prefix of each ``&&``/``;`` part."""
    for part in re.split(r"&&|;|\|\|", command):
        part = _ENV_PREFIX.sub("", part.strip())
        if not part or part.startswith("cd "):
            continue
        for kind, prefixes in KIND_PREFIXES:
            for prefix in prefixes:
                word = prefix.rstrip()
                if part == word or part.startswith(word + " "):
                    return kind
    return "other"


def has_compound(command: str) -> bool:
    """True when the exit code may belong to another process than the test:
    a pipe, ``||``, ``;`` or a trailing ``&``."""
    stripped = re.sub(r"'[^']*'|\"[^\"]*\"", "", command)
    return bool(re.search(r"\||;|&\s*$|&\s+\S", stripped.replace("&&", "")))


def _str(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None


def _tail(text: str) -> Optional[str]:
    lines = text.splitlines()[-TAIL_LINES:]
    tail = "\n".join(lines)
    data = tail.encode("utf-8")
    if len(data) > TAIL_BYTES:
        tail = data[-TAIL_BYTES:].decode("utf-8", "ignore")
    return tail or None


def reduce(payload: Dict[str, Any]) -> Dict[str, Any]:
    """The only form of a tool event that is ever stored."""
    event = payload.get("hook_event_name")
    tool = _str(payload.get("tool_name")) or "unknown"
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    tool_response = payload.get("tool_response")
    out: Dict[str, Any] = {"hook_event_name": event, "tool_name": tool, "reduced": 1}
    for key in ("session_id", "prompt_id", "tool_use_id", "agent_id", "agent_type", "cwd"):
        value = _str(payload.get(key))
        if value:
            out[key] = value
    duration = payload.get("duration_ms")
    if isinstance(duration, (int, float)) and not isinstance(duration, bool) and duration >= 0:
        out["duration_ms"] = int(duration)

    failed = event == "PostToolUseFailure"
    error = _str(payload.get("error")) if failed else None
    if failed:
        out["outcome"] = "interrupted" if payload.get("is_interrupt") is True else "failed"
    elif isinstance(tool_response, dict) and tool_response.get("interrupted") is True:
        out["outcome"] = "interrupted"
    else:
        out["outcome"] = "ok"

    if tool == "Bash":
        command = _str(tool_input.get("command")) or ""
        out["kind"] = command_kind(command)
        if has_compound(command):
            out["compound"] = 1
        if len(command.encode("utf-8")) > MAX_COMMAND_BYTES:
            out["command_withheld"] = "too_long"
        elif scan(command, "command"):
            out["command_withheld"] = "possible_secret"
        else:
            out["command"] = command
        if tool_input.get("run_in_background") is True:
            out["background"] = 1
        if failed and error:
            first, _, rest = error.partition("\n")
            match = _EXIT_RE.match(first.strip())
            if match:
                out["exit_code"] = int(match.group(1))
            if out["kind"] in ("test", "build") and out["outcome"] == "failed":
                tail = _tail(rest if match else error)
                if tail and scan(tail, "output"):
                    out["tail_withheld"] = "possible_secret"
                elif tail:
                    out["output_tail"] = tail
        elif not failed:
            out["exit_code"] = 0
    elif tool in EDIT_TOOLS:
        path = _str(tool_input.get("file_path")) or _str(tool_input.get("notebook_path"))
        if path:
            out["path"] = path
    elif tool == "SendUserFile":
        files = tool_input.get("files")
        if isinstance(files, list):
            out["paths"] = [f for f in files if isinstance(f, str) and f][:50]
    elif tool == "Artifact" and isinstance(tool_response, dict):
        artifact: Dict[str, Any] = {}
        for key in ("title", "url", "audience", "path"):
            value = _str(tool_response.get(key))
            if value:
                artifact[key] = value
        version = tool_response.get("version")
        if isinstance(version, (int, str)) and not isinstance(version, bool):
            artifact["version"] = version
        source = _str(tool_input.get("file_path"))
        if source:
            artifact["source_path"] = source
        if artifact:
            out["artifact"] = artifact
    return out


def summary_line(command: str, limit: int = 120) -> str:
    """One display line of a command (never used for copies)."""
    line = command.strip().splitlines()[0] if command.strip() else ""
    return line if len(line) <= limit else line[: limit - 1] + "…"


def unique_paths(events: List[Any]) -> List[Dict[str, Any]]:
    """Paths of edit events in first-seen order with edit counts."""
    seen: Dict[str, Dict[str, Any]] = {}
    for ev in events:
        for path in (ev.tool or {}).get("paths_changed", []):
            if isinstance(path, str):
                if not path.startswith("/") and ev.cwd:
                    path = ev.cwd.rstrip("/") + "/" + path
                entry = seen.setdefault(path, {"path": path, "tools": [], "count": 0})
                entry["count"] += 1
                if ev.tool_name not in entry["tools"]:
                    entry["tools"].append(ev.tool_name)
        if ev.tool_name in EDIT_TOOLS and ev.tool_path and (ev.tool or {}).get("outcome") == "ok":
            entry = seen.setdefault(ev.tool_path, {"path": ev.tool_path, "tools": [], "count": 0})
            entry["count"] += 1
            if ev.tool_name not in entry["tools"]:
                entry["tools"].append(ev.tool_name)
    return list(seen.values())


def observed_counts(t: Any) -> Dict[str, int]:
    runs = [e.tool for e in t.tools if e.tool and e.tool.get("tool_name") == "Bash" and e.tool.get("kind") in ("test", "build")]
    return {
        "tool_events": len(t.tools),
        "runs_exit_zero": sum(1 for r in runs if r.get("exit_code") == 0),
        "runs_nonzero": sum(1 for r in runs if isinstance(r.get("exit_code"), int) and r.get("exit_code") != 0),
        "runs_unknown": sum(1 for r in runs if not isinstance(r.get("exit_code"), int)),
        # Every shell command that exited non-zero, of any kind (Phase 5.11):
        # a failure outside tests and builds must not read as all clear.
        "commands_nonzero": sum(1 for e in t.tools if e.tool and e.tool.get("tool_name") == "Bash"
                                and isinstance(e.tool.get("exit_code"), int) and e.tool.get("exit_code") != 0),
        "files_changed": len(unique_paths(t.tools)),
        "background_started": sum(1 for e in t.tools if e.tool and e.tool.get("background") == 1),
    }


def observed_detail(t: Any) -> Dict[str, Any]:
    stop = t.last_stop
    stop_epoch = stop.received_at_epoch if stop is not None else None
    commands = []
    shown: List[str] = []
    artifacts = []
    for e in t.tools:
        r = e.tool or {}
        name = r.get("tool_name")
        if name == "Bash":
            commands.append({
                "at": e.received_at,
                "command": r.get("command"),
                "command_withheld": r.get("command_withheld"),
                "kind": r.get("kind"),
                "outcome": r.get("outcome"),
                "exit_code": r.get("exit_code"),
                "duration_ms": r.get("duration_ms"),
                "compound": r.get("compound") == 1,
                "background": r.get("background") == 1,
                "agent_type": r.get("agent_type") if r.get("agent_id") else None,
                "after_stop": bool(stop_epoch and e.received_at_epoch and e.received_at_epoch > stop_epoch),
                "output_tail": r.get("output_tail"),
                "tail_withheld": r.get("tail_withheld"),
            })
        elif name == "SendUserFile":
            shown += [p for p in r.get("paths", []) if p not in shown]
        elif name == "Artifact" and isinstance(r.get("artifact"), dict):
            artifacts.append(dict(r["artifact"], at=e.received_at))
    return {
        "commands": commands,
        "files_changed": unique_paths(t.tools),
        "shown_files": shown,
        "artifacts": artifacts,
        "notifications": len(t.notifications),
    }
