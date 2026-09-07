#!/bin/bash
# Builds fanfan.app into release/ for the signing pipeline.
#
# The app is built ad-hoc on purpose: the reusable workflow re-signs it with a
# Developer ID afterwards, signing the nested daemon before the outer bundle.
# Letting Xcode sign here would seal the bundle before the daemon is ready.
set -euo pipefail

cd "$(dirname "$0")/.."

MIN_OS="26.0"
TEAM_ID="${APPLE_TEAM_ID:-}"

echo "🛠  Building fanfan-smcd..."
make -C tools/fanfan-smcd clean
make -C tools/fanfan-smcd
lipo tools/fanfan-smcd/fanfan-smcd -verify_arch arm64
lipo tools/fanfan-smcd/fanfan-smcd -verify_arch x86_64
test "$(xcrun vtool -show-build tools/fanfan-smcd/fanfan-smcd \
  | awk '$1 == "minos" { print $2 }' | sort -u)" = "$MIN_OS"

# Refresh the bundled copy that Xcode picks up as a Resources file.
cp tools/fanfan-smcd/fanfan-smcd fanfan/Resources/fanfan-smcd

echo "🔨 Building fanfan.app..."
xcodebuild \
  -project fanfan.xcodeproj \
  -scheme fanfan \
  -configuration Release \
  -derivedDataPath build \
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
  clean build

BUILT_APP="build/Build/Products/Release/fanfan.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "❌ Built app not found at $BUILT_APP" >&2
  find build -name "*.app" -type d >&2
  exit 1
fi

APP_EXECUTABLE="$BUILT_APP/Contents/MacOS/fanfan"
lipo "$APP_EXECUTABLE" -verify_arch arm64
lipo "$APP_EXECUTABLE" -verify_arch x86_64
test "$(xcrun vtool -show-build "$APP_EXECUTABLE" \
  | awk '$1 == "minos" { print $2 }' | sort -u)" = "$MIN_OS"

# Symbols must cover both slices or crash reports from one arch stay unreadable.
DSYM="${BUILT_APP}.dSYM"
test -d "$DSYM"
DSYM_UUIDS=$(xcrun dwarfdump --uuid "$DSYM")
[[ "$DSYM_UUIDS" == *"(arm64)"* ]]
[[ "$DSYM_UUIDS" == *"(x86_64)"* ]]

test -f "$BUILT_APP/Contents/Resources/fanfan-smcd" \
  || { echo "❌ Daemon missing from bundle" >&2; exit 1; }

mkdir -p release
rm -rf release/fanfan.app
cp -R "$BUILT_APP" release/fanfan.app

echo "✅ Staged: release/fanfan.app"
