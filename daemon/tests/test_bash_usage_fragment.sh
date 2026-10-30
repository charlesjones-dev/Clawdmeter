#!/bin/bash
# Regression test for the OAuth-usage parser embedded in claude-usage-daemon.sh.
# Feeds the shared fixture through $USAGE_PY and checks the emitted payload
# fragment carries the 5h/7d windows plus the model-scoped weekly row ("m"/"mr"/"ml"),
# that a window the account lacks (Ultra has no 5h window) is left out rather
# than sent as 0%, and that an Enterprise-shaped body (no usage window at all)
# exits non-zero so the daemon falls back to the rate-limit-header probe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$HERE/../claude-usage-daemon.sh"
FIXTURE="$HERE/fixtures/oauth_usage_promax.json"

# Pull just the USAGE_PY heredoc assignment out of the daemon and eval it.
eval "$(awk '/^read -r -d .. USAGE_PY <<.PYEOF.$/{f=1} f{print} f&&/^PYEOF$/{exit}' "$DAEMON")"
[ -n "${USAGE_PY:-}" ] || { echo "FAIL: could not extract USAGE_PY"; exit 1; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — want [$3] got [$2]"; fail=1; fi; }

# Anchor "now" 180 min before the fixture's 5h reset so the minute arithmetic is
# deterministic; the weekly expectation is derived from the fixture the same way.
now=$(python3 -c 'import datetime as d; print(int(d.datetime(2026,9,20,7,40,tzinfo=d.timezone.utc).timestamp()) - 180*60)')
weekly_mins=$(python3 -c "import datetime as d; print(int(round((d.datetime(2026,9,24,5,0,tzinfo=d.timezone.utc).timestamp() - $now)/60)))")
frag=$(python3 -c "$USAGE_PY" "$now" < "$FIXTURE"); rc=$?
check "parser exits 0 on Pro/Max body" "$rc" "0"
check "fragment starts with the session % (poll() greps it)" "${frag:0:4}" '"s":'
get() { printf '{%s}' "$frag" | python3 -c "import sys,json; v=json.load(sys.stdin).get('$1'); print(v if v is not None else 'null')"; }
check "s"   "$(get s)"  "4"
check "sr"  "$(get sr)" "180"
check "w"   "$(get w)"  "18"
check "wr"  "$(get wr)" "$weekly_mins"
check "st"  "$(get st)" "allowed"
check "acct" "$(get acct)" "pro"
check "m (model-scoped weekly %)" "$(get m)"  "32"
check "ml (server label)"         "$(get ml)" "Fable"
check "mr (model-scoped reset)"   "$(get mr)" "$weekly_mins"

# Ultra-shaped body: no 5h window (null, and no "session" limits row). The
# fragment must leave "s"/"sr" out entirely so the device hides that bar.
ultra_body=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["five_hour"] = None
d["limits"] = [r for r in d["limits"] if r["kind"] != "session"]
print(json.dumps(d))' "$FIXTURE")
frag=$(printf '%s' "$ultra_body" | python3 -c "$USAGE_PY" "$now"); rc=$?
check "Ultra: parser exits 0 (not mistaken for Enterprise)" "$rc" "0"
check "Ultra: fragment starts with the weekly %" "${frag:0:4}" '"w":'
check "Ultra: no s"  "$(get s)"  "null"
check "Ultra: no sr" "$(get sr)" "null"
check "Ultra: w"     "$(get w)"  "18"
check "Ultra: m"     "$(get m)"  "32"
check "Ultra: st follows weekly" "$(get st)" "allowed"

# Each window is independent: a 5h window with a null utilization and a
# missing weekly window drop only their own keys.
frag=$(printf '{"five_hour":{"utilization":null},"seven_day":{"utilization":41,"resets_at":null},"limits":[]}' \
    | python3 -c "$USAGE_PY" "$now"); rc=$?
check "null 5h utilization: exits 0" "$rc" "0"
check "null 5h utilization: no s"    "$(get s)"  "null"
check "null 5h utilization: w"       "$(get w)"  "41"
check "null 5h utilization: wr 0"    "$(get wr)" "0"
check "null 5h utilization: no m"    "$(get m)"  "null"
frag=$(printf '{"five_hour":{"utilization":12,"resets_at":null},"limits":[]}' | python3 -c "$USAGE_PY" "$now")
check "missing weekly: s"    "$(get s)" "12"
check "missing weekly: no w" "$(get w)" "null"
frag=$(printf '{"five_hour":null,"seven_day":{"utilization":100},"limits":[]}' | python3 -c "$USAGE_PY" "$now")
check "Ultra at the weekly cap: rejected" "$(get st)" "rejected"

# Enterprise-shaped body: no usage window at all -> non-zero exit, empty stdout.
ent=$(printf '{"five_hour":null,"seven_day":null,"limits":[]}' | python3 -c "$USAGE_PY" "$now"); rc=$?
check "parser exits 1 on Enterprise body" "$rc" "1"
check "parser prints nothing on Enterprise body" "$ent" ""

# The plan selector's activity %: "s", or "w" on Ultra, then "m"; else 0.
eval "$(awk '$0 ~ "^_payload_activity_pct\\(\\) \\{"{f=1} f{print} f&&/^\}/{exit}' "$DAEMON")"
check "activity: session wins"     "$(_payload_activity_pct '{"s":7,"sr":1,"w":30,"m":50,"ok":true}')" "7"
check "activity: weekly without s" "$(_payload_activity_pct '{"w":30,"wr":9,"m":50,"ml":"Fable","ok":true}')" "30"
check "activity: scoped alone"     "$(_payload_activity_pct '{"m":50,"mr":9,"ml":"Fable","ok":true}')" "50"
check "activity: none -> 0"        "$(_payload_activity_pct '{"st":"allowed","ok":true}')" "0"

# Garbage body -> non-zero exit.
printf 'not json' | python3 -c "$USAGE_PY" "$now" >/dev/null 2>&1; rc=$?
check "parser exits 1 on non-JSON" "$rc" "1"

# fetch_usage_fragment must hand curl the token on stdin (-K -), never in argv,
# where any local user can read it via ps or /proc. A curl stub records both.
eval "$(awk '$0 ~ "^fetch_usage_fragment\\(\\) \\{"{f=1} f{print} f&&/^\}/{exit}' "$DAEMON")"
CURL_LOG="$(mktemp)"
curl() {   # %q keeps -w's embedded newline from splitting the ARGV line
    local a prev="" reads_stdin=false
    for a in "$@"; do [ "$prev" = "-K" ] && [ "$a" = "-" ] && reads_stdin=true; prev="$a"; done
    {   # like real curl, only read stdin when told to (-K -), so a regression can't hang
        printf 'ARGV:'; printf ' %q' "$@"; printf '\n'
        $reads_stdin && sed 's/^/STDIN:/'
    } > "$CURL_LOG"
    cat "$FIXTURE"; printf '\n200'
}
frag=$(fetch_usage_fragment "sk-ant-oat01-SECRET"); rc=$?
check "fetch: exits 0 on a 200"                  "$rc" "0"
check "fetch: fragment parsed from the body"     "${frag:0:4}" '"s":'
check "fetch: token absent from curl argv"       "$(grep -c '^ARGV:.*SECRET' "$CURL_LOG")" "0"
check "fetch: curl reads its config from stdin"  "$(grep -c '^ARGV:.* -K - ' "$CURL_LOG")" "1"
check "fetch: bearer header arrives on stdin" \
    "$(grep '^STDIN:' "$CURL_LOG")" 'STDIN:header = "Authorization: Bearer sk-ant-oat01-SECRET"'
rm -f "$CURL_LOG"; unset -f curl

exit $fail
