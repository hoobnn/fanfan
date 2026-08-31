#!/bin/bash
# Create GitHub Release using GitHub CLI
# Prerequisites: brew install gh
# Usage: ./scripts/create-release.sh [version]

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    exit 2
fi
VERSION=$1
REPO="hoobnn/fanfan"
TAG="v${VERSION}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "❌ Invalid semantic version: $VERSION" >&2
    exit 2
fi
PROJECT_VERSION=$(xcodebuild \
    -project fanfan.xcodeproj \
    -scheme fanfan \
    -configuration Release \
    -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
if [ "$PROJECT_VERSION" != "$VERSION" ]; then
    echo "❌ Version $VERSION does not match MARKETING_VERSION $PROJECT_VERSION" >&2
    exit 1
fi
if ! git rev-parse --verify --quiet "refs/tags/${TAG}^{commit}" >/dev/null; then
    echo "❌ Local tag $TAG does not exist" >&2
    exit 1
fi

echo "🚀 Creating GitHub Release: $TAG"

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI not found!"
    echo "Install with: brew install gh"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "🔐 Please authenticate with GitHub:"
    gh auth login
fi

# Create release notes
RELEASE_NOTES="releases/RELEASE_NOTES_${VERSION}.md"
mkdir -p releases

cat > "$RELEASE_NOTES" << 'EOF'
## 🌬️ fanfan v${VERSION} - macOS Fan Control

### ✨ Features
- 🌡️ Real-time CPU/GPU temperature monitoring
- 💨 Manual and automatic fan speed control  
- 📊 Animated menu bar icon showing fan activity
- 🚀 Launch at login support
- 🎨 Beautiful liquid glass UI design
- 🔒 Privacy-first: all processing happens locally

### 📦 Installation

#### Method 1: Quick Install (Recommended)
```bash
# Download and install
curl -L https://github.com/${REPO}/releases/download/${TAG}/fanfan-v${VERSION}-macos.zip -o fanfan.zip
unzip fanfan.zip
mv fanfan.app /Applications/
rm fanfan.zip

# Install privileged fan daemon
open /Applications/fanfan.app
```

#### Method 2: Manual Install
1. Download **fanfan-v${VERSION}-macos.zip** or **fanfan-v${VERSION}-macos.dmg**
2. Unzip/Mount and move `fanfan.app` to `/Applications`
3. **First launch**: Right-click → Open (to bypass Gatekeeper)
4. **Enable fan control**: launch fanfan and click **Install Helper** when prompted.

### 📋 Requirements
- macOS 26.0 or later
- Intel or Apple Silicon Mac
- Admin privileges for fan control

### 🔐 Verification
```bash
# Verify download integrity (optional)
shasum -a 256 fanfan-v${VERSION}-macos.zip
# Should match: [CHECKSUM_HERE]
```

### ⚠️ Important Notes
- **Fan control requires root access** to write to SMC (System Management Controller)
- Temperature reading works without special privileges
- First launch may show Gatekeeper warning - use Right-click → Open

### 🐛 Known Issues
- Some Apple Silicon Macs have limited SMC sensor exposure
- External GPU temperature monitoring not yet supported
- See full list: [Issues](https://github.com/${REPO}/issues)

### 📚 Documentation
- [User Guide](https://github.com/${REPO}/blob/main/docs/README.md)
- [FAQ](https://github.com/${REPO}/blob/main/docs/README.md#-faq)
- [Troubleshooting](https://github.com/${REPO}/issues)

### 🤝 Contributing
We welcome contributions! Please see our [Contributing Guide](https://github.com/${REPO}/blob/main/docs/README.md#-contributing).

### 📄 License
MIT License - see [LICENSE](https://github.com/${REPO}/blob/main/LICENSE)

---

**Full Changelog**: https://github.com/${REPO}/compare/v0.9.0...${TAG}

**⭐ If you find fanfan useful, please star the repo!**
EOF

# Replace template variables
sed -i '' "s|\${VERSION}|$VERSION|g" "$RELEASE_NOTES"
sed -i '' "s|\${TAG}|$TAG|g" "$RELEASE_NOTES"
sed -i '' "s|\${REPO}|$REPO|g" "$RELEASE_NOTES"

# Calculate and insert checksum
if [ -f "releases/fanfan-v${VERSION}-macos.zip" ]; then
    CHECKSUM=$(shasum -a 256 "releases/fanfan-v${VERSION}-macos.zip" | awk '{print $1}')
    sed -i '' "s/\[CHECKSUM_HERE\]/$CHECKSUM/g" "$RELEASE_NOTES"
fi

echo "📝 Release notes created: $RELEASE_NOTES"

# Create the release
echo "🎉 Creating release on GitHub..."
ZIP="releases/fanfan-v${VERSION}-macos.zip"
DMG="releases/fanfan-v${VERSION}-macos.dmg"
if [ ! -f "$ZIP" ] || [ ! -f "$DMG" ]; then
    echo "❌ Missing release artifacts. Run scripts/build-release.sh $VERSION first." >&2
    exit 1
fi

ASSETS=("$ZIP" "$DMG")
for checksum in "$ZIP.sha256" "$DMG.sha256"; do
    if [ -f "$checksum" ]; then
        ASSETS+=("$checksum")
    fi
done

gh release create "$TAG" \
    --repo "$REPO" \
    --title "fanfan v${VERSION} - macOS Fan Control" \
    --notes-file "$RELEASE_NOTES" \
    "${ASSETS[@]}"

echo ""
echo "✅ Release created successfully!"
echo "🔗 View at: https://github.com/${REPO}/releases/tag/${TAG}"
echo ""
echo "📤 Users can now download directly from:"
echo "   https://github.com/${REPO}/releases/latest/download/fanfan-v${VERSION}-macos.zip"
