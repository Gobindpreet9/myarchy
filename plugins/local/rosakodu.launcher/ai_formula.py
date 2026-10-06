"""Bounded arithmetic formulas for slider readouts.

A deliberately tiny grammar: numbers, the variable x, constants pi/e,
parentheses, + - * / % ^, and a fixed function set. No property access, calls,
strings, or assignment exist in the grammar, so there is nothing an expression
can do except arithmetic. The QML mirror in AiFormula.js implements the same
grammar; both suites share the same vectors.

Validation (this module) runs at answer-normalization time; evaluation runs
locally in QML as the user moves a slider, with no model round trip.
"""

import math
import re

MAX_FORMULA = 200
MAX_DEPTH = 32

FUNCTIONS = {
    "sin": (1, math.sin), "cos": (1, math.cos), "tan": (1, math.tan),
    "asin": (1, math.asin), "acos": (1, math.acos), "atan": (1, math.atan),
    "sind": (1, lambda v: math.sin(math.radians(v))),
    "cosd": (1, lambda v: math.cos(math.radians(v))),
    "tand": (1, lambda v: math.tan(math.radians(v))),
    "sqrt": (1, math.sqrt), "abs": (1, abs),
    "floor": (1, math.floor), "ceil": (1, math.ceil),
    # Half away from zero keeps Python and the QML mirror identical.
    "round": (1, lambda v: math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)),
    "min": (2, min), "max": (2, max),
    "clamp": (3, lambda v, lo, hi: max(lo, min(hi, v))),
}

_TOKEN = re.compile(r"\s*(?:([0-9]+(?:\.[0-9]+)?)|([A-Za-z_][A-Za-z0-9_]*)|([()+\-*/%^,]))")


class FormulaError(ValueError):
    pass


def compile_formula(expression):
    """Parse an expression into a small tree, or raise FormulaError."""
    text = str(expression or "").strip()
    if not text or len(text) > MAX_FORMULA:
        raise FormulaError("Expression is empty or too long")
    tokens, pos = [], 0
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if not match or match.end() == pos:
            raise FormulaError("Unsupported character in expression")
        tokens.append(match.group(1) or match.group(2) or match.group(3))
        pos = match.end()
    parser = _Parser(tokens)
    tree = parser.expression(0)
    if parser.pos != len(tokens):
        raise FormulaError("Unexpected trailing tokens")
    return tree


class _Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def take(self, expected=None):
        token = self.peek()
        if token is None:
            raise FormulaError("Expression ended unexpectedly")
        if expected is not None and token != expected:
            raise FormulaError("Expected " + expected)
        self.pos += 1
        return token

    def expression(self, depth):
        if depth > MAX_DEPTH:
            raise FormulaError("Expression nests too deeply")
        node = self.term(depth)
        while self.peek() in ("+", "-"):
            op = self.take()
            node = ("bin", op, node, self.term(depth))
        return node

    def term(self, depth):
        node = self.power(depth)
        while self.peek() in ("*", "/", "%"):
            op = self.take()
            node = ("bin", op, node, self.power(depth))
        return node

    def power(self, depth):
        node = self.unary(depth)
        if self.peek() == "^":
            self.take("^")
            node = ("bin", "^", node, self.power(depth))
        return node

    def unary(self, depth):
        token = self.peek()
        if token == "-":
            self.take("-")
            return ("neg", self.unary(depth))
        if token == "+":
            self.take("+")
            return self.unary(depth)
        return self.primary(depth)

    def primary(self, depth):
        token = self.take()
        if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", token):
            return ("num", float(token))
        if token == "(":
            node = self.expression(depth + 1)
            self.take(")")
            return node
        if token == "x":
            return ("x",)
        if token in ("pi", "e"):
            return ("const", token)
        if token in FUNCTIONS:
            arity, _ = FUNCTIONS[token]
            self.take("(")
            args = [self.expression(depth + 1)]
            while self.peek() == ",":
                self.take(",")
                args.append(self.expression(depth + 1))
            self.take(")")
            if len(args) != arity:
                raise FormulaError(token + " expects " + str(arity) + " argument(s)")
            return ("fn", token, args)
        raise FormulaError("Unknown name in expression")


def evaluate_formula(tree, x):
    """Evaluate a compiled tree; returns None when the result is not finite."""
    try:
        value = _eval(tree, float(x), 0)
    except (ValueError, OverflowError, ZeroDivisionError, RecursionError):
        return None
    if not math.isfinite(value):
        return None
    return value


def _eval(node, x, depth):
    value = _eval_unchecked(node, x, depth)
    if not math.isfinite(value):
        raise ValueError("non-finite arithmetic")
    return value


def _eval_unchecked(node, x, depth):
    if depth > MAX_DEPTH:
        raise ValueError("too deep")
    kind = node[0]
    if kind == "num":
        return node[1]
    if kind == "x":
        return x
    if kind == "const":
        return math.pi if node[1] == "pi" else math.e
    if kind == "neg":
        return -_eval(node[1], x, depth + 1)
    if kind == "bin":
        left = _eval(node[2], x, depth + 1)
        right = _eval(node[3], x, depth + 1)
        if node[1] == "+":
            return left + right
        if node[1] == "-":
            return left - right
        if node[1] == "*":
            return left * right
        if node[1] == "/":
            return left / right
        if node[1] == "%":
            return math.fmod(left, right)
        # Real arithmetic only: fractional powers of negative bases must fail
        # through the domain guard, not produce a complex value.
        return math.pow(left, right)
    if kind == "fn":
        _, fn = FUNCTIONS[node[1]]
        return fn(*[_eval(arg, x, depth + 1) for arg in node[2]])
    raise ValueError("unknown node")


def validate_expression(expression):
    """Return the compiled tree or raise FormulaError."""
    return compile_formula(expression)


def format_value(value, unit="", decimals=2):
    """Inexpensive display formatting shared with the QML readout."""
    if value is None or not math.isfinite(value):
        return "—"
    scale = 10 ** decimals
    scaled = value * scale
    rounded = ((math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)) / scale
               if math.isfinite(scaled) else value)
    text = str(rounded) if abs(rounded) >= 1e21 else f"{rounded:.{decimals}f}"
    mantissa, separator, exponent = text.partition("e")
    if "." in mantissa:
        mantissa = mantissa.rstrip("0").rstrip(".")
    text = mantissa + separator + exponent
    if text in ("", "-0"):
        text = "0"
    return text + (" " + unit if unit else "")
