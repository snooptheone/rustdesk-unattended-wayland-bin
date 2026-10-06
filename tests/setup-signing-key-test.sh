#!/usr/bin/env bash
# Tests tools/setup-signing-key.sh with fake `bw` and `gh` (directories instead of Bitwarden and GitHub). Touches no real vault, secret or keyring:
# every gpg call runs in a temporary GNUPGHOME. From the repo root: bash tests/setup-signing-key-test.sh
set -uo pipefail
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
t() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/tools/setup-signing-key.sh

W=$(mktemp -d); export TMPDIR=$W/tmp; mkdir -p "$TMPDIR" "$W/bin" "$W/bw" "$W/gh"
trap 'gpgconf --kill gpg-agent 2>/dev/null; rm -r "$W"' EXIT
export FAKE_BW=$W/bw FAKE_GH=$W/gh

cat > "$W/bin/bw" <<'E'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status "*)       echo '{"status":"unlocked"}' ;;
  "generate "*)     head -c 4000 /dev/urandom | tr -dc A-Za-z0-9 | head -c 48; echo ;;
  "get template")   echo '{"type":1,"name":"","notes":"","fields":[],"secureNote":{"type":0},"login":{}}' ;;
  "encode "*)       cat ;;
  "create item")    id=$(( $(ls "$FAKE_BW" | wc -l) + 1 )); jq --arg id "$id" '.id=$id' > "$FAKE_BW/$id.json"; echo "{\"id\":\"$id\"}" ;;
  "sync "*)         : ;;
  "get item")       cat "$FAKE_BW/$3.json" ;;
  "list items")     if ls "$FAKE_BW"/*.json >/dev/null 2>&1; then jq -s . "$FAKE_BW"/*.json; else echo '[]'; fi ;;
  *) echo "fake bw: unsupported: $*" >&2; exit 2 ;;
esac
E
cat > "$W/bin/gh" <<'E'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "secret list") if [ -n "${FAKE_GH_DENY:-}" ]; then echo "failed to get secrets: HTTP 403" >&2; exit 1; fi; for f in "$FAKE_GH"/*; do [ -e "$f" ] && echo "$(basename "$f")	Updated"; done; true ;;
  "secret set")  cat > "$FAKE_GH/$3" ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 2 ;;
esac
E
chmod +x "$W/bin/bw" "$W/bin/gh"; export PATH=$W/bin:$PATH

secret_keys_before=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec' || true)

echo "== gh sem permissão para ler secrets: tem que PARAR antes de gerar qualquer coisa (bug real achado na 1ª execução do dono)"
out=$(FAKE_GH_DENY=1 bash "$SCRIPT" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'cannot read the secrets' <<<"$out" && ok "recusou com mensagem clara (rc=$rc)" || { bad "não parou (rc=$rc)"; echo "$out" | tail -3; }
grep -q 'generating the key' <<<"$out" && bad "gerou a chave mesmo sem poder checar os secrets" || ok "não chegou a gerar a chave"
[ -z "$(find "$FAKE_BW" "$FAKE_GH" -type f)" ] && ok "nada gravado" || bad "gravou algo"

echo "== --dry-run: gera e prova a chave, mas não grava em lugar nenhum"
out=$(bash "$SCRIPT" --dry-run 2>&1); rc=$?
[ $rc -eq 0 ] && ok "dry-run terminou com sucesso" || { bad "dry-run falhou (rc=$rc)"; echo "$out" | tail -5; }
grep -q 'fingerprint:' <<<"$out" && ok "mostra a impressão digital" || bad "sem impressão digital"
[ -z "$(find "$FAKE_BW" "$FAKE_GH" -type f)" ] && ok "nada gravado no Bitwarden nem no GitHub" || bad "dry-run gravou algo"

echo "== execução real"
out=$(bash "$SCRIPT" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "terminou com sucesso" || { bad "falhou (rc=$rc)"; echo "$out" | tail -8; }
fpr=$(grep -o 'fingerprint: *[0-9A-F]\{40\}' <<<"$out" | head -1 | awk '{print $2}')
[ ${#fpr} -eq 40 ] && ok "impressão digital impressa (40 caracteres)" || bad "impressão digital ausente"
[ "$(ls "$FAKE_BW" | wc -l)" = 2 ] && ok "2 itens no Bitwarden" || bad "itens no Bitwarden: $(ls "$FAKE_BW" | wc -l)"
[ -s "$FAKE_GH/GPG_PRIVATE_KEY" ] && [ -s "$FAKE_GH/GPG_PASSPHRASE" ] && ok "os 2 secrets foram criados" || bad "secrets ausentes"
t "itens com os nomes combinados" bash -c "jq -e -s 'map(.name)|sort==[\"rustdesk-drm GPG - revocation certificate\",\"rustdesk-drm GPG - signing key\"]' $W/bw/*.json"
t "nota da chave no Bitwarden == secret do GitHub" bash -c "jq -j 'select(.name|test(\"signing\"))|.notes' $W/bw/*.json | cmp - $W/gh/GPG_PRIVATE_KEY"
t "frase-senha no Bitwarden == secret do GitHub" bash -c "jq -j 'select(.name|test(\"signing\"))|.fields[]|select(.name==\"passphrase\")|.value' $W/bw/*.json | cmp - $W/gh/GPG_PASSPHRASE"
[ "$(wc -c < "$FAKE_GH/GPG_PASSPHRASE")" -eq 48 ] && ok "frase-senha sem quebra de linha (48 caracteres)" || bad "tamanho da frase-senha: $(wc -c < "$FAKE_GH/GPG_PASSPHRASE")"

echo "== o que o workflow fará com o secret: importar e assinar com a frase-senha"
export GNUPGHOME=$W/ci; install -d -m700 "$GNUPGHOME"
gpg --batch --quiet --import < "$FAKE_GH/GPG_PRIVATE_KEY" 2>/dev/null
echo hello > "$W/f"
t "assina com a chave do secret + frase-senha do secret" gpg --batch --yes --pinentry-mode loopback --passphrase-file "$FAKE_GH/GPG_PASSPHRASE" --local-user "$fpr" --detach-sign -o "$W/f.sig" "$W/f"
t "a assinatura confere" gpg --batch --verify "$W/f.sig" "$W/f"
echo "== certificado de revogação guardado: é utilizável?"
jq -j 'select(.name|test("revocation"))|.notes' "$W"/bw/*.json > "$W/rev.asc"
! grep -q '^:-----' "$W/rev.asc" && grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$W/rev.asc" && ok "sem o ':' de proteção antes do BEGIN" || bad "ainda com o ':'"
gpg --batch --import "$W/rev.asc" 2>&1 | grep -qi 'revocation certificate imported' && ok "importar o certificado revoga a chave" || bad "certificado não revogou"
unset GNUPGHOME

echo "== segunda execução recusa (não sobrescreve)"
snap=$(cd "$W" && sha256sum bw/* gh/* | sort)
out=$(bash "$SCRIPT" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'already exists' <<<"$out" && ok "recusou: $(grep -m1 'already exists' <<<"$out" | cut -c1-70)..." || bad "não recusou (rc=$rc)"
[ "$snap" = "$(cd "$W" && sha256sum bw/* gh/* | sort)" ] && ok "nada foi alterado" || bad "o estado mudou"

echo "== isolamento"
[ -z "$(ls -A "$TMPDIR")" ] && ok "nenhum arquivo temporário sobrou" || bad "sobrou em $TMPDIR: $(ls -A "$TMPDIR")"
after=$(gpg --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec' || true)
[ "$secret_keys_before" = "$after" ] && ok "seu chaveiro (~/.gnupg) não ganhou nenhuma chave secreta" || bad "chaveiro alterado ($secret_keys_before -> $after)"

echo "== resultado: $FAILS falha(s)"
exit "$FAILS"
