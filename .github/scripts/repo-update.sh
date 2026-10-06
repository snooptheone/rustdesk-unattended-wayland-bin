#!/usr/bin/env bash
# Add the package of a version release to the signed pacman repo kept in the fixed release `repo`.
# Usage: repo-update.sh [version-release-tag]   (default: pkgver-pkgrel from ./PKGBUILD)
# Runs gh from a temp dir that is not a clone, so GH_REPO (owner/repo) must be set. Needs GPG_PRIVATE_KEY (armored) and, if the key has one, GPG_PASSPHRASE. Without a key it does nothing and succeeds.
set -euo pipefail
name=rustdesk-drm repo_tag=repo keep=3
tag=${1:-$(sed -n 's/^pkgver=//p' PKGBUILD)-$(sed -n 's/^pkgrel=//p' PKGBUILD)}
[ -n "${GPG_PRIVATE_KEY:-}" ] || { echo "::notice::GPG_PRIVATE_KEY is not set, skipping the pacman repository update"; exit 0; }

w=$(mktemp -d)
export GNUPGHOME=$w/gnupg
install -d -m700 "$GNUPGHOME" "$w/repo"
trap 'gpgconf --kill gpg-agent; rm -r "$w"' EXIT
gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY"
fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
[ -n "${GPG_PASSPHRASE:-}" ] && (umask 077; printf '%s' "$GPG_PASSPHRASE" > "$w/pass")
sign() { gpg --batch --yes --pinentry-mode loopback ${GPG_PASSPHRASE:+--passphrase-file "$w/pass"} --local-user "$fpr" --detach-sign --no-armor "$1"; }

cd "$w/repo"
gh release download "$tag" -p '*.pkg.tar.zst' -D .
pkg=$(ls -- *.pkg.tar.zst)
gh release view "$repo_tag" >/dev/null 2>&1 || gh release create "$repo_tag" ${GITHUB_SHA:+--target "$GITHUB_SHA"} --latest=false \
  --title "pacman repository ($name)" \
  --notes "Signed pacman repository. Add [$name] with Server = <this release's download URL>, trust the key in $name.gpg. See the README."
have=$(gh release view "$repo_tag" --json assets --jq '.assets[].name')
for f in "$name.db.tar.zst" "$name.files.tar.zst"; do
  if grep -qxF "$f" <<<"$have"; then gh release download "$repo_tag" -p "$f" -D .; fi
done
# done means the DATABASE lists this exact version; the package file alone proves nothing (an interrupted run uploads it first)
entry=$(bsdtar -xOf "$pkg" .PKGINFO | awk -F' = ' '$1=="pkgname"{n=$2} $1=="pkgver"{v=$2} END{print n"-"v"/"}')
if [ -f "$name.db.tar.zst" ] && bsdtar -tf "$name.db.tar.zst" | grep -qxF "$entry"; then echo "$entry is already in the repository"; exit 0; fi
repo-add -q "$name.db.tar.zst" "$pkg"
# releases have no symlinks: .db and .files must be real copies
for f in "$name.db" "$name.files"; do cp --remove-destination -L "$(readlink -f "$f")" "$f"; done
for f in "$pkg" "$name.db.tar.zst" "$name.files.tar.zst"; do sign "$f"; gpg --batch --verify "$f.sig" "$f" 2>/dev/null; done
cp "$name.db.tar.zst.sig" "$name.db.sig"; cp "$name.files.tar.zst.sig" "$name.files.sig"
gpg --armor --export "$fpr" > "$name.gpg"

# package first, database last: the db must never point to a file that is not there yet
gh release upload "$repo_tag" "$pkg" "$pkg.sig" "$name.gpg" --clobber
gh release upload "$repo_tag" "$name".{db,files}.tar.zst{,.sig} "$name".{db,files}{,.sig} --clobber

# keep the newest $keep package files (the db only ever points to the newest one)
for f in $({ echo "$have"; echo "$pkg"; } | grep -E '\.pkg\.tar\.zst$' | sort -uV | head -n "-$keep"); do
  gh release delete-asset "$repo_tag" "$f" -y
  gh release delete-asset "$repo_tag" "$f.sig" -y || true
done
