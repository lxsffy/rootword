#!/bin/bash
# ============================================================================
#  RootWord 独立回归测试（不依赖 Xcode / XCTest）
#
#  用法：bash Tests/run-tests.sh
#  说明：只编译纯逻辑层（Foundation / SQLite3），UI 代码不参与；
#        DesignSystem 的语义色由 Tests/Support/TestSupport.swift 提供测试替身。
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$(mktemp -d /tmp/rootword-tests-XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

SOURCES=(
  "$PROJECT_ROOT/Sources/Models/Word.swift"
  "$PROJECT_ROOT/Sources/Models/Settings.swift"
  "$PROJECT_ROOT/Sources/Models/RootEntry.swift"
  "$PROJECT_ROOT/Sources/Core/SRScheduler.swift"
  "$PROJECT_ROOT/Sources/Core/RootParser.swift"
  "$PROJECT_ROOT/Sources/Core/SQLiteRootIndex.swift"
  "$PROJECT_ROOT/Sources/Core/SQLiteDict.swift"
  "$PROJECT_ROOT/Sources/Core/ECDictValidator.swift"
  "$PROJECT_ROOT/Sources/Core/Store.swift"
  "$PROJECT_ROOT/Sources/Core/Importer.swift"
)

TESTS=(
  "$PROJECT_ROOT/Tests/Support/TestSupport.swift"
  "$PROJECT_ROOT/Tests/SRSchedulerTests.swift"
  "$PROJECT_ROOT/Tests/RootParserTests.swift"
  "$PROJECT_ROOT/Tests/SQLiteRootIndexTests.swift"
  "$PROJECT_ROOT/Tests/StoreTests.swift"
  "$PROJECT_ROOT/Tests/ImporterTests.swift"
)

echo "==> 编译回归测试（macOS / swiftc -O -l sqlite3）"
xcrun -sdk macosx swiftc \
  -target arm64-apple-macosx12.0 \
  -swift-version 5 \
  -O \
  -l sqlite3 \
  -o "$OUT/RootWordTests" \
  "${SOURCES[@]}" "${TESTS[@]}"

echo "==> 运行"
ROOTWORD_PROJECT_ROOT="$PROJECT_ROOT" "$OUT/RootWordTests"
