"""Exercise the built image's actual PID 1, health check and child lifecycles."""
import json
import subprocess
import sys
import time
import uuid

image = sys.argv[1]


def docker(*args, check=True):
    return subprocess.run(["docker", *args], check=check, text=True, capture_output=True)


def wait_exit(name, expected):
    result = docker("wait", name).stdout.strip()
    assert result == str(expected), (name, result, docker("logs", name).stdout)


def run_case(case):
    name = "headroom-test-" + uuid.uuid4().hex[:10]
    try:
        docker("run", "-d", "--name", name, "--health-interval=1s", "--health-start-period=1s",
               "--health-retries=1", image, "--host", "0.0.0.0", "--port", "8787",
               "--no-ccr-inject-tool", "--disable-kompress", "--no-rate-limit")
        for _ in range(120):
            state = json.loads(docker("inspect", "--format", "{{json .State}}", name).stdout)
            assert state["Running"], docker("logs", name).stdout
            if state["Health"]["Status"] == "healthy":
                break
            time.sleep(.5)
        else:
            raise AssertionError("Container did not become healthy")
        # Identify actual immediate children of Python PID 1 without requiring ps.
        children = json.loads(docker("exec", name, "python", "-c",
            "import pathlib,json; print(json.dumps({int(p.name): (p/'cmdline').read_bytes().decode().replace(chr(0),' ') for p in pathlib.Path('/proc').iterdir() if p.name.isdigit() and 'PPid:\\t1\\n' in (p/'status').read_text()}))").stdout)
        assert len(children) == 2, children
        target = next(pid for pid, cmd in children.items() if
                      ("mcp-http-bridge.py" in cmd) == (case in ("bridge", "bridge-health")))
        if case in ("proxy-health", "bridge-health"):
            docker("exec", name, "python", "-c", f"import os,signal; os.kill({target}, signal.SIGSTOP)")
            assert docker("exec", name, "python", "/opt/headroom/healthcheck.py", check=False).returncode != 0
            docker("exec", name, "python", "-c", f"import os,signal; os.kill({target}, signal.SIGCONT)")
            docker("stop", "--time", "15", name)
            wait_exit(name, 0)
        elif case in ("proxy", "bridge"):
            docker("exec", name, "python", "-c", f"import os,signal; os.kill({target}, signal.SIGKILL)")
            # Poll with a deadline rather than allowing docker wait to hang on a broken supervisor.
            for _ in range(40):
                if docker("inspect", "--format", "{{.State.Running}}", name).stdout.strip() == "false":
                    break
                time.sleep(.5)
            else:
                raise AssertionError("Supervisor failed to stop after child exit")
            wait_exit(name, 1)
        else:
            docker("kill", "--signal", "SIGINT" if case == "sigint" else "SIGTERM", name)
            for _ in range(40):
                if docker("inspect", "--format", "{{.State.Running}}", name).stdout.strip() == "false":
                    break
                time.sleep(.5)
            else:
                raise AssertionError("Supervisor failed to handle shutdown signal")
            wait_exit(name, 0)
        print("PASS: container lifecycle", case, flush=True)
    finally:
        docker("rm", "-f", name, check=False)


for case in ("sigterm", "sigint", "proxy", "bridge", "proxy-health", "bridge-health"):
    run_case(case)
