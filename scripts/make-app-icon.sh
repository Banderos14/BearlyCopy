#!/usr/bin/env bash
# Render BearlyCopy's application icon from Relay's vector drawing
# (macos/Sources/PromptRelayKit/Notch/AppIcon.swift, which draws
# MascotView.shapes — the notch bear) into macos/Resources/AppIcon.icns and a
# 1024-pixel preview, docs/images/app-icon-1024.png (Phase 16).
#
# Run after changing the bear or the icon; commit both files. Both the Xcode
# target and scripts/build-macos-app.sh bundle macos/Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swift run -c release --package-path macos PromptRelayIcon "$tmp/AppIcon.iconset" "$tmp/preview.png"
iconutil -c icns -o "$tmp/AppIcon.icns" "$tmp/AppIcon.iconset"
mkdir -p macos/Resources docs/images
cp "$tmp/AppIcon.icns" macos/Resources/AppIcon.icns
cp "$tmp/preview.png" docs/images/app-icon-1024.png
echo "== wrote macos/Resources/AppIcon.icns ($(wc -c < macos/Resources/AppIcon.icns | tr -d ' ') bytes) and docs/images/app-icon-1024.png"
