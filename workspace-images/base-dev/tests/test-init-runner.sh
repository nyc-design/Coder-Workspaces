#!/usr/bin/env bash
# run-workspace-inits: scripts run in sorted order, each line carries timing,
# and a failing script is reported without stopping the rest.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly RUNNER="$repo_root/workspace-images/base-dev/scripts/run-workspace-inits"
readonly T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

printf '#!/bin/sh\nsleep 1\n' > "$T/01-slow.sh"
printf '#!/bin/sh\nexit 3\n' > "$T/02-broken.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/03-quick.sh"
chmod +x "$T"/*.sh

runner_rc=0
runner_out="$(INIT_DIR="$T" sh "$RUNNER" 2>&1)" || runner_rc=$?
echo "$runner_out"

fail=0
chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
chk "start line has a UTC clock time" 'grep -Eq "^\[init-runner\] RUN 01-slow\.sh \([0-9]{2}:[0-9]{2}:[0-9]{2}Z\)$" <<< "$runner_out"'
chk "ok line has the duration"        'grep -Eq "^\[init-runner\] OK  01-slow\.sh \([1-9][0-9]*s\)$" <<< "$runner_out"'
chk "error line keeps the exit code"  'grep -Eq "^\[init-runner\] ERR 02-broken\.sh \(exit 3, [0-9]+s\)$" <<< "$runner_out"'
chk "later scripts still run"         'grep -Eq "^\[init-runner\] OK  03-quick\.sh" <<< "$runner_out"'
chk "summary has the total"           'grep -Eq "^\[init-runner\] done \(with errors\) in [1-9][0-9]*s\.$" <<< "$runner_out"'
chk "runner exits non-zero"           '[ "$runner_rc" -ne 0 ]'

exit $fail
