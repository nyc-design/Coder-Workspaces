# modeling-dev

Headless, CPU-first CAD/mesh/scene tooling extending `python-dev`, built natively
for `linux/amd64` and `linux/arm64` with the existing GHCR digest/manifest workflow.
No GUI, X server, GPU, EEVEE support, or global browser frontend stack is implied.

## Tools and architecture availability

| Tool | Installation / architecture strategy |
| --- | --- |
| Blender | Latest complete **published `blender-X.Y.Z` repository release**, resolved once per CI run; official same-version Linux x64 tarball on amd64, source-built release tarball on ARM64. Both checksummed. Bundled Python / `bpy`, never pip `bpy`. |
| Assimp CLI | Ubuntu `assimp-utils`, available on amd64 and ARM64. |
| CadQuery / OCP | `cadquery==2.8.0`, `cadquery-ocp==7.9.3.1`; OCP and its VTK 9.5.2 dependency provide CPython 3.12 Linux wheels for both architectures. `pip --only-binary` fails rather than silently compiling unsupported dependencies. |
| OpenUSD | `usd-core==26.5` wheel on amd64. PyPI has **no Linux ARM64 wheels**, including older releases; ARM64 builds matching upstream `v26.05` from a SHA256-pinned archive with system TBB and Python. Core scene/data bindings (`pxr`), without imaging, usdview, or extra command-line tools. |
| glTF validator | Locked, architecture-independent Khronos `gltf-validator` JS package, plus `gltf-validate` helper because npm does not ship a CLI. |
| PDF | `pypdf==6.18.0` (pure Python), `pypdfium2==5.13.0` (Linux wheels for both architectures). |

Inherited Python developer tools are not reinstalled. Project-specific libraries
such as gerbonara and texture2ddecoder, global three.js, and pip bpy are excluded.
Package versions above were verified against PyPI, including full dependency
resolution for Python 3.12 / both Linux architectures. The image inherits its
Python/Ubuntu versions from `python-dev`; new base versions must retain compatible
wheels or update these pins.

## Blender release contract

Both architectures pin Blender 5.1.0 and verify SHA256 before extraction.
AMD64 uses the official `blender-5.1.0-linux-x64.tar.xz` distribution and its
existing checksum. ARM64 uses the approved third-party
[`lfdevs/blender-linux-arm64` v5.1.0](https://github.com/lfdevs/blender-linux-arm64/releases/tag/v5.1.0)
asset `blender-5.1.0-git20260325.ae6d847d66fa-aarch64.tar.gz`, SHA256
`a4927219950566af13572e72f31b5bcb8baf87190ee86a26e2572ce7fd059793`.
These are not official Blender Foundation ARM64 Linux binaries. No moving
release lookup or source build is used; package updates require review.

### Safe CPU startup defaults

The ARM64 package renders successfully with Cycles CPU denoising disabled;
enabling denoising caused SIGILL in native testing. `30-modeling.sh` explicitly
runs `modeling-safe-defaults.py` to save an initial user `startup.blend` with
CPU rendering and final/preview denoising disabled. Existing user startup files
are preserved, not silently overwritten. This is a scene startup configuration,
not a global preference or an enforcement hook: **loaded projects, existing
startup files, and `--factory-startup` can enable denoising again**. Set
`scene.cycles.use_denoising = False` explicitly in automated render scripts.

Image smoke tests fail on missing USD, wrong Blender version, failed CPU render,
invalid GLB, failed USDZ export, or invalid/empty/CRC-damaged USDZ ZIP archives.
Runtime checks run exports without rendering; image builds pass `--render`.

## Usage

```sh
blender --background --factory-startup --python-exit-code 1 --python model.py
assimp info mesh.obj
gltf-validate scene.glb > validation.json
python3 -c 'import cadquery, OCP; from pxr import Usd; import pypdf, pypdfium2'
modeling-smoke-check
modeling-smoke-check --render
```

For Blender renders, explicitly select `scene.render.engine = 'CYCLES'` and
`scene.cycles.device = 'CPU'`. System Python's CAD/USD/PDF libraries are separate
from Blender's bundled interpreter. Do not assume they are importable inside
Blender. ARM64 source OpenUSD registers `/opt/openusd/lib/python` through a
system Python `.pth` file and `/opt/openusd/lib` through the dynamic loader
configuration; no global `PYTHONPATH` is imposed on Blender.

`gltf-validate` accepts `.gltf` and `.glb`, outputs the validator JSON report, and
returns 0 for no validation errors (warnings remain in the report), 1 for invalid
assets, and 2 for usage/I/O/runtime errors. Referenced resources must be local,
inside the asset directory; network requests and escaping paths/symlinks are
rejected.

## Layers and checks

`30-modeling` contributes a prompt, empty settings/extension manifests (Python
editor support is inherited), and skill placeholder directories using the standard
shared destinations. Startup runs the fast tool/operation smoke check. Every
native image build additionally renders the default Blender scene to a 32×32 PNG
with one Cycles CPU sample as the non-root `coder` user, gating publication.

```sh
python3 -m unittest discover -s workspace-images/modeling-dev/tests -v
for script in workspace-images/modeling-dev/scripts/*.sh workspace-images/modeling-dev/init.d/*.sh; do
  bash -n "$script" || exit
done
node --check workspace-images/modeling-dev/scripts/gltf-validate.cjs
```

Validator integration tests run when the locked npm dependencies are installed at
`/opt/modeling-tools`; otherwise those tests are explicitly skipped. Release
selection tests use mocked GitHub responses and run without network access.
