# CachyOS znver4 build

`master` tracks upstream. `cachyos-znver4` adds the build/release layer.
The known installed package is `153.0.8010.47-1`; read PKGBUILD for the current
recipe version. Changes to helpers need a full build before they can be called
end-to-end validated.

## One-command build

Requirements: Linux with x86-64-v4 CPU support, Docker access, Bash, Git,
coreutils, `flock`, Python 3 and `bsdtar` (`libarchive` on CachyOS). Run as an
ordinary user. Keep enough RAM/disk for a full Chromium build.

```bash
./cachyos-build.sh
```

This starts Docker if the local service is stopped, prepares the requested
source cache if needed, builds and verifies the package. Docker is not enabled
at boot. Completed caches are reused; interrupted downloads resume in staging.
The same resolved Docker image is used for prefetch and compilation.

For Actions, start your installed runner with:

```bash
./scripts/run-runner.sh
```

This starts Docker and runs the runner once. It exits after one build/upload
job. Hosted validation and release publishing finish independently.

## Save your proxy once

```bash
mkdir -p ~/.config/ungoogled-chromium-cachyos
cp -n config/build.env.example ~/.config/ungoogled-chromium-cachyos/build.env
```

Edit that file and uncomment this setting with **your actual HTTP or mixed
listener port**:

```bash
CACHYOS_PROXY_URL=http://127.0.0.1:7890
```

7890 is an example. Use an HTTP proxy URL even for HTTPS destinations, which
use CONNECT. A SOCKS-only port is unsuitable for this shortcut because the
download tools do not all support SOCKS in the same way.

The helpers pass upper/lowercase proxy variables into both containers for
Git, depot_tools/gsutil, npm, Python and makepkg downloads. Pacman's proxy
environment survives sudo inside the disposable container, including when
makepkg installs dependencies. TLS/signature checks stay enabled; the host's
sudoers file is not changed.

A loopback proxy automatically selects `--network host` on normal Linux
Docker Engine so the container can reach the laptop's listener. A non-loopback
proxy uses bridge networking by default. Host networking shares the host's
network namespace. For remote/rootless Docker contexts, use a proxy address
reachable from that Docker host, rather than your laptop's `127.0.0.1`.

The container proxy setting does not change desktop routing or the runner's
GitHub connection. If the runner also needs a proxy, set
`CACHYOS_RUNNER_PROXY_URL=http://127.0.0.1:YOUR_PORT` and use
`./scripts/run-runner.sh`. Restart the runner to apply the setting.

Existing `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy` variables
and their uppercase variants are forwarded. Lowercase takes precedence when
the two variants disagree. Environment variables override the saved config;
`CACHYOS_CONFIG_FILE` selects another trusted Bash configuration file.

For a temporary override (works from fish or Bash):

```bash
env CACHYOS_PROXY_URL=http://127.0.0.1:YOUR_PORT ./cachyos-build.sh
```

Keep proxy passwords in the local file or an Actions secret. The helpers pass
proxy variable names to Docker without logging their values or putting values
in Docker's command arguments. Download programs may still report network
details in their own diagnostics; inspect logs before sharing them.

### Docker image pulls need the daemon's proxy

Container environment variables do not configure the Docker daemon's image
pulls. If `docker pull` is blocked, configure that daemon separately once.
For systemd-managed Docker Engine, this is an example drop-in:

```ini
# /etc/systemd/system/docker.service.d/proxy.conf
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:YOUR_PORT"
Environment="HTTPS_PROXY=http://127.0.0.1:YOUR_PORT"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
```

Apply it while no build container is running:

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

A router-level proxy/TUN is also usable if it actually covers Docker traffic.
Retries can handle interruptions; they cannot fix a blocked route.

The image is pulled once per build by default. To deliberately reuse an
already-downloaded image without pulling it again:

```bash
env CACHYOS_IMAGE_PULL=missing ./cachyos-build.sh
```

`always` is the default; `never` requires an existing local image. Failed
pulls are reported rather than silently falling back to an older image.
See [container proxies](https://docs.docker.com/engine/cli/proxy/),
[daemon proxies](https://docs.docker.com/engine/daemon/proxy/) and
[host networking](https://docs.docker.com/engine/network/drivers/host/).

## GitHub Actions: less laptop work

| Stage | Where it runs |
| --- | --- |
| Tests, Bash syntax, ShellCheck and Actionlint | GitHub-hosted Ubuntu |
| Prefetch, compilation, verification and first artifact upload | Configured build runner |
| Artifact download, checksum recheck and Release upload | GitHub-hosted Ubuntu |

Ordinary pushes and PRs only validate. They do not start a multi-hour build.
Compilation is explicit:

| Trigger | Behavior |
| --- | --- |
| Ordinary push to `cachyos-znver4` or PR targeting it | Hosted validation only |
| Push whose head commit contains `[build]` | Validate, build and upload artifact |
| Tag `znver4-VERSION-RELEASE` | Build, upload artifact, publish Release in the cloud |
| Tag `znver4-upload-VERSION-RELEASE` | Reuse `CACHYOS_EXISTING_PACKAGE_PATH`, upload and publish |
| Dispatch with empty `existing_package_path` | Build and upload artifact |
| Dispatch with `existing_package_path` | Verify/upload existing package |

PRs never execute on a self-hosted machine. Release tags must match PKGBUILD.
A dispatch on a release tag also publishes it. Token presence and tag spelling
are checked on the hosted validator before using the build machine.

`master` remains upstream-only. GitHub's normal manual-dispatch UI/default-branch
requirement still applies; do not rely on a **Run workflow** button while the
workflow is absent from the default branch. A trusted build-request commit
or tag works without GitHub CLI or modifying `master`.
See [workflow_dispatch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).

Keep the repository secret `RELEASE_TOKEN` scoped to this repository, with
Contents write and Workflows write when required for the target ref. It is
available only to hosted release preflight/publishing steps, not to compilation.
Presence alone does not prove permissions or expiry.

If Release publishing fails after artifact upload, choose **Re-run failed
jobs**. Only the hosted release job retries; the successful build is not rerun.
The artifact must still exist (30-day retention). The laptop can finish its
work after the build job completes, including package/diagnostic uploads.
Failures before successful artifact upload still need that build runner.

Reused packages must be outside the checkout and match PKGBUILD. Their original
source revision is not inferred from the upload commit. Actions are pinned to
commit hashes; the Actionlint archive has a pinned version and SHA-256.
Checkout credentials are not persisted.

## Move compilation to another machine

Register an Actions runner on a **Linux x86-64-v4-capable machine with Docker**
and enough RAM/disk. Give it a distinct label and set this repository variable
as JSON, for example:

```text
CACHYOS_BUILD_RUNNER=["self-hosted","Linux","X64","chromium-builder"]
```

The default remains `["self-hosted","Linux","X64","zen4"]`. CPU features are
checked before the build. A generic older x86 CPU can fail to run the znver4
image's tools or generated host programs. Install the same host requirements
and configure that machine's proxy if necessary.

This selects the builder; it does not provision or pay for a server. A LAN
machine removes compilation from the laptop. A suitable overseas machine can
also remove the GFW from its download path.

A free standard GitHub Linux runner is not a validated full-build replacement.
GitHub advertises 4 CPUs, 16 GB RAM, 14 GB SSD and a 6-hour hosted-job limit.
Your successful build took about 5h18 on the 7940HS, and its source cache alone
was around 26 GiB. Cleaning preinstalled tools is not proof of enough build
space; standard labels also do not guarantee x86-64-v4 support.
See [runner resources](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
and [Actions limits](https://docs.github.com/en/actions/reference/limits).

Optional repository variables:

- `CHROMIUM_BUILD_JOBS`: concurrency override; otherwise saved config/default 8.
- `CHROMIUM_CACHE_DIR`: cache base on the selected runner.
- `CACHYOS_MAKEPKG_IMAGE`: official image, optionally pinned by digest.
- `CACHYOS_PROXY_URL`: container proxy; use a secret if it includes credentials.
- `CACHYOS_EXISTING_PACKAGE_PATH`: absolute path for upload-only tags.
- `CACHYOS_BUILD_RUNNER`: JSON runner labels.

## Build settings, caches and outputs

The official image is `cachyos/docker-makepkg-znver4:latest`. Package architecture
is `x86_64_v4`; tuning comes from the image. The validated concurrency default
remains **8**, including Ninja, Make and compression. Upstream system Clang,
disabled Chrome PGO, ThinLTO, codecs, VA-API, Wayland/PipeWire and UC patches
are preserved.

Both helpers share this layout:

```text
~/.cache/ungoogled-chromium-cachyos/
    chromium-source/chromium-VERSION/
    chromium-source/.prefetch-VERSION/
    git-cache/
```

`CHROMIUM_CACHE_DIR` means the cache base, not `chromium-source` itself.
Existing completed caches remain compatible. A build lock serializes local
and Actions builds sharing that cache; another lock protects prefetch.

`./prefetch-chromium.sh` remains available for downloading only. It retains
the private Python 3.13 shim for depot_tools. `CACHYOS_AUTO_PREFETCH=0` skips
automatic prefetch and requires a completed cache for the requested version.

Each build uses a fresh `build-output/TIMESTAMP-PID/` directory. An explicit
`CACHYOS_OUTPUT_DIR` must be empty. The source cache is read-only during build.
Cancellation removes the prefetch/build container while preserving caches/logs.
Outputs include the package, checksums, archive metadata, build environment,
package list and logs. Actions artifacts last 30 days; diagnostics last 7 days.
Actions temporary output directories may be cleaned after the job.

Source checksum verification remains enabled. Manual Chromium Git downloads
are selected by release tag; caches are trusted local inputs, not signed
archives. .BUILDINFO/provenance are metadata, not proof of source-to-binary
correspondence. The image and upgraded container packages are recorded, without
a reproducible-build guarantee.

To verify and install:

```bash
./scripts/verify-package.sh /path/to/output
cd /path/to/output
sha256sum -c SHA256SUMS
sudo pacman -U ./ungoogled-chromium-*.pkg.tar.zst
```

The verifier requires exactly one package of the expected name, version,
filename and v4 architecture, reading .PKGINFO directly.

## Maintain and validate

Merge upstream packaging updates into `cachyos-znver4` and inspect conflicts.
Normal merges validate without compiling. Preserve the Ninja job limit and
manual-fetch helper checksum during PKGBUILD conflicts. Chromium security
updates still need a new build.

```bash
python3 -m unittest discover -s tests -v
shellcheck -x cachyos-build.sh prefetch-chromium.sh fetch-chromium-release scripts/*.sh
actionlint
```

Offline tests cover identity/checksums, cache publication/version pinning,
cancellation, locks, config overrides, proxy propagation and route errors.
They do not download Chromium or run real containers. Hosted checks use real
archive tools. A full compile/install remains a separate validation step.
