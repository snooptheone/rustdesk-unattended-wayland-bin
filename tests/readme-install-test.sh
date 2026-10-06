#!/usr/bin/env bash
# Runs the README's "Install from the pacman repository" section LITERALLY, inside a clean archlinux container: extracts its bash/ini code blocks
# and executes them in order, then checks that `gpg --show-keys` prints the fingerprint the README shows and that the package got installed.
# Uses the PUBLISHED repository (needs network). Rerun it whenever that README section or the repository changes. From the repo root:
#   docker run --rm -v "$PWD":/src:ro archlinux:base-devel bash /src/tests/readme-install-test.sh
set -uo pipefail
README=/src/README.md
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

cd /tmp || exit 1
pacman-key --init >/dev/null 2>&1
pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1   # environment only: fresh Arch keyring

section=$(awk '/^## Install from the pacman repository/{f=1;next} /^## Install by building/{f=0} f' "$README")
shown=$(grep -E '^[0-9A-F]{4} [0-9A-F]{4} ' <<<"$section" | tr -d ' ')
echo "== fingerprint no README: $shown"
[ ${#shown} -eq 40 ] && ok "o README mostra um fingerprint de 40 caracteres" || bad "fingerprint do README não achado"

echo "== executando os blocos do README, na ordem"
blocks=$(awk '/^```/{ if (inb) {inb=0; next} else {inb=1; lang=$0; sub(/^```/,"",lang); next} } inb && lang!="" {print lang "\t" $0}' <<<"$section")
n=0
while IFS=$'\t' read -r lang line; do
  [ -z "$line" ] && continue
  case $lang in
    bash)
      cmd=${line#sudo }
      case $cmd in "pacman -S"*) cmd="$cmd --noconfirm";; esac
      n=$((n+1)); echo "-- \$ $line"
      if out=$(bash -c "$cmd" 2>&1); then ok "comando $n"; else bad "comando $n falhou: $(tail -2 <<<"$out" | tr '\n' ' ')"; fi
      case $cmd in "gpg --show-keys"*) got=$(grep -E '^ +[0-9A-F]{4} ' <<<"$out" | tr -d ' '); [ "$got" = "$shown" ] && ok "gpg imprime o MESMO fingerprint do README" || bad "fingerprint difere: gpg=$got README=$shown";; esac ;;
    ini) printf '\n%s\n' "$line" >> /etc/pacman.conf ;;
  esac
done <<<"$blocks"

echo "== resultado do passo 4"
pacman -Q rustdesk-unattended-wayland-bin 2>&1 | sed 's/^/   /'
pacman -Qi rustdesk-unattended-wayland-bin 2>/dev/null | grep -E "^Validated By" | sed 's/^/   /'
pacman -Qi rustdesk-unattended-wayland-bin >/dev/null 2>&1 && ok "pacote instalado seguindo só o README" || bad "pacote não instalado"
grep -A2 '^\[rustdesk-drm\]' /etc/pacman.conf | sed 's/^/   /'
echo "== resultado: $FAILS falha(s)"
exit "$FAILS"
