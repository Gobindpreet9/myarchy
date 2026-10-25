import QtQuick
import QtTest
import "../AiCalcExport.js" as Exp
import "../AiCalcView.js" as CalcView
import "../AiCalc.js" as Calc

// Markdown / CSV export text for the typed calc block. Pure JS: no file,
// process or provider. Exact strings are pinned; the example's numbers were
// recomputed outside the engine in exact Fraction arithmetic (see EXAMPLE).
TestCase {
    name: "AiCalcExport"

    // ai_catalog.CALC_EXAMPLE, copied. Exact-fraction check outside the engine:
    // score = (w1*speed/10 + w2*batt/20 + w3*clamp(1-price/2000,0,1)) / wsum * 100
    //   weights 5/3/2   : Air 13 66.5, Pro 14 63.5, Budget 15 50.5 (mean 180.5/3 = 60.1667)
    //   weights 10/10/10: 63.3333, 51.6667, 52.5 (mean 55.8333)
    // mean price = 3550/3 = 1183.33. The engine shows table formula cells with 2
    // places ("66.50"), the cells with their own decimals ("60.2", "1183 EUR").
    readonly property var example: ({
        type: "calc", title: "Laptop score",
        inputs: [
            {id: "w_perf", label: "Speed weight", unit: "", min: 0, max: 10, step: 1, value: 5, basis: "assumption"},
            {id: "w_batt", label: "Battery weight", unit: "", min: 0, max: 10, step: 1, value: 3, basis: "assumption"},
            {id: "w_price", label: "Price weight", unit: "", min: 0, max: 10, step: 1, value: 2, basis: "assumption"}],
        tables: [{id: "laptops", label: "Laptops", columns: [
            {id: "name", label: "Laptop", unit: "", kind: "text", expression: ""},
            {id: "perf", label: "Speed (0-10)", unit: "", kind: "number", expression: ""},
            {id: "batt", label: "Battery", unit: "h", kind: "number", expression: ""},
            {id: "price", label: "Price", unit: "EUR", kind: "number", expression: ""},
            {id: "score", label: "Score", unit: "", kind: "formula",
             expression: "if(wsum==0,0,(w_perf*perf/10+w_batt*batt/20[h]+w_price*clamp(1-price/2000[EUR],0,1))/wsum*100)"}],
            rows: [["Air 13", "7", "15", "1100", ""], ["Pro 14", "9", "11", "1800", ""], ["Budget 15", "5", "8", "650", ""]]}],
        cells: [
            {id: "wsum", label: "Total weight", expression: "w_perf+w_batt+w_price", unit: "", decimals: 0, note: ""},
            {id: "mean_score", label: "Average score", expression: "mean(laptops.score)", unit: "", decimals: 1, note: ""},
            {id: "avg_price", label: "Average price", expression: "mean(laptops.price)", unit: "EUR", decimals: 0, note: ""}],
        note: "Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."})

    function clone(v) { return JSON.parse(JSON.stringify(v)) }
    function viewOf(block, saved, extras) {
        var run = CalcView.run(block, saved || {})
        var ex = extras || {}
        ex.values = run.current
        return Exp.viewFromRun(block, run.plan, run.result, ex)
    }
    function lines(arr, eol) { return arr.join(eol) + eol }
    function md(arr) { return lines(arr, "\n") }
    function csvText(arr) { return lines(arr, "\r\n") }
    function utf8(s) { return unescape(encodeURIComponent(s)).length }
    // tiny RFC 4180 parser: rows of fields; a quoted field may hold , " CR LF
    function parseCsv(s) {
        var rows = [], row = [], f = "", q = false
        for (var i = 0; i < s.length; ++i) {
            var c = s.charAt(i)
            if (q) {
                if (c === "\"") { if (s.charAt(i + 1) === "\"") { f += "\""; ++i } else q = false }
                else f += c
            } else if (c === "\"") q = true
            else if (c === ",") { row.push(f); f = "" }
            else if (c === "\r" && s.charAt(i + 1) === "\n") { row.push(f); rows.push(row); row = []; f = ""; ++i }
            else f += c
        }
        if (f !== "" || row.length) { row.push(f); rows.push(row) }
        return rows
    }
    function simpleView(over) {
        var v = {inputs: [], cells: [], tables: [], scenarios: null, note: ""}
        for (var k in over) v[k] = over[k]
        return v
    }
    function textTable(texts, edited) {
        return {id: "t", label: "T", columns: [{id: "a", label: "A", unit: "", kind: "text"}],
                rows: texts.map(function (t, i) { return {id: String(i + 1), cells: [{text: t, error: null, edited: !!edited}]} })}
    }

    // ---- (a) the shipped example at its defaults ----------------------------
    function test_example_markdown() {
        var out = Exp.markdown(example, viewOf(example))
        compare(out, md([
            "# Laptop score",
            "",
            "## Inputs",
            "",
            "- Speed weight: 5 (assumption)",
            "- Battery weight: 3 (assumption)",
            "- Price weight: 2 (assumption)",
            "",
            "## Cells",
            "",
            "- Total weight: 10 (formula `w_perf+w_batt+w_price`)",
            "- Average score: 60.2 (formula `mean(laptops.score)`)",
            "- Average price: 1183 EUR (formula `mean(laptops.price)`)",
            "",
            "## Laptops",
            "",
            "| Laptop | Speed (0-10) | Battery (h) | Price (EUR) | Score |",
            "| --- | --- | --- | --- | --- |",
            "| Air 13 | 7 | 15 | 1100 | 66.50 |",
            "| Pro 14 | 9 | 11 | 1800 | 63.50 |",
            "| Budget 15 | 5 | 8 | 650 | 50.50 |",
            "",
            "Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."]))
    }
    function test_example_csv() {
        var out = Exp.csv(example, viewOf(example))
        compare(out, csvText([
            "Title,Laptop score",
            "",
            "Inputs",
            "Label,Value,Unit,Basis",
            "Speed weight,5,,assumption",
            "Battery weight,3,,assumption",
            "Price weight,2,,assumption",
            "",
            "Cells",
            "Label,Value,Unit,Formula",
            "Total weight,10,,w_perf+w_batt+w_price",
            "Average score,60.2,,mean(laptops.score)",
            "Average price,1183,EUR,mean(laptops.price)",
            "",
            "Laptops",
            "Laptop,Speed (0-10),Battery (h),Price (EUR),Score",
            "Air 13,7,15,1100,66.50",
            "Pro 14,9,11,1800,63.50",
            "Budget 15,5,8,650,50.50",
            "",
            "Note,\"Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR.\""]))
    }
    function test_view_shape_and_ui_text() {
        var run = CalcView.run(example, {}), v = Exp.viewFromRun(example, run.plan, run.result, {})
        compare(v.inputs.length, 3)
        compare(v.inputs[0].value, "5")
        compare(v.cells[2].text, Calc.formatCell(run.plan.model, run.result, "avg_price"))
        compare(v.cells[2].unit, "EUR")
        compare(v.cells[1].formula, "mean(laptops.score)")
        compare(v.tables[0].rows.length, 3)
        compare(v.tables[0].rows[0].cells[4].text, Calc.formatCell(run.plan.model, run.result, "laptops.score#1"))
        compare(v.tables[0].columns[2].unit, "h")
        compare(v.scenarios, null)
        verify(Exp.viewFromRun(example, null, run.result, {}) === null)
    }
    function test_adjusted_inputs_use_the_values_passed_in() {
        var block = clone(example)
        var out = Exp.markdown(block, viewOf(block, {w_perf: {v: 10, u: ""}, w_batt: {v: 10, u: ""}, w_price: {v: 10, u: ""}}))
        verify(out.indexOf("- Speed weight: 10 (assumption)") >= 0)
        verify(out.indexOf("- Total weight: 30 ") >= 0)
        verify(out.indexOf("| Air 13 | 7 | 15 | 1100 | 63.33 |") >= 0)   // 63.3333 exact
        verify(out.indexOf("| Budget 15 | 5 | 8 | 650 | 52.50 |") >= 0)
        verify(out.indexOf("- Average score: 55.8 ") >= 0)               // 55.8333 exact
    }

    // ---- (b) error cells ----------------------------------------------------
    readonly property var divBlock: ({
        type: "calc", title: "Ratio",
        inputs: [{id: "den", label: "Divisor", unit: "", min: 0, max: 10, step: 1, value: 0, basis: "provided"},
                 {id: "amt", label: "Amount", unit: "EUR", min: 0, max: 100, step: 1, value: 6, basis: "provided"}],
        tables: [{id: "parts", label: "Parts", columns: [
            {id: "name", label: "Part", unit: "", kind: "text", expression: ""},
            {id: "cnt", label: "Count", unit: "", kind: "number", expression: ""},
            {id: "share", label: "Share", unit: "", kind: "formula", expression: "cnt/den"}],
            rows: [["A", "6", ""], ["B", "3", ""]]}],
        cells: [{id: "ratio", label: "Ratio", expression: "amt/den", unit: "", decimals: 2, note: ""},
                {id: "total", label: "Total", expression: "sum(parts.share)", unit: "", decimals: 2, note: ""}],
        note: ""})
    function test_division_by_zero_is_marked_never_zero() {
        var view = viewOf(divBlock)
        compare(view.cells[0].error.code, "DIV0")
        var out = Exp.markdown(divBlock, view)
        compare(out, md([
            "# Ratio",
            "",
            "## Inputs",
            "",
            "- Divisor: 0 (provided)",
            "- Amount: 6 EUR (provided)",
            "",
            "## Cells",
            "",
            "- Ratio: ERR:DIV0 (formula `amt/den`)",
            "- Total: ERR:DIV0 (formula `sum(parts.share)`)",
            "",
            "## Parts",
            "",
            "| Part | Count | Share |",
            "| --- | --- | --- |",
            "| A | 6 | ERR:DIV0 |",
            "| B | 3 | ERR:DIV0 |"]))
        var c = Exp.csv(divBlock, view)
        compare(c, csvText([
            "Title,Ratio",
            "",
            "Inputs",
            "Label,Value,Unit,Basis",
            "Divisor,0,,provided",
            "Amount,6,EUR,provided",
            "",
            "Cells",
            "Label,Value,Unit,Formula",
            "Ratio,ERR:DIV0,,amt/den",
            "Total,ERR:DIV0,,sum(parts.share)",
            "",
            "Parts",
            "Part,Count,Share",
            "A,6,ERR:DIV0",
            "B,3,ERR:DIV0"]))
    }
    function test_unparseable_number_cell_is_a_type_error() {
        var block = clone(divBlock)
        block.tables[0].rows[0][1] = "abc"
        var out = Exp.markdown(block, viewOf(block))
        verify(out.indexOf("| A | ERR:TYPE | ERR:") >= 0)
    }

    // ---- (c) formula-injection guard ---------------------------------------
    function test_hostile_text_cell_and_at_label() {
        var hostile = "=cmd|' /C calc'!A0"
        var view = simpleView({
            cells: [{id: "c", label: "@sum", text: "3", error: null, formula: "a+b", unit: ""}],
            tables: [textTable([hostile])]})
        compare(Exp.csv({}, view), csvText([
            "Cells",
            "Label,Value,Unit,Formula",
            "'@sum,3,,a+b",
            "",
            "T",
            "A",
            "'=cmd|' /C calc'!A0"]))
        // Markdown keeps the text verbatim except the pipe, which would split the row
        compare(Exp.markdown({}, view), md([
            "# Calculation",
            "",
            "## Cells",
            "",
            "- @sum: 3 (formula `a+b`)",
            "",
            "## T",
            "",
            "| A |",
            "| --- |",
            "| =cmd\\|' /C calc'!A0 |"]))
    }
    function test_markdown_keeps_verbatim_formulas_csv_guards_them() {
        var view = simpleView({cells: [{id: "c", label: "F", text: "1", error: null, formula: "=1+1", unit: ""},
                                       {id: "d", label: "G", text: "1", error: null, formula: "-a", unit: ""}]})
        verify(Exp.markdown({}, view).indexOf("(formula `=1+1`)") >= 0)
        verify(Exp.markdown({}, view).indexOf("(formula `-a`)") >= 0)
        verify(Exp.csv({}, view).indexOf("F,1,,'=1+1\r\n") >= 0)
        verify(Exp.csv({}, view).indexOf("G,1,,'-a\r\n") >= 0)
    }
    function test_markdown_code_span_survives_backticks() {
        var view = simpleView({cells: [{id: "c", label: "F", text: "1", error: null, formula: "a`b``c", unit: ""}]})
        verify(Exp.markdown({}, view).indexOf("(formula ```a`b``c```)") >= 0)
        var edge = simpleView({cells: [{id: "c", label: "F", text: "1", error: null, formula: "`x`", unit: ""}]})
        verify(Exp.markdown({}, edge).indexOf("(formula `` `x` ``)") >= 0)
    }

    // ---- (d) plain numbers stay unescaped ----------------------------------
    function test_plain_numbers_are_not_escaped() {
        var view = simpleView({tables: [textTable(["-5", "+3.5", "-abc", "-.5", "-1e3", "+", "- 5", "-5 EUR", "=5", "\tx", "\rx"])]})
        var rows = parseCsv(Exp.csv({}, view))
        var data = rows.slice(rows.length - 11).map(function (r) { return r[0] })
        compare(data, ["-5", "+3.5", "'-abc", "-.5", "-1e3", "'+", "'- 5", "'-5 EUR", "'=5", "'\tx", "'\rx"])
        // Markdown never alters them
        var m = Exp.markdown({}, view)
        verify(m.indexOf("| -5 |\n| +3.5 |\n| -abc |") >= 0)
    }
    function test_csv_plain_number_rule_is_the_csvtypes_rule() {
        // the generator uses CsvTypes.PLAIN_NUMBER itself: pin a few boundaries
        var cases = {"0": "0", "-0": "-0", "+.5": "+.5", "1e5": "1e5", "-1.": "'-1.", "--1": "'--1", "-0x10": "'-0x10", "-Infinity": "'-Infinity"}
        for (var k in cases) {
            var rows = parseCsv(Exp.csv({}, simpleView({tables: [textTable([k])]})))
            compare(rows[rows.length - 1][0], cases[k], k)
        }
    }

    // ---- (e) CSV round trip ------------------------------------------------
    function test_csv_round_trip() {
        var tricky = ["plain", "a,b", "say \"hi\"", "two\r\nlines", "one\nline", "\"", ",", "", " lead and trail ", "x\ty"]
        var view = simpleView({
            inputs: [{id: "i", label: "In, put", unit: "k\"g", basis: "a\r\nb", value: "-5"}],
            cells: tricky.map(function (t, i) { return {id: "c" + i, label: t === "" ? "empty" : t, text: t, error: null, formula: t, unit: ""} }),
            tables: [textTable(tricky)], note: "n,o\"te\r\nx"})
        var rows = parseCsv(Exp.csv({title: "T, \"q\""}, view))
        compare(rows[0], ["Title", "T, \"q\""])
        compare(rows[2], ["Inputs"])
        compare(rows[4], ["In, put", "-5", "k\"g", "a\r\nb"])
        var cellRows = rows.slice(8, 8 + tricky.length)
        for (var i = 0; i < tricky.length; ++i) {
            compare(cellRows[i][0], tricky[i] === "" ? "empty" : tricky[i])
            compare(cellRows[i][1], tricky[i])
            compare(cellRows[i][3], tricky[i])
        }
        var tableRows = rows.slice(rows.length - 4 - tricky.length, rows.length - 2)
        compare(tableRows.map(function (r) { return r[0] }), ["T"].concat(["A"], tricky))
        compare(rows[rows.length - 1], ["Note", "n,o\"te\r\nx"])
        verify(Exp.csv({}, view).indexOf("\n") === Exp.csv({}, view).indexOf("\r\n") + 1)   // CRLF first
    }
    function test_csv_every_record_ends_crlf_and_matches_view() {
        var view = viewOf(example)
        var out = Exp.csv(example, view)
        verify(/\r\n$/.test(out))
        verify(!/[^\r]\n/.test(out.replace(/"[^"]*"/g, "")))   // no bare LF outside quoted fields
        var rows = parseCsv(out), tb = view.tables[0]
        var start = rows.findIndex(function (r) { return r.length === 1 && r[0] === "Laptops" })
        for (var r = 0; r < tb.rows.length; ++r)
            for (var c = 0; c < 5; ++c)
                compare(rows[start + 2 + r][c], tb.rows[r].cells[c].text)
    }

    // ---- (f) scenarios -----------------------------------------------------
    function scenarioView() {
        var a = CalcView.run(example, {}), b = CalcView.run(example, {w_perf: {v: 10, u: ""}, w_batt: {v: 10, u: ""}, w_price: {v: 10, u: ""}})
        function texts(run) { return ["wsum", "mean_score", "avg_price"].map(function (id) { return Calc.formatCell(run.plan.model, run.result, id) }) }
        var ta = texts(a), tb = texts(b)
        return {names: ["Base", "All 10"], rows: [
            {label: "Total weight", unit: "", values: [ta[0], tb[0]], errors: [null, null]},
            {label: "Average score", unit: "", values: [ta[1], tb[1]], errors: [null, null]},
            {label: "Average price", unit: "EUR", values: [ta[2], tb[2]], errors: [null, "DIV0"]}]}
    }
    function test_scenario_compare_table() {
        var sc = scenarioView()
        compare(sc.rows[1].values, ["60.2", "55.8"])   // 60.1667 and 55.8333 by hand
        compare(sc.rows[0].values, ["10", "30"])
        var view = viewOf(example, {}, {scenarios: sc})
        var m = Exp.markdown(example, view)
        verify(m.indexOf(md([
            "## Scenarios",
            "",
            "| Result | Base | All 10 |",
            "| --- | --- | --- |",
            "| Total weight | 10 | 30 |",
            "| Average score | 60.2 | 55.8 |",
            "| Average price | 1183 EUR | ERR:DIV0 |"])) >= 0)
        var c = Exp.csv(example, view)
        verify(c.indexOf(csvText([
            "Scenarios",
            "Result,Unit,Base,All 10",
            "Total weight,,10,30",
            "Average score,,60.2,55.8",
            "Average price,EUR,1183,ERR:DIV0"])) >= 0)
        // scenarios sit between the last table and the note
        verify(m.indexOf("## Scenarios") > m.indexOf("## Laptops"))
        verify(m.indexOf("## Scenarios") < m.indexOf("Illustrative"))
    }
    function test_edited_cells_are_marked_in_markdown_only() {
        var view = viewOf(example, {}, {edited: [{table: "laptops", row: 0, col: "perf"}, {table: "laptops", row: 2, col: "name"}]})
        var m = Exp.markdown(example, view)
        verify(m.indexOf("| Air 13 | 7 (edited) | 15 | 1100 | 66.50 |") >= 0)
        verify(m.indexOf("| Budget 15 (edited) | 5 | 8 | 650 | 50.50 |") >= 0)
        verify(Exp.csv(example, view).indexOf("Air 13,7,15,1100,66.50\r\n") >= 0)
    }

    // ---- (g) 64 KiB ----------------------------------------------------------
    function bigView(rowsCount, lastLen) {
        var texts = []
        for (var i = 0; i < rowsCount; ++i) texts.push(new Array((i === rowsCount - 1 ? lastLen : 100) + 1).join("x"))
        return simpleView({tables: [textTable(texts)]})
    }
    function boundary(make) {
        var n = 400   // 400 rows of ~100 bytes are well under the limit
        while (make(n + 1, 1).indexOf("[truncated]") < 0) ++n   // truncated output is always <= 64 KiB, so look for the marker
        var gap = 65536 - utf8(make(n, 1))
        verify(gap >= 0 && gap < 100)
        return {n: n, last: 1 + gap}
    }
    function test_markdown_truncation_boundary() {
        var make = function (n, k) { return Exp.markdown({}, bigView(n, k)) }
        var b = boundary(make)
        var exact = make(b.n, b.last)
        compare(utf8(exact), 65536)
        verify(exact.indexOf("[truncated]") < 0)
        var over = make(b.n, b.last + 1)
        verify(utf8(over) <= 65536)
        verify(/\n\n\[truncated\]\n$/.test(over))
        over.split("\n").slice(0, -2).forEach(function (l) {
            if (l.charAt(0) === "|") verify(/^\| x+ \|$|^\| A \|$|^\| --- \|$/.test(l), l.slice(0, 20))
        })
        verify(over.split("| xxxxxxxxxx").length < exact.split("| xxxxxxxxxx").length)
        verify(utf8(make(b.n + 40, 100)) <= 65536)
    }
    function test_csv_truncation_boundary() {
        var make = function (n, k) { return Exp.csv({}, bigView(n, k)) }
        var b = boundary(make)
        var exact = make(b.n, b.last)
        compare(utf8(exact), 65536)
        verify(exact.indexOf("[truncated]") < 0)
        var over = make(b.n, b.last + 1)
        verify(utf8(over) <= 65536)
        verify(/\r\n\r\n\[truncated\]\r\n$/.test(over))
        var rows = parseCsv(over)
        rows.slice(3, rows.length - 2).forEach(function (r) { verify(r.length === 1 && /^x+$/.test(r[0])) })
    }
    function test_truncation_never_leaves_a_heading_alone() {
        // many cells: the budget runs out inside the Cells list, never mid-line
        var cells = []
        for (var i = 0; i < 2000; ++i) cells.push({id: "c" + i, label: "Cell " + i, text: "1", error: null, formula: new Array(60).join("a+"), unit: ""})
        var m = Exp.markdown({}, simpleView({cells: cells}))
        verify(utf8(m) <= 65536)
        var ls = m.split("\n")
        compare(ls[ls.length - 2], "[truncated]")
        ls.slice(4, ls.length - 3).forEach(function (l) { verify(/^- Cell \d+: 1 \(formula `(a\+)+a?`\)$/.test(l), l) })
        var c = Exp.csv({}, simpleView({cells: cells}))
        verify(utf8(c) <= 65536)
        verify(/\r\n\r\n\[truncated\]\r\n$/.test(c))
        parseCsv(c).slice(3, -2).forEach(function (r) { compare(r.length, 4) })
    }

    // ---- (h) hostile strings ----------------------------------------------
    function test_control_and_bidi_characters_are_neutralised() {
        var evil = "a\u0000b\u202Ec\u2028d\u200Be\u0007\u2066f\u2029g\u0085h\u007Fi\uFEFFj"
        var expected = "abc de" + "f g h" + "ij"   // dropped: NUL, RLO, ZWSP, BEL, LRI, DEL, BOM; separators -> space
        var view = simpleView({inputs: [{id: "i", label: evil, unit: "", basis: "", value: evil}],
                               cells: [{id: "c", label: evil, text: evil, error: null, formula: evil, unit: ""}],
                               tables: [textTable([evil])], note: evil})
        var m = Exp.markdown({title: evil}, view)
        verify(m.indexOf(expected) >= 0, m)
        verify(!/[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u2028\u2029\u202A-\u202E\u2066-\u2069\u200B-\u200F\uFEFF]/.test(m))
        var c = Exp.csv({title: evil}, view)
        verify(c.indexOf(expected) >= 0, c)
        verify(!/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u2028\u2029\u202A-\u202E\u2066-\u2069\u200B-\u200F\uFEFF]/.test(c))
    }
    function test_line_breaks_and_markdown_syntax_cannot_break_structure() {
        var view = simpleView({inputs: [{id: "i", label: "a\nb\r\nc|d`e", unit: "", basis: "", value: "1"}],
                               tables: [textTable(["x|y\nz", "\\|"])], note: "# not a heading\nline2"})
        var m = Exp.markdown({title: "T\n## injected"}, view)
        compare(m, md([
            "# T ## injected",
            "",
            "## Inputs",
            "",
            "- a b  c\\|d\\`e: 1",
            "",
            "## T",
            "",
            "| A |",
            "| --- |",
            "| x\\|y z |",
            "| \\\\\\| |",
            "",
            "\\# not a heading line2"]))
    }
    function test_long_labels_are_clamped() {
        var long = new Array(5001).join("x")
        var view = simpleView({inputs: [{id: "i", label: long, unit: "", basis: "", value: long}], note: long})
        var m = Exp.markdown({title: long}, view)
        var ls = m.split("\n")
        compare(ls[0], "# " + new Array(160).join("x") + "\u2026")
        verify(ls[4].indexOf("- " + new Array(120).join("x") + "\u2026: " + new Array(200).join("x") + "\u2026") === 0)
        verify(utf8(m) < 3000)
        var c = Exp.csv({title: long}, view)
        verify(utf8(c) < 3000)
        // a pair of surrogates is never cut in half
        var emoji = new Array(300).join("\uD83D\uDE00")
        var out = Exp.markdown({title: emoji}, simpleView({}))
        verify(!/[\uD800-\uDBFF]\u2026/.test(out))
        verify(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(out))
    }
    function test_lone_surrogates_become_replacement_characters() {
        var view = simpleView({inputs: [{id: "i", label: "a\uD800b\uDC00c", unit: "", basis: "", value: "1"}]})
        verify(Exp.markdown({}, view).indexOf("- a\uFFFDb\uFFFDc: 1") >= 0)
        verify(Exp.csv({}, view).indexOf("a\uFFFDb\uFFFDc,1") >= 0)
    }
    function test_garbage_views_never_throw() {
        var garbage = [null, undefined, 5, "x", [], {}, {inputs: 5, cells: [null, 3, "x", []], tables: [null, {columns: 3, rows: "x"},
            {columns: [null, 7], rows: [null, {cells: 4}, {cells: [null]}]}], scenarios: {names: [1, null], rows: [null, {values: 3}]}, note: 5},
            {cells: [{label: {}, text: [], error: {code: {}}, formula: 9}]}]
        for (var i = 0; i < garbage.length; ++i) {
            var m = Exp.markdown(garbage[i], garbage[i]), c = Exp.csv(garbage[i], garbage[i])
            compare(typeof m, "string")
            compare(typeof c, "string")
        }
        compare(Exp.markdown({title: "T"}, null), "# T\n\nThis calculation can't be shown.\n")
        compare(Exp.csv({title: "T"}, null), "Title,T\r\n\r\nNote,This calculation can't be shown.\r\n")
        var cyc = {}; cyc.self = cyc
        compare(typeof Exp.markdown(cyc, cyc), "string")
        compare(typeof Exp.csv(cyc, cyc), "string")
        compare(Exp.viewFromRun(cyc, cyc, cyc, cyc), null)
    }
    function test_short_rows_and_extra_cells_stay_rectangular() {
        var view = simpleView({tables: [{id: "t", label: "T", columns: [{id: "a", label: "A", unit: "kg", kind: "number"}, {id: "b", label: "B", unit: "x", kind: "text"}],
            rows: [{id: "1", cells: [{text: "1", error: null}]}, {id: "2", cells: [{text: "1"}, {text: "2"}, {text: "3"}]}]}]})
        var m = Exp.markdown({}, view)
        verify(m.indexOf("| A (kg) | B |\n| --- | --- |\n|") >= 0)
        verify(m.indexOf("| 1 |  |\n| 1 | 2 |\n") >= 0)
        compare(parseCsv(Exp.csv({}, view)).slice(-3), [["A (kg)", "B"], ["1", ""], ["1", "2"]])
    }

    // ---- (i) determinism -----------------------------------------------------
    function test_deterministic() {
        var v1 = viewOf(example), v2 = viewOf(clone(example))
        compare(JSON.stringify(v1), JSON.stringify(v2))
        compare(Exp.markdown(example, v1), Exp.markdown(clone(example), v2))
        compare(Exp.csv(example, v1), Exp.csv(clone(example), v2))
        compare(Exp.markdown(example, v1), Exp.markdown(example, v1))
        var before = JSON.stringify(v1)
        Exp.markdown(example, v1); Exp.csv(example, v1)
        compare(JSON.stringify(v1), before)   // the view is never mutated
    }
}
