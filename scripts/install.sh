#!/bin/bash
# Installs the latest BearlyCopy release from GitHub. Files downloaded by
# curl are not quarantined by macOS, so the "Not Opened" warning for the
# non-notarized app does not appear; this script does not change any security
# attribute. It verifies the SHA-256 and that the app is signed by the
# author's Apple team before installing. Read it before you run it.
#
#   curl -fsSL https://raw.githubusercontent.com/Banderos14/BearlyCopy/main/scripts/install.sh | bash
#
# Environment: INSTALL_DIR (default ~/Applications), NO_OPEN=1 (do not launch).
set -euo pipefail

REPO="Banderos14/BearlyCopy"
BASE="https://github.com/$REPO/releases/latest/download"
ZIP="BearlyCopy-macOS.zip"
SUMS="SHA256SUMS.txt"
DEST="${INSTALL_DIR:-$HOME/Applications}"

[ "$(uname -s)" = "Darwin" ] || { echo "BearlyCopy is for macOS." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "This build is for Apple Silicon (arm64)." >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "macOS 14 or newer is required." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading BearlyCopy…"
curl -fsSL "$BASE/$ZIP" -o "$tmp/$ZIP"
curl -fsSL "$BASE/$SUMS" -o "$tmp/$SUMS"

want=$(grep " $ZIP\$" "$tmp/$SUMS" | awk '{print $1}')
have=$(shasum -a 256 "$tmp/$ZIP" | awk '{print $1}')
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "Checksum mismatch: not installing." >&2; exit 1; }
echo "Checksum ok."

ditto -x -k "$tmp/$ZIP" "$tmp/out"
[ -d "$tmp/out/BearlyCopy.app" ] || { echo "Unexpected archive layout." >&2; exit 1; }
# Authenticity: the app must be signed by the author's Apple team (a changed
# download cannot satisfy this without that team's private key). The checksum
# above only catches a damaged download; this is the real gate.
TEAM_ID="9KV676HTZM"
codesign --verify --strict -R="anchor apple generic and identifier \"io.github.banderos14.PromptRelay\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$tmp/out/BearlyCopy.app" \
  || { echo "The app is not signed by the expected developer: not installing." >&2; exit 1; }

mkdir -p "$DEST"
if pgrep -f "$DEST/BearlyCopy.app/Contents/MacOS/PromptRelay" >/dev/null 2>&1; then
  osascript -e 'tell application id "io.github.banderos14.PromptRelay" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
# The app was called "Prompt Relay" before: move a copy with the old name aside
# (history, settings and permissions are kept: same bundle ID and data folder),
# so only one app runs.
if [ -d "$DEST/Prompt Relay.app" ]; then
  if pgrep -f "$DEST/Prompt Relay.app/Contents/MacOS/PromptRelay" >/dev/null 2>&1; then
    osascript -e 'tell application id "io.github.banderos14.PromptRelay" to quit' >/dev/null 2>&1 || true
    sleep 2
  fi
  backup="$HOME/Library/Application Support/PromptRelay-AppBackups"
  mkdir -p "$backup"
  mv "$DEST/Prompt Relay.app" "$backup/Prompt Relay (renamed to BearlyCopy $(date +%Y%m%d-%H%M%S)).app"
fi
if [ -d "$DEST/BearlyCopy.app" ]; then
  backup="$HOME/Library/Application Support/PromptRelay-AppBackups"
  mkdir -p "$backup"
  mv "$DEST/BearlyCopy.app" "$backup/BearlyCopy (replaced $(date +%Y%m%d-%H%M%S)).app"
fi
ditto "$tmp/out/BearlyCopy.app" "$DEST/BearlyCopy.app"
echo "Installed: $DEST/BearlyCopy.app"
if [ "${NO_OPEN:-0}" != "1" ]; then open "$DEST/BearlyCopy.app"; fi
