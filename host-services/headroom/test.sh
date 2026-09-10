#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import json
import subprocess
from pathlib import Path

config = json.loads(subprocess.check_output([
    "docker", "compose", "-f", "docker-compose.snippet.yml", "config", "--format", "json"]))
env = config["services"]["headroom"]["environment"]
args = ["docker", "run", "--rm", "--entrypoint", "python"]
for key in ("HEADROOM_EXCLUDE_TOOLS", "HEADROOM_SMART_CRUSHER_COMPACTION"):
    args += ["-e", key + "=" + env[key]]
args += ["-e", "HEADROOM_MCP_BOOTSTRAP=" + config["services"]["headroom-mcp"]["command"][0]]
args += ["-v", str(Path("test_integration.py").resolve()) + ":/tmp/test_integration.py:ro",
         config["services"]["headroom"]["image"], "/tmp/test_integration.py"]
raise SystemExit(subprocess.call(args))
PY
