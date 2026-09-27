#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"
version="${1:-$(sed -n 's/^pkgver=//p' PKGBUILD)}"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo >&2 'Expected a Chromium version such as 153.0.8010.47'
    exit 1
}

image="${CACHYOS_MAKEPKG_IMAGE:-cachyos/docker-makepkg-znver4:latest}"
cache_base="${CHROMIUM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ungoogled-chromium-cachyos}"
source_cache="$cache_base/chromium-source"
git_cache="$cache_base/git-cache"
mkdir -p "$source_cache" "$git_cache"
source_cache="$(realpath "$source_cache")"
git_cache="$(realpath "$git_cache")"
target="$source_cache/chromium-$version"
stage="$source_cache/.prefetch-$version"

# Serialize all prefetches sharing the dependency cache, including different
# versions. Interrupted staging trees stay available to the next invocation.
exec 9>"$git_cache/.prefetch.lock"
flock -n 9 || { echo >&2 "Another prefetch is using $git_cache"; exit 1; }
if [[ -f $target/.ungoogled-chromium-cache-complete ]]; then
    echo "==> Chromium $version is already prefetched: $target"
    exit 0
fi
if [[ -e $target || -L $target ]]; then
    echo >&2 "Incomplete cache exists: $target; move it aside before retrying"
    exit 1
fi
mkdir -p "$stage"

builder_name="ungoogled-chromium-prefetch-$(id -u)-$$"
cleanup() {
    local rc=$?
    trap - EXIT
    docker rm -f "$builder_name" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Prefetching Chromium $version into $target"
echo '==> You may use WARP for prefetch, then disable it before starting the GitHub runner.'
if [[ ! -f $stage/chromium-$version/.ungoogled-chromium-cache-complete ]]; then
    command -v docker >/dev/null
    docker run --rm --init --pull=always --name "$builder_name" \
        -e CHROMIUM_VERSION="$version" -e GIT_CACHE_PATH=/git-cache \
        -v "$repo_root:/recipe:ro" -v "$stage:/work" -v "$git_cache:/git-cache" \
        "$image" /bin/bash /recipe/scripts/container-prefetch.sh &
    wait "$!"
fi

[[ -f $stage/chromium-$version/.ungoogled-chromium-cache-complete ]]
mv -T -- "$stage/chromium-$version" "$target"
rmdir "$stage" 2>/dev/null || true
echo "==> Prefetch complete: $target"
