#!/usr/bin/env bash
# One-shot setup of the GPG key that signs the rustdesk-drm pacman repository.
# Run it on a machine where `bw` (Bitwarden CLI), `gh` (logged in) and `gpg` work. It:
#   1. generates a dedicated ed25519 signing key (2 years) with a random passphrase, in a TEMPORARY keyring (~/.gnupg is never touched);
#   2. proves the exported key + passphrase work, in yet another empty keyring;
#   3. saves the key, passphrase, fingerprint and revocation certificate as secure notes in Bitwarden, and reads them back to compare;
#   4. only then sets the GitHub secrets GPG_PRIVATE_KEY and GPG_PASSPHRASE;
#   5. shreds every temporary file.
# Nothing is overwritten: it refuses if the secrets or the Bitwarden items already exist. `--dry-run` stops after step 2.
# Usage: tools/setup-signing-key.sh [--dry-run]     Env: REPO=owner/repo (default below)
set -euo pipefail
REPO=${REPO:-snooptheone/rustdesk-unattended-wayland-bin}
KEY_UID="rustdesk-drm repo (snooptheone) <4625164+snooptheone@users.noreply.github.com>"
ITEM_KEY="rustdesk-drm GPG - signing key"
ITEM_REV="rustdesk-drm GPG - revocation certificate"
dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
die() { echo "ERROR: $*" >&2; exit 1; }

for c in gpg gh bw jq; do command -v "$c" >/dev/null || die "missing command: $c"; done
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
case $(bw status | jq -r .status) in
  unauthenticated) die "bw is not logged in (bw login)" ;;
  locked) BW_SESSION=$(bw unlock --raw) || die "bw unlock failed"; export BW_SESSION ;;
esac

echo "== checking nothing would be overwritten"
if gh secret list --repo "$REPO" | awk '{print $1}' | grep -qxE 'GPG_PRIVATE_KEY|GPG_PASSPHRASE'; then
  die "a GPG secret already exists on $REPO. Replacing it makes a NEW key; delete the old one first (gh secret delete) if that is what you want"
fi
for n in "$ITEM_KEY" "$ITEM_REV"; do
  [ "$(bw list items --search "$n" | jq --arg n "$n" '[.[] | select(.name == $n)] | length')" = 0 ] || die "Bitwarden item '$n' already exists"
done

umask 077
w=$(mktemp -d)
export GNUPGHOME=$w/gnupg
install -d -m700 "$GNUPGHOME" "$w/verify"
trap 'gpgconf --kill gpg-agent 2>/dev/null; GNUPGHOME=$w/verify gpgconf --kill gpg-agent 2>/dev/null; find "$w" -type f -exec shred -u {} +; rm -r "$w"' EXIT

echo "== generating the key (temporary keyring)"
printf '%s' "$(bw generate -uln --length 48)" > "$w/pass"
[ "$(wc -c < "$w/pass")" -ge 32 ] || die "bw generate returned a short passphrase"
gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$w/pass" --quick-gen-key "$KEY_UID" ed25519 sign 2y
fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
[ -n "$fpr" ] || die "could not read the new key fingerprint"
gpg --batch --pinentry-mode loopback --passphrase-file "$w/pass" --armor --export-secret-keys "$fpr" > "$w/key.asc"
# gpg wrote a revocation certificate next to the key, with a safety colon before the first line; remove it to make it usable
sed 's/^:-----BEGIN/-----BEGIN/' "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" > "$w/revoke.asc"
grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$w/revoke.asc" || die "revocation certificate not found"

echo "== proving the exported key and passphrase work (empty keyring)"
GNUPGHOME=$w/verify gpg --batch --quiet --import "$w/key.asc" 2>/dev/null
echo proof | GNUPGHOME=$w/verify gpg --batch --pinentry-mode loopback --passphrase-file "$w/pass" --local-user "$fpr" --detach-sign >/dev/null \
  || die "the exported key does not sign with the passphrase"
expires=$(gpg --list-keys --with-colons "$fpr" | awk -F: '/^pub/{print $7; exit}')
echo "   fingerprint: $fpr"
echo "   expires:     $(date -d "@$expires" +%F)"
[ "$dry" = 1 ] && { echo "== --dry-run: stopping here, nothing was saved anywhere"; exit 0; }

echo "== saving to Bitwarden"
jq -n --arg fpr "$fpr" --rawfile p "$w/pass" '[{name:"fingerprint",value:$fpr,type:0},{name:"passphrase",value:$p,type:1}]' > "$w/fields.json"
jq -n --arg fpr "$fpr" '[{name:"fingerprint",value:$fpr,type:0}]' > "$w/fields-rev.json"
mk() { # name, notes file, fields file -> prints the new item id
  bw get template item | jq --arg n "$1" --rawfile notes "$2" --slurpfile f "$3" '.type=2 | .secureNote.type=0 | .name=$n | .notes=$notes | .fields=$f[0]' \
    | bw encode | bw create item | jq -r .id
}
id_key=$(mk "$ITEM_KEY" "$w/key.asc" "$w/fields.json")
id_rev=$(mk "$ITEM_REV" "$w/revoke.asc" "$w/fields-rev.json")
bw sync >/dev/null
echo "== reading it back from Bitwarden and comparing"
bw get item "$id_key" | jq -j .notes | cmp - "$w/key.asc" || die "Bitwarden key note differs; nothing was sent to GitHub"
bw get item "$id_key" | jq -j '.fields[] | select(.name == "passphrase") | .value' | cmp - "$w/pass" || die "Bitwarden passphrase differs; nothing was sent to GitHub"
bw get item "$id_rev" | jq -j .notes | cmp - "$w/revoke.asc" || die "Bitwarden revocation note differs; nothing was sent to GitHub"

echo "== setting the GitHub secrets on $REPO"
gh secret set GPG_PRIVATE_KEY --repo "$REPO" < "$w/key.asc"
gh secret set GPG_PASSPHRASE --repo "$REPO" < "$w/pass"
gh secret list --repo "$REPO" | awk '{print "   secret: " $1}'

cat <<E
== done
   Bitwarden items: "$ITEM_KEY" and "$ITEM_REV"
   fingerprint:     $fpr        (put it in the README; users must check it)
   key expires:     $(date -d "@$expires" +%F)  (renew before that)
   temporary files are being shredded; ~/.gnupg was never touched.
E
