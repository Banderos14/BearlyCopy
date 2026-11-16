# Releasing Prompt Relay on GitHub (Phase 11, ADR-020)

> Every release must also carry the stable-name assets `Prompt-Relay-macOS.zip` and `Prompt-Relay-macOS.dmg` (copies of the versioned files) and a `SHA256SUMS.txt` listing them: `scripts/install.sh` downloads `releases/latest/download/Prompt-Relay-macOS.zip`. Keep the Team ID pinned in that script equal to the signing team.

Nothing in this file has been run against Apple's notary service. As of
Phase 11 this Mac has only an *Apple Development* certificate, which cannot
be used for distribution; a *Developer ID Application* certificate (paid
Apple Developer Program, Account Holder creates it) is required.

## One-time setup (owner)

1. Developer ID Application certificate in the login keychain:
   `security find-identity -v -p codesigning` lists
   `"Developer ID Application: <Name> (<TEAMID>)"`.
2. Notary credentials in the keychain (app-specific password):
   `xcrun notarytool store-credentials prompt-relay --apple-id <id> --team-id <TEAMID>`.
3. Choose a license (the repository has none yet; `plugin.json` says
   `UNLICENSED`). Graphics (Relay, icons) need the same decision.

## Each release

```bash
git switch main && git pull                 # a reviewed, merged commit
scripts/check.sh && (cd macos && swift test)
DEVELOPER_ID="Developer ID Application: <Name> (<TEAMID>)" scripts/release-build.sh
scripts/release-notarize.sh dist/Prompt-Relay-<v>.dmg            # preflight + plan, sends nothing
NOTARY_PROFILE=prompt-relay scripts/release-notarize.sh --submit dist/Prompt-Relay-<v>.dmg
```

What the scripts guarantee:

| Check | Where |
|---|---|
| Clean tracked tree (no uncommitted changes) | `release-build.sh` |
| Identity is a Developer ID Application certificate present in the keychain | `release-build.sh` |
| Universal binary (arm64 + x86_64), `lipo -info` printed | `release-build.sh` |
| Hardened Runtime flag, no entitlement exceptions, secure timestamp | `release-build.sh`, re-checked in `release-notarize.sh` |
| Bundle stamp: version, commit, build date, Core digest | `Info.plist` |
| `codesign --verify --strict --deep` | both |
| zip via `ditto -c -k --sequesterRsrc --keepParent`, DMG via `hdiutil` (UDZO) with an Applications link, DMG signed | `release-build.sh` |
| `notarytool submit --wait`, `stapler staple` + `validate`, `spctl -a -t open` | `release-notarize.sh --submit` |
| SHA-256 file next to the artifacts | `release-build.sh` |

Then, by hand and only after the owner decides: create the tag and the
GitHub Release, upload the DMG, zip and `.sha256`, paste release notes
(what changed, known limits, the Python requirement).

## Packaging check without a certificate

`scripts/release-build.sh --unsigned-test` produces the same layout, ad-hoc
signed with the Hardened Runtime flag, every file name ending in
`UNSIGNED-NOT-FOR-RELEASE`. It proves the packaging steps run; it is not a
release and Gatekeeper rejects it on other Macs. `release-notarize.sh`
refuses these files.

## Gatekeeper check on a clean Mac (owner)

1. Download the DMG through a browser (so it gets the quarantine flag).
2. Open, drag to Applications, open the app: no "unidentified developer"
   dialog; `spctl -a -vv "/Applications/Prompt Relay.app"` →
   `source=Notarized Developer ID`.
3. Without Python: Setup shows the Python step, no CLT installer pops up by
   itself.
