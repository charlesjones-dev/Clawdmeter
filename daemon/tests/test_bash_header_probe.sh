#!/bin/bash
# Regression test for the rate-limit-header fallback in claude-usage-daemon.sh's
# build_payload_for_token(): the usage endpoint is stubbed out, curl prints
# canned probe headers, and each payload must carry only the windows whose
# headers exist. Ultra accounts send 7d headers without 5h ones, and must not be
# mistaken for Enterprise (whose spending path keys off overage-utilization).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="$HERE/../claude-usage-daemon.sh"

eval "$(awk '$0 ~ "^build_payload_for_token\\(\\) \\{"{f=1} f{print} f&&/^\}/{exit}' "$DAEMON")"
type build_payload_for_token >/dev/null 2>&1 || { echo "FAIL: could not extract build_payload_for_token"; exit 1; }

# Stubs: no clock/chime/buttons/schedule fragments, usage endpoint down, and a
# curl that swallows its stdin config and prints $PROBE_HEADERS as the response.
read_clock_setting() { echo off; }
read_chime_setting() { echo off; }
button_fragment() { :; }
schedule_fragment() { :; }
fetch_usage_fragment() { return 1; }
curl() { cat >/dev/null; printf 'HTTP/2 200\r\n'; printf '%s\n' "$PROBE_HEADERS" | sed 's/$/\r/'; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1: want [$3] got [$2]"; fail=1; fi; }
get() { printf '%s' "$payload" | python3 -c "import sys,json; v=json.load(sys.stdin).get('$1'); print(v if v is not None else 'null')"; }

now=$(date +%s)

PROBE_HEADERS="anthropic-ratelimit-unified-5h-utilization: 0.42
anthropic-ratelimit-unified-5h-reset: $((now + 3600))
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-7d-utilization: 0.10
anthropic-ratelimit-unified-7d-reset: $((now + 86400))"
payload=$(build_payload_for_token "tok"); rc=$?
check "Pro/Max: exits 0"  "$rc" "0"
check "Pro/Max: s"        "$(get s)"    "42"
check "Pro/Max: sr"       "$(get sr)"   "60"
check "Pro/Max: w"        "$(get w)"    "10"
check "Pro/Max: wr"       "$(get wr)"   "1440"
check "Pro/Max: acct"     "$(get acct)" "pro"
check "Pro/Max: st"       "$(get st)"   "allowed"

PROBE_HEADERS="anthropic-ratelimit-unified-7d-utilization: 0.25
anthropic-ratelimit-unified-7d-reset: $((now + 86400))
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-overage-utilization: 0.9"
payload=$(build_payload_for_token "tok")
check "Ultra (7d only): acct stays pro" "$(get acct)" "pro"
check "Ultra (7d only): no s"           "$(get s)"    "null"
check "Ultra (7d only): no sr"          "$(get sr)"   "null"
check "Ultra (7d only): w"              "$(get w)"    "25"
check "Ultra (7d only): st falls back to the overall status" "$(get st)" "allowed"

PROBE_HEADERS="anthropic-ratelimit-unified-5h-utilization: 0.07
anthropic-ratelimit-unified-5h-reset: $((now + 600))"
payload=$(build_payload_for_token "tok")
check "5h only: s"    "$(get s)" "7"
check "5h only: no w" "$(get w)" "null"

# The Enterprise branch parses its period info with gawk's 3-argument match();
# the bash daemon targets Linux. Skip it where awk lacks that (macOS awk).
if awk 'BEGIN { match("a", /(a)/, m) }' >/dev/null 2>&1; then
    PROBE_HEADERS="anthropic-ratelimit-unified-overage-utilization: 0.37
anthropic-ratelimit-unified-overage-reset: $((now + 10 * 86400))
anthropic-ratelimit-unified-status: allowed"
    payload=$(build_payload_for_token "tok")
    check "Enterprise: acct"  "$(get acct)" "ent"
    check "Enterprise: s"     "$(get s)"    "37"
    check "Enterprise: no w"  "$(get w)"    "null"
    check "Enterprise: no wr" "$(get wr)"   "null"

    PROBE_HEADERS="anthropic-ratelimit-unified-status: allowed"
    payload=$(build_payload_for_token "tok")
    check "no window headers: no s" "$(get s)" "null"
    check "no window headers: ok"   "$(get ok)" "True"
else
    echo "SKIP: Enterprise header cases (awk has no 3-argument match(); needs gawk)"
fi

exit $fail
