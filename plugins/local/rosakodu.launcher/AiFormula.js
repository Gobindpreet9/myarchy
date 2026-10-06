.pragma library

// Bounded arithmetic formulas for slider readouts — the QML mirror of
// ai_formula.py. Same grammar, same function set, same half-away-from-zero
// rounding, so both engines agree on every shared test vector. Compiled trees
// are tiny arrays; evaluation is pure arithmetic with a finite guard.

var MAX_FORMULA = 200;
var MAX_DEPTH = 32;

var FUNCTIONS = {
    sin: {arity: 1, fn: Math.sin}, cos: {arity: 1, fn: Math.cos}, tan: {arity: 1, fn: Math.tan},
    asin: {arity: 1, fn: Math.asin}, acos: {arity: 1, fn: Math.acos}, atan: {arity: 1, fn: Math.atan},
    sind: {arity: 1, fn: function(v) { return Math.sin(v * Math.PI / 180); }},
    cosd: {arity: 1, fn: function(v) { return Math.cos(v * Math.PI / 180); }},
    tand: {arity: 1, fn: function(v) { return Math.tan(v * Math.PI / 180); }},
    sqrt: {arity: 1, fn: Math.sqrt}, abs: {arity: 1, fn: Math.abs},
    floor: {arity: 1, fn: Math.floor}, ceil: {arity: 1, fn: Math.ceil},
    round: {arity: 1, fn: function(v) { return v >= 0 ? Math.floor(v + 0.5) : Math.ceil(v - 0.5); }},
    min: {arity: 2, fn: Math.min}, max: {arity: 2, fn: Math.max},
    clamp: {arity: 3, fn: function(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }}
};

var TOKEN = /\s*(?:([0-9]+(?:\.[0-9]+)?)|([A-Za-z_][A-Za-z0-9_]*)|([()+\-*/%^,]))/y;

function compile(expression) {
    var text = String(expression === undefined || expression === null ? "" : expression).trim();
    if (!text || text.length > MAX_FORMULA) return null;
    var tokens = [], pos = 0;
    while (pos < text.length) {
        TOKEN.lastIndex = pos;
        var match = TOKEN.exec(text);
        if (!match || match.index !== pos || match[0].length === 0) return null;
        tokens.push(match[1] !== undefined ? match[1] : (match[2] !== undefined ? match[2] : match[3]));
        pos = TOKEN.lastIndex;
    }
    var parser = { tokens: tokens, pos: 0 };
    var tree = parseExpression(parser, 0);
    if (tree === null || parser.pos !== tokens.length) return null;
    return tree;
}

function peek(parser) { return parser.pos < parser.tokens.length ? parser.tokens[parser.pos] : null; }
function take(parser, expected) {
    var token = peek(parser);
    if (token === null) return null;
    if (expected !== undefined && token !== expected) return null;
    parser.pos += 1;
    return token;
}

function parseExpression(parser, depth) {
    if (depth > MAX_DEPTH) return null;
    var node = parseTerm(parser, depth);
    if (node === null) return null;
    while (peek(parser) === "+" || peek(parser) === "-") {
        var op = take(parser);
        var right = parseTerm(parser, depth);
        if (right === null) return null;
        node = ["bin", op, node, right];
    }
    return node;
}

function parseTerm(parser, depth) {
    var node = parsePower(parser, depth);
    if (node === null) return null;
    while (peek(parser) === "*" || peek(parser) === "/" || peek(parser) === "%") {
        var op = take(parser);
        var right = parsePower(parser, depth);
        if (right === null) return null;
        node = ["bin", op, node, right];
    }
    return node;
}

function parsePower(parser, depth) {
    var node = parseUnary(parser, depth);
    if (node === null) return null;
    if (peek(parser) === "^") {
        take(parser, "^");
        var right = parsePower(parser, depth);
        if (right === null) return null;
        node = ["bin", "^", node, right];
    }
    return node;
}

function parseUnary(parser, depth) {
    var token = peek(parser);
    if (token === "-") { take(parser, "-"); var inner = parseUnary(parser, depth); return inner === null ? null : ["neg", inner]; }
    if (token === "+") { take(parser, "+"); return parseUnary(parser, depth); }
    return parsePrimary(parser, depth);
}

function parsePrimary(parser, depth) {
    var token = take(parser);
    if (token === null) return null;
    if (/^[0-9]+(?:\.[0-9]+)?$/.test(token)) return ["num", Number(token)];
    if (token === "(") {
        var inner = parseExpression(parser, depth + 1);
        if (inner === null || take(parser, ")") === null) return null;
        return inner;
    }
    if (token === "x") return ["x"];
    if (token === "pi" || token === "e") return ["const", token];
    if (Object.prototype.hasOwnProperty.call(FUNCTIONS, token)) {
        if (take(parser, "(") === null) return null;
        var args = [parseExpression(parser, depth + 1)];
        if (args[0] === null) return null;
        while (peek(parser) === ",") {
            take(parser, ",");
            var arg = parseExpression(parser, depth + 1);
            if (arg === null) return null;
            args.push(arg);
        }
        if (take(parser, ")") === null) return null;
        if (args.length !== FUNCTIONS[token].arity) return null;
        return ["fn", token, args];
    }
    return null;
}

function evaluate(tree, x) {
    if (tree === null) return null;
    var value;
    try { value = evalNode(tree, Number(x), 0); }
    catch (error) { return null; }
    return typeof value === "number" && isFinite(value) ? value : null;
}

function evalNode(node, x, depth) {
    var value = evalNodeUnchecked(node, x, depth);
    if (typeof value !== "number" || !isFinite(value)) throw new Error("non-finite arithmetic");
    return value;
}

function evalNodeUnchecked(node, x, depth) {
    if (depth > MAX_DEPTH || !node) throw new Error("deep");
    switch (node[0]) {
    case "num": return node[1];
    case "x": return x;
    case "const": return node[1] === "pi" ? Math.PI : Math.E;
    case "neg": return -evalNode(node[1], x, depth + 1);
    case "bin": {
        var left = evalNode(node[2], x, depth + 1);
        var right = evalNode(node[3], x, depth + 1);
        if (node[1] === "+") return left + right;
        if (node[1] === "-") return left - right;
        if (node[1] === "*") return left * right;
        if (node[1] === "/") return left / right;
        if (node[1] === "%") return left % right;
        return Math.pow(left, right);
    }
    case "fn": {
        var fn = FUNCTIONS[node[1]].fn;
        var values = node[2].map(function(arg) { return evalNode(arg, x, depth + 1); });
        return fn.apply(null, values);
    }
    }
    throw new Error("unknown");
}

function formatValue(value, unit, decimals) {
    if (value === null || value === undefined || !isFinite(value)) return "—";
    var places = typeof decimals === "number" ? decimals : 2;
    var scale = Math.pow(10, places);
    var scaled = value * scale;
    var rounded = isFinite(scaled)
        ? (scaled >= 0 ? Math.floor(scaled + 0.5) : Math.ceil(scaled - 0.5)) / scale : value;
    var parts = rounded.toFixed(places).split("e");
    if (parts[0].indexOf(".") >= 0) parts[0] = parts[0].replace(/0+$/, "").replace(/\.$/, "");
    var text = parts.join("e");
    if (text === "" || text === "-0") text = "0";
    return unit ? text + " " + unit : text;
}
