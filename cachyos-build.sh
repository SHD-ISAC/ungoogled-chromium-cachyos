#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

image="${CACHYOS_MAKEPKG_IMAGE:-cachyos/docker-makepkg-znver4:latest}"
jobs="${CHROMIUM_BUILD_JOBS:-8}"
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo >&2 'CHROMIUM_BUILD_JOBS must be a positive integer'; exit 1; }
command -v docker >/dev/null
command -v bsdtar >/dev/null

# CHROMIUM_CACHE_DIR has the same meaning in both entry points: the cache base.
cache_base="${CHROMIUM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ungoogled-chromium-cachyos}"
source_cache="$cache_base/chromium-source"
output_dir="${CACHYOS_OUTPUT_DIR:-$repo_root/build-output/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$source_cache" "$output_dir"
source_cache="$(realpath "$source_cache")"
output_dir="$(realpath "$output_dir")"

# Do not let a stale package make a failed build look successful or remove a
# previous successful build. Each invocation needs its own output directory.
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo >&2 "Output directory must be empty: $output_dir"
    exit 1
fi

builder_name="ungoogled-chromium-build-$(id -u)-$$"
cleanup() {
    local rc=$?
    trap - EXIT
    docker rm -f "$builder_name" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Build image: $image"
echo "==> Chromium source cache: $source_cache"
echo "==> Output: $output_dir"
echo "==> Parallel jobs: $jobs"
docker pull "$image"
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
{
    printf 'image=%s\nimage_id=%s\njobs=%s\n' "$image" "$image_id" "$jobs"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'recipe_commit=%s\n' "$(git rev-parse HEAD)"
        printf 'recipe_dirty=%s\n' "$(test -z "$(git status --porcelain)" && echo false || echo true)"
    else
        printf 'recipe_commit=unknown\nrecipe_dirty=unknown\n'
    fi
    docker image inspect --format 'repo_digests={{json .RepoDigests}}' "$image_id"
} > "$output_dir/build-environment.txt"

# The recipe and source cache are read-only. Waiting on a background client
# lets Bash handle cancellation immediately and remove its named container.
docker run --rm --init --name "$builder_name" \
    -e CHROMIUM_BUILD_JOBS="$jobs" \
    -e CHROMIUM_SOURCE_CACHE=/source-cache \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$repo_root:/recipe:ro" \
    -v "$source_cache:/source-cache:ro" \
    -v "$output_dir:/output" \
    "$image_id" /bin/bash /recipe/scripts/container-build.sh \
    > >(tee "$output_dir/build.log") 2>&1 &
wait "$!"

"$repo_root/scripts/verify-package.sh" "$output_dir"
echo "==> Build complete: $output_dir"
