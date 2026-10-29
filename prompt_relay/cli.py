"""prompt-relay command-line interface.

Exit codes: 0 ok · 1 error · 2 usage · 3 nothing to export ·
4 clipboard failure · 5 export blocked by sensitive-content check.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import platform
import sys
from pathlib import Path
from typing import List, Optional

from prompt_relay import __version__
from prompt_relay import config as _config
from prompt_relay import export, gitinfo, history
from prompt_relay.clipboard import ClipboardError, get_backend
from prompt_relay.paths import data_dir
from prompt_relay.store import Store, StoreError

EXIT_ERROR, EXIT_USAGE, EXIT_NOTHING, EXIT_CLIPBOARD, EXIT_SENSITIVE = 1, 2, 3, 4, 5
HOOK_EVENTS = ("UserPromptSubmit", "Stop", "StopFailure")


def _err(msg: str) -> None:
    sys.stderr.write(f"prompt-relay: {msg}\n")


def _now() -> str:
    return _dt.datetime.now(tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _preview(text: Optional[str], width: int = 60) -> str:
    if text is None:
        return "—"
    flat = " ".join(text.split())
    return flat if len(flat) <= width else flat[: width - 1] + "…"


def _store() -> Store:
    return Store(data_dir())


def _select(args: argparse.Namespace):
    sessions = history.load_all(_store())
    sess, turn, warnings = history.select_turn(sessions, session=args.session, project=args.project, turn=args.turn)
    for w in warnings:
        _err("warning: " + w)
    if sess.corrupt_lines:
        _err(f"warning: {sess.corrupt_lines} unreadable line(s) skipped in this session's history")
    return sess, turn


def _add_selectors(p: argparse.ArgumentParser) -> None:
    p.add_argument("--session", help="session id or unique prefix")
    p.add_argument("--project", help="limit to sessions whose project dir is this path or below it")
    p.add_argument("--turn", type=int, help="1-based turn number within the session")


def _write_stdout(text: str) -> None:
    sys.stdout.buffer.write(text.encode("utf-8", "surrogatepass"))
    sys.stdout.flush()


# -- commands ---------------------------------------------------------------

def cmd_hook(args: argparse.Namespace) -> int:
    from prompt_relay import hook
    return hook.main()


def cmd_enable(args: argparse.Namespace) -> int:
    root = data_dir()
    cfg = _config.load(root)
    if cfg.error:
        _err(f"config is unusable ({cfg.error}); fix or delete {root / 'config.json'}")
        return EXIT_ERROR
    path = _config.normalize_project_path(args.path)
    if not os.path.isdir(path):
        _err(f"not a directory: {path}")
        return EXIT_ERROR
    if path == os.sep or path == os.path.realpath(os.path.expanduser("~")):
        _err("refusing to enable capture for / or your home directory; choose a project directory")
        return EXIT_ERROR
    if path not in cfg.enabled_projects:
        cfg.enabled_projects.append(path)
        _config.save(root, cfg)
    print(f"capture enabled for {path}")
    return 0


def cmd_disable(args: argparse.Namespace) -> int:
    root = data_dir()
    cfg = _config.load(root)
    if cfg.error:
        _err(f"config is unusable ({cfg.error})")
        return EXIT_ERROR
    path = _config.normalize_project_path(args.path)
    if path in cfg.enabled_projects:
        cfg.enabled_projects.remove(path)
        _config.save(root, cfg)
        print(f"capture disabled for {path} (existing history is kept; use 'delete' to remove it)")
    else:
        print(f"capture was not enabled for {path}")
    return 0


def cmd_projects(args: argparse.Namespace) -> int:
    cfg = _config.load(data_dir())
    if cfg.error:
        _err(f"config is unusable ({cfg.error}); capture is OFF for all projects")
        return EXIT_ERROR
    if not cfg.enabled_projects:
        print("no projects enabled (capture is off)")
    for p in cfg.enabled_projects:
        print(p)
    return 0


def cmd_sessions(args: argparse.Namespace) -> int:
    sessions = history.filter_sessions(history.load_all(_store()), project=args.project)
    if not sessions:
        print("no captured sessions")
        return 0
    for s in sessions:
        last = s.turns[-1] if s.turns else None
        status = last.status if last else "-"
        extra = f"  [{s.corrupt_lines} corrupt line(s)]" if s.corrupt_lines else ""
        print(f"{s.last_at}  {s.session_id or s.key}  {s.project_name}  turns={len(s.turns)}  last={status}{extra}")
    return 0


def cmd_turns(args: argparse.Namespace) -> int:
    sessions = history.filter_sessions(history.load_all(_store()), session=args.session, project=args.project)
    if not sessions:
        _err("no captured sessions match the selection")
        return EXIT_NOTHING
    sess = sessions[0]
    print(f"session {sess.session_id or sess.key}  project {sess.project_dir or '-'}")
    for t in sess.turns:
        final = t.final_response
        req = t.prompt.text if t.prompt else None
        print(f"{t.index:>3}  {t.status:<40} link={t.link:<9} request: {_preview(req, 40)!s}  response: {_preview(final.text if final else None, 40)}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    sess, turn = _select(args)
    try:
        text = export.response_text(turn)
    except export.ExportError as exc:
        _err(str(exc))
        return EXIT_NOTHING
    _write_stdout(text)
    return 0


def _copy(text: str, args: argparse.Namespace) -> int:
    if args.stdout:
        _write_stdout(text)
        return 0
    try:
        backend = get_backend()
        backend.copy(text)
        if args.verify:
            if backend.read_back() != text.encode("utf-8"):
                _err("verification FAILED: clipboard content differs from the captured text")
                return EXIT_CLIPBOARD
    except ClipboardError as exc:
        _err(str(exc))
        return EXIT_CLIPBOARD
    note = " (MOCK clipboard)" if backend.is_mock else ""
    verified = ", verified by read-back" if args.verify else ""
    _err(f"copied {len(text)} characters via {backend.name}{note}{verified}")
    return 0


def cmd_copy(args: argparse.Namespace) -> int:
    sess, turn = _select(args)
    try:
        text = export.response_text(turn)
    except export.ExportError as exc:
        _err(str(exc))
        return EXIT_NOTHING
    if text == "":
        _err("the final response is empty; nothing copied")
        return EXIT_NOTHING
    final = turn.final_response
    if final is not None and final.has_background_tasks:
        _err("warning: background tasks were still running when Claude stopped; the work may not be finished")
    return _copy(text, args)


def _context(args: argparse.Namespace):
    sess, turn = _select(args)
    git = gitinfo.collect(sess.project_dir)
    return turn, export.render_context(sess, turn, git, _now())


def cmd_context(args: argparse.Namespace) -> int:
    turn, text = _context(args)
    findings = export.sensitive_findings(turn)
    _write_stdout(text)
    _report_findings(findings)
    return 0


def _report_findings(findings) -> None:
    if not findings:
        return
    _err(f"WARNING: {len(findings)} line(s) look like secrets or credentials:")
    for f in findings:
        _err(f"  {f.section} line {f.line}: {f.kind}")


def cmd_copy_context(args: argparse.Namespace) -> int:
    turn, text = _context(args)
    findings = export.sensitive_findings(turn)
    if findings and not args.allow_sensitive:
        _report_findings(findings)
        _err("not copied. Review with 'prompt-relay context', then re-run with --allow-sensitive if intended.")
        return EXIT_SENSITIVE
    _report_findings(findings)
    return _copy(text, args)


def cmd_delete(args: argparse.Namespace) -> int:
    store = _store()
    if not args.yes:
        _err("deletion is permanent; re-run with --yes to confirm")
        return EXIT_USAGE
    if args.all:
        n = store.delete_all()
        print(f"deleted {n} session file(s)")
        return 0
    sessions = history.filter_sessions(history.load_all(store), session=args.session)
    if len(sessions) != 1:
        _err("no single session matches; nothing deleted")
        return EXIT_NOTHING
    store.delete_path(store.path_for(sessions[0].session_id))
    print(f"deleted session {sessions[0].session_id}")
    return 0


def hook_settings(command: str, python: Optional[str] = None) -> dict:
    """Exec-form hook settings. With ``python``, the interpreter is pinned
    instead of resolving ``python3`` through PATH via the script's shebang."""
    if python:
        handler = {"type": "command", "command": python, "args": [command, "hook"], "timeout": 10}
    else:
        handler = {"type": "command", "command": command, "args": ["hook"], "timeout": 10}
    return {"hooks": {event: [{"hooks": [dict(handler)]}] for event in HOOK_EVENTS}}


def cmd_hook_config(args: argparse.Namespace) -> int:
    command = args.command or str(Path(__file__).resolve().parent.parent / "bin" / "prompt-relay")
    for path in filter(None, (command, args.python)):
        if not os.path.isabs(path):
            _err(f"hook paths must be absolute: {path}")
            return EXIT_USAGE
    print(json.dumps(hook_settings(command, args.python), indent=2))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    root = data_dir()
    print(f"prompt-relay {__version__}")
    print(f"python       {platform.python_version()} ({sys.executable})")
    print(f"platform     {sys.platform} {platform.machine()} {platform.mac_ver()[0] or ''}".rstrip())
    print(f"data dir     {root}")
    if root.exists():
        print(f"  mode       {oct(root.stat().st_mode & 0o777)}")
    cfg = _config.load(root)
    print(f"projects     {'ERROR ' + cfg.error if cfg.error else (len(cfg.enabled_projects) or 'none enabled')}")
    try:
        backend = get_backend()
        print(f"clipboard    {backend.name}")
    except ClipboardError as exc:
        print(f"clipboard    unavailable: {exc}")
    print(f"claude env   CLAUDE_CODE_REMOTE={os.environ.get('CLAUDE_CODE_REMOTE', '(unset)')}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="prompt-relay", description="Local capture and export of Claude Code results.")
    parser.add_argument("--version", action="version", version=f"prompt-relay {__version__}")
    sub = parser.add_subparsers(dest="command_name", required=True)

    sub.add_parser("hook", help="Claude Code hook handler (reads one event from stdin)").set_defaults(func=cmd_hook)

    p = sub.add_parser("enable", help="enable capture for a project directory")
    p.add_argument("path")
    p.set_defaults(func=cmd_enable)
    p = sub.add_parser("disable", help="disable capture for a project directory")
    p.add_argument("path")
    p.set_defaults(func=cmd_disable)
    sub.add_parser("projects", help="list projects with capture enabled").set_defaults(func=cmd_projects)

    p = sub.add_parser("sessions", help="list captured sessions")
    p.add_argument("--project")
    p.set_defaults(func=cmd_sessions)
    p = sub.add_parser("turns", help="list turns of a session (latest session by default)")
    p.add_argument("--session")
    p.add_argument("--project")
    p.set_defaults(func=cmd_turns)

    p = sub.add_parser("show", help="print the full final response verbatim")
    _add_selectors(p)
    p.set_defaults(func=cmd_show)

    for name, func, helptext in (("copy", cmd_copy, "Copy Response: copy the final response verbatim"),
                                 ("copy-context", cmd_copy_context, "Copy Context: copy a structured review packet")):
        p = sub.add_parser(name, help=helptext)
        _add_selectors(p)
        p.add_argument("--stdout", action="store_true", help="print instead of using the clipboard")
        p.add_argument("--verify", action="store_true", help="read the clipboard back and compare bytes")
        if name == "copy-context":
            p.add_argument("--allow-sensitive", action="store_true", help="copy even if secrets are suspected")
        p.set_defaults(func=func)

    p = sub.add_parser("context", help="preview the Copy Context text without copying")
    _add_selectors(p)
    p.set_defaults(func=cmd_context)

    p = sub.add_parser("delete", help="permanently delete captured history")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--session")
    g.add_argument("--all", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=cmd_delete)

    p = sub.add_parser("hook-config", help="print hook settings JSON for 'claude --settings' (writes nothing)")
    p.add_argument("--command", help="absolute path of the prompt-relay executable")
    p.add_argument("--python", help="absolute path of the Python interpreter to pin, e.g. /usr/bin/python3")
    p.set_defaults(func=cmd_hook_config)

    sub.add_parser("doctor", help="show environment diagnostics").set_defaults(func=cmd_doctor)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args) or 0)
    except history.SelectionError as exc:
        _err(str(exc))
        return EXIT_NOTHING
    except StoreError as exc:
        _err(f"storage error: {exc.code}")
        return EXIT_ERROR
    except BrokenPipeError:
        return 0
