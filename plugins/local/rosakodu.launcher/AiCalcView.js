.pragma library
.import "AiCalc.js" as Calc
.import "AiCalcEdit.js" as Edit

// Shared native-view adapter. Keep field coercion, validation and restoration
// here, not in consumers: the renderer and submit-time context must agree.
function txt(value, max) { return typeof value === "string" ? value.slice(0, max) : ""; }
function finite(value) { return typeof value === "number" && isFinite(value); }
function plain(value) {
    try { return JSON.parse(JSON.stringify(value)); } catch (e) { return null; }
}
// The part of a saved entry that changes the SPEC (table edits, `_d`) as a
// stable string; "" when there is none. A plan depends on nothing else, so
// moving a slider never recompiles: rebuild only when this key changes.
function dataKey(entry) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return "";
    var d = entry._d;
    if (d === undefined || d === null || (typeof d === "object" && !Array.isArray(d) && Object.keys(d).length === 0)) return "";
    try { return JSON.stringify(d); } catch (e) { return ""; }
}
// build(source[, entryOrDataKey]): the second argument is a saved entry
// ({..., _d}), or the string from dataKey(). Without it the block is built as authored.
function build(source, edits) {
    try {
        // QML sequence/reference wrappers need a plain JSON copy at the boundary.
        var b = plain(source);
        if (!b || typeof b !== "object" || !Array.isArray(b.inputs) || !Array.isArray(b.tables) || !Array.isArray(b.cells))
            return null;
        var key = typeof edits === "string" ? edits : dataKey(edits), applied = null;
        if (key !== "") {
            var rawData = null;
            try { rawData = JSON.parse(key); } catch (e2) { rawData = null; }
            applied = Edit.applyData(b, rawData);
            if (applied.reason === "bad-block") return null;
            b = applied.block;
        }
        if (b.inputs.length > Calc.maxInputs || b.tables.length > Calc.maxTables || b.cells.length > Calc.maxCells)
            return null;
        var inputs = [], specInputs = [], tables = [], specTables = [], cells = [], specCells = [], labels = {}, basis = {};
        var i, j, k;
        for (i = 0; i < b.inputs.length; ++i) {
            var inp = b.inputs[i];
            if (!inp || typeof inp.id !== "string") return null;
            if (!finite(inp.min) || !finite(inp.max) || !finite(inp.step) || !finite(inp.value)) return null;
            if (inp.min >= inp.max || inp.step <= 0 || inp.value < inp.min || inp.value > inp.max) return null;
            if (inp.basis !== "assumption" && inp.basis !== "provided" && inp.basis !== "sourced") return null;
            var unit = typeof inp.unit === "string" ? inp.unit : "";
            inputs.push({id: inp.id, label: txt(inp.label, 120), unit: unit, min: inp.min, max: inp.max,
                         step: inp.step, value: inp.value, basis: inp.basis});
            specInputs.push({id: inp.id, unit: unit, value: inp.value, min: inp.min, max: inp.max});
            labels[inp.id] = txt(inp.label, 120) || inp.id;
            basis[inp.id] = inp.basis;
        }
        for (i = 0; i < b.tables.length; ++i) {
            var tb = b.tables[i];
            if (!tb || !Array.isArray(tb.columns) || !Array.isArray(tb.rows)) return null;
            if (tb.columns.length > Calc.maxColumns || tb.rows.length > Calc.maxRows) return null;
            var cols = [], specCols = [], rows = [];
            for (j = 0; j < tb.columns.length; ++j) {
                var col = tb.columns[j];
                if (!col || typeof col !== "object") return null;
                var cu = typeof col.unit === "string" ? col.unit : "";
                cols.push({id: col.id, label: txt(col.label, 80), kind: col.kind, unit: cu});
                specCols.push({id: col.id, kind: col.kind, unit: cu, expression: typeof col.expression === "string" ? col.expression : ""});
            }
            for (j = 0; j < tb.rows.length; ++j) {
                if (!Array.isArray(tb.rows[j])) return null;
                var cellsOfRow = [];
                for (k = 0; k < tb.rows[j].length; ++k) cellsOfRow.push(String(tb.rows[j][k] === null || tb.rows[j][k] === undefined ? "" : tb.rows[j][k]).slice(0, 200));
                rows.push(cellsOfRow);
            }
            tables.push({id: tb.id, label: txt(tb.label, 120), cols: cols, rows: rows,
                         rowIds: applied ? applied.rowIds[tb.id] : rowIdsOf(rows.length)});
            specTables.push({id: tb.id, columns: specCols, rows: rows});
        }
        for (i = 0; i < b.cells.length; ++i) {
            var cell = b.cells[i];
            if (!cell || typeof cell.id !== "string" || typeof cell.expression !== "string") return null;
            var cuc = typeof cell.unit === "string" ? cell.unit : "";
            cells.push({id: cell.id, label: txt(cell.label, 120) || cell.id, note: txt(cell.note, 300), expression: cell.expression});
            specCells.push({id: cell.id, expression: cell.expression, unit: cuc, decimals: cell.decimals});
            labels[cell.id] = txt(cell.label, 120) || cell.id;
        }
        var model;
        try {
            model = Calc.compileSpec({inputs: specInputs, tables: specTables, cells: specCells});
        } catch (e3) {
            // An edit may never turn a showable block into a broken one: fall back to the authored rows.
            if (applied !== null) { var authored = build(source); if (authored) authored.dataReset = true; return authored; }
            throw e3;
        }
        for (i = 0; i < tables.length; ++i)
            for (j = 0; j < tables[i].cols.length; ++j)
                tables[i].cols[j].unitText = model.tables[i].cols[j].unitText;
        return {model: model, inputs: inputs, tables: tables, cells: cells, labels: labels, basis: basis,
                note: txt(b.note, 600), dataKey: key, data: applied ? applied.data : {}, dataReset: applied ? applied.dropped : false,
                edited: applied ? applied.edited : {cells: 0, rowsAdded: 0, rowsRemoved: 0}};
    } catch (e) {
        return null;
    }
}
function rowIdsOf(count) {
    var ids = [];
    for (var i = 0; i < count; ++i) ids.push(String(i));
    return ids;
}
function defaults(plan) {
    var out = {};
    if (plan) for (var i = 0; i < plan.inputs.length; ++i) out[plan.inputs[i].id] = plan.inputs[i].value;
    return out;
}
// restore(plan, saved) -> {values, reset, scenarios}. Saved inputs validate
// exactly as before (out of range or wrong unit: reset to the default, never
// clamped). reset is also true when the plan dropped bad table edits (plan.dataReset)
// or a saved scenario failed validation; `scenarios` holds only valid ones.
function restore(plan, saved) {
    var values = defaults(plan), reset = !!(plan && plan.dataReset), s = plain(saved), scenarios = [];
    if (plan && s !== null && typeof s === "object" && !Array.isArray(s)) {
        for (var i = 0; i < plan.inputs.length; ++i) {
            var inp = plan.inputs[i];
            if (!Object.prototype.hasOwnProperty.call(s, inp.id)) continue;
            var entry = s[inp.id];
            if (Edit.validInput(inp, entry)) values[inp.id] = entry.v;
            else reset = true;
        }
        var cleaned = Edit.cleanScenarios(plan.inputs, s._s);
        scenarios = cleaned.scenarios;
        if (cleaned.dropped) reset = true;
    }
    return {values: values, reset: reset, scenarios: scenarios};
}
// scenarioResults(plan, entry[, currentResult]) -> [{name, index, values, result}]:
// element 0 is "Current" (index -1), then each valid saved scenario in order.
// Pure Calc.evaluate calls on the plan's model; a scenario result is cached on
// the plan (so per model build) until its values change.
function scenarioResults(plan, entry, currentResult) {
    if (!plan) return [];
    var state = restore(plan, entry), out = [], cache = plan.scenarioCache || (plan.scenarioCache = {});
    function evaluate(values) {
        try { return Calc.evaluate(plan.model, values, null, null); } catch (e) { return null; }
    }
    out.push({name: "Current", index: -1, values: state.values, result: currentResult || evaluate(state.values)});
    for (var i = 0; i < state.scenarios.length; ++i) {
        var values = defaults(plan), v = state.scenarios[i].v;
        for (var id in v) values[id] = v[id].v;
        var key = JSON.stringify(values), hit = cache[i];
        if (!hit || hit.key !== key) hit = cache[i] = {key: key, result: evaluate(values)};
        out.push({name: state.scenarios[i].n, index: i, values: values, result: hit.result});
    }
    return out;
}
function run(source, saved) {
    var plan = build(source, saved), state = restore(plan, saved);
    try {
        return {plan: plan, current: state.values, reset: state.reset, scenarios: state.scenarios,
                result: plan ? Calc.evaluate(plan.model, state.values, null, null) : null};
    } catch (e) {
        return {plan: null, current: {}, reset: false, scenarios: [], result: null};
    }
}
