.pragma library

// Typed computation runtime (JS engine) - the QML twin of ai_calc.py. Both
// engines are written from tests/CalcGolden.js, which pins every rule (grammar,
// units, rounding, limits, error codes); read its header before changing
// anything here.
//
//   compileSpec(spec)                         -> model, or THROWS {why, msg}
//   evaluate(model, inputValues, env, prev)   -> result (pure; prev = incremental)
//   formatCell(model, result, id)             -> display text
//   provenance(model, result, id)             -> plain object, or null
//
// Compile rejects throw an instance of a private class with own fields
// {why, msg}; `why` is a slug from the golden header. Runtime errors are values:
// result.nodes[id].err = {code, msg, node} (node = where it first arose).
// result.nodes[id] = {value, unit, err, deps, warn, q, steps, from}; q (the
// typed value other nodes read) and steps (cost, for incremental totals) are
// engine internals. No module-level mutable state: V4 shares this file across
// importers, so everything lives in one closure and the exports are copies.

// Limits (identical in ai_calc.py; the engine reads its own copy at load).
var maxExpressionChars = 200;
var maxTokens = 120;
var maxNodes = 80;
var maxDepth = 32;
var maxCallArgs = 6;
var maxInputs = 12;
var maxCells = 24;
var maxTables = 2;
var maxColumns = 12;
var maxRows = 40;
var maxGraphNodes = 300;
var maxPassSteps = 50000;
var maxCellSteps = 5000;

var _calc = (function () {
"use strict";

var LIM = {
    maxExpressionChars: maxExpressionChars,
    maxTokens: maxTokens,
    maxNodes: maxNodes,
    maxDepth: maxDepth,
    maxCallArgs: maxCallArgs,
    maxInputs: maxInputs,
    maxCells: maxCells,
    maxTables: maxTables,
    maxColumns: maxColumns,
    maxRows: maxRows,
    maxGraphNodes: maxGraphNodes,
    maxPassSteps: maxPassSteps,
    maxCellSteps: maxCellSteps
};

// ---------------------------------------------------------------- small helpers
function Rej(why, msg) { this.why = why; this.msg = msg; }
function rej(why, msg) { return new Rej(why, msg); }
function CalcErr(code, msg, node) { this.code = code; this.msg = msg; this.node = node; }
function hasOwn(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
function isDigit(c) { return c >= 48 && c <= 57; }
function isAlpha(c) { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122); }
function isIdText(s) {
    if (s.length < 1 || s.length > 24) return false;
    var c = s.charCodeAt(0);
    if (c < 97 || c > 122) return false;
    for (var i = 1; i < s.length; ++i) {
        c = s.charCodeAt(i);
        if (!((c >= 97 && c <= 122) || isDigit(c) || c === 95)) return false;
    }
    return true;
}
function trimAscii(s) {
    var a = 0, b = s.length, c;
    while (a < b && ((c = s.charCodeAt(a)) === 32 || c === 9 || c === 10 || c === 13 || c === 11 || c === 12)) ++a;
    while (b > a && ((c = s.charCodeAt(b - 1)) === 32 || c === 9 || c === 10 || c === 13 || c === 11 || c === 12)) --b;
    return s.slice(a, b);
}
function zeros(n) { var s = ""; while (n-- > 0) s += "0"; return s; }
var NO_WARN = Object.freeze([]);

// ---------------------------------------------------------------- units
var ATOMS = Object.create(null);
function defAtom(sym, dims, scale) { ATOMS[sym] = {dims: dims, scale: scale, dim: ""}; }
(function () {
    var L = "length", M = "mass", T = "time", D = "data", P = "pixel", i;
    var table = [["mm", L, 1e-3], ["cm", L, 1e-2], ["m", L, 1], ["km", L, 1e3], ["in", L, 0.0254], ["ft", L, 0.3048],
        ["mi", L, 1609.344], ["g", M, 1e-3], ["kg", M, 1], ["lb", M, 0.45359237], ["oz", M, 0.028349523125],
        ["s", T, 1], ["min", T, 60], ["h", T, 3600], ["d", T, 86400], ["wk", T, 604800],
        ["B", D, 1], ["kB", D, 1e3], ["MB", D, 1e6], ["GB", D, 1e9], ["TB", D, 1e12],
        ["KiB", D, 1024], ["MiB", D, 1048576], ["GiB", D, 1073741824], ["TiB", D, 1099511627776], ["px", P, 1]];
    for (i = 0; i < table.length; ++i) defAtom(table[i][0], [[table[i][1], 1]], table[i][2]);
    defAtom("J", [[M, 1], [L, 2], [T, -2]], 1); defAtom("Wh", [[M, 1], [L, 2], [T, -2]], 3600);
    defAtom("kWh", [[M, 1], [L, 2], [T, -2]], 3.6e6);
    defAtom("W", [[M, 1], [L, 2], [T, -3]], 1); defAtom("kW", [[M, 1], [L, 2], [T, -3]], 1e3);
    defAtom("Hz", [[T, -1]], 1); defAtom("GHz", [[T, -1]], 1e9);
    defAtom("%", [], 0.01);
    // Every ISO-4217 alphabetic code is its own base dimension (never converts).
    var iso = ("AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF "
        + "CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL "
        + "HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL "
        + "MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON "
        + "RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH "
        + "UGX USD UYU UZS VES VND VUV WST XAF XCD XOF XPF YER ZAR ZMW ZWL").split(" ");
    for (i = 0; i < iso.length; ++i) defAtom(iso[i], [[iso[i], 1]], 1);
    for (var sym in ATOMS) ATOMS[sym].dim = dimKeyOf([{s: sym, e: 1}]);
})();

function powInt(base, e) {
    var r = 1, n = e < 0 ? -e : e;
    // Defensive constant-time fallback even if a future caller misses the
    // composed-exponent guard. Preserve existing small-power rounding.
    if (n > 1024) return Math.pow(base, e);
    while (n-- > 0) r *= base;
    return e < 0 ? 1 / r : r;
}
function ratioPow(from, to, e) { return e >= 0 ? powInt(from / to, e) : powInt(to / from, -e); }
function dimKeyOf(atoms) {
    var dims = {}, names = [], i, j, key = "";
    for (i = 0; i < atoms.length; ++i) {
        var at = ATOMS[atoms[i].s];
        for (j = 0; j < at.dims.length; ++j) {
            var n = at.dims[j][0];
            if (dims[n] === undefined) { dims[n] = 0; names.push(n); }
            dims[n] += at.dims[j][1] * atoms[i].e;
        }
    }
    names.sort();
    for (i = 0; i < names.length; ++i) if (dims[names[i]] !== 0) key += names[i] + ":" + dims[names[i]] + ";";
    return key;
}
function makeUnit(atoms) {
    var scale = 1;
    for (var i = 0; i < atoms.length; ++i) scale *= powInt(ATOMS[atoms[i].s].scale, atoms[i].e);
    return {atoms: atoms, dim: dimKeyOf(atoms), scale: scale};
}
function unitText(atoms) {
    var num = [], den = [], i;
    for (i = 0; i < atoms.length; ++i) {
        var a = atoms[i], x = a.e > 0 ? a.e : -a.e, t = a.s + (x > 1 ? "^" + x : "");
        (a.e > 0 ? num : den).push(t);
    }
    if (!num.length && !den.length) return "";
    var head = num.length ? num.join("*") : "1";
    return den.length ? head + "/" + (den.length > 1 ? "(" + den.join("*") + ")" : den[0]) : head;
}
function sameUnit(a, b) {
    if (a === b) return true;
    if (!a || !b || a.atoms.length !== b.atoms.length) return false;
    for (var i = 0; i < a.atoms.length; ++i)
        if (a.atoms[i].s !== b.atoms[i].s || a.atoms[i].e !== b.atoms[i].e) return false;
    return true;
}
function negAtoms(atoms) { return atoms.map(function (a) { return {s: a.s, e: -a.e}; }); }

// "kg*m/s^2" -> [{s,e}...] exactly as written; throws bad-unit / unknown-unit.
function parseUnitGroup(text) {
    var out = [], i = 0, n = text.length, sign = 1, unknown = null;
    if (n === 0) throw rej("bad-unit", "Empty unit brackets.");
    for (;;) {
        var j = i;
        while (j < n && (isAlpha(text.charCodeAt(j)) || text.charAt(j) === "%")) ++j;
        if (j === i) throw rej("bad-unit", "Bad unit text '" + text + "'.");
        var sym = text.slice(i, j), e = 1;
        if (ATOMS[sym] === undefined && unknown === null) unknown = sym;
        if (text.charAt(j) === "^") {
            var d = text.charCodeAt(j + 1);
            if (!(d >= 49 && d <= 57)) throw rej("bad-unit", "Unit exponent must be one digit 1-9.");
            e = d - 48; j += 2;
        }
        out.push({s: sym, e: sign * e});
        if (j === n) {
            if (unknown !== null) throw rej("unknown-unit", "Unknown unit '" + unknown + "'.");
            return out;
        }
        var op = text.charAt(j);
        if (op !== "*" && op !== "/") throw rej("bad-unit", "Bad unit text '" + text + "'.");
        sign = op === "/" ? -1 : 1;
        i = j + 1;
    }
}
// Combine atoms the way multiplication does: an IDENTICAL symbol cancels or adds
// exactly first (no conversion), then a symbol of an already-present dimension
// merges into the first-occurring symbol of that dimension (scale folded into
// `factor`). Exponents that reach 0 vanish.
function normalizeAtoms(list) {
    var same = [], atoms = [], factor = 1, i, j;
    for (i = 0; i < list.length; ++i) {
        var hit = -1;
        for (j = 0; j < same.length; ++j) if (same[j].s === list[i].s) { hit = j; break; }
        if (hit < 0) same.push({s: list[i].s, e: list[i].e}); else same[hit].e += list[i].e;
    }
    for (i = 0; i < same.length; ++i) {
        if (same[i].e === 0) continue;
        var at = ATOMS[same[i].s], at2 = -1;
        for (j = 0; j < atoms.length; ++j) if (ATOMS[atoms[j].s].dim === at.dim) { at2 = j; break; }
        if (at2 < 0) atoms.push({s: same[i].s, e: same[i].e});
        else {
            factor *= ratioPow(at.scale, ATOMS[atoms[at2].s].scale, same[i].e);
            atoms[at2].e += same[i].e;
        }
    }
    return {atoms: atoms.filter(function (x) { return x.e !== 0; }), factor: factor};
}
// A written unit used as a VALUE unit (literal): zero-dimension atoms (%) fold
// into the number; the rest stays as written (identical symbols summed) until a
// product or the final result normalises it.
function foldGroup(group) {
    var atoms = [], factor = 1, i, j;
    for (i = 0; i < group.length; ++i) {
        var g = group[i], at = ATOMS[g.s], hit = -1;
        if (at.dim === "") { factor *= powInt(at.scale, g.e); continue; }
        for (j = 0; j < atoms.length; ++j) if (atoms[j].s === g.s) { hit = j; break; }
        if (hit < 0) atoms.push({s: g.s, e: g.e}); else atoms[hit].e += g.e;
    }
    atoms = atoms.filter(function (a) { return a.e !== 0; });
    if (!atoms.length) return {factor: factor, unit: null};
    var u = makeUnit(atoms);
    return u.dim === "" ? {factor: factor * u.scale, unit: null} : {factor: factor, unit: u};
}
// Final form of a typed value: merged atoms, dimensionless collapsed to a plain number.
function normQ(q, c) {
    if (!q.u) return q;
    var n = normalizeAtoms(q.u.atoms);
    if (n.atoms.some(function (x) { return Math.abs(x.e) > 1024; }))
        throw fail(c, "RANGE", "The composed unit exponent is out of range.");
    if (n.factor === 1 && n.atoms.length === q.u.atoms.length) {
        var same = true;
        for (var i = 0; i < n.atoms.length; ++i) if (n.atoms[i].s !== q.u.atoms[i].s || n.atoms[i].e !== q.u.atoms[i].e) same = false;
        if (same) return q;
    }
    if (!n.atoms.length) return {v: q.v * n.factor, u: null};
    var u = makeUnit(n.atoms);
    return u.dim === "" ? {v: q.v * n.factor * u.scale, u: null} : {v: q.v * n.factor, u: u};
}
// A unit used as a conversion target / declaration: {atoms, unit, dim, scale, text, zero}.
function makeTarget(group) {
    var atoms = [], i, j, zero = 0;
    for (i = 0; i < group.length; ++i) {
        var hit = -1;
        for (j = 0; j < atoms.length; ++j) if (atoms[j].s === group[i].s) { hit = j; break; }
        if (hit < 0) atoms.push({s: group[i].s, e: group[i].e}); else atoms[hit].e += group[i].e;
    }
    atoms = atoms.filter(function (a) { return a.e !== 0; });
    if (!atoms.length) throw rej("bad-unit", "Unit cancels to nothing.");
    for (i = 0; i < atoms.length; ++i) if (ATOMS[atoms[i].s].dim === "") zero += 1;
    if (zero > 0 && zero < atoms.length) throw rej("bad-unit", "% cannot be combined with other units.");
    var u = makeUnit(atoms);
    return {atoms: atoms, unit: u.dim === "" ? null : u, dim: u.dim, scale: u.scale, text: unitText(atoms), zero: u.dim === ""};
}
function declUnit(text, what) {
    if (text === undefined || text === null) return null;
    if (typeof text !== "string") throw rej("bad-unit", what + " unit must be text.");
    return text === "" ? null : makeTarget(parseUnitGroup(text));
}

// ---------------------------------------------------------------- number display
// Decimal digits of CLEAN(v): v.toPrecision(15) is the exact decimal rendering of
// the double rounded to 15 significant digits; rounding then works on that
// string only, so half-away-from-zero is decided on decimal digits.
function digitsOf(v) {
    var a = Math.abs(v);
    if (a === 0) return {neg: false, ip: "0", fp: ""};
    var s = a.toPrecision(15), ePos = s.indexOf("e"), exp = 0, mant = s;
    if (ePos >= 0) { exp = Number(s.slice(ePos + 1)); mant = s.slice(0, ePos); }
    var dot = mant.indexOf("."), point = (dot < 0 ? mant.length : dot) + exp;
    var digits = dot < 0 ? mant : mant.slice(0, dot) + mant.slice(dot + 1);
    if (point <= 0) return {neg: v < 0, ip: "0", fp: zeros(-point) + digits};
    if (point >= digits.length) return {neg: v < 0, ip: digits + zeros(point - digits.length), fp: ""};
    return {neg: v < 0, ip: digits.slice(0, point), fp: digits.slice(point)};
}
function fixedString(v, places) {
    var d = digitsOf(v), ip = d.ip, fp = d.fp;
    if (fp.length > places) {
        var up = fp.charCodeAt(places) >= 53;
        fp = fp.slice(0, places);
        if (up) {
            var all = (ip + fp).split(""), k = all.length - 1;
            while (k >= 0) {
                if (all[k] === "9") { all[k] = "0"; --k; } else { all[k] = String.fromCharCode(all[k].charCodeAt(0) + 1); break; }
            }
            var joined = (k < 0 ? "1" : "") + all.join("");
            ip = joined.slice(0, joined.length - places); fp = joined.slice(joined.length - places);
        }
    } else fp += zeros(places - fp.length);
    var isZero = /^0*$/.test(ip + fp);
    return (d.neg && !isZero ? "-" : "") + ip + (places > 0 ? "." + fp : "");
}
function roundHalfAway(v, places) { return Number(fixedString(v, places)); }
function looseEq(a, b) {
    if (a === b) return true;
    return Math.abs(a - b) <= 1e-9 * Math.max(Math.abs(a), Math.abs(b));
}

// ---------------------------------------------------------------- lexer + parser
var FUNCS = Object.create(null);
(function () {
    var spec = {abs: [1, 1], floor: [1, 1], ceil: [1, 1], sqrt: [1, 1], min: [2, 6], max: [2, 6], clamp: [3, 3],
        round: [2, 2], "if": [3, 3], iferror: [2, 2], to: [2, 2], num: [2, 2], sum: [1, 6], mean: [1, 6],
        median: [1, 6], count: [1, 6], sumproduct: [2, 2], colstat: [2, 2]};
    for (var k in spec) FUNCS[k] = {min: spec[k][0], max: spec[k][1]};
})();
var KEYWORDS = Object.create(null);
KEYWORDS.or = true; KEYWORDS.and = true; KEYWORDS.not = true;
var STATS = ["count", "empty", "min", "max", "sum", "mean"];
var RESERVED = Object.create(null);
(function () {
    var k;
    for (k in FUNCS) RESERVED[k] = true;
    for (k in KEYWORDS) RESERVED[k] = true;
    for (k in ATOMS) if (isIdText(k)) RESERVED[k] = true;
})();
var AGGREGATES = Object.create(null);
AGGREGATES.sum = AGGREGATES.mean = AGGREGATES.median = AGGREGATES.count = AGGREGATES.sumproduct = true;
var CMP_OPS = Object.create(null);
CMP_OPS["=="] = CMP_OPS["!="] = CMP_OPS["<"] = CMP_OPS["<="] = CMP_OPS[">"] = CMP_OPS[">="] = true;

function lex(src) {
    var toks = [], i = 0, n = src.length, unknown = null;
    while (i < n) {
        var c = src.charCodeAt(i), ch = src.charAt(i), j;
        if (c === 32 || c === 9) { ++i; continue; }
        if (isDigit(c)) {
            j = i;
            while (j < n && isDigit(src.charCodeAt(j))) ++j;
            if (src.charAt(j) === "." && j + 1 < n && isDigit(src.charCodeAt(j + 1))) {
                ++j;
                while (j < n && isDigit(src.charCodeAt(j))) ++j;
            }
            var d = j < n ? src.charCodeAt(j) : 0;
            if (isAlpha(d) || d === 95) {
                if (d === 101 || d === 69) {
                    var k = j + 1;
                    if (src.charAt(k) === "+" || src.charAt(k) === "-") ++k;
                    if (k < n && isDigit(src.charCodeAt(k)))
                        throw rej("scientific-literal", "Scientific notation is not allowed; write the digits out.");
                }
                throw rej("syntax", "A number cannot run into letters.");
            }
            toks.push({t: "num", s: src.slice(i, j), at: i, end: j});
            i = j; continue;
        }
        if (isAlpha(c) || c === 95) {
            j = i + 1;
            while (j < n && (isAlpha(src.charCodeAt(j)) || isDigit(src.charCodeAt(j)) || src.charCodeAt(j) === 95)) ++j;
            toks.push({t: "name", s: src.slice(i, j), at: i, end: j});
            i = j; continue;
        }
        if (ch === "[") {
            j = src.indexOf("]", i + 1);
            if (j < 0) throw rej("bad-unit", "Unit bracket is not closed.");
            var inner = src.slice(i + 1, j);
            if (inner.indexOf("[") >= 0) throw rej("bad-unit", "Unit brackets cannot nest.");
            var prev = toks.length ? toks[toks.length - 1] : null;
            var group;
            try { group = parseUnitGroup(inner); }
            catch (ue) {   // a malformed group anywhere beats an unknown symbol anywhere
                if (!(ue instanceof Rej) || ue.why !== "unknown-unit") throw ue;
                if (unknown === null) unknown = ue;
                group = [{s: "m", e: 1}];
            }
            toks.push({t: "unit", s: inner, at: i, end: j + 1, group: group,
                glued: !!prev && prev.t === "num" && prev.end === i});
            i = j + 1; continue;
        }
        var two = src.slice(i, i + 2);
        if (two === "==" || two === "!=" || two === "<=" || two === ">=") { toks.push({t: "op", s: two, at: i, end: i + 2}); i += 2; continue; }
        if ("+-*/%^(),.<>".indexOf(ch) >= 0) { toks.push({t: "op", s: ch, at: i, end: i + 1}); ++i; continue; }
        throw rej("syntax", "Unexpected character '" + ch + "' at " + (i + 1) + ".");
    }
    if (unknown !== null) throw unknown;
    if (toks.length > LIM.maxTokens) throw rej("tokens", "More than " + LIM.maxTokens + " tokens.");
    return toks;
}

// env: {lookup(name) -> {kind:"node",idx}|{kind:"row",col}|null, table(name) -> table|"global"|null}
function parseExpression(src, env) {
    if (typeof src !== "string") throw rej("syntax", "An expression must be text.");
    for (var q = 0; q < src.length; ++q)
        if (src.charCodeAt(q) > 127) throw rej("non-ascii", "Only ASCII characters are allowed (found U+" + src.charCodeAt(q).toString(16).toUpperCase() + ").");
    if (src.length > LIM.maxExpressionChars) throw rej("length", "Longer than " + LIM.maxExpressionChars + " characters.");
    if (trimAscii(src) === "") throw rej("empty", "Expression is empty.");
    var toks = lex(src), pos = 0, count = 0, pending = null;
    function defer(why, msg) { if (pending === null) pending = rej(why, msg); }
    function hole() { return mk({k: "num", q: {v: 0, u: null}, lit0: false}); }

    function peek() { return pos < toks.length ? toks[pos] : null; }
    function isOp(t, s) { return t !== null && t.t === "op" && t.s === s; }
    function isWord(t, s) { return t !== null && t.t === "name" && t.s === s; }
    function unexpected(t) {
        if (t === null) throw rej("syntax", "The expression ends too early.");
        if (t.t === "unit") throw rej("unit-position", "A [unit] must directly follow a number (or be the second argument of to/num).");
        throw rej("syntax", "Unexpected '" + t.s + "' at " + (t.at + 1) + ".");
    }
    function expectOp(s) { var t = peek(); if (!isOp(t, s)) unexpected(t); ++pos; }
    function mk(node, kids) {
        if (++count > LIM.maxNodes) throw rej("nodes", "More than " + LIM.maxNodes + " nodes.");
        var h = 0;
        if (kids) for (var i = 0; i < kids.length; ++i) if (kids[i].h > h) h = kids[i].h;
        node.h = h + 1;
        if (node.h > LIM.maxDepth) throw rej("depth", "Nested deeper than " + LIM.maxDepth + ".");
        return node;
    }
    function nameOk(t) {
        if (KEYWORDS[t.s] === true) throw rej("syntax", "'" + t.s + "' is a keyword.");
        var c = t.s.charCodeAt(0);
        for (var i = 0; i < t.s.length; ++i) {
            var x = t.s.charCodeAt(i);
            if (x >= 65 && x <= 90) throw rej("syntax", "Names are lowercase: '" + t.s + "'.");
        }
        if (c === 95) throw rej("syntax", "A name cannot start with an underscore.");
    }

    function parseOr() {
        var l = parseAnd();
        while (isWord(peek(), "or")) { ++pos; var r = parseAnd(); l = mk({k: "logic", op: "or", a: l, b: r}, [l, r]); }
        return l;
    }
    function parseAnd() {
        var l = parseNot();
        while (isWord(peek(), "and")) { ++pos; var r = parseNot(); l = mk({k: "logic", op: "and", a: l, b: r}, [l, r]); }
        return l;
    }
    function parseNot() {
        if (isWord(peek(), "not")) { ++pos; var a = parseNot(); return mk({k: "not", a: a}, [a]); }
        return parseCmp();
    }
    function parseCmp() {
        var l = parseAdd(), t = peek();
        if (t !== null && t.t === "op" && CMP_OPS[t.s] === true) {
            ++pos;
            var r = parseAdd(), node = mk({k: "cmp", op: t.s, a: l, b: r}, [l, r]), t2 = peek();
            if (t2 !== null && t2.t === "op" && CMP_OPS[t2.s] === true)
                throw rej("chained-comparison", "Comparisons do not chain; write 1<2 and 2<3.");
            return node;
        }
        return l;
    }
    function parseAdd() {
        var l = parseMul();
        for (;;) {
            var t = peek();
            if (!(isOp(t, "+") || isOp(t, "-"))) return l;
            ++pos;
            var r = parseMul();
            l = mk({k: "bin", op: t.s, a: l, b: r}, [l, r]);
        }
    }
    function parseMul() {
        var l = parseUnary();
        for (;;) {
            var t = peek();
            if (!(isOp(t, "*") || isOp(t, "/") || isOp(t, "%"))) return l;
            ++pos;
            var r = parseUnary();
            l = mk({k: "bin", op: t.s, a: l, b: r}, [l, r]);
        }
    }
    function parseUnary() {
        if (isOp(peek(), "-")) { ++pos; var a = parseUnary(); return mk({k: "neg", a: a}, [a]); }
        return parsePow();
    }
    function parsePow() {
        var base = parsePrimary();
        if (isOp(peek(), "^")) { ++pos; var e = parseUnary(); return mk({k: "bin", op: "^", a: base, b: e}, [base, e]); }
        return base;
    }
    function parsePrimary() {
        var t = peek();
        if (t === null) unexpected(null);
        if (t.t === "num") {
            ++pos;
            var v = Number(t.s), nx = peek(), unit = null, lit0 = v === 0;
            if (nx !== null && nx.t === "unit" && nx.glued) {
                ++pos; lit0 = false;
                var f = foldGroup(nx.group);
                v = v * f.factor; unit = f.unit;
            }
            return mk({k: "num", q: {v: v, u: unit}, lit0: lit0});
        }
        if (isOp(t, "(")) { ++pos; var inner = parseOr(); expectOp(")"); return inner; }
        if (t.t === "name") {
            nameOk(t);
            var nx2 = pos + 1 < toks.length ? toks[pos + 1] : null;
            if (isOp(nx2, "(")) { pos += 2; return parseCall(t); }
            if (isOp(nx2, ".")) return parseColRef(t);
            ++pos;
            var r = t.s.length <= 24 ? env.lookup(t.s) : null;
            if (!r) { defer("unknown-name", "Unknown name '" + t.s + "'."); return hole(); }
            return r.kind === "node" ? mk({k: "ref", idx: r.idx, name: t.s}) : mk({k: "row", col: r.col, name: t.s});
        }
        unexpected(t);
    }
    function parseColRef(t) {
        var ct = pos + 2 < toks.length ? toks[pos + 2] : null;
        if (ct === null || ct.t !== "name") unexpected(ct);
        nameOk(ct);
        pos += 3;
        var tb = t.s.length <= 24 ? env.table(t.s) : null;
        if (tb === "global") { defer("input-as-table", "'" + t.s + "' is not a table."); return hole(); }
        if (!tb) { defer("unknown-table", "Unknown table '" + t.s + "'."); return hole(); }
        var ci = tb.colIndex[ct.s];
        if (ci === undefined) { defer("unknown-column", "Table '" + t.s + "' has no column '" + ct.s + "'."); return hole(); }
        return mk({k: "col", tbl: tb.index, col: ci, name: t.s + "." + ct.s, agg: false});
    }
    function parseColstat() {
        var groups = [[]], depth = 0;
        for (;;) {
            var t = peek();
            if (t === null) unexpected(null);
            ++pos;
            if (t.t === "unit" && !t.glued) unexpected(t);
            if (isOp(t, "(")) ++depth;
            else if (isOp(t, ")")) { if (depth === 0) break; --depth; }
            else if (isOp(t, ",") && depth === 0) { groups.push([]); continue; }
            groups[groups.length - 1].push(t);
        }
        for (var gi = 0; gi < groups.length; ++gi)
            for (var ti = 0; ti < groups[gi].length; ++ti) if (groups[gi][ti].t === "name") nameOk(groups[gi][ti]);
        if (groups.length === 1 && groups[0].length === 0) throw rej("syntax", "colstat() needs arguments.");
        if (groups.length > LIM.maxCallArgs) throw rej("args", "More than " + LIM.maxCallArgs + " arguments.");
        if (groups.length !== 2) throw rej("arity", "colstat takes (n, stat).");
        var a = groups[0], b = groups[1];
        if (a.length !== 1 || a[0].t !== "num" || a[0].s.indexOf(".") >= 0 || Number(a[0].s) < 1 || !isFinite(Number(a[0].s))) {
            defer("colstat-args", "colstat needs a positive whole-number literal first."); return hole();
        }
        if (b.length !== 1 || b[0].t !== "name" || STATS.indexOf(b[0].s) < 0) {
            defer("colstat-args", "colstat stat must be one of " + STATS.join("|") + "."); return hole();
        }
        var nNode = mk({k: "csn"}), sNode = mk({k: "css"});
        return mk({k: "call", fn: "colstat", args: [nNode, sNode], n: Number(a[0].s), stat: b[0].s}, [nNode, sNode]);
    }
    function parseCall(t) {
        var name = t.s, def = FUNCS[name];
        if (def === undefined) defer("unknown-name", "Unknown function '" + name + "'.");
        if (name === "colstat") return parseColstat();
        if (isOp(peek(), ")")) throw rej("syntax", name + "() needs arguments.");
        var args = [];
        for (;;) {
            var p = peek();
            if ((name === "to" || name === "num") && def !== undefined && args.length === 1 && p !== null && p.t === "unit") {
                ++pos;
                args.push(mk({k: "unit", tu: makeTarget(p.group)}));
            } else args.push(parseOr());
            var s = peek();
            if (isOp(s, ",")) { ++pos; continue; }
            if (isOp(s, ")")) { ++pos; break; }
            unexpected(s);
        }
        if (def === undefined) return hole();
        if (args.length > LIM.maxCallArgs) throw rej("args", "More than " + LIM.maxCallArgs + " arguments.");
        if (args.length < def.min || args.length > def.max)
            throw rej("arity", name + " takes " + (def.min === def.max ? def.min : def.min + " to " + def.max) + " arguments.");
        if ((name === "to" || name === "num") && args[1].k !== "unit")
            throw rej("unit-position", name + " needs a [unit] as its second argument.");
        if (AGGREGATES[name] === true) {
            for (var i = 0; i < args.length; ++i) if (args[i].k === "col") args[i].agg = true;
        }
        if (name === "sumproduct" && pending === null && (args[0].k !== "col" || args[1].k !== "col" || args[0].tbl !== args[1].tbl))
            throw rej("sumproduct-args", "sumproduct needs two columns of one table.");
        return mk({k: "call", fn: name, args: args}, args);
    }

    var ast = parseOr();
    if (pos < toks.length) unexpected(toks[pos]);
    return {ast: ast, usesStat: hasStat(ast), nodes: count, pending: pending};
}
function walk(n, fn) {
    fn(n);
    if (n.a) walk(n.a, fn);
    if (n.b) walk(n.b, fn);
    if (n.args) for (var i = 0; i < n.args.length; ++i) walk(n.args[i], fn);
}
function hasStat(ast) {
    var found = false;
    walk(ast, function (n) { if (n.k === "call" && n.fn === "colstat") found = true; });
    return found;
}
function checkColRefs(ast) {
    walk(ast, function (n) {
        if (n.k === "col" && !n.agg)
            throw rej("colref-outside-aggregate", "'" + n.name + "' is only allowed directly inside sum, mean, median, count or sumproduct.");
    });
}

// ---------------------------------------------------------------- compile
var PLAIN_NUMBER = /^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
function listOf(v, what) {
    if (v === undefined || v === null) return [];
    if (!Array.isArray(v)) throw rej("syntax", what + " must be a list.");
    return v;
}
function objOf(v, what) {
    if (v === null || typeof v !== "object" || Array.isArray(v)) throw rej("syntax", what + " must be an object.");
    return v;
}
function checkId(id, seen, what) {
    if (id === undefined || id === null) throw rej("syntax", what + " id is missing.");
    if (typeof id !== "string" || !isIdText(id)) throw rej("bad-id", what + " id " + JSON.stringify(id) + " must match [a-z][a-z0-9_]{0,23}.");
    if (RESERVED[id] === true) throw rej("reserved-id", "'" + id + "' is a function, keyword or unit name.");
    if (seen[id] !== undefined) throw rej("duplicate-id", "Duplicate id '" + id + "'.");
}
function clampDecimals(d) {
    if (typeof d !== "number" || !isFinite(d)) return 2;
    return Math.max(0, Math.min(10, Math.floor(d)));
}
function parseNumberCell(raw, tu) {
    var s = trimAscii(raw);
    if (s === "") return {empty: true};
    if (!PLAIN_NUMBER.test(s)) return {err: "TYPE", msg: "'" + (s.length > 24 ? s.slice(0, 24) + "..." : s) + "' is not a plain number."};
    var v = Number(s);
    if (!isFinite(v)) return {err: "RANGE", msg: "'" + s.slice(0, 24) + "' overflows."};
    return {q: tu ? (tu.zero ? {v: v * tu.scale, u: null} : {v: v, u: tu.unit}) : {v: v, u: null}};
}

function compileSpec(spec) {
    try { return compileInner(spec); }
    catch (e) {
        if (e instanceof Rej) throw e;
        throw rej("syntax", "Unexpected compile failure: " + (e && e.message ? e.message : String(e)));
    }
}
function compileInner(spec) {
    if (spec === null || typeof spec !== "object" || Array.isArray(spec)) throw rej("syntax", "The spec must be an object.");
    var inputs = listOf(spec.inputs, "inputs"), tables = listOf(spec.tables, "tables"), cells = listOf(spec.cells, "cells");
    var i, j, r, c;
    if (inputs.length > LIM.maxInputs) throw rej("limit-inputs", "More than " + LIM.maxInputs + " inputs.");
    if (tables.length > LIM.maxTables) throw rej("limit-tables", "More than " + LIM.maxTables + " tables.");
    if (cells.length > LIM.maxCells) throw rej("limit-cells", "More than " + LIM.maxCells + " cells.");
    for (i = 0; i < tables.length; ++i) {
        var tb0 = objOf(tables[i], "table");
        if (!Array.isArray(tb0.columns === undefined ? [] : tb0.columns) || !Array.isArray(tb0.rows === undefined ? [] : tb0.rows))
            throw rej("syntax", "A table needs columns and rows lists.");
        listOf(tb0.columns, "columns").forEach(function (cc) { objOf(cc, "column"); });
    }
    for (i = 0; i < tables.length; ++i)
        if (listOf(tables[i].columns).length > LIM.maxColumns) throw rej("limit-columns", "More than " + LIM.maxColumns + " columns.");
    for (i = 0; i < tables.length; ++i)
        if (listOf(tables[i].rows).length > LIM.maxRows) throw rej("limit-rows", "More than " + LIM.maxRows + " rows.");
    var graph = inputs.length + cells.length;
    for (i = 0; i < tables.length; ++i) {
        var cols0 = listOf(tables[i].columns), rows0 = listOf(tables[i].rows), formulas = 0;
        for (j = 0; j < cols0.length; ++j) {
            var kind = cols0[j].kind;
            if (kind !== "number" && kind !== "text" && kind !== "formula") throw rej("syntax", "Column kind must be number, text or formula.");
            if (kind === "formula") ++formulas;
        }
        for (r = 0; r < rows0.length; ++r)
            if (!Array.isArray(rows0[r]) || rows0[r].length !== cols0.length)
                throw rej("row-shape", "Table row " + (r + 1) + " needs exactly " + cols0.length + " entries.");
        graph += formulas * rows0.length;
    }
    if (graph > LIM.maxGraphNodes) throw rej("limit-graph", graph + " graph nodes; the limit is " + LIM.maxGraphNodes + ".");

    // ids: one namespace for inputs, tables and cells; columns are per table
    var globals = Object.create(null), seen = Object.create(null);
    for (i = 0; i < inputs.length; ++i) { objOf(inputs[i], "input"); checkId(inputs[i].id, seen, "input"); seen[inputs[i].id] = true; }
    for (i = 0; i < tables.length; ++i) { checkId(tables[i].id, seen, "table"); seen[tables[i].id] = true; }
    for (i = 0; i < cells.length; ++i) { objOf(cells[i], "cell"); checkId(cells[i].id, seen, "cell"); seen[cells[i].id] = true; }

    var nodes = [], index = Object.create(null), model = {nodes: nodes, index: index, tables: [], inputIds: [], cellIds: [], tableIds: []};
    function addNode(nd) { nd.idx = nodes.length; nodes.push(nd); index[nd.id] = nd.idx; return nd; }
    for (i = 0; i < inputs.length; ++i) {
        var tu = declUnit(inputs[i].unit, "input");
        addNode({kind: "input", id: inputs[i].id, tu: tu, unitText: tu ? tu.text : "", value: inputs[i].value, decimals: 2, deps: [], expr: null});
        globals[inputs[i].id] = {kind: "node", idx: nodes.length - 1};
        model.inputIds.push(inputs[i].id);
    }
    // tables: columns, parsed number cells
    var tbModels = model.tables;
    for (i = 0; i < tables.length; ++i) {
        var tsrc = tables[i], tm = {id: tsrc.id, index: i, cols: [], rows: tsrc.rows.length, colIndex: Object.create(null)};
        var tseen = Object.create(null);
        for (j = 0; j < tsrc.columns.length; ++j) {
            var cs = tsrc.columns[j];
            checkId(cs.id, tseen, "column");
            if (seen[cs.id] !== undefined) throw rej("duplicate-id", "Column '" + cs.id + "' repeats a global id.");
            tseen[cs.id] = true;
            var ctu = declUnit(cs.unit, "column");
            tm.colIndex[cs.id] = j;
            tm.cols.push({id: cs.id, kind: cs.kind, tu: cs.kind === "text" ? null : ctu, unitText: ctu && cs.kind !== "text" ? ctu.text : "",
                expr: cs.kind === "formula" ? cs.expression : null, cells: [], inst: [], ast: null});
        }
        for (r = 0; r < tm.rows; ++r) {
            for (j = 0; j < tm.cols.length; ++j) {
                var col = tm.cols[j], raw = tsrc.rows[r][j];
                if (typeof raw === "number") raw = String(raw);
                else if (raw === null || raw === undefined) raw = "";
                else if (typeof raw !== "string") throw rej("row-shape", "Table cells must be text.");
                if (col.kind === "number") col.cells.push(parseNumberCell(raw, col.tu));
                else if (col.kind === "text") col.cells.push({empty: trimAscii(raw) === ""});
                else {
                    var inst = addNode({kind: "inst", id: tm.id + "." + col.id + "#" + (r + 1), tbl: i, col: j, row: r, tu: col.tu,
                        unitText: col.unitText, decimals: 2, deps: [], expr: col.expr});
                    col.inst.push(inst.idx);
                }
            }
        }
        tbModels.push(tm); model.tableIds.push(tm.id);
        globals[tm.id] = {kind: "table", table: tm};
    }
    for (i = 0; i < cells.length; ++i) {
        var cu = declUnit(cells[i].unit, "cell");
        addNode({kind: "cell", id: cells[i].id, tu: cu, unitText: cu ? cu.text : "", decimals: clampDecimals(cells[i].decimals), deps: [], expr: cells[i].expression});
        globals[cells[i].id] = {kind: "node", idx: nodes.length - 1};
        model.cellIds.push(cells[i].id);
    }

    // expressions: formula columns (table by table), then cells
    function globalLookup(name) { var g = globals[name]; return g !== undefined && g.kind === "node" ? g : null; }
    function tableLookup(name) { var g = globals[name]; return g === undefined ? null : (g.kind === "table" ? g.table : "global"); }
    var firstPending = null;   // name/table/colstat faults wait until every expression has parsed
    for (i = 0; i < tbModels.length; ++i) {
        for (j = 0; j < tbModels[i].cols.length; ++j) {
            if (tbModels[i].cols[j].kind !== "formula") continue;
            var cm = tbModels[i].cols[j], tmI = tbModels[i];
            var pc = parseExpression(cm.expr, {
                lookup: function (name) {
                    if (tmI.colIndex[name] !== undefined) return {kind: "row", col: tmI.colIndex[name]};
                    return globalLookup(name);
                }, table: tableLookup});
            checkColRefs(pc.ast);
            if (firstPending === null) firstPending = pc.pending;
            cm.ast = pc.ast; cm.usesStat = pc.usesStat;
        }
    }
    for (i = 0; i < nodes.length; ++i) {
        if (nodes[i].kind !== "cell") continue;
        var pcell = parseExpression(nodes[i].expr, {lookup: globalLookup, table: tableLookup});
        checkColRefs(pcell.ast);
        if (firstPending === null) firstPending = pcell.pending;
        nodes[i].ast = pcell.ast; nodes[i].usesStat = pcell.usesStat;
    }
    if (firstPending !== null) throw firstPending;
    for (i = 0; i < nodes.length; ++i) {
        var nd = nodes[i];
        if (nd.kind === "inst") { var colM = tbModels[nd.tbl].cols[nd.col]; nd.ast = colM.ast; nd.usesStat = colM.usesStat; }
    }

    // static dependency edges, Kahn order with declaration-order ties, cycle path
    var n = nodes.length, rdeps = [], indeg = [], mark = [];
    for (i = 0; i < n; ++i) { rdeps.push([]); mark.push(-1); }
    for (i = 0; i < n; ++i) {
        var nd2 = nodes[i];
        if (nd2.kind === "input") continue;
        var deps = nd2.deps;
        walk(nd2.ast, function (a) {
            var list = null;
            if (a.k === "ref") list = [a.idx];
            else if (a.k === "row") { var cc = tbModels[nd2.tbl].cols[a.col]; if (cc.kind === "formula") list = [cc.inst[nd2.row]]; }
            else if (a.k === "col") { var cc2 = tbModels[a.tbl].cols[a.col]; if (cc2.kind === "formula") list = cc2.inst; }
            if (list) for (var q = 0; q < list.length; ++q) if (mark[list[q]] !== i) { mark[list[q]] = i; deps.push(list[q]); }
        });
        deps.sort(function (x, y) { return x - y; });
        for (j = 0; j < deps.length; ++j) rdeps[deps[j]].push(i);
    }
    for (i = 0; i < n; ++i) indeg.push(nodes[i].deps.length);
    var order = [], done = [];
    for (i = 0; i < n; ++i) done.push(false);
    for (c = 0; c < n; ++c) {
        var pick = -1;
        for (i = 0; i < n; ++i) if (!done[i] && indeg[i] === 0) { pick = i; break; }
        if (pick < 0) break;
        done[pick] = true; order.push(pick);
        for (j = 0; j < rdeps[pick].length; ++j) --indeg[rdeps[pick][j]];
    }
    if (order.length < n) {
        var start = -1;
        for (i = 0; i < n; ++i) if (!done[i]) { start = i; break; }
        var path = [], at = {}, cur = start;
        while (at[cur] === undefined) {
            at[cur] = path.length; path.push(cur);
            for (j = 0; j < nodes[cur].deps.length; ++j) if (!done[nodes[cur].deps[j]]) { cur = nodes[cur].deps[j]; break; }
        }
        var cyc = path.slice(at[cur]).map(function (x) { return nodes[x].id; });
        cyc.push(nodes[cur].id);
        throw rej("cycle", "Circular reference: " + cyc.join(" -> ") + ".");
    }
    model.order = order; model.rdeps = rdeps;
    model.orderIds = order.map(function (x) { return nodes[x].id; });
    for (i = 0; i < n; ++i) nodes[i].depIds = nodes[i].deps.map(function (x) { return nodes[x].id; });
    model.inputIdx = [];
    for (i = 0; i < n; ++i) if (nodes[i].kind === "input") model.inputIdx.push(i);
    return model;
}

// ---------------------------------------------------------------- evaluation
function fail(c, code, msg) { return new CalcErr(code, msg, c.id); }
function limitErr(c, msg) { return new CalcErr("LIMIT", msg, c.id); }
function charge(c, k) {
    if (c.exhausted) throw limitErr(c, "The pass step budget is spent.");
    if (c.total + k > c.pass) { c.exhausted = true; throw limitErr(c, "The pass step budget (" + LIM.maxPassSteps + ") is spent."); }
    if (c.cellSteps + k > LIM.maxCellSteps) throw limitErr(c, "The per-cell step budget (" + LIM.maxCellSteps + ") is spent.");
    c.total += k; c.cellSteps += k;
}
function fin(c, q) { if (!isFinite(q.v)) throw fail(c, "RANGE", "The result is out of range."); return q; }
function uname(q) { return q.u ? unitText(q.u.atoms) : "a plain number"; }
function num(c, x) { if (typeof x === "boolean") throw fail(c, "TYPE", "Needs a number, not true/false."); return x; }
function bool(c, x) { if (typeof x !== "boolean") throw fail(c, "TYPE", "Needs true/false, not a number."); return x; }
function convertTo(c, q, u) {   // number of q expressed in unit u (u may be null = plain)
    var qd = q.u ? q.u.dim : "", ud = u ? u.dim : "";
    if (qd !== ud) throw fail(c, "UNIT", "Cannot convert " + uname(q) + " to " + (u ? unitText(u.atoms) : "a plain number") + ".");
    var r = !q.u ? (u ? q.v / u.scale : q.v) : (sameUnit(q.u, u) ? q.v : q.v * q.u.scale / u.scale);
    if (!isFinite(r)) throw fail(c, "RANGE", "The converted value is out of range.");
    return r;
}
function unify(c, a, b, an, bn, zeroOk) {
    if (!a.u && !b.u) return {a: a.v, b: b.v, u: null};
    if (a.u && b.u) return {a: a.v, b: convertTo(c, b, a.u), u: a.u};
    if (zeroOk && a.u && bn.lit0) return {a: a.v, b: 0, u: a.u};
    if (zeroOk && b.u && an.lit0) return {a: 0, b: b.v, u: b.u};
    throw fail(c, "UNIT", "Cannot combine " + uname(a) + " with " + uname(b) + ".");
}
function combine(c, a, b, div) {
    if (div && b.v === 0) throw fail(c, "DIV0", "Division by zero.");
    var v = div ? a.v / b.v : a.v * b.v, ua = a.u, ub = b.u, i, j;
    if (!ub) return fin(c, {v: v, u: ua});
    if (!ua) return fin(c, {v: v, u: div ? makeUnit(negAtoms(ub.atoms)) : ub});
    var all = ua.atoms.concat(div ? negAtoms(ub.atoms) : ub.atoms), n = normalizeAtoms(all);
    if (n.atoms.some(function (x) { return Math.abs(x.e) > 1024; }))
        throw fail(c, "RANGE", "The composed unit exponent is out of range.");
    v *= n.factor;
    if (!n.atoms.length) return fin(c, {v: v, u: null});
    var u = makeUnit(n.atoms);
    return u.dim === "" ? fin(c, {v: v * u.scale, u: null}) : fin(c, {v: v, u: u});
}
function power(c, a, b) {
    if (b.u) throw fail(c, "UNIT", "An exponent must be a plain number.");
    var av = a.v, bv = b.v;
    if (a.u && (Math.floor(bv) !== bv || Math.abs(bv) > 9)) throw fail(c, "UNIT", "A unit can only be raised to a whole power up to 9.");
    if (a.u && a.u.atoms.some(function (x) { return Math.abs(x.e * bv) > 1024; }))
        throw fail(c, "RANGE", "The composed unit exponent is out of range.");
    if (av === 0 && bv < 0) throw fail(c, "DIV0", "Zero cannot be raised to a negative power.");
    if (av < 0 && Math.floor(bv) !== bv) throw fail(c, "DOMAIN", "A negative number has no real fractional power.");
    var r = fin(c, {v: Math.pow(av, bv), u: null});
    if (!a.u || bv === 0) return r;
    return fin(c, normQ({v: r.v, u: makeUnit(a.u.atoms.map(function (x) { return {s: x.s, e: x.e * bv}; }))}, c));
}
function binary(c, n) {
    var x = ev(c, n.a), y = ev(c, n.b), u;
    num(c, x); num(c, y);
    switch (n.op) {
    case "+": case "-":
        u = unify(c, x, y, n.a, n.b, true);
        return fin(c, {v: n.op === "+" ? u.a + u.b : u.a - u.b, u: u.u});
    case "*": return combine(c, x, y, false);
    case "/": return combine(c, x, y, true);
    case "%":
        u = unify(c, x, y, n.a, n.b, true);
        if (u.b === 0) throw fail(c, "DIV0", "Modulo by zero.");
        return fin(c, {v: u.a % u.b, u: u.u});
    }
    return power(c, x, y);
}
function compare(c, n, x, y) {
    if (typeof x === "boolean" || typeof y === "boolean") {
        if (typeof x === "boolean" && typeof y === "boolean" && (n.op === "==" || n.op === "!=")) return (x === y) === (n.op === "==");
        throw fail(c, "TYPE", "Comparison needs two numbers" + (typeof x === "boolean" && typeof y === "boolean" ? " (true/false only compare with == or !=)." : "."));
    }
    var u = unify(c, x, y, n.a, n.b, false);
    switch (n.op) {
    case "==": return looseEq(u.a, u.b);
    case "!=": return !looseEq(u.a, u.b);
    case "<": return u.a < u.b;
    case "<=": return u.a <= u.b;
    case ">": return u.a > u.b;
    }
    return u.a >= u.b;
}

// One table column read as an array of typed cells (null = empty); errors throw.
function columnCells(c, arg, fn) {
    var tb = c.model.tables[arg.tbl], col = tb.cols[arg.col], out = [], r, cell;
    if (col.kind === "text" && fn !== "count") throw fail(c, "TYPE", "'" + arg.name + "' is a text column; " + fn + " needs numbers.");
    for (r = 0; r < tb.rows; ++r) {
        ++c.rowReads;
        if (col.kind === "formula") {
            var res = c.cur[col.inst[r]];
            if (res.err) throw res.err;
            out.push(res.q);
            continue;
        }
        cell = col.cells[r];
        if (col.kind === "text") {
            if (fn !== "count") throw fail(c, "TYPE", "'" + arg.name + "' is a text column; " + fn + " needs numbers.");
            out.push(cell.empty ? null : true);
        } else if (cell.empty) out.push(null);
        else if (cell.err) throw fail(c, cell.err, arg.name + " row " + (r + 1) + ": " + cell.msg);
        else out.push(cell.q);
    }
    return out;
}
function colUnit(c, arg, cells) {   // the unit a column "has": its declared unit, else its first value's
    var col = c.model.tables[arg.tbl].cols[arg.col];
    if (col.kind !== "formula" || col.tu) return col.tu ? col.tu.unit : null;
    for (var i = 0; i < cells.length; ++i) if (cells[i] && cells[i] !== true) return cells[i].u;
    return null;
}
function aggregate(c, n) {
    var fn = n.fn, vals = [], first, firstSet = false, i, j, a;
    for (i = 0; i < n.args.length; ++i) {
        a = n.args[i];
        if (a.k === "col") {
            charge(c, 1 + c.model.tables[a.tbl].rows);
            var cells = columnCells(c, a, fn), used = 0;
            if (!firstSet) { first = colUnit(c, a, cells); firstSet = true; }
            for (j = 0; j < cells.length; ++j) if (cells[j] !== null) { vals.push(cells[j]); ++used; }
            if (used < cells.length) c.warn.push(a.name + ": " + used + " of " + cells.length + " rows used");
        } else {
            var q = ev(c, a);
            if (!firstSet) { first = typeof q === "boolean" ? null : q.u; firstSet = true; }
            vals.push(q);
        }
    }
    if (fn === "count") return {v: vals.length, u: null};
    var nums = [];
    for (i = 0; i < vals.length; ++i) nums.push(convertTo(c, num(c, vals[i]), first));
    if (fn === "sum" || fn === "mean") {
        var s = 0;
        for (i = 0; i < nums.length; ++i) s += nums[i];
        if (fn === "mean") {
            if (!nums.length) throw fail(c, "MISSING", "There are no values to average.");
            s = s / nums.length;
        }
        return fin(c, {v: s, u: first});
    }
    if (!nums.length) throw fail(c, "MISSING", "There are no values for the median.");
    nums.sort(function (x, y) { return x - y; });
    var mid = nums.length >> 1;
    return {v: nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2, u: first};
}
function sumproduct(c, n) {
    var a = n.args[0], b = n.args[1], rows = c.model.tables[a.tbl].rows, r;
    charge(c, 1 + rows);
    var ca = columnCells(c, a, "sumproduct");
    charge(c, 1 + rows);
    var cb = columnCells(c, b, "sumproduct"), acc = null, used = 0;
    for (r = 0; r < rows; ++r) {
        if (ca[r] === null || cb[r] === null) continue;
        var p = combine(c, num(c, ca[r]), num(c, cb[r]), false);
        acc = acc === null ? p : fin(c, {v: acc.v + convertTo(c, p, acc.u), u: acc.u});
        ++used;
    }
    if (used < rows) c.warn.push(a.name + "*" + b.name + ": " + used + " of " + rows + " rows used");
    if (acc !== null) return acc;
    var pu = combine(c, {v: 1, u: colUnit(c, a, ca)}, {v: 1, u: colUnit(c, b, cb)}, false).u;
    return {v: 0, u: pu};
}
function rowValue(c, n) {
    var tb = c.model.tables[c.node.tbl], col = tb.cols[n.col], cell = col.cells[c.node.row];
    if (col.kind === "formula") { var res = c.cur[col.inst[c.node.row]]; if (res.err) throw res.err; return res.q; }
    if (cell.empty) throw fail(c, "MISSING", "'" + n.name + "' is empty in row " + (c.node.row + 1) + ".");
    if (col.kind === "text") throw fail(c, "TYPE", "'" + n.name + "' is text; arithmetic needs numbers.");
    if (cell.err) throw fail(c, cell.err, n.name + " row " + (c.node.row + 1) + ": " + cell.msg);
    return cell.q;
}
function call(c, n) {
    var f = n.fn, args = n.args, x, y, z, i, vals;
    switch (f) {
    case "if":
        return ev(c, bool(c, ev(c, args[0])) ? args[1] : args[2]);
    case "iferror":
        try { return ev(c, args[0]); }
        catch (e) { if (e instanceof CalcErr && e.code !== "LIMIT") return ev(c, args[1]); throw e; }
    case "sum": case "mean": case "median": case "count": return aggregate(c, n);
    case "sumproduct": return sumproduct(c, n);
    case "colstat": {
        charge(c, 2);
        var st = c.stats, entry = Array.isArray(st) && n.n <= st.length ? st[n.n - 1] : null;
        var v = entry !== null && typeof entry === "object" && hasOwn(entry, n.stat) ? entry[n.stat] : null;
        if (typeof v !== "number" || !isFinite(v)) throw fail(c, "SRC", "No source statistic " + n.stat + " for column " + n.n + ".");
        return {v: v, u: null};
    }
    case "to": case "num": {
        x = num(c, ev(c, args[0]));
        charge(c, 1);
        var tu = args[1].tu, dv = convertTo(c, x, {dim: tu.dim, scale: tu.scale, atoms: tu.atoms});
        if (f === "num") return {v: dv, u: null};
        return tu.zero ? {v: x.v, u: null} : {v: dv, u: tu.unit};
    }
    case "abs": case "floor": case "ceil": case "sqrt":
        x = num(c, ev(c, args[0]));
        if (f === "sqrt") x = fin(c, normQ(x, c));
        if (f === "abs") return {v: Math.abs(x.v), u: x.u};
        if (f === "floor") return {v: Math.floor(x.v), u: x.u};
        if (f === "ceil") return {v: Math.ceil(x.v), u: x.u};
        if (x.u) for (i = 0; i < x.u.atoms.length; ++i)
            if (x.u.atoms[i].e % 2 !== 0) throw fail(c, "UNIT", "The square root needs even unit exponents.");
        if (x.v < 0) throw fail(c, "DOMAIN", "The square root of a negative number is not real.");
        if (!x.u) return {v: Math.sqrt(x.v), u: null};
        return {v: Math.sqrt(x.v), u: makeUnit(x.u.atoms.map(function (a) { return {s: a.s, e: a.e / 2}; }))};
    case "round": {
        x = ev(c, args[0]); y = ev(c, args[1]);
        num(c, x); num(c, y);
        if (y.u) throw fail(c, "UNIT", "round needs a plain number of places.");
        if (Math.floor(y.v) !== y.v || y.v < 0 || y.v > 10) throw fail(c, "DOMAIN", "round needs a whole number of places from 0 to 10.");
        if (!isFinite(Math.abs(x.v) * Math.pow(10, y.v))) throw fail(c, "RANGE", "round would overflow.");
        var rv = roundHalfAway(x.v, y.v);
        return {v: isFinite(rv) ? rv : x.v, u: x.u};
    }
    }
    vals = [];
    for (i = 0; i < args.length; ++i) vals.push(ev(c, args[i]));
    for (i = 0; i < vals.length; ++i) num(c, vals[i]);
    x = vals[0];
    if (f === "clamp") {
        y = convertTo(c, vals[1], x.u); z = convertTo(c, vals[2], x.u);
        return {v: Math.max(y, Math.min(z, x.v)), u: x.u};
    }
    var best = x.v;
    for (i = 1; i < vals.length; ++i) {
        var cv = convertTo(c, vals[i], x.u);
        if (f === "min" ? cv < best : cv > best) best = cv;
    }
    return {v: best, u: x.u};
}
function ev(c, n) {
    charge(c, 1);
    switch (n.k) {
    case "num":
        if (!isFinite(n.q.v)) throw fail(c, "RANGE", "The number is out of range.");
        return n.q;
    case "ref": var r = c.cur[n.idx]; if (r.err) throw r.err; return r.q;
    case "row": return rowValue(c, n);
    case "neg": var a = num(c, ev(c, n.a)); return {v: -a.v, u: a.u};
    case "not": return !bool(c, ev(c, n.a));
    case "logic": var l = ev(c, n.a), rr = ev(c, n.b); bool(c, l); bool(c, rr); return n.op === "and" ? l && rr : l || rr;
    case "cmp": var cl = ev(c, n.a), cr = ev(c, n.b); return compare(c, n, cl, cr);
    case "bin": return binary(c, n);
    case "call": return call(c, n);
    }
    throw fail(c, "LIMIT", "Internal: unexpected node " + n.k + ".");
}

function runNode(c, nd, inputValues) {
    c.node = nd; c.id = nd.id; c.cellSteps = 0; c.warn = [];
    var out = {value: null, unit: "", err: null, deps: nd.depIds, warn: NO_WARN, q: null, steps: 0, from: ""};
    try {
        if (nd.kind === "input") {
            var v = inputValues !== null && typeof inputValues === "object" && hasOwn(inputValues, nd.id) ? inputValues[nd.id] : nd.value;
            if (v === null || v === undefined) throw fail(c, "MISSING", "Input '" + nd.id + "' is empty.");
            if (typeof v !== "number") throw fail(c, "TYPE", "Input '" + nd.id + "' must be a number or empty.");
            if (!isFinite(v)) throw fail(c, "RANGE", "Input '" + nd.id + "' is out of range.");
            out.value = v; out.unit = nd.unitText;
            out.q = nd.tu ? (nd.tu.zero ? {v: v * nd.tu.scale, u: null} : {v: v, u: nd.tu.unit}) : {v: v, u: null};
            return out;
        }
        var r = ev(c, nd.ast), tu = nd.tu;
        if (typeof r !== "boolean") r = fin(c, normQ(r, c));
        if (typeof r === "boolean") {
            if (tu) throw fail(c, "UNIT", "A true/false result cannot have the unit " + tu.text + ".");
            out.value = r; out.q = r;
        } else if (tu) {
            var dv = convertTo(c, r, {dim: tu.dim, scale: tu.scale, atoms: tu.atoms});
            if (r.u && !sameUnit(r.u, {atoms: tu.atoms})) out.from = unitText(r.u.atoms);
            out.value = dv; out.unit = tu.text;
            out.q = tu.zero ? {v: r.v, u: null} : {v: dv, u: tu.unit};
        } else {
            out.value = r.v; out.unit = r.u ? unitText(r.u.atoms) : ""; out.q = r;
        }
    } catch (e) {
        out.value = null; out.unit = ""; out.q = null;
        out.err = e instanceof CalcErr ? e : new CalcErr("LIMIT", "Unexpected evaluation failure: " + (e && e.message ? e.message : String(e)), nd.id);
    }
    out.steps = c.cellSteps;
    if (c.warn.length) out.warn = c.warn;
    return out;
}
function sameResult(a, b) {
    if (a.err || b.err) return a.err === b.err || (!!a.err && !!b.err && a.err.code === b.err.code && a.err.msg === b.err.msg && a.err.node === b.err.node);
    return a.value === b.value && a.unit === b.unit;
}

function evaluate(model, inputValues, env, prev) {
    var nodes = model.nodes, n = nodes.length, i, j;
    var stats = env && typeof env === "object" && Array.isArray(env.stats) ? env.stats : null;
    var inc = !!prev && prev.model === model && !prev.limited && prev.raw.length === n;
    var c = {model: model, stats: stats, cur: new Array(n), total: 0, pass: inc ? Infinity : LIM.maxPassSteps,
        exhausted: false, rowReads: 0, cellSteps: 0, warn: [], id: "", node: null};
    var evaluated = 0, raw = c.cur;
    if (inc) {
        var dirty = new Array(n), statsMoved = prev.statsRef !== stats;
        for (i = 0; i < n; ++i) dirty[i] = statsMoved && !!nodes[i].usesStat;
        for (i = 0; i < model.order.length; ++i) {
            var idx = model.order[i], nd = nodes[idx];
            if (nd.kind !== "input" && !dirty[idx]) { raw[idx] = prev.raw[idx]; continue; }
            raw[idx] = runNode(c, nd, inputValues);
            ++evaluated;
            if (!sameResult(raw[idx], prev.raw[idx])) for (j = 0; j < model.rdeps[idx].length; ++j) dirty[model.rdeps[idx][j]] = true;
        }
        var sum = 0, bad = false;
        for (i = 0; i < n; ++i) { sum += raw[i].steps; if (raw[i].err && raw[i].err.code === "LIMIT") bad = true; }
        if (!bad && sum <= LIM.maxPassSteps) { c.total = sum; return finish(model, c, raw, stats, evaluated, false); }
        return evaluate(model, inputValues, env, null);
    }
    for (i = 0; i < model.order.length; ++i) raw[model.order[i]] = runNode(c, nodes[model.order[i]], inputValues);
    var limited = false;
    for (i = 0; i < n; ++i) if (raw[i].err && raw[i].err.code === "LIMIT") limited = true;
    return finish(model, c, raw, stats, n, limited);
}
function finish(model, c, raw, stats, evaluated, limited) {
    var map = Object.create(null);
    for (var i = 0; i < raw.length; ++i) map[model.nodes[i].id] = raw[i];
    return {model: model, nodes: map, order: model.orderIds, steps: c.total, stats: {rowReads: c.rowReads, evaluated: evaluated},
        raw: raw, statsRef: stats, limited: limited};
}

// ---------------------------------------------------------------- display + provenance
function formatCell(model, result, id) {
    var i = model.index[id], r = result.nodes[id];
    if (i === undefined || r === undefined) return "";
    if (r.err) return "—";
    if (typeof r.value === "boolean") return r.value ? "true" : "false";
    var text = fixedString(r.value, model.nodes[i].decimals);
    return r.unit ? text + " " + r.unit : text;
}
function provenance(model, result, id) {
    var i = model.index[id], r = result.nodes[id];
    if (i === undefined || r === undefined) return null;
    var nd = model.nodes[i], refs = [], seen = Object.create(null), shown = formatCell(model, result, id);
    if (nd.ast) walk(nd.ast, function (a) {
        var key = a.name, rec = null;
        if (key === undefined || seen[key]) return;
        seen[key] = true;
        if (a.k === "ref") {
            var t = model.nodes[a.idx], tr = result.nodes[t.id];
            rec = {name: key, basis: t.kind === "input" ? "input" : "cell", value: tr.value, unit: tr.unit, text: formatCell(model, result, t.id), error: tr.err ? tr.err.code : null};
        } else if (a.k === "row") {
            var tb = model.tables[nd.tbl], cm = tb.cols[a.col], q = nd.kind === "inst" && cm.kind === "formula" ? result.nodes[cm.inst[nd.row]] : null;
            rec = {name: key, basis: "this row of " + tb.id, value: q ? q.value : null, unit: cm.unitText, text: q ? formatCell(model, result, tb.id + "." + cm.id + "#" + (nd.row + 1)) : "", error: q && q.err ? q.err.code : null};
        } else if (a.k === "col") {
            var tc = model.tables[a.tbl], cc = tc.cols[a.col], used = 0;
            for (var k = 0; k < tc.rows; ++k) if (cc.kind === "formula" || !cc.cells[k].empty) ++used;
            rec = {name: key, basis: "column, " + used + " of " + tc.rows + " rows used", value: null, unit: cc.unitText, text: "", error: null};
        }
        if (rec) refs.push(rec);
    });
    var out = {id: id, kind: nd.kind === "inst" ? "column-cell" : nd.kind, formula: nd.expr, declaredUnit: nd.unitText,
        value: r.value, unit: r.unit, text: shown, refs: refs, warnings: r.warn.slice(), error: r.err, chain: [], unitDerivation: "", rounding: ""};
    var withUnits = refs.filter(function (x) { return x.unit; }).map(function (x) { return x.name + " (" + x.unit + ")"; });
    out.unitDerivation = (r.err ? "No result." : "Result unit: " + (r.unit || "plain number") + ".")
        + (withUnits.length ? " Built from " + withUnits.join(", ") + "." : "")
        + (r.from ? " Converted from " + r.from + " to the declared unit " + nd.unitText + "." : "");
    if (r.err) out.rounding = "Not shown (error " + r.err.code + ").";
    else if (typeof r.value === "boolean") out.rounding = "Not rounded (true/false).";
    else out.rounding = "Cleaned to 15 significant digits, then rounded half away from zero to " + nd.decimals + " places: " + fixedString(r.value, nd.decimals) + " (unrounded " + String(r.value) + ").";
    if (r.err) {
        var cur = r, curId = id;
        out.chain.push(id);
        for (var step = 0; step < 400; ++step) {
            var next = null;
            for (var d = 0; d < cur.deps.length; ++d) if (result.nodes[cur.deps[d]].err === r.err) { next = cur.deps[d]; break; }
            if (next === null) break;
            out.chain.push(next); cur = result.nodes[next]; curId = next;
        }
    }
    return out;
}

return {compileSpec: compileSpec, evaluate: evaluate, formatCell: formatCell, provenance: provenance};
})();

function compileSpec(spec) { return _calc.compileSpec(spec); }
function evaluate(model, inputValues, env, prev) { return _calc.evaluate(model, inputValues, env, prev); }
function formatCell(model, result, id) { return _calc.formatCell(model, result, id); }
function provenance(model, result, id) { return _calc.provenance(model, result, id); }
