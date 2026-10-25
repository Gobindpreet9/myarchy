"""Run with PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_ai_calc.py.

Part 1 replays every case of tests/CalcGolden.js (the table the JS engine is
tested against too). Part 2 pins behaviour the table cannot express.
"""

import ast
import copy
import importlib.util
import json
from pathlib import Path
import random
import re
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ai_calc", ROOT / "ai_calc.py")
calc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(calc)


def load_golden():
    text = (ROOT / "tests" / "CalcGolden.js").read_text(encoding="utf-8")
    body = text.split("\n", 1)[1].split("var CASES =\n", 1)[1]
    return json.loads(body)


GOLDEN = load_golden()
NUMBER_PREFIX = re.compile(r"-?[0-9]+(?:\.[0-9]+)?")


def spec_of(*cells, inputs=(), tables=()):
    """cells: (id, expression[, unit[, decimals]]); inputs: (id, unit, value)."""
    return {
        "inputs": [{"id": i, "unit": u, "value": v, "min": 0, "max": 1} for i, u, v in inputs],
        "tables": list(tables),
        "cells": [{"id": c[0], "expression": c[1], "unit": c[2] if len(c) > 2 else "",
                   "decimals": c[3] if len(c) > 3 else 2} for c in cells],
    }


def table(tid, columns, rows):
    """columns: (id, kind, unit[, expression])."""
    return {"id": tid, "rows": rows, "columns": [
        {"id": c[0], "kind": c[1], "unit": c[2], "expression": c[3] if len(c) > 3 else ""} for c in columns]}


def run(*cells, inputs=(), tables=(), values=None, env=None):
    model = calc.compile_spec(spec_of(*cells, inputs=inputs, tables=tables))
    return model, calc.evaluate(model, values, env)


def text_of(*cells, **kw):
    model, result = run(*cells, **kw)
    return [calc.format_cell(model, result, c[0]) for c in cells]


def reject_why(spec):
    with_error = None
    try:
        calc.compile_spec(spec)
    except calc.CalcError as error:
        with_error = error
    return with_error.why if with_error else None


class GoldenTests(unittest.TestCase):
    def test_nested_unit_power_cannot_stall_the_javascript_engine(self):
        source = (ROOT / "AiCalc.js").read_text().split("\n", 1)[1]
        script = source + '''
var expr = "1[m]";
for (var i = 0; i < 12; ++i) expr = "(" + expr + ")^9";
var model = compileSpec({inputs: [], tables: [], cells: [{id: "r", expression: expr, unit: "", decimals: 2}]});
console.log(JSON.stringify(evaluate(model, {}, null, null).nodes.r.err.code));
'''
        result = subprocess.run(["/usr/bin/node", "-"], input=script, text=True,
                                capture_output=True, timeout=3,
                                env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "RANGE")

    def test_golden_table_is_present_and_complete(self):
        self.assertGreaterEqual(len(GOLDEN), 257)
        self.assertEqual(len({c["tag"] for c in GOLDEN}), len(GOLDEN))

    def test_every_golden_case(self):
        for case in GOLDEN:
            with self.subTest(tag=case["tag"]):
                try:
                    model = calc.compile_spec(case["spec"])
                except calc.CalcError as error:
                    self.assertEqual(case["compile"], "reject", error.msg)
                    self.assertEqual(error.why, case["why"], error.msg)
                    continue
                self.assertEqual(case["compile"], "ok", "accepted a spec the table rejects")
                result = calc.evaluate(model, case.get("inputs"), case.get("env"))
                for cell_id, want in case["expect"].items():
                    node = result.nodes[cell_id]
                    self.assertEqual(node.err["code"] if node.err else None, want["err"], cell_id)
                    got = calc.format_cell(model, result, cell_id)
                    if "approx" not in want:
                        self.assertEqual(got, want["text"], cell_id)
                        continue
                    a, b = NUMBER_PREFIX.match(got), NUMBER_PREFIX.match(want["text"])
                    self.assertTrue(a and b, cell_id)
                    x, y = float(a.group()), float(b.group())
                    self.assertLessEqual(abs(x - y), want["approx"] * max(abs(x), abs(y)), cell_id)
                    self.assertEqual(got[a.end():], want["text"][b.end():], cell_id)


class UnitTableTests(unittest.TestCase):
    # Typed independently of ai_calc.py (the golden header lists the same factors).
    SCALES = {
        "mm": 0.001, "cm": 0.01, "m": 1, "km": 1000, "in": 0.0254, "ft": 0.3048, "mi": 1609.344,
        "g": 0.001, "kg": 1, "lb": 0.45359237, "oz": 0.028349523125,
        "s": 1, "min": 60, "h": 3600, "d": 86400, "wk": 604800,
        "B": 1, "kB": 1000, "MB": 10 ** 6, "GB": 10 ** 9, "TB": 10 ** 12,
        "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4,
        "J": 1, "Wh": 3600, "kWh": 3600000, "W": 1, "kW": 1000, "Hz": 1, "GHz": 10 ** 9,
        "px": 1, "%": 0.01,
    }
    CURRENCIES = "EUR USD GBP JPY CHF CAD AUD NZD SEK NOK DKK PLN CZK HUF INR CNY BRL MXN ZAR KRW".split()

    def test_scales(self):
        for symbol, scale in self.SCALES.items():
            self.assertEqual(calc.UNIT_SCALES[symbol], scale, symbol)
        for code in self.CURRENCIES + ["AED", "ZWL", "XOF", "HKD"]:
            self.assertEqual(calc.UNIT_SCALES[code], 1, code)
        for fake in ("ABC", "XXX", "EURO", "eur"):
            self.assertNotIn(fake, calc.UNIT_SCALES)
        self.assertEqual(len(calc.UNIT_SCALES), len(self.SCALES) + 155)

    def test_dimensions(self):
        dims = calc.UNIT_DIMENSIONS
        self.assertEqual(dict(dims["kWh"]), {"mass": 1, "length": 2, "time": -2})
        self.assertEqual(dict(dims["kW"]), {"mass": 1, "length": 2, "time": -3})
        self.assertEqual(dict(dims["GHz"]), {"time": -1})
        self.assertEqual(dict(dims["KiB"]), dict(dims["kB"]))
        self.assertEqual(dict(dims["px"]), {"pixel": 1})
        self.assertEqual(dict(dims["%"]), {})
        self.assertEqual(dict(dims["EUR"]), {"EUR": 1})
        self.assertNotEqual(dict(dims["EUR"]), dict(dims["USD"]))

    def test_tables_are_read_only(self):
        with self.assertRaises(TypeError):
            calc.UNIT_SCALES["m"] = 2

    def test_unit_group_parsing(self):
        self.assertEqual(calc.parse_unit("EUR/kg/h"), (("EUR", 1), ("kg", -1), ("h", -1)))
        self.assertEqual(calc.parse_unit("m*m"), (("m", 2),))
        self.assertEqual(calc.parse_unit("m/m"), ())
        for bad in ("", "kg^", "kg^0", "kg^10", "kg*", "*kg", "kg kg", " kg", "(kg)", "kg^-1"):
            with self.subTest(bad=bad), self.assertRaises(calc.CalcError):
                calc.parse_unit(bad)


class GraphTests(unittest.TestCase):
    def random_dag(self, rng, count):
        """Cells c0..cN each referencing earlier cells or inputs."""
        cells = []
        for n in range(count):
            names = ["x", "y"] + ["c%d" % k for k in range(n)]
            parts = [rng.choice(names) for _ in range(rng.randint(1, 3))]
            cells.append(("c%d" % n, "+".join(parts) + "*%d" % rng.randint(1, 3)))
        return cells

    @staticmethod
    def references(expression, ids):
        return {i for i in ids if re.search(r"(?<![a-z0-9_])%s(?![a-z0-9_])" % i, expression)}

    def reference_order(self, declared, exprs):
        ids = set(declared)
        deps = {i: self.references(exprs.get(i, ""), ids) for i in declared}
        done, order = set(), []
        while len(order) < len(declared):
            ready = [i for i in declared if i not in done and deps[i] <= done]
            order.append(ready[0])
            done.add(ready[0])
        return order

    def test_order_matches_reference_kahn_and_ignores_shuffling(self):
        rng = random.Random(20261008)
        for trial in range(25):
            cells = self.random_dag(rng, rng.randint(2, 14))
            baseline = None
            for shuffle in range(4):
                order = list(cells)
                if shuffle:
                    rng.shuffle(order)
                inputs = [("x", "", 2), ("y", "", 3)]
                model = calc.compile_spec(spec_of(*order, inputs=inputs))
                exprs = dict(order)
                self.assertEqual(list(model.order), self.reference_order(["x", "y"] + [c[0] for c in order], exprs))
                result = calc.evaluate(model)
                shown = {c[0]: calc.format_cell(model, result, c[0]) for c in cells}
                baseline = baseline or shown
                self.assertEqual(shown, baseline)

    def test_table_order_is_row_by_row_with_declaration_ties(self):
        spec = spec_of(("total", "sum(t.f)"), inputs=[("rate", "", 2)], tables=[
            table("t", [("v", "number", ""), ("f", "formula", "", "v*rate"), ("gg", "formula", "", "f+1")],
                  [["1", "", ""], ["2", "", ""]])])
        model = calc.compile_spec(spec)
        self.assertEqual(list(model.order), ["rate", "t.f#1", "t.gg#1", "t.f#2", "t.gg#2", "total"])

    def test_cycle_path_is_reported(self):
        for cells, members in ((("p", "q+1"), ("q", "r"), ("r", "p+1")), {"p", "q", "r"}), ((("p", "p+1"),), {"p"}):
            with self.assertRaises(calc.CalcError) as caught:
                calc.compile_spec(spec_of(*cells))
            self.assertEqual(caught.exception.why, "cycle")
            path = re.findall(r"[a-z]+", caught.exception.msg.split(":", 1)[-1].replace("Circular reference", ""))
            self.assertEqual(path[0], path[-1])
            self.assertEqual(set(path), members)

    def test_compile_is_deterministic(self):
        spec = spec_of(("a", "x+1"), ("b", "a*2"), inputs=[("x", "", 1)])
        self.assertEqual(calc.compile_spec(spec).order, calc.compile_spec(copy.deepcopy(spec)).order)


class EvaluateTests(unittest.TestCase):
    SPEC = spec_of(
        ("dsum", "a+b"), ("dbl", "dsum*2"), ("gate", "if(c>0,dbl,0)"), ("clp", "clamp(dbl,0,10)"),
        ("tot", "clp+sum(t.f)"), ("conv", "to(w*2,[m])", "m"), ("bad", "1/c"), ("safe", "iferror(bad,-1)"),
        ("big", "min(clp,5)>=5"),
        inputs=[("a", "", 1), ("b", "", 2), ("c", "", None), ("w", "cm", 150), ("rate", "", 3)],
        tables=[table("t", [("n", "number", ""), ("f", "formula", "", "n*rate")],
                      [["1", ""], ["", ""], ["4", ""]])])

    @staticmethod
    def snapshot(model, result):
        return ({k: (type(n.raw).__name__, calc.format_cell(model, result, k), n.unit, n.value,
                     n.err and (n.err["code"], n.err["node"]), n.warn) for k, n in result.nodes.items()},
                result.steps, result.stats["rowReads"])

    def test_incremental_equals_full_recompute_over_random_edits(self):
        model = calc.compile_spec(self.SPEC)
        rng = random.Random(7)
        pool = [None, 0, 1, 2.5, -3, 4, 100, 1e200, 0.1]
        values, prev = {}, calc.evaluate(model, {})
        for step in range(250):
            for _ in range(rng.randint(0, 3)):
                values[rng.choice(["a", "b", "c", "w", "rate"])] = rng.choice(pool)
            incremental = calc.evaluate(model, dict(values), None, prev)
            full = calc.evaluate(model, dict(values))
            self.assertEqual(self.snapshot(model, incremental), self.snapshot(model, full), (step, values))
            prev = incremental

    def test_unchanged_values_stop_propagation(self):
        model = calc.compile_spec(spec_of(("big", "clamp(x,0,10)"), ("next", "big+1"), ("other", "y*2"),
                                          inputs=[("x", "", 20), ("y", "", 1)]))
        first = calc.evaluate(model)
        again = calc.evaluate(model, {}, None, first)
        self.assertEqual(again.stats["evaluated"], 0)
        clamped = calc.evaluate(model, {"x": 50}, None, first)
        self.assertEqual(clamped.stats["evaluated"], 2)  # input + clamp; `next` is untouched
        self.assertIs(clamped.nodes["next"], first.nodes["next"])
        moved = calc.evaluate(model, {"x": 5}, None, first)
        self.assertEqual(moved.stats["evaluated"], 3)

    def test_incremental_follows_an_env_change(self):
        model = calc.compile_spec(spec_of(("src", "colstat(1,sum)"), ("twice", "src*2")))
        a = calc.evaluate(model, None, {"stats": [{"sum": 3}]})
        b = calc.evaluate(model, None, {"stats": [{"sum": 5}]}, a)
        self.assertEqual(calc.format_cell(model, b, "twice"), "10.00")
        self.assertEqual(calc.format_cell(model, calc.evaluate(model, None, None, b), "twice"), calc.DASH)

    def test_incremental_after_a_limit_pass_recomputes_everything(self):
        case = next(c for c in GOLDEN if c["tag"] == "limits-pass-budget-50001-steps-limit-on-last-cell")
        model = calc.compile_spec(case["spec"])
        first = calc.evaluate(model)
        second = calc.evaluate(model, {}, None, first)
        self.assertEqual(second.steps, first.steps)
        self.assertEqual(calc.format_cell(model, second, "fin"), calc.DASH)

    def test_evaluate_is_pure(self):
        model = calc.compile_spec(self.SPEC)
        values = {"a": 5, "c": 1}
        env = {"stats": [{"sum": 1.0}]}
        values_before, env_before = copy.deepcopy(values), copy.deepcopy(env)
        first = calc.evaluate(model, values, env)
        second = calc.evaluate(model, values, env)
        via_prev = calc.evaluate(model, values, env, first)
        self.assertEqual(values, values_before)
        self.assertEqual(env, env_before)
        for other in (second, via_prev):
            self.assertEqual(self.snapshot(model, first), self.snapshot(model, other))
        # nothing the caller can mutate on a result reaches the next one
        first.nodes.clear()
        self.assertEqual(self.snapshot(model, calc.evaluate(model, values, env)), self.snapshot(model, second))

    def test_a_second_model_in_between_changes_nothing(self):
        one = calc.compile_spec(self.SPEC)
        other = calc.compile_spec(spec_of(("z", "9^9"), ("y", "sqrt(-1)")))
        before = self.snapshot(one, calc.evaluate(one, {"a": 2}))
        calc.evaluate(other)
        calc.compile_spec(spec_of(("q", "1+1")))
        self.assertEqual(self.snapshot(one, calc.evaluate(one, {"a": 2})), before)

    def test_unknown_input_keys_are_ignored_and_bad_values_become_errors(self):
        model = calc.compile_spec(spec_of(("r", "x+1"), inputs=[("x", "", 1)]))
        self.assertEqual(calc.format_cell(model, calc.evaluate(model, {"nope": 5}), "r"), "2.00")
        for bad, code in ((float("inf"), "RANGE"), (float("nan"), "RANGE"), ("3", "TYPE"), (True, "TYPE"), (None, "MISSING")):
            result = calc.evaluate(model, {"x": bad})
            self.assertEqual(result.nodes["r"].err["code"], code, bad)

    def test_error_node_names_where_it_arose(self):
        model, result = run(("e1", "1/0"), ("e2", "e1+1"), ("e3", "e2*2"))
        self.assertEqual({k: n.err["node"] for k, n in result.nodes.items()}, {"e1": "e1", "e2": "e1", "e3": "e1"})
        self.assertIs(result.nodes["e3"].err, result.nodes["e1"].err)

    def test_every_error_code_is_producible(self):
        probes = {
            "DIV0": "1/0", "MISSING": "x", "TYPE": "1 and 2", "UNIT": "1[kg]+1[m]", "DOMAIN": "sqrt(-1)",
            "RANGE": "10^400", "SRC": "colstat(1,sum)",
        }
        for code, expr in probes.items():
            model, result = run(("r", expr), inputs=[("x", "", None)])
            self.assertEqual(result.nodes["r"].err["code"], code, expr)
        case = next(c for c in GOLDEN if c["tag"] == "limits-pass-budget-50001-steps-limit-on-last-cell")
        model = calc.compile_spec(case["spec"])
        self.assertEqual(calc.evaluate(model).nodes["fin"].err["code"], "LIMIT")
        self.assertEqual(set(probes) | {"LIMIT"}, set(calc.ERROR_CODES))

    def test_limit_is_not_catchable_and_poisons_later_nodes(self):
        case = next(c for c in GOLDEN if c["tag"] == "limits-pass-budget-50001-steps-limit-on-last-cell")
        spec = copy.deepcopy(case["spec"])
        spec["cells"].append({"id": "after", "expression": "iferror(fin,7)", "unit": "", "decimals": 0})
        spec["cells"].append({"id": "lit", "expression": "1", "unit": "", "decimals": 0})
        result = calc.evaluate(calc.compile_spec(spec))
        self.assertEqual(result.nodes["fin"].err["code"], "LIMIT")
        self.assertEqual(result.nodes["after"].err["code"], "LIMIT")
        self.assertEqual(result.nodes["lit"].err["code"], "LIMIT")


class LimitTests(unittest.TestCase):
    def test_constants(self):
        self.assertEqual(
            (calc.max_expression_chars, calc.max_tokens, calc.max_nodes, calc.max_depth, calc.max_call_args,
             calc.max_inputs, calc.max_cells, calc.max_tables, calc.max_columns, calc.max_rows,
             calc.max_graph_nodes, calc.max_pass_steps, calc.max_cell_steps, calc.max_id_chars),
            (200, 120, 80, 32, 6, 12, 24, 2, 12, 40, 300, 50000, 5000, 24))

    def expression_case(self, expression):
        return reject_why(spec_of(("r", expression)))

    def test_expression_boundaries(self):
        self.assertIsNone(self.expression_case("1+" + " " * 197 + "1"))                     # 200 chars
        self.assertEqual(self.expression_case("1+" + " " * 198 + "1"), "length")             # 201
        self.assertEqual(self.expression_case("\u00a0" + " " * 250), "non-ascii")           # checked before length
        self.assertIsNone(self.expression_case("(1)+" * 29 + "(-1)"))                        # 120 tokens
        self.assertEqual(self.expression_case("(1)+" * 28 + "(-1)+(-1)"), "tokens")        # 121
        self.assertIsNone(self.expression_case("abs(" * 31 + "1" + ")" * 31))               # depth 32
        self.assertEqual(self.expression_case("abs(" * 32 + "1" + ")" * 32), "depth")
        self.assertIsNone(self.expression_case("max(" + ",".join(["1"] * 6) + ")"))
        self.assertEqual(self.expression_case("max(" + ",".join(["1"] * 7) + ")"), "args")

    def test_node_boundary_is_exactly_eighty(self):
        def group(first, extra):          # (first + 1 x extra)
            return "(" + first + "+1" * extra + ")"
        self.assertIsNone(self.expression_case(group("-1", 19) + "+" + group("1", 19)))   # 40 + 39 + root
        self.assertEqual(self.expression_case(group("1", 19) + "+" + group("1", 20)), "nodes")

    def test_count_boundaries(self):
        def inputs(n):
            return [("i%d" % k, "", 1) for k in range(n)]
        self.assertIsNone(reject_why(spec_of(("r", "1"), inputs=inputs(12))))
        self.assertEqual(reject_why(spec_of(("r", "1"), inputs=inputs(13))), "limit-inputs")
        self.assertIsNone(reject_why(spec_of(*[("c%d" % k, "1") for k in range(24)])))
        self.assertEqual(reject_why(spec_of(*[("c%d" % k, "1") for k in range(25)])), "limit-cells")

        def tab(n, columns=1, rows=1):
            return table("t%d" % n, [("k%d" % c, "number", "") for c in range(columns)], [["1"] * columns] * rows)
        self.assertIsNone(reject_why(spec_of(("r", "1"), tables=[tab(1), tab(2)])))
        self.assertEqual(reject_why(spec_of(("r", "1"), tables=[tab(1), tab(2), tab(3)])), "limit-tables")
        self.assertIsNone(reject_why(spec_of(("r", "1"), tables=[tab(1, columns=12)])))
        self.assertEqual(reject_why(spec_of(("r", "1"), tables=[tab(1, columns=13)])), "limit-columns")
        self.assertIsNone(reject_why(spec_of(("r", "1"), tables=[tab(1, rows=40)])))
        self.assertEqual(reject_why(spec_of(("r", "1"), tables=[tab(1, rows=41)])), "limit-rows")

    def test_graph_node_boundary(self):
        def spec(extra_rows):
            formulas = [("f%d" % k, "formula", "", "n") for k in range(6)]
            first = table("a", [("n", "number", "")] + formulas, [["1"] + [""] * 6] * 40)
            second = table("b", [("n", "number", ""), ("gg", "formula", "", "n")], [["1", ""]] * (24 + extra_rows))
            return spec_of(*[("c%d" % k, "1") for k in range(24)],
                           inputs=[("i%d" % k, "", 1) for k in range(12)], tables=[first, second])
        self.assertIsNone(reject_why(spec(0)))         # 12 + 24 + 240 + 24 = 300
        self.assertEqual(reject_why(spec(1)), "limit-graph")

    def test_id_length_boundary(self):
        self.assertIsNone(reject_why(spec_of(("a" * 24, "1"))))
        self.assertEqual(reject_why(spec_of(("a" * 25, "1"))), "bad-id")

    def test_pass_budget_boundary_and_step_totals(self):
        ok = next(c for c in GOLDEN if c["tag"] == "limits-pass-budget-50000-steps-ok")
        over = next(c for c in GOLDEN if c["tag"] == "limits-pass-budget-50001-steps-limit-on-last-cell")
        self.assertEqual(calc.evaluate(calc.compile_spec(ok["spec"])).steps, calc.max_pass_steps)
        result = calc.evaluate(calc.compile_spec(over["spec"]))
        self.assertEqual(result.steps, calc.max_pass_steps)      # the crossing node is not charged
        self.assertEqual(sum(n.err is not None for n in result.nodes.values()), 1)


class StepAccountingTests(unittest.TestCase):
    def steps(self, expression, **kw):
        model, result = run(("r", expression), **kw)
        return result.steps

    def test_one_step_per_node_evaluated(self):
        self.assertEqual(self.steps("1+2"), 3)
        self.assertEqual(self.steps("12.5[kg]"), 1)                    # a unit literal is one node
        self.assertEqual(self.steps("-(1+2)"), 4)
        self.assertEqual(self.steps("abs(1)"), 2)
        self.assertEqual(self.steps("to(1[m],[km])"), 3)              # call, literal, [u] group
        self.assertEqual(self.steps("colstat(1,sum)", env={"stats": [{"sum": 1}]}), 3)

    def test_untaken_branches_and_short_circuited_operands_cost_nothing(self):
        self.assertEqual(self.steps("if(1<2,1,1/0)"), 1 + 3 + 1)      # if, (1<2), taken literal
        self.assertEqual(self.steps("if(2<1,1/0,1)"), 1 + 3 + 1)
        self.assertEqual(self.steps("iferror(1,1/0)"), 2)
        self.assertEqual(self.steps("iferror(1/0,5)"), 1 + 3 + 1)     # a failed try is charged
        self.assertEqual(self.steps("(1/0)+(1/0)"), 1 + 3)            # the right operand never runs

    def test_column_references_cost_one_plus_rows_and_inputs_are_free(self):
        rows = [[str(n)] for n in range(5)]
        tab = table("t", [("v", "number", "")], rows)
        model, result = run(("r", "sum(t.v)"), tables=[tab])
        self.assertEqual((result.steps, result.stats["rowReads"]), (1 + 1 + 5, 5))
        model, result = run(("r", "x"), inputs=[("x", "", 1)])
        self.assertEqual(result.steps, 1)                              # the reference node only
        self.assertEqual(result.nodes["x"].err, None)

    def test_formula_instances_cost_their_formula_and_count(self):
        tab = table("t", [("v", "number", ""), ("f", "formula", "", "v*2")], [["1", ""], ["2", ""], ["3", ""]])
        model, result = run(("r", "1"), tables=[tab])
        self.assertEqual(result.steps, 3 * 3 + 1)

    def test_incremental_steps_equal_full_steps(self):
        spec = spec_of(("a", "x+1"), ("b", "a*2"), inputs=[("x", "", 1)])
        model = calc.compile_spec(spec)
        first = calc.evaluate(model)
        later = calc.evaluate(model, {"x": 9}, None, first)
        self.assertEqual(later.steps, calc.evaluate(model, {"x": 9}).steps)


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.model = calc.compile_spec(spec_of(
            ("cost", "hours*rate+extra", "EUR", 1), ("bad", "cost/zero"), ("top", "bad+1"),
            ("avg", "mean(t.v)", "kg", 3),
            inputs=[("hours", "h", 2.5), ("rate", "EUR/h", 40), ("extra", "EUR", 0.04), ("zero", "", 0)],
            tables=[table("t", [("v", "number", "kg")], [["1"], [""], ["2"]])]))
        self.result = calc.evaluate(self.model)

    def test_cell_with_declared_unit_and_rounding(self):
        info = calc.provenance(self.model, self.result, "cost")
        self.assertEqual(info["formula"], "hours*rate+extra")
        self.assertEqual((info["kind"], info["declaredUnit"], info["unit"], info["text"]), ("cell", "EUR", "EUR", "100.0 EUR"))
        self.assertEqual([r["name"] for r in info["refs"]], ["hours", "rate", "extra"])
        self.assertEqual([r["basis"] for r in info["refs"]], ["input"] * 3)
        self.assertEqual([r["unit"] for r in info["refs"]], ["h", "EUR/h", "EUR"])
        self.assertEqual(info["refs"][0]["value"], 2.5)
        self.assertEqual(info["refs"][0]["text"], calc.format_cell(self.model, self.result, "hours"))
        self.assertEqual(info["refs"][2]["error"], None)
        self.assertIn("EUR/h", info["unitDerivation"])
        self.assertIn("1 places", info["rounding"])
        self.assertIn("half away from zero", info["rounding"])
        self.assertIn("100.04", info["rounding"])

    def test_aggregate_names_rows_used(self):
        info = calc.provenance(self.model, self.result, "avg")
        self.assertEqual(info["refs"][0]["name"], "t.v")
        self.assertEqual(info["refs"][0]["basis"], "column, 2 of 3 rows used")
        self.assertEqual(info["warnings"], ["mean(t.v): 2 of 3 rows used"])
        self.assertEqual(info["text"], "1.500 kg")

    def test_error_chain_walks_to_the_origin(self):
        info = calc.provenance(self.model, self.result, "top")
        self.assertEqual(info["error"]["code"], "DIV0")
        self.assertEqual(info["chain"], ["top", "bad"])
        self.assertEqual(info["error"]["node"], "bad")
        self.assertEqual(info["text"], calc.DASH)
        self.assertEqual(calc.provenance(self.model, self.result, "bad")["chain"], ["bad"])

    def test_input_and_unknown_ids(self):
        info = calc.provenance(self.model, self.result, "rate")
        self.assertEqual((info["kind"], info["formula"], info["refs"]), ("input", None, []))
        self.assertIsNone(calc.provenance(self.model, self.result, "nope"))
        self.assertEqual(calc.format_cell(self.model, self.result, "nope"), "")

    def test_row_reference_and_column_cell(self):
        tab = table("t", [("q", "number", ""), ("p", "number", "EUR"), ("line", "formula", "EUR", "q*p")],
                    [["2", "3", ""], ["", "5", ""]])
        model, result = run(("tot", "sum(t.line)"), tables=[tab])
        info = calc.provenance(model, result, "t.line#1")
        self.assertEqual(info["kind"], "column-cell")
        self.assertEqual([(r["name"], r["basis"], r["value"], r["unit"]) for r in info["refs"]],
                         [("q", "this row of t", None, ""), ("p", "this row of t", None, "EUR")])
        self.assertEqual(info["text"], "6.00 EUR")
        second = calc.provenance(model, result, "t.line#2")
        self.assertEqual(second["error"]["code"], "MISSING")
        self.assertEqual(calc.provenance(model, result, "tot")["chain"], ["tot", "t.line#2"])


class HostileTests(unittest.TestCase):
    def test_garbage_only_raises_calc_error_and_never_hangs(self):
        rng = random.Random(1008)
        alphabet = "()+-*/%^,.<>=!&|[] \tabcdefghijklmnopqrstuvwxyzABCXYZ0123456789_\né١−\"';:#@$"
        pieces = ["sum(", "if(", "iferror(", "to(", "num(", "colstat(", "t.v", "[kg]", "[m/s^2]", "1e3", "and", "or", "not"]
        worst = 0.0
        for _ in range(4000):
            if rng.random() < 0.5:
                text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 80)))
            else:
                text = "".join(rng.choice(pieces + list(alphabet)) for _ in range(rng.randint(1, 40)))
            began = time.perf_counter()
            try:
                calc.compile_expression(text)
            except calc.CalcError:
                pass
            worst = max(worst, time.perf_counter() - began)
        self.assertLess(worst, 0.5)

    def test_garbage_specs_only_raise_calc_error(self):
        rng = random.Random(55)
        junk = [None, 3, "x", [], {}, [1], {"id": 5}, {"id": "a"}, {"id": "a", "expression": 4}, {"id": "Z"}, "", 1.5, True]
        for _ in range(500):
            spec = {rng.choice(["inputs", "tables", "cells", "x"]): rng.choice(
                [junk, [rng.choice(junk) for _ in range(3)], rng.choice(junk)]) for _ in range(rng.randint(0, 3))}
            try:
                calc.compile_spec(spec)
            except calc.CalcError:
                pass
        for bad in ({"cells": [{"id": "a", "expression": "1", "unit": 5}]},
                    {"tables": [{"id": "t", "columns": [{"id": "v", "kind": "oops"}], "rows": []}]},
                    {"tables": [{"id": "t", "columns": [{"id": "v", "kind": "number"}], "rows": [[5]]}]},
                    {"inputs": [{"id": "x", "unit": "", "value": 1}, {"id": "x", "unit": "", "value": 2}]}):
            self.assertIsNotNone(reject_why(bad), bad)

    def test_hostile_expressions_compile_to_the_named_reject(self):
        cases = {
            "1 2": "syntax", "1+": "syntax", "()": "syntax", "a.b.c": "syntax",
            "x\ny": "syntax", "1١": "non-ascii", "5[kg] [m]": "unit-position", "5 [kg]": "unit-position",
            "5[ kg]": "bad-unit", "5[kg*]": "bad-unit", "to([kg],[m])": "unit-position", "not+1": "syntax",
            "1+not 2": "syntax", "-not 1": "syntax", "1<not 2": "syntax", "sum(1,)": "syntax", "abs(1))": "syntax",
            "5[m^10]": "bad-unit", "5[m^-1]": "bad-unit", "sqrt": "unknown-name", "Sum(1)": "syntax",
        }
        for text, why in cases.items():
            with self.subTest(text=text):
                self.assertEqual(reject_why(spec_of(("r", text))), why)

    def test_deep_nesting_cannot_exhaust_the_stack(self):
        for text in ("(" * 59 + "1" + ")" * 59, "-" * 100 + "1", "not " * 29 + "1<2", "2^" * 59 + "2"):
            try:
                calc.compile_expression(text)
            except calc.CalcError as error:
                self.assertIn(error.why, ("depth", "nodes", "tokens", "length"))


class SemanticsBeyondTheTable(unittest.TestCase):
    """Readings of the open questions this engine settled; the JS twin may differ."""

    def test_stat_and_aggregate_shapes(self):
        self.assertEqual(text_of(("r", "colstat(1,min)", "", 1), env={"stats": [{"min": 2}]}), ["2.0"])
        self.assertEqual(text_of(("r", "colstat(1,min)")), [calc.DASH])
        self.assertEqual(text_of(("r", "colstat(1,min)"), env={"stats": ["junk"]}), [calc.DASH])

    def test_declared_percent_on_a_referenced_cell_is_the_plain_number(self):
        self.assertEqual(text_of(("p", "0.25", "%"), ("q", "p*200", "", 0)), ["25.00 %", "50"])

    def test_nonfinite_and_overflow_never_display(self):
        for expression in ("10^308*10", "(10^200)*(10^200)", "sum(10^308,10^308)"):
            self.assertEqual(text_of(("r", expression)), [calc.DASH], expression)

    def test_decimals_are_clamped_and_unit_less_booleans_ignore_them(self):
        self.assertEqual(text_of(("ra", "1/3", "", 99), ("rb", "1/3", "", -4), ("rc", "1/3", "", "x")),
                         ["0.3333333333", "0", "0.33"])
        self.assertEqual(text_of(("r", "1<2", "", 5)), ["true"])

    def test_text_and_number_cell_trimming_is_ascii_only(self):
        tab = table("t", [("v", "number", "")], [[" 1 "], ["\t2\n"], [" 3"]])
        model, result = run(("sm", "sum(t.v)"), tables=[tab])
        self.assertEqual(result.nodes["sm"].err["code"], "TYPE")
        self.assertEqual(result.nodes["sm"].err["node"], "sm")
        self.assertIn("t.v#3", result.nodes["sm"].err["msg"])

    def test_zero_row_table_aggregates(self):
        tab = table("t", [("v", "number", "kg")], [])
        self.assertEqual(text_of(("sm", "sum(t.v)"), ("ct", "count(t.v)", "", 0), ("mn", "mean(t.v)"), tables=[tab]),
                         ["0.00 kg", "0", calc.DASH])


class ParityReadingsTests(unittest.TestCase):
    """Choices the golden table leaves open, agreed with the JS twin."""

    def test_clean_rounds_an_exact_16th_digit_tie_away_from_zero(self):
        self.assertEqual(calc.clean(123456789012344.5), 123456789012345.0)
        self.assertEqual(calc.clean(-123456789012344.5), -123456789012345.0)
        self.assertEqual(calc.clean(0.1 + 0.2), 0.3)
        self.assertEqual(calc.fixed_text(123456789012344.5, 0), "123456789012345")
        self.assertEqual(calc.fixed_text(-123456789012344.5, 0), "-123456789012345")
        self.assertEqual(text_of(("r", "123456789012344.5", "", 0), ("rr", "round(123456789012344.5,0)", "", 0)),
                         ["123456789012345", "123456789012345"])
        self.assertEqual(calc.fixed_text(-0.0, 2), "0.00")

    def test_sqrt_and_powers_of_quantities(self):
        self.assertEqual(text_of(("ra", "sqrt(9[m^2])", "", 1), ("rb", "(2[m])^3", "", 0), ("rc", "(2[m])^-1", "", 2)),
                         ["3.0 m", "8 m^3", "0.50 1/m"])
        self.assertEqual(text_of(("ra", "sqrt(9[m])"), ("rb", "(2[m])^0.5"), ("rc", "(2[m])^10"), ("rd", "2^(1[m])")),
                         [calc.DASH] * 4)
        model, result = run(("ra", "sqrt(9[m])"), ("rb", "(2[m])^2^1"), ("rc", "5[m]>0"))
        self.assertEqual([result.nodes[k].err and result.nodes[k].err["code"] for k in ("ra", "rb", "rc")],
                         ["UNIT", None, "UNIT"])

    def test_unknown_name_versus_syntax_for_odd_names(self):
        self.assertEqual(reject_why(spec_of(("r", "a" * 25))), "unknown-name")
        for text in ("Abc", "_a", "aB", "Min(1,2)"):
            self.assertEqual(reject_why(spec_of(("r", text))), "syntax", text)
        self.assertEqual(reject_why(spec_of(("r", "colstat(1,SUM)"))), "syntax")
        self.assertEqual(reject_why(spec_of(("r", "colstat(1,_x)"))), "syntax")
        self.assertEqual(reject_why(spec_of(("r", "colstat(1,median)"))), "colstat-args")

    def test_table_resolution_comes_before_the_aggregate_position_check(self):
        tab = table("t", [("v", "number", "")], [["1"]])
        self.assertEqual(reject_why(spec_of(("r", "abs(nosuch.v)"), tables=[tab])), "unknown-table")
        self.assertEqual(reject_why(spec_of(("r", "abs(t.zz)"), tables=[tab])), "unknown-column")
        self.assertEqual(reject_why(spec_of(("r", "abs(t.v)"), tables=[tab])), "colref-outside-aggregate")
        empty = table("e", [("v", "number", ""), ("f", "formula", "", "nosuch+1")], [])
        self.assertEqual(reject_why(spec_of(("r", "1"), tables=[empty])), "unknown-name")

    def test_reject_priority_across_the_spec(self):
        bad_expr = ("r", "1+")
        big_tab = table("t", [("v", "number", "")], [["1"]] * 41)
        # a count limit beats everything below it
        self.assertEqual(reject_why(spec_of(bad_expr, ("Bad", "1"), tables=[big_tab])), "limit-rows")
        # row-shape beats ids, ids beat units, units beat expressions, expressions beat cycles
        shaped = table("t", [("v", "number", "")], [["1", "2"]])
        self.assertEqual(reject_why(spec_of(("Bad", "1"), tables=[shaped])), "row-shape")
        self.assertEqual(reject_why(spec_of(("Bad", "1", "kg^0"))), "bad-id")
        self.assertEqual(reject_why(spec_of(("a", "1+", "kg^0"))), "bad-unit")
        self.assertEqual(reject_why(spec_of(("a", "b"), ("b", "a"), ("c", "1+"))), "syntax")
        # formula-column expressions are parsed before cell expressions
        fcol = table("t", [("v", "number", ""), ("f", "formula", "", "v+")], [["1", ""]])
        self.assertEqual(reject_why(spec_of(("a", "1e3"), tables=[fcol])), "syntax")
        # depth is checked as nodes are built, so it can beat a later syntax error
        self.assertEqual(self.depth_then_syntax(), "depth")

    @staticmethod
    def depth_then_syntax():
        return reject_why(spec_of(("r", "abs(" * 32 + "1" + ")" * 32 + "+")))


class DecisionTests(unittest.TestCase):
    """Rulings D1-D10 plus the two open questions settled with the JS twin (golden group "decisions")."""

    def codes(self, *cells, **kw):
        model, result = run(*cells, **kw)
        return [result.nodes[c[0]].err["code"] if result.nodes[c[0]].err else calc.format_cell(model, result, c[0])
                for c in cells]

    def test_d1_non_finite_conversions_are_range_not_crashes(self):
        big = dict(inputs=[("q", "kg", 1e308), ("k", "km", 1e308), ("p", "GHz", 1e308)])
        self.assertEqual(self.codes(("a", "to(q,[g])"), ("b", "num(q,[g])"), ("c", "k", "m"), ("e", "p", "Hz"),
                                    ("f", "k/1[mm]"), ("gm", "iferror(to(q,[g]),0[g])", "", 0), **big),
                         ["RANGE"] * 5 + ["0 g"])
        small = dict(inputs=[("q", "kg", 1e305), ("k", "km", 1e305)])
        self.assertEqual(self.codes(("a", "num(q,[g])>0"), ("b", "to(q,[g])>0[g]"), ("c", "k>1[m]"), **small),
                         ["true", "true", "true"])

    def test_d1_round_overflows_exactly_when_the_scaled_value_does(self):
        values = dict(inputs=[("q", "", 1.7976931348623157e308), ("a", "", 1e303), ("b", "", 1e304)])
        self.assertEqual(self.codes(("c1", "round(q,5)"), ("c2", "round(q,1)"), ("c3", "round(q,0)==q"),
                                    ("c4", "round(a,5)==a"), ("c5", "round(b,5)"), ("c6", "round(b,4)==b"), **values),
                         ["RANGE", "RANGE", "true", "true", "RANGE", "true"])

    def test_d1_quantity_power_overflow_and_d4_unit_check_first(self):
        q = dict(inputs=[("q", "m", 1e200)])
        self.assertEqual(self.codes(("a", "q^2"), ("b", "q^9"), ("c", "q^10"), ("dd", "q^3000"), ("e", "q^0.5"),
                                    ("f", "sqrt(0-5[cm])"), ("gg", "sqrt(0-9[m^2])"), **q),
                         ["RANGE", "RANGE", "UNIT", "UNIT", "UNIT", "UNIT", "DOMAIN"])

    def test_every_arithmetic_trap_is_an_error_value(self):
        expressions = ["10^300*10^300", "9[TB^9]*9[TB^9]*9[TB^9]*9[TB^9]*9[TB^9]*9[TB^9]", "(9[TB^9])^9",
                       "to(9[TB^9],[kB^9])", "num(1e300[km],[mm])", "1/(1[TB^9]*1[TB^9]*1[TB^9]*1[TB^9])",
                       "1[mm^9]*1[mm^9]*1[mm^9]*1[mm^9]*1[mm^9]*1[mm^9]*1[mm^9]*1[mm^9]/1[km^9]/1[km^9]/1[km^9]/1[km^9]",
                       "round(1e300,10)", "sum(1e308,1e308,1e308)", "mean(1e308,1e308)", "median(1e308,1e308)"]
        for text in expressions:
            with self.subTest(text=text):
                try:
                    model, result = run(("r", text))
                except calc.CalcError:
                    continue
                calc.provenance(model, result, "r")
                self.assertIn(result.nodes["r"].err["code"] if result.nodes["r"].err else None,
                              (None, "RANGE", "UNIT", "DIV0"))

    def test_d2_text_columns_are_type_even_without_rows(self):
        tab = table("t", [("name", "text", "")], [])
        self.assertEqual(self.codes(("a", "sum(t.name)"), ("b", "mean(t.name)"), ("c", "median(t.name)"),
                                    ("ct", "count(t.name)", "", 0), tables=[tab]), ["TYPE", "TYPE", "TYPE", "0"])

    def test_d3_second_argument_of_to_and_num_must_be_a_unit_group(self):
        for text in ("to(1,5)", "num(1[kg],5)", "to(1,x)", "to(1[kg],x+1)", "to(5[kg],kg)", "to(1,nosuch)"):
            self.assertEqual(reject_why(spec_of(("r", text), inputs=[("x", "", 1)])), "unit-position", text)
        self.assertEqual(self.codes(("r", "to(1[kg],[g])", "", 0)), ["1000 g"])

    def test_d5_parse_faults_come_before_resolution(self):
        cases = {"round690.9[Wh],1)": "syntax", "colstat(1,[kg])": "unit-position", "nosuch+(1": "syntax",
                 "sin(1))": "syntax", "sum(nosuch.x))": "syntax", "colstat(0,sum": "syntax", "nosuch(1,2": "syntax",
                 "1e3+nosuch": "scientific-literal", "nosuch<1<2": "chained-comparison", "nosuch+1": "unknown-name"}
        for text, why in cases.items():
            self.assertEqual(reject_why(spec_of(("r", text))), why, text)
        # across cells too: a later cell's syntax error beats an earlier cell's unknown name
        self.assertEqual(reject_why(spec_of(("a", "nosuch+1"), ("b", "1+"))), "syntax")
        self.assertEqual(reject_why(spec_of(("a", "colstat(0,sum)"), ("b", "1+"))), "syntax")

    def test_d6_d7_d8_shapes_overrides_and_declared_units(self):
        for bad in ({"cells": [5]}, {"inputs": {}}, {"cells": [{"id": "r", "expression": 5}]},
                    {"cells": [{"id": "r", "expression": None}]}, {"cells": [{"expression": "1"}]},
                    {"inputs": [{"unit": "", "value": 1}]}):
            self.assertEqual(reject_why(bad), "syntax", bad)
        model = calc.compile_spec(spec_of(("c1", "x+1"), ("c2", "iferror(x,5)"), ("c3", "q"), inputs=[("x", "", 1), ("q", "kg", 3)]))
        for override in ("7", True, [1], {"a": 1}):
            result = calc.evaluate(model, {"x": override, "q": override})
            self.assertEqual([result.nodes[k].err and result.nodes[k].err["code"] for k in ("c1", "c2", "c3")],
                             ["TYPE", None, "TYPE"], override)
        for unit, why in ((" kg", "bad-unit"), ("kg ", "bad-unit"), ("\tkg", "bad-unit"), ("%%", "unknown-unit")):
            self.assertEqual(reject_why(spec_of(("r", "1[kg]", unit))), why, unit)

    def test_missing_id_is_syntax_but_a_present_bad_id_is_bad_id(self):
        column = {"tables": [{"id": "t", "rows": [], "columns": [{"kind": "number"}]}]}
        for spec in ({"cells": [{"expression": "1"}]}, {"cells": [{"id": None, "expression": "1"}]},
                     {"inputs": [{"unit": "", "value": 1}]}, {"tables": [{"rows": [], "columns": []}]}, column):
            self.assertEqual(reject_why(spec), "syntax", spec)
        for bad in (5, 1.5, True, [], {}, "", "Aa", "1a", "a-b", "a" * 25):
            for key in ("cells", "inputs"):
                item = {"id": bad, "expression": "1", "unit": "", "value": 1}
                self.assertEqual(reject_why({key: [item]}), "bad-id", (key, bad))
            col = {"tables": [{"id": "t", "rows": [], "columns": [{"id": bad, "kind": "number"}]}]}
            self.assertEqual(reject_why(col), "bad-id", bad)

    def test_d9_unit_group_algebra(self):
        shown = text_of(("c1", "3[km/h/s]*2[s]"), ("c2", "2[s]*5[km/h/s]"), ("c3", "1[m*km]"), ("c4", "2[km*m]", "", 3),
                        ("c5", "5[h*min]", "", 4), ("c6", "1[kg/g]"), ("c7", "272[kg^2/s/g]"), ("c8", "2[km]*3[m]", "", 3),
                        ("c9", "3[m]*2[km]"), ("c10", "1[m/km]", "", 3), ("c11", "2[kg*m]"))
        self.assertEqual(shown, ["6.00 km/h", "10.00 km/h", "1000.00 m^2", "0.002 km^2", "0.0833 h^2", "1000.00",
                                 "272000.00 kg/s", "0.006 km^2", "6000.00 m^2", "0.001", "2.00 kg*m"])

    def test_d9_identical_symbols_cancel_without_float_noise(self):
        model, result = run(("r", "3[km/h/s]*2[s]"))
        node = result.nodes["r"]
        self.assertEqual((node.value, node.unit), (6.0, "km/h"))

    def test_d10_sumproduct_and_aggregates_examine_arguments_left_to_right(self):
        tab = table("t", [("v", "number", ""), ("a", "formula", "", "sqrt(0-v)"), ("b", "text", "")],
                    [["4", "", "x"], ["9", "", "y"]])
        self.assertEqual(self.codes(("c1", "sumproduct(t.a,t.b)"), ("c2", "sumproduct(t.b,t.a)"), ("c3", "sum(t.a,t.b)"),
                                    ("c4", "sum(t.b,t.a)"), tables=[tab]), ["DOMAIN", "TYPE", "DOMAIN", "TYPE"])

    def test_oq20_bad_unit_then_unknown_unit_then_unknown_name(self):
        for text, why in (("5[ABC]+5[kg^0.5]+nosuch", "bad-unit"), ("5[ABC^0]", "bad-unit"), ("5[kg^0.5]+nosuch", "bad-unit"),
                          ("5[ABC]+nosuch", "unknown-unit"), ("nosuch+1", "unknown-name")):
            self.assertEqual(reject_why(spec_of(("r", text))), why, text)

    def test_random_overflow_prone_specs_never_raise(self):
        rng = random.Random(99)
        units = ["m", "km", "mm", "TB", "kB", "g", "kg", "h", "s", "EUR", "%", "Hz", "kWh", "m^9", "TB^9", "mm^9/km^9"]

        def atom():
            return rng.choice(["1e300", "9[%s]" % rng.choice(units), "(2[%s])" % rng.choice(units), "q", "k", "1[%s]" % rng.choice(units)])

        def build(depth):
            if depth == 0 or rng.random() < 0.3:
                return atom()
            x, y = build(depth - 1), build(depth - 1)
            return rng.choice([
                "(%s)^%d" % (x, rng.randint(0, 11)), "%s*%s" % (x, y), "%s/%s" % (x, y), "%s+%s" % (x, y),
                "to(%s,[%s])" % (x, rng.choice(units)), "num(%s,[%s])" % (x, rng.choice(units)),
                "round(%s,%d)" % (x, rng.randint(0, 11)), "sqrt(%s)" % x, "sum(%s,%s)" % (x, y),
                "clamp(%s,%s,%s)" % (x, y, atom()), "min(%s,%s)" % (x, y)])
        for _ in range(1500):
            spec = spec_of(("r", build(3), rng.choice(["", "m", "kg", "%", "kWh", "EUR"])),
                           inputs=[("q", rng.choice(["", "km", "g", "TB"]), rng.choice([1e308, 1e-300, 7, 0, None])),
                                   ("k", rng.choice(["", "m", "kg"]), rng.choice([1e200, 3, -2.5]))])
            try:
                model = calc.compile_spec(spec)
            except calc.CalcError:
                continue
            result = calc.evaluate(model)
            for nid in model.order:
                calc.format_cell(model, result, nid)
                calc.provenance(model, result, nid)


class SourceHygieneTests(unittest.TestCase):
    """The engine must stay free of dynamic code, I/O and unicode-aware digit tests."""

    def test_no_dynamic_code_or_io(self):
        source = (ROOT / "ai_calc.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        banned = {"eval", "exec", "compile", "open", "getattr", "setattr", "__import__", "globals", "locals", "vars", "input"}
        called = {n.func.id for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertEqual(called & banned, set())
        imports = {a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
        imports |= {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        self.assertLessEqual(imports, {"heapq", "math", "re", "decimal", "types"})
        for pattern in (r"\.isdigit\(", r"\.isnumeric\(", r"\.isdecimal\(", r"\\d", r"\\w", r"\\s"):
            self.assertIsNone(re.search(pattern, source), pattern)

    def test_no_module_level_mutable_state(self):
        tree = ast.parse((ROOT / "ai_calc.py").read_text(encoding="utf-8"))
        for node in tree.body:
            if isinstance(node, ast.Assign):
                value = node.value
                self.assertNotIsInstance(value, (ast.List, ast.Dict, ast.Set, ast.ListComp, ast.DictComp, ast.SetComp),
                                         ast.dump(node.targets[0]))


# ---------------------------------------------------------------------------------------------
# Part 3: the seeded differential fuzz. tests/gen_calc_fuzz.py invents the specs; tests/CalcFuzz.js
# stores what THIS engine says about them; tst_AiCalc.qml replays the same file on the JS engine.
FUZZ_PATH = ROOT / "tests" / "CalcFuzz.js"
_FUZZ = {}


def fuzz_built():
    """Regenerate the fuzz set in memory (once per process): module, rows, engine crashes, skipped, text."""
    if not _FUZZ:
        spec = importlib.util.spec_from_file_location("gen_calc_fuzz", ROOT / "tests" / "gen_calc_fuzz.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        rows, bugs, skipped = gen.build_cases(calc)
        _FUZZ.update(gen=gen, rows=rows, bugs=bugs, skipped=skipped, text=gen.render(rows))
    return _FUZZ


def fuzz_file_rows():
    text = FUZZ_PATH.read_text(encoding="utf-8")
    return json.loads(text.split("\n", 1)[1].split("var CASES =\n", 1)[1])


def node_view(model, result):
    """Everything observable about a pass, keyed by node id: (display text, error code)."""
    return {nid: (calc.format_cell(model, result, nid), n.err["code"] if n.err else None)
            for nid, n in result.nodes.items()}


def has_limit(view):
    return any(code == "LIMIT" for _, code in view.values())


class FuzzDifferentialTests(unittest.TestCase):
    """CalcFuzz.js is generated, never stale, and this engine reproduces every row of it."""

    def test_checked_in_file_is_exactly_what_the_generator_produces(self):
        fresh, on_disk = fuzz_built()["text"], FUZZ_PATH.read_text(encoding="utf-8")
        if fresh != on_disk:
            for n, (a, b) in enumerate(zip(fresh.split("\n"), on_disk.split("\n"))):
                if a != b:
                    self.fail("CalcFuzz.js is stale (first difference at line %d); rerun python3 tests/gen_calc_fuzz.py\n"
                              "generator: %s\nfile:      %s" % (n + 1, a[:300], b[:300]))
            self.fail("CalcFuzz.js is stale (different length); rerun python3 tests/gen_calc_fuzz.py")

    def test_the_python_engine_never_raises_outside_calc_error(self):
        # A row whose evaluation crashes has no expected output; the generator drops it and lists it here.
        crashes = ["%s: %s" % (tag, why) for tag, why, _ in fuzz_built()["bugs"]]
        self.assertEqual(crashes, [], "engine exceptions on fuzz specs (ai_calc.py bugs)")

    def test_file_shape_and_coverage(self):
        text = FUZZ_PATH.read_text(encoding="utf-8")
        self.assertTrue(text.startswith(".pragma library\n/*"))
        self.assertTrue(text.isascii())
        self.assertFalse(text.rstrip().endswith(";"))
        self.assertLess(len(text.encode("ascii")), 1_500_000)
        rows = fuzz_file_rows()
        self.assertTrue(1500 <= len(rows) <= 3000, len(rows))
        self.assertEqual(len({r["tag"] for r in rows}), len(rows))
        codes, whys = {}, {}
        for r in rows:
            if r["compile"] == "reject":
                whys[r["why"]] = whys.get(r["why"], 0) + 1
            else:
                seen = {e["err"] for e in r["expect"].values() if e["err"]}
                for code in seen:
                    codes[code] = codes.get(code, 0) + 1
        for code in calc.ERROR_CODES:
            self.assertGreaterEqual(codes.get(code, 0), 10, "too few rows exercise " + code)
        self.assertGreaterEqual(len(whys), 18, sorted(whys))
        self.assertGreaterEqual(sum(1 for r in rows if r["compile"] == "ok"), 1400)
        self.assertGreaterEqual(sum(1 for r in rows if "env" in r), 40)
        self.assertGreaterEqual(sum(1 for r in rows if "approx" in r), 50)
        self.assertEqual(len(fuzz_built()["skipped"]), len({t for t, _ in fuzz_built()["skipped"]}))

    def test_python_reproduces_every_row(self):
        for index, row in enumerate(fuzz_file_rows()):
            with self.subTest(index=index, tag=row["tag"]):
                try:
                    model = calc.compile_spec(copy.deepcopy(row["spec"]))
                except calc.CalcError as error:
                    self.assertEqual(row["compile"], "reject", error.msg)
                    self.assertEqual(error.why, row["why"], error.msg)
                    continue
                self.assertEqual(row["compile"], "ok", "accepted a spec the file rejects")
                result = calc.evaluate(model, copy.deepcopy(row["inputs"]), copy.deepcopy(row.get("env")))
                for node_id, want in row["expect"].items():
                    node = result.nodes[node_id]
                    self.assertEqual((calc.format_cell(model, result, node_id), node.err["code"] if node.err else None),
                                     (want["text"], want["err"]), node_id)

    def test_evaluation_order_independence_over_shuffled_declarations(self):
        checked = 0
        for index, row in enumerate(fuzz_file_rows()):
            if row["compile"] != "ok":
                continue
            rng = random.Random(index)
            spec = copy.deepcopy(row["spec"])
            for key in ("inputs", "tables", "cells"):
                rng.shuffle(spec[key])
            first = calc.compile_spec(copy.deepcopy(row["spec"]))
            second = calc.compile_spec(spec)
            a = node_view(first, calc.evaluate(first, copy.deepcopy(row["inputs"]), copy.deepcopy(row.get("env"))))
            b = node_view(second, calc.evaluate(second, copy.deepcopy(row["inputs"]), copy.deepcopy(row.get("env"))))
            if has_limit(a) or has_limit(b):
                continue        # only which node hits LIMIT may depend on the order
            checked += 1
            self.assertEqual(a, b, (index, row["tag"]))
        self.assertGreater(checked, 1300)

    def test_incremental_equals_full_recompute_on_fuzz_specs(self):
        pool = [None, 0, 1, -1, 2.5, 100, 1e200, 0.1, 1e-9, -3, 7]
        checked = 0
        for index, row in enumerate(fuzz_file_rows()):
            if row["compile"] != "ok" or not row["spec"]["inputs"] or index % 3:
                continue
            rng = random.Random(index * 7 + 1)
            model = calc.compile_spec(copy.deepcopy(row["spec"]))
            ids = [i["id"] for i in row["spec"]["inputs"]]
            env = copy.deepcopy(row.get("env"))
            values = dict(row["inputs"])
            prev = calc.evaluate(model, dict(values), env)
            for step in range(10):
                for _ in range(rng.randint(1, 2)):
                    values[rng.choice(ids)] = rng.choice(pool)
                incremental = calc.evaluate(model, dict(values), copy.deepcopy(env), prev)
                full = calc.evaluate(model, dict(values), copy.deepcopy(env))
                self.assertEqual((node_view(model, incremental), incremental.steps),
                                 (node_view(model, full), full.steps), (index, row["tag"], step, values))
                prev = incremental
            checked += 1
        self.assertGreater(checked, 300)


class UnitRoundTripTests(unittest.TestCase):
    """to(to(x,[u]),[u0]) returns x within 1e-12 for every ordered pair of units of one dimension."""

    VALUES = (1, 0.37, 123456.789, -42.5, 0.001, 7e5, 3.0e-7, 98765432.1)

    def test_every_unit_pair_within_a_family(self):
        families = fuzz_built()["gen"].FAMILIES
        pairs = 0
        for name, units in families.items():
            for u0 in units:
                for u in units:
                    for v in self.VALUES:
                        spec = {"inputs": [{"id": "x", "unit": u0, "value": v}], "tables": [],
                                "cells": [{"id": "own", "expression": "x", "unit": "", "decimals": 10},
                                          {"id": "back", "expression": "to(to(x,[%s]),[%s])" % (u, u0), "unit": "", "decimals": 10}]}
                        model = calc.compile_spec(spec)
                        result = calc.evaluate(model)
                        own, back = result.nodes["own"], result.nodes["back"]
                        self.assertIsNone(back.err, (u0, u, v))
                        self.assertEqual(back.unit, own.unit, (u0, u, v))
                        self.assertLessEqual(abs(back.value - v), 1e-12 * abs(v), (u0, u, v, back.value))
                        pairs += 1
        self.assertGreater(pairs, 2000)

    def test_cross_family_conversion_is_a_unit_error_both_ways(self):
        for src, dst in (("kg", "m"), ("s", "Hz"), ("EUR", "USD"), ("B", "px"), ("km/h", "m"), ("W", "J")):
            model, result = run(("c", "to(1[%s],[%s])" % (src, dst)))
            self.assertEqual(result.nodes["c"].err["code"], "UNIT", (src, dst))


if __name__ == "__main__":
    unittest.main()
