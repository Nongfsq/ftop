#!/bin/bash
# The single gate: formatting, a warning-free build, and all tests.
# Run before reporting any change complete.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== format"
swift format lint --strict --recursive Package.swift Sources Tests

echo "== build"
swift build -Xswiftc -warnings-as-errors 2>&1 | tail -3

echo "== test"
swift test 2>&1 | grep -E "✘|error:|failed|Test run with" || true
swift test >/dev/null 2>&1

echo "check passed"
