"""Run with PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_ai_calc_cells.py.

tests/CalcCellCases.js classifies table-cell text for editable calc data. The
Python engine (ai_calc.py) must agree for every number case when the text is the
only non-trivial cell of a number column: TYPE/RANGE surface as that error code,
an empty cell is skipped, anything else is a number. (The JS engine and
AiCalcEdit.parseCell are checked against the same file in tst_AiCalcEdit.qml.)
"""

import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ai_calc", ROOT / "ai_calc.py")
calc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(calc)


def load_cases():
    text = (ROOT / "tests" / "CalcCellCases.js").read_text(encoding="utf-8")
    return json.loads(text.split("\n", 1)[1].split("var CASES =\n", 1)[1])


CASES = load_cases()


def one_cell(raw):
    return {"inputs": [], "tables": [{"id": "t", "columns": [
        {"id": "v", "kind": "number", "unit": "", "expression": ""}], "rows": [[raw], ["1"]]}],
        "cells": [{"id": "r", "expression": "sum(t.v)", "unit": "", "decimals": 2}]}


class CellCaseTests(unittest.TestCase):
    def test_file_shape(self):
        self.assertGreaterEqual(len(CASES), 40)
        self.assertEqual(len({c["tag"] for c in CASES}), len(CASES))
        self.assertTrue(all(c["kind"] in ("number", "text") for c in CASES))

    def test_python_engine_agrees_on_every_number_case(self):
        checked = 0
        for case in CASES:
            if case["kind"] != "number" or case.get("engine") is False:
                continue
            checked += 1
            with self.subTest(tag=case["tag"]):
                model = calc.compile_spec(one_cell(case["raw"]))
                node = calc.evaluate(model, {}).nodes["r"]
                got = node.err["code"] if node.err else None
                self.assertEqual(got, case["code"])
                if case["ok"] and not case["empty"]:
                    self.assertAlmostEqual(node.value, float(case["raw"].strip(" \t\r\n\f\v")) + 1, delta=1e-9 * max(1.0, abs(node.value)))
                if case["empty"]:
                    self.assertEqual(node.value, 1)
        self.assertGreaterEqual(checked, 50)

    def test_launcher_only_cases_are_accepted_by_the_engine(self):
        for case in CASES:
            if case["kind"] == "number" and case.get("engine") is False:
                with self.subTest(tag=case["tag"]):
                    node = calc.evaluate(calc.compile_spec(one_cell(case["raw"])), {}).nodes["r"]
                    self.assertIsNone(node.err)


class SourceHygieneTests(unittest.TestCase):
    """A raw U+2028/U+2029 (or any non-ASCII) inside a JS regex or string breaks compilation of
    every importer; an editing tool can turn a backslash-u escape into the raw character."""

    FILES = ("AiCalcEdit.js", "AiCalcView.js", "tests/CalcCellCases.js", "tests/tst_AiCalcEdit.qml",
             "tests/test_ai_calc_cells.py")

    def test_no_raw_line_separators_or_non_ascii(self):
        for name in self.FILES:
            with self.subTest(file=name):
                text = (ROOT / name).read_text(encoding="utf-8")
                bad = [(i, hex(ord(c))) for i, c in enumerate(text) if ord(c) > 127]
                self.assertEqual(bad, [])
                for ch in ("\u2028", "\u2029", "\u0085", "\ufeff"):
                    self.assertNotIn(ch, text)


if __name__ == "__main__":
    unittest.main()
