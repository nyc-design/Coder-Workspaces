# Mac build host

This directory contains the Mac-side pieces used by Linux Coder workspaces when Apple tooling is required.

The three execution paths are intentionally independent:

1. **XcodeBuildMCP** — interactive Xcode/simulator tools exposed to Coder Agents over MCP.
2. **Coder external workspace** — attach the Mac itself as a native `darwin/arm64` workspace when an entire Coder Agent session should execute on macOS.
3. **GitHub Actions self-hosted runner** — CI build/test execution from ordinary Linux `swift-dev` workspaces.

## XcodeBuildMCP service

`xcodebuildmcp/install.sh` installs Sentry's XcodeBuildMCP with Homebrew, installs `mcp-proxy`, generates an API key, and creates a per-user LaunchAgent.

```bash
bash mac-host/xcodebuildmcp/install.sh
```

The local endpoint is `http://127.0.0.1:8765/mcp` conceptually, although `mcp-proxy` may listen on additional local interfaces. Do not register a plain HTTP LAN endpoint with remote Coder. Put it behind an encrypted/private transport (for example Tailscale Serve) and retain the `X-API-Key` header.

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
  pull_request:
  workflow_dispatch:

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
