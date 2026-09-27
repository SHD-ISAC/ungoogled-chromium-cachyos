# CachyOS znver4 build

`master` tracks upstream. `cachyos-znver4` adds the CachyOS build and release
layer, while preserving the upstream Chromium patches and compiler settings.
The initial `153.0.8010.47-1` package was built and installed successfully on
the maintainer's Zen 4 machine. Changes to the build helpers still need a full
build on that machine before they can be considered end-to-end validated.

## Build settings

- Official image: `cachyos/docker-makepkg-znver4:latest`
- Package architecture: `x86_64_v4`; C/C++ tuning: `-march=znver4 -O3`
- Default parallelism: **8**, including Ninja, Make and package compression
- Upstream system Clang, `chrome_pgo_phase=0`, Chromium ThinLTO, codecs,
  VA-API, Wayland/PipeWire and ungoogled-chromium patches are preserved

The package is intended for Zen 4 systems such as Ryzen 7000/7040. It cannot
run on a CPU without x86-64-v4 support. Tuning alone does not guarantee better
performance than every generic build: PGO, V8's JIT and GPU workloads matter.

The small PKGBUILD delta is the validated `CHROMIUM_BUILD_JOBS` setting and
the checksum of the modified `fetch-chromium-release` helper. Source checksum
verification is enabled; builds do not rewrite checksums or use `--skipinteg`.
The manually fetched Chromium Git tree is not itself covered by the tarball
checksum: it is selected by its release tag, and a prefetched tree is trusted
local input. The completion marker and version check are not a signature.

## Prefetch and build

Requirements: Linux, a compatible Zen 4 CPU, Docker available to your user,
Bash, Git, coreutils, `flock`, and `bsdtar` (`libarchive` on Arch/CachyOS).
Use an ordinary user account. Keep enough RAM and disk space available for a
full Chromium build; 8 jobs is a concurrency limit, not a hard memory limit.

```bash
./prefetch-chromium.sh
./cachyos-build.sh
```

Prefetch uses the already-tested private Python 3.13 shim for depot_tools.
You can enable WARP for this download, then disable it before starting the
GitHub runner. Interrupted dependency downloads remain in staging and are
retried on the next invocation. A lock prevents two prefetch processes from
writing to the shared Git dependency cache. Completed caches are reused.

Both helpers use the same layout:

```text
~/.cache/ungoogled-chromium-cachyos/
    chromium-source/chromium-VERSION/
    chromium-source/.prefetch-VERSION/
    git-cache/
```

Existing completed caches remain compatible. In **both** helpers,
`CHROMIUM_CACHE_DIR` means the base directory containing `chromium-source`
and `git-cache`, not `chromium-source` itself. To relocate it:

```bash
env CHROMIUM_CACHE_DIR=/path/to/cache ./prefetch-chromium.sh
env CHROMIUM_CACHE_DIR=/path/to/cache ./cachyos-build.sh
```

Prefetch is recommended, especially when the runner and Chromium download
need different network routes. Without a completed cache, the upstream
makepkg prepare step fetches Chromium normally; that path also needs working
depot_tools Python/network access in the build container.

Each build writes into a new `build-output/TIMESTAMP-PID/` directory. The
helper prints the exact path. To choose a directory or lower parallelism:

```bash
env CHROMIUM_BUILD_JOBS=6 CACHYOS_OUTPUT_DIR=/path/to/empty-output ./cachyos-build.sh
```

The chosen output directory must be empty; previous packages are never
silently deleted or mistaken for the result of a new build. The source cache
is mounted read-only. The container is removed on completion/cancellation;
the host-side `build.log` remains available even on failure. makepkg logs are
exported on normal failure as well as success.

`CACHYOS_MAKEPKG_IMAGE` can select an official image by digest to hold the base
image constant. The build records the resolved image ID/digest, makepkg
configuration, installed packages, recipe commit and dirty state. Pacman still
performs a full upgrade inside the disposable container, so this metadata does
not constitute a reproducible-build guarantee or a cryptographic attestation.

## Verify and install

Successful outputs include the package, `SHA256SUMS`, `package.PKGINFO`,
`package.BUILDINFO`, `package.SRCINFO`, build-environment details and logs.
The verifier requires exactly one package with the expected name, version
and `x86_64_v4` architecture. It reads archive metadata, independent of locale.

```bash
./scripts/verify-package.sh /path/to/output
cd /path/to/output
sha256sum -c SHA256SUMS
sudo pacman -U ./ungoogled-chromium-*.pkg.tar.zst
```

If `ungoogled-chromium-bin` is installed, remove that conflicting package
first with `sudo pacman -Rns ungoogled-chromium-bin`.

## GitHub Actions

All jobs run on your self-hosted runner with labels
`[self-hosted, Linux, X64, zen4]`. Use a current Actions runner compatible with
Node 24 actions. Install Python 3 and `bsdtar` on the runner for validation;
Docker and x86-64-v4 CPU features are checked for actual builds.

Only trusted branch/tag pushes and manual dispatches run this workflow. There
is no pull-request trigger on the self-hosted machine. Checkout credentials
are not persisted. The normal GitHub token is read-only; the dedicated release
token is exposed only to release-related steps. Actions are pinned to full
commit hashes with version comments. The unused upstream staged-build action
and its npm dependencies have been removed from this branch.

Branch/tag jobs share one concurrency group. An in-progress build is allowed
to finish; GitHub may replace an older **pending** run with a newer pending
run. This prevents branch and tag builds from competing on the same runner.
This does not serialize builds launched manually outside Actions.

| Trigger | Behavior |
| --- | --- |
| Push build/helper/workflow changes to `cachyos-znver4` | Validate, build, verify, upload artifact |
| Push tag `znver4-VERSION-RELEASE` | Build and publish a Release after verification |
| Push tag `znver4-upload-VERSION-RELEASE` | Reuse the package in `CACHYOS_EXISTING_PACKAGE_PATH`, verify, publish |
| Manual dispatch with empty `existing_package_path` | Build and upload artifact |
| Manual dispatch with `existing_package_path` | Verify and upload an existing package |

Tag names must match PKGBUILD's version/release exactly. A manual dispatch on
a release tag also publishes that release. Keep reusable packages outside the
runner checkout so `actions/checkout` cannot remove them. Reused packages must
match PKGBUILD; their original build commit is **not** inferred from the commit
running the upload workflow. `.BUILDINFO` is packaged metadata, not proof of
source-to-binary correspondence.

Optional repository variables:

- `CHROMIUM_BUILD_JOBS`: default job count for push builds (otherwise 8).
- `CHROMIUM_CACHE_DIR`: cache base on the runner; defaults to its user's cache.
- `CACHYOS_EXISTING_PACKAGE_PATH`: absolute package path for upload-only tags.

For Releases, keep the existing repository secret `RELEASE_TOKEN`. Scope it
to this repository with the permissions needed by your release operation
(Contents write; Workflows write when GitHub requires it for the target ref).
Missing tokens and mismatched tags are rejected before compilation. A token
presence check cannot prove that its permissions or expiry are correct.

Since `master` stays upstream-only, the UI's **Run workflow** button may be
absent. GitHub documents API/CLI dispatch of a workflow after its first run;
use the registered numeric workflow ID with `--ref cachyos-znver4` if filename
resolution on the default branch fails. Upload tags provide another route
without changing `master` or committing one-shot absolute paths to the repo.
See [GitHub's dispatch documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).

Artifacts include checksums and metadata and are retained for 30 days.
Diagnostics are uploaded on success/failure and retained for 7 days. Artifact
names include the run ID and attempt, avoiding collisions when rerunning jobs.
Actions outputs use a run-specific directory under `RUNNER_TEMP`, outside the
checkout; GitHub may clean that directory after the job, so download artifacts
for long-term retention. Build logs are not uploaded as Release assets.

## Maintain and validate

Keep `master` aligned with upstream, then merge it into the customization
branch without rewriting already-published history:

```bash
git fetch upstream
git switch master
git merge --ff-only upstream/master
git push origin master
git switch cachyos-znver4
git merge master
```

Resolve packaging changes, refresh only checksums of files you intentionally
changed, and validate before pushing. Follow Chromium security updates promptly.

```bash
python3 -m unittest discover -s tests -v
shellcheck -x cachyos-build.sh prefetch-chromium.sh fetch-chromium-release scripts/*.sh
actionlint
```

The offline regression suite exercises cache publication/collisions, retries,
version pinning, cancellation cleanup, invalid resource limits and package
identity checks. It does not download Chromium or start Docker, and is not a
replacement for compiling and installing the browser on the intended runner.
