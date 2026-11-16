import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ConfigureTests(unittest.TestCase):
    def test_preview_apply_repeat_and_disable_preserve_foreign_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'hooks.json'
            foreign = {'hooks': [{'type': 'command', 'command': 'echo foreign'}], 'matcher': 'Bash'}
            original = {'hooks': {'PostToolUse': [foreign]}, 'description': 'keep me'}
            path.write_text(json.dumps(original))
            command = [sys.executable, str(Path(__file__).with_name('configure-codex.py')), '--config', str(path), '--host', 'unknown']
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(json.loads(path.read_text()), original)
            for _ in range(2):
                subprocess.run(command + ['--apply'], check=True, capture_output=True)
                saved = json.loads(path.read_text())
                self.assertEqual(len(saved['hooks']['Stop']), 1)
                self.assertIn(foreign, saved['hooks']['PostToolUse'])
            subprocess.run(command + ['--disable', '--apply'], check=True, capture_output=True)
            saved = json.loads(path.read_text())
            self.assertEqual(saved['hooks']['Stop'], [])
            self.assertEqual(saved['hooks']['PostToolUse'], [foreign])
            self.assertEqual(saved['description'], 'keep me')
            backups = sorted(Path(directory).glob('hooks.json.prompt-relay-backup-*'))
            self.assertEqual(len(backups), 3)
            self.assertEqual(json.loads(backups[0].read_text()), original)


if __name__ == '__main__':
    unittest.main()
