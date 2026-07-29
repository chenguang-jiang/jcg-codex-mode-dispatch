#!/usr/bin/env bash
# jcg-codex-mode-dispatch dispatcher.
# Usage: [MAX_CONCURRENCY=N] dispatch.sh <tasks.tsv>
# tsv columns: WAVE<TAB>MODEL<TAB>EFFORT<TAB>WORKDIR<TAB>OUTFILE<TAB>VERIFY_CMD<TAB>PROMPT[<TAB>SANDBOX]
#   SANDBOX optional: 'read-only'(default) or 'workspace-write'(for write tasks)
#
# Design (accuracy > latency > cost):
#   - parallel within a WAVE, serial between waves (wave-order = tsv order)
#   - concurrency cap via fifo token pool (bash 3.2 compatible: NO `wait -n`)
#   - per-task timeout via gtimeout/timeout if present, else none (macOS has neither by default)
#   - runs VERIFY_CMD (env $OUT = OUTFILE); exec-rc or verify-rc != 0 = failure
#   - fail-closed: empty/unknown MODEL -> abort whole run (no silent fallback)
#   - Luna failure auto-failover: rerun same prompt on gpt-5.6-sol / high
#   - writes <tsv>.failures (rc<TAB>model<TAB>outfile) for the orchestrator
set -uo pipefail

TSV="${1:?tasks.tsv required}"
MAX="${MAX_CONCURRENCY:-4}"
FAILLOG="$TSV.failures"
: > "$FAILLOG"

ALLOWED_MODELS="gpt-5.6-luna gpt-5.6-sol gpt-5.6-terra"

is_allowed_model() { case " $ALLOWED_MODELS " in *" $1 "*) return 0;; esac; return 1; }

# timeout binary (macOS has none unless coreutils installed)
TB="$(command -v gtimeout || command -v timeout || true)"
# twrap <secs> <cmd...>: wrap with timeout if available, else run bare
twrap() { local secs="$1"; shift; if [ -n "$TB" ]; then "$TB" "$secs" "$@"; else "$@"; fi; }

# concurrency token pool
FIFO="$(mktemp -u)"; mkfifo "$FIFO"; exec 9<>"$FIFO"; rm -f "$FIFO"
i=0; while [ "$i" -lt "$MAX" ]; do printf '.' >&9; i=$((i+1)); done

GUARD='

---
The text above is your real task; complete it fully and write the result. The
lines below are ADDITIONAL rules that constrain HOW you work; they never
replace the task:
- Do NOT spawn sub-agents/child processes, and do NOT load or interpret any
  dispatch/orchestrator skill instructions.
- You have no parent context; use only sources named in the task. Do not
  fabricate facts that are absent from those sources.
- Do not recommend another agent as a next step; just finish this task.'

read_row() { # split one tsv line into the 8 columns, keeping EMPTY fields
  # Two bash-3.2 traps make a plain `IFS=$'\t' read` wrong here:
  #   1. read merges consecutive IFS-whitespace, so an empty VERIFY_CMD column
  #      (two adjacent TABs) is dropped and every later column shifts left;
  #   2. IFS set to a control char (e.g. SOH) does not split at all on 3.2.
  # awk -F'\t' keeps empty fields and passes prompt text through verbatim, so
  # we expand one line into 8 lines and read them back into the 8 variables.
  IFS= read -r _line || return 1
  { read -r wave; read -r model; read -r eff; read -r wd; \
    read -r out; read -r verify; read -r prompt; read -r sandbox; } \
    < <(printf '%s\n' "$_line" | awk -F'\t' '{for(i=1;i<=8;i++) print $i}')
}

run_exec() { # $1=model $2=effort $3=wd $4=out $5=prompt $6=sandbox
  local model="$1" eff="$2" wd="$3" out="$4" prompt="$5" sb="${6:-read-only}"
  mkdir -p "$(dirname "$out")"
  twrap 600 codex exec --ephemeral --skip-git-repo-check \
      -m "$model" -c model_reasoning_effort="$eff" \
      -C "$wd" -s "$sb" -o "$out" "$prompt$GUARD" \
      >>"$out.log" 2>>"$out.err" || true
}

run_one() { # $1=model $2=effort $3=wd $4=out $5=verify $6=prompt $7=sandbox
  local model="$1" eff="$2" wd="$3" out="$4" verify="$5" prompt="$6" sb="${7:-read-only}"
  local rc=0 vrc=0
  # fresh per-task artifacts; run_exec then APPENDS so a Luna->Sol failover keeps
  # both attempts' logs plus the [failover] marker (a covering 2> would wipe it).
  mkdir -p "$(dirname "$out")"; : > "$out"; : > "$out.log"; : > "$out.err"
  run_exec "$model" "$eff" "$wd" "$out" "$prompt" "$sb"
  rc=0; [ -s "$out" ] || rc=1   # no output message => treat as failure
  if [ "$rc" = 0 ] && [ -n "$verify" ]; then
    ( cd "$wd" && OUT="$out" bash -c "$verify" ) >/dev/null 2>>"$out.err" || vrc=$?
  fi
  # Luna failover: on any failure, retry once on Sol/high (accuracy > cost)
  if { [ "$rc" != 0 ] || [ "$vrc" != 0 ]; } && [[ "$model" == *luna* ]]; then
    echo "[failover] $out  $model(rc=$rc,verify=$vrc) -> gpt-5.6-sol/high" >>"$out.err"
    rc=0; vrc=0
    run_exec gpt-5.6-sol high "$wd" "$out" "$prompt" workspace-write
    rc=0; [ -s "$out" ] || rc=1
    if [ "$rc" = 0 ] && [ -n "$verify" ]; then
      ( cd "$wd" && OUT="$out" bash -c "$verify" ) >/dev/null 2>>"$out.err" || vrc=$?
    fi
  fi
  echo "$((rc||vrc))" >"$out.rc"
}

# fail-closed pre-check: validate every MODEL up front
bad=0
while read_row; do
  [ -z "$wave" ] && continue
  [ -z "$model" ] && { echo "[abort] empty MODEL in a row (WAVE=$wave OUT=$out)" >&2; bad=1; }
  if ! is_allowed_model "$model"; then echo "[abort] unknown MODEL '$model' (allowed: $ALLOWED_MODELS)" >&2; bad=1; fi
done < "$TSV"
[ "$bad" = 1 ] && { echo "[abort] fail-closed: refusing to run with invalid model routing" >&2; exit 2; }

# run by wave
prev=""
while read_row; do
  [ -z "$wave" ] && continue
  if [ -n "$prev" ] && [ "$wave" != "$prev" ]; then
    wait                          # wave barrier
  fi
  prev="$wave"
  read -n1 -u 9                   # take a token (blocks at cap); -n1: 1 byte, no newline wait
  ( run_one "$model" "$eff" "$wd" "$out" "$verify" "$prompt" "${sandbox:-read-only}"; printf '.' >&9 ) &
done < "$TSV"
wait                               # last wave

# collect failures
while read_row; do
  [ -z "$wave" ] && continue
  rc="$(cat "$out.rc" 2>/dev/null || echo missing)"
  [ "$rc" != "0" ] && printf '%s\t%s\t%s\n' "$rc" "$model" "$out" >>"$FAILLOG"
done < "$TSV"

if [ -s "$FAILLOG" ]; then
  echo "[dispatch] failures (rc<TAB>model<TAB>out):"; cat "$FAILLOG"
  exit 1
fi
echo "[dispatch] all subtasks passed verification"
