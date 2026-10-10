#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/host-common.sh
source "$repo_root/scripts/host-common.sh"
load_build_config
ensure_docker
runner_dir=${CACHYOS_RUNNER_DIR:-$HOME/.local/share/github-actions-runner/ungoogled-chromium-cachyos}
[[ -x $runner_dir/run.sh ]] || {
    echo >&2 'Runner installation not found; set CACHYOS_RUNNER_DIR in build.env'
    exit 1
}
if [[ -n ${CACHYOS_RUNNER_PROXY_URL:-} ]]; then
    [[ $CACHYOS_RUNNER_PROXY_URL == http://* && $CACHYOS_RUNNER_PROXY_URL != *[[:space:]]* ]] || {
        echo >&2 'CACHYOS_RUNNER_PROXY_URL must use an HTTP proxy URL'
        exit 1
    }
    export http_proxy=$CACHYOS_RUNNER_PROXY_URL https_proxy=$CACHYOS_RUNNER_PROXY_URL
    export HTTP_PROXY=$CACHYOS_RUNNER_PROXY_URL HTTPS_PROXY=$CACHYOS_RUNNER_PROXY_URL
fi
cd "$runner_dir"
# Exit after one build/upload job. Hosted validation and release jobs can finish
# independently once the laptop has uploaded its artifact.
exec ./run.sh --once "$@"
