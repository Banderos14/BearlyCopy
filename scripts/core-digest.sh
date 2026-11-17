#!/usr/bin/env bash
# Print one SHA-256 over the BearlyCopy Core files in a directory laid out
# like the repository (bin/prompt-relay, plugin/prompt_relay/*.py).
# Usage: scripts/core-digest.sh <dir>     e.g. the repo root, or
#        scripts/core-digest.sh "BearlyCopy.app/Contents/Resources/core"
# Same files, same order, same bytes → same digest, wherever they live.
set -euo pipefail
root=${1:?usage: core-digest.sh <dir>}
cd "$root"
{
    printf '%s\n' bin/prompt-relay
    find plugin/prompt_relay -maxdepth 1 -type f -name '*.py' | LC_ALL=C sort
} | while IFS= read -r f; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
    printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done | shasum -a 256 | cut -d' ' -f1
