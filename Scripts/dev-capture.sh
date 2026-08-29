#!/bin/zsh
# Capture the running dev app's main window to build/captures/<label>.png.
# Usage: Scripts/dev-capture.sh <label> [--row "General"] [--click X,Y] [--dark]
#   --row   clicks the sidebar row by its accessibility name (SwiftUI List rows expose the label).
#   --click clicks a window-relative point (pt) — the fallback when --row finds nothing; sidebar rows
#           sit at x≈60 and y≈ 84 + 32·index (measure once off a capture).
# Requires: the terminal has Accessibility + Automation (System Events) access.
set -euo pipefail
LABEL=${1:?label}; shift
ROW=""; CLICK=""; DARK=0
while [[ $# -gt 0 ]]; do case "$1" in --row) ROW="$2"; shift 2;; --click) CLICK="$2"; shift 2;; --dark) DARK=1; shift;; *) echo "unknown $1"; exit 2;; esac; done
APP_DIR=$(xcodebuild -project DockTile.xcodeproj -scheme DockTile -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$APP_DIR/Dock Tile Dev.app"; PROC="Dock Tile Dev"
mkdir -p build/captures
open -a "$APP"; sleep 1.5
osascript -e "tell application \"System Events\" to tell process \"$PROC\" to set frontmost to true" >/dev/null
if [[ -n "$ROW" ]]; then
  osascript >/dev/null <<EOS
tell application "System Events" to tell process "$PROC"
  set els to entire contents of window 1
  repeat with e in els
    try
      if (name of e as string) is "$ROW" then
        click e
        exit repeat
      end if
    end try
  end repeat
end tell
EOS
  sleep 0.8
fi
if [[ -n "$CLICK" ]]; then
  P=$(osascript -e "tell application \"System Events\" to tell process \"$PROC\" to get position of window 1" | tr -d ' ')
  osascript -e "tell application \"System Events\" to click at {$(( ${P%%,*} + ${CLICK%%,*} )), $(( ${P#*,} + ${CLICK#*,} ))}" >/dev/null
  sleep 0.8
fi
restore_dark() { osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null; }
WAS_DARK=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')
SUFFIX=""
if [[ $DARK -eq 1 && "$WAS_DARK" == "false" ]]; then restore_dark true; SUFFIX="-dark"; sleep 1.2; fi
POS=$(osascript -e "tell application \"System Events\" to tell process \"$PROC\" to get {position, size} of window 1" | tr -d ' ')
X=${POS%%,*}; R=${POS#*,}; Y=${R%%,*}; R=${R#*,}; W=${R%%,*}; H=${R#*,}
screencapture -x -R "$X,$Y,$W,$H" "build/captures/$LABEL$SUFFIX.png"
if [[ $DARK -eq 1 && "$WAS_DARK" == "false" ]]; then restore_dark false; fi
echo "build/captures/$LABEL$SUFFIX.png"
