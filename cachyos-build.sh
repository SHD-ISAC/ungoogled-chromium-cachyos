#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"
# shellcheck source=scripts/host-common.sh
source "$repo_root/scripts/host-common.sh"
load_build_config

update=false
check=false
clean=false
for option in "$@"; do
    case $option in
        --update) update=true ;;
        --check) check=true ;;
        --clean) clean=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ./cachyos-build.sh [--update] [--check] [--clean]
  --update  Fast-forward a clean cachyos-znver4 checkout, then continue.
  --check   Check the host and show paths without downloading or building.
  --clean   Use rootless Podman and keep only the verified package and checksum.
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
    next_args=()
    if [[ $check == true ]]; then next_args+=(--check); fi
    if [[ $clean == true ]]; then next_args+=(--clean); fi
    exec "$repo_root/cachyos-build.sh" "${next_args[@]}"
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
output_dir="${CACHYOS_OUTPUT_DIR:-$HOME/Downloads/ungoogled-chromium-builds/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
engine=docker
check_path=$cache_base
if [[ $clean == true ]]; then
    [[ $EUID -ne 0 ]] || { echo >&2 'Run --clean as an ordinary user, without sudo'; exit 1; }
    clean_parent=$(realpath -e -- "${CACHYOS_CLEAN_PARENT:-$HOME}")
    [[ -d $clean_parent && -w $clean_parent && $clean_parent != "$repo_root" && $clean_parent != "$repo_root/"* ]] || {
        echo >&2 'CACHYOS_CLEAN_PARENT must be a writable directory outside the checkout'
        exit 1
    }
    engine=podman
    check_path=$clean_parent
fi
if [[ $check == true ]]; then
    check_build_environment "$repo_root" "$manual_clone" "$check_path" "$output_dir" "$jobs" "$engine"
    exit 0
fi
require_build_tools "$engine"
verify_build_cpu
mkdir -p "$output_dir"
output_dir="$(realpath "$output_dir")"

# Do not let a stale package make a failed build look successful or remove a
# previous successful build. Each invocation needs its own output directory.
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo >&2 "Output directory must be empty: $output_dir"
    exit 1
fi

builder_name="ungoogled-chromium-build-$(id -u)-$$"
prefetch_pid=''
builder_started=false
clean_workspace=''
podman_state=''
podman_runtime=''
private_store_ready=false
build_output=$output_dir
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $prefetch_pid ]]; then
        kill -TERM "$prefetch_pid" 2>/dev/null || true
        wait "$prefetch_pid" 2>/dev/null || true
    fi
    if [[ $builder_started == true ]]; then
        container_cli rm -f "$builder_name" >/dev/null 2>&1 || true
    fi
    if [[ -n $clean_workspace ]]; then
        local -a workdirs=("$clean_workspace")
        if [[ -n $podman_runtime ]]; then workdirs+=("$podman_runtime"); fi
        if ((rc != 0)); then
            local item
            for item in build.log prefetch.log build-environment.txt build-packages.txt logs; do
                if [[ -e $build_output/$item ]]; then
                    cp -a -- "$build_output/$item" "$output_dir/" ||
                        echo >&2 "Could not save $item to $output_dir"
                fi
            done
        fi
        # Reset only the verified private store, never the user's usual store.
        if { [[ $private_store_ready == true ]] && ! container_cli system reset --force >/dev/null; } ||
            ! rm -rf --one-file-system -- "${workdirs[@]}"; then
            printf >&2 'Clean build cleanup failed; temporary directories:\n  %s\n' "${workdirs[@]}"
            if ((rc == 0)); then rc=1; fi
        fi
    fi
    if ((rc == 0)); then echo "==> Build complete: $output_dir"; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build_uid=$(id -u)
build_gid=$(id -g)
if [[ $clean == true ]]; then
    clean_workspace=$(mktemp -d -- "$clean_parent/.uc-build.XXXXXXXX")
    cache_base="$clean_workspace/cache"
    build_output="$clean_workspace/output"
    podman_state="$clean_workspace/podman"
    # Older Podman versions cap runroot at 50 characters. Keep only small
    # runtime metadata here; image layers and downloads stay on the build disk.
    podman_runtime=$(mktemp -d -- /tmp/ucp.XXXXXXXX)
    mkdir -- "$build_output"
    echo "==> Disposable Podman workspace: $clean_workspace"
    prepare_clean_store "$podman_state" "$podman_runtime"
    private_store_ready=true
    CACHYOS_IMAGE_PULL=always
    auto_prefetch=1
    if [[ $image == cachyos/* ]]; then image="docker.io/$image"; fi
    build_uid=1000
    build_gid=1000
fi
source_cache="$cache_base/chromium-source"
source_downloads="$cache_base/source-downloads"
mkdir -p "$source_cache"
exec 8>"$cache_base/.build.lock"
flock -n 8 || { echo >&2 'Another build is using this cache; wait for it to finish'; exit 1; }
source_cache="$(realpath "$source_cache")"

echo "==> Build image: $image"
echo "==> Chromium source cache: $source_cache"
echo "==> Output: $output_dir"
echo "==> Parallel jobs: $jobs"
if [[ $manual_clone == 0 ]]; then
    echo '==> Source: upstream archive with makepkg checksum verification (no Git prefetch)'
else
    echo '==> Source: version-pinned Chromium Git cache'
fi
if [[ $engine == docker ]]; then ensure_docker; fi
container_network "$engine"
resolve_build_image "$image"
if [[ $manual_clone == 0 ]]; then
    : # makepkg downloads the upstream archive directly into the shared cache.
elif [[ $auto_prefetch == 1 ]]; then
    # Prefetch and compile with exactly the same image. Cache hits do no download.
    env CACHYOS_MAKEPKG_IMAGE="$image_id" CACHYOS_IMAGE_PULL=never \
        CHROMIUM_CACHE_DIR="$cache_base" CACHYOS_INTERNAL_PODMAN_DIR="$podman_state" \
        CACHYOS_INTERNAL_PODMAN_RUNTIME="$podman_runtime" \
        "$repo_root/prefetch-chromium.sh" > >(tee "$build_output/prefetch.log") 2>&1 &
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
    container_cli image inspect --format 'repo_digests={{json .RepoDigests}}' "$image_id"
} > "$build_output/build-environment.txt"

# The recipe and source cache are read-only. Waiting on a background client
# lets Bash handle cancellation immediately and remove its named container.
builder_started=true
(
    trap - EXIT
    container_run --rm --init --name "$builder_name" \
        "${container_network_args[@]}" "${container_proxy_args[@]}" \
        -e CHROMIUM_BUILD_JOBS="$jobs" \
        -e CHROMIUM_SOURCE_CACHE=/source-cache \
        -e HOST_UID="$build_uid" -e HOST_GID="$build_gid" \
        -v "$repo_root:/recipe:ro" \
        -v "$source_cache:/source-cache:ro" \
        -v "$package_cache:/var/cache/pacman/pkg" \
        -v "$source_downloads:/source-downloads" \
        -v "$build_output:/output" \
        "$image_id" /bin/bash /recipe/scripts/container-build.sh \
        2>&1 | tee "$build_output/build.log"
) &
wait "$!"

"$repo_root/scripts/verify-package.sh" "$build_output"
if [[ $clean == true ]]; then
    if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        echo >&2 "Output directory is no longer empty: $output_dir"
        exit 1
    fi
    cp --reflink=auto -- "$build_output"/ungoogled-chromium-*.pkg.tar.zst "$build_output/SHA256SUMS" "$output_dir/"
fi
