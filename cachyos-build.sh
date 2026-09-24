#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

image="${CACHYOS_MAKEPKG_IMAGE:-cachyos/docker-makepkg-znver4:latest}"
builder_name="ungoogled-chromium-cachyos-${USER:-builder}-$$"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required" >&2
    exit 1
fi

if [[ ! -f PKGBUILD ]]; then
    echo "error: PKGBUILD not found in $repo_root" >&2
    exit 1
fi

echo "==> Build image: $image"
echo "==> Source tree: $repo_root"
echo "==> Building ungoogled-chromium in the official CachyOS makepkg environment"

docker run --rm \
    --name "$builder_name" \
    -e EXPORT_PKG=1 \
    -e EXPORT_SRCINFO=1 \
    -e SYNC_DATABASE=1 \
    -v "$repo_root:/pkg" \
    "$image"

shopt -s nullglob
packages=(ungoogled-chromium-*.pkg.tar.zst)

if (("${#packages[@]}" == 0)); then
    echo "error: build completed but no ungoogled-chromium package was found" >&2
    exit 1
fi

echo
echo "==> Built package metadata"
for pkg in "${packages[@]}"; do
    echo "--- $pkg"
    pacman -Qip "$pkg" | grep -E '^(Name|Version|Architecture|Packager)' || true
done

echo
echo "==> Expected default target: Architecture=x86_64_v4, C/C++ tuned with -march=znver4"
