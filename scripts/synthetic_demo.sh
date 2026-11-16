#!/usr/bin/env bash
# Feed the synthetic fixtures through the real hook handler in an isolated,
# throw-away data directory, then show/export the result. Touches no Claude
# settings and no real user data. The clipboard step uses:
#   - the real macOS clipboard (pbcopy) when run with  --real-clipboard  on macOS
#   - the file MOCK backend otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PROMPT_RELAY_HOME="$tmp/data"
project="$tmp/demo-project"
mkdir -p "$project"
if [ "${1:-}" = "--real-clipboard" ]; then
  unset PROMPT_RELAY_CLIPBOARD
  echo "!! using the REAL system clipboard; its current content will be replaced"
else
  export PROMPT_RELAY_CLIPBOARD="file:$tmp/clipboard.bin"
fi

bin/prompt-relay enable "$project"
feed() {
  sed "s|__PROJECT_A__|$project|g" "tests/fixtures/$1" | bin/prompt-relay hook
}
feed prompt_basic.json
feed stop_unicode.json

echo "== sessions";  bin/prompt-relay sessions
echo "== turns";     bin/prompt-relay turns
echo "== show (verbatim)"; bin/prompt-relay show; echo
echo "== copy --verify";  bin/prompt-relay copy --verify
if [ -n "${PROMPT_RELAY_CLIPBOARD:-}" ]; then
  python3 - "$tmp/clipboard.bin" "$project" <<'EOF'
import json, sys
want = json.load(open("tests/fixtures/stop_unicode.json"))["last_assistant_message"].encode("utf-8")
got = open(sys.argv[1], "rb").read()
print("MOCK clipboard bytes identical to fixture:", got == want)
EOF
fi
echo "== context preview"; bin/prompt-relay context
