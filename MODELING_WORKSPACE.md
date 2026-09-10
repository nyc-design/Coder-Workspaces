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

## Build and package contract

The modeling image lineage is:

```text
base-dev → python-dev → modeling-dev
```

The separate Blender ARM64 source build is
`.github/workflows/build-blender-arm64.yaml`. Producers and consumers must agree
on these exact names:

| Item | Name |
| --- | --- |
| Package release tag | `blender-<version>` |
| Linux ARM64 archive | `blender-<version>-linux-arm64.tar.xz` |

The source package and modeling image have separate build responsibilities.
Publish the required Blender archive before expecting its modeling image
consumer to build successfully.

## Validation and rollout

Native ARM64 Blender compilation and end-to-end modeling workspace execution
have not been validated locally. CI must demonstrate the source build and
subsequent image build before those paths are considered tested.

For existing-repository usage:

1. Build and publish the ARM64 Blender package using the agreed tag and asset.
2. Build and publish `modeling-dev` through its image workflow.
3. Configure a repository's devcontainer to select the published modeling image.
4. Create/rebuild that repository's workspace through the existing-project flow.
5. Smoke-test Python imports and headless Blender startup.

No new-project template option or external scaffold is needed for this flow.
