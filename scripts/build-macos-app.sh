#!/usr/bin/env bash
# Build "Prompt Relay.app" (Phase 3A native macOS app) from this checkout.
#
# Usage: scripts/build-macos-app.sh            build into macos/build/
#        scripts/build-macos-app.sh --install  also copy the app to ~/Applications
#
# The bundle embeds a copy of the Python Core (bin/prompt-relay and
# plugin/prompt_relay) under Contents/Resources/core, in the repository's own
# layout, so the app does not depend on where the checkout lives. History is
# never in the bundle: it stays in ~/Library/Application Support/PromptRelay.
# The app is ad-hoc signed for local use only (no notarization, no release).
set -euo pipefail
cd "$(dirname "$0")/.."

install=0
[ "${1:-}" = "--install" ] && install=1

version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' plugin/prompt_relay/__init__.py)
[ -n "$version" ] || { echo "cannot read the Core version" >&2; exit 1; }

echo "== swift build (release)"
swift build -c release --package-path macos --product PromptRelayApp
bin_dir=$(swift build -c release --package-path macos --show-bin-path)

app="macos/build/Prompt Relay.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/core/bin" "$app/Contents/Resources/core/plugin/prompt_relay"
cp "$bin_dir/PromptRelayApp" "$app/Contents/MacOS/PromptRelay"
cp bin/prompt-relay "$app/Contents/Resources/core/bin/prompt-relay"
cp plugin/prompt_relay/*.py "$app/Contents/Resources/core/plugin/prompt_relay/"
chmod 755 "$app/Contents/Resources/core/bin/prompt-relay"

commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prompt Relay</string>
  <key>CFBundleDisplayName</key><string>Prompt Relay</string>
  <key>CFBundleIdentifier</key><string>io.github.banderos14.PromptRelay</string>
  <key>PRGitCommit</key><string>${commit}</string>
  <key>CFBundleExecutable</key><string>PromptRelay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$app/Contents/Resources/core/bin/prompt-relay" >/dev/null 2>&1 || true
codesign --force --deep --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
echo "== built $app (version $version, ad-hoc signed)"

if [ "$install" = 1 ]; then
    dest="$HOME/Applications/Prompt Relay.app"
    mkdir -p "$HOME/Applications"
    if pgrep -xq PromptRelay; then osascript -e 'quit app id "io.github.banderos14.PromptRelay"' >/dev/null 2>&1 || true; sleep 1; fi
    rm -rf "$dest"
    ditto "$app" "$dest"
    echo "== installed $dest"
fi
