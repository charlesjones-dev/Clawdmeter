#!/bin/bash
# Check which usage rows the firmware builds for each payload shape, by running
# the desktop simulator headless (the full firmware loop, no window) and reading
# its "UI: usage rows rebuilt (n=N, mask 0xM)" log line. Mask bits: 1 = Current
# (5-hour session), 2 = Weekly (Period on Enterprise), 4 = model-scoped (Fable).
# A window missing from the payload must get no row; Ultra has no 5-hour window.
#
#   ./firmware/sim/test_usage_rows.sh          # uses an existing sim build
#   BUILD=1 ./firmware/sim/test_usage_rows.sh  # rebuilds it first (pio run -e sim)
#
# Needs the sim's SDL2 build (see SIM-USAGE.md). Builds made with LCD_WIDTH/
# LCD_HEIGHT overrides work too: the row logic doesn't depend on the size.
set -u

FW="$(cd "$(dirname "$0")/.." && pwd)"
PROGRAM="$FW/.pio/build/sim/program"
if [ "${BUILD:-0}" = "1" ] || [ ! -x "$PROGRAM" ]; then
    (cd "$FW" && ${PIO:-pio} run -e sim >/dev/null) || { echo "FAIL: sim build failed"; exit 1; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
# rows <label> <want "n=N, mask 0xM"> <payload JSON>
rows() {
    printf '{"name":"t","hold_ms":60000,%s\n' "${3#\{}" > "$TMP/s.jsonl"
    local got
    got=$(cd "$FW" && SDL_VIDEODRIVER=dummy SIM_AUTOSHOT_MS=1200 SIM_BOOT_SCREEN=usage \
          SIM_SCENARIO="$TMP/s.jsonl" SIM_AUTOSHOT_PATH="$TMP/shot.bmp" "$PROGRAM" 2>&1 \
          | sed -n 's/.*UI: usage rows rebuilt (\(.*\)).*/\1/p' | tail -1)
    if [ "$got" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1: want [$2] got [$got]"; fail=1; fi
}

rows "Pro/Max: Current + Weekly"           "n=2, mask 0x3" '{"s":42,"sr":180,"w":33,"wr":7900,"st":"allowed","ok":true}'
rows "Max with Fable: all three rows"      "n=3, mask 0x7" '{"s":4,"sr":180,"w":18,"wr":5900,"m":32,"mr":5900,"ml":"Fable","st":"allowed","ok":true}'
rows "Ultra: Weekly + Fable, no Current"   "n=2, mask 0x6" '{"w":22,"wr":4300,"m":41,"mr":4300,"ml":"Fable","st":"allowed","ok":true}'
rows "Ultra: Weekly only"                  "n=1, mask 0x2" '{"w":18,"wr":5900,"st":"allowed","ok":true}'
rows "Current only"                        "n=1, mask 0x1" '{"s":12,"sr":60,"st":"allowed","ok":true}'
rows "No windows: No limits"               "n=0, mask 0x0" '{"st":"allowed","acct":"pro","ok":true}'
rows "Enterprise: Spending + Period"       "n=2, mask 0x3" '{"s":37,"sr":-1,"acct":"ent","tp":40,"pd":30,"rd":"Aug 15","st":"allowed","ok":true}'
rows "Enterprise without spend: No limits" "n=0, mask 0x0" '{"acct":"ent","tp":40,"pd":30,"rd":"Aug 15","st":"allowed","ok":true}'
rows "Old Enterprise payload (w:0 kept)"   "n=2, mask 0x3" '{"s":37,"sr":-1,"w":0,"wr":0,"acct":"ent","tp":40,"pd":30,"rd":"Aug 15","ok":true}'
rows "{\"ok\":false} beat: no rebuild"     "n=2, mask 0x3" '{"ok":false}'

exit $fail
