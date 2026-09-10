# Standalone Blender Linux ARM64 release packages

`.github/workflows/build-blender-arm64.yaml` checks the official Blender download
index daily and supports `workflow_dispatch`. Leave `version` empty to
select the highest **published stable** version, or specify an exact version
such as `5.2.1`. Alpha/beta/RC builds are excluded. This does not automatically
backfill older LTS lines; dispatch an exact published version for those.

The workflow publishes **unofficial** builds under `blender-<version>` GitHub
Release tags. Existing public releases are immutable and skipped. Draft releases
left by interrupted publication can be retried. Releases are not marked as the
repository's latest release, so unrelated releases remain unaffected.

## Assets and consumer contract

- `blender-<version>-linux-arm64.tar.xz`: relocatable installation, including
  bundled Python, Blender resources, release-built libraries and build provenance.
- `blender-<version>-linux-arm64.tar.xz.sha256`: `sha256sum -c` compatible binary checksum.
- `SHA256SUMS`: checksums for the binary, corresponding source parts and build info.
- `BUILD-INFO.txt`: source commit, host ABI, compiler and workflow commit.
- `blender-<version>-linux-arm64-sources.tar.zst.part-NNN`: corresponding Blender
  source, upstream dependency source archives/patches, and this build recipe.
  Parts are below GitHub's 2 GiB per-asset limit. Reassemble in filename order:

  ```sh
  sha256sum -c SHA256SUMS
  cat blender-*-linux-arm64-sources.tar.zst.part-* | tar --zstd -xf -
  ```

The release tag points to the **recipe repository commit**, not Blender's commit.
Blender's exact source commit is recorded separately and checked against the tag
again in each build job. GitHub's automatic source ZIP/tarball contains this
repository and is **not** Blender's corresponding source.

## Build and portability decisions

- Native `ubuntu-24.04-arm` runners; no emulation, GPU, display server, or CUDA SDK.
- Resolve official published stable version → pin upstream Git tag commit → use
  that release's own dependency versions, hashes, patches and release CMake preset.
- Use the official `build_files/build_environment` source dependency builder
  (`make deps` equivalent), not Ubuntu's mismatched graphics/media library versions.
  The v5.2.1 source has no `lib/linux_arm64` precompiled-library submodule.
- Ubuntu packages provide host tools and system interfaces, not replacements for
  Blender's versioned OpenUSD/OpenImageIO/LLVM/Python/media dependency stack.
  `ubuntu-packages.txt` was checked against actual Noble ARM64 main/universe indexes.
- Release optimization and upstream ARMv8.2-A + dotprod/fp16/LSE baseline; never
  `-march=native`. This is **not** a generic ARMv8.0 or all-Raspberry-Pi build.
- Portable layout means relocatable, **not** manylinux-compatible. Ubuntu 24.04
  builds require glibc 2.39 or newer and compatible system graphics/audio libraries.
  Official Blender releases use older Rocky Linux to achieve a wider glibc floor.
- Preserve GUI support, CPU Cycles, OpenUSD, OpenVDB, Alembic, OpenColorIO, FFmpeg,
  bundled Python and NumPy. Strict CMake options prevent silent feature fallback.
  GPU-specific Cycles devices/kernel toolchains are explicitly disabled. This
  package is CPU-rendering oriented, not a GPU-rendering distribution.
- Blender's bundled Python/OpenUSD does not supply OpenUSD for system Python.
  Image-level system-Python OpenUSD integration is independent of this workflow.

## CI limits and retries

Dependencies and Blender compile in separate jobs to avoid sharing a six-hour job
budget. Dependency compilation stops after 270 minutes, leaving time to save
partial CMake/ExternalProject state. Re-run the failed workflow to continue from
that state. Work caches use immutable per-run keys with source/recipe-scoped restore
prefixes. Completed dependency bundles have exact source/recipe keys and are also
transferred between jobs as temporary Actions artifacts. Durable user downloads
are GitHub Release assets, not expiring Actions artifacts.

The dependency graph includes LLVM, OpenUSD, OpenImageIO, Python, FFmpeg and more.
Its disk, time and cache use can exceed standard GitHub-hosted runner/repository
limits. Cache persistence is best-effort, not a guarantee: eviction/quota limits or
runner cancellation can prevent recovery. Large partial caches may require an
increased repository cache budget or a larger persistent native ARM64 runner.
The workflow deliberately fails instead of publishing a stripped-down package.

Parallel compiler jobs are bounded to approximately one per 4 GiB RAM. External
projects run sequentially to avoid multiplying nested build concurrency. This
trades initial build speed for memory reliability.

## Local invocation

Use an ordinary sudo-capable user on native Ubuntu 24.04 ARM64:

```sh
export BLENDER_VERSION=5.2.1
export BLENDER_SOURCE_SHA=<commit-resolved-from-the-upstream-release-tag>
export BLENDER_WORK_DIR=/absolute/scratch/blender-arm64
bash blender-build/build.sh prepare
bash blender-build/build.sh dependencies
bash blender-build/build.sh blender
bash blender-build/build.sh package
```

Use a fresh scratch directory for `prepare`; later dependency invocations may reuse
the same directory. Do not change source/recipe revisions within a resumed build.

## Validation

```sh
python3 -m unittest discover -s blender-build -p 'test_*.py' -v
bash -n blender-build/build.sh
actionlint .github/workflows/build-blender-arm64.yaml
```

CI smoke-tests the installed binary with no GPU: imports NumPy, checks required
features, renders a tiny Cycles CPU image, and exports USD. Packaging validates all
ELF architectures and their shared-library resolution on the build host. See
[REVIEW.md](REVIEW.md) for implementation validation and remaining limitations.

## Official references

- https://developer.blender.org/docs/handbook/building_blender/linux/
- https://download.blender.org/release/
- https://github.com/blender/blender/tree/v5.2.1/build_files/build_environment
- https://github.com/blender/blender/blob/v5.2.1/build_files/build_environment/cmake/check_software.cmake
- https://github.com/blender/blender/blob/v5.2.1/build_files/build_environment/cmake/options.cmake
- https://github.com/blender/blender/blob/v5.2.1/build_files/cmake/config/blender_release.cmake
