#!/usr/bin/env bash
# Behavior tests for scripts/dispatch.sh — NO network, NO real model.
# A fake `codex` stub is injected via PATH so we exercise the dispatcher's own
# logic: fail-closed routing, per-subtask VERIFY, wave barrier, the fifo token
# pool concurrency cap, and Luna->Sol failover. Runs on macOS bash 3.2 and CI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
[ -x "$DISPATCH" ] || { echo "dispatch.sh not executable: $DISPATCH" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# ---- fake codex stub -------------------------------------------------------
# Recognises only -o OUT and -m MODEL (value flags); -c/-C/-s skip their value;
# other tokens form the prompt. Behavior:
#   * luna + prompt contains FAIL_LUNA  -> write EMPTY out (simulated failure)
#   * prompt contains SLEEP1            -> sleep 1 before writing
#   * prompt contains MARK2             -> record whether wave-1 outputs exist yet
#   * otherwise                         -> echo the prompt into OUT
cat > "$WORK/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; model=""; raw=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -m) model="$2"; shift 2;;
    -c|-C|-s) shift 2;;
    --*) shift;;
    *) raw+=("$1"); shift;;
  esac
done
# last positional arg = "<prompt><GUARD>"; strip the appended multi-line GUARD
# so keyword tests run on the single-line prompt body (bash * does not cross
# the newlines that the GUARD injects, which would otherwise miss the token).
last="${raw[${#raw[@]}-1]}"
body="${last%%$'\n\n---'*}"
if [[ "$model" == *luna* && "$body" == *FAIL_LUNA* ]]; then : > "$out"; exit 0; fi
if [[ "$body" == *SLEEP1* ]]; then sleep 1; fi
d="$(dirname "$out")"
if [[ "$body" == *MARK2* ]]; then
  if [ -f "$d/w1a.txt" ] && [ -f "$d/w1b.txt" ]; then echo "W1_DONE=yes $body" > "$out"
  else echo "W1_DONE=no $body" > "$out"; fi
else
  echo "$body" > "$out"
fi
exit 0
STUB
chmod +x "$WORK/bin/codex"
export PATH="$WORK/bin:$PATH"

now() { python3 -c 'import time;print(time.time())'; }

# ---- T1: fail-closed on empty model ---------------------------------------
echo "[T1] fail-closed: empty MODEL aborts (exit 2)"
d="$WORK/c1"; mkdir -p "$d"
printf '1\t\tlow\t%s\tx.txt\t\twhatever\n' "$d" > "$d/t.tsv"
( cd "$d" && MAX_CONCURRENCY=2 "$DISPATCH" ./t.tsv >/dev/null 2>&1 )
rc=$?
[ "$rc" = 2 ] && ok "exit=$rc" || bad "expected exit 2, got $rc"

# ---- T2: normal parallel + verify all pass --------------------------------
echo "[T2] 3 parallel luna tasks, verify passes, no failures"
d="$WORK/c2"; mkdir -p "$d"
for w in apple banana cherry; do
  printf '1\tgpt-5.6-luna\tlow\t%s\t%s.txt\tgrep -q %s "$OUT"\t%s\n' "$d" "$w" "$w" "$w" >> "$d/t.tsv"
done
( cd "$d" && MAX_CONCURRENCY=3 "$DISPATCH" ./t.tsv >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ ! -s "$d/t.tsv.failures" ]; then ok "exit 0, no failures"
else bad "rc=$rc failures=$(cat "$d/t.tsv.failures" 2>/dev/null)"; fi

# ---- T3: verify failure is collected (and triggers failover, still fails) --
echo "[T3] failing VERIFY is collected into <tsv>.failures (exit 1)"
d="$WORK/c3"; mkdir -p "$d"
printf '1\tgpt-5.6-luna\tlow\t%s\to.txt\tgrep -q ZZZZZ "$OUT"\tapple\n' "$d" > "$d/t.tsv"
( cd "$d" && MAX_CONCURRENCY=2 "$DISPATCH" ./t.tsv >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 1 ] && [ -s "$d/t.tsv.failures" ]; then ok "exit 1, failure recorded"
else bad "rc=$rc failures=$(cat "$d/t.tsv.failures" 2>/dev/null)"; fi

# ---- T4: Luna failure auto-failover to Sol succeeds -----------------------
echo "[T4] luna empty-output -> failover to sol -> verify passes"
d="$WORK/c4"; mkdir -p "$d"
printf '1\tgpt-5.6-luna\tlow\t%s\to.txt\tgrep -q please "$OUT"\tFAIL_LUNA please\n' "$d" > "$d/t.tsv"
( cd "$d" && MAX_CONCURRENCY=2 "$DISPATCH" ./t.tsv >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$d/o.txt" ] && grep -q '\[failover\]' "$d/o.txt.err" 2>/dev/null; then
  ok "failover fired and recovered"
else bad "rc=$rc out=$(cat "$d/o.txt" 2>/dev/null) err_has_failover=$(grep -c '\[failover\]' "$d/o.txt.err" 2>/dev/null)"; fi

# ---- T5: wave barrier orders wave2 after wave1 ----------------------------
echo "[T5] wave barrier: wave-2 sees wave-1 outputs already written"
d="$WORK/c5"; mkdir -p "$d"
printf '1\tgpt-5.6-luna\tlow\t%s\tw1a.txt\t\tSLEEP1 MARK1a\n' "$d" >  "$d/t.tsv"
printf '1\tgpt-5.6-luna\tlow\t%s\tw1b.txt\t\tSLEEP1 MARK1b\n' "$d" >> "$d/t.tsv"
printf '2\tgpt-5.6-sol\tlow\t%s\tw2.txt\t\tMARK2\n' "$d"          >> "$d/t.tsv"
( cd "$d" && MAX_CONCURRENCY=3 "$DISPATCH" ./t.tsv >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && grep -q 'W1_DONE=yes' "$d/w2.txt" 2>/dev/null; then ok "barrier held"
else bad "rc=$rc w2=$(cat "$d/w2.txt" 2>/dev/null)"; fi

# ---- T6: fifo token pool enforces the concurrency cap ---------------------
echo "[T6] concurrency cap: MAX=2 parallel is faster than MAX=1 serial"
d="$WORK/c6"; mkdir -p "$d"
printf '1\tgpt-5.6-luna\tlow\t%s\ta.txt\t\tSLEEP1 x\n' "$d" >  "$d/t.tsv"
printf '1\tgpt-5.6-luna\tlow\t%s\tb.txt\t\tSLEEP1 x\n' "$d" >> "$d/t.tsv"
t0=$(now); ( cd "$d" && MAX_CONCURRENCY=1 "$DISPATCH" ./t.tsv >/dev/null 2>&1 ); t1=$(now)
serial=$(python3 -c "print($t1-$t0)")
rm -f "$d/a.txt" "$d/b.txt" "$d"/*.rc
t0=$(now); ( cd "$d" && MAX_CONCURRENCY=2 "$DISPATCH" ./t.tsv >/dev/null 2>&1 ); t1=$(now)
parallel=$(python3 -c "print($t1-$t0)")
faster=$(python3 -c "print('yes' if ($serial-$parallel) > 0.4 else 'no')")
if [ "$faster" = yes ]; then ok "serial=${serial}s parallel=${parallel}s"
else bad "serial=${serial}s parallel=${parallel}s (cap not enforced?)"; fi

echo
echo "dispatch tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
