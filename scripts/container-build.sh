#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/container-common.sh
source /recipe/scripts/container-common.sh

export_outputs() {
    local rc=$?
    trap - EXIT
    shopt -s nullglob
    local logs=(/home/notroot/packages/*.log)
    if ((${#logs[@]})); then
        sudo mkdir -p /output/logs
        sudo cp -- "${logs[@]}" /output/logs/ || true
    fi
    # Preserve makepkg's failure status; only export binaries on success.
    if ((rc == 0)); then
        local packages=(/home/notroot/packages/*.pkg.tar.zst)
        if ((${#packages[@]} == 0)); then
            echo 'error: makepkg succeeded without a package' >&2
            rc=1
        elif ! sudo cp -- "${packages[@]}" /output/; then
            rc=1
        fi
    fi
    sudo chown -R "$HOST_UID:$HOST_GID" /output || true
    exit "$rc"
}
trap export_outputs EXIT

bootstrap_pacman "$@"

# Exclude build products and checkout credentials, but keep local recipe edits.
mkdir -p /tmp/pkg /home/notroot/packages
tar -C /recipe --exclude='./.git' --exclude='./build-output' \
    --exclude='./src' --exclude='./pkg' --exclude='*.pkg.tar.*' \
    --exclude='*.log' -cf - . | tar -C /tmp/pkg -xf -
cd /tmp/pkg

# Cap the launcher and compressor too. Preserve CachyOS's compiler/hardening
# defaults and Chromium's ThinLTO handling.
printf '\nMAKEFLAGS="-j%s"\nNINJAFLAGS="-j%s"\nCOMPRESSZST=(zstd -c -T%s --ultra -20 -)\n' \
    "$CHROMIUM_BUILD_JOBS" "$CHROMIUM_BUILD_JOBS" "$CHROMIUM_BUILD_JOBS" |
    sudo tee -a /etc/makepkg.conf >/dev/null
{
    printf '\n--- Effective makepkg configuration ---\n'
    cat /etc/makepkg.conf
} | sudo tee -a /output/build-environment.txt >/dev/null

# Generate metadata without changing checksums, then enforce source integrity.
makepkg --printsrcinfo | sudo tee /output/package.SRCINFO >/dev/null
makepkg -sc --noconfirm --log
pacman -Q | sudo tee /output/build-packages.txt >/dev/null
