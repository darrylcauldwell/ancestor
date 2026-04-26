#!/bin/bash
# Capture App Store screenshots for Ancestor Research (macOS)
#
# Usage: ./Scripts/capture_screenshots.sh
#
# Requires: the app to be built and the project database to exist.
# Screenshots are saved to fastlane/screenshots/en-US/

set -euo pipefail

APP_NAME="Ancestor Research"
SCHEME="Ancestor Research"
PROJECT="Ancestor Research.xcodeproj"
SCREENSHOT_DIR="fastlane/screenshots/en-US"
BUILD_DIR="/tmp/AncestorScreenshots"

mkdir -p "$SCREENSHOT_DIR"

echo "=== Ancestor Research Screenshot Capture ==="
echo ""

# Build the app
echo "Building app..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    -skipMacroValidation \
    build 2>&1 | tail -3

APP_PATH=$(find "$BUILD_DIR" -name "Ancestor Research.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built app"
    exit 1
fi
echo "App: $APP_PATH"

# Function to capture a screenshot
capture() {
    local screen_name=$1
    local output_file=$2
    local wait_time=${3:-3}

    echo "Capturing: $screen_name..."

    # Kill any running instance
    pkill -f "Ancestor Research" 2>/dev/null || true
    sleep 1

    # Launch with screenshot mode
    open -a "$APP_PATH" --args --screenshot-mode --screenshot-screen "$screen_name" &
    sleep "$wait_time"

    # Get window ID and capture
    local wid
    wid=$(osascript -e "tell application \"System Events\" to get id of first window of process \"$APP_NAME\"" 2>/dev/null || echo "")

    if [ -n "$wid" ]; then
        screencapture -l "$wid" -x "$SCREENSHOT_DIR/$output_file"
        echo "  Saved: $SCREENSHOT_DIR/$output_file"
    else
        # Fallback: capture by window bounds
        local bounds
        bounds=$(osascript -e '
            tell application "System Events"
                tell process "Ancestor Research"
                    set {x, y} to position of first window
                    set {w, h} to size of first window
                    return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
                end tell
            end tell
        ' 2>/dev/null || echo "")

        if [ -n "$bounds" ]; then
            screencapture -x -R "$bounds" "$SCREENSHOT_DIR/$output_file"
            echo "  Saved (fallback): $SCREENSHOT_DIR/$output_file"
        else
            echo "  FAILED: could not capture window"
        fi
    fi
}

# Capture each screen
capture "tree-pedigree" "01_tree_pedigree.png" 4
capture "tree-descendants" "02_tree_descendants.png" 4
capture "audit" "03_audit.png" 3
capture "research" "04_research.png" 3

# Clean up
pkill -f "Ancestor Research" 2>/dev/null || true

echo ""
echo "=== Screenshots complete ==="
ls -la "$SCREENSHOT_DIR"/*.png 2>/dev/null
