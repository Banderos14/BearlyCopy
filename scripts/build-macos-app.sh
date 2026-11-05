#!/usr/bin/env bash
# Build "Prompt Relay.app" (Phase 3A native macOS app) from this checkout.
#
# Usage: scripts/build-macos-app.sh            build into macos/build/
#        scripts/build-macos-app.sh --install  build, then install with
#                                              scripts/install-local.sh (asks first)
#
# Phase 11: the bundle records what it was built from, so About and
# scripts/install-local.sh can tell builds apart without guessing:
#   PRGitCommit   short HEAD at build time
#   PRGitDirty    "yes" when tracked files differed from HEAD
#   PRBuildDate   UTC build time
#   PRCoreDigest  SHA-256 over the bundled Core files (scripts/core-digest.sh)
#
# The bundle embeds a copy of the Python Core (bin/prompt-relay and
# plugin/prompt_relay) under Contents/Resources/core, in the repository's own
# layout, so the app does not depend on where the checkout lives. History is
# never in the bundle: it stays in ~/Library/Application Support/PromptRelay.
# The app is ad-hoc signed for local use only (no notarization, no release).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--install" ]; then
    shift
    exec scripts/install-local.sh "$@"
fi

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
dirty=no
if [ -n "$(git status --porcelain --untracked-files=no -- macos/Sources bin plugin 2>/dev/null)" ]; then dirty=yes; fi
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
digest=$(scripts/core-digest.sh "$app/Contents/Resources/core")
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prompt Relay</string>
  <key>CFBundleDisplayName</key><string>Prompt Relay</string>
  <key>CFBundleIdentifier</key><string>io.github.banderos14.PromptRelay</string>
  <key>PRGitCommit</key><string>${commit}</string>
  <key>PRGitDirty</key><string>${dirty}</string>
  <key>PRBuildDate</key><string>${built}</string>
  <key>PRCoreDigest</key><string>${digest}</string>
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

echo "== install with: scripts/install-local.sh (or --dry-run first)"
