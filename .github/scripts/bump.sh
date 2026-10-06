#!/usr/bin/env bash
# Bump PKGBUILD and .SRCINFO to the latest stable RustDesk release that ships the unattended-wayland deb.
# Prints the new version; prints nothing (exit 0) when there is nothing to do.
set -euo pipefail
cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
rel=$(gh api repos/rustdesk/rustdesk/releases/latest)
new=$(jq -r .tag_name <<<"$rel")
[[ $new =~ ^[0-9]+(\.[0-9]+)*$ ]] || exit 0
[ "$new" != "$cur" ] && [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1)" = "$new" ] || exit 0
sha=$(jq -r --arg n "rustdesk-unattended-wayland-$new-x86_64.deb" '.assets[] | select(.name == $n) | .digest' <<<"$rel")
[[ $sha =~ ^sha256:[0-9a-f]{64}$ ]] || exit 0
old=$(sed -n "s/^sha256sums_x86_64=('\(.*\)')/\1/p" PKGBUILD)
sed -i -e "s/${cur//./\\.}/$new/g" -e "s/$old/${sha#sha256:}/" -e 's/^pkgrel=.*/pkgrel=1/' -e 's/^\tpkgrel = .*/\tpkgrel = 1/' PKGBUILD .SRCINFO
echo "$new"
