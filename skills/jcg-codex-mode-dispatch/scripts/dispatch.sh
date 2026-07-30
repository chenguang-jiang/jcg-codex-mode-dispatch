#!/usr/bin/env bash
# jcg-codex-mode-dispatch dispatcher.
# Usage: [ENV VARS] dispatch.sh <tasks.tsv>
#
# tsv columns (TAB-separated, 8 or 9):
#   WAVE  MODEL  EFFORT  WORKDIR  OUTFILE  VERIFY_CMD  PROMPT  [SANDBOX]  [DEPENDS_ON]
#   SANDBOX    optional: 'read-only'(default) | 'workspace-write'
#   DEPENDS_ON optional: comma-separated OUTFILE paths this task waits for (DAG mode)
#
# Environment variables:
#   MAX_CONCURRENCY       fifo token pool size (default 4)
#   SPECULATIVE_FAILOVER  1 = start Sol shadow N seconds after Luna (default 0)
#   SPECULATIVE_DELAY     seconds before shadow launch (default 30)
#   EXTRA_EXEC_FLAGS      extra flags appended to every `codex exec` call
#                         e.g. "--ignore-user-config --ignore-rules" to skip
#                         plugin/MCP loading (saves startup time; test first!)
#
# Design (accuracy > latency > cost):
#   - parallel within a WAVE, serial between waves (wave-order = tsv order)
#   - DAG deps (col 9): task bypasses wave barrier, polls for its own deps
#   - concurrency cap via fifo token pool (bash 3.2 compatible: NO `wait -n`)
#   - per-task timeout via gtimeout/timeout if present, else none
#   - runs VERIFY_CMD (env $OUT = OUTFILE); exec-rc or verify-rc != 0 = failure
#   - fail-closed: empty/unknown MODEL -> abort whole run (no silent fallback)
#   - Luna failure auto-failover: rerun same prompt on gpt-5.6-sol / high
#   - speculative failover: Luna + delayed Sol shadow in parallel (opt-in)
#   - writes <tsv>.failures (rc<TAB>model<TAB>outfile) for the orchestrator
set -uo pipefail

TSV="${1:?tasks.tsv required}"
MAX="${MAX_CONCURRENCY:-4}"
FAILLOG="$TSV.failures"
: > "$FAILLOG"

ALLOWED_MODELS="gpt-5.6-luna gpt-5.6-sol gpt-5.6-terra"
SPEC_FO="${SPECULATIVE_FAILOVER:-0}"
SPEC_DELAY="${SPECULATIVE_DELAY:-30}"
EXTRA_FLAGS="${EXTRA_EXEC_FLAGS:-}"

is_allowed_model() { case " $ALLOWED_MODELS " in *" $1 "*) return 0;; esac; return 1; }

# timeout binary (macOS has none unless coreutils installed)
TB="$(command -v gtimeout || command -v timeout || true)"
twrap() { local secs="$1"; shift; if [ -n "$TB" ]; then "$TB" "$secs" "$@"; else "$@"; fi; }

# concurrency token pool
FIFO="$(mktemp -u)"; mkfifo "$FIFO"; exec 9<>"$FIFO"; rm -f "$FIFO"
i=0; while [ "$i" -lt "$MAX" ]; do printf '.' >&9; i=$((i+1)); done

# --- slim GUARD: 3 high-impact rules, ~80 words ----------------------------
GUARD='

---
ADDITIONAL RULES (do NOT replace the task above):
1. Use ONLY sources named in the task. Do not fabricate facts absent from them.
2. Do NOT spawn sub-agents or load/interpret dispatch/skill instructions.
3. If you cannot finish, write what you have and explain the gap — never pad.'

# --- read_row: split tsv into 9 columns (awk keeps empty fields) -----------
read_row() {
  IFS= read -r _line || return 1
  { read -r wave; read -r model; read -r eff; read -r wd; \
    read -r out; read -r verify; read -r prompt; read -r sandbox; read -r depends; } \
    < <(printf '%s\n' "$_line" | awk -F'\t' '{for(i=1;i<=9;i++) print $i}')
}

# --- wait_deps: poll until all comma-separated files exist -----------------
wait_deps() { # $1=comma-separated file paths
  local IFS=','
  for dep in $1; do
    while [ ! -f "$dep" ]; do sleep 0.5; done
  done
}

# --- run_exec: one codex exec invocation -----------------------------------
run_exec() { # $1=model $2=effort $3=wd $4=out $5=prompt $6=sandbox
  local model="$1" eff="$2" wd="$3" out="$4" prompt="$5" sb="${6:-read-only}"
  mkdir -p "$(dirname "$out")"
  # shellcheck disable=SC2086
  twrap 600 codex exec --ephemeral --skip-git-repo-check \
      -m "$model" -c model_reasoning_effort="$eff" \
      -C "$wd" -s "$sb" -o "$out" $EXTRA_FLAGS "$prompt$GUARD" \
      >>"$out.log" 2>>"$out.err" || true
}

# --- run_one: exec + verify + failover (+ optional speculative) ------------
run_one() { # $1=model $2=eff $3=wd $4=out $5=verify $6=prompt $7=sandbox
  local model="$1" eff="$2" wd="$3" out="$4" verify="$5" prompt="$6" sb="${7:-read-only}"
  local rc=0 vrc=0 shadow_pid=""
  mkdir -p "$(dirname "$out")"; : > "$out"; : > "$out.log"; : > "$out.err"

  # speculative failover: launch Sol shadow after delay (opt-in, Luna only)
  if [ "$SPEC_FO" = 1 ] && [[ "$model" == *luna* ]]; then
    ( sleep "$SPEC_DELAY" && run_exec gpt-5.6-sol high "$wd" "$out.spec" "$prompt" workspace-write ) &
    shadow_pid=$!
  fi

  run_exec "$model" "$eff" "$wd" "$out" "$prompt" "$sb"
  rc=0; [ -s "$out" ] || rc=1
  if [ "$rc" = 0 ] && [ -n "$verify" ]; then
    ( cd "$wd" && OUT="$out" bash -c "$verify" ) >/dev/null 2>>"$out.err" || vrc=$?
  fi

  if [ "$rc" = 0 ] && [ "$vrc" = 0 ]; then
    # success — kill speculative shadow if running
    [ -n "$shadow_pid" ] && kill "$shadow_pid" 2>/dev/null
  else
    # failure path
    if [ -n "$shadow_pid" ]; then
      # speculative shadow already running — wait for it instead of serial failover
      echo "[spec-failover] $out  waiting for Sol shadow (pid=$shadow_pid)" >>"$out.err"
      wait "$shadow_pid" 2>/dev/null
      if [ -s "$out.spec" ]; then
        cp "$out.spec" "$out"
        rc=0; vrc=0
        if [ -n "$verify" ]; then
          ( cd "$wd" && OUT="$out" bash -c "$verify" ) >/dev/null 2>>"$out.err" || vrc=$?
        fi
      else
        rc=1
      fi
      rm -f "$out.spec"
    elif [[ "$model" == *luna* ]]; then
      # serial failover (default)
      echo "[failover] $out  $model(rc=$rc,verify=$vrc) -> gpt-5.6-sol/high" >>"$out.err"
      rc=0; vrc=0
      run_exec gpt-5.6-sol high "$wd" "$out" "$prompt" workspace-write
      rc=0; [ -s "$out" ] || rc=1
      if [ "$rc" = 0 ] && [ -n "$verify" ]; then
        ( cd "$wd" && OUT="$out" bash -c "$verify" ) >/dev/null 2>>"$out.err" || vrc=$?
      fi
    fi
  fi
  rm -f "$out.spec"
  echo "$((rc||vrc))" >"$out.rc"
}

# === fail-closed pre-check =================================================
bad=0
while read_row; do
  [ -z "$wave" ] && continue
  [ -z "$model" ] && { echo "[abort] empty MODEL in a row (WAVE=$wave OUT=$out)" >&2; bad=1; }
  if ! is_allowed_model "$model"; then echo "[abort] unknown MODEL '$model' (allowed: $ALLOWED_MODELS)" >&2; bad=1; fi
done < "$TSV"
[ "$bad" = 1 ] && { echo "[abort] fail-closed: refusing to run with invalid model routing" >&2; exit 2; }

# === run by wave + DAG deps ================================================
prev=""
wave_pids=""
dag_pids=""
while read_row; do
  [ -z "$wave" ] && continue

  if [ -n "$depends" ]; then
    # DAG task: bypass wave barrier, poll for own deps
    read -n1 -u 9
    ( wait_deps "$depends"; run_one "$model" "$eff" "$wd" "$out" "$verify" "$prompt" "${sandbox:-read-only}"; printf '.' >&9 ) &
    dag_pids="$dag_pids $!"
  else
    # wave task: barrier on wave transition (wait only wave PIDs, not DAG PIDs)
    if [ -n "$prev" ] && [ "$wave" != "$prev" ]; then
      [ -n "$wave_pids" ] && wait $wave_pids 2>/dev/null
      wave_pids=""
    fi
    prev="$wave"
    read -n1 -u 9
    ( run_one "$model" "$eff" "$wd" "$out" "$verify" "$prompt" "${sandbox:-read-only}"; printf '.' >&9 ) &
    wave_pids="$wave_pids $!"
  fi
done < "$TSV"
# final wait: both wave and DAG tasks
[ -n "$wave_pids" ] && wait $wave_pids 2>/dev/null
[ -n "$dag_pids" ]  && wait $dag_pids  2>/dev/null

# === collect failures =======================================================
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
