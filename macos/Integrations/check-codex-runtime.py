#!/usr/bin/env python3
"""Read-only protocol probe in an isolated Codex home. Never starts an AI turn.
This does NOT test capture from an existing Xcode/CLI session.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='relay-probe-') as temporary:
        env = dict(os.environ, CODEX_HOME=temporary)
        process = subprocess.Popen([str(args.binary), 'app-server'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   cwd=temporary, env=env, text=True)
        messages = queue.Queue()
        def read():
            for line in process.stdout:
                try: messages.put(json.loads(line))
                except ValueError: pass
        threading.Thread(target=read, daemon=True).start()
        def send(value):
            process.stdin.write(json.dumps(value) + '\n')
            process.stdin.flush()
        result = {'isolated_home': True, 'ai_turn_started': False, 'existing_session_capture_verified': False}
        try:
            send({'id':1, 'method':'initialize', 'params':{'clientInfo':{'name':'prompt_relay_probe', 'version':'0.1'}, 'capabilities':{'experimentalApi':True}}})
            deadline = time.monotonic() + 20
            pending = {1}
            while pending and time.monotonic() < deadline:
                try: message = messages.get(timeout=1)
                except queue.Empty: continue
                identifier = message.get('id')
                if identifier not in pending: continue
                pending.remove(identifier)
                if identifier == 1:
                    result['initialized'] = 'result' in message
                    send({'method':'initialized'})
                    send({'id':2, 'method':'hooks/list', 'params':{'cwds':[temporary]}})
                    send({'id':3, 'method':'thread/loaded/list', 'params':{}})
                    pending.update([2,3])
                elif identifier == 2:
                    result['hooks_list_supported'] = 'result' in message
                    if 'error' in message: result['hooks_error'] = message['error']
                elif identifier == 3:
                    result['loaded_threads'] = len(message.get('result', {}).get('data', []))
            result['timed_out_requests'] = sorted(pending)
            print(json.dumps(result, indent=2))
        finally:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
