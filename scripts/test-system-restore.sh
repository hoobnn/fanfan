#!/bin/bash
# Exercise the production controller without XPC, SMC access, or saved settings.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fanfan-restore-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT

xcrun swiftc -swift-version 5 \
    -module-cache-path "$TEST_BUILD_DIR/module-cache" \
    "$PROJECT_DIR/fanfan/Core/FanController.swift" \
    "$PROJECT_DIR/fanfan/Core/FanRPMBounds.swift" \
    "$PROJECT_DIR/scripts/tests/SystemRestoreRegression.swift" \
    -o "$TEST_BUILD_DIR/system-restore-tests"

"$TEST_BUILD_DIR/system-restore-tests"
