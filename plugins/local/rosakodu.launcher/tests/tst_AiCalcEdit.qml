import QtQuick
import QtTest
import "../AiCalc.js" as Calc
import "../AiCalcEdit.js" as Edit
import "../AiCalcView.js" as View
import "../AiState.js" as State
import "CalcCellCases.js" as Cells

// Editable calc data + scenarios: pure logic (AiCalcEdit.js) and its adapter
// (AiCalcView.js). The table-cell classification is checked against the SAME
// file the Python engine reads (CalcCellCases.js) and, for numbers, against the
// JS engine itself; edit sequences are checked against an oracle that rebuilds
// the spec from scratch. No file, process or provider.
TestCase {
    name: "AiCalcEdit"

    // ---- helpers ------------------------------------------------------
    function makeRng(seed) {
        var s = seed >>> 0
        return function () {
            s = (s + 0x6D2B79F5) >>> 0
            var t = s
            t = Math.imul(t ^ (t >>> 15), t | 1)
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296
        }
    }
    function pick(rng, list) { return list[Math.floor(rng() * list.length)] }
    function clone(v) { return JSON.parse(JSON.stringify(v)) }
    function sameJson(a, b, msg) { compare(JSON.stringify(a), JSON.stringify(b), msg) }
    function rep(ch, n) { var s = ""; while (n-- > 0) s += ch; return s }

    // The worked example from ai_catalog.CALC_EXAMPLE (keep in step with it).
    function example() {
        return JSON.parse('{"type":"calc","title":"Laptop score","inputs":[{"id":"w_perf","label":"Speed weight","unit":"","min":0,"max":10,"step":1,"value":5,"basis":"assumption"},{"id":"w_batt","label":"Battery weight","unit":"","min":0,"max":10,"step":1,"value":3,"basis":"assumption"},{"id":"w_price","label":"Price weight","unit":"","min":0,"max":10,"step":1,"value":2,"basis":"assumption"}],"tables":[{"id":"laptops","label":"Laptops","columns":[{"id":"name","label":"Laptop","unit":"","kind":"text","expression":""},{"id":"perf","label":"Speed (0-10)","unit":"","kind":"number","expression":""},{"id":"batt","label":"Battery","unit":"h","kind":"number","expression":""},{"id":"price","label":"Price","unit":"EUR","kind":"number","expression":""},{"id":"score","label":"Score","unit":"","kind":"formula","expression":"if(wsum==0,0,(w_perf*perf/10+w_batt*batt/20[h]+w_price*clamp(1-price/2000[EUR],0,1))/wsum*100)"}],"rows":[["Air 13","7","15","1100",""],["Pro 14","9","11","1800",""],["Budget 15","5","8","650",""]]}],"cells":[{"id":"wsum","label":"Total weight","expression":"w_perf+w_batt+w_price","unit":"","decimals":0,"note":""},{"id":"mean_score","label":"Average score","expression":"mean(laptops.score)","unit":"","decimals":1,"note":""},{"id":"avg_price","label":"Average price","expression":"mean(laptops.price)","unit":"EUR","decimals":0,"note":""}],"note":"Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."}')
    }
    // weights 5/3/2; rows Air 13 (7,15,1100), Pro 14 (9,11,1800), Budget 15 (5,8,650)
    function scoreText(plan, result, row) { return Calc.formatCell(plan.model, result, "laptops.score#" + (row + 1)) }
    function scores(plan, result) {
        var out = [], n = plan.tables[0].rows.length
        for (var i = 0; i < n; ++i) out.push(scoreText(plan, result, i))
        return out
    }
    function weights(a, b, c) {
        return {w_perf: {v: a, u: ""}, w_batt: {v: b, u: ""}, w_price: {v: c, u: ""}}
    }
    function snap(plan, result) {
        var ids = plan.model.orderIds, out = []
        for (var i = 0; i < ids.length; ++i) {
            var r = result.nodes[ids[i]]
            out.push([ids[i], Calc.formatCell(plan.model, result, ids[i]), r.err ? r.err.code : null])
        }
        return out
    }
    function mustOk(r, msg) { verify(r.ok === true, (msg || "op") + " failed: " + JSON.stringify(r)); return r }

    // engine verdict for a number cell, via a two-row column [raw, "1"]
    function engineClass(raw) {
        var m = Calc.compileSpec({inputs: [], tables: [{id: "t", columns: [{id: "v", kind: "number", unit: "", expression: ""}],
            rows: [[raw], ["1"]]}], cells: [{id: "sm", expression: "sum(t.v)", unit: "", decimals: 2},
                                              {id: "cn", expression: "count(t.v)", unit: "", decimals: 0}]})
        var r = Calc.evaluate(m, {}, null, null)
        if (r.nodes.sm.err) return {code: r.nodes.sm.err.code, empty: false, value: null}
        return {code: null, empty: r.nodes.cn.value === 1, value: r.nodes.sm.value - 1}
    }

    // ---- parseCell ----------------------------------------------------
    function test_parseCellMatchesTheSharedCases_data() {
        return Cells.CASES.map(function (c) { return {tag: c.tag, c: c} })
    }
    function test_parseCellMatchesTheSharedCases(data) {
        var c = data.c, p = Edit.parseCell(c.raw, c.kind)
        compare(p.ok, c.ok)
        compare(p.empty, c.empty)
        compare(p.code, c.code)
        if (c.ok) compare(p.msg, "")
        else verify(p.msg.length > 0 && p.msg.length < 80, "static short message")
        if (c.ok && !c.empty && c.kind === "number") compare(p.value, Number(c.raw.trim()))
        if (c.ok && !c.empty && c.kind === "text") compare(p.text, c.raw.replace(/^[ \t\n\r\v\f]+|[ \t\n\r\v\f]+$/g, ""))
        if (c.ok && c.empty) compare(p.text, "")
    }
    function test_numberCasesAgreeWithTheJsEngine_data() {
        return Cells.CASES.filter(function (c) { return c.kind === "number" && c.engine !== false })
                          .map(function (c) { return {tag: c.tag, c: c} })
    }
    function test_numberCasesAgreeWithTheJsEngine(data) {
        var e = engineClass(data.c.raw)
        compare(e.code, data.c.code)
        if (!e.code) compare(e.empty, data.c.empty)
    }
    function test_launcherOnlyCapIsStricterThanTheEngine() {
        var raw = rep("1", 65), e = engineClass(raw)
        compare(e.code, null, "the engine accepts it")
        compare(Edit.parseCell(raw, "number").code, "RANGE")
        compare(Edit.parseCell(rep("1", 64), "number").ok, true)
    }
    function test_parseCellAgreesWithTheEngineOnRandomStrings() {
        var rng = makeRng(20261009), alphabet = "0123456789012345+-..eE ,_\t\u00a0x\u0661\n", seen = {ok: 0, type: 0, range: 0, empty: 0}
        for (var i = 0; i < 700; ++i) {
            var s = "", n = Math.floor(rng() * 8)
            for (var k = 0; k < n; ++k) s += alphabet.charAt(Math.floor(rng() * alphabet.length))
            if (i % 50 === 0) s = "1e" + (305 + Math.floor(rng() * 10))
            var p = Edit.parseCell(s, "number"), e = engineClass(s)
            compare(p.code, e.code, JSON.stringify(s))
            if (!e.code) compare(p.empty, e.empty, JSON.stringify(s))
            if (p.ok && !p.empty) verify(Math.abs(p.value - e.value) <= 1e-9 * Math.max(1, Math.abs(p.value)) || Math.abs(p.value) > 1e15, JSON.stringify(s))
            if (p.ok && p.empty) seen.empty++; else if (p.ok) seen.ok++; else if (p.code === "TYPE") seen.type++; else seen.range++
        }
        verify(seen.ok > 30 && seen.type > 100 && seen.empty > 3 && seen.range > 5, JSON.stringify(seen))
    }
    function test_nonStringsAndFormulaColumnsAreRejected() {
        compare(Edit.parseCell(5, "number").ok, false)
        compare(Edit.parseCell(null, "text").ok, false)
        compare(Edit.parseCell("5", "formula").ok, false)
        compare(Edit.parseCell("5", "formula").msg, "This column is calculated.")
        compare(Edit.parseCell("1,5", "number").msg, "Not a plain number. Use a decimal point, e.g. 1.5")
    }
    function test_plainNameFollowsTheWorkspaceNamePolicy() {
        var probes = ["Base", "  Base  ", "", "   ", "a\tb", "a\u0000b", "\u200bx", "a\u202eb", "\ud800", "x\udc00", "caf\u00e9",
                      "ok \ud83d\ude00", "\ufeff", "a\u00adb", "\u00a0", rep("x", 32), rep("x", 33), "a\nb", "\nab"]
        for (var i = 0; i < probes.length; ++i) {
            var want = State.workspaceName(probes[i])
            if (want.length > 32) want = ""
            compare(Edit.plainName(probes[i]), want, JSON.stringify(probes[i]))
        }
        compare(Edit.plainName(5), "")
    }

    // ---- sizeOf / commit ----------------------------------------------
    function test_sizeOfCountsUtf8Bytes() {
        compare(Edit.sizeOf({}), 2)
        compare(Edit.sizeOf({a: "\u00e9"}), JSON.stringify({a: "\u00e9"}).length + 1)
        compare(Edit.sizeOf({a: "\ud83d\ude00"}), JSON.stringify({a: "\ud83d\ude00"}).length + 2)
        compare(Edit.sizeOf({a: "\u20ac"}), JSON.stringify({a: "\u20ac"}).length + 2)
    }
    function textBlock() {
        var cols = [], rows = [], i, r
        for (i = 0; i < 12; ++i) cols.push({id: "c" + i, label: "C", kind: "text", unit: "", expression: ""})
        for (r = 0; r < 40; ++r) rows.push(cols.map(function () { return "" }))
        return {type: "calc", title: "T", inputs: [], cells: [], tables: [{id: "t", label: "T", columns: cols, rows: rows}], note: ""}
    }
    function test_commitRefusesOverTenKiB() {
        var block = textBlock(), data = {}, last = null, refused = null, big = rep("w", 64)
        for (var r = 0; r < 40 && !refused; ++r)
            for (var c = 0; c < 12 && !refused; ++c) {
                var op = mustOk(Edit.setCell(data, block, "t", String(r), "c" + c, big), "setCell")
                var res = Edit.commit({}, op.data, [])
                if (res.ok) { data = op.data; last = res } else refused = res
            }
        verify(refused !== null, "reached the cap")
        compare(refused.reason, "too-large")
        verify(refused.bytes > 10240 && last.bytes <= 10240)
        compare(Edit.sizeOf(last.entry), last.bytes)
        // the refused data was never adopted: the accepted data still fits
        verify(Edit.commit({}, data, []).ok)
    }

    // ---- hand-verified example ----------------------------------------
    // Exact-fraction recomputation outside the engine (also in ai_catalog.CALC_EXAMPLE's comment):
    // 5/3/2: 66.5, 63.5, 50.5; Pro 14 at 1700: (4.5+1.65+0.3)/10*100 = 64.5, mean (66.5+64.5+50.5)/3 = 60.5,
    // mean price (1100+1700+650)/3 = 1150; 10/0/0: 70, 90, 50; 0/0/10: 45, 10, 67.5.
    function test_exampleAuthoredNumbers() {
        var run = View.run(example(), {})
        sameJson(scores(run.plan, run.result), ["66.50", "63.50", "50.50"])
        compare(Calc.formatCell(run.plan.model, run.result, "mean_score"), "60.2")
        compare(Calc.formatCell(run.plan.model, run.result, "avg_price"), "1183 EUR")
    }
    function test_exampleEditedPrice() {
        var block = example(), op = mustOk(Edit.setCell({}, block, "laptops", "1", "price", "1700"))
        sameJson(op.data, {laptops: {e: {"1|price": "1700"}}})
        var run = View.run(block, Edit.compose({}, op.data, []))
        compare(run.reset, false)
        sameJson(scores(run.plan, run.result), ["66.50", "64.50", "50.50"])
        compare(Calc.formatCell(run.plan.model, run.result, "mean_score"), "60.5")
        compare(Calc.formatCell(run.plan.model, run.result, "avg_price"), "1150 EUR")
        sameJson(run.plan.edited, {cells: 1, rowsAdded: 0, rowsRemoved: 0})
        sameJson(run.plan.tables[0].rowIds, ["0", "1", "2"])
        compare(run.plan.tables[0].rows[1][3], "1700")
    }
    function test_exampleWeightsOnEditedData() {
        var block = example(), data = mustOk(Edit.setCell({}, block, "laptops", "1", "price", "1700")).data
        var run = View.run(block, Edit.compose(weights(10, 0, 0), data, []))
        sameJson(scores(run.plan, run.result), ["70.00", "90.00", "50.00"], "price does not matter at 10/0/0")
        run = View.run(block, Edit.compose(weights(0, 0, 10), {}, []))
        sameJson(scores(run.plan, run.result), ["45.00", "10.00", "67.50"])
        run = View.run(block, Edit.compose(weights(0, 0, 10), data, []))
        sameJson(scores(run.plan, run.result), ["45.00", "15.00", "67.50"], "Pro 14 at 1700: 100*(1-0.85)")
        run = View.run(block, Edit.compose(weights(0, 0, 0), {}, []))
        sameJson(scores(run.plan, run.result), ["0.00", "0.00", "0.00"])
    }
    function test_exampleAddedAndRemovedRows() {
        var block = example(), d = {}
        d = mustOk(Edit.removeRow(d, block, "laptops", "0")).data
        var add = mustOk(Edit.addRow(d, block, "laptops"))
        compare(add.rowId, "n1")
        d = add.data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "name", "Fresh")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "perf", "10")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "batt", "20")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "price", "0")).data
        var run = View.run(block, Edit.compose({}, d, []))
        sameJson(run.plan.tables[0].rowIds, ["1", "2", "n1"])
        // Fresh: (5*1 + 3*1 + 2*1)/10*100 = 100
        sameJson(scores(run.plan, run.result), ["63.50", "50.50", "100.00"])
        compare(Calc.formatCell(run.plan.model, run.result, "mean_score"), "71.3")   // (63.5+50.5+100)/3 = 71.33
        compare(Calc.formatCell(run.plan.model, run.result, "avg_price"), "817 EUR")  // (1800+650+0)/3 = 816.67
    }

    // ---- applyData ----------------------------------------------------
    function test_noEditEffectiveSpecEqualsAuthored() {
        var block = example(), ap = Edit.applyData(block, {})
        verify(ap.ok)
        sameJson(ap.block, block)
        sameJson(ap.rowIds, {laptops: ["0", "1", "2"]})
        sameJson(ap.edited, {cells: 0, rowsAdded: 0, rowsRemoved: 0})
        sameJson(Edit.applyData(block, undefined).block, block)
        sameJson(Edit.applyData(block, null).block, block)
        var a = View.build(block), b = View.build(block, {})
        sameJson(a.tables, b.tables)
        compare(a.dataKey, "")
        compare(a.dataReset, false)
    }
    function test_applyDataNeverMutatesItsInputs() {
        var block = example(), data = mustOk(Edit.setCell({}, block, "laptops", "0", "perf", "8")).data
        var b0 = JSON.stringify(block), d0 = JSON.stringify(data)
        Edit.applyData(block, data)
        Edit.addRow(data, block, "laptops"); Edit.removeRow(data, block, "laptops", "1"); Edit.setCell(data, block, "laptops", "1", "perf", "3")
        Edit.bake(block, {_d: data})
        compare(JSON.stringify(block), b0)
        compare(JSON.stringify(data), d0)
    }
    function test_editThenRevertIsIdentical() {
        var block = example(), d1 = mustOk(Edit.setCell({}, block, "laptops", "2", "price", "700")).data
        var back = mustOk(Edit.setCell(d1, block, "laptops", "2", "price", "650"))
        sameJson(back.data, {})
        compare(back.changed, false)
        // equal after trimming still counts as the authored value
        sameJson(mustOk(Edit.setCell(d1, block, "laptops", "2", "price", " 650 ")).data, {})
        // a different spelling of the same number is an edit
        sameJson(mustOk(Edit.setCell({}, block, "laptops", "2", "price", "650.0")).data, {laptops: {e: {"2|price": "650.0"}}})
    }
    function test_addThenRemoveIsIdentical() {
        var block = example(), add = mustOk(Edit.addRow({}, block, "laptops"))
        sameJson(mustOk(Edit.removeRow(add.data, block, "laptops", add.rowId)).data, {})
        var base = mustOk(Edit.removeRow({}, block, "laptops", "1")).data
        add = mustOk(Edit.addRow(base, block, "laptops"))
        sameJson(mustOk(Edit.removeRow(add.data, block, "laptops", add.rowId)).data, base)
        // ids are never reused while added rows exist
        var two = mustOk(Edit.addRow(add.data, block, "laptops"))
        compare(two.rowId, "n2")
        var one = mustOk(Edit.removeRow(two.data, block, "laptops", "n1")).data
        compare(mustOk(Edit.addRow(one, block, "laptops")).rowId, "n3")
        // removing an added row also drops its edited cells
        var withCell = mustOk(Edit.setCell(add.data, block, "laptops", "n1", "name", "Zed")).data
        sameJson(mustOk(Edit.removeRow(withCell, block, "laptops", "n1")).data, base)
    }
    function test_removeAndRestoreAuthoredRow() {
        var block = example(), d = mustOk(Edit.setCell({}, block, "laptops", "1", "perf", "1")).data
        d = mustOk(Edit.removeRow(d, block, "laptops", "1")).data
        sameJson(d, {laptops: {x: ["1"]}}, "its edit went with it")
        compare(Edit.setCell(d, block, "laptops", "1", "perf", "2").reason, "unknown-row")
        compare(Edit.removeRow(d, block, "laptops", "1").reason, "unknown-row")
        sameJson(mustOk(Edit.restoreRow(d, block, "laptops", "1")).data, {})
        compare(Edit.restoreRow({}, block, "laptops", "1").reason, "unknown-row")
        var ap = Edit.applyData(block, d)
        sameJson(ap.rowIds, {laptops: ["0", "2"]})
        sameJson(ap.edited, {cells: 0, rowsAdded: 0, rowsRemoved: 1})
    }
    function test_opsReportWhyTheyRefuse() {
        var block = example()
        compare(Edit.setCell({}, block, "nope", "0", "perf", "1").reason, "unknown-table")
        compare(Edit.setCell({}, block, "laptops", "0", "nope", "1").reason, "unknown-column")
        compare(Edit.setCell({}, block, "laptops", "0", "score", "1").reason, "formula-column")
        compare(Edit.setCell({}, block, "laptops", "9", "perf", "1").reason, "unknown-row")
        compare(Edit.setCell({}, block, "laptops", "n1", "perf", "1").reason, "unknown-row")
        var bad = Edit.setCell({}, block, "laptops", "0", "perf", "1,5")
        compare(bad.reason, "invalid")
        compare(bad.code, "TYPE")
        compare(Edit.setCell({}, block, "laptops", "0", "perf", "1e999").code, "RANGE")
        compare(Edit.addRow({}, block, "nope").reason, "unknown-table")
        compare(Edit.removeRow({}, block, "nope", "0").reason, "unknown-table")
        sameJson(Edit.discardEdits({laptops: {x: ["0"]}}), {})
        // a blank number cell is a real edit (the value goes missing downstream)
        var blank = mustOk(Edit.setCell({}, block, "laptops", "0", "perf", "  ")).data
        sameJson(blank, {laptops: {e: {"0|perf": ""}}})
    }

    // ---- limits -------------------------------------------------------
    // 12 inputs + 24 cells + t: 6 formula columns x tRows + uu: 2 formula columns x uRows
    function wide(tRows, uRows) {
        var inputs = [], cells = [], i, r
        for (i = 1; i <= 12; ++i) inputs.push({id: "i" + i, label: "I", unit: "", min: 0, max: 100, step: 1, value: 5, basis: "assumption"})
        var tcols = [{id: "x", label: "X", kind: "number", unit: "", expression: ""}], fe = ["x*i1", "f1+i2", "f2*2", "f3-i3", "f4+x", "f5/2+i4"]
        for (i = 0; i < 6; ++i) tcols.push({id: "f" + (i + 1), label: "F", kind: "formula", unit: "", expression: fe[i]})
        var trows = []
        for (r = 0; r < tRows; ++r) trows.push([String(r + 1), "", "", "", "", "", ""])
        var ucols = [{id: "y", label: "Y", kind: "number", unit: "", expression: ""},
                     {id: "g1", label: "G", kind: "formula", unit: "", expression: "y+i5"},
                     {id: "g2", label: "G", kind: "formula", unit: "", expression: "g1*i6"}]
        var urows = []
        for (r = 0; r < uRows; ++r) urows.push([String(r + 1), "", ""])
        var ce = ["sum(t.f6)", "mean(t.f5)", "sum(uu.g2)", "sum(t.f1)"]
        for (i = 1; i <= 24; ++i) cells.push({id: "c" + i, label: "C", expression: i <= 4 ? ce[i - 1] : "c" + (i - 1) + "+i1", unit: "", decimals: 2, note: ""})
        return {type: "calc", title: "Wide", inputs: inputs, cells: cells, note: "",
                tables: [{id: "t", label: "T", columns: tcols, rows: trows}, {id: "uu", label: "U", columns: ucols, rows: urows}]}
    }
    function test_rowLimitGuard() {
        var block = example(), d = {}, i
        // 3 authored rows; add up to 40 then refuse
        for (i = 3; i < 40; ++i) d = mustOk(Edit.addRow(d, block, "laptops"), "add " + i).data
        compare(Edit.applyData(block, d).block.tables[0].rows.length, 40)
        var r = Edit.addRow(d, block, "laptops")
        compare(r.ok, false)
        compare(r.reason, "max-rows")
        // removing one makes room again
        d = mustOk(Edit.removeRow(d, block, "laptops", "0")).data
        mustOk(Edit.addRow(d, block, "laptops"))
        // restoring a removed row at 40 rows is refused too
        var full = mustOk(Edit.addRow(d, block, "laptops")).data
        compare(Edit.restoreRow(full, block, "laptops", "0").reason, "max-rows")
    }
    function test_graphNodeGuardMatchesTheEngine() {
        var b = wide(40, 12)
        verify(View.build(b) !== null, "300 nodes compile")
        compare(Edit.addRow({}, b, "uu").reason, "max-graph")
        compare(Edit.addRow({}, b, "t").reason, "max-rows")
        // the engine really does refuse 302
        var over = wide(40, 13), why = null
        try { Calc.compileSpec({inputs: over.inputs.map(function (i) { return {id: i.id, unit: "", value: 5, min: 0, max: 100} }),
                                tables: over.tables, cells: over.cells}) } catch (e) { why = e.why }
        compare(why, "limit-graph")
        // 298 nodes: a row of t (6 more) is refused by the graph, not the row cap; a row of uu (2 more) fits
        var near = wide(39, 14)
        compare(Edit.addRow({}, near, "t").reason, "max-graph")
        var ok = mustOk(Edit.addRow({}, near, "uu"))
        verify(View.build(near, {_d: ok.data}) !== null)
        compare(View.build(near, {_d: ok.data}).dataReset, false)
        // data that would exceed a limit when restored is dropped whole, with a reset
        var forged = {t: {a: ["n1"], n: 2}}
        var plan = View.build(near, {_d: forged})
        compare(plan.dataReset, true)
        compare(plan.tables[0].rows.length, 39)
        sameJson(plan.data, {})
        var ap = Edit.applyData(near, forged)
        compare(ap.ok, false)
        compare(ap.reason, "max-graph")
        sameJson(ap.block, near)
    }
    function test_textCellRules() {
        var block = example()
        mustOk(Edit.setCell({}, block, "laptops", "0", "name", rep("x", 64)))
        compare(Edit.setCell({}, block, "laptops", "0", "name", rep("x", 65)).code, "RANGE")
        compare(Edit.setCell({}, block, "laptops", "0", "name", "a\u0000b").code, "TYPE")
        compare(Edit.setCell({}, block, "laptops", "0", "name", "a\u202eb").reason, "invalid")
        compare(Edit.setCell({}, block, "laptops", "0", "name", "\ud800").reason, "invalid")
        mustOk(Edit.setCell({}, block, "laptops", "0", "name", "ok \ud83d\ude00"))
        sameJson(mustOk(Edit.setCell({}, block, "laptops", "0", "name", "  Air 13 ")).data, {})
    }

    // ---- restore validation -------------------------------------------
    function test_staleOrBadDataIsDroppedAndFlagged_data() {
        return [
            {tag: "unknown-table", d: {nope: {e: {"0|perf": "1"}}}},
            {tag: "unknown-row", d: {laptops: {e: {"99|perf": "1"}}}},
            {tag: "unknown-added-row", d: {laptops: {e: {"n1|perf": "1"}}}},
            {tag: "unknown-column", d: {laptops: {e: {"0|zzz": "1"}}}},
            {tag: "formula-column", d: {laptops: {e: {"0|score": "5"}}}},
            {tag: "bad-parse", d: {laptops: {e: {"0|perf": "1,5"}}}},
            {tag: "overflow", d: {laptops: {e: {"0|perf": "1e999"}}}},
            {tag: "non-string", d: {laptops: {e: {"0|perf": 5}}}},
            {tag: "no-pipe", d: {laptops: {e: {"perf": "5"}}}},
            {tag: "removed-row-edit", d: {laptops: {x: ["0"], e: {"0|perf": "1"}}}},
            {tag: "bad-removed-id", d: {laptops: {x: ["7"]}}},
            {tag: "leading-zero-id", d: {laptops: {x: ["01"]}}},
            {tag: "duplicate-removed", d: {laptops: {x: ["1", "1"]}}},
            {tag: "added-without-counter", d: {laptops: {a: ["n1"]}}},
            {tag: "added-id-beyond-counter", d: {laptops: {a: ["n3"], n: 2}}},
            {tag: "added-bad-id", d: {laptops: {a: ["x1"], n: 2}}},
            {tag: "counter-without-rows", d: {laptops: {n: 3}}},
            {tag: "unknown-key", d: {laptops: {q: 1}}},
            {tag: "record-not-object", d: {laptops: 5}},
            {tag: "data-not-object", d: 5},
            {tag: "data-array", d: []},
            {tag: "removed-not-array", d: {laptops: {x: "0"}}},
            {tag: "edits-not-object", d: {laptops: {e: []}}}
        ]
    }
    function test_staleOrBadDataIsDroppedAndFlagged(data) {
        var block = example(), entry = {_d: data.d}, plan = View.build(block, entry)
        verify(plan !== null)
        compare(plan.dataReset, true)
        compare(View.restore(plan, entry).reset, true)
        var run = View.run(block, entry)
        compare(run.reset, true)
        // none of it was applied
        verify(run.plan.edited.cells === 0 && run.plan.edited.rowsAdded === 0)
        if (data.tag !== "removed-row-edit" && data.tag !== "bad-removed-id" && data.tag !== "duplicate-removed" && data.tag !== "leading-zero-id")
            sameJson(run.plan.tables[0].rows, View.build(block).tables[0].rows)
    }
    function test_goodDataDoesNotReset() {
        var block = example(), entries = [
            {_d: {laptops: {e: {"1|price": "1700"}}}},
            {_d: {laptops: {x: ["2"], a: ["n1"], n: 2, e: {"n1|name": "Zed"}}}},
            {_d: {laptops: {e: {"0|perf": ""}}}},
            {w_perf: {v: 7, u: ""}, nothing: {v: 1, u: ""}},
            {_d: {}}, {}]
        for (var i = 0; i < entries.length; ++i) {
            var run = View.run(block, entries[i])
            compare(run.reset, false, JSON.stringify(entries[i]))
            verify(run.plan !== null)
        }
        compare(View.run(block, {w_perf: {v: 7, u: ""}}).current.w_perf, 7)
        compare(View.run(block, {w_perf: {v: 70, u: ""}}).reset, true)
        compare(View.run(block, {w_perf: {v: 7, u: "kg"}}).current.w_perf, 5)
    }
    function test_badScenariosAreDroppedAndFlagged() {
        var block = example(), plan = View.build(block)
        var good = {n: "Speed", v: {w_perf: {v: 9, u: ""}}}
        var cases = [
            [good, {n: "B", v: {}}, {n: "C", v: {}}, {n: "D", v: {}}],      // a fourth
            [good, {n: "", v: {}}],
            [good, {n: " pad ", v: {}}],
            [good, {n: rep("x", 33), v: {}}],
            [good, {n: "a\u0000b", v: {}}],
            [good, {n: "Speed", v: {}}],                                    // duplicate name
            [good, {n: "E", v: {nope: {v: 1, u: ""}}}],
            [good, {n: "E", v: {w_perf: {v: 11, u: ""}}}],                  // out of range: never clamped
            [good, {n: "E", v: {w_perf: {v: 5, u: "kg"}}}],
            [good, {n: "E", v: {w_perf: {v: "5", u: ""}}}],
            [good, {n: "E"}], [good, 5], [good, null], 5, {}]
        for (var i = 0; i < cases.length; ++i) {
            var st = View.restore(plan, {_s: cases[i]})
            compare(st.reset, true, "case " + i)
            if (Array.isArray(cases[i])) sameJson(st.scenarios[0], good, "the valid one survives, case " + i)
            else sameJson(st.scenarios, [])
        }
        // the unknown input / bad value is dropped from an otherwise good scenario
        var one = View.restore(plan, {_s: [{n: "E", v: {w_perf: {v: 11, u: ""}, w_batt: {v: 2, u: ""}}}]})
        sameJson(one.scenarios, [{n: "E", v: {w_batt: {v: 2, u: ""}}}])
        var fine = View.restore(plan, {_s: [good, {n: "Cheap", v: {}}]})
        compare(fine.reset, false)
        compare(fine.scenarios.length, 2)
    }
    function test_dataKeyIgnoresInputsAndScenarios() {
        var block = example(), d = mustOk(Edit.setCell({}, block, "laptops", "1", "price", "1700")).data
        compare(View.dataKey({}), "")
        compare(View.dataKey(null), "")
        compare(View.dataKey({_d: {}}), "")
        var k = View.dataKey(Edit.compose({}, d, []))
        compare(k, JSON.stringify(d))
        compare(View.dataKey(Edit.compose(weights(1, 2, 3), d, [{n: "A", v: {}}])), k)
        var plan = View.build(block, k)
        compare(plan.dataKey, k)
        sameJson(View.build(block, {_d: d, w_perf: {v: 9, u: ""}}).tables, plan.tables)
        verify(View.dataKey(Edit.compose({}, mustOk(Edit.setCell(d, block, "laptops", "1", "price", "1600")).data, [])) !== k)
        // canonical: the same edits made in a different order have the same key
        var a = mustOk(Edit.setCell(mustOk(Edit.setCell({}, block, "laptops", "0", "perf", "1")).data, block, "laptops", "2", "perf", "2")).data
        var b = mustOk(Edit.setCell(mustOk(Edit.setCell({}, block, "laptops", "2", "perf", "2")).data, block, "laptops", "0", "perf", "1")).data
        compare(View.dataKey({_d: a}), View.dataKey({_d: b}))
    }
    function test_composeAndParts() {
        var d = {laptops: {x: ["0"]}}, s = [{n: "A", v: {}}]
        sameJson(Edit.compose({}, {}, []), {})
        sameJson(Edit.compose(weights(1, 2, 3), d, s), {w_perf: {v: 1, u: ""}, w_batt: {v: 2, u: ""}, w_price: {v: 3, u: ""}, _d: d, _s: s})
        sameJson(Edit.compose({_d: 5, w_perf: {v: 1, u: ""}}, d, []), {w_perf: {v: 1, u: ""}, _d: d}, "reserved keys never leak from inputs")
        var entry = Edit.compose(weights(1, 2, 3), d, s), p = Edit.parts(entry)
        sameJson(p.inputs, weights(1, 2, 3)); sameJson(p.data, d); sameJson(p.scenarios, s)
        sameJson(Edit.parts(null), {inputs: {}, data: {}, scenarios: []})
        var src = {a: {v: 1, u: ""}}, out = Edit.compose(src, {}, [])
        out.a.v = 2
        compare(src.a.v, 1, "deep copy")
    }

    // ---- scenarios ----------------------------------------------------
    function test_scenarioOps() {
        var scn = [], r = mustOk(Edit.saveScenario(scn, "  Speed first ", weights(10, 0, 0)))
        sameJson(r.scenarios, [{n: "Speed first", v: weights(10, 0, 0)}])
        compare(r.index, 0)
        compare(scn.length, 0, "input untouched")
        compare(Edit.saveScenario(r.scenarios, "a\u0000", {}).reason, "bad-name")
        compare(Edit.saveScenario(r.scenarios, rep("x", 33), {}).reason, "bad-name")
        compare(Edit.saveScenario(r.scenarios, "  ", {}).reason, "bad-name")
        var r2 = mustOk(Edit.saveScenario(r.scenarios, "Price first", weights(0, 0, 10)))
        var r3 = mustOk(Edit.saveScenario(r2.scenarios, "Even", {}))
        compare(Edit.saveScenario(r3.scenarios, "Fourth", {}).reason, "full")
        // same name replaces in place, even when full
        var r4 = mustOk(Edit.saveScenario(r3.scenarios, "Price first", weights(1, 1, 1)))
        compare(r4.index, 1)
        compare(r4.scenarios.length, 3)
        sameJson(r4.scenarios[1].v, weights(1, 1, 1))
        // only well-formed changed inputs are kept
        var junk = mustOk(Edit.saveScenario([], "J", {w_perf: {v: 4, u: ""}, _d: {x: 1}, bad: {v: "x", u: ""}, bad2: 5, bad3: {v: 1}}))
        sameJson(junk.scenarios[0].v, {w_perf: {v: 4, u: ""}})
        var ld = mustOk(Edit.loadScenario(r4.scenarios, 0))
        sameJson(ld.inputs, weights(10, 0, 0))
        ld.inputs.w_perf.v = 1
        compare(r4.scenarios[0].v.w_perf.v, 10, "load returns a copy")
        compare(Edit.loadScenario(r4.scenarios, 3).reason, "unknown-scenario")
        compare(Edit.loadScenario(r4.scenarios, -1).reason, "unknown-scenario")
        compare(Edit.loadScenario(r4.scenarios, 0.5).reason, "unknown-scenario")
        var del = mustOk(Edit.deleteScenario(r4.scenarios, 1))
        sameJson(del.scenarios.map(function (s) { return s.n }), ["Speed first", "Even"])
        compare(r4.scenarios.length, 3)
        compare(Edit.deleteScenario(r4.scenarios, 3).reason, "unknown-scenario")
        compare(Edit.deleteScenario(null, 0).reason, "unknown-scenario")
    }
    function test_scenarioResultsEqualSingleEvaluations() {
        var block = example(), d = mustOk(Edit.setCell({}, block, "laptops", "1", "price", "1700")).data
        var scn = mustOk(Edit.saveScenario([], "Speed", weights(10, 0, 0))).scenarios
        scn = mustOk(Edit.saveScenario(scn, "Price", weights(0, 0, 10))).scenarios
        scn = mustOk(Edit.saveScenario(scn, "Defaults", {})).scenarios
        var entry = Edit.compose({w_batt: {v: 6, u: ""}}, d, scn), plan = View.build(block, entry)
        var all = View.scenarioResults(plan, entry)
        compare(all.length, 4)
        sameJson(all.map(function (x) { return x.name }), ["Current", "Speed", "Price", "Defaults"])
        sameJson(all.map(function (x) { return x.index }), [-1, 0, 1, 2])
        sameJson(scores(plan, all[1].result), ["70.00", "90.00", "50.00"])
        sameJson(scores(plan, all[2].result), ["45.00", "15.00", "67.50"])
        sameJson(scores(plan, all[3].result), ["66.50", "64.50", "50.50"], "a scenario is an input set from the defaults, with the shared data edits")
        for (var i = 0; i < all.length; ++i)
            sameJson(snap(plan, all[i].result), snap(plan, Calc.evaluate(plan.model, all[i].values, null, null)), all[i].name)
        // Current follows the saved inputs (battery weight 6)
        compare(all[0].values.w_batt, 6)
        var st = View.restore(plan, entry)
        sameJson(snap(plan, all[0].result), snap(plan, Calc.evaluate(plan.model, st.values, null, null)))
        // a supplied current result is used as is
        var cur = Calc.evaluate(plan.model, st.values, null, null)
        verify(View.scenarioResults(plan, entry, cur)[0].result === cur)
        compare(View.scenarioResults(null, entry).length, 0)
    }
    function test_scenarioResultsCacheIsPerModelBuild() {
        var block = example(), scn = mustOk(Edit.saveScenario([], "Speed", weights(10, 0, 0))).scenarios
        var entry = Edit.compose({}, {}, scn), plan = View.build(block, entry)
        var first = View.scenarioResults(plan, entry)
        var slider = Edit.compose({w_perf: {v: 8, u: ""}}, {}, scn)
        var second = View.scenarioResults(plan, slider)
        verify(second[1].result === first[1].result, "a slider move re-uses the scenario result")
        verify(second[0].result !== first[0].result, "Current is recomputed")
        var changed = Edit.compose({}, {}, mustOk(Edit.saveScenario(scn, "Speed", weights(9, 0, 0))).scenarios)
        var third = View.scenarioResults(plan, changed)
        verify(third[1].result !== first[1].result, "a changed scenario is recomputed")
        compare(scoreText(plan, third[1].result, 0), "70.00")   // 9/0/0: speed 7 of 10 -> 70
        // a new data edit builds a new plan: nothing is shared
        var entry2 = Edit.compose({}, mustOk(Edit.setCell({}, block, "laptops", "0", "perf", "1")).data, scn)
        var plan2 = View.build(block, entry2)
        verify(View.scenarioResults(plan2, entry2)[1].result !== first[1].result)
    }

    // ---- bake ---------------------------------------------------------
    function test_bakeIsAStandaloneCopy() {
        var block = example(), d = mustOk(Edit.setCell({}, block, "laptops", "1", "price", "1700")).data
        d = mustOk(Edit.removeRow(d, block, "laptops", "2")).data
        d = mustOk(Edit.addRow(d, block, "laptops")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "name", "Fresh")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "perf", "6")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "batt", "10")).data
        d = mustOk(Edit.setCell(d, block, "laptops", "n1", "price", "900")).data
        var scn = mustOk(Edit.saveScenario([], "Speed", weights(10, 0, 0))).scenarios
        scn = mustOk(Edit.saveScenario(scn, "Defaults", {})).scenarios
        scn = mustOk(Edit.saveScenario(scn, "Mixed", {w_batt: {v: 1, u: ""}})).scenarios
        var entry = Edit.compose({w_perf: {v: 8, u: ""}, w_price: {v: 4, u: ""}}, d, scn)
        var before = block && JSON.stringify(block)
        var baked = Edit.bake(block, entry)
        compare(JSON.stringify(block), before, "source untouched")
        compare(baked.block.title, "Copy of Laptop score")
        sameJson(baked.block.tables[0].rows, [["Air 13", "7", "15", "1100", ""], ["Pro 14", "9", "11", "1700", ""], ["Fresh", "6", "10", "900", ""]])
        sameJson(baked.block.inputs.map(function (i) { return i.value }), [8, 3, 4])
        verify(baked.entry._d === undefined)
        // identical numbers: baked current == original current; every scenario carries over
        var a = View.run(block, entry), b = View.run(baked.block, baked.entry)
        compare(b.reset, false)
        compare(a.reset, false)
        sameJson(snap(a.plan, a.result), snap(b.plan, b.result))
        var sa = View.scenarioResults(a.plan, entry), sb = View.scenarioResults(b.plan, baked.entry)
        compare(sb.length, 4)
        for (var i = 0; i < sa.length; ++i) {
            compare(sb[i].name, sa[i].name)
            sameJson(snap(a.plan, sa[i].result), snap(b.plan, sb[i].result), sa[i].name)
        }
        compare(b.plan.edited.cells + b.plan.edited.rowsAdded + b.plan.edited.rowsRemoved, 0)
        // deep, plain JSON
        sameJson(clone(baked), baked)
        baked.block.tables[0].rows[0][0] = "X"
        baked.block.inputs[0].value = 0
        compare(block.tables[0].rows[0][0], "Air 13")
        compare(block.inputs[0].value, 5)
        // stale saved values fall back to the authored default; never clamp
        var stale = Edit.bake(block, {w_perf: {v: 99, u: ""}, w_batt: {v: 2, u: "kg"}, _d: {laptops: {e: {"9|perf": "1"}}}})
        sameJson(stale.block.inputs.map(function (i) { return i.value }), [5, 3, 2])
        sameJson(stale.block.tables, block.tables)
        compare(Edit.bake(5, {}), null)
    }
    function test_bakeTitleIsClamped() {
        var block = example()
        block.title = rep("t", 200)
        var t = Edit.bake(block, {}).block.title
        compare(t.length, 160)
        compare(t.slice(0, 8), "Copy of ")
        block.title = rep("t", 149) + "\ud83d\ude00\ud83d\ude00"
        t = Edit.bake(block, {}).block.title
        verify(t.length <= 160 && !/[\ud800-\udbff]$/.test(t), "no split surrogate")
        delete block.title
        compare(Edit.bake(block, {}).block.title, "Copy of calculation")
    }

    // ---- property test: random op sequences vs a from-scratch oracle ---
    function stripAscii(s) { return s.replace(/^[ \t\n\r\v\f]+|[ \t\n\r\v\f]+$/g, "") }
    function oracleBlock(block, rows) {
        var b = clone(block)
        b.tables[0].rows = rows.map(function (r) { return r.cells.slice() })
        return b
    }
    function oracleCellValid(kind, raw) {
        var s = stripAscii(raw)
        if (kind === "number") return engineClass(raw).code === null
        return s === "" || (s.length <= 64 && State.workspaceName(s) !== "")
    }
    function runSequence(seed, steps) {
        var rng = makeRng(seed), block = example(), cols = ["name", "perf", "batt", "price", "score"], kinds = ["text", "number", "number", "number", "formula"]
        var numbers = ["0", "1", "12.5", "1700", "-3", "  9 ", "", "1e3", ".5", "1,5", "abc", "1e999", "1.", "0x1", "\u00a05", "5 EUR", "650", "1100"]
        var texts = ["Zed", "", "  Air  ", rep("x", 64), rep("x", 65), "a\u0000b", "a\tb", "\ud800", "caf\u00e9", "Air 13"]
        var names = ["Base", "Speed first", "Cheap", "Fourth", " Trim ", rep("n", 33), "a\u0000b", ""]
        var data = {}, scn = [], inputs = {}
        var rows = block.tables[0].rows.map(function (r, i) { return {id: String(i), cells: r.slice()} })
        var counts = {set: 0, setBad: 0, add: 0, remove: 0, discard: 0, save: 0, load: 0, del: 0, refused: 0}
        for (var step = 0; step < steps; ++step) {
            var op = Math.floor(rng() * 12), tag = "seed " + seed + " step " + step + " op " + op
            if (op <= 4) {   // setCell
                var ci = Math.floor(rng() * 5), live = rows.map(function (r) { return r.id })
                var rid = rng() < 0.1 ? pick(rng, ["99", "n77", "x"]) : pick(rng, live)
                var text = ci === 0 ? pick(rng, texts) : pick(rng, numbers)
                var res = Edit.setCell(data, block, "laptops", rid, cols[ci], text)
                var rowAt = live.indexOf(rid)
                if (kinds[ci] === "formula") compare(res.reason, "formula-column", tag)
                else if (rowAt < 0) compare(res.reason, "unknown-row", tag)
                else if (!oracleCellValid(kinds[ci], text)) { compare(res.reason, "invalid", tag); counts.setBad++ }
                else {
                    verify(res.ok, tag + " " + JSON.stringify(res))
                    rows[rowAt].cells[ci] = stripAscii(text)
                    counts.set++
                }
                if (res.ok) data = res.data
                else sameJson(res.data, undefined, tag)
            } else if (op === 5) {   // addRow
                var add = Edit.addRow(data, block, "laptops")
                if (rows.length >= 40) { compare(add.reason, "max-rows", tag); counts.refused++ }
                else {
                    verify(add.ok, tag)
                    rows.push({id: add.rowId, cells: ["", "", "", "", ""]})
                    data = add.data; counts.add++
                }
            } else if (op === 6 || op === 7) {   // removeRow
                var rm = rows.length && rng() < 0.9 ? pick(rng, rows).id : "404"
                var rr = Edit.removeRow(data, block, "laptops", rm)
                var at = rows.map(function (r) { return r.id }).indexOf(rm)
                if (at < 0) compare(rr.reason, "unknown-row", tag)
                else { verify(rr.ok, tag); rows.splice(at, 1); data = rr.data; counts.remove++ }
            } else if (op === 8) {   // discard (rare)
                if (rng() < 0.3) {
                    data = Edit.discardEdits(data)
                    rows = block.tables[0].rows.map(function (r, i) { return {id: String(i), cells: r.slice()} })
                    counts.discard++
                }
            } else if (op === 9) {   // inputs move, scenario save
                var st = {}
                for (var wi = 0; wi < 3; ++wi) if (rng() < 0.6) st[["w_perf", "w_batt", "w_price"][wi]] = {v: Math.floor(rng() * 11), u: ""}
                if (rng() < 0.5) { inputs = st }
                else {
                    var nm = pick(rng, names), want = State.workspaceName(nm), sv = Edit.saveScenario(scn, nm, st)
                    if (!want || want.length > 32) compare(sv.reason, "bad-name", tag)
                    else {
                        var idx = scn.map(function (s) { return s.n }).indexOf(want)
                        if (idx < 0 && scn.length >= 3) compare(sv.reason, "full", tag)
                        else {
                            verify(sv.ok, tag)
                            if (idx < 0) scn = scn.concat([{n: want, v: clone(st)}]); else { scn = clone(scn); scn[idx] = {n: want, v: clone(st)} }
                            counts.save++
                        }
                        if (sv.ok) sameJson(sv.scenarios, scn, tag)
                    }
                }
            } else if (op === 10 && scn.length) {   // load
                var li = Math.floor(rng() * scn.length), ld = Edit.loadScenario(scn, li)
                verify(ld.ok, tag)
                sameJson(ld.inputs, scn[li].v, tag)
                inputs = ld.inputs; counts.load++
            } else if (op === 11 && scn.length && rng() < 0.5) {   // delete
                var di = Math.floor(rng() * scn.length), dl = Edit.deleteScenario(scn, di)
                verify(dl.ok, tag)
                scn = scn.filter(function (s, k) { return k !== di }); counts.del++
                sameJson(dl.scenarios, scn, tag)
            }

            // ---- invariants after every op
            var ap = Edit.applyData(block, data)
            verify(ap.ok && !ap.dropped, tag + " applyData " + JSON.stringify(ap.reason))
            sameJson(ap.block.tables[0].rows, rows.map(function (r) { return r.cells }), tag + " rows")
            sameJson(ap.rowIds.laptops, rows.map(function (r) { return r.id }), tag + " ids")
            sameJson(Edit.applyData(block, ap.data).data, ap.data, tag + " clean data is a fixed point")
            sameJson(ap.data, data, tag + " ops emit clean data")
            if (rows.length === 3 && ap.edited.cells + ap.edited.rowsAdded + ap.edited.rowsRemoved === 0)
                sameJson(ap.block, block, tag + " no edits = authored")
            var entry = Edit.compose(inputs, data, scn), cm = Edit.commit(inputs, data, scn)
            compare(cm.ok, Edit.sizeOf(entry) <= 10240, tag)
            sameJson(cm.entry, entry, tag)
            var run = View.run(block, entry)
            compare(run.reset, false, tag + " restore")
            verify(run.plan !== null, tag)
            var scratch = View.build(oracleBlock(block, rows))
            verify(scratch !== null, tag + " scratch")
            var values = run.current, expect = Calc.evaluate(scratch.model, values, null, null)
            sameJson(snap(run.plan, run.result), snap(scratch, expect), tag + " evaluation")
            sameJson(run.scenarios, scn, tag + " scenarios restore")
            var all = View.scenarioResults(run.plan, entry, run.result)
            compare(all.length, scn.length + 1, tag)
            for (var si = 0; si < scn.length; ++si) {
                var sv2 = View.defaults(scratch)
                for (var key in scn[si].v) sv2[key] = scn[si].v[key].v
                sameJson(snap(run.plan, all[si + 1].result), snap(scratch, Calc.evaluate(scratch.model, sv2, null, null)), tag + " scenario " + si)
            }
        }
        return counts
    }
    function test_randomOperationSequencesMatchTheOracle() {
        var total = {set: 0, setBad: 0, add: 0, remove: 0, discard: 0, save: 0, load: 0, del: 0, refused: 0}
        var seeds = [1, 2, 3, 20261009, 77]
        for (var i = 0; i < seeds.length; ++i) {
            var c = runSequence(seeds[i], 220)
            for (var k in c) total[k] += c[k]
        }
        console.log("property ops: " + JSON.stringify(total))
        verify(total.set > 100 && total.setBad > 20 && total.add > 20 && total.remove > 20 && total.save > 10 && total.load > 5 && total.del > 3 && total.discard > 3,
               JSON.stringify(total))
    }
    function test_randomEditRevertAndAddRemoveRoundTrips() {
        var rng = makeRng(424242), block = example(), data = {}
        for (var step = 0; step < 150; ++step) {
            var live = Edit.applyData(block, data), ids = live.rowIds.laptops
            var kind = Math.floor(rng() * 3), before = JSON.stringify(data)
            if (kind === 0 && ids.length) {   // edit then revert to the previous effective text
                var rid = pick(rng, ids), ci = 1 + Math.floor(rng() * 3), col = ["name", "perf", "batt", "price"][ci]
                var prev = live.block.tables[0].rows[ids.indexOf(rid)][ci]
                var edit = Edit.setCell(data, block, "laptops", rid, col, pick(rng, ["1", "22", "3.5", "", "700"]))
                if (!edit.ok) continue
                var back = mustOk(Edit.setCell(edit.data, block, "laptops", rid, col, prev))
                compare(JSON.stringify(back.data), before, "revert " + step)
                data = edit.data
            } else if (kind === 1) {   // add then remove: same effective spec, same results
                var add = Edit.addRow(data, block, "laptops")
                if (!add.ok) continue
                var gone = mustOk(Edit.removeRow(add.data, block, "laptops", add.rowId))
                sameJson(Edit.applyData(block, gone.data).block, live.block, "add/remove " + step)
                sameJson(Edit.applyData(block, gone.data).rowIds, live.rowIds)
                var hadAdded = (data.laptops && data.laptops.a) ? data.laptops.a.length : 0
                if (hadAdded === 0) compare(JSON.stringify(gone.data), before, "exact data when no row was added before")
                data = add.data
            } else if (kind === 2 && ids.length && rng() < 0.5) {
                data = mustOk(Edit.removeRow(data, block, "laptops", pick(rng, ids))).data
            }
        }
    }

    // ---- worst case latency -------------------------------------------
    function percentile(sorted, p) { return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] }
    function test_worstCaseCompileAndEvaluateLatency() {
        var block = wide(40, 12), entry = Edit.compose({}, mustOk(Edit.setCell({}, block, "t", "3", "x", "9")).data, [])
        var plan = View.build(block, entry)
        verify(plan !== null)
        compare(plan.model.nodes.length, 300)
        var engineMs = [], viewMs = [], i, t0, r
        var spec = {inputs: block.inputs.map(function (n) { return {id: n.id, unit: "", value: n.value, min: n.min, max: n.max} }),
                    tables: block.tables, cells: block.cells.map(function (c) { return {id: c.id, expression: c.expression, unit: "", decimals: 2} })}
        var values = View.defaults(plan)
        var wallStart = Date.now()
        for (i = 0; i < 200; ++i) {
            t0 = Date.now()
            r = Calc.evaluate(Calc.compileSpec(spec), values, null, null)
            engineMs.push(Date.now() - t0)
        }
        var engineWall = Date.now() - wallStart
        wallStart = Date.now()
        for (i = 0; i < 200; ++i) {
            t0 = Date.now()
            var run = View.run(block, entry)
            viewMs.push(Date.now() - t0)
            verify(run.result !== null)
        }
        var viewWall = Date.now() - wallStart
        engineMs.sort(function (a, b) { return a - b }); viewMs.sort(function (a, b) { return a - b })
        console.log("latency 300 nodes x 40 rows, 200 loops (Date.now ms): compile+evaluate p50 " + percentile(engineMs, 0.5) + " p95 " + percentile(engineMs, 0.95)
                    + " mean " + (engineWall / 200).toFixed(2) + "; View.run (copy+applyData+build+restore+evaluate) p50 "
                    + percentile(viewMs, 0.5) + " p95 " + percentile(viewMs, 0.95) + " mean " + (viewWall / 200).toFixed(2))
        verify(percentile(viewMs, 0.95) < 250, "a generous regression bound, not the 16 ms goal")
        // a slider move needs only evaluate on the existing plan
        wallStart = Date.now()
        for (i = 0; i < 200; ++i) { values.i1 = i % 100; r = Calc.evaluate(plan.model, values, null, r) }
        console.log("latency evaluate only (incremental, 200 slider moves): mean " + ((Date.now() - wallStart) / 200).toFixed(2) + " ms")
    }
}
