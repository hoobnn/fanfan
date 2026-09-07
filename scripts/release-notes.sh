#!/bin/bash
# Writes release_notes.md for the version currently staged in release/fanfan.app.
# Run after ci-build.sh; the reusable workflow picks the file up when publishing.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="release/fanfan.app"
test -d "$APP" || { echo "❌ $APP not found; run ci-build.sh first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist")

# Pull this version's section: everything between its heading and the next one.
CHANGELOG=$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md)

if [ -z "$(printf '%s' "$CHANGELOG" | tr -d '[:space:]')" ]; then
  echo "❌ No CHANGELOG.md section for [$VERSION]" >&2
  exit 1
fi

cat > release_notes.md << NOTES
${CHANGELOG}

---

### Installation

**Option 1: DMG (Recommended)**
1. Download and open \`fanfan-${VERSION}-macOS.dmg\`
2. Drag **fanfan.app** to /Applications/
3. Launch — it will prompt once to install the helper tool

**Option 2: One-liner**
\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash
\`\`\`

### Requirements
- macOS 26.0 or later · Apple Silicon or Intel

### Verify the download
\`\`\`bash
shasum -a 256 -c fanfan-${VERSION}-macOS.dmg.sha256
\`\`\`
NOTES

echo "✅ Wrote release_notes.md for ${VERSION}"
