#!/usr/bin/env bash
set -u

cd /home/notroot
BUILD_ARGUMENTS=""

if [[ -d "/mnt/input" && -f "/mnt/input/progress.tar.zst.sum" && -f "/mnt/input/progress.tar.zst" ]]; then
    echo "==> Found input directory, extracting previous build state"
    cd /mnt/input
    sha256sum -c progress.tar.zst.sum
    cd /home/notroot

    sudo tar -xf /mnt/input/progress.tar.zst -C /home/notroot
    sudo rm -f /mnt/input/progress.tar.zst /mnt/input/progress.tar.zst.sum
    sudo rm -f ./*.tar.* 2>/dev/null || true
    sudo chown -R notroot:notroot /home/notroot

    echo "==> Build subdirectory sizes"
    du -h -d 1 || true
    BUILD_ARGUMENTS="--noextract --nodeps"
fi

echo "==> Building for up to ${TIMEOUT:-330} minutes"
echo "==> SOURCE_DATE_EPOCH=$(cat /etc/buildtime)"

set +e
SOURCE_DATE_EPOCH="$(cat /etc/buildtime)" \
    timeout -k 10m -s SIGTERM "${TIMEOUT:-330}m" \
    makepkg $BUILD_ARGUMENTS
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "==> Build successful"
elif [[ $EXIT_CODE -eq 124 ]]; then
    echo "==> Build stage timed out normally; saving progress"
else
    echo "==> Build failed with exit code $EXIT_CODE" >&2
    exit "$EXIT_CODE"
fi

echo "==> Build directory content"
ls -lah /home/notroot
echo "==> Build subdirectory sizes"
sudo du -hd 1 /home/notroot || true

if compgen -G "/home/notroot/*.pkg.tar.zst" >/dev/null; then
    echo "==> Package produced"
    cd /home/notroot
    sha256sum ./*.pkg.tar.zst | tee sum.txt

    if [[ -d "/mnt/output" ]]; then
        sudo mv ./*.pkg.tar.zst sum.txt /mnt/output/
    fi
fi

if [[ -d "/mnt/progress" ]]; then
    cd /home/notroot
    if [[ -d src ]]; then
        echo "==> Saving build progress"
        tar caf progress.tar.zst src/ --remove-file -H posix --atime-preserve
        sha256sum progress.tar.zst | tee progress.tar.zst.sum
        sudo mv progress.tar.zst progress.tar.zst.sum /mnt/progress/
    fi
fi
