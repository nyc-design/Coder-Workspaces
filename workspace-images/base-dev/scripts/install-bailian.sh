#!/usr/bin/env bash
# Install the official Model Studio CLI without login, skills, or user config writes.
# Upstream: https://github.com/modelstudioai/cli/tree/v2.0.0/packages/cli
# v2.0.0 has no Linux ARM64 standalone asset; the Node package supports both arches.
set -euo pipefail

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64|Linux/aarch64|Linux/arm64) ;;
  *) echo 'Bailian CLI installer supports Linux amd64 and arm64 only.' >&2; exit 1 ;;
esac

readonly version='2.0.0'
readonly sha256='d6b236ebb66a6ce4c48f064dd73814256732bbc84fcbca704d1c6d93a7a34912'
readonly prefix="${NPM_CONFIG_PREFIX:-/usr/local/share/npm-global}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  "https://registry.npmjs.org/bailian-cli/-/bailian-cli-${version}.tgz" \
  --output "$tmp_dir/bailian-cli.tgz"
printf '%s  %s\n' "$sha256" "$tmp_dir/bailian-cli.tgz" | sha256sum --check --status

# The upstream postinstall downloads mutable wiki/skills content into ~/.bailian.
# Disable all lifecycle hooks: image builds must not initialize user state.
# npm still verifies registry integrity for dependencies; their ranges are upstream's.
npm install --global --prefix "$prefix" --ignore-scripts --no-audit --no-fund \
  "$tmp_dir/bailian-cli.tgz"
"$prefix/bin/bl" --version
