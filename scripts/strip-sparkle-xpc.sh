#!/bin/bash
# Removes Sparkle's XPC services from a built fanfan.app.
#
# They exist for sandboxed apps only; fanfan is not sandboxed, so Sparkle
# never uses them. Downloader.xpc also carries entitlements that a plain
# Developer ID re-sign (as in the release workflow) would drop. Run this
# before signing: it breaks the existing seal of the framework and the app.
#
# Usage: ./scripts/strip-sparkle-xpc.sh path/to/fanfan.app
set -euo pipefail

APP="${1:?usage: $0 path/to/fanfan.app}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

test -d "$FRAMEWORK/Versions/B" \
  || { echo "❌ Sparkle.framework missing from $APP" >&2; exit 1; }

rm -rf "$FRAMEWORK/Versions/B/XPCServices"
rm -f "$FRAMEWORK/XPCServices"

if find "$FRAMEWORK" -name '*.xpc' | grep -q .; then
  echo "❌ XPC services still present in $FRAMEWORK" >&2
  exit 1
fi
echo "✂️  Removed Sparkle XPC services"
