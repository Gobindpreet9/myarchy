"""Typed computation runtime: a closed expression language with units.

Python twin of AiCalc.js; both are written from tests/CalcGolden.js, which pins
every rule (grammar, unit algebra, rounding, limits, error codes). There is no
eval/exec and no I/O: user text goes through a hand-written lexer and a Pratt
parser into tuples, and the evaluator walks those tuples.

    compile_spec(spec)                          -> CompiledModel, or CalcError
    evaluate(model, input_values, env, prev)    -> Result (pure; prev = incremental)
    format_cell(model, result, node_id)         -> display text
    provenance(model, result, node_id)          -> plain dict, or None

A compile reject raises CalcError(why, msg) for the WHOLE spec. A runtime error
is a value: result.nodes[id].err = {"code", "msg", "node"}. A formula-column
cell instance has the node id "<table>.<column>#<row>" (row is 1-based).
"""

import heapq
import math
import re
from decimal import Context, Decimal, ROUND_HALF_UP
from types import MappingProxyType

max_expression_chars = 200
max_tokens = 120
max_nodes = 80
max_depth = 32
max_call_args = 6
max_inputs = 12
max_cells = 24
max_tables = 2
max_columns = 12
max_rows = 40
max_graph_nodes = 300
max_pass_steps = 50000
max_cell_steps = 5000
max_id_chars = 24

ERROR_CODES = ("DIV0", "MISSING", "TYPE", "UNIT", "DOMAIN", "RANGE", "LIMIT", "SRC")
DASH = "—"
STAT_WORDS = ("count", "empty", "min", "max", "sum", "mean")


class CalcError(ValueError):
    """A whole-spec compile reject; `why` is a slug from the golden header."""

    def __init__(self, why, msg=""):
        ValueError.__init__(self, why + ": " + msg if msg else why)
        self.why = why
        self.msg = msg


def _rej(why, msg=""):
    return CalcError(why, msg)


# ------------------------------------------------------------------ units
# every active ISO-4217 alphabetic code is its own base dimension
_CURRENCIES = tuple((
    "AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP "
    "BYN BZD CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP "
    "GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR "
    "KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK "
    "MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR "
    "SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS "
    "UAH UGX USD UYU UZS VES VND VUV WST XAF XCD XOF XPF YER ZAR ZMW ZWL "
).split())
_BASES = ("length", "mass", "time", "data", "pixel") + _CURRENCIES


def _d(**exps):
    return tuple(sorted((_BASES.index(n), e) for n, e in exps.items()))


_ENERGY = _d(mass=1, length=2, time=-2)
_POWER = _d(mass=1, length=2, time=-3)
_ROWS = tuple(
    [(s, k, _d(length=1)) for s, k in (("mm", 1e-3), ("cm", 1e-2), ("m", 1.0), ("km", 1e3),
                                       ("in", 0.0254), ("ft", 0.3048), ("mi", 1609.344))]
    + [(s, k, _d(mass=1)) for s, k in (("g", 1e-3), ("kg", 1.0), ("lb", 0.45359237),
                                       ("oz", 0.028349523125))]
    + [(s, k, _d(time=1)) for s, k in (("s", 1.0), ("min", 60.0), ("h", 3600.0),
                                       ("d", 86400.0), ("wk", 604800.0))]
    + [(s, k, _d(data=1)) for s, k in (("B", 1.0), ("kB", 1e3), ("MB", 1e6), ("GB", 1e9),
                                       ("TB", 1e12), ("KiB", 2.0 ** 10), ("MiB", 2.0 ** 20),
                                       ("GiB", 2.0 ** 30), ("TiB", 2.0 ** 40))]
    + [("J", 1.0, _ENERGY), ("Wh", 3600.0, _ENERGY), ("kWh", 3.6e6, _ENERGY),
       ("W", 1.0, _POWER), ("kW", 1e3, _POWER),
       ("Hz", 1.0, _d(time=-1)), ("GHz", 1e9, _d(time=-1)),
       ("px", 1.0, _d(pixel=1)), ("%", 0.01, ())]
    + [(c, 1.0, _d(**{c: 1})) for c in _CURRENCIES]
)
_ATOMS = MappingProxyType({s: (k, d) for s, k, d in _ROWS})
UNIT_SCALES = MappingProxyType({s: k for s, k, _ in _ROWS})
UNIT_DIMENSIONS = MappingProxyType(
    {s: MappingProxyType({_BASES[i]: e for i, e in d}) for s, _, d in _ROWS})
_SYMBOL_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz%")


class Q:
    """A quantity: number v expressed in unit u, a tuple of (symbol, exponent)."""

    __slots__ = ("v", "u")

    def __init__(self, v, u):
        self.v = v
        self.u = u

    def __eq__(self, other):
        return type(other) is Q and self.v == other.v and self.u == other.u

    __hash__ = None


def _dim_of(u):
    acc = {}
    for sym, e in u:
        for i, k in _ATOMS[sym][1]:
            acc[i] = acc.get(i, 0) + k * e
    return tuple(sorted((i, k) for i, k in acc.items() if k))


def _pow(base, e):
    """base ** e that turns overflow into inf (the caller's finite check says RANGE)."""
    try:
        return base ** e
    except (OverflowError, ZeroDivisionError):
        return math.inf


def _factor(u):
    f = 1.0
    for sym, e in u:
        f *= _pow(_ATOMS[sym][0], e)
    return f


def _mkq(v, u):
    """Normalise a unit product: fold dimensionless atoms (%) into the value, cancel an identical
    symbol exactly, merge other same-dimension symbols into the first-occurring one (scale folded
    into the value), and collapse a dimensionless product to a plain number."""
    same = {}
    for sym, e in u:                      # pass 1: identical symbols cancel exactly
        same[sym] = same.get(sym, 0) + e
    keep = []
    for sym, e in same.items():           # pass 2: same-dimension symbols join the first one
        scale, dim = _ATOMS[sym]
        if not e:
            continue
        if not dim:
            v *= _pow(scale, e)
            continue
        for item in keep:
            if _ATOMS[item[0]][1] == dim:
                v *= _pow(scale / _ATOMS[item[0]][0], e)
                item[1] += e
                break
        else:
            keep.append([sym, e])
    keep = tuple((s, e) for s, e in keep if e)
    if any(abs(e) > 1024 for _, e in keep):
        raise _Fail("RANGE", "The composed unit exponent is out of range.")
    if not keep:
        return v
    if _dim_of(keep):
        return Q(v, keep)
    return v * _factor(keep)


def _lit_q(v, u):
    """A unit as written: % folded, identical symbols combined, merged only when dimensionless."""
    if not _dim_of(u):
        return _mkq(v, u)
    same = {}
    for sym, e in u:
        same[sym] = same.get(sym, 0) + e
    keep = []
    for sym, e in same.items():
        if _ATOMS[sym][1]:
            keep.append((sym, e))
        elif e:
            v *= _pow(_ATOMS[sym][0], e)
    keep = tuple((s, e) for s, e in keep if e)
    return Q(v, keep) if keep else v


def _render(u):
    def one(s, e):
        return s if e == 1 else s + "^" + str(e)
    num = [one(s, e) for s, e in u if e > 0]
    den = [one(s, -e) for s, e in u if e < 0]
    text = "*".join(num) if num else ("1" if den else "")
    if len(den) == 1:
        text += "/" + den[0]
    elif den:
        text += "/(" + "*".join(den) + ")"
    return text


def parse_unit(text):
    """Parse a unit group (no brackets) into a tuple of (symbol, exponent)."""
    if not isinstance(text, str) or text == "":
        raise _rej("bad-unit", "A unit cannot be empty.")
    n, i, sign, out, unknown = len(text), 0, 1, [], None
    while True:
        j = i
        while j < n and text[j] in _SYMBOL_CHARS:
            j += 1
        sym = text[i:j]
        if sym == "":
            raise _rej("bad-unit", "Expected a unit symbol in '" + text + "'.")
        if sym not in _ATOMS and unknown is None:
            unknown = sym
        exp = 1
        if j < n and text[j] == "^":
            if j + 1 >= n or text[j + 1] not in "123456789":
                raise _rej("bad-unit", "A unit exponent is one digit 1-9.")
            exp = int(text[j + 1])
            j += 2
        for k, (s, e) in enumerate(out):
            if s == sym:
                out[k] = (s, e + sign * exp)
                break
        else:
            out.append((sym, sign * exp))
        if j == n:
            break
        if text[j] not in "*/":
            raise _rej("bad-unit", "Unexpected '" + text[j] + "' in a unit.")
        sign = 1 if text[j] == "*" else -1
        i = j + 1
    if unknown is not None:                # a malformed group is reported before an unknown symbol
        raise _rej("unknown-unit", "'" + unknown + "' is not a known unit.")
    return tuple((s, e) for s, e in out if e)


# ------------------------------------------------------------------ lexer / parser
_ID = re.compile(r"[a-z][a-z0-9_]{0,23}")
_FUNCS = MappingProxyType({  # name -> (min args, max args)
    "abs": (1, 1), "floor": (1, 1), "ceil": (1, 1), "sqrt": (1, 1),
    "min": (2, 6), "max": (2, 6), "clamp": (3, 3), "round": (2, 2),
    "if": (3, 3), "iferror": (2, 2), "to": (2, 2), "num": (2, 2),
    "sum": (1, 6), "mean": (1, 6), "median": (1, 6), "count": (1, 6),
    "sumproduct": (2, 2), "colstat": (2, 2),
})
_AGG = ("sum", "mean", "median", "count")
_KEYWORDS = ("and", "or", "not")
_RESERVED = frozenset(_FUNCS) | frozenset(_KEYWORDS) | frozenset(_ATOMS)
_CMP = ("<", "<=", ">", ">=", "==", "!=")
_LEVEL = MappingProxyType({"or": 10, "and": 20, "<": 40, "<=": 40, ">": 40, ">=": 40, "==": 40, "!=": 40,
                           "+": 50, "-": 50, "*": 60, "/": 60, "%": 60, "^": 80})
_NOT_LEVEL = 30
_NEG_LEVEL = 80
_OPS2 = ("<=", ">=", "==", "!=")
_OPS1 = "+-*/%^(),<>."


def _lex(src):
    toks, n, i, unknown = [], len(src), 0, None
    while i < n:
        c = src[i]
        if c == " " or c == "\t":
            i += 1
        elif "0" <= c <= "9":
            j = i
            while j < n and "0" <= src[j] <= "9":
                j += 1
            if j + 1 < n and src[j] == "." and "0" <= src[j + 1] <= "9":
                j += 1
                while j < n and "0" <= src[j] <= "9":
                    j += 1
            if j < n and src[j] in "eE":
                k = j + 1
                if k < n and src[k] in "+-":
                    k += 1
                if k < n and "0" <= src[k] <= "9":
                    raise _rej("scientific-literal", "Write 1000, not 1e3.")
            toks.append(("num", float(src[i:j]), i, j, "." not in src[i:j]))
            i = j
        elif ("a" <= c <= "z") or ("A" <= c <= "Z") or c == "_":
            j = i + 1
            while j < n and (("a" <= src[j] <= "z") or ("A" <= src[j] <= "Z")
                             or ("0" <= src[j] <= "9") or src[j] == "_"):
                j += 1
            toks.append(("name", src[i:j], i, j))
            i = j
        elif c == "[":
            j = i + 1
            while j < n and src[j] not in "[]":
                j += 1
            if j >= n or src[j] == "[":
                raise _rej("bad-unit", "Unit brackets must close and cannot nest.")
            try:
                group = parse_unit(src[i + 1:j])
            except CalcError as error:       # bad-unit anywhere beats unknown-unit anywhere
                if error.why != "unknown-unit":
                    raise
                group, unknown = (), unknown or error
            toks.append(("unit", group, i, j + 1))
            i = j + 1
        elif src[i:i + 2] in _OPS2:
            toks.append(("op", src[i:i + 2], i, i + 2))
            i += 2
        elif c in _OPS1:
            toks.append(("op", c, i, i + 1))
            i += 1
        else:
            raise _rej("syntax", "Unexpected character " + repr(c) + ".")
    if unknown is not None:
        raise unknown
    return toks


class _Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0
        self.n = 0
        self.height = {}

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if j < len(self.t) else None

    def mk(self, *node):
        self.n += 1
        if self.n > max_nodes:
            raise _rej("nodes", "More than " + str(max_nodes) + " syntax nodes.")
        h = 1 + max([self.height[id(k)] for k in _kids(node)], default=0)
        if h > max_depth:
            raise _rej("depth", "Deeper than " + str(max_depth) + " levels.")
        self.height[id(node)] = h
        return node

    def take(self):
        tok = self.peek()
        if tok is None:
            raise _rej("syntax", "The expression ends unexpectedly.")
        self.i += 1
        return tok

    def is_op(self, tok, text):
        return tok is not None and tok[0] == "op" and tok[1] == text

    def expect(self, text):
        tok = self.take()
        if not self.is_op(tok, text):
            raise self.unexpected(tok)

    @staticmethod
    def unexpected(tok):
        if tok[0] == "unit":
            return _rej("unit-position", "A [unit] must follow a number directly.")
        return _rej("syntax", "Unexpected " + repr(tok[1]) + ".")

    @staticmethod
    def binop(tok):
        if tok is None:
            return None
        if tok[0] == "op" and tok[1] in _LEVEL:
            return tok[1]
        if tok[0] == "name" and tok[1] in ("and", "or"):
            return tok[1]
        return None

    def expr(self, min_bp):
        left = self.nud(min_bp)
        while True:
            op = self.binop(self.peek())
            if op is None or _LEVEL[op] < min_bp:
                return left
            self.i += 1
            level = _LEVEL[op]
            right = self.expr(level if op == "^" else level + 1)
            left = self.mk("bin", op, left, right)
            if op in _CMP and self.binop(self.peek()) in _CMP:
                raise _rej("chained-comparison", "Comparisons do not chain; use 'and'.")

    def nud(self, min_bp):
        tok = self.take()
        kind, val = tok[0], tok[1]
        if kind == "num":
            nxt = self.peek()
            if nxt is not None and nxt[0] == "unit" and nxt[2] == tok[3]:
                self.i += 1
                return self.mk("lit", _lit_q(val, nxt[1]), False, False, False)
            return self.mk("lit", val, val == 0.0, True, tok[4])
        if kind == "name":
            if val == "not":
                if min_bp > _NOT_LEVEL:
                    raise _rej("syntax", "'not' is not allowed here; use parentheses.")
                return self.mk("not", self.expr(_NOT_LEVEL))
            self.plain_name(val)
            nxt = self.peek()
            if self.is_op(nxt, "("):
                return self.call(val)
            if self.is_op(nxt, "."):
                self.i += 1
                col = self.take()
                if col[0] != "name":
                    raise _rej("syntax", "Expected a column name after '.'.")
                self.plain_name(col[1])
                return self.mk("col", val, col[1])
            return self.mk("name", val)
        if kind == "op":
            if val == "(":
                inner = self.expr(0)
                self.expect(")")
                return inner
            if val == "-":
                return self.mk("neg", self.expr(_NEG_LEVEL))
        raise self.unexpected(tok)

    @staticmethod
    def plain_name(val):
        if not re.fullmatch(r"[a-z][a-z0-9_]*", val) or val in ("and", "or"):
            raise _rej("syntax", "Unexpected name " + repr(val[:24]) + ".")

    def call(self, name):
        self.i += 1  # (
        if self.is_op(self.peek(), ")"):
            raise _rej("syntax", name + "() needs arguments.")
        args = []
        while True:
            tok, after = self.peek(), self.peek(1)
            closes = after is not None and after[0] == "op" and after[1] in ",)"
            index = len(args)
            if name in ("to", "num") and index == 1 and tok is not None and tok[0] == "unit" and closes:
                self.i += 1
                args.append(self.mk("unit", tok[1]))
            elif name == "colstat" and index == 1 and tok is not None and tok[0] == "name" and closes:
                self.i += 1
                self.plain_name(tok[1])
                args.append(self.mk("word", tok[1]))
            else:
                args.append(self.expr(0))
            if len(args) > max_call_args:
                raise _rej("args", "A call takes at most " + str(max_call_args) + " arguments.")
            sep = self.take()
            if self.is_op(sep, ")"):
                break
            if not self.is_op(sep, ","):
                raise self.unexpected(sep)
        lo, hi = _FUNCS.get(name, (1, max_call_args))   # an unknown function is reported by _resolve
        if not lo <= len(args) <= hi:
            raise _rej("arity", name + " takes " + (str(lo) if lo == hi else "%d to %d" % (lo, hi)) + " argument(s).")
        if name in ("to", "num") and args[1][0] != "unit":
            raise _rej("unit-position", name + "() needs a [unit] group as its second argument.")
        return self.mk("call", name, tuple(args))


def _kids(a):
    k = a[0]
    if k in ("neg", "not"):
        return (a[1],)
    if k == "bin":
        return (a[2], a[3])
    if k == "call":
        return a[2]
    return ()


def compile_expression(src):
    """Lex and parse one expression into a tuple tree; raises CalcError."""
    if not isinstance(src, str):
        raise _rej("syntax", "An expression must be text.")
    if any(ord(ch) > 127 for ch in src):
        raise _rej("non-ascii", "Expressions are ASCII only.")
    if len(src) > max_expression_chars:
        raise _rej("length", "More than " + str(max_expression_chars) + " characters.")
    if src.strip(" \t\n\r\v\f") == "":
        raise _rej("empty", "The expression is empty.")
    toks = _lex(src)
    if len(toks) > max_tokens:
        raise _rej("tokens", "More than " + str(max_tokens) + " tokens.")
    p = _Parser(toks)
    try:
        ast = p.expr(0)
    except RecursionError:
        raise _rej("depth", "The expression nests too deeply.")
    if p.i != len(toks):
        raise p.unexpected(toks[p.i])
    return ast


# ------------------------------------------------------------------ numbers
_PLAIN_NUMBER = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")


def clean_decimal(v):
    """The 15-significant-digit decimal of v; an exact tie at digit 16 rounds away from zero."""
    return Context(prec=15, rounding=ROUND_HALF_UP).plus(Decimal(v))


def clean(v):
    return float(clean_decimal(v))


def fixed_text(v, places):
    """CLEAN to 15 significant digits, round half away from zero, fixed notation."""
    q = clean_decimal(v).quantize(Decimal(1).scaleb(-places),
                                  context=Context(prec=400, rounding=ROUND_HALF_UP))
    if q.is_zero():
        q = q.copy_abs()
    return format(q, "f")


def _round_to(v, places):
    r = float(fixed_text(v, places))
    return v if math.isinf(r) else r      # the 15-digit clean of a number near the largest double


def _close(a, b):
    return a == b or abs(a - b) <= 1e-9 * max(abs(a), abs(b))


_MESSAGES = MappingProxyType({
    "DIV0": "Division by zero.", "MISSING": "A value is empty.", "TYPE": "The wrong kind of value.",
    "UNIT": "The units do not fit.", "DOMAIN": "No real result.", "RANGE": "The result is out of range.",
    "LIMIT": "The step budget is spent.", "SRC": "The source statistic is not available.",
})


def _err(code, msg, node):
    return {"code": code, "msg": msg or _MESSAGES[code], "node": node}


class _Fail(Exception):
    def __init__(self, code, msg="", err=None):
        Exception.__init__(self, code)
        self.code = code
        self.msg = msg
        self.err = err


# ------------------------------------------------------------------ compile
class _Def:
    __slots__ = ("id", "kind", "ast", "text", "decl", "decimals", "tab", "row", "col", "deps",
                 "idx", "value", "dependents")

    def __init__(self, id, kind, idx):
        self.id = id
        self.kind = kind
        self.idx = idx
        self.ast = self.text = self.decl = self.tab = self.row = self.col = self.value = None
        self.decimals = 2
        self.deps = ()
        self.dependents = []


class _Decl:
    """A declared unit: tuple form, dimension, factor to the coherent base, text."""

    __slots__ = ("u", "dim", "factor", "text")

    def __init__(self, text):
        self.u = parse_unit(text)
        if not self.u:
            raise _rej("bad-unit", "Unit cancels to nothing.")
        zero = sum(not _ATOMS[s][1] for s, _ in self.u)
        if 0 < zero < len(self.u):
            raise _rej("bad-unit", "% cannot be combined with other units.")
        self.dim = _dim_of(self.u)
        self.factor = _factor(self.u)
        self.text = _render(self.u)


class _Col:
    __slots__ = ("id", "kind", "decl", "ast", "text", "cells", "index")


class _Tab:
    __slots__ = ("id", "cols", "ci", "nrows", "index")


class CompiledModel:
    """Immutable result of compile_spec; holds no run state."""

    def __init__(self):
        self.defs = {}
        self.order = ()
        self.inputs = ()
        self.cells = ()
        self.tables = {}


def _id_ok(v, label):
    if v is None:
        raise _rej("syntax", label + " needs an id.")
    if not isinstance(v, str) or not _ID.fullmatch(v):
        raise _rej("bad-id", label + " id " + repr(v) + " must match [a-z][a-z0-9_]{0,23}.")
    if v in _RESERVED:
        raise _rej("reserved-id", repr(v) + " is a function, keyword or unit name.")
    return v


def _seq(spec, key):
    v = spec.get(key, [])
    if not isinstance(v, list) or any(not isinstance(x, dict) for x in v):
        raise _rej("syntax", key + " must be a list of objects.")
    return v


def _decl(text, what):
    if text is None or text == "":
        return None
    if not isinstance(text, str):
        raise _rej("bad-unit", what + " unit must be text.")
    return _Decl(text)


def _decimals(d):
    if isinstance(d, bool) or not isinstance(d, (int, float)) or not math.isfinite(d):
        return 2
    return max(0, min(10, int(math.floor(d))))


def _source_cell(raw, col):
    """Parse one literal table cell: ('e',) empty, ('n', x), ('t', text) or ('x', code, msg)."""
    if not isinstance(raw, str):
        raise _rej("row-shape", "Table cells are text.")
    s = raw.strip(" \t\r\n\f\v")
    if s == "":
        return ("e",)
    if col.kind == "text":
        return ("t", s)
    if not _PLAIN_NUMBER.fullmatch(s):
        return ("x", "TYPE", repr(s[:24]) + " is not a plain number.")
    x = float(s)
    if not math.isfinite(x):
        return ("x", "RANGE", repr(s[:24]) + " overflows.")
    return ("n", x)


def _walk_refs(ast):
    stack, out = [ast], []
    while stack:
        a = stack.pop()
        if a[0] in ("name", "col"):
            out.append(a)
        stack.extend(reversed(_kids(a)))
    return out


def compile_spec(spec):
    if not isinstance(spec, dict):
        raise _rej("syntax", "A spec is an object.")
    inputs, tables, cells = _seq(spec, "inputs"), _seq(spec, "tables"), _seq(spec, "cells")
    for items, limit, why, noun in ((inputs, max_inputs, "limit-inputs", "inputs"),
                                    (tables, max_tables, "limit-tables", "tables"),
                                    (cells, max_cells, "limit-cells", "cells")):
        if len(items) > limit:
            raise _rej(why, "More than %d %s." % (limit, noun))
    for t in tables:
        if (not isinstance(t.get("columns", []), list) or not isinstance(t.get("rows", []), list)
                or any(not isinstance(c, dict) for c in t.get("columns", []))):
            raise _rej("syntax", "A table needs columns and rows lists.")
    for t in tables:
        if len(t.get("columns", [])) > max_columns:
            raise _rej("limit-columns", "More than %d columns." % max_columns)
    for t in tables:
        if len(t.get("rows", [])) > max_rows:
            raise _rej("limit-rows", "More than %d rows." % max_rows)
    for t in tables:
        for c in t.get("columns", []):
            if c.get("kind") not in ("number", "text", "formula"):
                raise _rej("syntax", "A column kind is number, text or formula.")
        for row in t.get("rows", []):
            if not isinstance(row, list) or len(row) != len(t.get("columns", [])):
                raise _rej("row-shape", "Every row needs one entry per column.")
    graph = len(inputs) + len(cells) + sum(
        len(t.get("rows", [])) * sum(1 for c in t.get("columns", []) if c["kind"] == "formula") for t in tables)
    if graph > max_graph_nodes:
        raise _rej("limit-graph", "More than %d graph nodes." % max_graph_nodes)

    m = CompiledModel()
    defs, glob, table_ids = m.defs, set(), set()
    # ids: one namespace for inputs, tables and cells
    for src, label in ((inputs, "input"), (tables, "table"), (cells, "cell")):
        for item in src:
            i = _id_ok(item.get("id"), label)
            if i in glob:
                raise _rej("duplicate-id", "Duplicate id '" + i + "'.")
            glob.add(i)
            if label == "table":
                table_ids.add(i)
    for t in tables:
        seen = set()
        for c in t.get("columns", []):
            ci = _id_ok(c.get("id"), "column")
            if ci in seen or ci in glob:
                raise _rej("duplicate-id", "Duplicate id '" + ci + "'.")
            seen.add(ci)

    # units: inputs, then columns, then cells
    input_units = [_decl(i.get("unit"), "input") for i in inputs]
    tabs = {}
    for t in tables:
        tab = _Tab()
        tab.id, tab.cols, tab.nrows = t["id"], [], len(t.get("rows", []))
        for c in t.get("columns", []):
            col = _Col()
            col.id, col.kind = c["id"], c["kind"]
            col.decl = _decl(c.get("unit"), "column") if col.kind != "text" else None
            col.ast = col.text = col.cells = None
            tab.cols.append(col)
        tab.ci = {c.id: n for n, c in enumerate(tab.cols)}
        tabs[tab.id] = tab
    cell_units = [_decl(c.get("unit"), "cell") for c in cells]

    # expressions: formula columns first, then cells
    for t in tables:
        tab = tabs[t["id"]]
        for n, col in enumerate(tab.cols):
            if col.kind == "formula":
                col.text = t["columns"][n].get("expression")
                col.ast = compile_expression(col.text)
            else:
                col.cells = [_source_cell(row[n], col) for row in t.get("rows", [])]
    cell_asts = [compile_expression(c.get("expression")) for c in cells]

    # declaration order: inputs, tables (row by row, formula columns left to right), cells
    idx = 0
    for item, decl in zip(inputs, input_units):
        d = _Def(item["id"], "input", idx)
        idx += 1
        d.decl, d.value = decl, item.get("value")
        defs[d.id] = d
    for t in tables:
        tab = tabs[t["id"]]
        for r in range(tab.nrows):
            for col in tab.cols:
                if col.kind == "formula":
                    d = _Def("%s.%s#%d" % (tab.id, col.id, r + 1), "inst", idx)
                    idx += 1
                    d.ast, d.text, d.decl, d.tab, d.row, d.col = col.ast, col.text, col.decl, tab, r, col
                    defs[d.id] = d
    for c, ast, decl in zip(cells, cell_asts, cell_units):
        d = _Def(c["id"], "cell", idx)
        idx += 1
        d.text, d.ast, d.decl = c.get("expression"), ast, decl
        d.decimals = _decimals(c.get("decimals", 2))
        defs[d.id] = d
    m.inputs = tuple(i["id"] for i in inputs)
    m.cells = tuple(c["id"] for c in cells)
    m.tables = tabs

    # names and table references (one pass per formula column, then per cell), then static edges
    scopes = [(col.ast, tab) for tab in tabs.values() for col in tab.cols if col.kind == "formula"]
    scopes += [(ast, None) for ast in cell_asts]
    for ast, tab in scopes:
        _resolve(ast, tab, glob - table_ids, tabs)
    for d in defs.values():
        if d.ast is not None:
            d.deps = _edges(d.ast, d.tab, d.row, glob - table_ids, tabs)

    # Kahn, ties by declaration order
    byidx = sorted(defs.values(), key=lambda x: x.idx)
    left = {d.id: len(d.deps) for d in byidx}
    for d in byidx:
        for dep in d.deps:
            defs[dep].dependents.append(d.id)
    heap = [d.idx for d in byidx if left[d.id] == 0]
    heapq.heapify(heap)
    order = []
    while heap:
        d = byidx[heapq.heappop(heap)]
        order.append(d.id)
        for nxt in d.dependents:
            left[nxt] -= 1
            if left[nxt] == 0:
                heapq.heappush(heap, defs[nxt].idx)
    if len(order) < len(byidx):
        path = _cycle(defs, {i for i, k in left.items() if k > 0})
        raise _rej("cycle", "Circular reference: " + " -> ".join(path) + ".")
    m.order = tuple(order)
    return m


def _resolve(ast, tab, names, tabs):
    """After every expression parsed: names, tables, call shapes, then Table.column positions."""
    for a in _walk_refs(ast):
        if a[0] == "name":
            if a[1] not in names and not (tab is not None and a[1] in tab.ci):
                raise _rej("unknown-name", "Unknown name '" + a[1] + "'.")
        else:
            if a[1] in names:
                raise _rej("input-as-table", "'" + a[1] + "' is not a table.")
            if a[1] not in tabs:
                raise _rej("unknown-table", "Unknown table '" + a[1] + "'.")
            if a[2] not in tabs[a[1]].ci:
                raise _rej("unknown-column", "Unknown column '" + a[1] + "." + a[2] + "'.")
    calls, stack = [], [ast]
    while stack:
        a = stack.pop()
        if a[0] == "call":
            calls.append(a)
        stack.extend(_kids(a))
    for a in calls:
        if a[1] not in _FUNCS:
            raise _rej("unknown-name", "'" + a[1] + "' is not a function.")
    for a in calls:
        name, args = a[1], a[2]
        if name == "colstat":
            n = args[0]
            if n[0] != "lit" or not n[3] or not n[4] or n[1] < 1:
                raise _rej("colstat-args", "colstat needs a positive integer literal first.")
            if args[1][0] != "word" or args[1][1] not in STAT_WORDS:
                raise _rej("colstat-args", "colstat stat is one of " + "|".join(STAT_WORDS) + ".")
        elif name == "sumproduct" and any(x[0] != "col" for x in args):
            raise _rej("sumproduct-args", "sumproduct takes two column references.")
    stack = [(ast, False)]
    while stack:
        a, ok = stack.pop()
        if a[0] == "col" and not ok:
            raise _rej("colref-outside-aggregate",
                       "Table.column is only valid inside sum, mean, median, count or sumproduct.")
        if a[0] == "call" and a[1] == "sumproduct" and a[2][0][1] != a[2][1][1]:
            raise _rej("sumproduct-args", "sumproduct columns must come from one table.")
        agg = a[0] == "call" and (a[1] in _AGG or a[1] == "sumproduct")
        stack.extend((k, agg) for k in _kids(a))


def _edges(ast, tab, row, names, tabs):
    """Static dependencies: every branch counts, a bare column id means this row."""
    deps = []
    for a in _walk_refs(ast):
        if a[0] == "name":
            if a[1] in names:
                deps.append(a[1])
            elif tab.cols[tab.ci[a[1]]].kind == "formula":
                deps.append("%s.%s#%d" % (tab.id, a[1], row + 1))
        elif tabs[a[1]].cols[tabs[a[1]].ci[a[2]]].kind == "formula":
            deps.extend("%s.%s#%d" % (a[1], a[2], r + 1) for r in range(tabs[a[1]].nrows))
    return tuple(dict.fromkeys(deps))


def _cycle(defs, stuck):
    """One cycle among the nodes Kahn could not order, as a closed id path."""
    cur, path, seen = min(stuck, key=lambda i: defs[i].idx), [], {}
    while cur not in seen:
        seen[cur] = len(path)
        path.append(cur)
        cur = next(d for d in defs[cur].deps if d in stuck)
    return path[seen[cur]:] + [cur]


# ------------------------------------------------------------------ evaluation
class Node:
    __slots__ = ("value", "unit", "err", "deps", "warn", "raw")

    def __init__(self, value, unit, err, deps, warn, raw):
        self.value, self.unit, self.err, self.deps, self.warn, self.raw = value, unit, err, deps, warn, raw


class Result:
    __slots__ = ("nodes", "order", "steps", "stats", "model", "inputs", "env", "costs", "limited")


def _same(a, b):
    if a.err or b.err:
        return a.err is b.err or (bool(a.err) and bool(b.err) and a.err == b.err and a.warn == b.warn)
    return type(a.raw) is type(b.raw) and a.raw == b.raw and a.unit == b.unit and a.value == b.value and a.warn == b.warn


class _Run:
    def __init__(self, model, stats, nodes, cap):
        self.m, self.stats, self.nodes, self.cap = model, stats, nodes, cap
        self.total = self.cell = self.reads = 0
        self.exhausted = False
        self.warn, self.id, self.tab, self.row = [], "", None, None

    # -- accounting and errors
    def tick(self, k=1):
        if self.exhausted:
            raise _Fail("LIMIT", "The pass step budget is spent.")
        if self.cap is not None and self.total + k > self.cap:
            self.exhausted = True
            raise _Fail("LIMIT", "The pass step budget (%d) is spent." % self.cap)
        if self.cell + k > max_cell_steps:
            raise _Fail("LIMIT", "The per-cell step budget (%d) is spent." % max_cell_steps)
        self.total += k
        self.cell += k

    @staticmethod
    def fin(x):
        if not math.isfinite(x.v if type(x) is Q else x):
            raise _Fail("RANGE")
        return x

    # -- node level
    def compute(self, d, override, has_override):
        self.cell, self.reads, self.warn = 0, 0, []
        self.id, self.tab, self.row = d.id, d.tab, d.row
        try:
            if d.kind == "input":
                raw, shown, unit = self.input_value(d, override if has_override else d.value)
            else:
                raw, shown, unit = self.declare(self.ev(d.ast), d.decl)
            node = Node(shown, unit, None, d.deps, tuple(self.warn), raw)
        except (_Fail, ArithmeticError) as f:
            if isinstance(f, ArithmeticError):   # overflow, 0.0 ** -n, decimal trouble: out of range
                f = _Fail("RANGE")
            err = f.err if f.err is not None else _err(f.code, f.msg, d.id)
            node = Node(None, "", err, d.deps, tuple(self.warn), None)
        return node, self.cell, self.reads

    def input_value(self, d, v):
        if v is None:
            raise _Fail("MISSING", "Input '" + d.id + "' is empty.")
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise _Fail("TYPE", "Input '" + d.id + "' is not a number.")
        try:
            x = float(v)
        except OverflowError:
            raise _Fail("RANGE", "Input '" + d.id + "' is out of range.")
        if not math.isfinite(x):
            raise _Fail("RANGE", "Input '" + d.id + "' is out of range.")
        if d.decl is None:
            return x, x, ""
        return self.fin(_lit_q(x, d.decl.u)), x, d.decl.text

    @staticmethod
    def declare(r, decl):
        """Convert a result into the declared unit; returns (raw, shown, unit text)."""
        if type(r) is bool:
            if decl is not None:
                raise _Fail("UNIT", "A true/false result cannot have the unit " + decl.text + ".")
            return r, r, ""
        if decl is None:
            if type(r) is float:
                return r, r, ""
            n = _mkq(r.v, r.u)               # shown in the merged unit; the raw value keeps its atoms
            return r, n.v, _render(n.u)
        if type(r) is float:
            if decl.dim:
                raise _Fail("UNIT", "A plain number cannot have the unit " + decl.text + ".")
            return r, _Run.fin(r / decl.factor), decl.text
        if _dim_of(r.u) != decl.dim:
            raise _Fail("UNIT", _render(r.u) + " does not convert to " + decl.text + ".")
        v = _Run.fin(r.v * _factor(r.u) / decl.factor)
        return _Run.fin(_lit_q(v, decl.u)), v, decl.text

    # -- expression evaluation (one step per node, charged on entry)
    def ev(self, a):
        self.tick()
        k = a[0]
        if k == "lit":
            return self.fin(a[1])
        if k == "name":
            return self.name(a[1])
        if k == "neg":
            x = self.ev(a[1])
            if type(x) is bool:
                raise _Fail("TYPE", "Cannot negate true/false.")
            return -x if type(x) is float else Q(-x.v, x.u)
        if k == "not":
            x = self.ev(a[1])
            if type(x) is not bool:
                raise _Fail("TYPE", "'not' needs true/false.")
            return not x
        if k == "bin":
            return self.binary(a)
        return self.call(a)

    def ref(self, node_id):
        n = self.nodes[node_id]
        if n.err is not None:
            raise _Fail(n.err["code"], err=n.err)
        return n.raw

    def name(self, n):
        if n in self.m.defs:
            return self.ref(n)
        col = self.tab.cols[self.tab.ci[n]]
        if col.kind == "formula":
            return self.ref("%s.%s#%d" % (self.tab.id, n, self.row + 1))
        return self.source(col, self.tab, self.row, True)

    def source(self, col, tab, r, strict):
        """A literal table cell as a value, None when empty and not strict."""
        e = col.cells[r]
        where = "%s.%s#%d" % (tab.id, col.id, r + 1)
        if e[0] == "e":
            if strict:
                raise _Fail("MISSING", "Cell " + where + " is empty.")
            return None
        if e[0] == "t":
            raise _Fail("TYPE", "Cell " + where + " is text, not a number.")
        if e[0] == "x":
            raise _Fail(e[1], where + ": " + e[2])
        return self.fin(_lit_q(e[1], col.decl.u)) if col.decl is not None else e[1]

    def binary(self, a):
        op = a[1]
        x = self.ev(a[2])
        y = self.ev(a[3])
        if op in ("and", "or"):
            if type(x) is not bool or type(y) is not bool:
                raise _Fail("TYPE", "'" + op + "' needs true/false on both sides.")
            return (x and y) if op == "and" else (x or y)
        if op in _CMP:
            return self.compare(op, x, y)
        if type(x) is bool or type(y) is bool:
            raise _Fail("TYPE", "Arithmetic needs numbers, not true/false.")
        if op == "^":
            return self.power(x, y)
        if op in ("*", "/"):
            return self.fin(self.mul(x, y, op == "/"))
        # + - %: the right operand converts to the left unit; a literal 0 takes the other unit
        zero_l = a[2][0] == "lit" and a[2][2]
        zero_r = a[3][0] == "lit" and a[3][2]
        xv, yv, u = self.align(x, y, zero_l, zero_r)
        if op == "%":
            if yv == 0:
                raise _Fail("DIV0")
            r = math.fmod(xv, yv)
        else:
            r = xv + yv if op == "+" else xv - yv
        return self.fin(r if u is None else Q(r, u))

    @staticmethod
    def align(x, y, zero_l=False, zero_r=False):
        """(x value, y value converted to x's unit, unit tuple or None for plain)."""
        if type(x) is float and type(y) is float:
            return x, y, None
        if type(x) is not type(y):
            if type(x) is Q and zero_r:
                y = Q(0.0, x.u)
            elif type(y) is Q and zero_l:
                x = Q(0.0, y.u)
            else:
                raise _Fail("UNIT", "A quantity and a plain number do not mix.")
        if x.u == y.u:
            return x.v, y.v, x.u
        if _dim_of(x.u) != _dim_of(y.u):
            raise _Fail("UNIT", _render(x.u) + " and " + _render(y.u) + " are different kinds of unit.")
        return x.v, y.v * _factor(y.u) / _factor(x.u), x.u

    @staticmethod
    def mul(x, y, div):
        xv, xu = (x, ()) if type(x) is float else (x.v, x.u)
        yv, yu = (y, ()) if type(y) is float else (y.v, y.u)
        if div and yv == 0:
            raise _Fail("DIV0")
        val = xv / yv if div else xv * yv
        if not xu and not yu:
            return val
        cur = [[s, e] for s, e in xu]
        for sym, e in yu:
            e = -e if div else e
            cur.append([sym, e])
        return _mkq(val, tuple((s, e) for s, e in cur if e))

    def power(self, x, y):
        if type(y) is not float:
            raise _Fail("UNIT", "An exponent must be a plain number.")
        if type(x) is Q:
            if y != math.floor(y) or abs(y) > 9:
                raise _Fail("UNIT", "A quantity needs a whole exponent from -9 to 9.")
            if any(abs(e * y) > 1024 for _, e in x.u):
                raise _Fail("RANGE", "The composed unit exponent is out of range.")
            if x.v == 0 and y < 0:
                raise _Fail("DIV0")
            try:
                v = math.pow(x.v, y)
            except OverflowError:
                raise _Fail("RANGE")
            return self.fin(_mkq(v, tuple((s, e * int(y)) for s, e in x.u if e * int(y))))
        if x == 0 and y < 0:
            raise _Fail("DIV0")
        if x < 0 and y != math.floor(y):
            raise _Fail("DOMAIN", "A negative base needs a whole exponent.")
        try:
            return self.fin(math.pow(x, y))
        except OverflowError:
            raise _Fail("RANGE")

    def compare(self, op, x, y):
        if type(x) is bool or type(y) is bool:
            if type(x) is not type(y) or op not in ("==", "!="):
                raise _Fail("TYPE", "Only == and != compare true/false with true/false.")
            return (x == y) == (op == "==")
        xv, yv, _ = self.align(x, y)
        if op == "==":
            return _close(xv, yv)
        if op == "!=":
            return not _close(xv, yv)
        return {"<": xv < yv, "<=": xv <= yv, ">": xv > yv, ">=": xv >= yv}[op]

    # -- calls
    def call(self, a):
        f, args = a[1], a[2]
        if f == "if":
            c = self.ev(args[0])
            if type(c) is not bool:
                raise _Fail("TYPE", "if() needs a true/false condition.")
            return self.ev(args[1] if c else args[2])
        if f == "iferror":
            try:
                return self.ev(args[0])
            except _Fail as e:
                if e.code == "LIMIT":
                    raise
                return self.ev(args[1])
        if f in _AGG:
            return self.aggregate(f, args)
        if f == "sumproduct":
            return self.sumproduct(args)
        if f == "colstat":
            return self.colstat(args)
        if f in ("to", "num"):
            return self.convert(f, args)
        vals = [self.ev(x) for x in args]
        if any(type(v) is bool for v in vals):
            raise _Fail("TYPE", f + "() needs numbers, not true/false.")
        if f in ("abs", "floor", "ceil", "sqrt"):
            return self.unary(f, vals[0])
        if f == "round":
            n = vals[1]
            if type(n) is not float:
                raise _Fail("UNIT", "round() places must be a plain number.")
            if n != math.floor(n) or not 0 <= n <= 10:
                raise _Fail("DOMAIN", "round() places is a whole number from 0 to 10.")
            x = vals[0]
            if not math.isfinite((x if type(x) is float else x.v) * 10.0 ** int(n)):
                raise _Fail("RANGE", "round() would overflow.")
            if type(x) is float:
                return self.fin(_round_to(x, int(n)))
            return Q(self.fin(_round_to(x.v, int(n))), x.u)
        first = vals[0]
        conv = []
        for v in vals:
            xv, yv, _ = self.align(first, v)
            conv.append(yv)
        base = conv[0]
        if f == "min":
            r = min(conv)
        elif f == "max":
            r = max(conv)
        else:  # clamp(v, lo, hi)
            r = max(conv[1], min(conv[2], base))
        return r if type(first) is float else Q(r, first.u)

    def unary(self, f, x):
        v = x if type(x) is float else x.v
        if f == "sqrt":
            if type(x) is Q:
                x = _mkq(x.v, x.u)
                v = x.v
            if type(x) is Q and any(e % 2 for _, e in x.u):
                raise _Fail("UNIT", "sqrt needs a unit with even exponents.")
            if v < 0:
                raise _Fail("DOMAIN", "sqrt of a negative number.")
            r = math.sqrt(v)
            return r if type(x) is float else Q(r, tuple((s, e // 2) for s, e in x.u))
        r = abs(v) if f == "abs" else float(math.floor(v) if f == "floor" else math.ceil(v))
        return r if type(x) is float else Q(r, x.u)

    def convert(self, f, args):
        q = self.ev(args[0])
        self.tick()  # the [unit] argument is a node
        u = args[1][1]
        if type(q) is bool:
            raise _Fail("TYPE", f + "() needs a number or quantity.")
        qv, qu = (q, ()) if type(q) is float else (q.v, q.u)
        if _dim_of(qu) != _dim_of(u):
            raise _Fail("UNIT", "Cannot convert " + (_render(qu) or "a plain number") + " to " + _render(u) + ".")
        v = qv * _factor(qu) / _factor(u) if qu != u else qv
        if f == "num":
            return self.fin(v)
        return q if not _dim_of(u) else self.fin(_lit_q(self.fin(v), u))

    def column(self, tab, col):
        """Per-row values of a column (None for empty source cells); first error wins."""
        out = []
        for r in range(tab.nrows):
            if col.kind == "formula":
                out.append(self.ref("%s.%s#%d" % (tab.id, col.id, r + 1)))
            elif col.kind == "text":
                out.append(None if col.cells[r][0] == "e" else col.cells[r][1])
            else:
                out.append(self.source(col, tab, r, False))
        return out

    def col_arg(self, a):
        tab = self.m.tables[a[1]]
        col = tab.cols[tab.ci[a[2]]]
        self.tick(1 + tab.nrows)
        self.reads += tab.nrows
        return tab, col

    def aggregate(self, f, args):
        vals, ref, texts = [], None, 0
        for a in args:
            if a[0] == "col":
                tab, col = self.col_arg(a)
                rows = self.column(tab, col)
                if col.kind == "text":
                    if f != "count":
                        raise _Fail("TYPE", "A text column cannot be used as numbers.")
                    texts += sum(1 for v in rows if v is not None)
                    mine, here = [], None
                else:
                    mine = [v for v in rows if v is not None]
                    proto = _lit_q(1.0, col.decl.u) if col.decl is not None else 1.0
                    first = mine[0] if col.kind == "formula" and mine else proto
                    here = first.u if type(first) is Q else ()
                if len(mine) < tab.nrows:
                    self.warn.append("%s(%s.%s): %d of %d rows used" % (f, tab.id, col.id, len(mine), tab.nrows))
                vals.extend(mine)
            else:
                v = self.ev(a)
                vals.append(v)
                here = (v.u if type(v) is Q else ())
            if ref is None:
                ref = here
        if f == "count":
            return float(len(vals) + texts)
        if any(type(v) is bool for v in vals):
            raise _Fail("TYPE", f + "() needs numbers, not true/false.")
        nums = self.to_unit(vals, ref or ())
        return self.reduce(f, nums, ref or ())

    def to_unit(self, vals, ref):
        dim, fac = _dim_of(ref), _factor(ref)
        out = []
        for v in vals:
            if type(v) is float:
                if ref:
                    raise _Fail("UNIT", "A plain number does not mix with " + _render(ref) + ".")
                out.append(v)
            else:
                if _dim_of(v.u) != dim:
                    raise _Fail("UNIT", _render(v.u) + " does not convert to " + _render(ref or ()) + ".")
                out.append(v.v if v.u == ref else v.v * _factor(v.u) / fac)
        return out

    def reduce(self, f, nums, ref):
        if f == "sum":
            r = 0.0
            for x in nums:
                r += x
        elif not nums:
            raise _Fail("MISSING", f + "() of no values.")
        elif f == "mean":
            r = 0.0
            for x in nums:
                r += x
            r /= len(nums)
        else:
            s, n = sorted(nums), len(nums)
            r = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2
        self.fin(r)
        return Q(r, ref) if ref else r

    def sumproduct(self, args):
        scanned = []
        for a in args:                       # left to right: a column's error beats a later column's kind
            tab, col = self.col_arg(a)
            if col.kind == "text":
                raise _Fail("TYPE", "sumproduct needs number columns.")
            scanned.append((tab, col, self.column(tab, col)))
        (ta, ca, ra), (tb, cb, rb) = scanned
        prods = []
        for x, y in zip(ra, rb):
            if x is None or y is None:
                continue
            if type(x) is bool or type(y) is bool:
                raise _Fail("TYPE", "sumproduct needs numbers, not true/false.")
            prods.append(self.fin(self.mul(x, y, False)))
        if len(prods) < ta.nrows:
            self.warn.append("sumproduct(%s.%s,%s.%s): %d of %d rows used" % (ta.id, ca.id, tb.id, cb.id, len(prods), ta.nrows))
        proto = self.mul(_lit_q(1.0, ca.decl.u) if ca.decl else 1.0, _lit_q(1.0, cb.decl.u) if cb.decl else 1.0, False)
        ref = (prods[0].u if type(prods[0]) is Q else ()) if prods else (proto.u if type(proto) is Q else ())
        return self.reduce("sum", self.to_unit(prods, ref), ref)

    def colstat(self, args):
        self.tick(2)  # the n and stat-word nodes
        n, word = int(args[0][1]), args[1][1]
        if self.stats is None or n > len(self.stats) or not isinstance(self.stats[n - 1], dict):
            raise _Fail("SRC", "No source statistics for column %d." % n)
        v = self.stats[n - 1].get(word)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise _Fail("SRC", "The source has no " + word + " for column %d." % n)
        return self.fin(float(v))


def _copy_stats(env):
    stats = env.get("stats") if isinstance(env, dict) else None
    if not isinstance(stats, list):
        return None
    return [dict(s) if isinstance(s, dict) else s for s in stats]


def evaluate(model, input_values=None, env=None, prev=None):
    """Evaluate every node in order. Pure; `prev` makes it incremental."""
    ov = input_values if isinstance(input_values, dict) else {}
    eff = {i: (ov[i] if i in ov else model.defs[i].value) for i in model.inputs}
    stats = _copy_stats(env)
    inc = (prev is not None and prev.model is model and not prev.limited and prev.env == stats)
    run = _Run(model, stats, {}, None if inc else max_pass_steps)
    costs, reads = {}, 0
    if inc:
        dirty = {i for i in model.inputs if not _same_input(eff[i], prev.inputs[i])}
        run.nodes = dict(prev.nodes)
        costs = dict(prev.costs)
        evaluated = 0
        for nid in model.order:
            if nid not in dirty:
                continue
            d = model.defs[nid]
            node, cost, rd = run.compute(d, eff.get(nid), nid in eff)
            costs[nid] = (cost, rd)
            evaluated += 1
            if not _same(node, prev.nodes[nid]):
                dirty.update(d.dependents)
                run.nodes[nid] = node
        total = sum(c for c, _ in costs.values())
        if total <= max_pass_steps and not any(n.err and n.err["code"] == "LIMIT" for n in run.nodes.values()):
            return _finish(model, run.nodes, costs, eff, stats, False, evaluated)
        return evaluate(model, input_values, env, None)
    for nid in model.order:
        node, cost, rd = run.compute(model.defs[nid], eff.get(nid), nid in eff)
        run.nodes[nid] = node
        costs[nid] = (cost, rd)
    return _finish(model, run.nodes, costs, eff, stats, run.exhausted, len(model.order))


def _same_input(a, b):
    return type(a) is type(b) and a == b


def _finish(model, nodes, costs, eff, stats, limited, evaluated):
    r = Result()
    r.model, r.nodes, r.order, r.inputs, r.env, r.costs, r.limited = model, nodes, model.order, eff, stats, costs, limited
    r.steps = min(sum(c for c, _ in costs.values()), max_pass_steps)
    r.stats = {"rowReads": sum(rd for _, rd in costs.values()), "evaluated": evaluated}
    return r


# ------------------------------------------------------------------ display + provenance
def format_cell(model, result, node_id):
    d, n = model.defs.get(node_id), result.nodes.get(node_id)
    if d is None or n is None:
        return ""
    if n.err is not None:
        return DASH
    if type(n.value) is bool:
        return "true" if n.value else "false"
    text = fixed_text(n.value, d.decimals)
    return text + " " + n.unit if n.unit else text


def provenance(model, result, node_id):
    d, n = model.defs.get(node_id), result.nodes.get(node_id)
    if d is None or n is None:
        return None
    refs, seen = [], set()
    for a in (_walk_refs(d.ast) if d.ast is not None else ()):
        key = a[1] if a[0] == "name" else a[1] + "." + a[2]
        if key in seen:
            continue
        seen.add(key)
        if a[0] == "name" and a[1] in model.defs:
            t = result.nodes[a[1]]
            refs.append({"name": key, "basis": "input" if model.defs[a[1]].kind == "input" else "cell",
                         "value": t.value, "unit": t.unit, "text": format_cell(model, result, a[1]),
                         "error": t.err["code"] if t.err else None})
        elif a[0] == "name":
            col = d.tab.cols[d.tab.ci[a[1]]]
            inst = "%s.%s#%d" % (d.tab.id, a[1], d.row + 1)
            t = result.nodes.get(inst)
            refs.append({"name": key, "basis": "this row of " + d.tab.id, "value": t.value if t else None,
                         "unit": col.decl.text if col.decl else "", "text": format_cell(model, result, inst),
                         "error": t.err["code"] if t and t.err else None})
        else:
            tab = model.tables[a[1]]
            col = tab.cols[tab.ci[a[2]]]
            used = tab.nrows if col.kind == "formula" else sum(1 for c in col.cells if c[0] != "e")
            refs.append({"name": key, "basis": "column, %d of %d rows used" % (used, tab.nrows), "value": None,
                         "unit": col.decl.text if col.decl else "", "text": "", "error": None})
    shown = format_cell(model, result, node_id)
    unit_note = "No result." if n.err else "Result unit: " + (n.unit or "plain number") + "."
    with_units = ["%s (%s)" % (r["name"], r["unit"]) for r in refs if r["unit"]]
    if with_units:
        unit_note += " Built from " + ", ".join(with_units) + "."
    if d.decl is not None and not n.err:
        unit_note += " Converted to the declared unit " + d.decl.text + "."
    if n.err:
        rounding = "Not shown (error " + n.err["code"] + ")."
    elif type(n.value) is bool or d.kind == "input":
        rounding = "Not rounded."
    else:
        rounding = ("Cleaned to 15 significant digits, then rounded half away from zero to %d places: %s (unrounded %r)."
                    % (d.decimals, fixed_text(n.value, d.decimals), n.value))
    chain = []
    if n.err:
        cur = node_id
        chain.append(cur)
        while len(chain) < 400:
            nxt = next((x for x in result.nodes[cur].deps if result.nodes[x].err is n.err), None)
            if nxt is None:
                break
            chain.append(nxt)
            cur = nxt
    return {"id": node_id, "kind": {"inst": "column-cell"}.get(d.kind, d.kind), "formula": d.text,
            "declaredUnit": d.decl.text if d.decl else "", "value": n.value, "unit": n.unit, "text": shown,
            "refs": refs, "warnings": list(n.warn), "error": n.err, "chain": chain,
            "unitDerivation": unit_note, "rounding": rounding}
