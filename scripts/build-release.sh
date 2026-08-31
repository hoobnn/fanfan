#!/bin/bash
# Build, sign, and notarize fanfan for public distribution.
#
# Requirements (one-time setup):
#   1. "Developer ID Application" cert in your keychain.
#      Verify: security find-identity -v -p codesigning
#   2. notarytool credentials stored under a keychain profile name.
#      Create with:
#        xcrun notarytool store-credentials "fanfan-notarize" \
#          --apple-id <email> --team-id 8FUPL8QHFH --password <app-specific-pw>
#
# Usage: ./scripts/build-release.sh [version]
#   e.g. ./scripts/build-release.sh 0.1.0

set -euo pipefail

VERSION=${1:-}
APP_NAME="fanfan"
TARGET_NAME="fanfan"
TEAM_ID="8FUPL8QHFH"
SIGN_IDENTITY="Developer ID Application: HAOBIN WU (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-fanfan-notarize}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/release-build"
RELEASE_DIR="$PROJECT_DIR/releases"
ENTITLEMENTS="$PROJECT_DIR/fanfan/Resources/fanfan.entitlements"
DAEMON_SRC_DIR="$PROJECT_DIR/tools/fanfan-smcd"
DAEMON_BUNDLED="$PROJECT_DIR/fanfan/Resources/fanfan-smcd"

PROJECT_VERSION=$(xcodebuild \
    -project "$PROJECT_DIR/fanfan.xcodeproj" \
    -scheme "$TARGET_NAME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
VERSION=${VERSION:-$PROJECT_VERSION}
if [ -z "$PROJECT_VERSION" ] || [ "$VERSION" != "$PROJECT_VERSION" ]; then
    echo "❌ Requested version '$VERSION' does not match app MARKETING_VERSION '$PROJECT_VERSION'"
    exit 1
fi
ARCHIVE_NAME="${APP_NAME}-v${VERSION}-macos"

# --- preflight ---------------------------------------------------------------

echo "🔍 Preflight checks"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "❌ Signing identity not found in keychain: $SIGN_IDENTITY"
    echo "   Run: security find-identity -v -p codesigning"
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "❌ notarytool profile '$NOTARY_PROFILE' not found."
    echo "   Create with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "      --apple-id <email> --team-id $TEAM_ID --password <app-specific-pw>"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "❌ Missing entitlements file: $ENTITLEMENTS"
    exit 1
fi

echo "   ✓ signing identity ready"
echo "   ✓ notarytool profile '$NOTARY_PROFILE'"
echo "   ✓ entitlements file present"

# --- daemon ------------------------------------------------------------------

echo ""
echo "🛠  Rebuilding privileged daemon"
make -C "$DAEMON_SRC_DIR" clean >/dev/null
make -C "$DAEMON_SRC_DIR" >/dev/null
lipo "$DAEMON_SRC_DIR/fanfan-smcd" -verify_arch arm64
lipo "$DAEMON_SRC_DIR/fanfan-smcd" -verify_arch x86_64
DAEMON_MIN_OS=$(xcrun vtool -show-build "$DAEMON_SRC_DIR/fanfan-smcd" | awk '$1 == "minos" { print $2 }' | sort -u)
if [ "$DAEMON_MIN_OS" != "26.0" ]; then
    echo "❌ daemon deployment target is not macOS 26.0"
    exit 1
fi

# Refresh the bundled copy Xcode picks up as a resource.
cp "$DAEMON_SRC_DIR/fanfan-smcd" "$DAEMON_BUNDLED"
echo "   ✓ refreshed $DAEMON_BUNDLED"

# --- build -------------------------------------------------------------------

echo ""
echo "🔨 Building $APP_NAME v$VERSION (Release)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

cd "$PROJECT_DIR"
xcodebuild \
    -project fanfan.xcodeproj \
    -scheme "$TARGET_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_CODE_COVERAGE=NO \
    CLANG_COVERAGE_MAPPING=NO \
    GCC_GENERATE_TEST_COVERAGE_FILES=NO \
    GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
    clean build \
    > "$BUILD_DIR/xcodebuild.log" 2>&1 || {
        echo "❌ xcodebuild failed. Last 30 lines of log:"
        tail -30 "$BUILD_DIR/xcodebuild.log"
        exit 1
    }

BUILT_APP=$(find "$BUILD_DIR/Build/Products/Release" -maxdepth 2 -name "${TARGET_NAME}.app" -type d | head -n 1)
if [ ! -d "$BUILT_APP" ]; then
    echo "❌ Built app not found under $BUILD_DIR"
    exit 1
fi
APP_EXECUTABLE="$BUILT_APP/Contents/MacOS/$TARGET_NAME"
lipo "$APP_EXECUTABLE" -verify_arch arm64
lipo "$APP_EXECUTABLE" -verify_arch x86_64
APP_MIN_OS=$(xcrun vtool -show-build "$APP_EXECUTABLE" | awk '$1 == "minos" { print $2 }' | sort -u)
if [ "$APP_MIN_OS" != "26.0" ]; then
    echo "❌ app deployment target is not macOS 26.0"
    exit 1
fi
DSYM="${BUILT_APP}.dSYM"
if [ ! -d "$DSYM" ]; then
    echo "❌ app dSYM was not generated"
    exit 1
fi
DSYM_UUIDS=$(xcrun dwarfdump --uuid "$DSYM")
if [[ "$DSYM_UUIDS" != *"(arm64)"* || "$DSYM_UUIDS" != *"(x86_64)"* ]]; then
    echo "❌ app dSYM is missing an arm64 or x86_64 UUID"
    exit 1
fi

RELEASE_APP="$RELEASE_DIR/${APP_NAME}.app"
rm -rf "$RELEASE_APP"
cp -R "$BUILT_APP" "$RELEASE_APP"
echo "   ✓ staged: $RELEASE_APP"

# --- sign --------------------------------------------------------------------

echo ""
echo "✍️  Code-signing with Developer ID"

# Inner-most first: the daemon binary inside Contents/Resources.
DAEMON_IN_APP="$RELEASE_APP/Contents/Resources/fanfan-smcd"
if [ -f "$DAEMON_IN_APP" ]; then
    codesign --force --timestamp --options runtime \
        --identifier fanfan-smcd \
        --sign "$SIGN_IDENTITY" \
        "$DAEMON_IN_APP"
    echo "   ✓ signed daemon"
else
    echo "❌ daemon binary not found in app bundle — Xcode resource copy may have changed"
    exit 1
fi

# Then the app itself with hardened runtime + entitlements.
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$RELEASE_APP"
echo "   ✓ signed app"

echo ""
echo "🔎 Verifying signature"
codesign --verify --deep --strict --verbose=2 "$RELEASE_APP" 2>&1 | tail -3
lipo "$RELEASE_APP/Contents/MacOS/$TARGET_NAME" -verify_arch arm64
lipo "$RELEASE_APP/Contents/MacOS/$TARGET_NAME" -verify_arch x86_64
lipo "$DAEMON_IN_APP" -verify_arch arm64
lipo "$DAEMON_IN_APP" -verify_arch x86_64
FINAL_DAEMON_MIN_OS=$(xcrun vtool -show-build "$DAEMON_IN_APP" | awk '$1 == "minos" { print $2 }' | sort -u)
test "$FINAL_DAEMON_MIN_OS" = "26.0"

# --- notarize ----------------------------------------------------------------

echo ""
echo "📤 Submitting to Apple notary service (this takes minutes)"

NOTARIZE_ZIP="$BUILD_DIR/${ARCHIVE_NAME}-notarize.zip"
ditto -c -k --keepParent "$RELEASE_APP" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout 30m

echo ""
echo "📎 Stapling notarization ticket"
xcrun stapler staple "$RELEASE_APP"
xcrun stapler validate "$RELEASE_APP"

echo "🛡  Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$RELEASE_APP" 2>&1 || {
    echo "⚠️  spctl assessment did not pass — investigate before shipping."
    exit 1
}

# --- package -----------------------------------------------------------------

echo ""
echo "📦 Packaging signed + stapled artifacts"

cd "$RELEASE_DIR"
rm -f "${ARCHIVE_NAME}.zip" "${ARCHIVE_NAME}.zip.sha256"
rm -f "${ARCHIVE_NAME}.dmg" "${ARCHIVE_NAME}.dmg.sha256"

# Final zip uses ditto so xattrs / metadata survive the round-trip.
ditto -c -k --keepParent "${APP_NAME}.app" "${ARCHIVE_NAME}.zip"
shasum -a 256 "${ARCHIVE_NAME}.zip" > "${ARCHIVE_NAME}.zip.sha256"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "${APP_NAME}.app" \
    -ov -format UDZO \
    "${ARCHIVE_NAME}.dmg" >/dev/null

# The container has an independent Gatekeeper/notarization lifecycle from the
# already-stapled app inside it.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "${ARCHIVE_NAME}.dmg"
xcrun notarytool submit "${ARCHIVE_NAME}.dmg" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout 30m
xcrun stapler staple "${ARCHIVE_NAME}.dmg"
xcrun stapler validate "${ARCHIVE_NAME}.dmg"
shasum -a 256 "${ARCHIVE_NAME}.dmg" > "${ARCHIVE_NAME}.dmg.sha256"

echo ""
echo "✨ Release build complete"
echo "📍 $RELEASE_DIR"
for artifact in \
    "$RELEASE_DIR/${ARCHIVE_NAME}.zip" \
    "$RELEASE_DIR/${ARCHIVE_NAME}.zip.sha256" \
    "$RELEASE_DIR/${ARCHIVE_NAME}.dmg" \
    "$RELEASE_DIR/${ARCHIVE_NAME}.dmg.sha256"; do
    if [ -f "$artifact" ]; then
        size=$(du -h "$artifact" | awk '{ print $1 }')
        printf '   %s (%s)\n' "$(basename "$artifact")" "$size"
    fi
done
echo ""
echo "Next: upload zip + dmg + .sha256 files to GitHub Releases."
