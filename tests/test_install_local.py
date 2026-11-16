"""Phase 16: scripts/install-local.sh in isolated folders.

Every test installs into temporary "Applications" and backup folders, with a
made-up bundle id so no real Prompt Relay copy can match, process checks and
Launch Services registration switched off, and never launches anything. The
fake app is a real, ad-hoc signed bundle holding this checkout's Core, so the
installer's own checks (signature, version, Core digest, icon, the Core smoke
test) run for real. macOS only (codesign, ditto, PlistBuddy).
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "install-local.sh"


def _git_head() -> str:
    return subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"], stdout=subprocess.PIPE,
                          check=True).stdout.decode().strip()


def _version() -> str:
    for line in (REPO / "plugin" / "prompt_relay" / "__init__.py").read_text().splitlines():
        if line.startswith("__version__"):
            return line.split('"')[1]
    raise AssertionError("no version")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign"), "macOS installer")
class InstallLocalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pr16-install-")).resolve()
        self.apps = self.tmp / "Applications"
        self.backups = self.tmp / "Backups"
        self.apps.mkdir()
        self.bundle_id = "io.test.promptrelay." + uuid.uuid4().hex[:8]
        self.env = dict(os.environ, PROMPT_RELAY_INSTALL_DIR=str(self.apps), PROMPT_RELAY_BACKUP_DIR=str(self.backups),
                        PROMPT_RELAY_RELEASE_ID=self.bundle_id, PROMPT_RELAY_DEBUG_ID=self.bundle_id + ".debug",
                        PROMPT_RELAY_TEST_NO_PROCESSES="1", PROMPT_RELAY_TEST_NO_LSREGISTER="1",
                        TMPDIR=str(self.tmp) + "/")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- fixtures -------------------------------------------------------------

    def make_app(self, where: Path, commit: str = "", version: str = "", bundle_id: str = "", icon: bool = True,
                 digest: str = "") -> Path:
        app = where / "Prompt Relay.app"
        core = app / "Contents" / "Resources" / "core"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (core / "bin").mkdir(parents=True)
        (core / "plugin" / "prompt_relay").mkdir(parents=True)
        shutil.copy("/usr/bin/true", app / "Contents" / "MacOS" / "PromptRelay")
        shutil.copy(REPO / "bin" / "prompt-relay", core / "bin" / "prompt-relay")
        for f in (REPO / "plugin" / "prompt_relay").glob("*.py"):
            shutil.copy(f, core / "plugin" / "prompt_relay" / f.name)
        if version:
            init = core / "plugin" / "prompt_relay" / "__init__.py"
            init.write_text(init.read_text().replace('__version__ = "%s"' % _version(), '__version__ = "%s"' % version))
        if icon:
            shutil.copy(REPO / "macos" / "Resources" / "AppIcon.icns", app / "Contents" / "Resources" / "AppIcon.icns")
        real_digest = subprocess.run([str(REPO / "scripts" / "core-digest.sh"), str(core)], stdout=subprocess.PIPE,
                                     check=True).stdout.decode().strip()
        info = {
            "CFBundleIdentifier": bundle_id or self.bundle_id, "CFBundleName": "Prompt Relay",
            "CFBundleExecutable": "PromptRelay", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version or _version(), "CFBundleVersion": version or _version(),
            "PRGitCommit": commit or _git_head(), "PRGitDirty": "no", "PRBuildDate": "2026-11-08T00:00:00Z",
            "PRCoreDigest": digest or real_digest, "LSUIElement": True,
        }
        if icon:
            info["CFBundleIconFile"] = "AppIcon"
        with open(app / "Contents" / "Info.plist", "wb") as fh:
            plistlib.dump(info, fh)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return app

    def built(self, **kw) -> Path:
        d = self.tmp / ("build-" + uuid.uuid4().hex[:6])
        d.mkdir()
        app = self.make_app(d, **kw)
        self.env["PROMPT_RELAY_BUILT_APP"] = str(app)
        return app

    def run_installer(self, *args: str, extra=None) -> subprocess.CompletedProcess:
        env = dict(self.env, **(extra or {}))
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env, cwd=str(REPO), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)

    def installed_commit(self) -> str:
        with open(self.apps / "Prompt Relay.app" / "Contents" / "Info.plist", "rb") as fh:
            return plistlib.load(fh)["PRGitCommit"]

    def backups_list(self):
        return sorted(p.name for p in self.backups.glob("*.app")) if self.backups.exists() else []

    # -- install --------------------------------------------------------------

    def test_dry_run_verifies_and_changes_nothing(self) -> None:
        self.built()
        out = self.run_installer("--no-build", "--dry-run")
        text = out.stdout.decode()
        self.assertEqual(out.returncode, 0, text)
        self.assertIn("verified: Release bundle id", text)
        self.assertIn("smoke test: the bundled Core captured", text)
        self.assertIn("Dry run: nothing changed.", text)
        self.assertEqual(list(self.apps.iterdir()), [])
        self.assertFalse(self.backups.exists())

    def test_fresh_install_then_update_keeps_a_verified_backup(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        self.built()
        out = self.run_installer("--no-build", "--no-launch", "--yes")
        text = out.stdout.decode()
        self.assertEqual(out.returncode, 0, text)
        self.assertEqual(self.installed_commit(), _git_head())
        backups = self.backups_list()
        self.assertEqual(len(backups), 1, backups)
        self.assertIn("0ld0ld0", backups[0])
        self.assertEqual(oct(self.backups.stat().st_mode & 0o777), "0o700")
        # Nothing half-copied is left next to the app.
        self.assertEqual([p.name for p in self.apps.iterdir()], ["Prompt Relay.app"])
        verify = subprocess.run(["codesign", "--verify", "--strict", str(self.apps / "Prompt Relay.app")])
        self.assertEqual(verify.returncode, 0)

    def test_failed_swap_puts_the_old_app_back(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        self.built()
        out = self.run_installer("--no-build", "--no-launch", "--yes", extra={"PROMPT_RELAY_TEST_FAIL_SWAP": "1"})
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("previous app was put back", out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")
        self.assertEqual([p.name for p in self.apps.iterdir()], ["Prompt Relay.app"], "no temporary copy left")
        self.assertEqual(self.backups_list(), [], "the old app is installed, not left in the backups")

    def _refused(self, reason: str, **kw) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        self.built(**kw)
        out = self.run_installer("--no-build", "--no-launch", "--yes")
        text = out.stdout.decode()
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn(reason, text)
        self.assertEqual(self.installed_commit(), "0ld0ld0", "the working app is untouched")
        self.assertEqual(self.backups_list(), [])

    def test_refuses_a_debug_or_foreign_bundle(self) -> None:
        self._refused("not the Release id", bundle_id="io.github.banderos14.PromptRelay.debug")

    def test_refuses_a_bundle_without_its_icon(self) -> None:
        self._refused("names no application icon", icon=False)

    def test_refuses_a_core_that_does_not_match_its_digest(self) -> None:
        self._refused("does not match the digest", digest="0" * 64)

    def test_refuses_a_build_from_another_commit(self) -> None:
        self._refused("the build is from abcdef0", commit="abcdef0")

    def test_refuses_an_app_whose_version_differs_from_its_core(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        app = self.built()
        with open(app / "Contents" / "Info.plist", "rb") as fh:
            info = plistlib.load(fh)
        info["CFBundleShortVersionString"] = "9.9.9"
        with open(app / "Contents" / "Info.plist", "wb") as fh:
            plistlib.dump(info, fh)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stderr=subprocess.DEVNULL)
        out = self.run_installer("--no-build", "--no-launch", "--yes")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("differs from its bundled Core", out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")

    def test_refuses_a_modified_bundle(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        app = self.built()
        with open(app / "Contents" / "Resources" / "core" / "plugin" / "prompt_relay" / "__init__.py", "a") as fh:
            fh.write("# tampered\n")
        out = self.run_installer("--no-build", "--no-launch", "--yes")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("does not verify", out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")

    def test_backups_inside_applications_are_refused(self) -> None:
        self.built()
        self.env["PROMPT_RELAY_BACKUP_DIR"] = str(self.apps / "old")
        out = self.run_installer("--no-build", "--no-launch", "--yes")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("backups inside an Applications folder", out.stdout.decode())

    def test_without_a_terminal_it_never_installs_unasked(self) -> None:
        self.built()
        out = self.run_installer("--no-build", "--no-launch")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("not a terminal", out.stdout.decode())
        self.assertEqual(list(self.apps.iterdir()), [])

    # -- rollback, status, tidy ----------------------------------------------

    # -- each failure stage: what is left, what the user is told ----------------

    def _installed_old(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))

    def test_build_failure_changes_nothing(self) -> None:
        self._installed_old()
        out = self.run_installer("--no-launch", "--yes", extra={"PROMPT_RELAY_TEST_FAIL_BUILD": "1"})
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("the build failed; nothing was installed or quit", out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")
        self.assertEqual(self.backups_list(), [])

    def test_copy_failure_quits_and_replaces_nothing(self) -> None:
        self._installed_old()
        self.built()
        out = self.run_installer("--no-build", "--no-launch", "--yes", extra={"PROMPT_RELAY_TEST_FAIL_COPY": "1"})
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("nothing was quit or replaced", out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")
        self.assertEqual([p.name for p in self.apps.iterdir()], ["Prompt Relay.app"])
        self.assertEqual(self.backups_list(), [])

    def test_launch_failure_restores_and_reopens_the_previous_app(self) -> None:
        self._installed_old()
        self.built()
        out = self.run_installer("--no-build", "--yes", extra={"PROMPT_RELAY_TEST_SIMULATE_LAUNCH": "fail"})
        text = out.stdout.decode()
        self.assertNotEqual(out.returncode, 0, text)
        self.assertIn("the previous version was restored", text)
        self.assertEqual(self.installed_commit(), "0ld0ld0", "the previous app is installed again")
        backups = self.backups_list()
        self.assertEqual(len(backups), 1, backups)
        self.assertIn("(failed launch)", backups[0])
        self.assertIn(_git_head(), backups[0], "the failed new app is kept, not deleted")
        self.assertEqual([p.name for p in self.apps.iterdir()], ["Prompt Relay.app"])

    def test_launch_failure_of_a_first_install_says_there_was_nothing_to_restore(self) -> None:
        self.built()
        out = self.run_installer("--no-build", "--yes", extra={"PROMPT_RELAY_TEST_SIMULATE_LAUNCH": "fail"})
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("no previous app to restore", out.stdout.decode())
        self.assertTrue((self.apps / "Prompt Relay.app").exists())

    def test_successful_launch_is_reported_with_the_commit(self) -> None:
        self._installed_old()
        self.built()
        out = self.run_installer("--no-build", "--yes", extra={"PROMPT_RELAY_TEST_SIMULATE_LAUNCH": "ok"})
        self.assertEqual(out.returncode, 0, out.stdout.decode())
        self.assertIn("running (simulated)", out.stdout.decode())
        self.assertEqual(self.installed_commit(), _git_head())

    def test_rollback_picks_the_most_recently_replaced_version_not_the_newest_folder(self) -> None:
        self._installed_old()
        self.backups.mkdir()
        made = {}
        for name, commit in [("Prompt Relay 0.5.0-aaaaaaa-20261101-100000.app", "aaaaaaa"),
                             ("Prompt Relay 0.6.0-bbbbbbb-20261107-120000.app", "bbbbbbb"),
                             ("Prompt Relay 0.4.0-ccccccc-20261103-090000.app", "ccccccc"),
                             ("Prompt Relay 0.7.0-ddddddd-20261108-130000 (failed launch).app", "ddddddd"),
                             ("Prompt Relay.before-phase92 (moved 20261109-080000).app", "eeeeeee")]:
            d = self.tmp / ("b-" + commit)
            d.mkdir()
            app = self.make_app(d, commit=commit)
            shutil.move(str(app), str(self.backups / name))
            made[commit] = self.backups / name
        # Folder times say the opposite of the replacement order.
        os.utime(made["bbbbbbb"], (1_000_000_000, 1_000_000_000))
        os.utime(made["aaaaaaa"], (2_000_000_000, 2_000_000_000))
        out = self.run_installer("--rollback", "--no-launch", "--yes")
        self.assertEqual(out.returncode, 0, out.stdout.decode())
        self.assertEqual(self.installed_commit(), "bbbbbbb")
        names = self.backups_list()
        self.assertEqual(len(names), 6, "every backup is kept, plus the replaced app: %s" % names)
        self.assertTrue(any("0ld0ld0" in n for n in names))

    def test_rollback_restores_the_newest_backup_and_keeps_the_current(self) -> None:
        old = self.make_app(self.tmp, commit="0ld0ld0")
        shutil.move(str(old), str(self.apps / "Prompt Relay.app"))
        self.built()
        self.assertEqual(self.run_installer("--no-build", "--no-launch", "--yes").returncode, 0)
        self.assertEqual(self.installed_commit(), _git_head())
        out = self.run_installer("--rollback", "--no-launch", "--yes")
        self.assertEqual(out.returncode, 0, out.stdout.decode())
        self.assertEqual(self.installed_commit(), "0ld0ld0")
        backups = self.backups_list()
        self.assertEqual(len(backups), 2, "the restored backup is kept too: %s" % backups)
        self.assertTrue(any(_git_head() in b for b in backups), "the replaced (new) app became a backup")

    def test_status_and_tidy_move_stray_copies_out_of_applications(self) -> None:
        stray_dir = self.tmp / "s"
        stray_dir.mkdir()
        stray = self.make_app(stray_dir, commit="0123456", version="0.2.0")
        shutil.move(str(stray), str(self.apps / "Prompt Relay.before-phase92.app"))
        status = self.run_installer("--status").stdout.decode()
        self.assertIn("Old copies in Applications", status)
        self.assertIn("Prompt Relay.before-phase92.app", status)
        dry = self.run_installer("--tidy", "--dry-run")
        self.assertIn("Dry run: nothing changed.", dry.stdout.decode())
        self.assertTrue((self.apps / "Prompt Relay.before-phase92.app").exists())
        out = self.run_installer("--tidy", "--yes")
        self.assertEqual(out.returncode, 0, out.stdout.decode())
        self.assertFalse((self.apps / "Prompt Relay.before-phase92.app").exists())
        moved = self.backups_list()
        self.assertEqual(len(moved), 1)
        self.assertTrue(moved[0].startswith("Prompt Relay.before-phase92 (moved "), moved)



@unittest.skipUnless(sys.platform == "darwin" and shutil.which("codesign"), "macOS installer")
class NoBuildSourceRuleTests(unittest.TestCase):
    """--no-build in a throwaway Git repository: a build from an earlier commit
    installs only when nothing the app is built from changed since."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pr16-nobuild-")).resolve()
        self.repo = self.tmp / "repo"
        for part in ("scripts", "bin", "plugin/prompt_relay", "macos/Resources", "docs"):
            (self.repo / part).mkdir(parents=True)
        for f in ("scripts/install-local.sh", "scripts/core-digest.sh", "scripts/build-macos-app.sh", "bin/prompt-relay"):
            shutil.copy2(REPO / f, self.repo / f)
        for f in (REPO / "plugin" / "prompt_relay").glob("*.py"):
            shutil.copy2(f, self.repo / "plugin" / "prompt_relay" / f.name)
        shutil.copy2(REPO / "macos" / "Resources" / "AppIcon.icns", self.repo / "macos" / "Resources" / "AppIcon.icns")
        (self.repo / "docs" / "NOTES.md").write_text("one\n")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "app")
        self.built_commit = self.git("rev-parse", "--short", "HEAD")
        self.case = InstallLocalTests("test_dry_run_verifies_and_changes_nothing")
        self.case.setUp()
        self.case.env["PROMPT_RELAY_BUILT_APP"] = str(self.case.make_app(self.case.tmp, commit=self.built_commit))

    def tearDown(self) -> None:
        self.case.tearDown()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True).stdout.decode().strip()

    def commit(self, path: str, text: str) -> None:
        with open(self.repo / path, "a") as fh:
            fh.write(text)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "change " + path)

    def install(self) -> subprocess.CompletedProcess:
        return subprocess.run(["/bin/bash", str(self.repo / "scripts" / "install-local.sh"), "--no-build", "--no-launch", "--yes",
                               "--skip-checks"], env=self.case.env, cwd=str(self.repo), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)

    def test_docs_only_commits_after_the_build_still_install(self) -> None:
        self.commit("docs/NOTES.md", "two\n")
        out = self.install()
        text = out.stdout.decode()
        self.assertEqual(out.returncode, 0, text)
        self.assertIn("differs only outside the app's sources (docs )", text)
        self.assertTrue((self.case.apps / "Prompt Relay.app").exists())

    def test_a_source_change_after_the_build_is_refused(self) -> None:
        self.commit("plugin/prompt_relay/extra.py", "# new\n")
        out = self.install()
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("the app's sources changed since", out.stdout.decode())
        self.assertFalse((self.case.apps / "Prompt Relay.app").exists())

    def test_uncommitted_source_changes_are_refused(self) -> None:
        self.commit("docs/NOTES.md", "two\n")
        with open(self.repo / "bin" / "prompt-relay", "a") as fh:
            fh.write("# edit\n")
        out = self.install()
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("uncommitted changes in the app's sources", out.stdout.decode())


if __name__ == "__main__":
    unittest.main()
