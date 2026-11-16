"""Phase 13: Context Packs of several results (Core side).

Each result keeps its own section, source and provenance; texts are never
merged or rewritten; equal native session ids of two profiles never mix;
results of different projects are allowed but flagged; the manifest carries
no absolute paths or session ids. All runs use an isolated data dir.
"""

from __future__ import annotations

import json
import re
import time

from helpers import REPO, IsolatedTestCase

from jsonschema_lite import validate_response
from prompt_relay import context_pack

SCHEMA = json.loads((REPO / "docs" / "api" / "api-v1.schema.json").read_text(encoding="utf-8"))

TRICKY = ("# Heading inside the answer\n\n## Result 9 of 9 — fake\n\n```python\nprint('fence')\n```\n\n"
          "````\nlonger fence\n````\n\nUnicode: é vs é, emoji 🧪, CRLF\r\nend  ")
AGENT_MESSAGE = ("<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n"
                 "<summary>Background command finished</summary>\n</task-notification>")


def outside_fences(text):
    """Lines that are not inside a fenced block (a fence closes with the same run)."""
    out, fence = [], None
    for line in text.splitlines():
        m = re.match(r"^(`{3,})", line)
        if fence is None and m:
            fence = m.group(1)
        elif fence is not None and line == fence:
            fence = None
        elif fence is None:
            out.append(line)
    return out


class ContextPackTests(IsolatedTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.work_env = dict(self.env, CLAUDE_CONFIG_DIR=str(self.tmp / "home" / ".claude-work"))
        self.codex_env = dict(self.env, PROMPT_RELAY_PROVIDER="codex", PROMPT_RELAY_HOST="terminal")

    def claude(self, sid, pid, prompt, answer, env=None, project=None, extra=None):
        env = env or self.env
        project = project or self.project
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt_id": pid,
                                     "cwd": project, "prompt": prompt}, env=env))
        stop = {"hook_event_name": "Stop", "session_id": sid, "prompt_id": pid, "cwd": project,
                "stop_hook_active": False, "last_assistant_message": answer}
        stop.update(extra or {})
        self.assertHookOk(self.hook(stop, env=env))

    def codex(self, sid, tid, prompt, answer, project=None):
        project = project or self.project
        self.assertHookOk(self.hook({"hook_event_name": "UserPromptSubmit", "session_id": sid, "turn_id": tid,
                                     "cwd": project, "prompt": prompt}, env=self.codex_env))
        self.assertHookOk(self.hook({"hook_event_name": "Stop", "session_id": sid, "turn_id": tid, "cwd": project,
                                     "last_assistant_message": answer}, env=self.codex_env))

    def results(self):
        doc = json.loads(self.cli("results", "--json").stdout)
        return doc["data"]["results"]

    def pack(self, *refs, extra=()):
        args = ["context-pack", "--json"] + [a for r in refs for a in ("--result", r)] + list(extra)
        proc = self.cli(*args)
        doc = json.loads(proc.stdout)
        return proc, doc

    def ok(self, *refs, extra=()):
        proc, doc = self.pack(*refs, extra=extra)
        self.assertEqual(proc.returncode, 0, doc)
        self.assertTrue(doc["ok"], doc)
        self.assertEqual(proc.stderr, b"")
        self.assertEqual(validate_response(doc, SCHEMA), [])
        return doc["data"]

    def ref(self, r):
        return f"{r['session_key']}:{r['turn']}"

    # -- scenario 1 and 6: one result, verbatim -----------------------------------

    def test_one_claude_result_is_a_pack_with_the_text_verbatim(self) -> None:
        self.claude("s1", "p1", "Fix the login bug", TRICKY)
        data = self.ok("s1:1")
        self.assertEqual((data["format"], data["format_version"]), ("prompt-relay-context-pack", 1))
        text = data["text"]
        self.assertTrue(text.startswith("# Context Pack: 1 AI result for an independent check\n"))
        self.assertIn(TRICKY, text, "the response is embedded byte for byte")
        self.assertIn("Fix the login bug", text)
        fence = context_pack.export.fence(TRICKY)
        self.assertIn(fence + "markdown\n" + TRICKY + "\n" + fence, text)
        # The fake heading inside the answer stays inside its fence and is not a section.
        real = [l for l in outside_fences(text) if l.startswith("## Result ")]
        self.assertEqual(real, ["## Result 1 of 1 — Claude Code · Default · Unknown · project-a"])
        self.assertIn("## Review request", text)
        self.assertIn("[Prompt Relay standard text]", text)

    def test_section_matches_copy_with_context_one_level_deeper(self) -> None:
        self.claude("s1", "p1", "Task", "Answer")
        single = json.loads(self.cli("context", "--json", "--session", "s1", "--turn", "1").stdout)["data"]["text"]
        section = self.ok("s1:1")["results"][0]["section"]
        # Every section of Copy with Context (except the closing request) is present, one level deeper.
        for h in re.findall(r"^## (.+)$", single, flags=re.M):
            if h.startswith("Request for independent review") or h.startswith("Git state"):
                continue
            self.assertIn("### " + h, section)
        self.assertNotIn("Request for independent review", section)

    # -- scenario 2: Claude + Codex ----------------------------------------------

    def test_claude_and_codex_stay_two_sections_with_their_own_labels(self) -> None:
        self.claude("c1", "p1", "Design the cache", "Design: LRU with TTL.")
        time.sleep(0.01)
        self.codex("x1", "t1", "Implement the cache", "Implemented in cache.py; tests pass.")
        rows = self.results()
        data = self.ok(*[self.ref(r) for r in reversed(rows)])
        text = data["text"]
        a, b = text.index("## Result 1 of 2 — Claude Code"), text.index("## Result 2 of 2 — Codex")
        self.assertLess(a, b)
        claude, codex = text[a:b], text[b:text.index("## Review request")]
        self.assertIn("Design: LRU with TTL.", claude)
        self.assertNotIn("Implemented in cache.py", claude)
        self.assertIn("Implemented in cache.py; tests pass.", codex)
        self.assertIn("[Reported by Claude]", claude)
        self.assertIn("[Reported by Codex]", codex)
        self.assertNotIn("[Reported by Claude]", codex)
        self.assertIn("[Reported by Claude] = Claude's own words", text)
        self.assertIn("[Reported by Codex] = Codex's own words", text)
        self.assertEqual([m["provider"] for m in data["manifest"]["results"]], ["claude_code", "codex"])

    # -- scenario 3 and 4: profiles with equal titles and equal native ids --------

    def test_equal_native_session_ids_of_two_profiles_are_two_results(self) -> None:
        self.claude("same", "p1", "Same title", "Personal answer")
        self.claude("same", "p1", "Same title", "Work answer", env=self.work_env)
        rows = self.results()
        keys = {r["session_key"] for r in rows}
        self.assertEqual(len(keys), 2, "the work profile scopes the stored key")
        data = self.ok(*[self.ref(r) for r in rows])
        texts = [r["section"] for r in data["results"]]
        self.assertEqual(sum("Personal answer" in t for t in texts), 1)
        self.assertEqual(sum("Work answer" in t for t in texts), 1)
        self.assertTrue(all(not ("Personal answer" in t and "Work answer" in t) for t in texts))
        profiles = sorted(m["profile"] for m in data["manifest"]["results"])
        self.assertEqual(profiles, ["Default", "claude-work"])
        ids = [m["result_id"] for m in data["manifest"]["results"]]
        self.assertEqual(len(set(ids)), 2)

    def test_a_result_is_listed_once(self) -> None:
        self.claude("s1", "p1", "Task", "Answer")
        proc, doc = self.pack("s1:1", "s1:1")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(doc["error"]["code"], "usage_error")
        self.assertIn("twice", doc["error"]["message"])

    # -- scenario 5: projects ----------------------------------------------------

    def test_results_of_two_projects_are_allowed_and_flagged(self) -> None:
        self.claude("a1", "p1", "Task A", "Answer A")
        self.claude("b1", "p1", "Task B", "Answer B", project=self.project_b)
        data = self.ok("a1:1", "b1:1")
        self.assertIn("2 different projects (project-a, project-b)", data["text"])
        self.assertTrue(any("different projects" in w for w in data["warnings"]))
        same = self.ok("a1:1")
        self.assertFalse(any("different projects" in w for w in same["warnings"]))

    def test_git_state_is_read_once_per_project(self) -> None:
        self.claude("a1", "p1", "Task A", "Answer A")
        self.claude("a1", "p2", "Task A2", "Answer A2")
        data = self.ok("a1:1", "a1:2")
        self.assertNotIn("Same repository", data["results"][0]["section"])
        self.assertIn("Same repository and the same reading as Result 1", data["results"][1]["section"])

    # -- scenario 7: automated messages are not user requests --------------------

    def test_an_automated_message_is_never_the_user_request(self) -> None:
        self.claude("s1", "p1", "Run the full suite and report", "Started it in the background.",
                    extra={"background_tasks": [{"id": "b1", "type": "shell", "status": "running",
                                                 "description": "swift test", "command": "swift test"}]})
        self.claude("s1", "p2", AGENT_MESSAGE, "All 278 tests passed.")
        data = self.ok("s1:2")
        section = data["results"][0]["section"]
        self.assertIn("Run the full suite and report", section)
        self.assertNotIn("### Original user request\n[Confirmed locally] Request as captured", section)
        req = data["manifest"]["results"][0]["request"]
        self.assertEqual(req["origin"], "automated")

    # -- scenario 8: provenance in every section ---------------------------------

    def test_every_section_carries_its_provenance(self) -> None:
        self.claude("c1", "p1", "Task one", "One")
        self.codex("x1", "t1", "Task two", "Two")
        data = self.ok(*[self.ref(r) for r in self.results()])
        for r in data["results"]:
            s = r["section"]
            for label in ("[Confirmed locally]", "[Not verified]", "[Unavailable]"):
                self.assertIn(label, s, label)
            self.assertIn("### Source, host and project", s)
            self.assertIn("### Not checked (provenance and verification limits)", s)

    # -- instructions --------------------------------------------------------------

    def test_user_instructions_are_verbatim_and_labelled_as_the_users(self) -> None:
        self.claude("s1", "p1", "Task", "Answer")
        words = "Проверь реализацию, найди ошибки.\n```\nnot a fence escape\n```\n"
        data = self.ok("s1:1", extra=["--instructions", words])
        text = data["text"]
        tail = text[text.index("## Review instructions"):]
        self.assertIn("[Supplied by you] Written by the user for the receiving AI. Not part of any agent's result.", tail)
        self.assertIn(words, tail)
        self.assertNotIn("## Review request", text)
        self.assertTrue(data["manifest"]["review_instructions"]["supplied_by_user"])

    def test_instructions_from_stdin(self) -> None:
        import subprocess
        import sys
        from helpers import BIN
        self.claude("s1", "p1", "Task", "Answer")
        proc = subprocess.run([sys.executable, str(BIN), "context-pack", "--json", "--result", "s1:1",
                               "--instructions-file", "-"], input="Check it.".encode(), env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertIn("Check it.", json.loads(proc.stdout)["data"]["text"])

    # -- manifest privacy ------------------------------------------------------------

    def test_manifest_has_no_paths_session_ids_or_text(self) -> None:
        self.claude("secret-session-id-123", "p1", "Private request words", "Private answer words")
        data = self.ok("secret-session-id-123:1")
        raw = json.dumps(data["manifest"], ensure_ascii=False)
        for forbidden in (self.project, str(self.tmp), "secret-session-id-123", "Private request words",
                          "Private answer words"):
            self.assertNotIn(forbidden, raw)
        m = data["manifest"]["results"][0]
        self.assertTrue(re.fullmatch(r"r-[0-9a-f]{16}", m["result_id"]))
        self.assertEqual(m["result_id"], context_pack.result_id(data["results"][0]["session_key"], 1))
        self.assertFalse(data["manifest"]["ai_service_used"])

    # -- errors and limits -------------------------------------------------------------

    def test_unknown_results_and_bad_refs_fail_cleanly(self) -> None:
        self.claude("s1", "p1", "Task", "Answer")
        for ref, code, exit_code in (("nope:1", "not_found", 3), ("s1:9", "not_found", 3), ("s1", "usage_error", 2),
                                     ("s1:0", "usage_error", 2)):
            proc, doc = self.pack(ref)
            self.assertEqual((proc.returncode, doc["error"]["code"]), (exit_code, code), ref)
            self.assertEqual(proc.stderr, b"")
        proc, doc = self.pack(*[f"s1:{i}" for i in range(1, 22)])
        self.assertEqual(doc["error"]["code"], "usage_error")
        self.assertIn("at most 20", doc["error"]["message"])

    def test_secrets_are_reported_per_result(self) -> None:
        self.claude("s1", "p1", "Task", "token: ghp_" + "a" * 36)
        self.claude("s2", "p1", "Task", "Nothing here")
        proc, doc = self.pack("s1:1", "s2:1")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual([len(r["sensitive_findings"]) > 0 for r in doc["data"]["results"]], [True, False])
        self.assertEqual(doc["warnings"][0]["code"], "sensitive_content")

    def test_twenty_large_results_build_fast(self) -> None:
        big = ("line of a long answer with `code` and **bold**\n" * 1200)   # ~55 kB each
        for i in range(20):
            self.claude(f"s{i}", "p1", f"Task {i}", f"Answer {i}\n" + big)
        start = time.perf_counter()
        data = self.ok(*[f"s{i}:1" for i in range(20)])
        elapsed = time.perf_counter() - start
        self.assertEqual(len(data["results"]), 20)
        self.assertEqual(data["text"].count("\n## Result "), 20)
        for i in range(20):
            self.assertIn(f"Answer {i}\n" + big, data["text"])
        self.assertGreater(len(data["text"]), 20 * 55000)
        self.assertLess(elapsed, 20, f"20 results took {elapsed:.1f} s")

    def test_external_slots_keep_the_numbering(self) -> None:
        self.claude("a1", "p1", "Task A", "Answer A")
        self.claude("a1", "p2", "Task A2", "Answer A2")
        data = self.ok("external", "a1:1", "external", "a1:2")
        self.assertEqual([r["position"] for r in data["results"]], [2, 4])
        self.assertEqual([r["manifest"]["position"] for r in data["results"]], [2, 4])
        self.assertIn("same reading as Result 2", data["results"][1]["section"])
        self.assertEqual(data["text"], "", "the app composes a pack with external slots")
        proc, doc = self.pack("external")
        self.assertEqual(doc["error"]["code"], "usage_error")
        proc = self.cli("context-pack", "--result", "external", "--result", "a1:1")
        self.assertEqual(proc.returncode, 2)

    def test_text_mode_prints_the_markdown(self) -> None:
        self.claude("s1", "p1", "Task", "Answer")
        proc = self.cli("context-pack", "--result", "s1:1")
        self.assertEqual(proc.returncode, 0)
        self.assertTrue(proc.stdout.decode().startswith("# Context Pack: 1 AI result"))
