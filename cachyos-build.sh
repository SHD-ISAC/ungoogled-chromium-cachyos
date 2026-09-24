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
    --pull=always \
    --name "$builder_name" \
    -e EXPORT_PKG=1 \
    -e EXPORT_SRCINFO=1 \
    -e SYNC_DATABASE=1 \
    -v "$repo_root:/pkg" \
    "$image" \
    /bin/bash -lc '
        set -euo pipefail

        echo "==> Preparing pacman inside the build container"

        # pacman 7 download sandboxing can fail under Docker when Landlock
        # rules cannot be applied. Disable it only inside this ephemeral
        # build container; the host pacman configuration is untouched.
        if grep -q "^#DisableSandbox" /etc/pacman.conf; then
            sudo sed -i "s/^#DisableSandbox/DisableSandbox/" /etc/pacman.conf
        elif ! grep -q "^DisableSandbox" /etc/pacman.conf; then
            echo "DisableSandbox" | sudo tee -a /etc/pacman.conf >/dev/null
        fi

        # Bootstrap current signing trust before the image performs its full
        # system upgrade. Re-populating an old keyring is not enough when new
        # Arch packager keys have been added since this image was published.
        sudo pacman-key --init
        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        echo "==> Updating repository databases and keyring packages first"
        sudo pacman -Syy --noconfirm

        # Arch recommends updating archlinux-keyring before a full upgrade
        # when package signatures are newer than the local trust database.
        keyring_packages=(archlinux-keyring)
        if pacman -Si cachyos-keyring >/dev/null 2>&1; then
            keyring_packages+=(cachyos-keyring)
        fi
        sudo pacman -S --needed --noconfirm "${keyring_packages[@]}"

        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        # Refresh CachyOS mirror ordering at build time. A stale/lagging
        # mirror should not pin the build to 404s from an old mirror list.
        if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
            sudo cachyos-rate-mirrors || true
        fi

        # Discard package files fetched during bootstrap so /run.sh starts
        # from a clean cache after the trust database has been refreshed.
        sudo pacman -Scc --noconfirm || true

        exec /run.sh
    '

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
    pacman -Qip "$pkg" | grep -E "^(Name|Version|Architecture|Packager)" || true
done

echo
echo "==> Expected default target: Architecture=x86_64_v4, C/C++ tuned with -march=znver4"
