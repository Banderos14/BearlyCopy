#!/usr/bin/env bash
# Build a distributable Prompt Relay for GitHub Releases (Phase 11, ADR-020).
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" scripts/release-build.sh
#       universal (arm64 + x86_64) Release, Hardened Runtime, Developer ID
#       signature with a secure timestamp, then dist/Prompt-Relay-<v>.zip and .dmg
#   scripts/release-build.sh --unsigned-test
#       the same layout, ad-hoc signed with Hardened Runtime, every file name
#       marked UNSIGNED-NOT-FOR-RELEASE. For checking the packaging only;
#       Gatekeeper will refuse it on other Macs.
#
# Never uploads, notarizes, tags or pushes. Notarization is a separate,
# explicit step: scripts/release-notarize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

unsigned=0
[ "${1:-}" = "--unsigned-test" ] && unsigned=1
die() { printf 'release-build: %s\n' "$*" >&2; exit 1; }

for tool in git swift codesign ditto hdiutil shasum lipo; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -z "$(git status --porcelain --untracked-files=no)" ] || [ "$unsigned" = 1 ] \
    || die "tracked files have uncommitted changes; a release is built from a commit"

if [ "$unsigned" = 0 ]; then
    [ -n "${DEVELOPER_ID:-}" ] || die "set DEVELOPER_ID to your 'Developer ID Application: … (TEAMID)' identity (security find-identity -v -p codesigning). Without one, use --unsigned-test."
    case "$DEVELOPER_ID" in "Developer ID Application:"*) ;; *) die "DEVELOPER_ID must be a 'Developer ID Application' identity; Apple Development certificates cannot be notarized for distribution" ;; esac
    security find-identity -v -p codesigning | grep -qF "\"$DEVELOPER_ID\"" || die "identity not in the keychain: $DEVELOPER_ID"
    identity=$DEVELOPER_ID
    suffix=""
else
    identity="-"
    suffix="-UNSIGNED-NOT-FOR-RELEASE"
fi

version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' plugin/prompt_relay/__init__.py)
[ -n "$version" ] || die "cannot read the Core version"
commit=$(git rev-parse --short HEAD)
out=dist
stage="$out/stage"
app="$stage/Prompt Relay.app"
rm -rf "$stage"; mkdir -p "$stage"

echo "== swift build (release, universal)"
swift build -c release --package-path macos --product PromptRelayApp --arch arm64 --arch x86_64
bin_dir=$(swift build -c release --package-path macos --arch arm64 --arch x86_64 --show-bin-path)
lipo -info "$bin_dir/PromptRelayApp"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/core/bin" "$app/Contents/Resources/core/plugin/prompt_relay"
cp "$bin_dir/PromptRelayApp" "$app/Contents/MacOS/PromptRelay"
cp macos/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"   # Phase 16: the Relay bear icon
cp bin/prompt-relay "$app/Contents/Resources/core/bin/prompt-relay"
cp plugin/prompt_relay/*.py "$app/Contents/Resources/core/plugin/prompt_relay/"
chmod 755 "$app/Contents/Resources/core/bin/prompt-relay"
digest=$(scripts/core-digest.sh "$app/Contents/Resources/core")
dirty=no; [ -z "$(git status --porcelain --untracked-files=no)" ] || dirty=yes

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Prompt Relay</string>
  <key>CFBundleDisplayName</key><string>Prompt Relay</string>
  <key>CFBundleIdentifier</key><string>io.github.banderos14.PromptRelay</string>
  <key>CFBundleExecutable</key><string>PromptRelay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>PRGitCommit</key><string>${commit}</string>
  <key>PRGitDirty</key><string>${dirty}</string>
  <key>PRBuildDate</key><string>$(date -u +%Y-%m-%dT%H:%M:%SZ)</string>
  <key>PRCoreDigest</key><string>${digest}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Prompt Relay contributors</string>
</dict>
</plist>
PLIST

echo "== sign (identity: $([ "$unsigned" = 1 ] && echo 'ad-hoc' || echo "$identity"))"
ts="--timestamp"; [ "$unsigned" = 1 ] && ts="--timestamp=none"
# Inside out, no --deep: the only Mach-O is the main executable; the Core
# files are resources sealed by the bundle signature.
codesign --force --options runtime $ts --entitlements macos/Release/PromptRelay.entitlements \
    --sign "$identity" "$app"
codesign --verify --strict --deep --verbose=2 "$app"
# Capture first: `grep -q` closing the pipe early would fail under pipefail.
sig=$(codesign -d --verbose=2 "$app" 2>&1)
printf '%s\n' "$sig" | grep -E "^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)" || true
case "$sig" in *"flags="*"runtime"*) ;; *) die "Hardened Runtime flag missing" ;; esac

base="Prompt-Relay-${version}${suffix}"
zip="$out/$base.zip"
dmg="$out/$base.dmg"
rm -f "$zip" "$dmg"
echo "== zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "== dmg"
dmgsrc="$out/dmg-src"; rm -rf "$dmgsrc"; mkdir -p "$dmgsrc"
ditto "$app" "$dmgsrc/Prompt Relay.app"
ln -s /Applications "$dmgsrc/Applications"
hdiutil create -quiet -volname "Prompt Relay ${version}" -srcfolder "$dmgsrc" -ov -format UDZO "$dmg"
rm -rf "$dmgsrc"
[ "$unsigned" = 1 ] || codesign --force $ts --sign "$identity" "$dmg"

(cd "$out" && shasum -a 256 "$base.zip" "$base.dmg" > "$base.sha256")
echo "== artifacts"
ls -lh "$zip" "$dmg" "$out/$base.sha256"
du -sh "$app"
if [ "$unsigned" = 1 ]; then
    echo "!! UNSIGNED test packaging. Not for distribution; Gatekeeper will block it on other Macs."
else
    echo "== next (owner's decision): scripts/release-notarize.sh \"$dmg\""
fi
