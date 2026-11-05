"""Read-only diagnostics of how Prompt Relay is connected to Claude Code.

Three kinds of evidence, never mixed (docs/PLUGIN.md §6):
- configuration: what settings files and plugin records *say* (may be stale);
- observed: what the handler actually logged (``handler.log``, metadata only);
- unverified: what files cannot tell, such as whether a running Claude
  Desktop session loaded the plugin.

Nothing here writes, runs Claude Code, or prints other tools' hook commands
(they can contain tokens); foreign hooks are only counted per event.
"""

from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

from prompt_relay import config as _config
from prompt_relay import runtime
from prompt_relay.paths import data_dir

PLUGIN_NAME = "prompt-relay"
MAX_JSON_BYTES = 5 * 1024 * 1024
LOG_TAIL_LINES = 5000
# Markers that identify a Prompt Relay hook handler in a settings file.
OUR_MARKERS = ("prompt-relay", "prompt_relay")


def claude_dir(env: Mapping[str, str]) -> Path:
    if env.get("CLAUDE_CONFIG_DIR"):
        return Path(env["CLAUDE_CONFIG_DIR"]).expanduser()
    return Path(env.get("HOME") or Path.home()) / ".claude"


def plugins_root(env: Mapping[str, str]) -> Path:
    if env.get("CLAUDE_CODE_PLUGIN_CACHE_DIR"):
        return Path(env["CLAUDE_CODE_PLUGIN_CACHE_DIR"]).expanduser()
    return claude_dir(env) / "plugins"


def read_json(path: Path) -> Tuple[Optional[Any], str]:
    """(data, state) with state "ok", "missing", "too_large", "unreadable" or "invalid_json"."""
    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            return None, "too_large"
        raw = path.read_bytes()
    except FileNotFoundError:
        return None, "missing"
    except OSError:
        return None, "unreadable"
    try:
        return json.loads(raw.decode("utf-8")), "ok"
    except (UnicodeDecodeError, ValueError):
        return None, "invalid_json"


def is_ours(handler: Any) -> bool:
    if not isinstance(handler, dict):
        return False
    parts = [handler.get("command")] + list(handler.get("args") or [])
    text = " ".join(p for p in parts if isinstance(p, str))
    return any(marker in text for marker in OUR_MARKERS)


def scan_settings(path: Path, scope: str) -> Dict[str, Any]:
    data, state = read_json(path)
    result: Dict[str, Any] = {"file": str(path), "scope": scope, "state": state,
                              "prompt_relay_hooks": [], "foreign_hooks": {}, "enabled_plugins": {}}
    if state != "ok" or not isinstance(data, dict):
        if state == "ok":
            result["state"] = "not_an_object"
        return result
    hooks = data.get("hooks")
    foreign: Counter = Counter()
    if isinstance(hooks, dict):
        for event, groups in hooks.items():
            for group in groups if isinstance(groups, list) else []:
                handlers = group.get("hooks") if isinstance(group, dict) else None
                for handler in handlers if isinstance(handlers, list) else []:
                    if is_ours(handler):
                        result["prompt_relay_hooks"].append({"event": str(event)})
                    else:
                        foreign[str(event)] += 1
    result["foreign_hooks"] = dict(sorted(foreign.items()))
    enabled = data.get("enabledPlugins")
    if isinstance(enabled, dict):
        result["enabled_plugins"] = {k: v for k, v in sorted(enabled.items())
                                     if isinstance(k, str) and k.split("@")[0] == PLUGIN_NAME}
    return result


def installed_records(env: Mapping[str, str]) -> Dict[str, Any]:
    """Best-effort read of installed_plugins.json (its format is not documented)."""
    path = plugins_root(env) / "installed_plugins.json"
    data, state = read_json(path)
    records: List[Dict[str, Any]] = []
    if state == "ok":
        plugins = data.get("plugins") if isinstance(data, dict) else None
        if isinstance(plugins, dict):
            for plugin_id, entries in plugins.items():
                if not isinstance(plugin_id, str) or plugin_id.split("@")[0] != PLUGIN_NAME:
                    continue
                for entry in entries if isinstance(entries, list) else [entries]:
                    if not isinstance(entry, dict):
                        continue
                    install_path = entry.get("installPath") if isinstance(entry.get("installPath"), str) else None
                    records.append({
                        "id": plugin_id,
                        "scope": entry.get("scope") if isinstance(entry.get("scope"), str) else None,
                        "version": entry.get("version") if isinstance(entry.get("version"), str) else None,
                        "install_path": install_path,
                        "manifest_found": bool(install_path) and
                        os.path.isfile(os.path.join(install_path, ".claude-plugin", "plugin.json")),
                        "launcher_found": bool(install_path) and
                        os.path.isfile(os.path.join(install_path, "hooks", "run-hook")),
                    })
        else:
            state = "unrecognized_format"
    return {"file": str(path), "state": state, "records": records}


def observed(root: Path) -> Dict[str, Any]:
    path = Path(root) / "handler.log"
    lines: List[str] = []
    try:
        with open(path, "r", encoding="ascii", errors="replace") as fh:
            lines = fh.read().splitlines()[-LOG_TAIL_LINES:]
    except FileNotFoundError:
        pass
    except OSError:
        return {"log_file": str(path), "state": "unreadable", "lines_scanned": 0, "by_via": {}, "outcomes": {}}
    by_via: Dict[str, Dict[str, Any]] = {}
    by_source: Dict[str, Dict[str, Any]] = {}
    outcomes: Counter = Counter()
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        via = parts[2][4:] if len(parts) >= 4 and parts[2].startswith("via=") else "unknown"
        outcome = parts[-1]
        outcomes[outcome.split(":")[0]] += 1
        slot = by_via.setdefault(via, {"events": 0, "last_at": None})
        slot["events"] += 1
        slot["last_at"] = parts[0]
        # Only launcher-controlled, allowlisted labels establish attribution.
        # Historical lines without these fields never prove Codex execution.
        if "provider=codex" in parts and "host=xcode" in parts:
            source = by_source.setdefault("codex:xcode", {"events": 0})
            source.update(events=source["events"] + 1, last_at=parts[0],
                          last_event=parts[1], last_outcome=outcome.split(":")[0])
            if outcome in ("stored", "duplicate"):
                source["last_stored_at"] = parts[0]
            elif outcome not in ("ignored_event", "project_not_enabled", "disabled"):
                source["last_error_at"] = parts[0]
                source["last_error"] = outcome.split(":")[0]
    return {"log_file": str(path), "state": "ok" if lines else "empty", "lines_scanned": len(lines),
            "by_via": dict(sorted(by_via.items())), "outcomes": dict(sorted(outcomes.items())),
            "by_source": by_source}


def diagnose(env: Mapping[str, str], project: Optional[str], python_version: Tuple[int, int, int],
             python_executable: str) -> Dict[str, Any]:
    root = data_dir(env)
    cfg = _config.load(root)
    pin, pin_state = runtime.read_pin(root)
    settings = [scan_settings(claude_dir(env) / "settings.json", "user")]
    if project:
        settings.append(scan_settings(Path(project) / ".claude" / "settings.json", "project"))
        settings.append(scan_settings(Path(project) / ".claude" / "settings.local.json", "local"))
    plugin = installed_records(env)
    seen = observed(root)
    events_dir = root / "events"
    storage = {
        "data_dir": str(root),
        "exists": root.is_dir(),
        "writable": os.access(str(root), os.W_OK | os.X_OK) if root.is_dir()
        else os.access(str(_existing_parent(root)), os.W_OK | os.X_OK),
        "session_files": len([n for n in os.listdir(str(events_dir)) if n.endswith(".jsonl")])
        if events_dir.is_dir() and not events_dir.is_symlink() else 0,
    }
    capture = {
        "config_error": cfg.error,
        "enabled_projects": list(cfg.enabled_projects),
        "project": None if not project else {"path": project, "capture_enabled": _config.is_enabled(cfg, project)},
    }
    enabled_flags = [v for s in settings for v in s["enabled_plugins"].values()]
    plugin_configured = bool(plugin["records"]) or any(v is True for v in enabled_flags)
    settings_hooks = [s for s in settings if s["prompt_relay_hooks"]]
    findings: List[Dict[str, str]] = []

    def add(level: str, code: str, message: str) -> None:
        findings.append({"level": level, "code": code, "message": message})

    if python_version[:2] < runtime.MIN_VERSION:
        add("error", "python_unsupported", f"this Python is {python_version[0]}.{python_version[1]}; 3.9+ is required")
    if pin_state == runtime.NOT_SET:
        add("warning", "python_not_pinned", "no pinned interpreter; the plugin launcher will search well-known locations "
            "(run 'prompt-relay pin-python' or 'enable' to pin this one)")
    elif pin_state != runtime.OK:
        add("error", "pinned_python_unusable", f"pinned interpreter is {pin_state}; run 'prompt-relay pin-python'")
    if not storage["writable"]:
        add("error", "storage_not_writable", "the data directory is not writable; hooks cannot store events")
    if cfg.error:
        add("error", "config_unusable", f"config.json is unusable ({cfg.error}); capture is off everywhere")
    elif not cfg.enabled_projects:
        add("warning", "no_projects_enabled", "capture is off: no project is enabled ('prompt-relay enable <dir>')")
    if capture["project"] and not capture["project"]["capture_enabled"]:
        add("warning", "project_not_enabled", "capture is off for this project")
    if plugin_configured and settings_hooks:
        add("warning", "double_registration",
            "Prompt Relay is configured both as a plugin and as settings hooks ("
            + ", ".join(s["scope"] for s in settings_hooks) + "). Events are deduplicated, but remove the settings "
            "hooks to avoid running the handler twice")
    if len(settings_hooks) > 1:
        add("warning", "settings_registered_twice", "settings hooks for Prompt Relay exist in more than one settings file")
    if not plugin_configured and not settings_hooks:
        add("warning", "not_registered", "no plugin install record and no settings hooks found for Prompt Relay")
    for rec in plugin["records"]:
        if not rec["manifest_found"] or not rec["launcher_found"]:
            add("error", "plugin_install_incomplete", f"install record {rec['id']} points to a directory without the plugin files")
    for s in settings:
        if s["state"] not in ("ok", "missing"):
            add("warning", "settings_unreadable", f"{s['scope']} settings file is {s['state']}; it was not changed")
    via = seen["by_via"]
    if "plugin" in via and "direct" in via:
        add("warning", "events_from_two_sources", "handler.log shows events from both the plugin and another registration")
    failures = {k: v for k, v in seen["outcomes"].items()
                if k not in ("stored", "duplicate", "ignored_event", "project_not_enabled", "disabled")}
    if failures:
        add("warning", "handler_errors_logged", "handler.log records failures: " + ", ".join(f"{k}×{v}" for k, v in failures.items()))
    return {
        "core": {
            "python": {"executable": python_executable, "version": "%d.%d.%d" % python_version,
                       "supported": python_version[:2] >= runtime.MIN_VERSION},
            "pinned_python": {"path": pin, "state": pin_state},
        },
        "storage": storage,
        "capture": capture,
        "configuration": {"plugin": plugin, "settings": settings},
        "observed": seen,
        "findings": findings,
        "unverified": [
            "Whether a running Claude Code or Claude Desktop session has loaded the plugin: check 'claude plugin list' "
            "or the Desktop plugin panel, then look for events with via=plugin under 'observed'.",
            "installed_plugins.json has no documented format; its reading here is best-effort.",
        ],
    }


def _existing_parent(path: Path) -> Path:
    path = Path(path)
    while not path.exists() and path.parent != path:
        path = path.parent
    return path
