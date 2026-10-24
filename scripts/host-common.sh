#!/usr/bin/env bash
# Shared host setup. Proxy settings apply to child containers, not the desktop.

require_build_tools() {
    local tool missing=0
    for tool in docker bsdtar git flock lscpu python3 realpath find tee sha256sum tar; do
        if ! command -v "$tool" >/dev/null; then
            echo >&2 "Missing command: $tool"
            missing=1
        fi
    done
    ((missing == 0)) || {
        echo >&2 'On CachyOS, install missing host tools from docker, libarchive, git, util-linux, python and coreutils.'
        return 1
    }
}

verify_build_cpu() {
    local flags flag
    flags=" $(LC_ALL=C lscpu | sed -n 's/^Flags:[[:space:]]*//p') "
    local required=(cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave
        avx512f avx512bw avx512cd avx512dq avx512vl)
    for flag in "${required[@]}"; do
        [[ $flags == *" $flag "* ]] || {
            echo >&2 "Missing x86-64-v4 CPU flag: $flag. Use a compatible Zen 4 Linux build host."
            return 1
        }
    done
}

check_build_environment() {
    local root=$1 mode=$2 cache=$3 output=$4 jobs_count=$5
    require_build_tools
    verify_build_cpu
    container_network
    printf '==> Host tools and baseline x86-64-v4 flags: OK\n'
    printf '==> Recipe: %s\n' "$(sed -n 's/^pkgver=//p' "$root/PKGBUILD")"
    printf '==> Source mode: %s\n' "$([[ $mode == 0 ]] && echo 'upstream archive; no Git prefetch' || echo 'version-pinned Git cache')"
    printf '==> Cache: %s\n==> Output: %s\n==> Parallel jobs: %s\n' "$cache" "$output" "$jobs_count"
    if docker info >/dev/null 2>&1; then
        echo '==> Docker: reachable'
    else
        echo '==> Docker: unavailable now; a normal build can start a stopped local service'
    fi
    local path probe
    for path in "$cache" "$output"; do
        probe=$path
        while [[ ! -d $probe ]]; do probe=$(dirname -- "$probe"); done
        df -h -- "$probe"
    done
    echo '==> No image pull, network download or container run was attempted.'
    echo '==> Remote download reachability and sufficient build disk/RAM still need checking on the builder.'
}

update_checkout() {
    local root=$1
    command -v git >/dev/null
    [[ ${CI:-} != true && $(git -C "$root" branch --show-current) == cachyos-znver4 ]] || {
        echo >&2 '--update requires a local cachyos-znver4 branch outside CI'
        return 1
    }
    [[ -z $(git -C "$root" status --porcelain) ]] || {
        echo >&2 'Commit or stash local changes before --update; no files were changed'
        return 1
    }
    if [[ -n ${CACHYOS_PROXY_URL:-} ]]; then
        [[ $CACHYOS_PROXY_URL == http://* && $CACHYOS_PROXY_URL != *[[:space:]]* ]] || {
            echo >&2 'CACHYOS_PROXY_URL must use the HTTP/mixed listener'
            return 1
        }
        # Function-local exports reach Git without changing the caller's route
        # or putting proxy credentials in process arguments.
        local -x http_proxy=$CACHYOS_PROXY_URL https_proxy=$CACHYOS_PROXY_URL
        local -x HTTP_PROXY=$CACHYOS_PROXY_URL HTTPS_PROXY=$CACHYOS_PROXY_URL
    fi
    git -C "$root" fetch origin refs/heads/cachyos-znver4
    git -C "$root" merge --ff-only FETCH_HEAD
}

lock_package_cache() {
    local base=$1
    mkdir -p "$base/pacman"
    # Returned to the caller for the container bind mount. Serialize the entire
    # container use so two pacman processes cannot race on the same .part file.
    # shellcheck disable=SC2034
    package_cache=$(realpath "$base/pacman")
    exec 7>"$base/.packages.lock"
    flock -n 7 || { echo >&2 'Another container is using the package download cache'; return 1; }
}

load_build_config() {
    local config_file=${CACHYOS_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ungoogled-chromium-cachyos/build.env}
    local key
    local -a settings=(CACHYOS_MAKEPKG_IMAGE CACHYOS_IMAGE_PULL CHROMIUM_BUILD_JOBS
        CHROMIUM_CACHE_DIR CACHYOS_OUTPUT_DIR CACHYOS_AUTO_PREFETCH CACHYOS_START_DOCKER
        CACHYOS_PROXY_URL CACHYOS_DOCKER_NETWORK CACHYOS_RUNNER_DIR CACHYOS_RUNNER_PROXY_URL
        http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)
    local -A supplied=()
    for key in "${settings[@]}"; do
        if [[ -v $key ]]; then supplied[$key]=${!key}; fi
    done
    if [[ -f $config_file ]]; then
        # This is a trusted, user-owned Bash configuration, outside the checkout.
        # shellcheck disable=SC1090
        source "$config_file"
    elif [[ -n ${CACHYOS_CONFIG_FILE:-} ]]; then
        echo >&2 'CACHYOS_CONFIG_FILE does not exist'
        return 1
    fi
    for key in "${settings[@]}"; do
        if [[ -v supplied[$key] ]]; then printf -v "$key" '%s' "${supplied[$key]}"; fi
        if [[ -v $key ]]; then export "${key?}"; fi
    done
}

ensure_docker() {
    command -v docker >/dev/null || { echo >&2 'Install Docker first'; return 1; }
    if docker info >/dev/null 2>&1; then return 0; fi
    local start=${CACHYOS_START_DOCKER:-auto}
    [[ $start == auto || $start == never ]] || {
        echo >&2 'CACHYOS_START_DOCKER must be auto or never'; return 1;
    }
    # Starting a local service does not enable it at boot. Do not touch a
    # remote Docker context or guess that a permission error means it is stopped.
    if [[ $start == auto && -z ${DOCKER_HOST:-} ]] &&
        command -v systemctl >/dev/null &&
        [[ $(docker context show 2>/dev/null) == default ]] &&
        ! systemctl is-active --quiet docker; then
        echo '==> Starting Docker for this session'
        if [[ ${CI:-} == true ]]; then
            sudo -n systemctl start docker
        else
            sudo systemctl start docker
        fi
    fi
    docker info >/dev/null 2>&1 || {
        echo >&2 'Docker is unavailable. Start Docker and grant this user access to it.'
        return 1
    }
}

resolve_build_image() {
    local image=$1 policy=${CACHYOS_IMAGE_PULL:-always} attempt rc=1
    case $policy in
        always) ;;
        missing) if docker image inspect "$image" >/dev/null 2>&1; then policy=never; fi ;;
        never) ;;
        *) echo >&2 'CACHYOS_IMAGE_PULL must be always, missing or never'; return 1 ;;
    esac
    if [[ $policy != never ]]; then
        for attempt in 1 2 3; do
            if docker pull "$image"; then rc=0; break; else rc=$?; fi
            echo >&2 "warning: image pull failed ($attempt/3). Docker image pulls need the daemon's own proxy settings."
            if ((attempt < 3)); then sleep 5; fi
        done
        ((rc == 0)) || return "$rc"
    fi
    # shellcheck disable=SC2034 # Returned to callers without using stdout.
    image_id=$(docker image inspect --format '{{.Id}}' "$image")
    [[ -n $image_id ]] || { echo >&2 'Could not resolve build image'; return 1; }
}

container_network() {
    local lower upper value host network=${CACHYOS_DOCKER_NETWORK:-auto}
    # These arrays are consumed by the host entry points.
    # shellcheck disable=SC2034
    container_network_args=()
    # shellcheck disable=SC2034
    container_proxy_args=()
    if [[ -n ${CACHYOS_PROXY_URL:-} ]]; then
        [[ $CACHYOS_PROXY_URL == http://* && $CACHYOS_PROXY_URL != *[[:space:]]* ]] || {
            echo >&2 'CACHYOS_PROXY_URL must use an HTTP proxy URL; use the HTTP/mixed listener, not a SOCKS-only port'
            return 1
        }
        export http_proxy=$CACHYOS_PROXY_URL
        export https_proxy=$CACHYOS_PROXY_URL
        export all_proxy=$CACHYOS_PROXY_URL
    fi
    local loopback=false
    for lower in http_proxy https_proxy all_proxy no_proxy; do
        upper=${lower^^}
        # Lowercase variables are preferred by several tools (including curl).
        value=${!lower-${!upper-}}
        if [[ -v $lower || -v $upper ]]; then
            printf -v "$lower" '%s' "$value"
            printf -v "$upper" '%s' "$value"
            export "${lower?}" "${upper?}"
            # Pass names only: do not put proxy credentials in Docker's argv.
            container_proxy_args+=(-e "$lower" -e "$upper")
        fi
        [[ $lower == no_proxy ]] && continue
        host=${value#*://}
        host=${host##*@}
        host=${host%%/*}
        case $host in
            localhost|localhost:*|127.*|\[::1\]|\[::1\]:*) loopback=true ;;
        esac
    done
    if [[ $network == auto ]]; then
        if [[ $loopback == true ]]; then network=host; else network=bridge; fi
    fi
    [[ $network == bridge || $network == host ]] || {
        echo >&2 'CACHYOS_DOCKER_NETWORK must be auto, bridge or host'; return 1;
    }
    if [[ $loopback == true && $network != host ]]; then
        echo >&2 'A loopback proxy requires CACHYOS_DOCKER_NETWORK=host on Linux'
        return 1
    fi
    container_network_args+=(--network "$network")
    # The normal Linux host backend is needed to reach its loopback listener.
    # A remote daemon has a different loopback address; reject misleading URLs.
    if [[ $loopback == true && ( -n ${DOCKER_HOST:-} || $(docker context show 2>/dev/null) != default ) ]]; then
        echo >&2 'Use a proxy address reachable from the Docker host for a remote/rootless Docker context'
        return 1
    fi
}
