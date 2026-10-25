"""Seeded differential-fuzz generator for the typed computation runtime.

    python3 tests/gen_calc_fuzz.py          rewrites tests/CalcFuzz.js
    python3 tests/gen_calc_fuzz.py --check  exit 1 when the checked-in file is stale

Why: ai_calc.py (Python) and AiCalc.js (QML JS) are written from the same golden
table, which only covers inputs somebody thought of. This module invents a few
thousand more - random but well-typed specs, deliberately mistyped ones,
overflow/near-zero/domain traps, hostile text - runs each through the PYTHON
engine, and stores the observable outcome (compile reject slug, or per cell the
display text plus error code). tests/test_ai_calc.py re-runs this generator in
memory and requires the checked-in file to be byte-identical, then replays every
row on Python; tests/tst_AiCalc.qml replays every row on the JS engine. The
expected values are therefore "what Python says", and the file proves the two
engines agree on them.

Determinism: one `random.Random(SEED)`; nothing else is random, no set/dict
iteration feeds a decision, no clock. Bump SEED or COUNT only together with a
regeneration of tests/CalcFuzz.js (the Python suite fails until you do).

File format: same as CalcGolden.js (line 1 `.pragma library`, a block comment,
`var CASES =` on its own line, then ONE pure-JSON array, ASCII, no trailing
semicolon). A row is
    {tag, spec, inputs, [env,] compile:"ok", expect:{id:{text, err}}, [approx]}
 or {tag, spec, inputs, [env,] compile:"reject", why}.
`expect` lists every cell and the first formula-column instances ("t.f#1").
`approx` (1e-12) is set ONLY on rows whose expressions use sqrt or a `^` whose
exponent is not a plain integer literal; there the comparison is relative on the
numeric prefix with the unit suffix exact. Every other row is exact text.

SKIP: rows the two engines disagree on where CalcGolden.js is silent are listed
in SKIP below (match by tag) and are excluded from the file; the report names
each class. Never add to SKIP to hide a golden-pinned disagreement.
"""

import importlib.util
import json
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests" / "CalcFuzz.js"
SEED = 20261008
COUNT = 1800
APPROX = 1e-12

# ---- the skip list -------------------------------------------------------------------------
# CalcGolden.js is SILENT on the behaviours below and the two engines differ, so no engine is "right";
# rows that exercise them are generated, then dropped here (they are listed in the task report as OPEN
# QUESTIONS with minimal reproducers). Disagreements where the golden header SPEAKS are never listed:
# those stay in the file and fail the suite of the engine that is wrong.
#   malformed-shape      containers/entries of the wrong JSON type (non-list sections, non-object entries,
#                        non-string ids/expressions, unknown column kinds, non-list rows): the reject slug
#                        differs (syntax vs empty vs bad-id)
#   input-value-type     an input value or override that is neither a number nor null ("7", true, [], {}):
#                        Python TYPE, JS MISSING
#   unit-text            a declared unit with outer whitespace (" kg": Python bad-unit, JS accepts) or a stray
#                        percent sign ("%%", "ft%2": bad-unit vs unknown-unit)
SKIP_CLASSES = ("malformed-shape", "input-value-type", "unit-text")
#   Tag list (this seed only; regenerate and re-triage if the generator changes):
#   multi-fault          a spec/expression with two independent compile faults; which slug wins (syntax vs
#                        unknown-name/-table/-column, colstat-args vs unit-position, ...) is unpinned
#   quantity-power       sqrt/^ applied to a quantity that is both negative/huge and has an odd unit
#                        exponent (UNIT vs DOMAIN vs RANGE precedence; golden OQ7)
SKIP = {
    # one construct breaking two reject rules at once
    "fz0947-hostile": "multi-fault: two [unit] groups after to() AND a group that cancels to nothing",
    "fz1352-hostile": "multi-fault: nested brackets in a number's unit AND letters glued to the number",
    "fz1391-hostile": "multi-fault: a truncated formula-column expression AND a dangling name",
}


def load_engine():
    spec = importlib.util.spec_from_file_location("ai_calc_for_fuzz", ROOT / "ai_calc.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------- units
FAMILIES = {
    "length": "mm cm m km in ft mi".split(),
    "mass": "g kg lb oz".split(),
    "time": "s min h d wk".split(),
    "data": "B kB MB GB TB KiB MiB GiB TiB".split(),
    "energy": "J Wh kWh".split(),
    "power": "W kW".split(),
    "freq": "Hz GHz".split(),
    "px": ["px"],
    "EUR": ["EUR"], "USD": ["USD"], "GBP": ["GBP"], "JPY": ["JPY"], "CHF": ["CHF"], "PLN": ["PLN"],
    "speed": ["km/h", "m/s", "mi/h", "ft/s"],
    "area": ["m^2", "cm^2", "km^2", "ft^2", "m*m"],
    "accel": ["m/s^2"],
    "eurkg": ["EUR/kg", "EUR/lb", "EUR/g"],
    "usdh": ["USD/h", "USD/min"],
    "eurh": ["EUR/h", "EUR/min", "EUR/d"],
    "drate": ["MB/s", "kB/s", "GB/h", "MiB/s"],
}
FAM_ORDER = sorted(FAMILIES)
SIMPLE = ["length", "mass", "time", "data", "energy", "power", "freq", "px", "EUR", "USD", "GBP", "JPY", "CHF", "PLN"]
UNIT_FAM = {u: f for f in FAM_ORDER for u in FAMILIES[f]}
# (a, b) -> product / quotient family; the right factor converts into the left symbol
MUL = [("speed", "time", "length"), ("power", "time", "energy"), ("length", "length", "area"),
       ("eurh", "time", "EUR"), ("eurkg", "mass", "EUR"), ("usdh", "time", "USD"), ("freq", "time", "n"),
       ("accel", "time", "speed"), ("drate", "time", "data")]
DIV = [("length", "time", "speed"), ("energy", "time", "power"), ("area", "length", "length"),
       ("EUR", "time", "eurh"), ("EUR", "mass", "eurkg"), ("USD", "time", "usdh"), ("speed", "time", "accel"),
       ("data", "time", "drate"), ("length", "speed", "time"), ("energy", "power", "time")]
FAM_WEIGHTS = (["n"] * 9 + ["EUR"] * 4 + ["length"] * 4 + ["mass"] * 4 + ["time"] * 4 + ["USD"] * 2 + SIMPLE
               + ["speed", "eurkg", "eurh", "area"])
COMPOUND_FACTORS = ["m", "kg", "s", "h", "km", "g", "min", "EUR", "USD", "B", "Hz", "W", "px", "lb", "m^2", "kg^2"]
# One unit group never holds two symbols of one dimension (m*km, kg/g): CalcGolden.js is silent on how such
# a group prints and the engines differ (OPEN QUESTION OQ-A in the report), so the generator keeps them apart.
FACTOR_DIM = {"m": "L", "km": "L", "m^2": "L", "kg": "M", "g": "M", "lb": "M", "kg^2": "M", "s": "T", "h": "T", "min": "T",
              "Hz": "T", "EUR": "EUR", "USD": "USD", "B": "B", "W": "W", "px": "P"}

INPUT_NAMES = "x y z a b p q r w v tax rate price qty load n2 k1 k2 base fx lim disc".split()
COL_NAMES = "n f g1 amt qty2 val tot unit_p w2 note".split()
CELL_FORCED = ["c%d" % i for i in range(1, 25)]
NUM_POOL = ["0", "1", "2", "3", "4", "5", "7", "10", "12", "100", "1000", "0.5", "0.25", "1.5", "2.5", "12.5", "3.14159",
            "0.1", "0.2", "0.3", "9.81", "99.99", "1234.5678", "0.000001", "1000000", "123456789.123456",
            "0.000000000000000000001", "100000000000000000000", "999999999999999", "1.005", "2.675"]
HOSTILE_CHARS = ["@", "#", "$", "~", "\\", "\"", "'", ";", ":", "!", "&", "|", "`", "{", "}", "?", "=", "_", "\n",
                 "ÿ", "１", "٣", "−", " ", "а", "е", "²", "√",
                 "\U0001f600", "​", "\x00", "\x7f"]
HOSTILE_TAILS = [")", "(", ",", "+", "^", "[kg]", " and ", "<1<2", "..", "1e3", "1_000", ".5", "5.", "0x10", "[", "]",
                 "()", "(,)", "if(", "x.y", "t.n", "T.n", "sum(", "--", "!=", "=", "&&", "||", "%", "%%", "[]", "[ ]"]
HOSTILE_UNITS = ["[ kg]", "[kg ]", "[kg^2]", "[kg^-1]", "[kg^10]", "[kg/]", "[ ]", "[]", "[kg*]", "[Kg]", "[ABC]",
                 "[EUR/EUR]", "[m^0]", "[(kg)]", "[kg^1.5]", "[kg*m/s^2]", "[1/s]", "[C]", "[F]", "[K]", "[kg[kg]]",
                 "[%]", "[km/h]", "[m^3]", "[XYZ]", "[ZWL]", "[HKD]", "[EURO]", "[eur]"]
HOSTILE_NAMES = ["sin", "pi", "e", "if", "or", "and", "not", "true", "false", "kg", "m", "min", "max", "Sum", "SUM",
                 "x1y", "a_b", "_a", "a__b", "aaaaaaaaaaaaaaaaaaaaaaaaa", "T", "t", "u", "c0", "c99"]
RESERVED_IDS = ["sum", "or", "and", "not", "if", "kg", "min", "max", "h", "m", "to", "num", "in", "px", "d", "colstat"]
BAD_IDS = ["A", "1x", "a-b", "", "x" * 25, "ab cd", "\u00e9", "_x", "x.y", "x[", None, 5]
BAD_UNITS = ["foo", "kg^0", "KG", "EUR/", "%%", "Celsius", "C", "kg**2", "kg^", "(kg)", " kg", "kg kg", "kg^10", "ABC",
             "kg/ ", "*kg", "kg*", "1/kg", "m^-1", "kg^1.5"]

KINDS = [("typed", 40), ("typed-bad", 14), ("table", 14), ("units", 6), ("hostile", 10), ("spec-hostile", 3),
         ("colstat", 3), ("limit", 3), ("pool", 6)]


class Cx:
    """The names a case offers to expressions (types are generator-side labels only)."""

    def __init__(self):
        self.inputs = []      # (id, family)
        self.cells = []       # (id, family) - already generated cells
        self.tables = []      # dict(id, cols=[dict(id, kind, fam)], nrows)
        self.row = None       # (table index, [(col id, family)]) while generating a formula column
        self.colstat = False


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.p_bad = 0.0
        self.sp = 0
        self.par = 0.0
        self.cx = Cx()

    # ---------------------------------------------------------------- tiny helpers
    def chance(self, p):
        return self.r.random() < p

    def pick(self, seq):
        return seq[self.r.randrange(len(seq))]

    def weighted(self, pairs):
        total = sum(w for _, w in pairs)
        x = self.r.random() * total
        for item, w in pairs:
            x -= w
            if x < 0:
                return item
        return pairs[-1][0]

    def S(self):
        if self.sp == 2:
            return self.pick(["", " ", "  ", "\t", " \t"])
        return " " if self.sp == 1 else ""

    # ---------------------------------------------------------------- nodes
    # node: ("lit", text) | ("ref", text) | ("un", x) | ("not", x) | ("bin", op, l, r) | ("call", name, [args])
    def prec(self, n):
        if n[0] in ("lit", "ref", "call"):
            return 9
        if n[0] == "un":
            return 7
        if n[0] == "not":
            return 3
        return {"or": 1, "and": 2, "<": 4, "<=": 4, ">": 4, ">=": 4, "==": 4, "!=": 4,
                "+": 5, "-": 5, "*": 6, "/": 6, "%": 6, "^": 8}[n[1]]

    def show(self, n, need):
        s = self.raw(n)
        if self.prec(n) < need or (n[0] in ("bin", "un", "not") and self.chance(self.par)):
            s = "(" + s + ")"
            if self.chance(0.03):
                s = "(" + s + ")"
        return s

    def raw(self, n):
        k = n[0]
        if k in ("lit", "ref"):
            return n[1]
        if k == "un":
            return "-" + self.S() + self.show(n[1], 7)
        if k == "not":
            return "not " + self.show(n[1], 3)
        if k == "call":
            sep = "," + self.S()
            return n[1] + "(" + self.S() + sep.join(self.show(a, 0) for a in n[2]) + self.S() + ")"
        op = n[1]
        if op == "^":
            left, right = 9, 7
        elif op in ("or",):
            left, right = 1, 2
        elif op == "and":
            left, right = 2, 3
        elif op in ("<", "<=", ">", ">=", "==", "!="):
            left = right = 5
        else:
            p = self.prec(n)
            left, right = p, p + 1
        word = op in ("or", "and")
        sp = " " if word else self.S()
        return self.show(n[2], left) + sp + op + sp + self.show(n[3], right)

    def text(self, n):
        return self.show(n, 0)

    # ---------------------------------------------------------------- literals and leaves
    def num_text(self):
        r = self.r.random()
        if r < 0.55:
            return self.pick(NUM_POOL[:20])
        if r < 0.8:
            return str(self.r.randrange(0, 300))
        if r < 0.92:
            return "%d.%d" % (self.r.randrange(0, 2000), self.r.randrange(0, 100))
        return self.pick(NUM_POOL)

    def lit(self, fam):
        if fam == "n":
            return ("lit", self.num_text())
        if fam == "b":
            return self.cmp_node(1)
        return ("lit", self.num_text() + "[" + self.pick(FAMILIES[fam]) + "]")

    def input_pool(self, fam):
        return [i for i, f in self.cx.inputs if f == fam]

    def leaf(self, fam):
        cx = self.cx
        if fam == "b":
            return self.cmp_node(0)
        opts = [("lit", 3)]
        ins = self.input_pool(fam)
        if ins:
            opts.append(("input", 9))
        cells = [i for i, f in cx.cells if f == fam]
        if cells:
            opts.append(("cell", 7))
        if cx.row:
            cols = [c for c, f in cx.row[1] if f == fam]
            if cols:
                opts.append(("col", 8))
        if self.aggregate_sources(fam):
            opts.append(("agg", 3))
        if fam == "n" and cx.colstat:
            opts.append(("colstat", 3))
        if fam == "n" and cx.tables:
            opts.append(("count", 1))
        kind = self.weighted(opts)
        if kind == "input":
            return ("ref", self.pick(ins))
        if kind == "cell":
            return ("ref", self.pick(cells))
        if kind == "col":
            return ("ref", self.pick([c for c, f in cx.row[1] if f == fam]))
        if kind == "agg":
            return self.aggregate(fam)
        if kind == "colstat":
            return ("call", "colstat", [("lit", str(self.r.randrange(1, 4))),
                                        ("lit", self.pick(["count", "empty", "min", "max", "sum", "mean"]))])
        if kind == "count":
            srcs = [t["id"] + "." + c["id"] for t in self.visible_tables() for c in t["cols"]]
            return ("call", "count", [("ref", self.pick(srcs))]) if srcs else self.lit(fam)
        return self.lit(fam)

    def visible_tables(self):
        cx = self.cx
        if cx.row:
            return cx.tables[:cx.row[0]]
        return cx.tables

    def aggregate_sources(self, fam):
        out = []
        for t in self.visible_tables():
            for c in t["cols"]:
                if c["kind"] != "text" and c["fam"] == fam:
                    out.append(t["id"] + "." + c["id"])
        return out

    def aggregate(self, fam):
        srcs = self.aggregate_sources(fam)
        f = self.weighted([("sum", 5), ("mean", 3), ("median", 3), ("min", 0)])
        if f == "min":
            f = "sum"
        args = [("ref", self.pick(srcs))]
        if self.chance(0.25):
            extra = self.r.randrange(1, 4)
            for _ in range(extra):
                args.append(("ref", self.pick(srcs)) if self.chance(0.5) else self.gen(fam, 1))
            if self.chance(0.3):
                self.r.shuffle(args)
        return ("call", f, args)

    # ---------------------------------------------------------------- compound productions
    def cmp_node(self, d):
        fam = self.weighted([("n", 6), ("length", 1), ("mass", 1), ("EUR", 2), ("time", 1), ("data", 1), ("speed", 1)])
        a, b = self.gen(fam, d), self.gen(fam, d)
        if self.chance(0.12):
            b = ("lit", "0")
        op = self.pick(["<", "<=", ">", ">=", "==", "!="])
        return ("bin", op, a, b)

    def wrong(self, fam):
        pool = ["n", "b"] + [self.pick(SIMPLE)]
        if fam in pool:
            pool.remove(fam)
        return self.pick(pool)

    def gen(self, fam, d):
        if self.p_bad and self.chance(self.p_bad):
            fam = self.wrong(fam)
        if d <= 0 or self.chance(0.22):
            return self.leaf(fam)
        return self.compound(fam, d - 1)

    def int_lit(self, lo, hi):
        return ("lit", str(self.r.randrange(lo, hi + 1)))

    def compound(self, fam, d):
        if fam == "b":
            return self.bool_node(d)
        if fam == "n":
            return self.number_node(d)
        return self.quantity_node(fam, d)

    def bool_node(self, d):
        k = self.weighted([("cmp", 10), ("and", 3), ("or", 3), ("not", 3)])
        if k == "cmp":
            return self.cmp_node(d)
        if k == "not":
            return ("not", self.gen("b", d))
        return ("bin", k, self.gen("b", d), self.gen("b", d))

    def common(self, fam, d):
        k = self.weighted([("if", 4), ("iferror", 4), ("minmax", 4), ("clamp", 2), ("unary", 4), ("round", 4)])
        if k == "if":
            return ("call", "if", [self.gen("b", d), self.gen(fam, d), self.gen(fam, d)])
        if k == "iferror":
            return ("call", "iferror", [self.gen(fam, d), self.gen(fam, d)])
        if k == "minmax":
            return ("call", self.pick(["min", "max"]), [self.gen(fam, d) for _ in range(self.r.randrange(2, 5))])
        if k == "clamp":
            return ("call", "clamp", [self.gen(fam, d) for _ in range(3)])
        if k == "round":
            return ("call", "round", [self.gen(fam, d), self.int_lit(0, 6)])
        return ("call", self.pick(["abs", "floor", "ceil"]), [self.gen(fam, d)])

    def number_node(self, d):
        k = self.weighted([("bin", 40), ("neg", 5), ("common", 18), ("sqrt", 3), ("pow", 6), ("num", 5), ("ratio", 5),
                           ("agg", 6), ("sumproduct", 2), ("lit", 1), ("trap", 9), ("anycol", 6)])
        if k == "anycol":
            return self.any_column_aggregate()
        if k == "trap":
            return self.trap(d)
        if k == "bin":
            op = self.weighted([("+", 5), ("-", 4), ("*", 5), ("/", 4), ("%", 1)])
            return ("bin", op, self.gen("n", d), self.gen("n", d))
        if k == "neg":
            return ("un", self.gen("n", d))
        if k == "common":
            return self.common("n", d)
        if k == "sqrt":
            return ("call", "sqrt", [self.gen("n", d)])
        if k == "pow":
            base = self.gen("n", d)
            e = self.weighted([("int", 6), ("neg", 2), ("frac", 2), ("expr", 1)])
            if e == "int":
                ex = self.int_lit(0, 6)
            elif e == "neg":
                ex = ("un", self.int_lit(1, 4))
            elif e == "frac":
                ex = ("lit", self.pick(["0.5", "1.5", "0.25", "2.5", "0.333"]))
            else:
                ex = self.gen("n", 1)
            return ("bin", "^", base, ex)
        if k == "num":
            fam = self.pick(SIMPLE + ["speed", "area"])
            return ("call", "num", [self.gen(fam, d), ("lit", "[" + self.pick(FAMILIES[fam]) + "]")])
        if k == "ratio":
            fam = self.pick(SIMPLE)
            return ("bin", "/", self.gen(fam, d), self.gen(fam, d))
        if k == "agg":
            srcs = self.aggregate_sources("n")
            if srcs:
                return self.aggregate("n")
            if self.visible_tables():
                t = self.pick(self.visible_tables())
                if t["cols"]:
                    c = self.pick(t["cols"])
                    return ("call", self.pick(["count", "sum", "mean", "median"]), [("ref", t["id"] + "." + c["id"])])
            return self.leaf("n")
        if k == "sumproduct":
            return self.sumproduct()
        return self.lit("n")

    def trap(self, d):
        """Division by zero or by almost zero, overflow, sqrt/pow domain errors."""
        a = self.gen("n", d)
        k = self.weighted([("div0", 3), ("near", 2), ("big", 3), ("sqrtneg", 2), ("negpow", 2), ("zeropow", 1), ("mod0", 1),
                           ("huge", 2), ("tiny", 1)])
        if k == "div0":
            b = self.gen("n", 1)
            return ("bin", "/", a, ("bin", "-", b, b)) if self.chance(0.6) else ("bin", self.pick(["/", "%"]), a, ("lit", self.pick(["0", "0.0"])))
        if k == "near":
            return ("bin", "/", a, ("lit", self.pick(["0.00000000000000000001", "0.000000000000001", "0.0000000000000000000000000001"])))
        if k == "big":
            return ("bin", "*", a, ("bin", "^", ("lit", "10"), ("lit", self.pick(["100", "200", "300", "307", "308", "309", "400"]))))
        if k == "sqrtneg":
            return ("call", "sqrt", [("un", ("bin", "+", ("call", "abs", [a]), ("lit", "1")))])
        if k == "negpow":
            return ("bin", "^", ("un", ("bin", "+", ("call", "abs", [a]), ("lit", "1"))), ("lit", self.pick(["0.5", "1.5", "0.3", "2.5"])))
        if k == "zeropow":
            return ("bin", "^", ("lit", "0"), ("un", self.int_lit(1, 3)))
        if k == "mod0":
            return ("bin", "%", a, ("bin", "-", ("lit", "2"), ("lit", "2")))
        if k == "huge":
            return ("bin", "^", a, ("lit", self.pick(["50", "100", "400", "1000", "3000"])))
        return ("bin", "/", a, ("bin", "^", ("lit", "10"), ("lit", self.pick(["300", "310", "400"]))))

    def any_column_aggregate(self):
        """sum/mean/median/count/sumproduct over ANY column, text ones and empty tables included."""
        tabs = self.visible_tables()
        if not tabs:
            return self.leaf("n")
        t = self.pick(tabs)
        if not t["cols"]:
            return self.leaf("n")
        f = self.weighted([("sum", 3), ("mean", 3), ("median", 3), ("count", 2), ("sumproduct", 3)])
        a = t["id"] + "." + self.pick(t["cols"])["id"]
        if f == "sumproduct":
            return ("call", f, [("ref", a), ("ref", t["id"] + "." + self.pick(t["cols"])["id"])])
        return ("call", f, [("ref", a)])

    def sumproduct(self):
        tabs = [t for t in self.visible_tables() if len([c for c in t["cols"] if c["kind"] != "text"]) >= 1]
        if not tabs:
            return self.lit("n")
        t = self.pick(tabs)
        cols = [c for c in t["cols"]]
        a, b = self.pick(cols), self.pick(cols)
        return ("call", "sumproduct", [("ref", t["id"] + "." + a["id"]), ("ref", t["id"] + "." + b["id"])])

    def quantity_node(self, fam, d):
        k = self.weighted([("addsub", 22), ("mulscale", 12), ("mulfam", 8), ("divscale", 6), ("to", 12), ("common", 18),
                           ("neg", 3), ("agg", 5), ("zero", 2), ("mod", 1), ("pow", 1), ("trap", 1)])
        if k == "addsub":
            return ("bin", self.pick(["+", "-"]), self.gen(fam, d), self.gen(fam, d))
        if k == "zero":
            z = ("lit", "0")
            a = self.gen(fam, d)
            return ("bin", self.pick(["+", "-"]), z, a) if self.chance(0.5) else ("bin", self.pick(["+", "-"]), a, z)
        if k == "mulscale":
            a, b = self.gen(fam, d), self.gen("n", d)
            return ("bin", "*", a, b) if self.chance(0.5) else ("bin", "*", b, a)
        if k == "divscale":
            return ("bin", "/", self.gen(fam, d), self.gen("n", d))
        if k == "mulfam":
            muls = [(a, b) for a, b, c in MUL if c == fam]
            divs = [(a, b) for a, b, c in DIV if c == fam]
            if muls and (not divs or self.chance(0.5)):
                a, b = self.pick(muls)
                if self.chance(0.3):
                    a, b = b, a
                return ("bin", "*", self.gen(a, d), self.gen(b, d))
            if divs:
                a, b = self.pick(divs)
                return ("bin", "/", self.gen(a, d), self.gen(b, d))
            return ("bin", "*", self.gen(fam, d), self.gen("n", d))
        if k == "to":
            arg = self.gen(fam, d)
            if self.chance(0.12):       # push the converted value towards the float64 edge
                arg = ("bin", "*", arg, ("bin", "^", ("lit", "10"), ("lit", self.pick(["290", "300", "305", "307", "308"]))))
            return ("call", "to", [arg, ("lit", "[" + self.pick(FAMILIES[fam]) + "]")])
        if k == "common":
            return self.common(fam, d)
        if k == "neg":
            return ("un", self.gen(fam, d))
        if k == "agg":
            if self.aggregate_sources(fam):
                return self.aggregate(fam)
            return self.leaf(fam)
        if k == "mod":
            return ("bin", "%", self.gen(fam, d), self.gen(fam, d))
        if k == "trap":
            b = self.gen(fam, 1)
            return ("bin", "/", self.gen(fam, d), ("bin", "-", b, b))
        if fam in ("area", "length", "mass", "time"):
            if fam == "length":
                return ("call", "sqrt", [self.gen("area", d)])
            return ("bin", "^", self.gen(fam, d), self.int_lit(1, 2)) if fam == "area" else self.leaf(fam)
        return self.leaf(fam)

    # ---------------------------------------------------------------- unit-algebra expressions
    def unit_chain(self, d):
        """A product/quotient of quantities over arbitrary atoms (the unit text is the point)."""
        n = self.r.randrange(2, 5)
        node = self.chain_leaf()
        for _ in range(n - 1):
            op = self.pick(["*", "/", "*", "/", "+"])
            node = ("bin", op, node, self.chain_leaf() if op != "+" else node)
        k = self.weighted([("plain", 6), ("to", 3), ("num", 2), ("round", 2), ("cmp", 1)])
        if k == "to":
            tgt = self.pick(["m*kg/s^2", "J", "km/h", "kg*m", "1/s", "EUR/h", "m^2", "GB/h", "kWh", "W", "N"])
            node = ("call", "to", [node, ("lit", "[" + tgt + "]")])
        elif k == "num":
            node = ("call", "num", [node, ("lit", "[" + self.pick(["m*kg/s^2", "J", "km/h", "kg*m", "1/s", "m^2", "W", "s"]) + "]")])
        elif k == "round":
            node = ("call", "round", [node, self.int_lit(0, 4)])
        elif k == "cmp":
            node = ("bin", self.pick(["<", ">", "==", "!="]), node, self.chain_leaf())
        return node

    def chain_leaf(self):
        r = self.r.random()
        atom = self.pick(COMPOUND_FACTORS)
        if r < 0.15:
            return ("lit", self.num_text())
        if r < 0.3 and self.cx.inputs:
            return ("ref", self.pick(self.cx.inputs)[0])
        group, dims = atom, [FACTOR_DIM[atom]]
        for p in (0.35, 0.1):
            if self.chance(p):
                other = self.pick([f for f in COMPOUND_FACTORS if FACTOR_DIM[f] not in dims])
                dims.append(FACTOR_DIM[other])
                group += self.pick(["/", "*"]) + other
        return ("lit", self.num_text() + "[" + group + "]")

    # ---------------------------------------------------------------- spec pieces
    def value_pool(self, fam):
        r = self.r.random()
        if r < 0.07:
            return None
        if r < 0.40:
            return self.r.randrange(0, 50)
        if r < 0.55:
            return self.r.randrange(-50, 0)
        if r < 0.80:
            return round(self.r.uniform(-100, 1000), self.r.randrange(0, 5))
        if r < 0.86:
            return self.pick([0, 0.1, 0.2, 0.3, 1 / 3, 2 / 3, 1e-9, 1e-300, 5e-324, -1e-20])
        if r < 0.93:
            return self.pick([1e6, 123456789, 1e15, 1e21, 1e100, 1e154, 1e200, 1e308, -1e308, 1.7976931348623157e308])
        return self.pick([0, 0, 1, -1, 1.005, 2.675, 100, 12.5])

    def make_inputs(self, n):
        names = list(INPUT_NAMES)
        self.r.shuffle(names)
        out = []
        for i in range(n):
            fam = self.pick(FAM_WEIGHTS)
            unit = "" if fam == "n" else self.pick(FAMILIES[fam])
            if fam == "n" and self.chance(0.07):
                unit = "%"
            out.append({"id": names[i], "unit": unit, "value": self.value_pool(fam)})
            self.cx.inputs.append((names[i], fam))
        return out

    def cell_string(self, fam, junk):
        r = self.r.random()
        if r < junk * 0.5:
            return self.pick(["", "", "  ", "\t", " "])
        if r < junk:
            return self.pick(["abc", "1,5", "5 kg", "1 000", "EUR5", "1.000,5", "--1", "1e999", "-1e999", "0x10", "1_0",
                              "٣", " 5", "5 ", "1e", "e5", ".", "+", "-", "1.", "1..2", "NaN", "inf", "−" "5"])
        r = self.r.random()
        if r < 0.5:
            return str(self.r.randrange(-20, 200))
        if r < 0.75:
            return "%.*f" % (self.r.randrange(1, 4), self.r.uniform(-50, 500))
        return self.pick(["+3", ".5", "1e3", "-0", "  7 ", "0", "0.0", "1E2", "2.50", "-.25", "00012", "1e-3", "123456789012345678",
                          "1e308", "-1e308", "0.1", "0.2", "0.3", "1.005", "2.675", " 5\t", "5\n"])

    def make_table(self, tid, index, ncols_hint=None, nrows=None, junk=0.15):
        cx = self.cx
        t = {"id": tid, "cols": [], "nrows": 0}
        ncol = ncols_hint or self.weighted([(2, 3), (3, 4), (4, 2), (5, 1)])
        names = [c for c in COL_NAMES if c not in [i for i, _ in cx.inputs] and c != tid]
        self.r.shuffle(names)
        cols = []
        for j in range(ncol):
            kind = self.weighted([("number", 6), ("text", 1), ("formula", 3)])
            if j == 0 and kind == "formula":
                kind = "number"
            if kind == "formula" and not any(c["kind"] == "number" for c in cols):
                kind = "number"
            fam = self.weighted([("n", 4), ("length", 1), ("mass", 2), ("EUR", 3), ("time", 1), ("USD", 1), ("data", 1)])
            c = {"id": names[j], "kind": kind, "fam": fam if kind != "text" else "n",
                 "unit": "" if fam == "n" or kind == "text" else self.pick(FAMILIES[fam]), "expression": ""}
            cols.append(c)
        n = nrows if nrows is not None else self.weighted([(0, 3), (1, 2), (2, 3), (3, 4), (4, 2), (6, 1)])
        t["nrows"] = n
        rows = [["" for _ in cols] for _ in range(n)]
        for j, c in enumerate(cols):
            if c["kind"] == "number":
                for i in range(n):
                    rows[i][j] = self.cell_string("n", junk)
            elif c["kind"] == "text":
                for i in range(n):
                    rows[i][j] = self.pick(["", "apple", "pear", "x 1", "  ", "7", "kg"])
        t["cols"], t["rows"] = cols, rows
        return t

    def formula_columns(self, ti):
        """Fill the expressions of formula columns (needs the table registered in cx)."""
        cx = self.cx
        t = cx.tables[ti]
        done = []
        for c in t["cols"]:
            if c["kind"] == "formula":
                cx.row = (ti, [(d["id"], d["fam"]) for d in done if d["kind"] != "text"])
                node = self.gen(c["fam"], 2)
                c["expression"] = self.text(node)
                if c["fam"] != "n" and self.chance(0.3):
                    c["unit"] = self.pick(FAMILIES[c["fam"]])
                elif c["fam"] == "n" and self.chance(0.08):
                    c["unit"] = ""
                cx.row = None
            done.append(c)

    def spec_tables_json(self):
        return [{"id": t["id"],
                 "columns": [{"id": c["id"], "kind": c["kind"], "unit": c["unit"], "expression": c["expression"]} for c in t["cols"]],
                 "rows": t["rows"]} for t in self.cx.tables]

    def make_cells(self, count, tyfn):
        cx = self.cx
        cells = []
        for i in range(count):
            cid = "c%d" % (i + 1)
            fam = tyfn(i)
            node = self.gen(fam, self.weighted([(1, 2), (2, 5), (3, 3)]))
            unit, decimals = "", self.weighted([(0, 2), (1, 2), (2, 8), (3, 2), (4, 2), (6, 1), (10, 1)])
            rfam = fam
            if fam not in ("n", "b"):
                if self.chance(0.4):
                    unit = self.pick(FAMILIES[fam])
                elif self.chance(0.04):
                    unit = self.pick(FAMILIES[self.pick([f for f in SIMPLE if f != fam])])
            elif fam == "n" and self.chance(0.06):
                unit = "%"
            cells.append({"id": cid, "expression": self.text(node), "unit": unit, "decimals": decimals})
            cx.cells.append((cid, rfam))
        return cells

    def random_type(self):
        return self.weighted([("n", 7), ("b", 2)] + [(f, 1) for f in SIMPLE] + [("speed", 1), ("eurkg", 1), ("area", 1), ("energy", 1)])


# --------------------------------------------------------------------------- case builders
def make_stats(g, n):
    out = []
    for _ in range(n):
        if g.chance(0.12):
            out.append({"count": 0, "empty": g.r.randrange(0, 5), "min": None, "max": None, "sum": None, "mean": None})
            continue
        lo = g.r.randrange(-20, 20)
        hi = lo + g.r.randrange(0, 50)
        cnt = g.r.randrange(1, 20)
        out.append({"count": cnt, "empty": g.r.randrange(0, 5), "min": lo, "max": hi,
                    "sum": round((lo + hi) / 2 * cnt, 3), "mean": round((lo + hi) / 2, 6)})
    return out


def shuffled_spec(g, spec):
    if g.chance(0.3):
        for key in ("inputs", "cells", "tables"):
            g.r.shuffle(spec[key])
    return spec


def typed_case(g, kind):
    chaos = {"typed": 0.0, "typed-bad": g.pick([0.04, 0.08, 0.15])}.get(kind, 0.0)
    g.p_bad = chaos
    g.sp = g.weighted([(0, 4), (1, 4), (2, 1)])
    g.par = g.pick([0.0, 0.0, 0.1, 0.5])
    spec_inputs = g.make_inputs(g.weighted([(0, 1), (1, 3), (2, 4), (3, 2), (4, 1)]))
    tables_json = []
    if kind in ("table", "pool", "colstat") or g.chance(0.12):
        for ti in range(g.weighted([(1, 5), (2, 2)])):
            t = g.make_table("t" if ti == 0 else "u", ti, junk=g.pick([0.0, 0.1, 0.2]))
            g.cx.tables.append(t)
            g.formula_columns(ti)
        tables_json = g.spec_tables_json()
    g.cx.colstat = kind == "colstat" or g.chance(0.04)
    if kind == "units":
        g.p_bad = 0.0
        cells = []
        for i in range(g.r.randrange(2, 7)):
            node = g.unit_chain(2)
            cells.append({"id": "c%d" % (i + 1), "expression": g.text(node), "unit": "", "decimals": g.pick([0, 2, 4, 6])})
            g.cx.cells.append(("c%d" % (i + 1), "?"))
    else:
        cells = g.make_cells(g.weighted([(1, 2), (2, 3), (3, 4), (4, 3), (5, 2), (7, 1)]), lambda i: g.random_type())
    spec = shuffled_spec(g, {"inputs": spec_inputs, "tables": tables_json, "cells": cells})
    overrides = {}
    if spec["inputs"] and g.chance(0.6):
        for inp in spec["inputs"]:
            if g.chance(0.5):
                overrides[inp["id"]] = g.value_pool("n")
    env = None
    if g.cx.colstat and g.chance(0.8):
        env = {"stats": make_stats(g, g.r.randrange(0, 4))}
    return spec, overrides, env


def limit_case(g):
    """Passes around the 50,000-step budget: a 40-row formula column of sum(t.a) terms (17 terms is
    the longest that fits 120 tokens), a second one, and cells that read them."""
    total = g.r.uniform(42000, 58000)       # ~43 steps per sum(t.a) term per row, 40 rows
    k1 = g.r.randrange(12, 18)
    k2 = max(1, min(17, int(round(total / 1720)) - k1 + g.r.randrange(-1, 2)))
    cols = [{"id": "a", "kind": "number", "unit": "", "expression": ""},
            {"id": "f", "kind": "formula", "unit": "", "expression": "+".join(["sum(t.a)"] * k1)},
            {"id": "w", "kind": "formula", "unit": "", "expression": "+".join(["sum(t.a)"] * k2)}]
    pool = ["1", "2", "3.5"] + (["", "x"] if g.chance(0.1) else [])
    table = {"id": "t", "columns": cols, "rows": [[g.pick(pool), "", ""] for _ in range(40)]}
    cells = []
    for i in range(g.r.randrange(1, 6)):
        e = g.pick(["sum(t.f)", "sum(t.w)", "mean(t.f)", "count(t.w)", "sum(t.a)", "median(t.w)"])
        extra = "+".join(["sum(t.a)"] * g.r.randrange(0, 15))
        expr = e + ("+" + extra if extra and g.chance(0.7) else "")
        if g.chance(0.2):
            expr = "iferror(" + expr + ",-1)"
        cells.append({"id": "c%d" % (i + 1), "expression": expr, "unit": "", "decimals": g.pick([0, 2])})
    return {"inputs": [], "tables": [table], "cells": cells}, {}, None


# ---- hostile text
def mutate(g, s):
    r = g.r
    k = g.weighted([("del", 4), ("ins", 5), ("dup", 3), ("trunc", 3), ("swap", 2), ("tail", 4), ("unit", 4), ("name", 3),
                    ("long", 1), ("wrap", 2), ("lit", 4), ("op", 3), ("nonascii", 2)])
    if not s:
        return g.pick(HOSTILE_TAILS)
    i = r.randrange(len(s))
    if k == "del":
        return s[:i] + s[i + 1:]
    if k == "ins":
        return s[:i] + g.pick(HOSTILE_CHARS) + s[i:]
    if k == "dup":
        return s[:i] + s[i] + s[i:]
    if k == "trunc":
        return s[:i]
    if k == "swap" and i + 1 < len(s):
        return s[:i] + s[i + 1] + s[i] + s[i + 2:]
    if k == "tail":
        return s + g.pick(HOSTILE_TAILS) if g.chance(0.7) else g.pick(HOSTILE_TAILS) + s
    if k == "unit":
        return s[:i] + g.pick(HOSTILE_UNITS) + s[i:] if g.chance(0.4) else re.sub(r"\[[^\]]*\]", lambda m: g.pick(HOSTILE_UNITS), s, count=1) or s
    if k == "name":
        m = list(re.finditer(r"[a-z][a-z0-9_]*", s))
        if m:
            mm = g.pick(m)
            return s[:mm.start()] + g.pick(HOSTILE_NAMES) + s[mm.end():]
        return s + g.pick(HOSTILE_NAMES)
    if k == "long":
        n = g.pick([190, 199, 200, 201, 202, 250, 400])
        core = s if len(s) < n else s[:n]
        pad = n - len(core)
        return core + " " * pad if g.chance(0.5) else " " * pad + core
    if k == "wrap":
        depth = g.pick([1, 5, 31, 32, 33, 40])
        return "(" * depth + s + ")" * depth
    if k == "lit":
        m = list(re.finditer(r"[0-9]+(?:\.[0-9]+)?", s))
        repl = g.pick([".5", "5.", "1e3", "1E5", "1_000", "0x10", "00", "01", "0.0", "007", "1e-3", "9" * 25, "0." + "0" * 40 + "1",
                       "123456789012345678901234567890", "1.5.2", "1e999"])
        if m:
            mm = g.pick(m)
            return s[:mm.start()] + repl + s[mm.end():]
        return s + repl
    if k == "op":
        m = list(re.finditer(r"[-+*/%^<>]=?|==|!=", s))
        if m:
            mm = g.pick(m)
            return s[:mm.start()] + g.pick(["+", "-", "*", "/", "%", "^", "<", ">", "<=", "==", "!=", "", "--", "**", "//", "^^", "<>"]) + s[mm.end():]
        return s + "+"
    return s[:i] + g.pick(HOSTILE_CHARS[8:]) + s[i:]


def grammar_mutation(g, s):
    """Structured breakage that targets one named reject (or an odd-but-legal form)."""
    tabs = g.cx.tables
    t = tabs[0] if tabs else None
    col = (t["id"] + "." + g.pick(t["cols"])["id"]) if t and t["cols"] else "1"
    nm = g.pick([i for i, _ in g.cx.inputs] or ["1"])
    k = g.weighted([("chain", 3), ("arity", 5), ("colref", 4), ("colstat", 3), ("sumproduct", 3), ("convert", 3), ("deep", 3),
                    ("nodes", 2), ("tokens", 2), ("args", 2), ("misc", 6)])
    if k == "chain":
        return g.pick(["1<2<3", "1<2==2", "%s<%s>%s" % (nm, nm, nm), "1<=2<=3", "not 1<2<3", "(1<2)<3", "1==1==1", "1!=2!=3"]) if g.chance(0.5) else s + "<1<2"
    if k == "arity":
        m = list(re.finditer(r"\b([a-z]+)\(([^()]*)\)", s))
        if m:
            mm = g.pick(m)
            parts = [x for x in mm.group(2).split(",")]
            parts = parts[:-1] if g.chance(0.5) and len(parts) > 1 else parts + [g.pick(["1", nm, "2"])]
            return s[:mm.start()] + mm.group(1) + "(" + ",".join(parts) + ")" + s[mm.end():]
        return g.pick(["abs()", "abs(1,2)", "min(1)", "max(1,2,3,4,5,6,7)", "clamp(1,2)", "round(1)", "round(1,2,3)", "if(1,2)",
                       "iferror(1)", "sqrt()", "to(1)", "num(1,[kg],2)", "sum()", "sum(1,2,3,4,5,6,7)"])
    if k == "colref":
        return g.pick([col, "1+" + col, "abs(" + col + ")", col + "*2", "if(" + col + ">1,1,2)", "-" + col, "round(" + col + ",2)", "to(" + col + ",[kg])"])
    if k == "colstat":
        return g.pick(["colstat(0,sum)", "colstat(1.5,sum)", "colstat(%s,sum)" % nm, "colstat(1,sd)", "colstat(1,2)", "colstat(1)", "colstat(-1,sum)",
                       "colstat(01,sum)", "colstat(1,sum,2)", "colstat(1,[kg])", "colstat(99,count)", "colstat(1,Sum)", "colstat(1, mean)",
                       "colstat(2,empty)+colstat(1,count)"])
    if k == "sumproduct":
        return g.pick(["sumproduct(%s)" % col, "sumproduct(1,2)", "sumproduct(%s,%s)" % (col, col), "sumproduct(%s,2)" % col,
                       "sumproduct(%s,%s,%s)" % (col, col, col), "sumproduct(%s, 2)" % col, "sumproduct(%s+1,%s)" % (col, col)])
    if k == "convert":
        return g.pick(["to(1,5)", "to(1,kg)", "to(1,[])", "to(1,[kg],[g])", "num(1,[ABC])", "to(2[kg],[lb])", "to(2[kg],[m])", "to(2,[kg])",
                       "num(true,[kg])", "to(1[kg],[kg^2])", "to(1[m],[m*m])", "to(5[J],[W])", "to(5[W]*1[h],[J])", "num(1[%],[%])"])
    if k == "deep":
        n = g.pick([30, 31, 32, 33, 34])
        form = g.pick(["abs(%s)", "-%s", "(%s)", "not %s", "%s^1"])
        inner = "1"
        for _ in range(n):
            inner = form % inner
        return inner
    if k == "nodes":
        n = g.pick([39, 40, 41])        # n adds -> 2n+1 nodes: 79, 81, 83 around the cap of 80
        return "+".join(["1"] * (n + 1))
    if k == "tokens":
        n = g.pick([59, 60, 61])        # 2n-1 tokens: 117, 119, 121
        return "+".join([nm] * n)
    if k == "args":
        return "max(" + ",".join(["1"] * g.pick([5, 6, 7])) + ")"
    return g.pick(["1+", "+1", "*2", "2**3", "2//3", "1 2", "1,2", "(1,2)", "%s %s" % (nm, nm), "3 4 + 5", "1+(2", "1+2)", "((", "))", "()", "1()", "abs 1", "--", "-",
                   "not", "not not 1", "1 and 2", "1 or 0", "true", "false", "null", "NaN", "inf", "1e", "1.", ".", "..1", "1..2", "$1", "1;2", "%s=1" % nm,
                   "%s:=1" % nm, "1?2:3", "'a'", "\"a\"", "[kg]", "5 [kg]", "5[kg] [m]", "5[kg]5", "5[ kg ]", "2^3^4", "-2^-2", "--3", "1 + - + 2", "5%%2",
                   "0^0", "0.1+0.2==0.3", "10%3", "-7%3", "7%-3", "1/3*3==1"])


def hostile_case(g):
    """Exactly ONE broken expression in an otherwise valid spec: when a spec has several faults the
    engines pick different reject slugs (precedence is unpinned, see the report), so a row carries one."""
    spec, overrides, env = typed_case(g, g.pick(["typed", "table"]))
    keep = spec["cells"][: g.weighted([(1, 4), (2, 3), (3, 1)])]
    gone = {c["id"] for c in spec["cells"][len(keep):]}
    for c in keep:      # a kept cell must not read a dropped one (that would be a second fault)
        if gone & set(re.findall(r"[a-z][a-z0-9_]*", c["expression"])):
            c["expression"] = "1"
    spec["cells"] = keep
    formulas = [c for t in spec["tables"] for c in t["columns"] if c["kind"] == "formula"]
    target = g.pick(formulas) if formulas and g.chance(0.25) else g.pick(spec["cells"])
    if g.chance(0.45):
        target["expression"] = grammar_mutation(g, target["expression"])
    else:
        for _ in range(g.weighted([(1, 6), (2, 3), (3, 1)])):
            target["expression"] = mutate(g, target["expression"])
    return spec, overrides, env


def spec_hostile_case(g):
    spec, overrides, env = typed_case(g, g.pick(["typed", "table"]))
    k = g.weighted([("dup", 3), ("reserved", 3), ("badid", 3), ("badunit", 4), ("rowshape", 3), ("colid", 2), ("cycle", 3), ("tabinput", 2),
                    ("unknown-col", 2), ("kind", 1), ("rowtype", 1), ("limits", 3), ("emptyexpr", 2), ("values", 1), ("decimals", 2), ("types", 2)])
    cells, inputs, tables = spec["cells"], spec["inputs"], spec["tables"]
    if k == "dup":
        pool = [x for x in inputs + cells + tables]
        if pool:
            a = g.pick(pool)
            b = g.pick(cells) if cells else None
            if b is not None:
                b["id"] = a["id"]
    elif k == "reserved":
        tgt = g.pick(cells + inputs + tables or [{"id": "c1"}])
        tgt["id"] = g.pick(RESERVED_IDS)
    elif k == "badid":
        tgt = g.pick(cells + inputs + tables or [{"id": "c1"}])
        tgt["id"] = g.pick(BAD_IDS)
    elif k == "badunit":
        pool = cells + inputs + [c for t in tables for c in t["columns"]]
        if pool:
            g.pick(pool)["unit"] = g.pick(BAD_UNITS)
    elif k == "rowshape" and tables:
        t = g.pick(tables)
        if t["rows"]:
            row = g.pick(t["rows"])
            if g.chance(0.5) and row:
                row.pop()
            else:
                row.append("1")
    elif k == "colid" and tables:
        t = g.pick(tables)
        if t["columns"]:
            tgt = g.pick(t["columns"])
            pool = [i["id"] for i in inputs] + [c["id"] for c in cells] + [c["id"] for c in t["columns"]]
            if pool:
                tgt["id"] = g.pick(pool)
    elif k == "cycle" and cells:
        a = g.pick(cells)
        b = g.pick(cells)
        a["expression"] = "1+" + b["id"]
        b["expression"] = "2*" + a["id"] if g.chance(0.6) else "1+" + b["id"]
    elif k == "tabinput" and tables and inputs:
        cells[0]["expression"] = inputs[0]["id"] + "." + tables[0]["columns"][0]["id"] if tables[0]["columns"] else "1"
        cells[0]["expression"] = "sum(" + cells[0]["expression"] + ")"
    elif k == "unknown-col" and tables and cells:
        tid = tables[0]["id"]
        cells[0]["expression"] = g.pick(["sum(%s.zz)", "count(zz.n)", "sum(%s.n.n)", "%s.n", "sum(%s)", "sumproduct(%s.n)"]).replace("%s", tid)
    elif k == "kind" and tables and tables[0]["columns"]:
        tables[0]["columns"][0]["kind"] = g.pick(["bool", "", None, "Number", "formula"])
    elif k == "rowtype" and tables and tables[0]["rows"]:
        tables[0]["rows"][0] = g.pick(["abc", 5, None, {}])
    elif k == "limits":
        which = g.pick(["inputs", "cells", "tables", "columns", "rows", "graph"])
        if which == "inputs":
            spec["inputs"] = [{"id": "i%d" % n, "unit": "", "value": n} for n in range(g.pick([12, 13]))]
            spec["cells"] = [{"id": "c1", "expression": "i1", "unit": "", "decimals": 2}]
            spec["tables"] = []
        elif which == "cells":
            spec["cells"] = [{"id": "c%d" % n, "expression": str(n), "unit": "", "decimals": 2} for n in range(1, g.pick([24, 25]) + 1)]
        elif which == "tables":
            spec["tables"] = [{"id": "t%d" % n, "columns": [{"id": "a", "kind": "number", "unit": "", "expression": ""}], "rows": [["1"]]}
                              for n in range(g.pick([2, 3]))]
        elif which == "columns":
            n = g.pick([12, 13])
            spec["tables"] = [{"id": "t", "columns": [{"id": "k%d" % j, "kind": "number", "unit": "", "expression": ""} for j in range(n)],
                               "rows": [["1"] * n]}]
        elif which == "rows":
            n = g.pick([40, 41])
            spec["tables"] = [{"id": "t", "columns": [{"id": "a", "kind": "number", "unit": "", "expression": ""}], "rows": [["1"]] * n}]
        else:
            def ftable(tid, nrows, nf):
                cols = [{"id": "a", "kind": "number", "unit": "", "expression": ""}]
                cols += [{"id": "f%d" % j, "kind": "formula", "unit": "", "expression": "a+%d" % j} for j in range(nf)]
                return {"id": tid, "columns": cols, "rows": [["1"] + [""] * nf for _ in range(nrows)]}
            over = g.chance(0.5)     # 12 inputs + 24 cells + 264 instances = 300; the other layout is 301
            spec["inputs"] = [{"id": "i%d" % n, "unit": "", "value": n} for n in range(12)]
            spec["tables"] = [ftable("t", 40, 4), ftable("u", 21, 5) if over else ftable("u", 26, 4)]
            spec["cells"] = [{"id": "c%d" % n, "expression": "1", "unit": "", "decimals": 2} for n in range(1, 25)]
    elif k == "emptyexpr" and cells:
        cells[0]["expression"] = g.pick(["", " ", "\t", "   \t ", None, 5, "()", "(", ")"])
    elif k == "values" and inputs:
        inputs[0]["value"] = g.pick(["7", "", True, False, [], {}, "abc", "1e3"])
        if overrides:
            overrides[next(iter(overrides))] = g.pick(["7", True, [], {}, "x"])
        else:
            overrides[inputs[0]["id"]] = g.pick(["7", True, [], None])
    elif k == "decimals" and cells:
        cells[0]["decimals"] = g.pick([0, 10, 11, -1, 2.5, "2", None, True, 3.0])
    elif k == "types":
        spec[g.pick(["inputs", "tables", "cells"])] = g.pick([{}, "x", 5, [1], [None], {"a": 1}, [[]]])
    return spec, overrides, env


KIND_BUILDERS = {
    "typed": lambda g: typed_case(g, "typed"),
    "typed-bad": lambda g: typed_case(g, "typed-bad"),
    "table": lambda g: typed_case(g, "table"),
    "units": lambda g: typed_case(g, "units"),
    "colstat": lambda g: typed_case(g, "colstat"),
    "pool": lambda g: typed_case(g, "table"),
    "hostile": hostile_case,
    "spec-hostile": spec_hostile_case,
    "limit": limit_case,
}


# --------------------------------------------------------------------------- expectations
def all_expressions(spec):
    out = []
    try:
        for c in spec.get("cells", []):
            if isinstance(c, dict):
                out.append(c.get("expression"))
        for t in spec.get("tables", []):
            for c in t.get("columns", []):
                out.append(c.get("expression"))
    except (AttributeError, TypeError):
        pass
    return [e for e in out if isinstance(e, str)]


NON_INTEGER_POW = re.compile(r"\^(?!\s*-?\s*[0-9]+(?![0-9.]))")


def transcendental(spec):
    """True when an expression uses sqrt or a ^ whose exponent is not a plain integer literal."""
    for e in all_expressions(spec):
        e = re.sub(r"\[[^\]]*\]", "", e)
        if "sqrt" in e or NON_INTEGER_POW.search(e):
            return True
    return False


def expected_ids(model):
    ids = list(model.cells)
    for t in model.tables.values():
        for col in t.cols:
            if col.kind == "formula":
                for r in range(min(2, t.nrows)):
                    ids.append("%s.%s#%d" % (t.id, col.id, r + 1))
    return ids


class EngineBug(Exception):
    pass


def evaluate_row(calc, spec, overrides, env):
    """The Python engine's verdict as row fields; raises EngineBug on a non-CalcError exception."""
    try:
        model = calc.compile_spec(json.loads(json.dumps(spec)))
    except calc.CalcError as error:
        return {"compile": "reject", "why": error.why}
    except Exception as error:  # noqa: BLE001 - reported, not hidden
        raise EngineBug("compile: %s: %s" % (type(error).__name__, error))
    try:
        result = calc.evaluate(model, json.loads(json.dumps(overrides)), json.loads(json.dumps(env)) if env is not None else None)
        expect = {}
        for nid in expected_ids(model):
            node = result.nodes[nid]
            expect[nid] = {"text": calc.format_cell(model, result, nid), "err": node.err["code"] if node.err else None}
    except Exception as error:  # noqa: BLE001
        raise EngineBug("evaluate: %s: %s" % (type(error).__name__, error))
    return {"compile": "ok", "expect": expect}


def malformed_shape(spec):
    if not isinstance(spec, dict):
        return True
    for key in ("inputs", "tables", "cells"):
        v = spec.get(key)
        if not isinstance(v, list) or any(not isinstance(x, dict) for x in v):
            return True
    for item in spec["inputs"] + spec["cells"] + spec["tables"]:
        if not isinstance(item.get("id"), str):
            return True
    if any(not isinstance(c.get("expression"), str) for c in spec["cells"]):
        return True
    for t in spec["tables"]:
        if not isinstance(t.get("columns"), list) or not isinstance(t.get("rows"), list):
            return True
        for c in t["columns"]:
            if not isinstance(c, dict) or c.get("kind") not in ("number", "text", "formula") or not isinstance(c.get("id"), str):
                return True
            if c["kind"] == "formula" and not isinstance(c.get("expression"), str):
                return True
        if any(not isinstance(r, list) for r in t["rows"]):
            return True
    return False


def input_value_type(spec, overrides):
    values = [i.get("value") for i in spec["inputs"]] + list(overrides.values())
    return any(v is not None and (isinstance(v, bool) or not isinstance(v, (int, float))) for v in values)


def unit_text(spec):
    units = [i.get("unit") for i in spec["inputs"]] + [c.get("unit") for c in spec["cells"]]
    units += [c.get("unit") for t in spec["tables"] for c in t["columns"]]
    return any(isinstance(u, str) and ((u != u.strip()) or ("%" in u and len(u) > 1)) for u in units)


def skip_reason(tag, spec, overrides):
    if tag in SKIP:
        return SKIP[tag]
    if malformed_shape(spec):
        return "malformed-shape"
    if input_value_type(spec, overrides):
        return "input-value-type"
    if unit_text(spec):
        return "unit-text"
    return None


def build_cases(calc=None):
    """Deterministic: returns (rows, engine_bugs, skipped). engine_bugs is [] on a healthy engine;
    skipped is [(tag, reason)] for rows dropped by the skip list."""
    calc = calc or load_engine()
    rng = random.Random(SEED)
    g = Gen(rng)
    kinds = [k for k, w in KINDS for _ in range(w)]
    rows, bugs, skipped = [], [], []
    for index in range(COUNT):
        kind = kinds[rng.randrange(len(kinds))]
        g.cx, g.p_bad = Cx(), 0.0
        spec, overrides, env = KIND_BUILDERS[kind](g)
        tag = "fz%04d-%s" % (index, kind)
        row = {"tag": tag, "spec": spec, "inputs": overrides}
        reason = skip_reason(tag, spec, overrides)
        if reason:
            skipped.append((tag, reason))
            continue
        if env is not None:
            row["env"] = env
        try:
            verdict = evaluate_row(calc, spec, overrides, env)
        except EngineBug as bug:
            bugs.append((tag, str(bug), row))
            continue
        row.update(verdict)
        if verdict["compile"] == "ok" and transcendental(spec):
            row["approx"] = APPROX
        rows.append(row)
    return rows, bugs, skipped


HEADER = """.pragma library
/*
 * CalcFuzz.js - GENERATED by tests/gen_calc_fuzz.py (seed %d, %d candidate rows). Do not edit.
 *
 * Differential fuzz table for the typed computation runtime. Expected values are
 * what the PYTHON engine (ai_calc.py) says; tests/test_ai_calc.py proves this
 * file is exactly what the generator produces today and that Python reproduces
 * every row, tests/tst_AiCalc.qml proves the JS engine (AiCalc.js) matches
 * every row. Format as CalcGolden.js: the keyword var, the name CASES, an equals
 * sign on its own line, then ONE pure-JSON array (ASCII, no trailing semicolon).
 *
 * Row: tag, spec, inputs (value overrides), optional env, and either
 *   compile "reject" + why, or compile "ok" + expect {id: {text, err}} for every
 *   cell and the first two instances of each formula column ("t.f#1").
 * "approx" (relative 1e-12 on the numeric prefix, unit suffix exact) is present
 * ONLY on rows that use sqrt or a ^ with a non-integer-literal exponent; every
 * other row is compared as exact text.
 */
var CASES =
""" % (SEED, COUNT)


def render(rows):
    body = ",\n".join(json.dumps(r, separators=(",", ":"), ensure_ascii=True, allow_nan=False) for r in rows)
    return HEADER + "[\n" + body + "\n]\n"


def main(argv):
    rows, bugs, skipped = build_cases()
    text = render(rows)
    counts = {}
    for _, reason in skipped:
        counts[reason] = counts.get(reason, 0) + 1
    print("skipped:", counts or "none")
    if bugs:
        for tag, message, _ in bugs:
            print("ENGINE BUG", tag, message, file=sys.stderr)
    if "--check" in argv:
        fresh = OUT.read_text(encoding="utf-8") == text
        print("fresh" if fresh else "STALE")
        return 0 if fresh and not bugs else 1
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print("wrote %s: %d rows, %d bytes, %d engine bugs" % (OUT.name, len(rows), len(text.encode()), len(bugs)))
    return 1 if bugs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
