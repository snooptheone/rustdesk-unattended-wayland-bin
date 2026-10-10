#!/usr/bin/env bash
# Tests rustdesk_default_options and post_upgrade from rustdesk.install against temporary config files, with
# systemctl and friends stubbed. Touches nothing outside its temp dir (RUSTDESK_ROOT_CONFIG points there).
# From the repo root: bash tests/options-default-test.sh
set -uo pipefail
FAILS=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
t()   { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
INSTALL=$(cd "$(dirname "$0")/.." && pwd)/rustdesk.install
W=$(mktemp -d); trap 'rm -r "$W"' EXIT
export RUSTDESK_ROOT_CONFIG=$W/home/.config/rustdesk/RustDesk2.toml
# shellcheck disable=SC1090
source "$INSTALL"
KEY=enable-drm-display-wake
CFGDIR=$(dirname "$RUSTDESK_ROOT_CONFIG")
reset() { rm -rf "$W/home"; mkdir -p "$CFGDIR"; }
count() { grep -c -E "^[[:space:]]*$KEY[[:space:]]*=" "$RUSTDESK_ROOT_CONFIG"; }
val()   { sed -n -E "s/^[[:space:]]*$KEY[[:space:]]*=[[:space:]]*'(.*)'.*/\1/p" "$RUSTDESK_ROOT_CONFIG" | head -1; }
backups() { ls "$CFGDIR" | grep -c '^RustDesk2.toml.bak\.' ; }
# value of the key inside [options] only
in_options() { awk '/^[[:space:]]*\[/{o = ($0 ~ /^[[:space:]]*\[options\][[:space:]]*$/)} o && /^[[:space:]]*enable-drm-display-wake[[:space:]]*=/{print; exit}' "$RUSTDESK_ROOT_CONFIG"; }
run_opt() { rustdesk_default_options; RC=$?; }
absent() { ! grep -q "$@"; }

# --- no file
reset; rm -rf "$CFGDIR"; run_opt
t "no file: created, returns 0" [ "$RC" = 0 ]
t "no file: key N, once" [ "$(val)" = N ] && [ "$(count)" = 1 ]
t "no file: mode 600" [ "$(stat -c %a "$RUSTDESK_ROOT_CONFIG")" = 600 ]
t "no file: key is under [options]" [ "$(head -1 "$RUSTDESK_ROOT_CONFIG")" = '[options]' ]
t "no file: no backup (nothing to back up)" [ "$(backups)" = 0 ]

# --- file without [options]
reset; printf "id = 'abc'\nenc_id = 'x'\n" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "no [options]: returns 0" [ "$RC" = 0 ]
t "no [options]: appended, other keys kept" [ "$(val)" = N ] && grep -q "^id = 'abc'" "$RUSTDESK_ROOT_CONFIG"
t "no [options]: backup holds the original" [ "$(backups)" = 1 ] && grep -qx "id = 'abc'" "$CFGDIR"/RustDesk2.toml.bak.* && ! grep -q "$KEY" "$CFGDIR"/RustDesk2.toml.bak.*

# --- [options] without the key
reset; printf "id = 'abc'\n\n[options]\nfoo = 'bar'\n\n[other]\nz = '1'\n" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "[options] without key: returns 0" [ "$RC" = 0 ]
t "[options] without key: added inside [options], rest kept" \
  [ "$(in_options)" = "$KEY = 'N'" ] && grep -q "^foo = 'bar'" "$RUSTDESK_ROOT_CONFIG" && grep -q "^z = '1'" "$RUSTDESK_ROOT_CONFIG"
t "[options] without key: one backup" [ "$(backups)" = 1 ]

# --- [options] with trailing spaces
reset; printf "[options]   \nfoo = 'bar'\n" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "[options] with trailing spaces: matched" [ "$(in_options)" = "$KEY = 'N'" ]

# --- key already there: left alone, no backup
reset; printf "[options]\n%s = 'Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "admin set Y: returns 10, left alone" [ "$RC" = 10 ] && [ "$(val)" = Y ] && [ "$(count)" = 1 ]
t "admin set Y: no backup" [ "$(backups)" = 0 ]
reset; printf "[options]\n  %s='Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "key with odd spacing: still recognised" [ "$RC" = 10 ]

# --- the same key in another table does not count
reset; printf "[other]\n%s = 'Y'\n\n[options]\nfoo = 'bar'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "key only in another table: [options] still gets N" [ "$RC" = 0 ] && [ "$(in_options)" = "$KEY = 'N'" ]
reset; printf "[other]\n%s = 'Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; run_opt
t "key only in another table, no [options]: [options] created with N" [ "$RC" = 0 ] && [ "$(in_options)" = "$KEY = 'N'" ]

# --- idempotent
reset; run_opt; before=$(cat "$RUSTDESK_ROOT_CONFIG"); run_opt; first=$RC; run_opt
t "idempotent across reruns (upgrades)" [ "$first" = 10 ] && [ "$(cat "$RUSTDESK_ROOT_CONFIG")" = "$before" ] && [ "$(count)" = 1 ] && [ "$(backups)" = 0 ]

# --- unwritable location is reported, not silent
reset; chmod 500 "$CFGDIR"; rm -f "$RUSTDESK_ROOT_CONFIG"
if [ "$(id -u)" != 0 ]; then run_opt 2>/dev/null; t "unwritable config dir: returns 1" [ "$RC" = 1 ]; else ok "unwritable config dir: skipped (running as root)"; fi
chmod 700 "$CFGDIR"

# --- what pacman runs on an upgrade (post_upgrade -> post_install), with stubbed system commands
LOG=$W/calls.log; NOTES=$W/notes.log
systemctl() { printf 'systemctl %s | key-present=%s\n' "$*" "$([ -f "$RUSTDESK_ROOT_CONFIG" ] && grep -c "^$KEY" "$RUSTDESK_ROOT_CONFIG" || echo 0)" >> "$LOG"; }
update-desktop-database() { :; }
note() { printf '%s\n' "$1" >> "$NOTES"; }

reset; : > "$LOG"; : > "$NOTES"; printf "id = 'abc'\n[options]\nfoo = 'bar'\n" > "$RUSTDESK_ROOT_CONFIG"
post_upgrade
t "upgrade, key absent: post_upgrade sets it to N" [ "$(val)" = N ]
t "upgrade: key written after stop, before restart" \
  grep -q "stop rustdesk.service | key-present=0" "$LOG" && grep -q "restart rustdesk.service | key-present=1" "$LOG"
t "upgrade, key absent: the note says it was set" grep -q "was not set: it is now N" "$NOTES"

reset; : > "$NOTES"; printf "[options]\n%s = 'Y'\n" "$KEY" > "$RUSTDESK_ROOT_CONFIG"; post_upgrade
t "upgrade, key already Y: kept" [ "$(val)" = Y ]
t "upgrade, key already Y: no misleading 'defaults to N' note" absent "enable-drm-display-wake" "$NOTES"

[ "$FAILS" = 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
