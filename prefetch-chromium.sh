#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

version="${1:-$(sed -n 's/^pkgver=//p' PKGBUILD | head -n1)}"
if [[ -z "$version" ]]; then
    echo "error: could not determine Chromium version from PKGBUILD" >&2
    exit 1
fi

image="${CACHYOS_MAKEPKG_IMAGE:-cachyos/docker-makepkg-znver4:latest}"
cache_base="${CHROMIUM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ungoogled-chromium-cachyos}"
source_cache="$cache_base/chromium-source"
git_cache="$cache_base/git-cache"
target="$source_cache/chromium-$version"
stage="$source_cache/.prefetch-$version"

mkdir -p "$source_cache" "$git_cache"

if [[ -f "$target/.ungoogled-chromium-cache-complete" ]]; then
    echo "==> Chromium $version is already prefetched:"
    echo "    $target"
    exit 0
fi

mkdir -p "$stage"

echo "==> Prefetching Chromium $version"
echo "==> Image: $image"
echo "==> Source cache: $source_cache"
echo "==> Git dependency cache: $git_cache"
echo "==> This step may be run with WARP enabled; do not run the GitHub runner at the same time."

docker run --rm \
    --pull=always \
    -e CHROMIUM_VERSION="$version" \
    -e GIT_CACHE_PATH=/git-cache \
    -e VPYTHON_BYPASS="manually managed python not supported by chrome operations" \
    -v "$repo_root:/repo:ro" \
    -v "$stage:/work" \
    -v "$git_cache:/git-cache" \
    "$image" \
    /bin/bash -lc '
        set -euo pipefail

        retry() {
            local attempts=$1
            local delay=$2
            shift 2
            local n=1
            until "$@"; do
                local rc=$?
                if (( n >= attempts )); then
                    echo "error: command failed after $n attempts (exit $rc): $*" >&2
                    return "$rc"
                fi
                echo "warning: attempt $n/$attempts failed; retrying in ${delay}s: $*" >&2
                sleep "$delay"
                ((n++))
            done
        }

        if grep -q "^#DisableSandbox" /etc/pacman.conf; then
            sudo sed -i "s/^#DisableSandbox/DisableSandbox/" /etc/pacman.conf
        elif ! grep -q "^DisableSandbox" /etc/pacman.conf; then
            echo "DisableSandbox" | sudo tee -a /etc/pacman.conf >/dev/null
        fi

        sudo pacman-key --init
        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        retry 5 10 sudo pacman -Syy --noconfirm
        sudo pacman -S --needed --noconfirm archlinux-keyring cachyos-keyring || true
        sudo pacman-key --populate archlinux
        if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
            sudo pacman-key --populate cachyos
        fi

        retry 5 15 sudo pacman -Syu --needed --noconfirm \
            git python python313 python-httplib2 python-pyparsing python-six python-requests \
            python-urllib3 python-idna python-yaml python-lxml python-pygments \
            python-pytest python-coverage python-packaging python-brotli \
            python-hjson python-parameterized python-colorama python-sqlparse \
            python-pluggy python-iniconfig npm rsync

        # VPYTHON_BYPASS makes depot_tools use the system Python. CachyOS
        # currently ships Python 3.14 as /usr/bin/python3, while depot_tools
        # gsutil supports only Python 3.9-3.13. Put a private Python 3.13 shim
        # first in PATH for this prefetch process only; the host and normal
        # CachyOS build environment remain unchanged.
        mkdir -p /tmp/chromium-python
        ln -sf /usr/bin/python3.13 /tmp/chromium-python/python3
        export PATH="/tmp/chromium-python:$PATH"
        echo "==> depot_tools Python: $(python3 --version)"

        cd /work
        /repo/fetch-chromium-release "$CHROMIUM_VERSION"
        touch "chromium-$CHROMIUM_VERSION/.ungoogled-chromium-cache-complete"
    '

rm -rf "$target"
mv "$stage/chromium-$version" "$target"
rmdir "$stage" 2>/dev/null || true

echo
echo "==> Prefetch complete"
echo "    $target"
echo "==> You can now disable WARP and run the GitHub self-hosted runner."
