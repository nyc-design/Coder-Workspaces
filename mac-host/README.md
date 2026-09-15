# Mac build host

This directory contains the Mac-side pieces used by Linux Coder workspaces when Apple tooling is required.

The three execution paths are intentionally independent:

1. **XcodeBuildMCP** — interactive Xcode/simulator tools exposed to Coder Agents over MCP.
2. **Coder external workspace** — attach the Mac itself as a native `darwin/arm64` workspace when an entire Coder Agent session should execute on macOS.
3. **GitHub Actions self-hosted runner** — CI build/test execution from ordinary Linux `swift-dev` workspaces.

## One-click service controls

Both Mac background execution paths are deliberately toggleable. Installing either XcodeBuildMCP or a GitHub runner installs the shared controller at:

```text
~/.local/bin/coder-mac-control
```

Commands:

```bash
coder-mac-control xcode on
coder-mac-control xcode off
coder-mac-control xcode toggle
coder-mac-control xcode status

coder-mac-control github on
coder-mac-control github off
coder-mac-control github toggle
coder-mac-control github status

coder-mac-control all on
coder-mac-control all off
coder-mac-control all status
```

`github` controls all configured runners under `~/actions-runners`. `github toggle` turns them all off when any runner is currently on; when none are running it turns them all on.

The off state is persistent across logout/reboot. The controller uses launchd's enable/disable override rather than merely killing a process, so an intentionally disabled service does not come back at the next login.

### Dock buttons

After installing the services, generate two native macOS applet buttons:

```bash
bash mac-host/install-toggle-apps.sh
```

This creates:

```text
~/Applications/Coder Mac Controls/Toggle XcodeBuildMCP.app
~/Applications/Coder Mac Controls/Toggle GitHub Runners.app
```

Drag them into the Dock. Each click toggles its service(s) and posts a macOS notification showing the resulting ON/OFF state. No third-party menu-bar utility is required.

If preferred, the same `coder-mac-control ... toggle` commands can be placed in macOS Shortcuts and exposed from the Shortcuts Menu Bar or Control Center collections.

## XcodeBuildMCP service

`xcodebuildmcp/install.sh` installs Sentry's XcodeBuildMCP with Homebrew, installs `mcp-proxy`, generates an API key, and creates a per-user LaunchAgent.

```bash
bash mac-host/xcodebuildmcp/install.sh
```

The local endpoint is `http://127.0.0.1:8765/mcp` conceptually, although `mcp-proxy` may listen on additional local interfaces. Do not register a plain HTTP LAN endpoint with remote Coder. Put it behind an encrypted/private transport and retain the `X-API-Key` header.

If the Coder deployment is also on your tailnet, prefer Tailscale Serve:

```bash
tailscale serve --bg 8765
tailscale serve status
```

The resulting HTTPS node URL is tailnet-only; append `/mcp` when registering the MCP server. If Coder cannot join the tailnet, Tailscale Funnel can expose the same endpoint over public HTTPS while `mcp-proxy` still enforces the API key:

```bash
tailscale funnel --bg 8765
tailscale funnel status
```

Serve is preferred because it does not make the endpoint internet-accessible.

The generated secret is stored at:

```text
~/.config/coder-mac/xcodebuildmcp.env
```

The Coder MCP registration shape is documented in `xcodebuildmcp/coder-mcp-server.example.yaml`. The example is deliberately not part of the live `coder-agents-config/mcp-servers.yaml` because the endpoint and API key are Mac-specific and should not be committed.

## Coder external workspace

Publish `workspace-templates/macos-external`, create an external workspace, then persist Coder's generated external-agent command as a LaunchAgent:

```bash
mkdir -p /Users/Shared/Coder
bash mac-host/coder-external/install.sh neil-macbook-pro
```

The helper stores the generated external-agent command under `~/.local/share/coder-mac/` with restrictive permissions. Re-run it if the external workspace is deleted/recreated or its token changes.

## GitHub Actions runner

Because `nyc-design` is a personal GitHub account, self-hosted runners are repository-scoped. Run the installer once for every Apple-platform repository that should be able to use the Mac:

```bash
bash mac-host/github-actions/install-repo-runner.sh nyc-design/Vision-Villa
```

Each runner gets the custom labels `swift-ci`, `xcode`, and `visionos`, in addition to GitHub's default `self-hosted`, `macOS`, and `ARM64` labels.

The reusable workflow at `.github/workflows/macos-xcode-ci.yaml` can then be called from an application repository:

```yaml
name: Apple CI

on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  visionos:
    uses: nyc-design/Coder-Workspaces/.github/workflows/macos-xcode-ci.yaml@main
    with:
      project: Vision-Villa.xcodeproj
      scheme: Vision-Villa
      destination: generic/platform=visionOS Simulator
      action: build
```

For tests, set `action: test` and use a concrete simulator destination supported by the installed Xcode, for example a specific Apple Vision Pro simulator name/OS combination.

The reusable workflow uploads `xcodebuild.log` and `XcodeResult.xcresult` as seven-day artifacts even when the build fails.

### Self-hosted runner security

A self-hosted runner executes repository workflow code directly on the Mac. Do not route untrusted fork pull requests to it. For public repositories, use trusted-branch/manual dispatch policies (or a separate disposable runner) instead of automatically running arbitrary PR code on your personal Mac.
