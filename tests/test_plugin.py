"""Phase 2B: Claude Code plugin package, launcher, coexistence and diagnostics.

Everything runs in temp directories with synthetic settings. Nothing touches
the real ~/.claude. The plugin is "installed" by copying plugin/ to a temp
cache-like path, as Claude Code does for marketplace installs. The tests that
run the real ``claude`` binary only call ``plugin validate`` and
``--plugin-dir … plugin list/details`` with an isolated HOME: no install,
no session, no API request. They are skipped where ``claude`` is missing.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional

from helpers import BIN, PLUGIN, REPO, IsolatedTestCase
from jsonschema_lite import validate_response

from prompt_relay import __version__, runtime
from prompt_relay.store import Store

SCHEMA = json.loads((REPO / "docs" / "api" / "api-v1.schema.json").read_text(encoding="utf-8"))
MANIFEST = PLUGIN / ".claude-plugin" / "plugin.json"
HOOKS = PLUGIN / "hooks" / "hooks.json"
LAUNCHER_REL = Path("hooks") / "run-hook"
MARKETPLACE = REPO / ".claude-plugin" / "marketplace.json"
EVENTS = {"UserPromptSubmit", "Stop", "StopFailure", "PostToolUse", "PostToolUseFailure"}
# Tool events (ADR-013): async, limited by a matcher, never blocking Claude.
TOOL_MATCHERS = {"PostToolUse": "Bash|Write|Edit|MultiEdit|NotebookEdit|SendUserFile|Artifact",
                 "PostToolUseFailure": "Bash|Write|Edit|MultiEdit|NotebookEdit"}
CLAUDE = shutil.which("claude")


def install_copy(dest: Path, with_package: bool = True) -> Path:
    """Copy the plugin like a marketplace install into cache/<mkt>/<plugin>/<version>/."""
    ignore = shutil.ignore_patterns("__pycache__", *([] if with_package else ["prompt_relay"]))
    shutil.copytree(str(PLUGIN), str(dest), ignore=ignore)
    return dest


class PluginPackageTests(unittest.TestCase):
    def test_manifest(self):
        m = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(m["name"], "prompt-relay")
        self.assertRegex(m["name"], r"^[a-z0-9]+(-[a-z0-9]+)*$")
        self.assertEqual(m["version"], __version__, "plugin.json version follows the package version")
        documented = {"$schema", "name", "displayName", "version", "description", "author", "homepage", "repository",
                      "license", "keywords", "metadata", "defaultEnabled", "dependencies", "settings", "userConfig",
                      "hooks", "skills", "commands", "agents", "mcpServers", "lspServers", "outputStyles"}
        self.assertLessEqual(set(m), documented)
        self.assertNotIn("hooks", m, "hooks load from the default hooks/hooks.json")
        self.assertIn("name", m["author"])

    def test_plugin_root_contents(self):
        names = {p.name for p in PLUGIN.iterdir() if p.name != "__pycache__"}
        self.assertEqual(names, {".claude-plugin", "hooks", "prompt_relay"})
        # bin/ would be put on Claude's Bash PATH; CLAUDE.md at the root is not loaded and warns.
        self.assertFalse((PLUGIN / "bin").exists())
        self.assertFalse((PLUGIN / "CLAUDE.md").exists())
        for path in PLUGIN.rglob("*"):
            self.assertFalse(path.is_symlink(), f"no symlinks in the plugin ({path})")

    def test_hooks_json(self):
        doc = json.loads(HOOKS.read_text(encoding="utf-8"))
        self.assertEqual(set(doc), {"hooks"}, "hooks file wraps the event map in a top-level 'hooks' key")
        self.assertEqual(set(doc["hooks"]), EVENTS)
        for event, groups in doc["hooks"].items():
            self.assertEqual(len(groups), 1, event)
            expected = {"type": "command", "command": "/bin/sh",
                        "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/run-hook"], "timeout": 10}
            if event in TOOL_MATCHERS:
                self.assertEqual(groups[0]["matcher"], TOOL_MATCHERS[event])
                expected["async"] = True
            else:
                self.assertNotIn("matcher", groups[0])
            (handler,) = groups[0]["hooks"]
            self.assertEqual(handler, expected, "exec form: the plugin root is one argument, never shell-parsed")
        launcher = PLUGIN / LAUNCHER_REL
        self.assertTrue(launcher.is_file())
        self.assertTrue(os.access(str(launcher), os.X_OK))
        self.assertTrue((PLUGIN / "hooks" / "prompt_relay_hook.py").is_file())

    def test_launcher_is_posix_and_safe(self):
        text = (PLUGIN / LAUNCHER_REL).read_text()
        self.assertTrue(text.startswith("#!/bin/sh\n"))
        self.assertNotRegex(text, r"\beval\b|curl|wget|\bsource\b|\$\(cat")
        self.assertIn('exec "$python" -I -S "$entry"', text)
        self.assertNotIn("echo ", text, "the launcher must never write to stdout")
        if shutil.which("sh"):
            self.assertEqual(subprocess.run(["sh", "-n", str(PLUGIN / LAUNCHER_REL)]).returncode, 0)

    def test_marketplace(self):
        mk = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        self.assertEqual(mk["name"], "prompt-relay")
        self.assertIn("name", mk["owner"])
        (entry,) = mk["plugins"]
        self.assertEqual(entry["name"], json.loads(MANIFEST.read_text())["name"], "entry name == manifest name")
        self.assertEqual(entry["source"], "./plugin")
        self.assertNotIn("..", entry["source"])
        self.assertTrue((REPO / entry["source"] / ".claude-plugin" / "plugin.json").is_file())

    def test_no_history_or_data_in_plugin_tree(self):
        for path in PLUGIN.rglob("*"):
            self.assertNotEqual(path.suffix, ".jsonl")
            self.assertNotIn(path.name, ("config.json", "handler.log", "python-path"))


@unittest.skipIf(CLAUDE is None, "claude CLI not installed")
class ClaudeCliValidationTests(unittest.TestCase):
    """Real Claude Code parser, isolated HOME. Verifies configuration, not execution."""

    def claude(self, *args: str) -> subprocess.CompletedProcess:
        home = Path(tempfile.mkdtemp(prefix="pr-claude-home-"))
        try:
            env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "CLAUDE_CONFIG_DIR": str(home / ".claude"),
                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"}
            for key in ("HTTPS_PROXY", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"):
                if key in os.environ:
                    env[key] = os.environ[key]
            return subprocess.run([CLAUDE, *args], env=env, cwd=str(home), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, timeout=180)
        finally:
            shutil.rmtree(str(home), ignore_errors=True)

    def test_plugin_validates_strictly(self):
        proc = self.claude("plugin", "validate", str(PLUGIN), "--strict", "--json")
        report = json.loads(proc.stdout)
        self.assertTrue(report["success"], report)
        self.assertEqual((report["manifest"]["errors"], report["manifest"]["warnings"]), ([], []))
        for item in report["contents"]:
            self.assertEqual(item.get("errors"), [], item)

    def test_marketplace_validates(self):
        proc = self.claude("plugin", "validate", str(REPO))
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_claude_code_registers_the_three_hooks(self):
        listing = json.loads(self.claude("--plugin-dir", str(PLUGIN), "plugin", "list", "--json").stdout)
        (entry,) = [e for e in listing if e["id"] == "prompt-relay@inline"]
        self.assertEqual((entry["version"], entry["enabled"]), (__version__, True))
        self.assertNotIn("errors", entry)
        details = self.claude("--plugin-dir", str(PLUGIN), "plugin", "details", "prompt-relay").stdout.decode()
        self.assertRegex(details, r"Hooks \(5\)")
        self.assertRegex(details, r"Always-on:\s+~0 tok")

    def test_plugin_root_with_spaces_and_unicode_validates(self):
        tmp = Path(tempfile.mkdtemp(prefix="pr-root-"))
        try:
            root = install_copy(tmp / "Plugin Cache ü" / "версия 0.2.0")
            self.assertEqual(self.claude("plugin", "validate", str(root), "--strict").returncode, 0)
        finally:
            shutil.rmtree(str(tmp), ignore_errors=True)


class LauncherTests(IsolatedTestCase):
    """The plugin launcher started like Claude Code starts it: /bin/sh <root>/hooks/run-hook."""

    def setUp(self) -> None:
        super().setUp()
        self.cache = self.tmp / "home" / ".claude" / "plugins" / "cache" / "prompt-relay" / "prompt-relay"
        self.root = install_copy(self.cache / "Version ü 0.2.0")
        runtime.write_pin(self.home, sys.executable)

    def launch(self, payload, root: Optional[Path] = None, env: Optional[Dict[str, str]] = None,
               extra: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
        root = root or self.root
        base = {"HOME": self.env["HOME"], "PATH": "/usr/bin:/bin", "PROMPT_RELAY_HOME": str(self.home),
                "CLAUDE_PLUGIN_ROOT": str(root), "CLAUDE_PROJECT_DIR": self.project}
        if env is not None:
            base = env
        base.update(extra or {})
        raw = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        return subprocess.run(["/bin/sh", str(root / LAUNCHER_REL)], input=raw, env=base,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def assertLaunchOk(self, proc: subprocess.CompletedProcess) -> None:
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"", "the plugin hook must never write to stdout")

    def test_stop_captured_verbatim_from_root_with_spaces_and_unicode(self):
        self.assertIn(" ", str(self.root))
        self.assertLaunchOk(self.launch(self.fx("prompt_basic.json")))
        stop = self.fx("stop_unicode.json")
        self.assertLaunchOk(self.launch(stop))
        recs = self.records("sess-a")
        self.assertEqual(recs[-1]["payload"], stop)
        self.assertEqual(self.cli("show").stdout, stop["last_assistant_message"].encode("utf-8"))
        self.assertIn("link=prompt_id", self.cli("turns").stdout.decode())
        log = (self.home / "handler.log").read_text()
        self.assertIn("Stop via=plugin stored", log)

    def test_independent_of_working_directory(self):
        proc = subprocess.run(["/bin/sh", str(self.root / LAUNCHER_REL)], cwd="/",
                              input=json.dumps(self.fx("stop_basic.json")).encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30,
                              env={"HOME": self.env["HOME"], "PATH": "/usr/bin:/bin", "PROMPT_RELAY_HOME": str(self.home)})
        self.assertLaunchOk(proc)
        self.assertEqual(len(self.records("sess-a")), 1)

    def test_without_pin_uses_discovery(self):
        runtime.clear_pin(self.home)
        if not shutil.which("python3", path="/usr/bin:/bin"):
            self.skipTest("no python3 in /usr/bin:/bin on this machine")
        self.assertLaunchOk(self.launch(self.fx("stop_basic.json")))
        self.assertEqual(len(self.records("sess-a")), 1)

    def test_stale_or_wrong_pin_falls_back(self):
        if not shutil.which("python3", path="/usr/bin:/bin"):
            self.skipTest("no python3 in /usr/bin:/bin on this machine")
        fake = self.tmp / "not-python"
        fake.write_text("#!/bin/sh\nexit 3\n")
        fake.chmod(0o755)
        for target in (str(self.tmp / "missing" / "python3"), str(self.tmp), str(fake), "relative/python3"):
            with self.subTest(target):
                runtime.pin_path(self.home).write_text(target + "\n")
                self.assertLaunchOk(self.launch(self.fx("stop_basic.json", prompt_id="p-" + target)))
        self.assertEqual(len(self.records("sess-a")), 4)

    @unittest.skipIf(sys.platform == "darwin", "macOS falls back to fixed locations (Homebrew, python.org, CLT) "
                     "that exist on a developer Mac; the no-Python path is covered on Linux")
    def test_no_usable_python_exits_zero_silently(self):
        old = self.tmp / "oldbin"
        old.mkdir()
        (old / "python3").write_text("#!/bin/sh\nexit 1\n")  # a "python" that fails the 3.9 check
        (old / "python3").chmod(0o755)
        runtime.pin_path(self.home).write_text(str(old / "python3") + "\n")
        env = {"HOME": self.env["HOME"], "PATH": str(old), "PROMPT_RELAY_HOME": str(self.home)}
        proc = self.launch(self.fx("stop_basic.json"), env=env)
        self.assertLaunchOk(proc)
        self.assertIn(b"no_python_3_9", proc.stderr)
        self.assertEqual(self.records("sess-a"), [])

    def test_missing_package_or_entry_exits_zero(self):
        broken = install_copy(self.tmp / "broken root", with_package=False)
        proc = self.launch(self.fx("stop_basic.json"), root=broken)
        self.assertLaunchOk(proc)
        self.assertIn(b"startup_failed:ModuleNotFoundError", proc.stderr)
        (broken / "hooks" / "prompt_relay_hook.py").unlink()
        proc = self.launch(self.fx("stop_basic.json"), root=broken)
        self.assertLaunchOk(proc)
        self.assertIn(b"launcher_entry_missing", proc.stderr)
        self.assertEqual(self.records("sess-a"), [])

    def test_pythonpath_cannot_inject_code(self):
        evil = self.tmp / "evil" / "prompt_relay"
        evil.mkdir(parents=True)
        (evil / "__init__.py").write_text("")
        (evil / "hook.py").write_text("import sys\ndef main():\n    print('INJECTED')\n    return 0\n")
        (self.tmp / "evil" / "sitecustomize.py").write_text("print('INJECTED')\n")
        proc = self.launch(self.fx("stop_basic.json"), extra={"PYTHONPATH": str(self.tmp / "evil"),
                                                              "PYTHONSTARTUP": str(self.tmp / "evil" / "sitecustomize.py")})
        self.assertLaunchOk(proc)
        self.assertEqual(len(self.records("sess-a")), 1, "the real handler ran")

    def test_capture_off_and_failures_never_block(self):
        self.cli("disable", self.project)
        self.assertLaunchOk(self.launch(self.fx("stop_basic.json")))
        self.assertEqual(self.records("sess-a"), [])
        blocked = self.tmp / "blocked"
        blocked.write_text("x")
        proc = self.launch(self.fx("stop_basic.json"), extra={"PROMPT_RELAY_HOME": str(blocked / "sub")})
        self.assertLaunchOk(proc)
        for raw in (b"{broken", b"", b"\xff"):
            self.assertLaunchOk(self.launch(raw))

    def test_plugin_root_change_after_update_keeps_history(self):
        self.assertLaunchOk(self.launch(self.fx("prompt_basic.json")))
        new_root = install_copy(self.cache / "0.2.1")
        self.assertLaunchOk(self.launch(self.fx("stop_basic.json"), root=new_root))
        shutil.rmtree(str(self.root))  # the old version is cleaned up later by Claude Code
        self.assertLaunchOk(self.launch(self.fx("prompt_basic.json", prompt_id="p-2", prompt="next"), root=new_root))
        turns = self.cli("turns").stdout.decode()
        self.assertIn("link=prompt_id", turns)
        self.assertEqual(len(self.records("sess-a")), 3)
        self.assertEqual(self.cli("show").stdout, self.fx("stop_basic.json")["last_assistant_message"].encode())

    def test_uninstall_and_disable_never_delete_history(self):
        self.assertLaunchOk(self.launch(self.fx("prompt_basic.json")))
        self.assertLaunchOk(self.launch(self.fx("stop_basic.json")))
        shutil.rmtree(str(self.cache))  # plugin uninstalled: its files are gone
        self.assertEqual(self.cli("disable", self.project).returncode, 0)
        self.assertEqual(len(self.records("sess-a")), 2)
        self.assertIn(b"sess-a", self.cli("sessions").stdout)
        self.assertEqual(self.cli("show").returncode, 0)

    def test_double_registration_stores_each_event_once(self):
        payload = self.fx("stop_basic.json")
        raw = json.dumps(payload).encode()
        plugin_proc = subprocess.Popen(["/bin/sh", str(self.root / LAUNCHER_REL)], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env={"HOME": self.env["HOME"], "PATH": "/usr/bin:/bin",
                                            "PROMPT_RELAY_HOME": str(self.home)})
        settings_proc = subprocess.Popen([sys.executable, str(BIN), "hook"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        for p in (plugin_proc, settings_proc):
            out, _ = p.communicate(raw, timeout=30)
            self.assertEqual((p.returncode, out), (0, b""))
        self.assertEqual(len(self.records("sess-a")), 1)
        outcomes = sorted(line.split()[2:] for line in (self.home / "handler.log").read_text().splitlines())
        self.assertEqual(sorted(o[-1] for o in outcomes), ["duplicate", "stored"])
        self.assertEqual(sorted(o[0] for o in outcomes), ["via=direct", "via=plugin"])
        doctor = self.doctor()
        self.assertIn("events_from_two_sources", [f["code"] for f in doctor["data"]["findings"]])

    def doctor(self, *extra: str, env: Optional[Dict[str, str]] = None) -> Dict:
        proc = subprocess.run([sys.executable, str(BIN), "doctor", "--project", self.project, "--json", *extra],
                              env=env or self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(proc.stderr, b"")
        doc = json.loads(proc.stdout)
        self.assertEqual(validate_response(doc, SCHEMA), [])
        return doc


class CoexistenceAndDiagnosticsTests(IsolatedTestCase):
    FOREIGN_TOKEN = "nb_secret_token_" + "0123456789abcdef"

    def setUp(self) -> None:
        super().setUp()
        self.claude_home = Path(self.env["HOME"]) / ".claude"
        self.claude_home.mkdir(parents=True)
        self.user_settings = self.claude_home / "settings.json"

    def notchbuddy_settings(self, with_prompt_relay: bool = False) -> Dict:
        # Shaped like other tools' global hooks seen on the owner's Mac (NotchBuddy).
        handler = {"type": "command", "command": f"/Applications/NotchBuddy.app/Contents/MacOS/notchbuddy-hook --token {self.FOREIGN_TOKEN}"}
        hooks = {e: [{"hooks": [dict(handler)]}] for e in ("SessionStart", "UserPromptSubmit", "Stop", "Notification")}
        if with_prompt_relay:
            hooks["Stop"].append({"hooks": [{"type": "command", "command": sys.executable,
                                             "args": [str(BIN), "hook"], "timeout": 10}]})
        return {"permissions": {"allow": ["Bash(ls:*)"]}, "hooks": hooks,
                "enabledPlugins": {"other-plugin@somewhere": True}}

    def write(self, path: Path, data) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        text = data if isinstance(data, str) else json.dumps(data, indent=2)
        path.write_text(text)
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def installed_record(self, install_path: Path) -> None:
        records = {"version": 2, "plugins": {"prompt-relay@prompt-relay": [
            {"scope": "user", "installPath": str(install_path), "version": "0.2.0"}]}}
        self.write(self.claude_home / "plugins" / "installed_plugins.json", records)

    def doctor(self, *extra: str) -> Dict:
        proc = subprocess.run([sys.executable, str(BIN), "doctor", "--project", self.project, "--json", *extra],
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(proc.stderr, b"")
        doc = json.loads(proc.stdout)
        self.assertEqual(validate_response(doc, SCHEMA), [])
        return doc

    def codes(self, doc: Dict) -> List[str]:
        return [f["code"] for f in doc["data"]["findings"]]

    def test_foreign_hooks_are_counted_never_printed_or_changed(self):
        digest = self.write(self.user_settings, self.notchbuddy_settings())
        doc = self.doctor()
        user = doc["data"]["configuration"]["settings"][0]
        self.assertEqual(user["foreign_hooks"], {"Notification": 1, "SessionStart": 1, "Stop": 1, "UserPromptSubmit": 1})
        self.assertEqual(user["prompt_relay_hooks"], [])
        self.assertEqual(user["enabled_plugins"], {}, "other plugins' flags are not reported")
        text = self.cli("doctor", "--project", self.project)
        for out in (json.dumps(doc), text.stdout.decode()):
            self.assertNotIn(self.FOREIGN_TOKEN, out)
            self.assertNotIn("notchbuddy-hook", out)
        self.assertEqual(hashlib.sha256(self.user_settings.read_bytes()).hexdigest(), digest)

    def test_plugin_alongside_foreign_hooks_is_not_double_registration(self):
        self.write(self.user_settings, dict(self.notchbuddy_settings(), enabledPlugins={"prompt-relay@prompt-relay": True}))
        self.installed_record(install_copy(self.tmp / "cache" / "0.2.0"))
        doc = self.doctor()
        self.assertNotIn("double_registration", self.codes(doc))
        self.assertNotIn("not_registered", self.codes(doc))
        rec = doc["data"]["configuration"]["plugin"]["records"][0]
        self.assertEqual((rec["id"], rec["manifest_found"], rec["launcher_found"]), ("prompt-relay@prompt-relay", True, True))

    def test_double_registration_is_reported(self):
        digest = self.write(self.user_settings, self.notchbuddy_settings(with_prompt_relay=True))
        self.installed_record(install_copy(self.tmp / "cache" / "0.2.0"))
        doc = self.doctor()
        self.assertIn("double_registration", self.codes(doc))
        self.assertEqual(doc["data"]["configuration"]["settings"][0]["prompt_relay_hooks"], [{"event": "Stop"}])
        self.assertEqual(hashlib.sha256(self.user_settings.read_bytes()).hexdigest(), digest, "doctor never edits settings")

    def test_settings_registered_in_two_files(self):
        hook = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": str(BIN), "args": ["hook"]}]}]}}
        self.write(self.user_settings, hook)
        self.write(Path(self.project) / ".claude" / "settings.local.json", hook)
        self.assertIn("settings_registered_twice", self.codes(self.doctor()))

    def test_incomplete_install_record(self):
        self.installed_record(self.tmp / "gone")
        self.assertIn("plugin_install_incomplete", self.codes(self.doctor()))

    def test_broken_settings_are_reported_not_touched(self):
        cases = {"invalid": "{not json", "array": "[1, 2]", "huge": None}
        for name, content in cases.items():
            with self.subTest(name):
                if content is None:
                    with open(self.user_settings, "w") as fh:
                        fh.write('{"x": "' + "a" * (6 * 1024 * 1024) + '"}')
                    digest = hashlib.sha256(self.user_settings.read_bytes()).hexdigest()
                else:
                    digest = self.write(self.user_settings, content)
                doc = self.doctor()
                self.assertIn("settings_unreadable", self.codes(doc))
                self.assertEqual(hashlib.sha256(self.user_settings.read_bytes()).hexdigest(), digest)

    def test_doctor_reports_capture_state_and_never_message_text(self):
        marker = "private-answer-" + os.urandom(6).hex()
        self.assertHookOk(self.hook(self.fx("stop_basic.json", last_assistant_message=marker)))
        doc = self.doctor()
        self.assertTrue(doc["data"]["capture"]["project"]["capture_enabled"])
        self.assertEqual(doc["data"]["storage"]["session_files"], 1)
        self.assertEqual(doc["data"]["observed"]["by_via"]["direct"]["events"], 1)
        self.assertNotIn(marker, json.dumps(doc))
        self.assertNotIn(marker, self.cli("doctor").stdout.decode())
        self.cli("disable", self.project)
        doc = self.doctor()
        self.assertIn("project_not_enabled", self.codes(doc))
        self.assertEqual(doc["data"]["storage"]["session_files"], 1, "disabling keeps history")

    def test_doctor_handles_missing_everything(self):
        env = dict(self.env, PROMPT_RELAY_HOME=str(self.tmp / "nothing-here"))
        proc = subprocess.run([sys.executable, str(BIN), "doctor", "--no-project", "--json"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        doc = json.loads(proc.stdout)
        self.assertEqual((proc.returncode, validate_response(doc, SCHEMA)), (0, []))
        self.assertIn("not_registered", self.codes(doc))
        self.assertIn("no_projects_enabled", self.codes(doc))
        self.assertFalse((self.tmp / "nothing-here").exists(), "doctor never creates the data dir")


class PinPythonTests(IsolatedTestCase):
    def test_enable_pins_running_interpreter_once(self):
        # IsolatedTestCase.setUp already ran `enable` twice
        path, state = runtime.read_pin(self.home)
        self.assertEqual((path, state), (sys.executable, runtime.OK))
        other = self.tmp / "other-python"
        other.symlink_to(sys.executable)
        self.assertEqual(self.cli("pin-python", "--python", str(other)).returncode, 0)
        self.cli("enable", self.project)
        self.assertEqual(runtime.read_pin(self.home)[0], str(other), "a valid pin is never overwritten by enable")
        self.assertEqual(oct(os.stat(runtime.pin_path(self.home)).st_mode & 0o777), "0o600")

    def test_pin_python_rejects_bad_interpreters(self):
        fake = self.tmp / "fake"
        fake.write_text("#!/bin/sh\necho 3 8 0\n")
        fake.chmod(0o755)
        for bad in ("relative/python", str(self.tmp / "missing"), str(self.tmp), str(fake)):
            with self.subTest(bad):
                self.assertEqual(self.cli("pin-python", "--python", bad).returncode, 2)
        self.assertEqual(runtime.read_pin(self.home)[0], sys.executable)
        self.assertIn(b"ok: ", self.cli("pin-python", "--show").stdout)
        self.assertEqual(self.cli("pin-python", "--clear").returncode, 0)
        self.assertEqual(runtime.read_pin(self.home), (None, runtime.NOT_SET))


class JsonApiCompatibilityTests(IsolatedTestCase):
    def test_existing_commands_keep_api_v1(self):
        self.assertHookOk(self.hook(self.fx("stop_basic.json")))
        for args in (["sessions"], ["turns"], ["show"], ["projects"], ["retention"]):
            proc = subprocess.run([sys.executable, str(BIN), *args, "--json"], env=self.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            doc = json.loads(proc.stdout)
            self.assertEqual((doc["api_version"], doc["ok"]), (1, True))
            self.assertEqual(validate_response(doc, SCHEMA), [])


if __name__ == "__main__":
    unittest.main()
