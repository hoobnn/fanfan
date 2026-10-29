#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fanfan-smc-transition.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -Wall -Wextra -Wno-unused-function -O2 \
    "$PROJECT_DIR/scripts/tests/SMCModeTransitionRegression.c" \
    -framework IOKit -framework CoreFoundation -o "$TEST_DIR/test"
"$TEST_DIR/test"
