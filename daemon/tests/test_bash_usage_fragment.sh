#!/bin/bash
# Regression test for the OAuth-usage parser embedded in claude-usage-daemon.sh.
# Feeds the shared fixture through $USAGE_PY and checks the emitted payload
# fragment carries the 5h/7d windows plus the model-scoped weekly row ("m"/"mr"/"ml"),
# and that an Enterprise-shaped body (no 5h window) exits non-zero so the daemon
# falls back to the rate-limit-header probe.
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

# Enterprise-shaped body: no 5h window -> non-zero exit, empty stdout.
ent=$(printf '{"five_hour":null,"seven_day":null,"limits":[]}' | python3 -c "$USAGE_PY" "$now"); rc=$?
check "parser exits 1 on Enterprise body" "$rc" "1"
check "parser prints nothing on Enterprise body" "$ent" ""

# Garbage body -> non-zero exit.
printf 'not json' | python3 -c "$USAGE_PY" "$now" >/dev/null 2>&1; rc=$?
check "parser exits 1 on non-JSON" "$rc" "1"

exit $fail
