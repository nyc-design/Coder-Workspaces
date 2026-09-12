#!/usr/bin/env bash
# Build-time smoke gate: prove the toolchain actually compiles, links and runs
# Swift code before the image is allowed to publish, then leave nothing behind.
#
# This runs as root during `docker build` in a throwaway directory. Any failure
# fails the build — that is the point.
set -euo pipefail

log() { echo "[swift-build-smoke] $*"; }
die() { echo "[swift-build-smoke] ERROR: $*" >&2; exit 1; }

workdir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand workdir now, on purpose
trap "rm -rf '$workdir'" EXIT

log "swift: $(swift --version 2>&1 | head -1)"

# ── 1. Toolchain components that ship inside the tarball ─────────────────
command -v swiftc         >/dev/null || die "swiftc not on PATH"
command -v swift-format   >/dev/null || die "swift-format not on PATH (expected in the 6.x toolchain)"
command -v sourcekit-lsp  >/dev/null || die "sourcekit-lsp not on PATH (expected in the 6.x toolchain)"
log "swift-format: $(swift-format --version 2>&1 | head -1)"

# ── 2. Compile + test a throwaway SwiftPM package ────────────────────────
pkg="$workdir/SmokePackage"
mkdir -p "$pkg/Sources/Smoke" "$pkg/Tests/SmokeTests"

cat > "$pkg/Package.swift" <<'SWIFTPM'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Smoke",
    targets: [
        .target(name: "Smoke"),
        .testTarget(name: "SmokeTests", dependencies: ["Smoke"]),
    ]
)
SWIFTPM

cat > "$pkg/Sources/Smoke/Smoke.swift" <<'SWIFT'
import Foundation

public struct Smoke: Sendable {
    public init() {}

    /// Exercises the stdlib, Foundation and generics in one go so a broken
    /// resource dir or missing runtime library surfaces at build time.
    public func summarize(_ values: [Int]) -> String {
        let total = values.reduce(0, +)
        return "count=\(values.count) total=\(total) stamp=\(Date(timeIntervalSince1970: 0).timeIntervalSince1970)"
    }
}
SWIFT

cat > "$pkg/Tests/SmokeTests/SmokeTests.swift" <<'SWIFT'
import XCTest
@testable import Smoke

final class SmokeTests: XCTestCase {
    func testSummarize() {
        XCTAssertEqual(Smoke().summarize([1, 2, 3]), "count=3 total=6 stamp=0.0")
    }
}
SWIFT

log "swift build"
( cd "$pkg" && swift build ) || die "swift build failed"

log "swift test"
( cd "$pkg" && swift test ) || die "swift test failed"

# ── 3. swift-format must actually process a file ─────────────────────────
log "swift-format lint"
swift-format lint --strict "$pkg/Sources/Smoke/Smoke.swift" >/dev/null 2>&1 \
    || log "swift-format reported style findings on the sample (non-fatal; the binary ran)"
swift-format format "$pkg/Sources/Smoke/Smoke.swift" >/dev/null \
    || die "swift-format could not format a valid Swift file"

# ── 4. SwiftLint must actually run ───────────────────────────────────────
command -v swiftlint >/dev/null || die "swiftlint not on PATH"
log "swiftlint: $(swiftlint version)"
# `lint` exits non-zero when rules are violated, which is not what we are
# testing; we assert it parses real Swift and emits a report.
( cd "$pkg" && swiftlint lint --quiet --reporter json Sources >"$workdir/lint.json" 2>"$workdir/lint.err" ) || true
python3 -c "import json,sys; json.load(open('$workdir/lint.json'))" \
    || die "swiftlint did not produce a parseable report: $(cat "$workdir/lint.err")"

log "all build-time checks passed"
