# macOS External Workspace

Attach an existing Apple Silicon Mac to Coder as an externally managed workspace. Coder does not provision, start, stop, or delete the Mac; it only manages the workspace record and external agent connection.

## Requirements

- Coder with External Workspaces enabled (Premium / Early Access in Coder 2.37)
- Apple Silicon Mac (`darwin/arm64`)
- Network access from the Mac to the Coder deployment
- Xcode installed when the workspace is used for iOS, macOS, or visionOS work

## Publish the template

From the `Coder-Workspaces` repository:

```bash
coder templates push \
  --directory workspace-templates/macos-external \
  --yes \
  macos-external
```

## Create the external workspace

```bash
coder external-workspaces create neil-macbook-pro \
  --template macos-external \
  --yes
```

The template defaults the agent working directory to `/Users/Shared/Coder`. Create it on the Mac before attaching the agent, or choose a different path when creating/updating the workspace.

## Attach the Mac

Retrieve Coder's generated command:

```bash
coder external-workspaces agent-instructions neil-macbook-pro
```

Run the generated command on the Mac. For a persistent setup, run the Coder external agent from a macOS LaunchAgent rather than a terminal session.

## Notes

- External-workspace lifecycle controls are intentionally disabled in Coder; the Mac remains independently managed.
- The Coder Agent runs natively on macOS and can use Xcode, simulators, local repositories, and other Mac-only tooling.
- This template is intentionally separate from the Linux `swift-dev` image. `swift-dev` remains the default editing/reasoning environment; this template is for work that should execute directly on the Mac.
