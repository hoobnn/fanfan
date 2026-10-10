#!/bin/bash
# FanFan Quick Installation Script
# Usage: curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash

set -euo pipefail

EXPECTED_TEAM_ID="8FUPL8QHFH"
INSTALL_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fanfan-install.XXXXXX")
chmod 700 "$INSTALL_TMP_DIR"

cleanup() {
    rm -rf -- "$INSTALL_TMP_DIR"
}
trap cleanup EXIT

echo "🌬️  FanFan Installation"
echo "====================="
echo ""

# Determine latest version from GitHub API.
RELEASE_JSON="$INSTALL_TMP_DIR/release.json"
curl -fsSL --retry 3 \
    https://api.github.com/repos/hoobnn/fanfan/releases/latest \
    -o "$RELEASE_JSON"
LATEST_VERSION=$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$RELEASE_JSON" | head -n 1)

if [[ ! "$LATEST_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "❌ Failed to fetch latest version"
    exit 1
fi

echo "📥 Downloading FanFan $LATEST_VERSION..."
ARCHIVE_NAME="fanfan-${LATEST_VERSION#v}-macOS.zip"
ARCHIVE="$INSTALL_TMP_DIR/$ARCHIVE_NAME"
CHECKSUM="$ARCHIVE.sha256"
RELEASE_BASE="https://github.com/hoobnn/fanfan/releases/download/$LATEST_VERSION"
curl -fsSL --retry 3 "$RELEASE_BASE/$ARCHIVE_NAME" -o "$ARCHIVE"
curl -fsSL --retry 3 "$RELEASE_BASE/$ARCHIVE_NAME.sha256" -o "$CHECKSUM"

echo "🔐 Verifying checksum and Developer ID signature..."
(
    cd "$INSTALL_TMP_DIR"
    shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)

echo "📦 Extracting..."
EXTRACT_DIR="$INSTALL_TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
SOURCE_APP="$EXTRACT_DIR/fanfan.app"
if [ ! -d "$SOURCE_APP" ] || \
   [ ! -f "$SOURCE_APP/Contents/Resources/fanfan-smcd" ] || \
   [ ! -f "$SOURCE_APP/Contents/Library/LaunchDaemons/com.hoobnn.fanfan.helper.plist" ]; then
    echo "❌ Release archive does not contain the expected app/helper files"
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$SOURCE_APP"
SOURCE_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$SOURCE_TEAM" != "$EXPECTED_TEAM_ID" ]; then
    echo "❌ Unexpected signing Team ID: ${SOURCE_TEAM:-missing}"
    exit 1
fi

echo "🔄 Installing to /Applications..."
/usr/bin/pkill -x fanfan >/dev/null 2>&1 || true
sudo rm -rf /Applications/fanfan.app
sudo /usr/bin/ditto "$SOURCE_APP" /Applications/fanfan.app
sudo /usr/sbin/chown -R root:wheel /Applications/fanfan.app
sudo /usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/fanfan.app
sudo /usr/sbin/spctl --assess --type execute --verbose=2 /Applications/fanfan.app
INSTALLED_TEAM=$(sudo /usr/bin/codesign -dv --verbose=4 /Applications/fanfan.app 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$INSTALLED_TEAM" != "$EXPECTED_TEAM_ID" ]; then
    echo "❌ Installed app signature changed during staging"
    sudo rm -rf /Applications/fanfan.app
    exit 1
fi

echo "🧹 Cleaning up..."
cleanup
trap - EXIT

echo ""
echo "✅ Installation complete!"
echo "🚀 Launching fanfan..."
echo "   Click Install Helper, then allow FanFan in"
echo "   System Settings › General › Login Items & Extensions."
echo ""

open /Applications/fanfan.app
