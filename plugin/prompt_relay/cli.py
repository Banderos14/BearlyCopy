"""prompt-relay command-line interface.

Exit codes: 0 ok · 1 error · 2 usage / confirmation required · 3 nothing
found or nothing to export · 4 clipboard failure · 5 export blocked by the
sensitive-content check · 6 kept by active-session protection.

``--json`` (projects, sessions, turns, show, context, delete, prune,
retention) switches to the machine API in ``api.py``: exactly one JSON
document on stdout, nothing on stderr, same exit codes.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import platform
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

from prompt_relay import __version__, api
from prompt_relay import config as _config
from prompt_relay import export, gitinfo, history, integration, retention, runtime
from prompt_relay.clipboard import ClipboardError, get_backend
from prompt_relay.paths import ENV_HOME, data_dir
from prompt_relay.store import Store, StoreError

EXIT_ERROR, EXIT_USAGE, EXIT_NOTHING, EXIT_CLIPBOARD, EXIT_SENSITIVE, EXIT_ACTIVE = 1, 2, 3, 4, 5, 6
HOOK_EVENTS = ("UserPromptSubmit", "Stop", "StopFailure")


class CommandError(Exception):
    """A failure that maps to an exit code and, in --json mode, an API error."""

    def __init__(self, exit_code: int, code: str, message: str, data: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.error = api.ApiError(code, message, data)


def _err(msg: str) -> None:
    sys.stderr.write(f"prompt-relay: {msg}\n")


def _now() -> str:
    return _dt.datetime.now(tz=_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _preview(text: Optional[str], width: int = 60) -> str:
    if text is None:
        return "—"
    flat = " ".join(text.split())
    return flat if len(flat) <= width else flat[: width - 1] + "…"


def _store() -> Store:
    return Store(data_dir())


def _json(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "json", False))


def _emit(args: argparse.Namespace, data: Dict[str, Any], warnings: Optional[List[Dict[str, str]]] = None) -> int:
    sys.stdout.buffer.write(api.dumps(api.envelope(args.command_name, data, warnings)))
    sys.stdout.flush()
    return 0


def _select(args: argparse.Namespace):
    """Returns (session, turn, warnings as API objects). Text mode prints them."""
    sessions = history.load_all(_store())
    sess, turn, selection = history.select_turn(sessions, session=args.session, project=args.project, turn=args.turn)
    warnings = api.turn_warnings(sess, turn, selection)
    if not _json(args):
        for w in warnings:
            _err("warning: " + w["message"])
    return sess, turn, warnings


def _add_selectors(p: argparse.ArgumentParser) -> None:
    p.add_argument("--session", help="session id or unique prefix")
    p.add_argument("--project", help="limit to sessions whose project dir is this path or below it")
    p.add_argument("--turn", type=int, help="1-based turn number within the session")


def _add_json(p: argparse.ArgumentParser) -> None:
    p.add_argument("--json", action="store_true", help="machine-readable output (docs/JSON_API.md)")


def _write_stdout(text: str) -> None:
    sys.stdout.buffer.write(text.encode("utf-8", "surrogatepass"))
    sys.stdout.flush()


# -- commands ---------------------------------------------------------------

def cmd_hook(args: argparse.Namespace) -> int:
    from prompt_relay import hook
    return hook.main()


def cmd_enable(args: argparse.Namespace) -> int:
    with _config.locked(data_dir()):
        return _enable(args)


def _enable(args: argparse.Namespace) -> int:
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
    _pin_if_needed(root)
    return 0


def _pin_if_needed(root: Path) -> None:
    """Pin the running interpreter for the plugin launcher unless a usable pin
    exists, so plugin hooks work without any PATH setup."""
    _, state = runtime.read_pin(root)
    if state == runtime.OK:
        return
    try:
        version = runtime.write_pin(root, sys.executable)
    except (ValueError, OSError) as exc:
        _err(f"warning: could not pin {sys.executable} for the plugin hook: {exc}")
        return
    print(f"plugin hooks will use Python {'.'.join(map(str, version))} ({sys.executable})")


def cmd_pin_python(args: argparse.Namespace) -> int:
    root = data_dir()
    if args.clear:
        removed = runtime.clear_pin(root)
        print("pinned interpreter removed" if removed else "no interpreter was pinned")
        return 0
    if args.show:
        path, state = runtime.read_pin(root)
        print(f"{state}: {path}" if path else state)
        return 0 if state in (runtime.OK, runtime.NOT_SET) else EXIT_ERROR
    python = args.python or sys.executable
    try:
        version = runtime.write_pin(root, python)
    except (ValueError, OSError) as exc:
        _err(f"{python}: {exc}")
        return EXIT_USAGE
    print(f"plugin hooks will use Python {'.'.join(map(str, version))} ({python})")
    return 0


def cmd_disable(args: argparse.Namespace) -> int:
    with _config.locked(data_dir()):
        return _disable(args)


def _disable(args: argparse.Namespace) -> int:
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
        raise CommandError(EXIT_ERROR, api.CONFIG_ERROR,
                           f"config is unusable ({cfg.error}); capture is OFF for all projects")
    if not _json(args):
        if not cfg.enabled_projects:
            print("no projects enabled (capture is off)")
        for p in cfg.enabled_projects:
            print(p)
        return 0
    sessions = history.load_all(_store())
    by_path: Dict[Optional[str], List[history.Session]] = {}
    for s in sessions:
        by_path.setdefault(s.project_dir, []).append(s)
    paths = set(by_path) | set(cfg.enabled_projects)
    projects = []
    for path in sorted(paths, key=lambda p: (p is None, p or "")):
        group = by_path.get(path, [])
        ref = api.project_ref(path)
        ref.update({
            "capture_enabled": path is not None and _config.is_enabled(cfg, path),
            "explicitly_enabled": path in cfg.enabled_projects,
            "session_count": len(group),
            "last_event_at": max((s.last_at for s in group if s.last_at), default=None),
        })
        projects.append(ref)
    warnings = []
    if cfg.retention_error:
        warnings.append(api.warning("retention_setting_invalid", "retention_days in config.json is invalid and ignored"))
    data = {"projects": projects, "settings": {"retention_days": cfg.retention_days, "automatic_deletion": False}}
    return _emit(args, data, warnings)


def cmd_sessions(args: argparse.Namespace) -> int:
    sessions = history.filter_sessions(history.load_all(_store()), project=args.project)
    if _json(args):
        return _emit(args, {"project_filter": args.project, "sessions": [api.session_summary(s) for s in sessions]})
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
        raise CommandError(EXIT_NOTHING, api.NOT_FOUND, "no captured sessions match the selection")
    sess = sessions[0]
    if _json(args):
        data = {"session": api.session_summary(sess), "turns": [api.turn_object(t) for t in sess.turns]}
        return _emit(args, data, api.integrity_warnings(sess))
    print(f"session {sess.session_id or sess.key}  project {sess.project_dir or '-'}")
    for t in sess.turns:
        final = t.final_response
        req = t.prompt.text if t.prompt else None
        print(f"{t.index:>3}  {t.status:<40} link={t.link:<9} request: {_preview(req, 40)!s}  response: {_preview(final.text if final else None, 40)}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    sess, turn, warnings = _select(args)
    try:
        text = export.response_text(turn)
    except export.ExportError as exc:
        data = {"session": api.session_summary(sess), "turn": api.turn_object(turn, full=True)}
        raise CommandError(EXIT_NOTHING, api.NO_FINAL_RESPONSE, str(exc), data)
    if _json(args):
        return _emit(args, {"session": api.session_summary(sess), "turn": api.turn_object(turn, full=True)}, warnings)
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
    sess, turn, _ = _select(args)
    try:
        text = export.response_text(turn)
    except export.ExportError as exc:
        _err(str(exc))
        return EXIT_NOTHING
    if text == "":
        _err("the final response is empty; nothing copied")
        return EXIT_NOTHING
    # Copy Response is the explicit verbatim copy: warn about suspected
    # secrets, but never block or alter the text.
    _report_findings(export.sensitive_findings(turn, request=False))
    return _copy(text, args)


def _context(args: argparse.Namespace):
    sess, turn, warnings = _select(args)
    git = gitinfo.collect(sess.project_dir)
    exported_at = _now()
    return sess, turn, warnings, git, exported_at, export.render_context(sess, turn, git, exported_at)


def cmd_context(args: argparse.Namespace) -> int:
    sess, turn, warnings, git, exported_at, text = _context(args)
    findings = export.sensitive_findings(turn)
    if _json(args):
        if findings:
            warnings.append(api.warning("sensitive_content", f"{len(findings)} line(s) look like secrets or credentials"))
        data = {
            "session": api.session_summary(sess),
            "turn": api.turn_object(turn),
            "exported_at": exported_at,
            "text": text,
            "sensitive_findings": api.findings(findings),
            "git": {
                "available": git.available,
                "reason": git.reason or None,
                "branch": git.branch,
                "head": git.head,
                "changed_file_count": len(git.changed_files),
                "changed_files_truncated": git.changed_files_truncated,
            },
        }
        return _emit(args, data, warnings)
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
    sess, turn, _, _, _, text = _context(args)
    findings = export.sensitive_findings(turn)
    if findings and not args.allow_sensitive:
        _report_findings(findings)
        _err("not copied. Review with 'prompt-relay context', then re-run with --allow-sensitive if intended.")
        return EXIT_SENSITIVE
    _report_findings(findings)
    return _copy(text, args)


# -- history management --------------------------------------------------------

def _size(n: int) -> str:
    return f"{n} B" if n < 1024 else (f"{n / 1024:.1f} KB" if n < 1 << 20 else f"{n / (1 << 20):.1f} MB")


def _print_plan(plan: retention.Plan, dry_run: bool) -> None:
    for it in plan.items:
        when = api.iso(it.last_activity_epoch) or "-"
        reason = f"  ({it.reason})" if it.reason else ""
        print(f"{it.action:<15} {it.session.session_id or it.file.key}  {it.session.project_name}  "
              f"last activity {when}  {_size(it.file.size)}{reason}")
    if dry_run:
        n = plan.count(retention.WOULD_DELETE)
        size = sum(it.file.size for it in plan.items if it.action == retention.WOULD_DELETE)
        print(f"dry run: {n} session file(s) would be deleted ({_size(size)}); nothing was deleted")
    else:
        print(f"deleted {plan.count(retention.DELETED)} session file(s); "
              f"skipped {plan.count(retention.SKIPPED_ACTIVE, retention.SKIPPED_CHANGED, retention.SKIPPED_UNSAFE)}; "
              f"failed {plan.count(retention.FAILED)}")


def _finish_plan(args: argparse.Namespace, plan: retention.Plan, dry_run: bool, confirm_needed: bool) -> int:
    data = api.plan_object(plan, dry_run)
    warnings = []
    active = plan.count(retention.SKIPPED_ACTIVE)
    if active:
        warnings.append(api.warning("active_sessions_kept",
                                    f"{active} session(s) active in the last {retention.ACTIVE_GRACE_S // 60} min were kept"))
    if confirm_needed:
        raise CommandError(EXIT_USAGE, api.CONFIRMATION_REQUIRED,
                           "deletion is permanent; re-run with --yes to confirm (or --dry-run to preview)", data)
    failed = plan.count(retention.FAILED, retention.SKIPPED_UNSAFE)
    if not _json(args):
        _print_plan(plan, dry_run)
        for w in warnings:
            _err("warning: " + w["message"])
    if failed:
        raise CommandError(EXIT_ERROR, api.STORAGE_ERROR, f"{failed} session file(s) could not be deleted safely", data)
    if plan.kind == "delete" and active and not dry_run:
        raise CommandError(EXIT_ACTIVE, api.ACTIVE_SESSION,
                           "active session(s) were kept; re-run with --force-active to delete them", data)
    if _json(args):
        return _emit(args, data, warnings)
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    store = _store()
    plan = retention.plan_delete(store, session=args.session, all_sessions=args.all, force_active=args.force_active)
    if args.dry_run:
        return _finish_plan(args, plan, dry_run=True, confirm_needed=False)
    if not args.yes:
        if not _json(args):
            _print_plan(plan, dry_run=True)
        return _finish_plan(args, plan, dry_run=True, confirm_needed=True)
    retention.execute(store, plan)
    return _finish_plan(args, plan, dry_run=False, confirm_needed=False)


def cmd_prune(args: argparse.Namespace) -> int:
    days = args.older_than_days
    if days is None:
        cfg = _config.load(data_dir())
        if cfg.error:
            raise CommandError(EXIT_ERROR, api.CONFIG_ERROR, f"config is unusable ({cfg.error})")
        days = cfg.retention_days
    if days is None:
        raise CommandError(EXIT_USAGE, api.USAGE_ERROR,
                           "no retention period set; pass --older-than-days N or run 'prompt-relay retention --days N'")
    if not _config.valid_retention_days(days):
        raise CommandError(EXIT_USAGE, api.USAGE_ERROR, f"--older-than-days must be 1..{_config.MAX_RETENTION_DAYS}")
    store = _store()
    plan = retention.plan_prune(store, days)
    dry_run = not args.yes
    if not dry_run:
        retention.execute(store, plan)
    return _finish_plan(args, plan, dry_run=dry_run, confirm_needed=False)


def cmd_retention(args: argparse.Namespace) -> int:
    root = data_dir()
    with _config.locked(root):
        cfg = _config.load(root)
        if cfg.error:
            raise CommandError(EXIT_ERROR, api.CONFIG_ERROR, f"config is unusable ({cfg.error})")
        if args.days is not None or args.off:
            if args.days is not None and not _config.valid_retention_days(args.days):
                raise CommandError(EXIT_USAGE, api.USAGE_ERROR, f"--days must be 1..{_config.MAX_RETENTION_DAYS}")
            cfg.retention_days = None if args.off else args.days
            cfg.retention_error = None
            _config.save(root, cfg)
    data = {"retention_days": cfg.retention_days, "automatic_deletion": False}
    warnings = []
    if cfg.retention_error:
        warnings.append(api.warning("retention_setting_invalid", "retention_days in config.json is invalid and ignored"))
    if _json(args):
        return _emit(args, data, warnings)
    for w in warnings:
        _err("warning: " + w["message"])
    if cfg.retention_days is None:
        print("retention: not set (history is kept until you delete it)")
    else:
        print(f"retention: {cfg.retention_days} day(s). Nothing is deleted automatically; "
              f"run 'prompt-relay prune' to preview and 'prune --yes' to delete.")
    return 0


# -- hook configuration and diagnostics ----------------------------------------

ENV_PROGRAM = "/usr/bin/env"


def hook_settings(command: str, python: Optional[str] = None, home: Optional[str] = None) -> dict:
    """Exec-form hook settings. With ``python``, the interpreter is pinned
    instead of resolving ``python3`` through PATH via the script's shebang.
    With ``home``, the hook runs through ``/usr/bin/env PROMPT_RELAY_HOME=…``
    (still no shell), so it writes to that data dir even where the hook's
    environment cannot be set, such as Claude Desktop."""
    argv = ([python] if python else []) + [command, "hook"]
    if home:
        argv = [ENV_PROGRAM, ENV_HOME + "=" + home] + argv
    handler = {"type": "command", "command": argv[0], "args": argv[1:], "timeout": 10}
    return {"hooks": {event: [{"hooks": [dict(handler)]}] for event in HOOK_EVENTS}}


MIN_PYTHON = (3, 9)


def _usable_python(path: str) -> Optional[str]:
    """Why ``path`` cannot run the hook, or None if it looks usable."""
    if not os.path.isabs(path):
        return "path must be absolute"
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        return "not an executable file"
    return None


def _checkout_bin() -> Optional[str]:
    """bin/prompt-relay of a repository checkout (plugin/prompt_relay/../../bin)."""
    candidate = Path(__file__).resolve().parent.parent.parent / "bin" / "prompt-relay"
    return str(candidate) if candidate.is_file() else None


def cmd_hook_config(args: argparse.Namespace) -> int:
    command = args.command or _checkout_bin()
    if command is None:
        _err("no repository checkout found next to this package; pass --command")
        return EXIT_USAGE
    # Default: pin the interpreter running this command, which is known to
    # work. Nothing assumes /usr/bin/python3 or a particular PATH (Claude
    # Desktop starts hooks with a minimal PATH).
    python = None if args.use_shebang else (args.python or sys.executable)
    if not os.path.isabs(command):
        _err(f"hook paths must be absolute: {command}")
        return EXIT_USAGE
    if python:
        problem = _usable_python(python)
        if problem:
            _err(f"--python {python}: {problem}")
            return EXIT_USAGE
    home = args.data_dir
    if home is not None and not (os.path.isabs(home) and os.path.isdir(home)):
        _err(f"--data-dir {home}: must be an existing absolute directory")
        return EXIT_USAGE
    print(json.dumps(hook_settings(command, python, home), indent=2))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    project = args.project
    if project is None and not args.no_project:
        project = os.getcwd()
    if project:
        project = _config.normalize_project_path(project)
    report = integration.diagnose(os.environ, project, tuple(sys.version_info[:3]), sys.executable)
    report["core"]["prompt_relay_version"] = __version__
    report["core"]["api_version"] = api.API_VERSION
    if _json(args):
        warnings = [api.warning(f["code"], f["message"]) for f in report["findings"] if f["level"] != "ok"]
        return _emit(args, report, warnings)
    _print_doctor(report)
    return 0


def _print_doctor(report: Dict[str, Any]) -> None:
    core, storage, capture = report["core"], report["storage"], report["capture"]
    print(f"prompt-relay {core['prompt_relay_version']} (JSON API v{core['api_version']})")
    py = core["python"]
    print(f"python       {py['version']} ({py['executable']}){'' if py['supported'] else '  UNSUPPORTED: need 3.9+'}")
    pin = core["pinned_python"]
    print(f"hook python  {pin['state']}{': ' + pin['path'] if pin['path'] else ''}")
    if sys.platform == "darwin":
        print(f"xcode CLT    {_xcode_clt()}")
    print(f"platform     {sys.platform} {platform.machine()} {platform.mac_ver()[0] or ''}".rstrip())
    print(f"data dir     {storage['data_dir']} ({'writable' if storage['writable'] else 'NOT writable'}, "
          f"{storage['session_files']} session file(s))")
    print(f"projects     {'ERROR ' + capture['config_error'] if capture['config_error'] else (len(capture['enabled_projects']) or 'none enabled')}")
    if capture["project"]:
        print(f"this project {'capture ON' if capture['project']['capture_enabled'] else 'capture off'} ({capture['project']['path']})")
    plugin = report["configuration"]["plugin"]
    print(f"plugin       install records: {len(plugin['records'])} ({plugin['state']}, {plugin['file']})")
    for rec in plugin["records"]:
        print(f"               {rec['id']} scope={rec['scope']} version={rec['version']} files={'ok' if rec['manifest_found'] and rec['launcher_found'] else 'MISSING'}")
    for s in report["configuration"]["settings"]:
        ours = len(s["prompt_relay_hooks"])
        foreign = sum(s["foreign_hooks"].values())
        flags = ", ".join(f"{k}={v}" for k, v in s["enabled_plugins"].items()) or "-"
        print(f"settings     {s['scope']:<7} {s['state']:<12} prompt-relay hooks: {ours}  other hooks: {foreign}  enabledPlugins: {flags}")
    seen = report["observed"]
    vias = ", ".join(f"{k}: {v['events']} (last {v['last_at']})" for k, v in seen["by_via"].items()) or "none"
    print(f"observed     {vias}  [{seen['log_file']}, metadata only]")
    try:
        backend = get_backend()
        print(f"clipboard    {backend.name}")
    except ClipboardError as exc:
        print(f"clipboard    unavailable: {exc}")
    print(f"retention    {_config.load(data_dir()).retention_days or 'not set'} (automatic deletion: off)")
    for f in report["findings"]:
        print(f"{f['level'].upper():<12} {f['code']}: {f['message']}")
    for note in report["unverified"]:
        print(f"UNVERIFIED   {note}")


def _xcode_clt() -> str:
    """Read-only check. Without the Command Line Tools, /usr/bin/python3 is a
    stub that opens an install dialog instead of running Python."""
    import subprocess
    try:
        proc = subprocess.run(["/usr/bin/xcode-select", "-p"], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return "unknown (xcode-select not runnable)"
    if proc.returncode != 0:
        return "NOT installed: /usr/bin/python3 will not work; install with 'xcode-select --install' or use another Python 3.9+"
    return "installed at " + proc.stdout.decode("utf-8", "replace").strip()


# -- parser ---------------------------------------------------------------------

class _Parser(argparse.ArgumentParser):
    """In --json mode, usage errors become a JSON error document (exit 2)."""

    json_mode = False

    def error(self, message: str) -> None:  # type: ignore[override]
        if _Parser.json_mode:
            parts = self.prog.split()
            command = parts[1] if len(parts) > 1 else None
            doc = api.envelope(command, error=api.ApiError(api.USAGE_ERROR, message))  # type: ignore[arg-type]
            sys.stdout.buffer.write(api.dumps(doc))
            sys.stdout.flush()
            sys.exit(EXIT_USAGE)
        super().error(message)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="prompt-relay", description="Local capture and export of Claude Code results.")
    parser.add_argument("--version", action="version", version=f"prompt-relay {__version__}")
    sub = parser.add_subparsers(dest="command_name", required=True)

    sub.add_parser("hook", help="Claude Code hook handler (reads one event from stdin)").set_defaults(func=cmd_hook)

    p = sub.add_parser("enable", help="enable capture for a project directory")
    p.add_argument("path")
    p.set_defaults(func=cmd_enable)
    p = sub.add_parser("disable", help="disable capture for a project directory")
    p.add_argument("path")
    p.set_defaults(func=cmd_disable)
    p = sub.add_parser("projects", help="list projects with capture enabled (--json: also projects with history)")
    _add_json(p)
    p.set_defaults(func=cmd_projects)

    p = sub.add_parser("sessions", help="list captured sessions")
    p.add_argument("--project")
    _add_json(p)
    p.set_defaults(func=cmd_sessions)
    p = sub.add_parser("turns", help="list turns of a session (latest session by default)")
    p.add_argument("--session")
    p.add_argument("--project")
    _add_json(p)
    p.set_defaults(func=cmd_turns)

    p = sub.add_parser("show", help="print the full final response verbatim")
    _add_selectors(p)
    _add_json(p)
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
    _add_json(p)
    p.set_defaults(func=cmd_context)

    p = sub.add_parser("delete", help="delete captured history (preview first; --yes to delete)")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--session")
    g.add_argument("--all", action="store_true")
    p.add_argument("--yes", action="store_true", help="confirm the permanent deletion")
    p.add_argument("--dry-run", action="store_true", help="only show what would be deleted")
    p.add_argument("--force-active", action="store_true",
                   help=f"also delete sessions active in the last {retention.ACTIVE_GRACE_S // 60} minutes")
    _add_json(p)
    p.set_defaults(func=cmd_delete)

    p = sub.add_parser("prune", help="delete sessions older than the retention period (dry run unless --yes)")
    p.add_argument("--older-than-days", type=int, help="age threshold in days (default: the retention setting)")
    p.add_argument("--yes", action="store_true", help="really delete; without it only a preview is shown")
    p.add_argument("--dry-run", action="store_true", help="preview only (the default)")
    _add_json(p)
    p.set_defaults(func=cmd_prune)

    p = sub.add_parser("retention", help="show or set the retention period used by prune")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--days", type=int, help="keep history for N days (used by prune; never automatic)")
    g.add_argument("--off", action="store_true", help="clear the retention period")
    _add_json(p)
    p.set_defaults(func=cmd_retention)

    p = sub.add_parser("hook-config", help="print hook settings JSON for 'claude --settings' (writes nothing)")
    p.add_argument("--command", help="absolute path of the prompt-relay executable")
    p.add_argument("--python", help="absolute path of the Python 3.9+ interpreter to pin (default: the one running this command)")
    p.add_argument("--use-shebang", action="store_true", help="do not pin an interpreter; rely on '#!/usr/bin/env python3' and PATH")
    p.add_argument("--data-dir", help="absolute data dir the hook writes to (sets PROMPT_RELAY_HOME through /usr/bin/env; for isolated checks)")
    p.set_defaults(func=cmd_hook_config)

    p = sub.add_parser("doctor", help="diagnose Python, storage, capture and the Claude Code integration (read-only)")
    p.add_argument("--project", help="project to check (default: the current directory)")
    p.add_argument("--no-project", action="store_true", help="skip the project checks")
    _add_json(p)
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("pin-python", help="choose the Python 3.9+ the plugin hook runs with")
    p.add_argument("--python", help="absolute interpreter path (default: the one running this command)")
    p.add_argument("--show", action="store_true", help="show the pinned interpreter")
    p.add_argument("--clear", action="store_true", help="remove the pin (the launcher then searches)")
    p.set_defaults(func=cmd_pin_python)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    _Parser.json_mode = "--json" in argv
    args = build_parser().parse_args(argv)
    json_mode = _json(args)
    try:
        return int(args.func(args) or 0)
    except CommandError as exc:
        failure, code = exc.error, exc.exit_code
    except history.SelectionError as exc:
        failure, code = api.ApiError(exc.code, str(exc)), EXIT_NOTHING
    except StoreError as exc:
        kind = api.UNSAFE_PATH if exc.code == "unsafe_path" else api.STORAGE_ERROR
        failure, code = api.ApiError(kind, f"storage error: {exc.code}"), EXIT_ERROR
    except BrokenPipeError:
        return 0
    except Exception as exc:  # pragma: no cover - last resort, keeps --json output valid
        if not json_mode:
            raise
        failure, code = api.ApiError(api.INTERNAL_ERROR, f"internal error: {type(exc).__name__}"), EXIT_ERROR
    if json_mode:
        sys.stdout.buffer.write(api.dumps(api.envelope(args.command_name, error=failure)))
        sys.stdout.flush()
    else:
        _err(failure.message)
    return code
