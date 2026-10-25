.pragma library
.import "AiCalc.js" as Calc
.import "CsvTypes.js" as CsvTypes

// Export text for the typed calc block: Markdown and CSV. Pure JS, no QML, no
// file or process; the caller copies or saves the returned string.
//
//   markdown(block, view) -> string      csv(block, view) -> string
//   viewFromRun(block, plan, result, extras) -> view | null
//
// `block` is only read for its `title`. Everything else comes from `view`, a
// plain object that this file defines and the callers fill:
//
//   view = {
//     inputs:    [{id, label, unit, basis, value}],      value = display string ("" or null = empty)
//     cells:     [{id, label, text, error, formula, unit}],
//                text = the UI text (Calc.formatCell, unit suffix included); error = null | {code, msg};
//                formula = the authored expression verbatim; unit = the result unit text ("" if none)
//     tables:    [{id, label, columns: [{id, label, unit, kind}],      kind = number | text | formula
//                  rows: [{id, cells: [{text, error: null | {code}, edited: bool}]}]}],
//     scenarios: null | {names: [string...],
//                        rows: [{label, unit?, values: [text...], errors: [code | null ...]}]},
//     note:      string }
//
// `viewFromRun` builds that object from AiCalcView.build/run results, so every
// displayed value is Calc.formatCell text and every formula is the authored one.
// Its `extras` (all optional): {values: {inputId: number} the input values the
// result was computed from (default: the authored ones), edited: [{table, row,
// col}] (table id, 0-based row, column id) to mark as edited, scenarios: a
// ready-made view.scenarios, note: string overriding plan.note}.
//
// Honesty rules: an error is always `ERR:<CODE>`, never 0 or an empty value;
// both outputs are at most 64 KiB UTF-8 and, when longer, stop BEFORE a whole
// group (a list item or table row, never mid-row) and end with a `[truncated]`
// line; nothing here throws (a bad view yields a one-line "can't be shown").
// Output is a pure function of the input.
//
// Trade-offs, pinned by tests:
//  * Markdown keeps formulas VERBATIM in a code span (a longer backtick fence
//    when the formula has backticks); the CSV formula-injection guard is not
//    applied to it, since Markdown does not execute anything.
//  * CSV prefixes an apostrophe to any text field that begins with = + - @ TAB
//    or CR UNLESS the whole field is a plain number (the PLAIN_NUMBER rule of
//    CsvTypes.js, used directly). A value with a unit ("-5.00 EUR") is not a
//    plain number, so CSV splits the unit into its own column wherever it can
//    (Inputs, Cells, Scenarios, columns with a declared unit).
//  * CSV does not mark edited cells (the data stays clean); Markdown does.
//  * Hostile text: control, bidi and zero-width characters are dropped; line
//    separators (U+0085, U+2028/2029, VT, FF) become a space, and so do TAB/CR/LF
//    in Markdown (CSV keeps TAB/CR/LF inside quoted fields); lone surrogates
//    become U+FFFD; strings are clamped (title 160, label 120, text 200,
//    formula 240, note 600 UTF-16 units) with a trailing "…".

var maxBytes = 65536;
var truncatedLine = "[truncated]";
var failText = "This calculation can't be shown.";
var LIM = {title: 160, label: 120, text: 200, formula: 240, note: 600, unit: 24, code: 16, basis: 24, id: 48};
var MAX_COLUMNS = 64;

// ---------------------------------------------------------------- sanitising
function plainCopy(value) {
    try { return JSON.parse(JSON.stringify(value)); } catch (e) { return null; }
}
function list(value) { return Array.isArray(value) ? value : []; }
function dict(value) { return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {}; }

// keepBreaks: CSV keeps TAB, CR and LF (they live inside quoted fields).
function clean(value, max, keepBreaks) {
    var s = typeof value === "string" ? value : (typeof value === "number" && isFinite(value) ? String(value) : "");
    var bound = max * 2 + 8, cut = s.length > bound;
    if (cut) s = s.slice(0, bound);
    var out = "", i, c, n;
    for (i = 0; i < s.length; ++i) {
        c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF) {
            n = s.charCodeAt(i + 1);
            if (n >= 0xDC00 && n <= 0xDFFF) { out += s.charAt(i) + s.charAt(i + 1); ++i; }
            else out += "�";
            continue;
        }
        if (c >= 0xDC00 && c <= 0xDFFF) { out += "�"; continue; }
        if (c === 9 || c === 10 || c === 13) { out += keepBreaks ? s.charAt(i) : " "; continue; }
        if (c === 0x0B || c === 0x0C || c === 0x85 || c === 0x2028 || c === 0x2029) { out += " "; continue; }
        if (c < 32 || (c >= 0x7F && c <= 0x9F) || c === 0xAD || c === 0x61C || c === 0x180E
                || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) || (c >= 0x2060 && c <= 0x206F)
                || c === 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB)) continue;
        out += s.charAt(i);
    }
    if (cut || out.length > max) {
        var end = max - 1, hi = out.charCodeAt(end - 1);
        if (hi >= 0xD800 && hi <= 0xDBFF) --end;
        out = out.slice(0, Math.max(0, end)) + "…";
    }
    return out;
}
function code(value) {
    var raw = value && typeof value === "object" ? value.code : value;
    var s = typeof raw === "string" ? raw.replace(/[^A-Za-z0-9_]/g, "").slice(0, LIM.code) : "";
    return s || "ERROR";
}
function failed(value) { return value !== null && value !== undefined && value !== false && value !== ""; }
function utf8Len(s) {
    var n = 0, c;
    for (var i = 0; i < s.length; ++i) {
        c = s.charCodeAt(i);
        if (c < 0x80) n += 1;
        else if (c < 0x800) n += 2;
        else if (c >= 0xD800 && c <= 0xDBFF) { n += 4; ++i; }
        else n += 3;
    }
    return n;
}

// Output assembler: groups of lines that stay together, a hard byte budget.
function Out(eol) { this.eol = eol; this.groups = []; this.sizes = []; this.used = 0; this.cut = false; }
Out.prototype.add = function (lines) {
    if (this.cut) return false;
    if (!this.groups.length && lines.length && lines[0] === "") lines = lines.slice(1);   // never open with a blank line
    var size = 0, i;
    for (i = 0; i < lines.length; ++i) size += utf8Len(lines[i]) + this.eol.length;
    if (this.used + size > maxBytes) { this.cut = true; return false; }
    this.groups.push(lines); this.sizes.push(size); this.used += size;
    return true;
};
Out.prototype.finish = function () {
    if (this.cut) {
        var marker = ["", truncatedLine], need = 2 * this.eol.length + utf8Len(truncatedLine);
        while (this.groups.length && this.used + need > maxBytes) { this.groups.pop(); this.used -= this.sizes.pop(); }
        this.groups.push(marker);
    }
    var text = "";
    for (var i = 0; i < this.groups.length; ++i)
        for (var j = 0; j < this.groups[i].length; ++j) text += this.groups[i][j] + this.eol;
    return text;
};

// ---------------------------------------------------------------- Markdown
function mdEsc(s) { return s.replace(/[\\|`<]/g, function (c) { return "\\" + c; }); }
function mdCode(s) {
    if (s === "") return "";
    var longest = 0, runs = s.match(/`+/g) || [], i, fence = "";
    for (i = 0; i < runs.length; ++i) if (runs[i].length > longest) longest = runs[i].length;
    for (i = 0; i <= longest; ++i) fence += "`";
    var pad = /^[` ]|[` ]$/.test(s) ? " " : "";
    return fence + pad + s + pad + fence;
}
function mdText(value, max) { return mdEsc(clean(value, max, false)); }
function mdName(label, id) { return mdText(label, LIM.label) || mdText(id, LIM.id); }
function mdValue(text, error) { return failed(error) ? "ERR:" + code(error) : mdText(text, LIM.text); }
function mdHeader(col) {
    var label = mdName(col.label, col.id), unit = col.kind === "text" ? "" : mdText(col.unit, LIM.unit);
    return unit ? label + " (" + unit + ")" : label;
}
function mdRow(cells) { return "| " + cells.join(" | ") + " |"; }

function mdBuild(block, view) {
    var out = new Out("\n"), i, j;
    var title = mdText(dict(block).title, LIM.title) || "Calculation";
    out.add(["# " + title]);
    if (!view) { out.add(["", failText]); return out.finish(); }
    var inputs = list(view.inputs), cells = list(view.cells), tables = list(view.tables);
    var items = [];
    for (i = 0; i < inputs.length; ++i) {
        var inp = dict(inputs[i]), value = clean(inp.value, LIM.text, false), unit = mdText(inp.unit, LIM.unit), basis = mdText(inp.basis, LIM.basis);
        items.push("- " + mdName(inp.label, inp.id) + ": " + (value === "" ? "empty" : mdEsc(value)) + (unit ? " " + unit : "") + (basis ? " (" + basis + ")" : ""));
    }
    section(out, "Inputs", items, []);
    items = [];
    for (i = 0; i < cells.length; ++i) {
        var cell = dict(cells[i]), formula = mdCode(clean(cell.formula, LIM.formula, false));
        items.push("- " + mdName(cell.label, cell.id) + ": " + mdValue(cell.text, cell.error) + (formula ? " (formula " + formula + ")" : ""));
    }
    section(out, "Cells", items, []);
    for (i = 0; i < tables.length && !out.cut; ++i) {
        var tb = dict(tables[i]), cols = list(tb.columns).slice(0, MAX_COLUMNS), rows = list(tb.rows);
        if (!cols.length) continue;
        var head = [], rule = [];
        for (j = 0; j < cols.length; ++j) { head.push(mdHeader(dict(cols[j]))); rule.push("---"); }
        var lines = [];
        for (j = 0; j < rows.length; ++j) {
            var rc = list(dict(rows[j]).cells), parts = [];
            for (var k = 0; k < cols.length; ++k) {
                var tc = dict(rc[k]), shown = mdValue(tc.text, tc.error);
                parts.push(shown + (tc.edited === true ? " (edited)" : ""));
            }
            lines.push(mdRow(parts));
        }
        section(out, mdName(tb.label, tb.id), lines, [mdRow(head), mdRow(rule)]);
    }
    var sc = view.scenarios ? dict(view.scenarios) : null;
    if (sc && list(sc.names).length && !out.cut) {
        var names = list(sc.names).slice(0, MAX_COLUMNS), h = ["Result"], r = ["---"], srows = list(sc.rows), body = [];
        for (j = 0; j < names.length; ++j) { h.push(mdText(names[j], LIM.label) || "Scenario " + (j + 1)); r.push("---"); }
        for (i = 0; i < srows.length; ++i) {
            var sr = dict(srows[i]), vals = list(sr.values), errs = list(sr.errors), cellsOut = [mdText(sr.label, LIM.label)];
            for (j = 0; j < names.length; ++j) cellsOut.push(failed(errs[j]) ? "ERR:" + code(errs[j]) : mdText(vals[j], LIM.text));
            body.push(mdRow(cellsOut));
        }
        section(out, "Scenarios", body, [mdRow(h), mdRow(r)]);
    }
    var note = clean(dict(view).note, LIM.note, false);
    if (note !== "") {
        note = mdEsc(note);
        if (/^[#>*+\-|~=]/.test(note)) note = "\\" + note;
        out.add(["", note]);
    }
    return out.finish();
}
// heading + blank + optional header lines + items; the first item travels with
// the heading and header so a heading never ends the output alone.
function section(out, name, items, header) {
    if (!items.length || out.cut) return;
    var first = ["", "## " + name, ""].concat(header, [items[0]]);
    if (!out.add(first)) return;
    for (var i = 1; i < items.length; ++i) if (!out.add([items[i]])) return;
}

// ---------------------------------------------------------------- CSV
function csvField(text, max) {
    var s = clean(text, max || LIM.text, true);
    if (s !== "" && /^[=+\-@\t\r]/.test(s) && !CsvTypes.PLAIN_NUMBER.test(s)) s = "'" + s;
    return /[",\r\n]/.test(s) ? "\"" + s.replace(/"/g, "\"\"") + "\"" : s;
}
function csvRow(fields) { return fields.join(","); }
function csvValue(text, error) { return failed(error) ? "ERR:" + code(error) : csvField(text); }
// "-5.00 EUR" + "EUR" -> ["-5.00", "EUR"]; any other text keeps its unit apart.
function splitUnit(text, unit) {
    var t = clean(text, LIM.text, true), u = clean(unit, LIM.unit, true);
    if (u !== "" && t.length > u.length + 1 && t.slice(-(u.length + 1)) === " " + u) return t.slice(0, t.length - u.length - 1);
    return t;
}
function csvName(label, id) { return clean(label, LIM.label, true) || clean(id, LIM.id, true); }
function csvHeader(col) {
    var label = csvName(col.label, col.id), unit = col.kind === "text" ? "" : clean(col.unit, LIM.unit, true);
    return label + (unit ? " (" + unit + ")" : "");
}
function csvSection(out, name, header, rows) {
    if (!rows.length || out.cut) return;
    if (!out.add(["", csvField(name), csvRow(header), rows[0]])) return;
    for (var i = 1; i < rows.length; ++i) if (!out.add([rows[i]])) return;
}

function csvBuild(block, view) {
    var out = new Out("\r\n"), i, j;
    var title = clean(dict(block).title, LIM.title, true);
    if (title !== "") out.add([csvRow(["Title", csvField(title, LIM.title)])]);
    if (!view) { out.add(["", csvRow(["Note", csvField(failText)])]); return out.finish(); }
    var inputs = list(view.inputs), cells = list(view.cells), tables = list(view.tables), rows = [];
    for (i = 0; i < inputs.length; ++i) {
        var inp = dict(inputs[i]);
        rows.push(csvRow([csvField(csvName(inp.label, inp.id)), csvField(inp.value), csvField(inp.unit), csvField(inp.basis)]));
    }
    csvSection(out, "Inputs", ["Label", "Value", "Unit", "Basis"], rows);
    rows = [];
    for (i = 0; i < cells.length; ++i) {
        var cell = dict(cells[i]);
        rows.push(csvRow([csvField(csvName(cell.label, cell.id)), csvValue(splitUnit(cell.text, cell.unit), cell.error),
                          csvField(cell.unit), csvField(cell.formula, LIM.formula)]));
    }
    csvSection(out, "Cells", ["Label", "Value", "Unit", "Formula"], rows);
    for (i = 0; i < tables.length && !out.cut; ++i) {
        var tb = dict(tables[i]), cols = list(tb.columns).slice(0, MAX_COLUMNS), trows = list(tb.rows), head = [];
        if (!cols.length) continue;
        for (j = 0; j < cols.length; ++j) head.push(csvField(csvHeader(dict(cols[j]))));
        rows = [];
        for (j = 0; j < trows.length; ++j) {
            var rc = list(dict(trows[j]).cells), parts = [];
            for (var k = 0; k < cols.length; ++k) {
                var tc = dict(rc[k]), col = dict(cols[k]);
                parts.push(csvValue(col.kind === "text" ? tc.text : splitUnit(tc.text, col.unit), tc.error));
            }
            rows.push(csvRow(parts));
        }
        csvSection(out, csvName(tb.label, tb.id), head, rows);
    }
    var sc = view.scenarios ? dict(view.scenarios) : null;
    if (sc && list(sc.names).length && !out.cut) {
        var names = list(sc.names).slice(0, MAX_COLUMNS), h = [csvField("Result"), csvField("Unit")], srows = list(sc.rows);
        for (j = 0; j < names.length; ++j) h.push(csvField(clean(names[j], LIM.label, true) || "Scenario " + (j + 1)));
        rows = [];
        for (i = 0; i < srows.length; ++i) {
            var sr = dict(srows[i]), vals = list(sr.values), errs = list(sr.errors), f = [csvField(sr.label), csvField(sr.unit)];
            for (j = 0; j < names.length; ++j) f.push(csvValue(splitUnit(vals[j], sr.unit), errs[j]));
            rows.push(csvRow(f));
        }
        csvSection(out, "Scenarios", h, rows);
    }
    var note = clean(dict(view).note, LIM.note, true);
    if (note !== "") out.add(["", csvRow(["Note", csvField(note, LIM.note)])]);
    return out.finish();
}

// ---------------------------------------------------------------- public API
function markdown(block, view) {
    try { return mdBuild(plainCopy(block), plainCopy(view)); }
    catch (e) { return "# Calculation\n\n" + failText + "\n"; }
}
function csv(block, view) {
    try { return csvBuild(plainCopy(block), plainCopy(view)); }
    catch (e) { return "Note," + failText + "\r\n"; }
}

function inputText(value) {
    // the same shortest form the calculator's own number field shows
    return typeof value === "number" && isFinite(value) ? String(Number(value.toPrecision(12))) : "";
}
function viewFromRun(block, plan, result, extras) {
    try {
        if (!plan || !plan.model || !result || !result.nodes) return null;
        var ex = dict(extras), values = dict(ex.values), model = plan.model, i, j, k;
        var edited = Object.create(null), marks = list(ex.edited);
        for (i = 0; i < marks.length; ++i) {
            var m = dict(marks[i]);
            edited[String(m.table) + "\u0000" + String(m.row) + "\u0000" + String(m.col)] = true;
        }
        var inputs = [], cells = [], tables = [];
        for (i = 0; i < plan.inputs.length; ++i) {
            var inp = plan.inputs[i], v = typeof values[inp.id] === "number" ? values[inp.id] : inp.value;
            inputs.push({id: inp.id, label: inp.label || inp.id, unit: inp.unit, basis: inp.basis, value: inputText(v)});
        }
        for (i = 0; i < plan.cells.length; ++i) {
            var c = plan.cells[i], node = result.nodes[c.id];
            cells.push({id: c.id, label: plan.labels[c.id] || c.id, text: Calc.formatCell(model, result, c.id),
                        error: node && node.err ? {code: node.err.code, msg: node.err.msg} : null,
                        formula: c.expression, unit: node && node.unit ? node.unit : ""});
        }
        for (i = 0; i < plan.tables.length; ++i) {
            var tb = plan.tables[i], tm = model.tables[i], columns = [], rows = [];
            for (j = 0; j < tb.cols.length; ++j) {
                var col = tb.cols[j];
                columns.push({id: col.id, label: col.label, unit: col.kind === "text" ? "" : (col.unitText || ""), kind: col.kind});
            }
            for (j = 0; j < tb.rows.length; ++j) {
                var rcells = [];
                for (k = 0; k < tb.cols.length; ++k) {
                    var cc = tb.cols[k], text, err = null;
                    if (cc.kind === "formula") {
                        var nid = tb.id + "." + cc.id + "#" + (j + 1), nr = result.nodes[nid];
                        text = Calc.formatCell(model, result, nid);
                        if (nr && nr.err) err = {code: nr.err.code};
                    } else {
                        text = tb.rows[j][k];
                        var pc = cc.kind === "number" ? tm.cols[k].cells[j] : null;
                        if (pc && pc.err) err = {code: pc.err};
                    }
                    rcells.push({text: text, error: err, edited: edited[tb.id + "\u0000" + j + "\u0000" + cc.id] === true});
                }
                rows.push({id: String(j + 1), cells: rcells});
            }
            tables.push({id: tb.id, label: tb.label, columns: columns, rows: rows});
        }
        return {inputs: inputs, cells: cells, tables: tables, scenarios: ex.scenarios || null,
                note: typeof ex.note === "string" ? ex.note : (typeof plan.note === "string" ? plan.note : "")};
    } catch (e) {
        return null;
    }
}
