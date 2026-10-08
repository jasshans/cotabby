#!/usr/bin/env bash
# Remove all local Ghostype installations and reset TCC permissions.
# Useful when stale copies cause confusion about which build is running.
# Usage: bash scripts/clean_local.sh
set -euo pipefail

BUNDLE_ID="com.jasshans.ghostype"

echo "=== Ghostype Local Cleanup ==="

# --- 1. Kill any running Ghostype processes ---
echo ""
echo "Killing running Ghostype processes..."
pkill -f "Ghostype" 2>/dev/null && echo "  Killed running processes." || echo "  No running processes found."

# --- 2. Reset TCC permissions ---
echo ""
echo "Resetting TCC permissions for $BUNDLE_ID..."
tccutil reset All "$BUNDLE_ID" && echo "  TCC permissions reset." || echo "  Failed to reset TCC (may need sudo)."

# --- 3. Find and remove Ghostype app bundles ---
echo ""
echo "Searching for Ghostype app bundles..."

SEARCH_PATHS=(
    "$HOME/Applications"
    "/Applications"
    "$HOME/Desktop"
    "$HOME/Downloads"
    "/tmp"
)

found=0
for dir in "${SEARCH_PATHS[@]}"; do
    if [ ! -d "$dir" ]; then
        continue
    fi
    while IFS= read -r app; do
        # Verify it's actually Ghostype by checking the bundle identifier
        plist="$app/Contents/Info.plist"
        if [ -f "$plist" ]; then
            bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)
            if [ "$bid" = "$BUNDLE_ID" ]; then
                echo "  Removing: $app"
                rm -rf "$app"
                found=$((found + 1))
            fi
        fi
    done < <(find "$dir" -maxdepth 3 -name "Ghostype.app" -type d 2>/dev/null)
done

# Also check DerivedData for built copies
for dd in "$HOME/Library/Developer/Xcode/DerivedData" "/tmp/GhostypeDerivedData"; do
    if [ -d "$dd" ]; then
        while IFS= read -r app; do
            echo "  Removing (DerivedData): $app"
            rm -rf "$app"
            found=$((found + 1))
        done < <(find "$dd" -name "Ghostype.app" -type d 2>/dev/null)
    fi
done

if [ "$found" -eq 0 ]; then
    echo "  No Ghostype app bundles found."
else
    echo "  Removed $found app bundle(s)."
fi

# --- 4. Eject any mounted Ghostype DMG volumes ---
echo ""
echo "Ejecting mounted Ghostype volumes..."
while IFS= read -r vol; do
    [ -z "$vol" ] && continue
    hdiutil detach "$vol" -quiet 2>/dev/null && echo "  Ejected $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -i "^Ghostype" | sed 's|^|/Volumes/|')

# --- 5. Clean up caches and saved state ---
echo ""
echo "Cleaning caches and saved state..."
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" 2>/dev/null && echo "  Removed caches." || true
rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState" 2>/dev/null && echo "  Removed saved state." || true

echo ""
echo "=== Done. You have a clean slate. ==="
