"""Run with PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_ai_formula.py."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ai_formula", ROOT / "ai_formula.py")
formula = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(formula)


# Shared vectors: the QML mirror (AiFormula.js) is tested against the same
# expectations so the two implementations cannot drift silently.
VECTORS = [
    ("2*x + 1", 3, 7),
    ("2 * (x + 1) - 4 / 2", 2, 4),
    ("x ^ 2", -3, 9),
    ("x ^ 3", -2, -8),
    ("x ^ 0.5", 4, 2),
    ("x ^ 0.5", -1, None),         # real-domain failure, never complex
    ("x ^ 1000", 100, None),       # overflow is a guarded invalid result
    ("x ^ -1", 0, None),
    ("x ^ 0", 0, 1),
    ("min(1/x,10)", 0, None),
    ("1/(x^1000)", 100, None),
    ("sqrt(-x)^0", 1, None),
    ("min(x*x,10)", 1e200, None),
    ("2 ^ 3 ^ 2", 0, 512),          # right-associative
    ("-x + 5", 2, 3),
    ("x % 7", 10, 3),
    ("min(x, 5) + max(x, 2)", 4, 8),
    ("clamp(x, 0, 10)", 42, 10),
    ("clamp(x, 0, 10)", -3, 0),
    ("abs(x) + floor(x) + ceil(x)", 2.4, 7.4),
    ("round(x)", 2.5, 3),           # half away from zero, identical in QML
    ("sind(x)", 90, 1),
    ("cosd(x)", 180, -1),
    ("sqrt(x)", 16, 4),
    ("pi", 0, 3.141592653589793),
    ("e", 0, 2.718281828459045),
]
# numpy/Python round(2.5) == 2 (banker's); JS Math.round(2.5) == 3. The
# grammar defines round as half away from zero so both engines agree.


class FormulaTests(unittest.TestCase):
    def test_shared_vectors(self):
        for expression, x, expected in VECTORS:
            with self.subTest(expression=expression, x=x):
                tree = formula.compile_formula(expression)
                result = formula.evaluate_formula(tree, x)
                if expected is None:
                    self.assertIsNone(result)
                else:
                    self.assertAlmostEqual(result, expected, places=9)

    def test_months_monthly_angle_example(self):
        # A plausible seasons readout: noon angle shrinks away from midsummer.
        tree = formula.compile_formula("90 - abs(x - 5.5) * 8")
        self.assertAlmostEqual(formula.evaluate_formula(tree, 5.5), 90)
        self.assertAlmostEqual(formula.evaluate_formula(tree, 0), 46)
        self.assertIsNone(formula.evaluate_formula(formula.compile_formula("sqrt(x)"), -1))
        self.assertIsNone(formula.evaluate_formula(formula.compile_formula("1 / x"), 0))

    def test_domain_and_finite_guard(self):
        self.assertIsNone(formula.evaluate_formula(formula.compile_formula("sqrt(-x)"), 4))
        self.assertIsNone(formula.evaluate_formula(formula.compile_formula("x ^ x"), 1000))

    def test_rejects_anything_but_arithmetic(self):
        for bad in ["x.__class__", "system(x)", "x;y", "[1]", "'x'", "{x}", "x=1",
                    "import os", "open(x)", "x[0]", "lambda: 1", "x and y", "@x",
                    "cos(x", "min(x)", "clamp(x,1)", "min(1,2,3)", "x,,1", "()",
                    "１２ + x", "١٢ + x", "1.２ + x"]:
            with self.subTest(bad=bad):
                with self.assertRaises(formula.FormulaError):
                    formula.compile_formula(bad)

    def test_bounds(self):
        with self.assertRaises(formula.FormulaError):
            formula.compile_formula("")
        with self.assertRaises(formula.FormulaError):
            formula.compile_formula("x+" * 200 + "x")
        with self.assertRaises(formula.FormulaError):
            formula.compile_formula("(" * 40 + "x" + ")" * 40)

    def test_format_value(self):
        self.assertEqual(formula.format_value(6, "°"), "6 °")
        self.assertEqual(formula.format_value(2.50, "°"), "2.5 °")
        self.assertEqual(formula.format_value(None, "°"), "—")
        self.assertEqual(formula.format_value(-0.0001, ""), "0")
        self.assertEqual(formula.format_value(100, "m", 0), "100 m")
        self.assertEqual(formula.format_value(1e30, "m"), "1e+30 m")
        self.assertEqual(formula.format_value(1e100, "m"), "1e+100 m")
        self.assertEqual(formula.format_value(1e308, "m"), "1e+308 m")


if __name__ == "__main__":
    unittest.main()
