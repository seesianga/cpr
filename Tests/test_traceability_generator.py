#!/usr/bin/env python3
"""Regression test for the generated Phase 3B traceability artefacts."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class TraceabilityGeneratorTests(unittest.TestCase):
    def test_generator_runs_with_zero_unmapped_items(self) -> None:
        completed = subprocess.run(
            [sys.executable, "Scripts/generate_traceability_matrix.py"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            completed.returncode,
            0,
            msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        self.assertIn("PASS: 698 mapped trace rows, 0 unmapped", completed.stdout)

        matrix = (ROOT / "Docs" / "COURSE_TRACEABILITY_MATRIX.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("Validation result: **PASS — 698 mapped items, 0 unmapped", matrix)


if __name__ == "__main__":
    unittest.main()
