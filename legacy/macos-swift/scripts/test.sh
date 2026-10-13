#!/bin/bash
# Builds and runs the workspace tests (Sources/Workspace + Tests/) as a plain executable.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SDK=$(xcrun --show-sdk-path)
rm -f build/workspace-tests              # never run a stale binary when the build fails
swiftc -swift-version 5 -Onone -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
  Sources/Workspace/*.swift Sources/ControlCenter/Jobs.swift Tests/*.swift -o build/workspace-tests 2>&1 | grep -E ": error:" || true
[ -x build/workspace-tests ] || { echo "✗ test build failed"; exit 1; }
build/workspace-tests
