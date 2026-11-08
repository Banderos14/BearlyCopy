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
        self.assertEqual(len(backups), 1, backups)
        self.assertIn(_git_head(), backups[0], "the replaced (new) app became the backup")

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


if __name__ == "__main__":
    unittest.main()
