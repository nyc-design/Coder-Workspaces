"""A container is healthy only when both HTTP services are ready."""
import os
import urllib.request

for url in (
    os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787") + "/readyz",
    "http://127.0.0.1:8788/healthz",
):
    with urllib.request.urlopen(url, timeout=2) as response:
        if response.status != 200:
            raise SystemExit(1)
