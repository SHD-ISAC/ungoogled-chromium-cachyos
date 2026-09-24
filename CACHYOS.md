# CachyOS znver4 build

This branch keeps the upstream `ungoogled-software/ungoogled-chromium-archlinux`
packaging intact and adds a thin CachyOS build layer.

## Goal

Build `ungoogled-chromium` using the official CachyOS Zen 4 build environment:

- package architecture: `x86_64_v4`
- C/C++ target: `-march=znver4`
- optimization level: `-O3`
- CachyOS hardening/linker defaults
- Chromium's own ThinLTO handling remains controlled by the upstream PKGBUILD

This is intended for Zen 4 systems such as Ryzen 7000/7040-class CPUs. The
resulting package is not suitable for CPUs that do not implement the
x86-64-v4 ISA level.

## Why the PKGBUILD is not patched

The upstream PKGBUILD already contains Chromium-specific handling for compiler
flags, ThinLTO, system libraries, codecs, VA-API, Wayland/PipeWire support, and
the ungoogled-chromium patches. Keeping it unchanged minimizes merge conflicts
and makes security updates easier to follow.

The architecture tuning comes from the official CachyOS
`cachyos/docker-makepkg-znver4` image rather than hard-coding another set of
flags into the PKGBUILD.

## Build

Install Docker, then from this branch run:

```bash
docker pull cachyos/docker-makepkg-znver4:latest
./cachyos-build.sh
```

The helper exports both the package and an updated `.SRCINFO` into the
repository directory.

To use the generic x86-64-v4 CachyOS environment instead of Zen 4 tuning:

```bash
CACHYOS_MAKEPKG_IMAGE=cachyos/docker-makepkg-v4:latest \
  ./cachyos-build.sh
```

## Verify the package

After a successful build:

```bash
pacman -Qip ./ungoogled-chromium-*.pkg.tar.zst |
  grep -E '^(Name|Version|Architecture|Packager)'
```

For the default build, `Architecture` should be `x86_64_v4`.

The CachyOS znver4 build image currently uses
`PACKAGECARCH="x86_64_v4"` and `CFLAGS="-march=znver4 -O3 ..."`.

## Install

If `ungoogled-chromium-bin` is currently installed, remove it first:

```bash
sudo pacman -Rns ungoogled-chromium-bin
```

Then install the locally built package:

```bash
sudo pacman -U ./ungoogled-chromium-*.pkg.tar.zst
```

## Important performance note

The current upstream PKGBUILD uses the system Clang toolchain
(`_system_clang=1`) and sets `chrome_pgo_phase=0`. This branch deliberately
does not change that behavior.

Therefore, `znver4` means the native C/C++ portions are compiled for Zen 4,
but it does **not** guarantee that this package will outperform every generic
prebuilt Chromium binary. V8 JIT-generated code, GPU paths, profile-guided
optimization, and workload choice can matter more than the ISA baseline.

Benchmark first before introducing PGO/toolchain changes. Keeping the initial
fork small also makes Chromium security updates much safer to track.

## Keep the fork current

Configure the original packaging repository once:

```bash
git remote add upstream https://github.com/ungoogled-software/ungoogled-chromium-archlinux.git
```

Update the clean upstream-tracking branch:

```bash
git fetch upstream
git switch master
git merge --ff-only upstream/master
git push origin master
```

Then rebase the CachyOS branch:

```bash
git switch cachyos-znver4
git rebase master
git push --force-with-lease origin cachyos-znver4
```

Because the CachyOS branch only adds build-layer files, rebases should normally
remain simple.

## Security

Chromium is a high-exposure application. Rebuild promptly when the upstream
packaging repository publishes Chromium security updates. Architecture
optimization should never be used as a reason to remain on an older browser
release.
