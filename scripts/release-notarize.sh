#!/usr/bin/env bash
# Notarize, staple and check a Developer ID-signed DMG (Phase 11, ADR-020).
#
#   scripts/release-notarize.sh dist/BearlyCopy-<v>.dmg            show the plan only
#   NOTARY_PROFILE=prompt-relay scripts/release-notarize.sh --submit dist/BearlyCopy-<v>.dmg
#
# One-time setup (stores an app-specific password in the keychain; Apple ID
# and Team ID are yours):
#   xcrun notarytool store-credentials prompt-relay --apple-id <id> --team-id <TEAMID>
#
# Uploading to Apple's notary service sends the app to Apple. Run --submit
# only when you have decided to publish this build.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { printf 'release-notarize: %s\n' "$*" >&2; exit 1; }

submit=0
[ "${1:-}" = "--submit" ] && { submit=1; shift; }
dmg=${1:?usage: release-notarize.sh [--submit] <dmg>}
[ -f "$dmg" ] || die "no such file: $dmg"
case "$dmg" in *UNSIGNED*) die "refusing: this is an unsigned test package" ;; esac

mnt=$(mktemp -d)
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
trap 'hdiutil detach -quiet "$mnt" >/dev/null 2>&1 || true; rmdir "$mnt" 2>/dev/null || true' EXIT
app="$mnt/BearlyCopy.app"
codesign --verify --strict --deep "$app" || die "app signature does not verify"
# Code requirement, not text matching: Apple-anchored Developer ID
# Application leaf (OID 1.2.840.113635.100.6.1.13) and its intermediate.
codesign --verify --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app" \
    || die "app is not signed with a Developer ID Application certificate"
sig=$(codesign -d --verbose=2 "$app" 2>&1)   # captured: grep -q + pipefail would misreport
printf '%s\n' "$sig" | grep -Eq '^CodeDirectory v=[0-9]+ .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' || die "Hardened Runtime missing"
printf '%s\n' "$sig" | grep -Eq '^Timestamp=.+' || die "no secure timestamp"
echo "== preflight OK: Developer ID, Hardened Runtime, timestamp"

if [ "$submit" = 0 ]; then
    echo "Plan: xcrun notarytool submit \"$dmg\" --keychain-profile \"\$NOTARY_PROFILE\" --wait"
    echo "      xcrun stapler staple \"$dmg\"; xcrun stapler validate \"$dmg\""
    echo "      spctl -a -vv -t open --context context:primary-signature \"$dmg\""
    echo "Nothing was sent. Re-run with --submit and NOTARY_PROFILE set to notarize."
    exit 0
fi
[ -n "${NOTARY_PROFILE:-}" ] || die "set NOTARY_PROFILE (see the header of this script)"
hdiutil detach -quiet "$mnt"; trap - EXIT; rmdir "$mnt" 2>/dev/null || true

xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg"
shasum -a 256 "$dmg"
echo "== notarized and stapled: $dmg (not uploaded anywhere)"
