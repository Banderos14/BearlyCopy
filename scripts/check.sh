#!/usr/bin/env bash
# Run every automated check that works without Claude, the network or a GUI.
# Usage: scripts/check.sh            (uses python3, plus python3.9 if found)
#        PYTHONS="python3.9 python3.12" scripts/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHONS=${PYTHONS:-"python3 $(command -v python3.9 || true)"}
status=0
for py in $PYTHONS; do
  [ -x "$(command -v "$py" 2>/dev/null)" ] || continue
  echo "== $("$py" --version 2>&1) ($py)"
  "$py" -m compileall -q plugin bin >/dev/null
  if ! "$py" -m unittest discover -s tests; then status=1; fi
  if ! "$py" -m unittest discover -s macos/Integrations -p "test_*.py"; then status=1; fi
done

echo "== hook latency (50 runs, synthetic Stop, isolated data dir)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/proj"
PROMPT_RELAY_HOME="$tmp/data" bin/prompt-relay enable "$tmp/proj" >/dev/null
python3 - "$tmp" <<'EOF'
import json, os, subprocess, sys, time
tmp = sys.argv[1]
env = dict(os.environ, PROMPT_RELAY_HOME=tmp + "/data")
times = []
for i in range(50):
    raw = json.dumps({"hook_event_name": "Stop", "session_id": "bench", "prompt_id": str(i),
                      "cwd": tmp + "/proj", "last_assistant_message": "x" * 20000}).encode()
    t = time.perf_counter()
    subprocess.run(["bin/prompt-relay", "hook"], input=raw, env=env, check=True)
    times.append((time.perf_counter() - t) * 1000)
times.sort()
print(f"median {times[25]:.1f} ms, p95 {times[47]:.1f} ms, max {times[-1]:.1f} ms")
plugin = []
for i in range(50):
    raw = json.dumps({"hook_event_name": "Stop", "session_id": "bench", "prompt_id": "pl" + str(i),
                      "cwd": tmp + "/proj", "last_assistant_message": "x" * 20000}).encode()
    t = time.perf_counter()
    subprocess.run(["/bin/sh", "plugin/hooks/run-hook"], input=raw, env=env, check=True)
    plugin.append((time.perf_counter() - t) * 1000)
plugin.sort()
print(f"plugin launcher: median {plugin[25]:.1f} ms, p95 {plugin[47]:.1f} ms, max {plugin[-1]:.1f} ms")
EOF
exit $status
