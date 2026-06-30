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

APP="BlackHolePlayground"
DISPLAY_NAME="Black Hole Playground"
BUNDLE_ID="com.example.blackholeplayground"
BUILD="build"
BUNDLE="$BUILD/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"

# --- locate sources: the Sources/ module tree, or a flat folder (all files together) ---
if [ -d "Sources" ]; then
    SRC="Sources"
elif ls ./*.swift >/dev/null 2>&1; then
    SRC="."
else
    echo "error: couldn't find the Swift sources in ./Sources or the current folder." >&2
    echo "This folder ($(pwd)) currently contains:" >&2
    ls -1 >&2
    exit 1
fi

# Compile every .swift under the source root (any depth), and locate the Metal shader —
# so the module layout under Sources/ can be reorganized freely without touching this script.
SWIFT_FILES=()
while IFS= read -r f; do SWIFT_FILES+=("$f"); done < <(find "$SRC" -name '*.swift' | sort)
SHADER=$(find "$SRC" -name 'Shaders.metal' | head -1)
if [ "${#SWIFT_FILES[@]}" -eq 0 ] || [ -z "$SHADER" ]; then
    echo "error: no Swift files and/or Shaders.metal found under $SRC/." >&2
    exit 1
fi
echo "› sources: $SRC/ (${#SWIFT_FILES[@]} Swift files)"

rm -rf "$BUILD"
mkdir -p "$MACOS" "$RES"

echo "› bundling Metal shader (compiled at runtime — no Metal toolchain needed)"
cp "$SHADER" "$RES/Shaders.metal"

# App icon: ship the prebuilt .icns (derived from Resources/C-logo.png — regenerate with
# tools/make-icon.sh). Optional; the build still works without it.
ICON_FILE=""
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RES/AppIcon.icns"
    ICON_FILE="AppIcon"
    echo "› bundling app icon (AppIcon.icns)"
fi

echo "› compiling Swift"
xcrun -sdk macosx swiftc -O \
    "${SWIFT_FILES[@]}" \
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
ICON_PLIST=""
[ -n "$ICON_FILE" ] && ICON_PLIST="    <key>CFBundleIconFile</key>        <string>$ICON_FILE</string>"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
$ICON_PLIST
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
    OUT="$DIST/BlackHolePlayground Installer.pkg"
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