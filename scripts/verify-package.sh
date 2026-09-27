#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:?Usage: verify-package.sh OUTPUT_DIRECTORY}"
expected_version="$(bash -c 'source "$1"; printf "%s\n" "${epoch:+$epoch:}${pkgver}-${pkgrel}"' -- "$repo_root/PKGBUILD")"
[[ $expected_version =~ ^([0-9]+:)?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(\.[0-9]+)?$ ]]

cd "$output_dir"
shopt -s nullglob
packages=(ungoogled-chromium-*.pkg.tar.zst)
((${#packages[@]} == 1)) || {
    echo >&2 "Expected exactly one Chromium package, found ${#packages[@]}"
    exit 1
}
pkg=${packages[0]}

# Raw .PKGINFO is stable across locales and pacman's display formatting.
metadata="$(bsdtar -xOf "$pkg" .PKGINFO)"
field() { awk -F ' = ' -v key="$1" '$1 == key { print $2 }' <<< "$metadata"; }
name=$(field pkgname)
version=$(field pkgver)
arch=$(field arch)
[[ $name == ungoogled-chromium && $version == "$expected_version" && $arch == x86_64_v4 ]] || {
    printf >&2 'Package mismatch: name=%s version=%s arch=%s; expected ungoogled-chromium %s x86_64_v4\n' \
        "$name" "$version" "$arch" "$expected_version"
    exit 1
}
[[ $pkg == "ungoogled-chromium-${version#*:}-x86_64_v4.pkg.tar.zst" ]] || {
    echo >&2 "Unexpected package filename: $pkg"
    exit 1
}
printf '%s\n' "$metadata" > package.PKGINFO
bsdtar -xOf "$pkg" .BUILDINFO > package.BUILDINFO
sha256sum -- "$pkg" > SHA256SUMS
cat SHA256SUMS
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'version=%s\n' "$version" >> "$GITHUB_OUTPUT"
fi
echo "==> Verified ungoogled-chromium $version ($arch)"
