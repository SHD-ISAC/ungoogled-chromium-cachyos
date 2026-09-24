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
    -v "$repo_root:/pkg" \
    "$image" \
    /bin/bash -lc '
        set -euo pipefail

        pacman_sync_retry() {
            local attempt
            for attempt in 1 2 3 4 5; do
                echo "==> Repository sync attempt $attempt/5"
                if sudo pacman -Syy --noconfirm; then
                    return 0
                fi
                echo "warning: repository sync failed; discarding temporary sync databases before retry" >&2
                sudo rm -f /var/lib/pacman/sync/*.db /var/lib/pacman/sync/*.db.sig \
                           /var/lib/pacman/sync/*.files /var/lib/pacman/sync/*.files.sig
                sleep $((attempt * 5))
            done
            echo "error: repository sync failed after 5 attempts" >&2
            return 1
        }

        pacman_upgrade_retry() {
            local attempt
            for attempt in 1 2 3 4 5; do
                echo "==> Full system upgrade attempt $attempt/5"
                if sudo pacman -Syyu --noconfirm; then
                    return 0
                fi
                echo "warning: full upgrade failed; refreshing repository databases before retry" >&2
                sudo rm -f /var/lib/pacman/sync/*.db /var/lib/pacman/sync/*.db.sig \
                           /var/lib/pacman/sync/*.files /var/lib/pacman/sync/*.files.sig
                sleep $((attempt * 5))
            done
            echo "error: full system upgrade failed after 5 attempts" >&2
            return 1
        }

        echo "==> Preparing pacman inside the build container"

        # pacman 7 download sandboxing can fail under Docker when Landlock
        # rules cannot be applied. Disable it only inside this ephemeral
        # build container; the host pacman configuration is untouched.
        if grep -q "^#DisableSandbox" /etc/pacman.conf; then
            sudo sed -i "s/^#DisableSandbox/DisableSandbox/" /etc/pacman.conf
        elif ! grep -q "^DisableSandbox" /etc/pacman.conf; then
            echo "DisableSandbox" | sudo tee -a /etc/pacman.conf >/dev/null
        fi

        # Bootstrap trust from the keyrings already present in the image.
        sudo pacman-key --init
        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        echo "==> Updating repository databases and keyring packages first"
        pacman_sync_retry

        # Update signing metadata before the full upgrade. Package signature
        # checking remains enabled; this does not use TrustAll for Arch repos.
        keyring_packages=(archlinux-keyring)
        if pacman -Si cachyos-keyring >/dev/null 2>&1; then
            keyring_packages+=(cachyos-keyring)
        fi
        sudo pacman -S --needed --noconfirm "${keyring_packages[@]}"

        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        # Refresh mirror ordering at build time. If one mirror is in the middle
        # of syncing its database/signature pair, the retry logic below will
        # discard the inconsistent copy and fetch it again.
        if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
            sudo cachyos-rate-mirrors || true
        fi

        pacman_sync_retry
        pacman_upgrade_retry

        # Continue with the same build flow as the CachyOS image run.sh, but
        # keep failures visible instead of swallowing makepkg errors.
        rm -rf /tmp/pkg
        cp -r /pkg /tmp/pkg
        cd /tmp/pkg

        mkdir -p /home/notroot/packages

        if [[ -n "${CHECKSUMS:-}" ]]; then
            echo "==> Updating checksums"
            updpkgsums
            makepkg --printsrcinfo > .SRCINFO
        fi

        if [[ -n "${USE_PARU:-}" ]]; then
            paru -U --noconfirm --cleanafter
        else
            makepkg -sc --skipinteg --noconfirm --log
        fi

        if [[ -n "${EXPORT_PKG:-}" ]]; then
            sudo chown "$(stat -c "%u:%g" /pkg/PKGBUILD)" /home/notroot/packages/* || true
            sudo mv /home/notroot/packages/*.log /pkg/ || true
            sudo mv /home/notroot/packages/*pkg.tar* /pkg/
        fi
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
