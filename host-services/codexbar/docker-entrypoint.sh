#!/bin/sh
# codexbar entrypoint: render the provider config, then run `codexbar serve`.
#
# - Serving on a non-loopback host requires a dashboard token; fail fast
#   instead of letting CodexBar exit with a less obvious error.
# - CodexBar resolves config/cache under $HOME, which is a fresh (or volume-
#   mounted) dir at runtime, so the required dirs are created here.
# - The Alibaba region is templated because CodexBar defaults a missing
#   `region` to `cn`; the Token Plan in use is international.
set -eu

: "${CODEXBAR_DASHBOARD_TOKEN:?set CODEXBAR_DASHBOARD_TOKEN (required for non-loopback serve)}"

mkdir -p "$(dirname "$CODEXBAR_CONFIG")" "$HOME/.cache" "$HOME/.local/share"
sed "s/__ALIBABA_REGION__/${CODEXBAR_ALIBABA_REGION}/" \
  /etc/codexbar/config.template.json > "$CODEXBAR_CONFIG"
codexbar config validate --format json

exec codexbar serve --host 0.0.0.0 --port 8080 --allow-plain-http --identity redacted "$@"
