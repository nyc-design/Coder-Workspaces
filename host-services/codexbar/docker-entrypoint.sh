#!/bin/sh
# codexbar entrypoint: render the provider config, then run `codexbar serve`.
#
# - Serving on a non-loopback host requires a dashboard token; fail fast
#   instead of letting CodexBar exit with a less obvious error.
# - CodexBar resolves config/cache under $HOME, which is a fresh (or volume-
#   mounted) dir at runtime, so the required dirs are created here.
set -eu

: "${CODEXBAR_DASHBOARD_TOKEN:?set CODEXBAR_DASHBOARD_TOKEN (required for non-loopback serve)}"

mkdir -p "$(dirname "$CODEXBAR_CONFIG")" "$HOME/.cache" "$HOME/.local/share"
cp /etc/codexbar/config.template.json "$CODEXBAR_CONFIG"
codexbar config validate --format json

exec node /usr/local/lib/codexbar-bridge/serve.mjs "$@"
