#!/bin/bash
# Builds and runs the workspace tests (Sources/Workspace + Tests/) as a plain executable.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SDK=$(xcrun --show-sdk-path)
swiftc -swift-version 5 -Onone -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
  Sources/Workspace/*.swift Sources/ControlCenter/Jobs.swift Tests/*.swift -o build/workspace-tests 2>&1 | grep -E ": error:" || true
[ -x build/workspace-tests ] || { echo "✗ test build failed"; exit 1; }
build/workspace-tests

# Raphael Web (Python, stdlib only): same cron/job rules, workspace store, HTTP API.
python3 web/extract.py >/dev/null
python3 -m unittest discover -s web/tests 2>&1 | tail -1 | grep -q '^OK' \
  && echo "✓ web: $(python3 -m unittest discover -s web/tests 2>&1 | grep -E '^Ran' )" \
  || { python3 -m unittest discover -s web/tests 2>&1 | tail -30; echo "✗ web tests failed"; exit 1; }
