# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Batch exec rule** (SKILL.md): merge 2–4 light independent subtasks (<15s each) into a single `codex exec` call, paying the startup tax only once. Cuts light-task scenarios by 40–70%.
- **DAG dependency scheduling** (`DEPENDS_ON`, tsv column 9): tasks with declared file dependencies bypass the wave barrier and start as soon as their deps appear, eliminating bucket-effect waits on unrelated slow tasks.
- **Speculative failover** (`SPECULATIVE_FAILOVER=1`, opt-in): launches a delayed Sol shadow in parallel with Luna; if Luna fails, the shadow is already running — total latency ≈ max(Luna, delay+Sol) instead of Luna+Sol.
- **`EXTRA_EXEC_FLAGS`** env var: append arbitrary flags (e.g. `--ignore-user-config --ignore-rules`) to every `codex exec` call, letting users skip plugin/MCP loading to reduce startup time.

### Changed
- **Slim GUARD**: reduced from ~150 words to 3 high-impact rules (~80 words), lowering attention dilution and indirectly reducing failover trigger rate.
- `wait_deps` poll interval reduced from 2s to 0.5s for tighter DAG scheduling.
- `dispatch.sh` now reads 9 tsv columns (was 8); column 9 `DEPENDS_ON` is optional.
- Behavior tests expanded from 6 to 8 cases (added DAG deps T7, speculative failover T8).
- Contract tests expanded from 13 to 14 (added `test_perf_optimizations_documented`).

## [0.1.0] - 2026-07-29

### Added
- `jcg-codex-mode-dispatch` Codex Skill: parallel multi-model dispatch via shell-nested `codex exec`.
- `scripts/dispatch.sh`: wave-parallel dispatcher with a fifo token pool (macOS bash 3.2 compatible), per-subtask machine verification, Luna→Sol automatic failover, fail-closed model routing, and an injected behavioral GUARD.
- Routing model: `gpt-5.6-luna` for machine-verifiable work, `gpt-5.6-sol` for everything else and final synthesis, `gpt-5.6-terra` optional.
- Hard **startup gate** (~35–45s per-exec startup tax) and a pre-dispatch three-question self-check, so small tasks stay in the main thread.
- Dispatch contract (seven fields), fresh-context review discipline, partial verdicts, dual-run cross-validation.
- Contract tests (`tests/test_skill_contract.py`) and dispatch behavior tests (`tests/test_dispatch.sh`).
- GitHub Actions CI (`.github/workflows/test.yml`).
- Bilingual README (English / 简体中文) with a mermaid flow and an SVG banner.

### Verified
- End-to-end on Codex CLI 0.146: 3×Luna parallel + Sol reduce, all checks pass, `exit 0`.
- Fail-closed aborts on empty/illegal model (`exit 2`).
- Fifo token pool enforces the concurrency cap and the wave barrier orders waves.
