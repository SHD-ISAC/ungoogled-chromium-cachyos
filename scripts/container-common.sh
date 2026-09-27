#!/usr/bin/env bash
# Shared setup for the ephemeral CachyOS containers. Never run on the host.

retry() {
    local attempts=$1 delay=$2 n rc
    shift 2
    for ((n = 1; n <= attempts; n++)); do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        echo "warning: attempt $n/$attempts failed (exit $rc): $*" >&2
        if ((n < attempts)); then sleep "$delay"; fi
    done
    return "$rc"
}

clear_sync_databases() {
    sudo rm -f /var/lib/pacman/sync/*.{db,db.sig,files,files.sig,part}
}

sync_databases() {
    clear_sync_databases
    if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
        sudo cachyos-rate-mirrors || echo 'warning: mirror ranking failed; using current mirrors' >&2
    fi
    sudo pacman -Syy --noconfirm
}

bootstrap_pacman() {
    # Some Docker hosts cannot apply pacman's Landlock download sandbox. Scope
    # this setting to [options] in the container, never to a repository section.
    if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
        sudo sed -i '/^\[options\]$/a DisableSandbox' /etc/pacman.conf
    fi

    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    if [[ -f /usr/share/pacman/keyrings/cachyos.gpg ]]; then
        sudo pacman-key --populate cachyos
    fi

    retry 5 15 sync_databases
    local keyrings=(archlinux-keyring)
    if pacman -Si cachyos-keyring >/dev/null 2>&1; then
        keyrings+=(cachyos-keyring)
    fi
    retry 5 15 sudo pacman -S --needed --noconfirm "${keyrings[@]}"
    sudo pacman-key --populate "${keyrings[@]%-keyring}"
    # Finish the upgrade before using build tools. Never ignore keyring errors
    # or disable package signature validation to work around a stale mirror.
    retry 5 15 upgrade_packages "$@"
}

upgrade_packages() {
    sync_databases || return "$?"
    sudo pacman -Su --needed --noconfirm "$@"
}

depot_python() {
    # Preserve the verified Python 3.13 workaround for depot_tools/gsutil.
    # This is used only for prefetch, not for the normal Chromium build.
    mkdir -p /tmp/chromium-python
    ln -sf /usr/bin/python3.13 /tmp/chromium-python/python3
    export PATH="/tmp/chromium-python:$PATH"
    export VPYTHON_BYPASS='manually managed python not supported by chrome operations'
    echo "==> depot_tools Python: $(python3 --version)"
}
