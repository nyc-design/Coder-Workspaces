---
name: mac-development
description: Use the Mac Development MCP (macdev) to build, test, run, and debug Apple-platform code on the user's MacBook - Xcode builds and tests, simulators, physical devices, UI automation, and Mac shell or file access. Read when a task needs Xcode, an Apple SDK, a simulator, a device, or signing, or before the first macdev tool call.
---

# Mac Development MCP

The `macdev` MCP server is MCPProxy running on the user's MacBook Pro, reached
over Tailscale. It fronts two servers:

- **XcodeBuildMCP**: structured Xcode builds and tests, simulators, physical
  devices, debugging, and UI automation.
- **Desktop Commander**: terminal, git, filesystem, and process control on the Mac.

Use it instead of asking the user to do Mac steps by hand.

## Availability

The server is off by default, so the user enables it per chat. If no `macdev__*`
tools appear in your tool list or in the deferred tool catalog, ask the user to
enable Mac Development for the chat.

Connection errors mean the laptop is asleep or off the tailnet. Say so and ask
the user to wake it. Do not retry in a loop.

## Calling tools

MCPProxy exposes a small discovery surface, not every upstream tool.

1. Call `macdev__retrieve_tools` with a description of what you need.
2. Each result has an exact `name` and a `call_with` value. Invoke the tool
   through the `macdev__call_tool_*` variant named by `call_with`, passing that
   exact `name`.
3. When a returned signature is marked lossy (`~`) or is unclear, call
   `macdev__describe_tool` for the full schema before invoking it.

Call `macdev__retrieve_tools` and `macdev__describe_tool` directly. Only names
that `retrieve_tools` returned go through `call_tool_*`; do not guess upstream
tool names.

## Before building

XcodeBuildMCP builds what is on the Mac's disk, not what is in the Linux
workspace. Get the Mac checkout ready first with Desktop Commander:

1. Find or clone the repository on the Mac and check out the branch under test.
   Push from the workspace first so the Mac can fetch it.
2. Update submodules.
3. Run any project generation step the repository uses (XcodeGen, Tuist, or a
   script) so the `.xcodeproj` or `.xcworkspace` exists and is current.

Then build, test, or run through XcodeBuildMCP, and report those results as Mac
or Xcode validation, separate from anything validated on Linux.

## Care on the user's Mac

This is the user's personal laptop, not a disposable workspace. Stay inside the
project checkout and Xcode's own build and simulator state. Do not change system
settings, install software, or delete files outside the checkout unless the user
asked for it.
