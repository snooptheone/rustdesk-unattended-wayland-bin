#!/usr/bin/env bash
# Tests rustdesk_default_options from rustdesk.install against temporary config files. Touches nothing outside
# its temp dir (RUSTDESK_ROOT_CONFIG points there). From the repo root: bash tests/options-default-test.sh
set -uo pipefail
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
INSTALL=$(cd "$(dirname "$0")/.." && pwd)/rustdesk.install
W=$(mktemp -d); trap 'rm -r "$W"' EXIT
export RUSTDESK_ROOT_CONFIG=$W/home/.config/rustdesk/RustDesk2.toml
# shellcheck disable=SC1090
source "$INSTALL"
KEY=enable-drm-display-wake
reset() { rm -rf "$W/home"; }
count() { grep -c -E "^[[:space:]]*$KEY[[:space:]]*=" "$RUSTDESK_ROOT_CONFIG"; }
val()   { sed -n -E "s/^[[:space:]]*$KEY[[:space:]]*=[[:space:]]*'(.*)'.*/\1/p" "$RUSTDESK_ROOT_CONFIG"; }

reset; rustdesk_default_options
[ "$(val)" = N ] && [ "$(count)" = 1 ] && ok "no file: created with the key set to N" || bad "no file: created with the key set to N"
[ "$(stat -c %a "$RUSTDESK_ROOT_CONFIG")" = 600 ] && ok "no file: mode 600" || bad "no file: mode 600"
head -1 "$RUSTDESK_ROOT_CONFIG" | grep -qx '\[options\]' && ok "no file: key is under [options]" || bad "no file: key is under [options]"

reset; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"
printf "id = 'abc'\nenc_id = 'x'\n" > "$RUSTDESK_ROOT_CONFIG"; rustdesk_default_options
[ "$(val)" = N ] && grep -q "^id = 'abc'" "$RUSTDESK_ROOT_CONFIG" && ok "no [options]: appended, other keys kept" || bad "no [options]: appended, other keys kept"

reset; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"
printf "id = 'abc'\n\n[options]\nfoo = 'bar'\n\n[other]\nz = '1'\n" > "$RUSTDESK_ROOT_CONFIG"; rustdesk_default_options
[ "$(val)" = N ] && grep -q "^foo = 'bar'" "$RUSTDESK_ROOT_CONFIG" && grep -q "^z = '1'" "$RUSTDESK_ROOT_CONFIG" \
  && awk '/^\[options\]/{o=1;next} /^\[/{o=0} o && /enable-drm-display-wake/{f=1} END{exit !f}' "$RUSTDESK_ROOT_CONFIG" \
  && ok "[options] without the key: added inside [options], rest kept" || bad "[options] without the key: added inside [options], rest kept"

reset; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"
printf "[options]\n%s = 'Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; rustdesk_default_options
[ "$(val)" = Y ] && [ "$(count)" = 1 ] && ok "admin set Y: left alone" || bad "admin set Y: left alone"

reset; rustdesk_default_options; before=$(cat "$RUSTDESK_ROOT_CONFIG"); rustdesk_default_options; rustdesk_default_options
[ "$(cat "$RUSTDESK_ROOT_CONFIG")" = "$before" ] && [ "$(count)" = 1 ] && ok "idempotent across reruns (upgrades)" || bad "idempotent across reruns (upgrades)"

reset; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"
printf "[options]   \nfoo = 'bar'\n" > "$RUSTDESK_ROOT_CONFIG"; rustdesk_default_options
[ "$(val)" = N ] && ok "[options] with trailing spaces: matched" || bad "[options] with trailing spaces: matched"

# End to end: what pacman runs on an upgrade (post_upgrade -> post_install) with stubbed system commands.
# The key must be written after the daemon is stopped and before it is started again.
LOG=$W/calls.log
systemctl() { printf 'systemctl %s | key-present=%s\n' "$*" "$([ -f "$RUSTDESK_ROOT_CONFIG" ] && grep -c "^$KEY" "$RUSTDESK_ROOT_CONFIG" || echo 0)" >> "$LOG"; }
update-desktop-database() { :; }
note() { :; }
reset; : > "$LOG"; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"
printf "id = 'abc'\n[options]\nfoo = 'bar'\n" > "$RUSTDESK_ROOT_CONFIG"     # an existing install, key absent
post_upgrade
[ "$(val)" = N ] && ok "upgrade, key absent: post_upgrade sets it to N" || bad "upgrade, key absent: post_upgrade sets it to N"
grep -q "stop rustdesk.service | key-present=0" "$LOG" && grep -q "restart rustdesk.service | key-present=1" "$LOG" \
  && ok "upgrade: key written after stop, before restart" || bad "upgrade: key written after stop, before restart"
reset; mkdir -p "$(dirname "$RUSTDESK_ROOT_CONFIG")"; printf "[options]\n%s = 'Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; post_upgrade
[ "$(val)" = Y ] && ok "upgrade, key already Y: kept" || bad "upgrade, key already Y: kept"

[ "$FAILS" = 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
