#!/usr/bin/env python3
"""Skill contract tests for jcg-codex-mode-dispatch.

Asserts SKILL.md contains the non-negotiable design contracts so the skill
cannot silently drift away from: accuracy>latency>cost priority, the routing
table, the dispatch contract (borrowed from codex-team-mode), fail-closed gate,
fresh-context review discipline, dual-run/failover, and the GUARD.
Run: python3 tests/test_skill_contract.py
"""
from __future__ import annotations
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]  # repo root; the skill lives under skills/<name>/
SKILL = (ROOT / "SKILL.md").read_text(encoding="utf-8")


class JcgCodexModeDispatchContractTests(unittest.TestCase):
    def test_frontmatter(self) -> None:
        self.assertIn("name: jcg-codex-mode-dispatch", SKILL)
        self.assertIn("disable-model-invocation: true", SKILL)
        self.assertIn("metadata:", SKILL)

    def test_priority_order(self) -> None:
        self.assertIn("accuracy > latency > cost", SKILL)

    def test_routing_models(self) -> None:
        self.assertIn("gpt-5.6-luna", SKILL)
        self.assertIn("gpt-5.6-sol", SKILL)
        self.assertIn("gpt-5.6-terra", SKILL)

    def test_dispatch_contract_seven_fields(self) -> None:
        for label in ("Outcome", "Benefit", "Sources", "Scope", "Checks", "Stop when", "Return"):
            with self.subTest(label=label):
                self.assertIn(f"`{label}`", SKILL)

    def test_fail_closed_gate(self) -> None:
        self.assertIn("Dispatch Gate", SKILL)
        self.assertIn("失败关闭", SKILL)
        self.assertIn("不 fallback", SKILL)

    def test_accuracy_features(self) -> None:
        self.assertIn("失败升档", SKILL)
        self.assertIn("双跑", SKILL)
        self.assertIn("effort 地板", SKILL)

    def test_borrowed_disciplines(self) -> None:
        self.assertIn("partial verdict", SKILL)
        self.assertIn("Reviewer 独立性", SKILL)
        self.assertIn("smallest-useful-set", SKILL)
        self.assertIn("不可替换目标", SKILL)

    def test_startup_gate_documented(self) -> None:
        # 防止把单任务/少量任务误路由到 exec(每个 exec ~37s 启动税)
        self.assertIn("启动门槛", SKILL)
        self.assertIn("35-45", SKILL)        # 实测启动税范围
        self.assertIn("< 3", SKILL)           # 子任务<3 禁用
        self.assertIn("三问全 yes", SKILL)   # 派发前自检
        self.assertIn("直接主线程做", SKILL) # 不满足就主线程做

    def test_codex_compliance_and_guard(self) -> None:
        self.assertIn("绝不", SKILL)  # never delegate reading skill to subagent
        self.assertIn("GUARD", SKILL)
        self.assertIn("fork_turns", SKILL)

    def test_switches_documented(self) -> None:
        self.assertIn("disable-model-invocation: true", SKILL)
        self.assertIn("--no-skills", SKILL)
        self.assertIn(".disabled", SKILL)

    def test_readme_bilingual_and_no_placeholder(self) -> None:
        en = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
        zh = (REPO_ROOT / "README.zh-CN.md").read_text(encoding="utf-8")
        for doc in (en, zh):
            self.assertIn("chenguang-jiang", doc)                 # owner filled in
            self.assertNotIn("<your-github-username>", doc)      # no leaked placeholder
            self.assertIn("```mermaid", doc)                     # architecture diagram
            self.assertIn("MIT", doc)
        self.assertIn("README.zh-CN.md", en)                     # language switch (en->zh)
        self.assertIn("README.md", zh)                           # language switch (zh->en)
        self.assertIn("简体中文", en)
        self.assertIn("English", zh)

    def test_dispatch_script_exists_and_executable(self) -> None:
        script = ROOT / "scripts" / "dispatch.sh"
        self.assertTrue(script.is_file(), "scripts/dispatch.sh missing")
        self.assertTrue(script.stat().st_mode & 0o111, "scripts/dispatch.sh not executable")
        behavior = ROOT / "tests" / "test_dispatch.sh"
        self.assertTrue(behavior.is_file(), "tests/test_dispatch.sh missing")
        self.assertTrue(behavior.stat().st_mode & 0o111, "tests/test_dispatch.sh not executable")

    def test_repo_root_assets(self) -> None:
        # professional open-source layout at the repo root
        license_ = (REPO_ROOT / "LICENSE").read_text(encoding="utf-8")
        self.assertIn("MIT License", license_)
        self.assertIn("chenguang-jiang", license_)
        self.assertTrue((REPO_ROOT / ".gitignore").is_file())
        self.assertTrue((REPO_ROOT / "CHANGELOG.md").is_file())
        ci = (REPO_ROOT / ".github" / "workflows" / "test.yml").read_text(encoding="utf-8")
        self.assertIn("test_skill_contract.py", ci)
        self.assertIn("test_dispatch.sh", ci)
        banner = (REPO_ROOT / "assets" / "readme" / "banner.svg").read_text(encoding="utf-8")
        self.assertIn("<svg", banner)
        self.assertIn("dispatch.sh", banner)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2, exit=False))
