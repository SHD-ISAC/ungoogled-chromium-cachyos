#!/usr/bin/env bash
# Shared host setup. Proxy settings apply to child containers, not the desktop.

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
