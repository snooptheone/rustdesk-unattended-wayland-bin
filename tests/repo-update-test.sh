#!/usr/bin/env bash
# Tests .github/scripts/repo-update.sh end to end, INSIDE a throwaway archlinux container, with a throwaway passphrase-protected key and a
# directory standing in for GitHub releases (tests/fake-gh). Never touches the host or GitHub. From the repo root, with the package built:
#   docker run --rm -v "$PWD":/src:ro archlinux:base-devel bash /src/tests/repo-update-test.sh
set -uo pipefail
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

mkdir -p /w/bin && cp /src/tests/fake-gh /w/bin/gh && chmod +x /w/bin/gh
cp /src/PKGBUILD /w/ && cd /w || exit 1
export PATH=/w/bin:$PATH FAKE_RELEASES=/w/releases
tag=$(sed -n 's/^pkgver=//p' PKGBUILD)-$(sed -n 's/^pkgrel=//p' PKGBUILD)
pkg=$(basename "$(ls /src/*.pkg.tar.zst | head -1)")
R=$FAKE_RELEASES/repo

echo "== sem chave: não faz nada e termina com sucesso"
mkdir -p "$FAKE_RELEASES/$tag" && cp "/src/$pkg" "$FAKE_RELEASES/$tag/"
out=$(bash /src/.github/scripts/repo-update.sh 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q "skipping" <<<"$out" && [ ! -d "$R" ] && ok "sem GPG_PRIVATE_KEY: aviso, exit 0, nada criado" || bad "sem chave (rc=$rc): $out"

echo "== chave de teste COM frase-senha"
export GNUPGHOME=/w/gnupg-test; install -d -m700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase 'test-pass' --quick-gen-key "rustdesk-drm TEST <test@example.invalid>" ed25519 sign never 2>/dev/null
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
GPG_PRIVATE_KEY=$(gpg --batch --pinentry-mode loopback --passphrase 'test-pass' --armor --export-secret-keys "$FPR")
export GPG_PRIVATE_KEY GPG_PASSPHRASE='test-pass'
unset GNUPGHOME

echo "== versões antigas já na release (poda deve manter só as 3 mais novas)"
mkdir -p "$R"
for v in 1.4.7-1 1.4.8-1 1.4.9-1; do for s in "" .sig; do echo old > "$R/rustdesk-unattended-wayland-bin-$v-x86_64.pkg.tar.zst$s"; done; done

echo "== run anterior interrompido: pacote já na release, banco ainda não (o script tem que completar o trabalho)"
cp "/src/$pkg" "$R/$pkg"; echo partial > "$R/$pkg.sig"

echo "== 1ª execução"
out=$(bash /src/.github/scripts/repo-update.sh 2>&1); rc=$?
[ $rc -eq 0 ] && ok "script terminou com sucesso" || { bad "script falhou (rc=$rc)"; echo "$out" | tail -8; }
for f in "$pkg" "$pkg.sig" rustdesk-drm.gpg rustdesk-drm.db rustdesk-drm.db.sig rustdesk-drm.db.tar.zst rustdesk-drm.db.tar.zst.sig \
         rustdesk-drm.files rustdesk-drm.files.sig rustdesk-drm.files.tar.zst rustdesk-drm.files.tar.zst.sig; do
  check "release 'repo' tem $f" test -s "$R/$f"
done
check ".db é arquivo real (não symlink)" test ! -L "$R/rustdesk-drm.db"
check "assinatura do .db confere (chave de teste)" env GNUPGHOME=/w/gnupg-test gpg --batch --verify "$R/rustdesk-drm.db.sig" "$R/rustdesk-drm.db"
check "poda: 1.4.7-1 removida" test ! -e "$R/rustdesk-unattended-wayland-bin-1.4.7-1-x86_64.pkg.tar.zst"
check "poda: .sig de 1.4.7-1 removida" test ! -e "$R/rustdesk-unattended-wayland-bin-1.4.7-1-x86_64.pkg.tar.zst.sig"
check "poda: 1.4.8-1 e 1.4.9-1 mantidas" test -e "$R/rustdesk-unattended-wayland-bin-1.4.8-1-x86_64.pkg.tar.zst" -a -e "$R/rustdesk-unattended-wayland-bin-1.4.9-1-x86_64.pkg.tar.zst"
check "pacote do repo é idêntico ao da release versionada" cmp "$R/$pkg" "$FAKE_RELEASES/$tag/$pkg"

echo "== 2ª execução: idempotente (nada muda)"
before=$(cd "$R" && sha256sum ./* | sort)
out=$(bash /src/.github/scripts/repo-update.sh 2>&1); rc=$?
after=$(cd "$R" && sha256sum ./* | sort)
[ $rc -eq 0 ] && grep -q "is already in the repository" <<<"$out" && [ "$before" = "$after" ] && ok "já presente: nada reenviado, nada alterado" || bad "não idempotente (rc=$rc)"

echo "== o que um usuário faz: confiar na chave publicada e instalar pelo repo"
pacman-key --init >/dev/null 2>&1
pacman-key --add "$R/rustdesk-drm.gpg" >/dev/null 2>&1 && pacman-key --lsign-key "$FPR" >/dev/null 2>&1
printf '\n[rustdesk-drm]\nSigLevel = Required DatabaseRequired\nServer = file://%s\n' "$R" >> /etc/pacman.conf
pacman -Sy --noconfirm >/dev/null 2>&1 && ok "pacman -Sy com SigLevel estrito aceita o banco assinado" || bad "pacman -Sy falhou"
pacman -Si rustdesk-unattended-wayland-bin 2>/dev/null | grep -q '^Repository *: rustdesk-drm' && ok "pacman -Si acha o pacote" || bad "pacman -Si"
pacman -Sdd --noconfirm rustdesk-unattended-wayland-bin >/dev/null 2>&1 && ok "instalação assinada ok" || bad "instalação falhou"

echo "== resultado: $FAILS falha(s)"
exit "$FAILS"
