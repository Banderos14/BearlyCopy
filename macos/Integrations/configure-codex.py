#!/usr/bin/env python3
"""Preview a scoped Codex hook configuration; apply only with --apply.
No agent task is started. Existing hooks are preserved, backups never overwritten.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shlex


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='Explicit hooks.json path')
    parser.add_argument('--host', choices=['xcode', 'terminal', 'vscode', 'unknown'], required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--disable', action='store_true')
    args = parser.parse_args()
    target = args.config.expanduser().absolute()
    if target.name != 'hooks.json' or target.is_symlink():
        parser.error('Choose a regular hooks.json file')
    before = target.read_bytes() if target.exists() else b'{}'
    config = json.loads(before)
    root = Path(__file__).resolve().parents[2]
    launcher = root / 'plugin/hooks/run-hook'
    command = 'env PROMPT_RELAY_PROVIDER=codex PROMPT_RELAY_HOST=' + args.host + ' /bin/sh ' + shlex.quote(str(launcher))
    groups = config.setdefault('hooks', {})
    for event in ('UserPromptSubmit', 'Stop', 'PostToolUse'):
        rows = groups.setdefault(event, [])
        for row in rows:
            row['hooks'] = [h for h in row.get('hooks', []) if not (
                h.get('type') == 'command' and 'PROMPT_RELAY_PROVIDER=codex' in h.get('command', '')
                and str(launcher) in h.get('command', ''))]
        rows[:] = [r for r in rows if r.get('hooks')]
        if not args.disable:
            rows.append({'hooks': [{'type': 'command', 'command': command, 'timeout': 5}]})
    output = (json.dumps(config, indent=2) + '\n').encode()
    # Print only our changes, never unrelated hook commands or credentials.
    print(json.dumps({'file': str(target), 'action': 'disable' if args.disable else 'enable',
                      'events': ['UserPromptSubmit', 'Stop', 'PostToolUse'], 'command': command}, indent=2))
    if not args.apply:
        print('Preview only. Review, then repeat with --apply. Trust hooks in your Codex client before use.')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')
    if target.exists():
        backup = target.with_name('hooks.json.prompt-relay-backup-' + stamp)
        fd = os.open(str(backup), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as f: f.write(before)
    temp = target.with_name('.prompt-relay-hooks-' + stamp)
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f: f.write(output)
    if target.exists() and target.read_bytes() != before:
        temp.unlink()
        raise RuntimeError('Configuration changed since preview; retry')
    os.replace(temp, target)
    print('Saved. Capture still requires enabling this project in BearlyCopy. Disable with --disable --apply.')


if __name__ == '__main__':
    main()
