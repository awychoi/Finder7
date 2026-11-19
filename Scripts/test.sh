#!/usr/bin/env bash
# Runs the Swift unit tests and the offline self-update integration test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$TMPDIR"

echo "==> Swift unit tests"
(cd "$ROOT" && swift test --disable-sandbox)

echo
echo "==> Self-update integration"
"$ROOT/Scripts/test-self-update.sh"
