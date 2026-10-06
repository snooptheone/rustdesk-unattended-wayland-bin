#!/usr/bin/env bash
# Signed pacman repo test. Runs INSIDE a throwaway archlinux container, with a throwaway GPG key, so it never touches the host.
# Needs a built package (run `makepkg` first). From the repo root:
#   docker run --rm -v "$PWD":/src:ro -v "$PWD/tests/repotest.sh":/t/repotest.sh:ro archlinux:base-devel bash /t/repotest.sh
# Checks: repo-add --sign, pacman -Sy/-Si, signed install, dependencies resolve; and that pacman REFUSES an unsigned package,
# a package signed by an untrusted key, a corrupted db signature and a db without signature (SigLevel = Required DatabaseRequired).
set -uo pipefail
PKG=$(ls /src/*.pkg.tar.zst | head -1)
NAME=rustdesk-unattended-wayland-bin
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
FAILS=0
expect_fail() { # description, command...
  local d=$1; shift
  if out=$("$@" 2>&1); then bad "$d (deveria ter falhado)"; else ok "$d -> $(grep -m1 -i -E 'signature|trust|unknown|invalid|required|corrupt|failed' <<<"$out" | cut -c1-110)"; fi
}

echo "== setup: chaves de teste e pacman-key"
pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1
pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 && pacman-key --populate archlinux >/dev/null 2>&1 && echo "  keyring do container atualizado"
export GNUPGHOME=/tmp/gpg-good; mkdir -p $GNUPGHOME; chmod 700 $GNUPGHOME
gpg --batch --passphrase '' --quick-gen-key "rustdesk-drm TEST <test@example.invalid>" ed25519 sign never 2>/dev/null
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
echo "  chave de teste: $FPR"
gpg --armor --export "$FPR" > /tmp/good.pub

echo "== monta o repositório (como o workflow faria)"
mkdir -p /repo && cp "$PKG" /repo/ && { cd /repo || exit 1; }
P=$(basename "$PKG")
gpg --batch --yes --detach-sign --no-armor --local-user "$FPR" "$P"
repo-add --sign --key "$FPR" rustdesk-drm.db.tar.zst "$P" 2>&1 | grep -E "Adding|Creating|ERROR|WARNING" | cut -c1-110
# GitHub Releases não tem symlink: troca por cópias reais
for f in rustdesk-drm.db rustdesk-drm.db.sig rustdesk-drm.files rustdesk-drm.files.sig; do [ -L "$f" ] && { cp --remove-destination -L "$(readlink -f "$f")" "$f"; }; done
ls -l /repo | awk '{print "   ",$5,$9}' | tail -n +2

echo "== configura o pacman (SigLevel estrito) e confia só na chave de teste"
pacman-key --add /tmp/good.pub >/dev/null 2>&1 && pacman-key --lsign-key "$FPR" >/dev/null 2>&1
cat >> /etc/pacman.conf <<E

[rustdesk-drm]
SigLevel = Required DatabaseRequired
Server = file:///repo
E
pacman -Sy --noconfirm 2>&1 | grep -E "rustdesk-drm|error" | head -3
pacman -Si "$NAME" 2>&1 | grep -E "^(Repository|Name|Version|Signatures)"

echo "== NEGATIVOS (todos devem ser recusados)"
# 1) pacote sem assinatura
mv /repo/"$P".sig /tmp/"$P".sig.bak
expect_fail "pacote SEM .sig é recusado" pacman -Sdd --noconfirm "$NAME"
mv /tmp/"$P".sig.bak /repo/"$P".sig
# 2) pacote assinado por chave NÃO confiável (e banco refeito com ela)
export GNUPGHOME=/tmp/gpg-evil; mkdir -p $GNUPGHOME; chmod 700 $GNUPGHOME
gpg --batch --passphrase '' --quick-gen-key "evil <evil@example.invalid>" ed25519 sign never 2>/dev/null
EVIL=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
cp /repo/"$P".sig /tmp/"$P".sig.good
gpg --batch --yes --detach-sign --no-armor --local-user "$EVIL" -o /repo/"$P".sig /repo/"$P"
expect_fail "pacote assinado por chave NÃO confiável é recusado" pacman -Sdd --noconfirm "$NAME"
cp /tmp/"$P".sig.good /repo/"$P".sig
# 3) banco com assinatura corrompida
rm -f /var/lib/pacman/sync/rustdesk-drm.db /var/lib/pacman/sync/rustdesk-drm.db.sig
cp /repo/rustdesk-drm.db.sig /tmp/db.sig.good
printf 'X' | dd of=/repo/rustdesk-drm.db.sig bs=1 seek=10 conv=notrunc 2>/dev/null
expect_fail "banco com .sig corrompida é recusado" pacman -Sy --noconfirm
cp /tmp/db.sig.good /repo/rustdesk-drm.db.sig
# 4) banco sem assinatura (DatabaseRequired)
rm -f /var/lib/pacman/sync/rustdesk-drm.db /var/lib/pacman/sync/rustdesk-drm.db.sig
mv /repo/rustdesk-drm.db.sig /tmp/db.sig.bak
expect_fail "banco SEM .sig é recusado (DatabaseRequired)" pacman -Sy --noconfirm
mv /tmp/db.sig.bak /repo/rustdesk-drm.db.sig
rm -f /var/lib/pacman/sync/rustdesk-drm.db /var/lib/pacman/sync/rustdesk-drm.db.sig

echo "== POSITIVO: instala nosso pacote pelo repositório assinado (sem baixar deps do Arch)"
rm -f /var/cache/pacman/pkg/rustdesk-unattended-wayland-bin-* # o cache guardou a .sig da chave maliciosa do negativo 2
pacman -Sy --noconfirm >/dev/null 2>&1 || bad "pacman -Sy com o banco assinado falhou"
if pacman -Sdd --noconfirm "$NAME" >/tmp/inst.log 2>&1; then ok "instalação assinada pelo repo concluída"; else bad "instalação falhou"; tail -8 /tmp/inst.log; fi
grep -E "verifying|checking package integrity|checking keyring" /tmp/inst.log | head -3 | sed 's/^/  /'
pacman -Q "$NAME" 2>&1
grep -E "libdrmtap\.so\.0\.|usr/lib/systemd/system/rustdesk.service" <(pacman -Ql "$NAME") | awk '{print "  arquivo:",$2}'
test -L /usr/bin/rustdesk && echo "  symlink /usr/bin/rustdesk -> $(readlink /usr/bin/rustdesk)"
echo "  avisos dos scriptlets (esperados no container, sem systemd):"; grep -i -E "warning|error|failed|not found" /tmp/inst.log | head -5 | sed 's/^/    /'
echo "== DEPENDÊNCIAS existem nos repositórios do Arch?"
N=0; for d in $(pacman -Qi "$NAME" | awk -F: '/^Depends On/{print $2}'); do d=${d%%[<>=]*}; [ "$d" = None ] && continue; N=$((N+1)); pacman -Si "$d" >/dev/null 2>&1 || bad "dependência sem pacote: $d"; done; echo "  $N dependências verificadas"; [ "$N" -ge 5 ] || bad "lista de dependências suspeita (N=$N)"
echo "== resultado: $FAILS falha(s)"
exit "$FAILS"
