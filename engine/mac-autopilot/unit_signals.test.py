#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roi_rollup
from unit_signals import unit_signals

SHA = "a" * 40
OTHER = "b" * 40
PROMPT_A = "a" * 64
PROMPT_B = "b" * 64


def stages(*names):
    return {"id": "issue-1", "stage": "ready-to-merge", "history": [{"stage": name} for name in names]}


class UnitSignalsTests(unittest.TestCase):
    def test_disproved_findings_are_grouped_by_review_prompt_version(self):
        unit = stages("review-approve")
        unit["review_findings"] = [{
            "prompt": "engine/prompts/review-contract.md",
            "prompt_version": PROMPT_A,
            "disposition_block": "ok",
            "dispositions": [
                {"id": "F1", "disposition": "disproved"},
                {"id": "F2", "disposition": "fixed"},
            ],
        }, {
            "prompt": "engine/prompts/review-contract.md",
            "prompt_version": PROMPT_B,
            "disposition_block": "ok",
            "dispositions": [{"id": "F3", "disposition": "intentional"}],
        }]
        out = unit_signals(unit, {})
        self.assertIsNone(out["prompt"])
        self.assertEqual(out["disproved_findings"], [
            {"prompt": "engine/prompts/review-contract.md", "prompt_version": PROMPT_A, "disproved": 1, "total": 2},
            {"prompt": "engine/prompts/review-contract.md", "prompt_version": PROMPT_B, "disproved": 0, "total": 1},
        ])
        self.assertNotIn("disproved_share", out["signals"])

    def test_incomplete_dispositions_are_excluded(self):
        unit = stages("review-approve")
        unit["review_findings"] = [{
            "prompt": "engine/prompts/review-contract.md",
            "prompt_version": PROMPT_A,
            "disposition_block": "incomplete",
            "dispositions": [{"id": "F1", "disposition": "fixed"}],
        }]
        out = unit_signals(unit, {})
        self.assertEqual(out["disproved_findings"], [])

    def test_disproved_findings_without_prompt_version_are_unknown(self):
        unit = stages("review-approve")
        unit["review_findings"] = [{
            "prompt": "engine/prompts/review-contract.md",
            "disposition_block": "ok",
            "dispositions": [{"id": "F1", "disposition": "disproved"}],
        }]
        self.assertEqual(unit_signals(unit, {})["disproved_findings"], [])

    def test_overturned_review_after_supervisor_approve(self):
        unit = stages("review-request-changes", "supervisor-approve")
        self.assertIs(unit_signals(unit, {})["signals"]["overturned"], True)

    def test_approve_without_block_is_not_an_overturn(self):
        unit = stages("review-approve", "supervisor-approve")
        self.assertIs(unit_signals(unit, {})["signals"]["overturned"], False)

    def test_repair_and_rereview_rounds(self):
        unit = stages("review-request-changes", "repair-delivered", "review-approve")
        signals = unit_signals(unit, {})["signals"]
        self.assertIs(signals["repair"], True)
        self.assertIs(signals["rereview"], True)

    def test_review_without_repair_has_no_rereview(self):
        out = unit_signals(stages("review-approve"), {})
        self.assertIsNone(out["prompt"])
        signals = out["signals"]
        self.assertIs(signals["repair"], False)
        self.assertIs(signals["rereview"], False)

    def test_reverted_merge_from_git_map(self):
        unit = {"id": "issue-2", "stage": "merged", "history": [], "merge_sha": SHA}
        self.assertIs(unit_signals(unit, {SHA: None})["signals"]["reverted"], True)
        self.assertIs(unit_signals(unit, {OTHER: None})["signals"]["reverted"], False)

    def test_reverted_stage_marks_true_without_git(self):
        unit = stages("merged", "merge-reverted")
        self.assertIs(unit_signals(unit, None)["signals"]["reverted"], True)

    def test_missing_evidence_is_null_and_other_signals_stay_filled(self):
        unit = {"id": "issue-3", "stage": "implement", "merge_sha": SHA, "prompt": "fixture-prompt"}
        out = unit_signals(unit, None)
        self.assertEqual(out["prompt"], "fixture-prompt")
        self.assertEqual(out["signals"], {"overturned": None, "repair": None, "rereview": None, "reverted": None})
        self.assertEqual(out["disproved_findings"], [])
        out = unit_signals({"id": "issue-4", "stage": "merged", "history": [], "merge_sha": SHA}, {OTHER: None})
        self.assertEqual(out["signals"], {"overturned": None, "repair": None, "rereview": None, "reverted": False})
        self.assertEqual(out["disproved_findings"], [])

    def test_no_sha_leaves_reverted_null(self):
        self.assertIsNone(unit_signals(stages("review-approve"), {})["signals"]["reverted"])

    def test_reverted_shas_reads_git_and_is_none_outside_git(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(roi_rollup._reverted_shas(root))
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
            git = ["git", "-C", root]
            subprocess.run(git + ["init", "-q"], check=True, env=env)
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "base"], check=True, env=env)
            base = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True, check=True, env=env).stdout.strip()
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", f"Revert\n\nThis reverts commit {base}."], check=True, env=env)
            self.assertIn(base, roi_rollup._reverted_shas(root))


if __name__ == "__main__":
    unittest.main()
