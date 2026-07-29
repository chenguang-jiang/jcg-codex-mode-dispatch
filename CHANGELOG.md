# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
