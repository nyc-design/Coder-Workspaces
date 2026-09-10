#!/usr/bin/env python3
"""Supervise the upstream proxy and private MCP bridge as a single failure unit."""
import os
import signal
import subprocess
import sys
import time

children = []
stopping = False


def request_stop(signum, frame):
    global stopping
    stopping = True


def main():
    global stopping
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, request_stop)
    result = 0
    try:
        for command in (
            ["headroom", "proxy", *sys.argv[1:]],
            [sys.executable, "/opt/headroom/mcp-http-bridge.py"],
        ):
            if stopping:
                break
            children.append(subprocess.Popen(command, start_new_session=True))
        while not stopping:
            for child in children:
                if child.poll() is not None:
                    print(f"Child {child.pid} exited ({child.returncode}); stopping container", flush=True)
                    result = 1  # Even an unexpected successful exit must trigger restart.
                    stopping = True
                    break
            time.sleep(0.1)
    finally:
        # Signal process groups, including subprocesses created by either service.
        for child in children:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 10
        for child in children:
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
        for child in children:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    return result


if __name__ == "__main__":
    sys.exit(main())
