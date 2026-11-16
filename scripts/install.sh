#!/bin/bash
# Installs the latest Prompt Relay release from GitHub without the macOS
# "Not Opened" warning: files downloaded by curl are not quarantined, so
# Gatekeeper has nothing to block. Read it before you run it.
#
#   curl -fsSL https://raw.githubusercontent.com/Banderos14/prompt-relay/main/scripts/install.sh | bash
#
# Environment: INSTALL_DIR (default ~/Applications), NO_OPEN=1 (do not launch).
set -euo pipefail

REPO="Banderos14/prompt-relay"
BASE="https://github.com/$REPO/releases/latest/download"
ZIP="Prompt-Relay-macOS.zip"
SUMS="SHA256SUMS.txt"
DEST="${INSTALL_DIR:-$HOME/Applications}"

[ "$(uname -s)" = "Darwin" ] || { echo "Prompt Relay is for macOS." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "This build is for Apple Silicon (arm64)." >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "macOS 14 or newer is required." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Prompt Relay…"
curl -fsSL "$BASE/$ZIP" -o "$tmp/$ZIP"
curl -fsSL "$BASE/$SUMS" -o "$tmp/$SUMS"

want=$(grep " $ZIP\$" "$tmp/$SUMS" | awk '{print $1}')
have=$(shasum -a 256 "$tmp/$ZIP" | awk '{print $1}')
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "Checksum mismatch: not installing." >&2; exit 1; }
echo "Checksum ok."

ditto -x -k "$tmp/$ZIP" "$tmp/out"
[ -d "$tmp/out/Prompt Relay.app" ] || { echo "Unexpected archive layout." >&2; exit 1; }
codesign --verify --strict "$tmp/out/Prompt Relay.app" || { echo "The app signature does not verify." >&2; exit 1; }

mkdir -p "$DEST"
if pgrep -f "$DEST/Prompt Relay.app/Contents/MacOS/PromptRelay" >/dev/null 2>&1; then
  osascript -e 'tell application id "io.github.banderos14.PromptRelay" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
if [ -d "$DEST/Prompt Relay.app" ]; then
  backup="$HOME/Library/Application Support/PromptRelay-AppBackups"
  mkdir -p "$backup"
  mv "$DEST/Prompt Relay.app" "$backup/Prompt Relay (replaced $(date +%Y%m%d-%H%M%S)).app"
fi
ditto "$tmp/out/Prompt Relay.app" "$DEST/Prompt Relay.app"
xattr -dr com.apple.quarantine "$DEST/Prompt Relay.app" 2>/dev/null || true
echo "Installed: $DEST/Prompt Relay.app"
if [ "${NO_OPEN:-0}" != "1" ]; then open "$DEST/Prompt Relay.app"; fi
