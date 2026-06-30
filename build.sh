#!/usr/bin/env bash
# build.sh — compile and bundle the app without opening Xcode.
#
#   bash build.sh           build into ./build
#   bash build.sh install   build, copy to /Applications, and launch it
#
# Needs only the Xcode Command Line Tools (swiftc, codesign). The Metal shader is
# compiled at runtime, so Xcode's `metal` toolchain is NOT required.

set -euo pipefail

# Always run from the script's own directory, so it works no matter where you call it.
cd "$(dirname "$0")"

# --- toolchain preflight -----------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    echo "error: the Xcode Command Line Tools aren't installed." >&2
    echo "Install them (a system dialog will appear), then run this again:" >&2
    echo >&2
    echo "    xcode-select --install" >&2
    echo >&2
    exit 1
fi

APP="GhosttyBlackholeDesktop"
BUNDLE_ID="com.example.ghostty-blackhole-desktop"
BUILD="build"
BUNDLE="$BUILD/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"

# --- locate sources: a Sources/ subfolder, or a flat folder (all files together) ---
if [ -d "Sources" ] && ls Sources/*.swift >/dev/null 2>&1; then
    SRC="Sources"
elif ls ./*.swift >/dev/null 2>&1; then
    SRC="."
else
    echo "error: couldn't find the Swift sources in ./Sources or the current folder." >&2
    echo "This folder ($(pwd)) currently contains:" >&2
    ls -1 >&2
    exit 1
fi

NEEDED=(Shaders.metal main.swift AppDelegate.swift OverlayWindow.swift PetWindow.swift ScreenCaptureManager.swift Renderer.swift Idle.swift Simulation.swift ControlPanel.swift)
MISSING=0
for f in "${NEEDED[@]}"; do
    [ -f "$SRC/$f" ] || { echo "missing file: $SRC/$f" >&2; MISSING=1; }
done
if [ "$MISSING" -ne 0 ]; then
    echo >&2
    echo "Put all of these files together in one folder (flat is fine) and rerun:" >&2
    printf '  %s\n' "${NEEDED[@]}" build.sh >&2
    exit 1
fi
echo "› sources: $SRC/"

rm -rf "$BUILD"
mkdir -p "$MACOS" "$RES"

echo "› bundling Metal shader (compiled at runtime — no Metal toolchain needed)"
cp "$SRC/Shaders.metal" "$RES/Shaders.metal"

echo "› compiling Swift"
xcrun -sdk macosx swiftc -O \
    "$SRC/main.swift" \
    "$SRC/AppDelegate.swift" \
    "$SRC/OverlayWindow.swift" \
    "$SRC/PetWindow.swift" \
    "$SRC/ScreenCaptureManager.swift" \
    "$SRC/Renderer.swift" \
    "$SRC/Idle.swift" \
    "$SRC/Simulation.swift" \
    "$SRC/ControlPanel.swift" \
    -framework Cocoa \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework IOKit \
    -framework QuartzCore \
    -framework SwiftUI \
    -framework Combine \
    -framework ApplicationServices \
    -framework Carbon \
    -o "$MACOS/$APP"

echo "› writing Info.plist"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP</string>
    <key>CFBundleExecutable</key>      <string>$APP</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Sign. Default is ad-hoc ("-": free, runs locally, but Gatekeeper will ask on first
# open). Set CODESIGN_IDENTITY to a "Developer ID Application: Name (TEAMID)" string
# to sign properly. (A fully click-free open also needs notarization — see README.)
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "› codesign (identity: $SIGN_ID)"
codesign --force --sign "$SIGN_ID" "$BUNDLE"
# Strip any quarantine flag so the freshly built app isn't treated as "downloaded".
xattr -cr "$BUNDLE" 2>/dev/null || true

# --- optional install / packaging -------------------------------------------
if [ "${1:-}" = "install" ]; then
    DEST="/Applications/$APP.app"
    echo "› installing to $DEST"
    rm -rf "$DEST"
    cp -R "$BUNDLE" "$DEST"
    codesign --force --sign "$SIGN_ID" "$DEST" >/dev/null 2>&1 || true
    xattr -cr "$DEST" 2>/dev/null || true     # not "downloaded" → opens directly
    echo
    echo "Installed to Applications. Launching…"
    open "$DEST"
    echo "From now on you can open it from Spotlight or Launchpad like any app."
elif [ "${1:-}" = "pkg" ]; then
    # Build a double-clickable .pkg installer (GUI install — no terminal needed afterwards).
    DIST="dist"
    PKGROOT="$BUILD/pkgroot"
    COMPONENT="$BUILD/${APP}-component.pkg"
    OUT="$DIST/Ghostty Black Holes Installer.pkg"
    echo "› building installer package"
    rm -rf "$PKGROOT" "$DIST"
    mkdir -p "$PKGROOT/Applications" "$DIST"
    cp -R "$BUNDLE" "$PKGROOT/Applications/"
    pkgbuild --quiet --root "$PKGROOT" \
             --identifier "$BUNDLE_ID" \
             --version "1.0" \
             --install-location "/" \
             "$COMPONENT"
    productbuild --quiet --package "$COMPONENT" "$OUT"
    rm -rf "$PKGROOT" "$COMPONENT"
    echo
    echo "Built installer:  $OUT"
    echo "Double-click it in Finder to install."
    echo "The FIRST time you open the app, macOS asks you to confirm because it isn't"
    echo "notarized: Control-click the app ▸ Open, or System Settings ▸ Privacy &"
    echo "Security ▸ Open Anyway. After that it opens normally."
    open -R "$OUT" 2>/dev/null || true   # reveal it in Finder
else
    echo
    echo "Built $BUNDLE"
    echo "Try it now:                            open \"$BUNDLE\""
    echo "Install to /Applications and launch:   bash build.sh install"
    echo "Build a double-click .pkg installer:   bash build.sh pkg"
fi

echo
echo "First launch asks for Screen Recording permission. Grant it, then open the app again."