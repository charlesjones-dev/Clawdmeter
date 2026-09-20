#!/bin/bash
# Regression test for the side-button key parser embedded in claude-usage-daemon.sh
# ($KEYMAP_PY). Must agree with the Python daemons' parse_key_spec table.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$HERE/../claude-usage-daemon.sh"
eval "$(awk '/^read -r -d .. KEYMAP_PY <<.PYEOF.$/{f=1} f{print} f&&/^PYEOF$/{exit}' "$DAEMON")"
[ -n "${KEYMAP_PY:-}" ] || { echo "FAIL: could not extract KEYMAP_PY"; exit 1; }

fail=0
ok()  { got=$(python3 -c "$KEYMAP_PY" "$1" 2>/dev/null); rc=$?
        if [ $rc -eq 0 ] && [ "$got" = "$2" ]; then echo "PASS: $1 -> $2"; else echo "FAIL: $1 -> want [$2] got [$got] rc=$rc"; fail=1; fi; }
bad() { if python3 -c "$KEYMAP_PY" "$1" >/dev/null 2>&1; then echo "FAIL: $1 accepted"; fail=1; else echo "PASS: $1 rejected"; fi; }

ok "space" "44,0"
ok "shift+tab" "43,2"
ok "Shift + Tab" "43,2"
ok "enter" "40,0"
ok "ctrl+shift+p" "19,3"
ok "cmd+k" "14,8"
ok "f12" "69,0"
ok "0" "39,0"
ok "shift" "0,2"
ok "none" "0,0"
bad "bogus"
bad "tab+ctrl"
bad "ctrl+"
bad ""
exit $fail
