#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=${HEADROOM_TEST_IMAGE:-headroom:test}
if [[ "${HEADROOM_SKIP_BUILD:-0}" != 1 ]]; then
  # Resolve the floating tag once. BuildKit's remote builder need not populate
  # the Docker daemon's image store, so pull explicitly before inspecting it.
  docker pull ghcr.io/chopratejas/headroom:latest
  BASE=$(docker image inspect ghcr.io/chopratejas/headroom:latest --format '{{index .RepoDigests 0}}')
  docker build --load --build-arg "HEADROOM_IMAGE=$BASE" -t "$IMAGE" .
fi
export HEADROOM_TEST_IMAGE="$IMAGE"
python3 - <<'PY'
import os
import json
import subprocess
from pathlib import Path

config = json.loads(subprocess.check_output([
    "docker", "compose", "-f", "docker-compose.snippet.yml", "config", "--format", "json"]))
env = config["services"]["headroom"]["environment"]
args = ["docker", "run", "--rm", "--entrypoint", "python"]
for key in ("HEADROOM_EXCLUDE_TOOLS", "HEADROOM_SMART_CRUSHER_COMPACTION"):
    args += ["-e", key + "=" + env[key]]
args += ["-v", str(Path("test_integration.py").resolve()) + ":/tmp/test_integration.py:ro",
         os.environ["HEADROOM_TEST_IMAGE"], "/tmp/test_integration.py"]
raise SystemExit(subprocess.call(args))
PY

python3 test_lifecycle.py "$IMAGE"
