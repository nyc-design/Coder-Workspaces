# Implementation review / handoff

## Contract

- Workflow name: **Build Blender ARM64 package**.
- Daily schedule `31 5 * * *`; manual optional exact published version.
- Release tag: `blender-<version>`.
- Binary: `blender-<version>-linux-arm64.tar.xz`.
- Binary checksum: `blender-<version>-linux-arm64.tar.xz.sha256`.
- No commits/pushes performed. Changes limited to this directory and the standalone workflow.
- Image-level Blender and system-Python OpenUSD integration remains separately owned.

## Validation completed

- Seven Python unit tests passed (five release-discovery tests, two ELF/runtime validation tests).
- `bash -n blender-build/build.sh` passed.
- `/tmp/modeling-tools/actionlint .github/workflows/build-blender-arm64.yaml` passed.
- Python byte-compilation passed; generated `__pycache__` removed.
- Scoped `git diff --check` passed.
- Live official download index selected stable **5.2.1**.
- Live upstream tag resolved to **9e2066aef7ef7e20c142ad7bd3303138a4304c93**.
- All 83 host package names verified in Ubuntu Noble ARM64 main/universe package indexes.
- Smoke-test `bpy.app.build_options` names verified against v5.2.1 source.
- Shellcheck standalone binary was unavailable; actionlint completed with available tooling.
- **Full source dependency build, Blender compilation, packaging, installed smoke tests,
  cache recovery and GitHub publication have NOT been executed.** No claim of a proven
  end-to-end build is made.

## Research-backed design

The current source's `.gitmodules` lists precompiled linux_x64, macOS ARM64 and
Windows libraries, but **no Linux ARM64 library submodule**. Official Blender Linux
build documentation explicitly supports `make deps` producing `lib/linux_arm64` and
warns that source dependency builds are primarily maintainer workflows and may need
platform-specific debugging. The same documentation warns that distribution package
libraries are unsuitable for portable packages. Accordingly this workflow builds
release-pinned dependencies with upstream `build_environment`, upstream hashes and
patches, then applies `blender_release.cmake` with strict feature requirements.

Confirmed upstream dependency ARM baseline is `armv8.2-a+dotprod+fp16+lse`. GPU
compiler branches are architecture-gated upstream; Blender's own GPU Cycles devices
and binary compiler options are explicitly disabled. CPU Cycles, GUI support,
OpenUSD, OpenVDB, Alembic, OpenColorIO, FFmpeg, Python and NumPy are retained. The
recipe does not intentionally remove features to make a first compile succeed.

## Important caveats / likely first-CI issues

1. **Capacity/time:** LLVM, OpenUSD and the full media stack are large. Standard
   hosted ARM runners may run out of disk, RAM, cache quota, or job time. Separate
   dependency/Blender jobs, RAM-bounded parallelism, a 270-minute dependency timeout,
   exact-key completed caches and resumable per-run work caches mitigate this but
   do not guarantee hosted-runner feasibility. Retry failed runs to restore partial
   dependency builds. A larger cache budget/persistent native ARM runner may be needed.
2. **Toolchain/dependency compatibility:** GCC 14 and prerequisites are available on
   Noble ARM64, but availability is not proof every pinned dependency compiles there.
   Upstream ARM source-build support can regress per Blender release. Strict CMake
   intentionally fails rather than silently removing supported features.
3. **Portability:** glibc >= 2.39 and ARMv8.2-A + dotprod/fp16/LSE, not all ARM64 CPUs
   or older distros. System graphics/audio libraries remain runtime requirements.
   Packaging checks every ELF, then temporarily hides the harvested dependency tree
   and relocates the install before repeating the CPU-render/USD-export smoke test.
4. **GPU:** no GPU is required, but GPU Cycles devices/toolchains are disabled. This is
   CPU-rendering oriented, not feature-equivalent to every official GPU distribution.
5. **Source/license payload:** Blender source, dependency source archives, upstream
   patches and build recipe ship as split durable release assets. This avoids
   mistaking this repo's automatic GitHub source archive for corresponding source.
   Final redistribution/license compliance should be reviewed on actual output.
6. **Caching:** partial caches may exceed GitHub quotas; timeout recovery needs an
   explicit rerun. Existing public releases are skipped; drafts may resume uploads.
7. **Trigger semantics:** use `workflow_run` with the exact workflow name above, not
   a release-event trigger (GITHUB_TOKEN publications do not trigger ordinary release
   workflows). A scheduled successful no-op still emits workflow completion. No-op
   runs have **no `blender-arm64-release` Actions artifact**; image integration can
   check that artifact's presence on the triggering run to avoid unnecessary builds.
   Published binary/checksum artifacts themselves are durable GitHub Release assets.

## Scope / GitNexus

Only new files were authored; no pre-existing functions/classes were changed.
Impact queries for newly introduced symbols returned not indexed/unknown (no known
existing callers); there is no existing execution-flow blast radius to report.
No commit was attempted, so no commit-time detect-changes step was needed.
