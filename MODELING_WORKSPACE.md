# Modeling Workspace Integration

## Existing repository usage

`modeling-dev` extends `python-dev`, inheriting the Python workspace environment
and adding Blender. It is separate from the Vite/fullstack image lineage.

Existing repositories select the published `modeling-dev` image in their own
`.devcontainer/devcontainer.json`, or use a Dockerfile based on that image, then
create/rebuild the workspace through the normal existing-project flow. Use the
registry and tag published by the modeling image workflow; this document does
not assert that the new image is already available.

The shared envbuilder module is image-agnostic; no new module-level image enum
or mapping is required. The template's `base-dev` fallback is not a modeling
image override. Reusing a Python devcontainer without changing its image does
not select `modeling-dev`.

## Deferred new-project integration

The `project-workspace` template intentionally does **not** expose a modeling
project-type option. Project types select external scaffold branches rather
than directly selecting an image, and `nyc-design/Project-Scaffolds` has no
`scaffold/modeling` branch as verified during this integration.

A future, separately scoped change could publish and validate a modeling
scaffold with the appropriate devcontainer before adding a template option.
That work would also verify scaffold initialization supports
`NEW_PROJECT_TYPE=modeling` and update Coder Agents' central project-type policy
if needed. No external scaffold or central prompt changes are required for
existing-repository image use, and none are part of this integration.

## Blender package source

ARM64 Blender uses the user-approved third-party community package from
[`lfdevs/blender-linux-arm64`](https://github.com/lfdevs/blender-linux-arm64),
stable release `v5.1.0` (not an official Blender Foundation ARM64 Linux binary).

- Asset: `blender-5.1.0-git20260325.ae6d847d66fa-aarch64.tar.gz`
- SHA-256: `a4927219950566af13572e72f31b5bcb8baf87190ee86a26e2572ce7fd059793`
- Package updates require explicit review; no source compilation or automatic updates.
- The previous standalone source-build workflow and `blender-build/` tooling remain removed.

## Validation and rollout

Verified on native ARM64 with the selected package:

- Background execution reports Blender `5.1.0`.
- USD support is enabled (`true`).
- Default-scene USDZ export and archive integrity checks pass.
- CPU rendering passes with denoising disabled.
- CPU rendering with denoising enabled fails with `SIGILL`; keep denoising disabled for the verified path.

Apple Vision Pro / RealityKit device compatibility is **untested**. Successful
USDZ export does not establish device compatibility. The full modeling image
build and end-to-end workspace rollout are **untested**; package-level checks
do not establish image-level readiness.
