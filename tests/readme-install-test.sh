#!/usr/bin/env bash
# Runs the README's "Install from the pacman repository" copy-paste block LITERALLY, inside a clean archlinux container (only `sudo` is dropped,
# the container is root, and --noconfirm is added). Checks, in this order:
#   1. the fingerprint shown in the text is the one the block pins;
#   2. the block with a WRONG pinned fingerprint stops, and leaves pacman.conf and the keyring untouched;
#   3. the real block installs the package, validated by signature;
#   4. running it a second time does not add the repository to pacman.conf twice.
# Uses the PUBLISHED repository (needs network). Rerun it whenever that README section or the repository changes. From the repo root:
#   docker run --rm -v "$PWD":/src:ro archlinux:base-devel bash /src/tests/readme-install-test.sh
set -uo pipefail
README=/src/README.md
PKG=rustdesk-unattended-wayland-bin
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

cd /tmp || exit 1
pacman-key --init >/dev/null 2>&1
pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1   # environment only: fresh Arch keyring

section=$(awk '/^## Install from the pacman repository/{f=1;next} /^## Install by building/{f=0} f' "$README")
# first ```bash block of the section, newlines kept
block=$(awk '/^```/{ if (inb) { exit } else { inb=1; lang=$0; sub(/^```/,"",lang); skip=(lang!="bash"); inb=!skip; next } } inb' <<<"$section")
[ -n "$block" ] && ok "bloco bash encontrado no README ($(wc -l <<<"$block") linhas)" || { bad "bloco bash não encontrado"; exit 1; }

echo "== 1. o fingerprint do texto é o que o bloco fixa?"
shown=$(grep -E '^`[0-9A-F]{4} [0-9A-F]{4} ' <<<"$section" | tr -d '` ')
pinned=$(grep -o 'FPR=[0-9A-F]\{40\}' <<<"$block" | head -1 | cut -d= -f2)
echo "   texto:  $shown"; echo "   bloco:  $pinned"
[ ${#shown} -eq 40 ] && [ "$shown" = "$pinned" ] && ok "iguais (40 caracteres)" || bad "o fingerprint do texto difere do fixado no bloco"

run() { bash -c "$(sed -e 's/sudo //g' -e 's/pacman -Syu\? /&--noconfirm /' <<<"$1")" 2>&1; }

echo "== 2. NEGATIVO: com o fingerprint fixado errado o bloco tem que parar antes de confiar em qualquer coisa"
wrong=${pinned%?}0; [ "$wrong" = "$pinned" ] && wrong=${pinned%?}1
if out=$(run "${block/FPR=$pinned/FPR=$wrong}"); then bad "o bloco com fingerprint errado NÃO parou"; else ok "o bloco parou (exit != 0)"; fi
grep -q '^\[rustdesk-drm\]' /etc/pacman.conf && bad "pacman.conf foi alterado" || ok "pacman.conf intacto"
pacman-key --list-keys "$pinned" >/dev/null 2>&1 && bad "a chave entrou no chaveiro do pacman" || ok "nenhuma chave nova no chaveiro"
pacman -Q "$PKG" >/dev/null 2>&1 && bad "o pacote foi instalado" || ok "pacote não instalado"

echo "== 3. o bloco real, colado como está"
if out=$(run "$block"); then ok "bloco terminou com sucesso"; else bad "bloco falhou: $(tail -3 <<<"$out" | tr '\n' ' ')"; fi
pacman -Q "$PKG" 2>&1 | sed 's/^/   /'
pacman -Qi "$PKG" >/dev/null 2>&1 && ok "pacote instalado seguindo só o README" || bad "pacote não instalado"
pacman -Qi "$PKG" 2>/dev/null | grep -E "^Validated By" | sed 's/^/   /' | grep -q Signature && ok "validado por assinatura" || bad "sem validação por assinatura"
pacman -Qk "$PKG" 2>&1 | tail -1 | grep -q ' 0 missing files' && ok "0 arquivos faltando" || bad "arquivos faltando"

echo "== 4. IDEMPOTENTE: rodar de novo não duplica o repositório"
if out=$(run "$block"); then ok "segunda execução terminou com sucesso"; else bad "segunda execução falhou: $(tail -3 <<<"$out" | tr '\n' ' ')"; fi
n=$(grep -c '^\[rustdesk-drm\]' /etc/pacman.conf)
[ "$n" = 1 ] && ok "[rustdesk-drm] aparece uma única vez em pacman.conf" || bad "[rustdesk-drm] aparece $n vezes"
grep -A2 '^\[rustdesk-drm\]' /etc/pacman.conf | sed 's/^/   /'

echo "== resultado: $FAILS falha(s)"
exit "$FAILS"
