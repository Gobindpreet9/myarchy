.pragma library
.import "AiCalc.js" as Calc

// Pure logic for editable calc data and saved scenarios. No UI, no I/O, no
// mutable module state; every function returns NEW plain JSON and never changes
// its inputs. An edit is just a different SPEC: applyData() returns the
// "effective" block (authored rows + edits) that AiCalcView compiles; the
// engines are untouched.
//
// State per block lives in uiStates "calc:<blockIndex>":
//   {<inputId>: {v,u}, ...changed inputs only,
//    _d: {<tableId>: {e: {"<rowId>|<colId>": text}, a: ["n1",..], x: ["2",..], n: <next added counter>}},
//    _s: [{n: "<name <=32>", v: {<inputId>: {v,u}}}]}      (<= 3 scenarios, inputs only)
// Underscore keys cannot collide with ids ([a-z][a-z0-9_]{0,23}). Authored rows
// are "0".."39" (the block is immutable per turn); added rows are "n1","n2"...
// (omitted `n` means no added rows). Reordering is out of scope.

var maxCellText = 64;
var maxScenarioName = 32;
var maxScenarios = 3;
var maxEntryBytes = 10240;
var maxAddedCounter = 999;

var MSG = {
    notText: "Enter text.",
    number: "Not a plain number. Use a decimal point, e.g. 1.5",
    overflow: "Too large to use.",
    tooLong: "Too long. Use at most 64 characters.",
    chars: "Remove control or invisible characters.",
    formula: "This column is calculated."
};

function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }
function finite(v) { return typeof v === "number" && isFinite(v); }
function plain(v) { try { return JSON.parse(JSON.stringify(v)); } catch (e) { return null; } }

// ---------------------------------------------------------------- cell text
// The engine's own rules (AiCalc.js trimAscii / PLAIN_NUMBER); a differential
// test (tst_AiCalcEdit.qml) keeps this in step with compileSpec.
var PLAIN_NUMBER = /^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;
function trimAscii(s) {
    var a = 0, b = s.length, c;
    while (a < b && ((c = s.charCodeAt(a)) === 32 || c === 9 || c === 10 || c === 13 || c === 11 || c === 12)) ++a;
    while (b > a && ((c = s.charCodeAt(b - 1)) === 32 || c === 9 || c === 10 || c === 13 || c === 11 || c === 12)) --b;
    return s.slice(a, b);
}
// AiState.workspaceName's character policy: no control/format characters, no
// unpaired surrogates (valid emoji pairs pass).
var UNSAFE = /[\x00-\x1f\x7f-\x9f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]/;
function pairsOk(s) {
    for (var i = 0; i < s.length; ++i) {
        var code = s.charCodeAt(i);
        if (code >= 0xd800 && code <= 0xdbff) {
            var next = s.charCodeAt(++i);
            if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
        } else if (code >= 0xdc00 && code <= 0xdfff) return false;
    }
    return true;
}
function result(ok, empty, value, text, code, msg) {
    return {ok: ok, empty: empty, value: value, text: text, code: code, msg: msg};
}
function bad(code, msg) { return result(false, false, null, "", code, msg); }

// parseCell(raw, kind) -> {ok, empty, value, text, code: "TYPE"|"RANGE"|null, msg}
// kind "number": exactly what compileSpec accepts (ASCII-trimmed plain decimal
// or scientific notation; '.5' and '1e3' are accepted, '1.' is not) plus a
// 64-character launcher cap (reported as RANGE). kind "text": <= 64 characters
// under the workspaceName character policy. Empty/whitespace is {ok, empty}.
function parseCell(raw, kind) {
    if (typeof raw !== "string") return bad("TYPE", MSG.notText);
    if (kind !== "number" && kind !== "text") return bad("TYPE", MSG.formula);
    var s = trimAscii(raw);
    if (s === "") return result(true, true, null, "", null, "");
    if (kind === "number") {
        if (!PLAIN_NUMBER.test(s)) return bad("TYPE", MSG.number);
        var v = Number(s);
        if (!isFinite(v)) return bad("RANGE", MSG.overflow);
        if (s.length > maxCellText) return bad("RANGE", MSG.tooLong);
        return result(true, false, v, s, null, "");
    }
    if (s.length > maxCellText) return bad("RANGE", MSG.tooLong);
    if (UNSAFE.test(s) || !pairsOk(s)) return bad("TYPE", MSG.chars);
    return result(true, false, null, s, null, "");
}
// Scenario/tool name: same policy as AiState.workspaceName with a 32-unit cap.
// Returns the trimmed name, or "" when it is not acceptable.
function plainName(text) {
    if (typeof text !== "string" || UNSAFE.test(text)) return "";
    var name = text.trim();
    if (!name || name.length > maxScenarioName || !pairsOk(name)) return "";
    return name;
}

// ---------------------------------------------------------------- sizing
function utf8Bytes(s) {
    var n = 0;
    for (var i = 0; i < s.length; ++i) {
        var c = s.charCodeAt(i);
        if (c < 0x80) n += 1;
        else if (c < 0x800) n += 2;
        else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xdc00 && s.charCodeAt(i + 1) <= 0xdfff) { n += 4; ++i; }
        else n += 3;
    }
    return n;
}
function sizeOf(entry) {
    try { return utf8Bytes(JSON.stringify(entry === undefined ? {} : entry)); } catch (e) { return Infinity; }
}

// ---------------------------------------------------------------- data model
function rowKey(rowId, colId) { return rowId + "|" + colId; }
function tableOf(block, id) {
    var tables = block && Array.isArray(block.tables) ? block.tables : [];
    for (var i = 0; i < tables.length; ++i)
        if (tables[i] && tables[i].id === id && Array.isArray(tables[i].columns) && Array.isArray(tables[i].rows)) return tables[i];
    return null;
}
function columnOf(table, id) {
    for (var i = 0; i < table.columns.length; ++i) if (table.columns[i] && table.columns[i].id === id) return i;
    return -1;
}
function authoredText(table, rowIndex, colIndex) {
    var raw = table.rows[rowIndex] ? table.rows[rowIndex][colIndex] : "";
    raw = String(raw === null || raw === undefined ? "" : raw).slice(0, 200);
    var p = parseCell(raw, table.columns[colIndex].kind);
    return p.ok ? p.text : trimAscii(raw);
}
function numericOrder(a, b) { return Number(a) - Number(b); }
function lexOrder(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

// Canonical form: tables with edits only, sorted keys, x numeric ascending, `n`
// only while added rows exist. Equal states have equal JSON (dataKey).
function canon(data) {
    var out = {}, ids = isObj(data) ? Object.keys(data).sort(lexOrder) : [];
    for (var i = 0; i < ids.length; ++i) {
        var t = data[ids[i]], e = {}, keys = Object.keys(t.e || {}).sort(lexOrder), j;
        for (j = 0; j < keys.length; ++j) e[keys[j]] = t.e[keys[j]];
        var a = (t.a || []).slice(), x = (t.x || []).slice().sort(numericOrder);
        if (!keys.length && !a.length && !x.length) continue;
        var rec = {};
        if (keys.length) rec.e = e;
        if (a.length) rec.a = a;
        if (x.length) rec.x = x;
        if (a.length) rec.n = t.n;
        out[ids[i]] = rec;
    }
    return out;
}
function liveAuthored(table, x, id) {
    return /^(0|[1-9][0-9]*)$/.test(id) && Number(id) < table.rows.length && x.indexOf(id) < 0;
}
function liveRow(table, rec, id) {
    return liveAuthored(table, rec.x, id) || rec.a.indexOf(id) >= 0;
}
function normRec(raw) {   // a table record with all four members present (for editing)
    return {e: raw && raw.e ? plain(raw.e) : {}, a: raw && raw.a ? raw.a.slice() : [], x: raw && raw.x ? raw.x.slice() : [],
            n: raw && raw.n ? raw.n : 1};
}
function formulaCount(table) {
    var n = 0;
    for (var i = 0; i < table.columns.length; ++i) if (table.columns[i] && table.columns[i].kind === "formula") ++n;
    return n;
}
// The engine's graph-node count: inputs + cells + formula-column instances.
function graphNodes(block, rowsByTable) {
    var n = (Array.isArray(block.inputs) ? block.inputs.length : 0) + (Array.isArray(block.cells) ? block.cells.length : 0);
    var tables = Array.isArray(block.tables) ? block.tables : [];
    for (var i = 0; i < tables.length; ++i) n += formulaCount(tables[i]) * rowsByTable[i];
    return n;
}
function limitReason(block, rowsByTable) {
    for (var i = 0; i < rowsByTable.length; ++i) if (rowsByTable[i] > Calc.maxRows) return "max-rows";
    return graphNodes(block, rowsByTable) > Calc.maxGraphNodes ? "max-graph" : null;
}

// cleanData(block, raw) -> {data, dropped, reason}. Keeps only what applies to
// THIS block; anything unknown, stale, unparsable or over a limit is DROPPED
// and flagged (never clamped, never applied silently). Over a row/graph limit
// the whole data part is dropped (reason 'max-rows' | 'max-graph').
function cleanData(block, raw) {
    var out = {}, dropped = false, tables = block && Array.isArray(block.tables) ? block.tables : [], i, j;
    if (raw === undefined || raw === null) return {data: {}, dropped: false, reason: null};
    if (!isObj(raw)) return {data: {}, dropped: true, reason: null};
    var ids = Object.keys(raw), rows = [];
    for (i = 0; i < tables.length; ++i) rows.push(Array.isArray(tables[i] && tables[i].rows) ? tables[i].rows.length : 0);
    for (i = 0; i < ids.length; ++i) {
        var table = tableOf(block, ids[i]), src = raw[ids[i]];
        if (!table || !isObj(src)) { dropped = true; continue; }
        var keys = Object.keys(src), rec = {e: {}, a: [], x: [], n: 1}, k, id;
        for (k = 0; k < keys.length; ++k) if (["e", "a", "x", "n"].indexOf(keys[k]) < 0) dropped = true;
        if (own(src, "x")) {
            if (!Array.isArray(src.x)) dropped = true;
            else for (k = 0; k < src.x.length; ++k) {
                id = src.x[k];
                if (typeof id === "string" && liveAuthored(table, [], id) && rec.x.indexOf(id) < 0) rec.x.push(id);
                else dropped = true;
            }
        }
        if (own(src, "a")) {
            var counter = src.n;
            if (!Array.isArray(src.a)) dropped = true;
            else if (src.a.length && !(Number.isInteger(counter) && counter >= 2 && counter <= maxAddedCounter + 1)) dropped = true;
            else for (k = 0; k < src.a.length; ++k) {
                id = src.a[k];
                if (typeof id === "string" && /^n[1-9][0-9]{0,2}$/.test(id) && Number(id.slice(1)) < counter && rec.a.indexOf(id) < 0)
                    rec.a.push(id);
                else dropped = true;
            }
            if (rec.a.length) rec.n = counter;
        } else if (own(src, "n")) dropped = true;
        if (own(src, "e")) {
            if (!isObj(src.e)) dropped = true;
            else {
                var ekeys = Object.keys(src.e);
                for (k = 0; k < ekeys.length; ++k) {
                    var cut = ekeys[k].indexOf("|"), rowId = ekeys[k].slice(0, cut), colId = ekeys[k].slice(cut + 1);
                    var ci = cut > 0 ? columnOf(table, colId) : -1;
                    if (ci < 0 || table.columns[ci].kind === "formula" || !liveRow(table, rec, rowId) || typeof src.e[ekeys[k]] !== "string") {
                        dropped = true; continue;
                    }
                    var parsed = parseCell(src.e[ekeys[k]], table.columns[ci].kind);
                    if (!parsed.ok) { dropped = true; continue; }
                    if (rec.a.indexOf(rowId) >= 0 && parsed.empty) continue;   // blank added cell = default
                    rec.e[ekeys[k]] = parsed.text;
                }
            }
        }
        out[ids[i]] = rec;
        for (j = 0; j < tables.length; ++j) if (tables[j] === table) rows[j] = table.rows.length - rec.x.length + rec.a.length;
    }
    var reason = limitReason(block, rows);
    if (reason) return {data: {}, dropped: true, reason: reason};
    return {data: canon(out), dropped: dropped, reason: null};
}

function rowIdsOf(table, rec) {
    var ids = [], i;
    for (i = 0; i < table.rows.length; ++i) if (rec.x.indexOf(String(i)) < 0) ids.push(String(i));
    return ids.concat(rec.a);
}

// applyData(block, data) -> {ok, block, rowIds, edited, data, dropped, reason}
// block = the EFFECTIVE block (deep copy): removed rows gone, edits applied,
// added rows appended; rowIds[tableId] parallels its rows. `data` is the cleaned
// canonical data actually applied; `dropped` says something in the input was
// discarded. ok:false (reason 'max-rows' | 'max-graph' | 'bad-block') still
// returns the AUTHORED block so callers can carry on.
function applyData(block, data) {
    var b = plain(block), failed = null;
    if (!isObj(b) || !Array.isArray(b.tables)) return {ok: false, reason: "bad-block", block: b, rowIds: {}, edited: edited0(), data: {}, dropped: true};
    var c;
    try { c = cleanData(b, data); } catch (e) { c = {data: {}, dropped: true, reason: "bad-block"}; }
    if (c.reason) failed = c.reason;
    var edited = edited0(), rowIds = {}, i, j, r;
    for (i = 0; i < b.tables.length; ++i) {
        var t = b.tables[i];
        if (!t || !Array.isArray(t.columns) || !Array.isArray(t.rows)) continue;
        var rec = normRec(c.data[t.id]), rows = [], ids = [];
        for (r = 0; r < t.rows.length; ++r) {
            var id = String(r);
            if (rec.x.indexOf(id) >= 0) continue;
            var cells = [];
            for (j = 0; j < t.columns.length; ++j) {
                var key = rowKey(id, t.columns[j].id);
                if (own(rec.e, key)) { cells.push(rec.e[key]); ++edited.cells; }
                else cells.push(t.rows[r][j]);
            }
            rows.push(cells); ids.push(id);
        }
        for (r = 0; r < rec.a.length; ++r) {
            var cells2 = [];
            for (j = 0; j < t.columns.length; ++j) {
                var key2 = rowKey(rec.a[r], t.columns[j].id);
                cells2.push(own(rec.e, key2) ? rec.e[key2] : "");
            }
            rows.push(cells2); ids.push(rec.a[r]);
        }
        edited.rowsAdded += rec.a.length; edited.rowsRemoved += rec.x.length;
        t.rows = rows; rowIds[t.id] = ids;
    }
    return {ok: failed === null, reason: failed, block: b, rowIds: rowIds, edited: edited, data: c.data, dropped: c.dropped};
}
function edited0() { return {cells: 0, rowsAdded: 0, rowsRemoved: 0}; }

// Effective row count per table for already-clean data, and the limit check an
// op needs BEFORE it adds a row.
function rowsFor(block, data) {
    var out = [], tables = block.tables || [];
    for (var i = 0; i < tables.length; ++i) {
        var t = tables[i], rec = normRec(data[t.id]);
        out.push(t.rows.length - rec.x.length + rec.a.length);
    }
    return out;
}
function cleanFor(block, data) { return cleanData(block, data).data; }
function fail(reason, extra) {
    var o = {ok: false, reason: reason};
    if (extra) for (var k in extra) o[k] = extra[k];
    return o;
}
function put(data, tableId, rec) {
    var next = plain(data) || {};
    next[tableId] = rec;
    return canon(next);
}

// ---------------------------------------------------------------- operations
// Every op returns {ok:true, data, ...} or {ok:false, reason, ...}. reasons:
// unknown-table, unknown-column, unknown-row, formula-column, invalid (+code,
// msg from parseCell), max-rows, max-graph, max-adds.
function setCell(data, block, tableId, rowId, colId, text) {
    var b = plain(block), table = tableOf(b, tableId);
    if (!table) return fail("unknown-table");
    var ci = columnOf(table, colId);
    if (ci < 0) return fail("unknown-column");
    var kind = table.columns[ci].kind;
    if (kind === "formula") return fail("formula-column");
    var cur = cleanFor(b, data), rec = normRec(cur[tableId]);
    if (typeof rowId !== "string" || !liveRow(table, rec, rowId)) return fail("unknown-row");
    var p = parseCell(text, kind);
    if (!p.ok) return fail("invalid", {code: p.code, msg: p.msg});
    var base = rec.a.indexOf(rowId) >= 0 ? "" : authoredText(table, Number(rowId), ci), key = rowKey(rowId, colId);
    if (p.text === base) delete rec.e[key]; else rec.e[key] = p.text;
    return {ok: true, data: put(cur, tableId, rec), changed: p.text !== base};
}
function addRow(data, block, tableId) {
    var b = plain(block), table = tableOf(b, tableId);
    if (!table) return fail("unknown-table");
    var cur = cleanFor(b, data), rec = normRec(cur[tableId]), rows = rowsFor(b, cur), ti = b.tables.indexOf(table);
    if (rec.n > maxAddedCounter) return fail("max-adds");
    rows[ti] += 1;
    var reason = limitReason(b, rows);
    if (reason) return fail(reason);
    var id = "n" + rec.n;
    rec.a.push(id); rec.n += 1;
    return {ok: true, data: put(cur, tableId, rec), rowId: id};
}
function removeRow(data, block, tableId, rowId) {
    var b = plain(block), table = tableOf(b, tableId);
    if (!table) return fail("unknown-table");
    var cur = cleanFor(b, data), rec = normRec(cur[tableId]);
    if (typeof rowId !== "string" || !liveRow(table, rec, rowId)) return fail("unknown-row");
    if (rec.a.indexOf(rowId) >= 0) rec.a.splice(rec.a.indexOf(rowId), 1);
    else rec.x.push(rowId);
    var keys = Object.keys(rec.e);
    for (var i = 0; i < keys.length; ++i) if (keys[i].slice(0, keys[i].indexOf("|")) === rowId) delete rec.e[keys[i]];
    return {ok: true, data: put(cur, tableId, rec)};
}
// Bring a removed AUTHORED row back (its earlier edits were discarded with it).
function restoreRow(data, block, tableId, rowId) {
    var b = plain(block), table = tableOf(b, tableId);
    if (!table) return fail("unknown-table");
    var cur = cleanFor(b, data), rec = normRec(cur[tableId]), at = rec.x.indexOf(rowId);
    if (at < 0) return fail("unknown-row");
    var rows = rowsFor(b, cur);
    rows[b.tables.indexOf(table)] += 1;
    var reason = limitReason(b, rows);
    if (reason) return fail(reason);
    rec.x.splice(at, 1);
    return {ok: true, data: put(cur, tableId, rec)};
}
function discardEdits(data) { return {}; }

// ---------------------------------------------------------------- scenarios
function changedInputs(inputsState) {
    var out = {};
    if (!isObj(inputsState)) return out;
    var keys = Object.keys(inputsState);
    for (var i = 0; i < keys.length; ++i) {
        var e = inputsState[keys[i]];
        if (keys[i].charAt(0) !== "_" && isObj(e) && finite(e.v) && typeof e.u === "string") out[keys[i]] = {v: e.v, u: e.u};
    }
    return out;
}
// saveScenario(scn, name, inputsState) -> {ok, scenarios, index} | {ok:false, reason: 'bad-name'|'full'}
// inputsState = the CHANGED inputs {id:{v,u}}; a scenario with the same name is
// replaced in place; a fourth distinct name is refused.
function saveScenario(scn, name, inputsState) {
    var list = Array.isArray(scn) ? plain(scn) : [], clean = plainName(name);
    if (!clean) return fail("bad-name");
    var entry = {n: clean, v: changedInputs(inputsState)}, at = -1, i;
    for (i = 0; i < list.length; ++i) if (list[i].n === clean) at = i;
    if (at < 0) {
        if (list.length >= maxScenarios) return fail("full");
        list.push(entry); at = list.length - 1;
    } else list[at] = entry;
    return {ok: true, scenarios: list, index: at};
}
// loadScenario(scn, index) -> {ok, inputs}: the changed-inputs state to make current.
function loadScenario(scn, index) {
    if (!Array.isArray(scn) || !Number.isInteger(index) || index < 0 || index >= scn.length || !isObj(scn[index])) return fail("unknown-scenario");
    return {ok: true, inputs: changedInputs(scn[index].v), name: scn[index].n};
}
function deleteScenario(scn, index) {
    if (!Array.isArray(scn) || !Number.isInteger(index) || index < 0 || index >= scn.length) return fail("unknown-scenario");
    var list = plain(scn);
    list.splice(index, 1);
    return {ok: true, scenarios: list};
}
// A stored input value is valid only if it is finite, in range and in the input's unit.
function validInput(inp, entry) {
    return isObj(entry) && finite(entry.v) && entry.u === inp.unit && entry.v >= inp.min && entry.v <= inp.max;
}
// cleanScenarios(inputs, raw) -> {scenarios, dropped}. `inputs` = the plan's
// input list ({id, unit, min, max}). A bad name, duplicate, extra scenario,
// unknown input or bad value is dropped and flagged.
function cleanScenarios(inputs, raw) {
    var out = [], dropped = false;
    if (raw === undefined || raw === null) return {scenarios: out, dropped: false};
    if (!Array.isArray(raw)) return {scenarios: out, dropped: true};
    var byId = {}, i, k;
    for (i = 0; i < inputs.length; ++i) byId[inputs[i].id] = inputs[i];
    for (i = 0; i < raw.length; ++i) {
        var s = raw[i], name = isObj(s) && typeof s.n === "string" ? plainName(s.n) : "";
        var dup = false;
        for (k = 0; k < out.length; ++k) if (out[k].n === name) dup = true;
        if (!name || name !== s.n || dup || out.length >= maxScenarios || !isObj(s.v)) { dropped = true; continue; }
        var v = {}, ids = Object.keys(s.v);
        for (k = 0; k < ids.length; ++k) {
            if (own(byId, ids[k]) && validInput(byId[ids[k]], s.v[ids[k]])) v[ids[k]] = {v: s.v[ids[k]].v, u: s.v[ids[k]].u};
            else dropped = true;
        }
        out.push({n: name, v: v});
    }
    return {scenarios: out, dropped: dropped};
}

// ---------------------------------------------------------------- entry
// compose(inputs, data, scenarios) -> the `calc:<i>` object. Empty parts are
// omitted, so nothing edited composes to {} (the thin-save Reset state).
function compose(inputs, data, scenarios) {
    var out = {}, keys = isObj(inputs) ? Object.keys(inputs) : [], i;
    for (i = 0; i < keys.length; ++i) if (keys[i].charAt(0) !== "_") out[keys[i]] = plain(inputs[keys[i]]);
    if (isObj(data) && Object.keys(data).length) out._d = plain(data);
    if (Array.isArray(scenarios) && scenarios.length) out._s = plain(scenarios);
    return out;
}
// commit(...) = compose + the 10 KiB cap: {ok, entry, bytes} | {ok:false, reason:'too-large', bytes}
function commit(inputs, data, scenarios) {
    var entry = compose(inputs, data, scenarios), bytes = sizeOf(entry);
    return bytes > maxEntryBytes ? {ok: false, reason: "too-large", bytes: bytes} : {ok: true, entry: entry, bytes: bytes};
}
// parts(entry) -> {inputs, data, scenarios}: the raw (unvalidated) pieces of a stored entry.
function parts(entry) {
    var e = isObj(entry) ? entry : {}, inputs = {};
    Object.keys(e).forEach(function (k) { if (k.charAt(0) !== "_") inputs[k] = plain(e[k]); });
    return {inputs: inputs, data: isObj(e._d) ? plain(e._d) : {}, scenarios: Array.isArray(e._s) ? plain(e._s) : []};
}

// ---------------------------------------------------------------- duplicate
function clampTitle(text) {
    var t = "Copy of " + (typeof text === "string" && text ? text : "calculation");
    if (t.length > 160) {
        t = t.slice(0, 160);
        if (/[\ud800-\udbff]$/.test(t)) t = t.slice(0, -1);
    }
    return t;
}
// bake(block, entry) -> {block, entry} | null. A standalone block for Duplicate:
// effective rows become authored rows, every input's value becomes its current
// value (stale/out-of-range saved values fall back to the authored default),
// the title is 'Copy of ...' (<= 160), and the valid saved scenarios come back
// as a fresh entry ({_s} or {}) re-expressed against the NEW defaults.
function bake(block, entry) {
    var ap = applyData(block, isObj(entry) ? entry._d : undefined), nb = ap.block;
    if (!isObj(nb) || !Array.isArray(nb.inputs)) return null;
    var e = isObj(entry) ? entry : {}, old = [], i, k;
    for (i = 0; i < nb.inputs.length; ++i) {
        var inp = nb.inputs[i], cur = inp.value;
        old.push({id: inp.id, unit: typeof inp.unit === "string" ? inp.unit : "", min: inp.min, max: inp.max, value: inp.value});
        if (own(e, inp.id) && validInput(old[i], e[inp.id])) cur = e[inp.id].v;
        inp.value = cur;
    }
    var scn = cleanScenarios(old, e._s).scenarios, list = [];
    for (i = 0; i < scn.length; ++i) {
        var v = {};
        for (k = 0; k < old.length; ++k) {
            var val = own(scn[i].v, old[k].id) ? scn[i].v[old[k].id].v : old[k].value;
            if (val !== nb.inputs[k].value) v[old[k].id] = {v: val, u: old[k].unit};
        }
        list.push({n: scn[i].n, v: v});
    }
    nb.title = clampTitle(nb.title);
    return {block: nb, entry: list.length ? {_s: list} : {}};
}
