#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"
# shellcheck source=scripts/host-common.sh
source "$repo_root/scripts/host-common.sh"
load_build_config

update=false
check=false
for option in "$@"; do
    case $option in
        --update) update=true ;;
        --check) check=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ./cachyos-build.sh [--update] [--check]
  --update  Fast-forward a clean cachyos-znver4 checkout, then continue.
  --check   Check the host and show paths without downloading or building.
  --help    Show this help.
Without --check, prepare sources, compile and verify the package.
EOF
            exit 0 ;;
        *) echo >&2 "Unknown option: $option (use --help)"; exit 2 ;;
    esac
done
if [[ $update == true ]]; then
    update_checkout "$repo_root"
    # Run the updated helpers rather than continuing a script read before pull.
    if [[ $check == true ]]; then exec "$repo_root/cachyos-build.sh" --check; fi
    exec "$repo_root/cachyos-build.sh"
fi

image="${CACHYOS_MAKEPKG_IMAGE:-cachyos/docker-makepkg-znver4:latest}"
jobs="${CHROMIUM_BUILD_JOBS:-8}"
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo >&2 'CHROMIUM_BUILD_JOBS must be a positive integer'; exit 1; }
auto_prefetch=${CACHYOS_AUTO_PREFETCH:-1}
[[ $auto_prefetch == 0 || $auto_prefetch == 1 ]] || { echo >&2 'CACHYOS_AUTO_PREFETCH must be 0 or 1'; exit 1; }
manual_clone=$(sed -n 's/^_manual_clone=//p' PKGBUILD)
[[ $manual_clone == 0 || $manual_clone == 1 ]] || { echo >&2 'PKGBUILD must select _manual_clone=0 or 1'; exit 1; }

# CHROMIUM_CACHE_DIR has the same meaning in both entry points: the cache base.
cache_base="${CHROMIUM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ungoogled-chromium-cachyos}"
source_cache="$cache_base/chromium-source"
source_downloads="$cache_base/source-downloads"
output_dir="${CACHYOS_OUTPUT_DIR:-$HOME/Downloads/ungoogled-chromium-builds/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
if [[ $check == true ]]; then
    check_build_environment "$repo_root" "$manual_clone" "$cache_base" "$output_dir" "$jobs"
    exit 0
fi
require_build_tools
verify_build_cpu
mkdir -p "$source_cache" "$output_dir"
exec 8>"$cache_base/.build.lock"
flock -n 8 || { echo >&2 'Another build is using this cache; wait for it to finish'; exit 1; }
source_cache="$(realpath "$source_cache")"
output_dir="$(realpath "$output_dir")"

# Do not let a stale package make a failed build look successful or remove a
# previous successful build. Each invocation needs its own output directory.
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo >&2 "Output directory must be empty: $output_dir"
    exit 1
fi

builder_name="ungoogled-chromium-build-$(id -u)-$$"
prefetch_pid=''
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $prefetch_pid ]]; then
        kill -TERM "$prefetch_pid" 2>/dev/null || true
        wait "$prefetch_pid" 2>/dev/null || true
    fi
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
if [[ $manual_clone == 0 ]]; then
    echo '==> Source: upstream archive with makepkg checksum verification (no Git prefetch)'
else
    echo '==> Source: version-pinned Chromium Git cache'
fi
ensure_docker
container_network
resolve_build_image "$image"
if [[ $manual_clone == 0 ]]; then
    : # makepkg downloads the upstream archive directly into the shared cache.
elif [[ $auto_prefetch == 1 ]]; then
    # Prefetch and compile with exactly the same image. Cache hits do no download.
    env CACHYOS_MAKEPKG_IMAGE="$image_id" CACHYOS_IMAGE_PULL=never \
        "$repo_root/prefetch-chromium.sh" > >(tee "$output_dir/prefetch.log") 2>&1 &
    prefetch_pid=$!
    wait "$prefetch_pid"
    prefetch_pid=''
else
    version=$(sed -n 's/^pkgver=//p' PKGBUILD)
    [[ -f $source_cache/chromium-$version/.ungoogled-chromium-cache-complete ]] || {
        echo >&2 'Prefetch is disabled but the requested source cache is missing'
        exit 1
    }
fi
lock_package_cache "$cache_base"
mkdir -p "$source_downloads"
source_downloads=$(realpath "$source_downloads")
{
    printf 'image=%s\nimage_id=%s\njobs=%s\n' "$image" "$image_id" "$jobs"
    printf 'manual_clone=%s\n' "$manual_clone"
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
    "${container_network_args[@]}" "${container_proxy_args[@]}" \
    -e CHROMIUM_BUILD_JOBS="$jobs" \
    -e CHROMIUM_SOURCE_CACHE=/source-cache \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$repo_root:/recipe:ro" \
    -v "$source_cache:/source-cache:ro" \
    -v "$package_cache:/var/cache/pacman/pkg" \
    -v "$source_downloads:/source-downloads" \
    -v "$output_dir:/output" \
    "$image_id" /bin/bash /recipe/scripts/container-build.sh \
    > >(tee "$output_dir/build.log") 2>&1 &
wait "$!"

"$repo_root/scripts/verify-package.sh" "$output_dir"
echo "==> Build complete: $output_dir"
