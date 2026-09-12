#!/usr/bin/env bash
# swift-dev workspace init. Reports what the image provides and runs cheap
# sanity checks.
#
# Deliberately NOT `set -e`: nothing here may abort workspace startup. The
# toolchain was already proven at build time by swift-build-smoke.sh; this is
# informational plus a guard against a broken mount/PATH at runtime.
set -uo pipefail

say() { echo "[swift-dev] $*"; }

SWIFT_HOME="${SWIFT_HOME:-/usr/local/swift}"
case ":$PATH:" in
    *":$SWIFT_HOME/bin:"*) ;;
    *) export PATH="$SWIFT_HOME/bin:$PATH" ;;
esac

if command -v swift >/dev/null 2>&1; then
    say "$(swift --version 2>&1 | head -1)"
else
    say "WARNING: swift not found on PATH (expected $SWIFT_HOME/bin)"
fi

for tool in swiftc swift-format sourcekit-lsp swiftlint; do
    if command -v "$tool" >/dev/null 2>&1; then
        version="$("$tool" --version 2>/dev/null | head -1)"
        [ -n "$version" ] || version="$("$tool" version 2>/dev/null | head -1)"
        say "  $tool ${version:-present}"
    else
        say "  $tool not available (optional)"
    fi
done

# Cheap end-to-end compile check: single file, no package, no network.
if command -v swiftc >/dev/null 2>&1; then
    probe="$(mktemp -d)"
    printf 'print("ok")\n' > "$probe/probe.swift"
    if (cd "$probe" && swiftc -O probe.swift -o probe >/dev/null 2>&1) && [ "$("$probe/probe" 2>/dev/null)" = "ok" ]; then
        say "compiler check: ok"
    else
        say "WARNING: compiler check failed — 'swiftc probe.swift' did not produce a working binary"
    fi
    rm -rf "$probe"
fi

say "Linux toolchain only — no Apple SDKs, Xcode or simulators. See ~/.coder/AGENTS.md."
say "Run 'swift-smoke-check' for a full offline build+test+lint verification."

exit 0
