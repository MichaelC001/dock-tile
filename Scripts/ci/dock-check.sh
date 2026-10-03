#!/bin/zsh
# CI-ONLY. Pins stub app bundles carrying freshly-baked legacy `.icns` tiles to the Dock of the
# machine it runs on, screenshots the Dock, and measures every icon's width so a tile that
# ignores Apple's icon grid (the 2.0.2 macOS 15 defect: ~24 % wider than its neighbours) fails.
#
# It REWRITES the Dock of the current user and restarts the Dock. Never run it on a developer
# Mac — it exists for the throwaway macOS 15 runner (`dock-check-macos-15` in ci.yml).
#
# Usage: Scripts/ci/dock-check.sh <workdir>
#   <workdir>/fixtures/<Name>/AppIcon.icns   — written by LegacyIcnsDockFixtureTests
#   <workdir>/dock.png, <workdir>/dock-window.png, <workdir>/measure.txt — outputs
set -euo pipefail

WORK=${1:?workdir}
FIXTURES="$WORK/fixtures"
[[ -n "${GITHUB_ACTIONS:-}" ]] || { echo "refusing to rewrite a non-CI Dock"; exit 2; }

MEASURE="$(dirname "$0")/dock-measure.swift"

# 0. How many app icons the Dock shows BEFORE pinning. The final measurement must find exactly
#    this many plus the fixtures, or a PASS could come from Apple's icons alone while the pinning
#    silently failed.
BEFORE=$(swift "$MEASURE" "$WORK/dock-before.png" --count-only)
echo "app icons before pinning: $BEFORE"
PINNED=0

# 1. One stub .app per fixture: Info.plist + a no-op executable + the baked icon. The Dock draws a
#    pinned bundle's CFBundleIconFile without ever launching it.
for dir in "$FIXTURES"/*/; do
  name=$(basename "$dir")
  app="$WORK/apps/DockTile $name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  printf '#!/bin/sh\nexec /bin/sleep 1\n' > "$app/Contents/MacOS/stub"; chmod +x "$app/Contents/MacOS/stub"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DockTile $name</string>
  <key>CFBundleIdentifier</key><string>com.docktile.ci.dockcheck.$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>stub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  # 2. Pin it (the dockutil-style persistent-apps entry: file URL, _CFURLStringType 15).
  defaults write com.apple.dock persistent-apps -array-add "<dict>
    <key>tile-data</key><dict><key>file-data</key><dict>
      <key>_CFURLString</key><string>file://$app/</string>
      <key>_CFURLStringType</key><integer>15</integer>
    </dict></dict>
    <key>tile-type</key><string>file-tile</string></dict>"
  echo "pinned: $app"
  PINNED=$((PINNED + 1))
done
defaults write com.apple.dock autohide -bool false
defaults write com.apple.dock magnification -bool false
killall Dock; sleep 8

# 3. A full-screen capture for human eyes (the runner has nothing private on screen), then the
#    measurer, which captures the Dock window by ID itself, requires exactly BEFORE + PINNED app
#    icons (so the tiles are provably among what it scores) and scores the icon widths.
screencapture -x "$WORK/dock.png"
swift "$MEASURE" "$WORK/dock-window.png" --expect-apps $((BEFORE + PINNED)) | tee "$WORK/measure.txt"
