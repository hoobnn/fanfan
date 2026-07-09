#!/bin/bash
# fanfan Quick Installation Script
# Usage: curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash

set -e

echo "🌬️  fanfan Installation"
echo "====================="
echo ""

# Determine latest version from GitHub API
LATEST_VERSION=$(curl -s https://api.github.com/repos/hoobnn/fanfan/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_VERSION" ]; then
    echo "❌ Failed to fetch latest version"
    exit 1
fi

echo "📥 Downloading fanfan $LATEST_VERSION..."
curl -L "https://github.com/hoobnn/fanfan/releases/download/$LATEST_VERSION/fanfan-$LATEST_VERSION-macos.zip" -o /tmp/fanfan.zip

echo "📦 Extracting..."
cd /tmp
unzip -q fanfan.zip

echo "🔄 Installing to /Applications..."
sudo rm -rf /Applications/fanfan.app
sudo mv fanfan.app /Applications/

echo "🔧 Installing privileged fan daemon (requires password)..."
sudo mkdir -p /usr/local/bin /usr/local/libexec /Library/LaunchDaemons
sudo cp /Applications/fanfan.app/Contents/Resources/fanfan-smcd /usr/local/libexec/fanfan-smcd
sudo chown root:wheel /usr/local/libexec/fanfan-smcd
sudo chmod 755 /usr/local/libexec/fanfan-smcd
sudo cp /Applications/fanfan.app/Contents/Resources/com.hoobnn.fanfan.smcd.plist /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist
sudo chown root:wheel /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist
sudo chmod 644 /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist
sudo xattr -d com.apple.quarantine /usr/local/libexec/fanfan-smcd >/dev/null 2>&1 || true
sudo xattr -d com.apple.quarantine /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist >/dev/null 2>&1 || true
sudo launchctl bootout system /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist >/dev/null 2>&1 || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist
sudo launchctl kickstart -k system/com.hoobnn.fanfan.smcd

echo "🧹 Cleaning up..."
rm -f /tmp/fanfan.zip
rm -rf /tmp/fanfan.app

echo ""
echo "✅ Installation complete!"
echo "🚀 Launching fanfan..."
echo ""

open /Applications/fanfan.app
