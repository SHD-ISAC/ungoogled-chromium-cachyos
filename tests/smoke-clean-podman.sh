#!/usr/bin/env bash
# Real rootless Podman smoke test; import a tiny local image without a registry.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/host-common.sh
source "$root/scripts/host-common.sh"
[[ $EUID -ne 0 ]]
scratch=$(mktemp -d -- "${RUNNER_TEMP:-/tmp}/uc-podman.XXXXXXXX")
runtime_root=$(mktemp -d -- /tmp/ucp.XXXXXXXX)
other_ready=false
build_ready=false
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ $build_ready == true ]]; then
        podman_state="$scratch/build"
        podman_runtime="$runtime_root/build"
        container_cli system reset --force >/dev/null || rc=1
    fi
    if [[ $other_ready == true ]]; then
        podman_state="$scratch/other"
        podman_runtime="$runtime_root/other"
        container_cli system reset --force >/dev/null || rc=1
    fi
    rm -rf --one-file-system -- "$scratch" "$runtime_root" || rc=1
    exit "$rc"
}
trap cleanup EXIT

mkdir -p "$scratch/rootfs"/{bin,etc,home/notroot,probe} "$scratch/probe"
mkdir -m 700 -- "$runtime_root"/{build,other}
cp -- "$(command -v busybox)" "$scratch/rootfs/bin/busybox"
ln -s busybox "$scratch/rootfs/bin/sh"
printf 'root:x:0:0:root:/root:/bin/sh\nnotroot:x:1000:1000:builder:/home/notroot:/bin/sh\n' > "$scratch/rootfs/etc/passwd"
printf 'root:x:0:\nnotroot:x:1000:\n' > "$scratch/rootfs/etc/group"
tar -C "$scratch/rootfs" --owner=0 --group=0 --numeric-owner -cf "$scratch/image.tar" .

podman_state="$scratch/other"
podman_runtime="$runtime_root/other"
prepare_clean_store "$podman_state" "$podman_runtime"
other_ready=true
container_cli import "$scratch/image.tar" localhost/keep-fixture:latest >/dev/null

podman_state="$scratch/build"
podman_runtime="$runtime_root/build"
prepare_clean_store "$podman_state" "$podman_runtime"
build_ready=true
image=$(container_cli import --change 'USER 1000:1000' "$scratch/image.tar" localhost/build-fixture:latest)
# shellcheck disable=SC2016 # Run the substitution in the container.
container_run --rm --init --name clean-smoke --network none -v "$scratch/probe:/probe" \
    "$image" /bin/sh -c 'test "$(/bin/busybox id -u)" = 1000 && echo done > /probe/result'
[[ $(stat -c '%u:%g' "$scratch/probe/result") == "$(id -u):$(id -g)" ]]
container_cli system reset --force >/dev/null
build_ready=false
[[ ! -e $podman_state/graph && ! -e $podman_runtime/run ]]

podman_state="$scratch/other"
podman_runtime="$runtime_root/other"
container_cli image exists localhost/keep-fixture:latest
echo 'Rootless Podman bind mounts and private-store cleanup passed.'
