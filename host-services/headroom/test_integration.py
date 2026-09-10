"""Run inside the unmodified upstream image. Uses a mock LLM; makes no model API calls."""
import asyncio
import json
import os
import re
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


captured = []


class Upstream(BaseHTTPRequestHandler):
    def do_POST(self):
        captured.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        response = {"id": "resp_test", "object": "response", "status": "completed",
                    "output": [], "usage": {"input_tokens": 1, "output_tokens": 1,
                                             "total_tokens": 2}}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

    def log_message(self, *_):
        pass


def post(body):
    request = urllib.request.Request(
        "http://127.0.0.1:18788/v1/responses", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer test-only"})
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()
    return captured[-1]


def payload(name, content, kind="function_call", stream=False):
    call = {"type": kind, "call_id": "call_test", "name": name}
    call["input" if kind == "custom_tool_call" else "arguments"] = "{}"
    return {"model": "gpt-4.1", "stream": stream,
            "input": [{"role": "user", "content": "Summarize the tool results"}, call,
                      {"type": kind + "_output", "call_id": "call_test", "output": content}],
            "tools": [{"type": "function", "name": "headroom__headroom_retrieve",
                       "parameters": {"type": "object", "properties": {"hash": {"type": "string"}}}}]}


async def retrieve(hash_key):
    async with streamablehttp_client("http://127.0.0.1:8788/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert "headroom_retrieve" in {tool.name for tool in tools.tools}
            result = await session.call_tool("headroom_retrieve", {"hash": hash_key})
            assert not result.isError, result
            return json.loads(result.content[0].text)


def main():
    mock = HTTPServer(("127.0.0.1", 18789), Upstream)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    env = dict(os.environ, OPENAI_TARGET_API_URL="http://127.0.0.1:18789")
    with open("/tmp/headroom-integration.log", "w") as log:
        proxy = subprocess.Popen([
            "headroom", "proxy", "--host", "127.0.0.1", "--port", "18788",
            "--no-ccr-inject-tool", "--disable-kompress", "--no-rate-limit"],
            env=env, stdout=log, stderr=log)
        mcp_server = subprocess.Popen(["python", "-c", os.environ["HEADROOM_MCP_BOOTSTRAP"]],
            env=dict(os.environ, HEADROOM_PROXY_URL="http://127.0.0.1:18788"), stdout=log, stderr=log)
        try:
            for _ in range(120):
                try:
                    urllib.request.urlopen("http://127.0.0.1:18788/readyz", timeout=1)
                    urllib.request.urlopen("http://127.0.0.1:8788/healthz", timeout=1)
                    break
                except OSError:
                    time.sleep(.25)
            else:
                raise AssertionError("Proxy failed to become ready")

            report = json.dumps({"report": "Subagent evidence with file paths and findings. " * 200})
            exclusions = [name.strip() for name in os.environ["HEADROOM_EXCLUDE_TOOLS"].split(",")]
            for name in exclusions:
                for kind in ("function_call",):
                    body = payload(name, report, kind)
                    forwarded = post(body)
                    assert forwarded["input"] == body["input"], (name, kind)
                    assert forwarded["tools"] == body["tools"], "Phantom tool injected"
            print(f"PASS: {len(exclusions)} excluded tools preserved in native Coder function-call format", flush=True)

            for size in (408, 16384):
                for stream in (False, True):
                    body = payload("wait_agent", (report * 3)[:size], stream=stream)
                    assert post(body)["input"] == body["input"]
            print("PASS: streaming and nonstreaming agent reports preserved", flush=True)

            original = json.dumps([{"id": i, "status": "ok", "details": "Build evidence. " * 50}
                                   for i in range(100)])
            body = payload("execute", original)
            forwarded = post(body)
            compressed = forwarded["input"][-1]["output"]
            assert len(compressed) < len(original), "Ordinary tool compression is disabled"
            assert forwarded["tools"] == body["tools"], "Phantom tool injected"
            hashes = re.findall(r"<<ccr:([a-f0-9]+)|hash=([a-f0-9]+)", compressed)
            assert hashes, "Expected a retrievable compression marker"
            hash_key = next(a or b for a, b in hashes)
            with urllib.request.urlopen("http://127.0.0.1:18788/v1/retrieve/" + hash_key, timeout=10) as response:
                direct = json.load(response)
                print("PASS: proxy HTTP retrieval", sorted(direct), flush=True)
            # A marker may refer to a nested field or the full original payload.
            recovered = asyncio.run(retrieve(hash_key))
            content = recovered.get("original_content", recovered.get("content"))
            assert content, recovered
            assert json.loads(content) == json.loads(original), "Retrieved original differs"
            body = payload("headroom__headroom_retrieve", json.dumps(recovered))
            assert post(body)["input"] == body["input"]
            print(f"PASS: ordinary output compressed {len(original)} -> {len(compressed)} bytes; "
                  "MCP recovered proxy content and its result stayed intact", flush=True)
        finally:
            mcp_server.terminate()
            mcp_server.wait(timeout=15)
            proxy.terminate()
            proxy.wait(timeout=15)
            mock.shutdown()


if __name__ == "__main__":
    main()
