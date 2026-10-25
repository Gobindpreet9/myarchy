import QtQuick
import QtTest
import "../AiCalc.js" as Calc
import "CalcGolden.js" as Golden
import "CalcFuzz.js" as Fuzz

// Typed computation runtime (JS engine). The reviewed golden table
// (CalcGolden.js) is the ground truth; the Python twin ai_calc.py is checked
// against the same table. Everything here is pure JS: no file, process or
// provider. A data row's tag names the failing golden case.
TestCase {
    name: "AiCalc"

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
    function clone(v) { return JSON.parse(JSON.stringify(v)) }
    function compileOrNull(spec) {
        try { return {model: Calc.compileSpec(spec), rej: null} } catch (e) { return {model: null, rej: e} }
    }
    function rejectOf(spec) { return compileOrNull(spec).rej }
    function one(expr, extra) {
        var s = {inputs: [], tables: [], cells: [{id: "r", expression: expr, unit: "", decimals: 2}]}
        for (var k in extra) s[k] = extra[k]
        return s
    }
    function textOf(expr, inputs, extra) {
        var m = Calc.compileSpec(one(expr, extra))
        return Calc.formatCell(m, Calc.evaluate(m, inputs || {}, null, null), "r")
    }
    function codeOf(model, result, id) { var e = result.nodes[id].err; return e ? e.code : null }
    // everything observable about a result, as one comparable string
    function snap(result) {
        var ids = result.order, parts = []
        for (var i = 0; i < ids.length; ++i) {
            var n = result.nodes[ids[i]]
            parts.push(JSON.stringify([ids[i], n.value, n.unit, n.err ? [n.err.code, n.err.msg, n.err.node] : null,
                                       n.warn, n.steps, n.from, n.deps]))
        }
        return result.steps + "|" + parts.join("\n")
    }
    function numericPrefix(text) {
        var m = /^(-?[0-9]+(?:\.[0-9]+)?)(.*)$/.exec(text)
        return m ? {n: parseFloat(m[1]), rest: m[2]} : {n: NaN, rest: text}
    }
    // Runs one golden case against a spec; returns the list of problems.
    function goldenProblems(c, spec) {
        var bad = [], out = compileOrNull(spec)
        if (c.compile === "reject") {
            if (out.rej === null) bad.push("expected reject '" + c.why + "' but it compiled")
            else if (out.rej.why !== c.why) bad.push("reject '" + out.rej.why + "' != '" + c.why + "' (" + out.rej.msg + ")")
            return bad
        }
        if (out.rej !== null) { bad.push("unexpected reject '" + out.rej.why + "': " + out.rej.msg); return bad }
        var res = Calc.evaluate(out.model, c.inputs, c.env === undefined ? null : c.env, null)
        for (var id in c.expect) {
            var want = c.expect[id], got = Calc.formatCell(out.model, res, id), code = codeOf(out.model, res, id)
            if (code !== want.err) bad.push(id + ": error " + code + " != " + want.err)
            if (want.approx !== undefined) {
                var a = numericPrefix(got), b = numericPrefix(want.text)
                if (!(Math.abs(a.n - b.n) <= want.approx * Math.max(Math.abs(a.n), Math.abs(b.n))) || a.rest !== b.rest)
                    bad.push(id + ": '" + got + "' not within " + want.approx + " of '" + want.text + "'")
            } else if (got !== want.text) bad.push(id + ": '" + got + "' != '" + want.text + "'")
        }
        return bad
    }
    function shuffled(list, rng) {
        var a = list.slice()
        for (var i = a.length - 1; i > 0; --i) { var j = Math.floor(rng() * (i + 1)); var t = a[i]; a[i] = a[j]; a[j] = t }
        return a
    }
    function caseByTag(tag) {
        for (var i = 0; i < Golden.CASES.length; ++i) if (Golden.CASES[i].tag === tag) return Golden.CASES[i]
        return null
    }

    // ---- the golden table ---------------------------------------------
    function test_golden_data() {
        return Golden.CASES.map(function (c) { return {tag: c.tag, c: c} })
    }
    function test_golden(data) {
        var bad = goldenProblems(data.c, data.c.spec)
        verify(bad.length === 0, data.c.tag + ": " + bad.join(" | "))
    }
    function test_goldenTableShape() {
        compare(Golden.CASES.length, 328)
        var seen = {}
        for (var i = 0; i < Golden.CASES.length; ++i) {
            verify(!seen[Golden.CASES[i].tag], "duplicate tag " + Golden.CASES[i].tag)
            seen[Golden.CASES[i].tag] = true
        }
    }

    // ---- order independence --------------------------------------------
    function test_declarationOrderDoesNotMatter_data() {
        var rows = []
        Golden.CASES.forEach(function (c, i) {
            if (c.compile === "ok" && c.group !== "limits") rows.push({tag: c.tag, c: c, seed: 1000 + i})
        })
        return rows
    }
    function test_declarationOrderDoesNotMatter(data) {
        var rng = makeRng(data.seed), spec = clone(data.c.spec)
        spec.inputs = shuffled(spec.inputs, rng)
        spec.tables = shuffled(spec.tables, rng)
        spec.cells = shuffled(spec.cells, rng)
        var bad = goldenProblems(data.c, spec)
        verify(bad.length === 0, data.c.tag + " (shuffled): " + bad.join(" | "))
    }
    function test_kahnOrderUsesDeclarationOrderForTies() {
        var m = Calc.compileSpec({inputs: [{id: "b", unit: "", value: 1}, {id: "a", unit: "", value: 2}], tables: [], cells: [
            {id: "z", expression: "a+b", unit: "", decimals: 0}, {id: "y", expression: "b", unit: "", decimals: 0},
            {id: "x", expression: "z+y", unit: "", decimals: 0}]})
        compare(m.orderIds.join(","), "b,a,z,y,x")
        var r = Calc.evaluate(m, {}, null, null)
        compare(r.order.join(","), "b,a,z,y,x")
        // a cell declared first that needs a later one waits for it
        var m2 = Calc.compileSpec({inputs: [], tables: [], cells: [
            {id: "p", expression: "q+1", unit: "", decimals: 0}, {id: "q", expression: "1", unit: "", decimals: 0}]})
        compare(m2.orderIds.join(","), "q,p")
    }
    function test_cycleReportsItsPath() {
        var e = rejectOf({inputs: [], tables: [], cells: [{id: "p", expression: "q+1", unit: "", decimals: 0},
            {id: "q", expression: "r", unit: "", decimals: 0}, {id: "r", expression: "p", unit: "", decimals: 0}]})
        compare(e.why, "cycle")
        compare(e.msg, "Circular reference: p -> q -> r -> p.")
    }

    // ---- incremental == full --------------------------------------------
    function randomValue(rng, current) {
        var r = rng()
        if (r < 0.15) return null
        if (r < 0.3) return current
        return Math.round((rng() * 40 - 8) * 100) / 100
    }
    // Applies `edits` random single-input edits; returns the first mismatch or "".
    function incrementalMismatch(spec, env, seed, edits) {
        var model = Calc.compileSpec(spec), rng = makeRng(seed), vals = {}, i
        for (i = 0; i < spec.inputs.length; ++i) vals[spec.inputs[i].id] = spec.inputs[i].value
        var prev = Calc.evaluate(model, vals, env, null)
        if (spec.inputs.length === 0) return ""
        for (var step = 0; step < edits; ++step) {
            var id = spec.inputs[Math.floor(rng() * spec.inputs.length)].id
            vals[id] = randomValue(rng, vals[id])
            var useEnv = env
            if (env && rng() < 0.2) useEnv = {stats: clone(env.stats)}   // equal but fresh stats
            var inc = Calc.evaluate(model, clone(vals), useEnv, prev)
            var full = Calc.evaluate(model, clone(vals), useEnv, null)
            if (snap(inc) !== snap(full)) return "step " + step + " after editing " + id + "=" + vals[id]
            if (inc.stats.rowReads > full.stats.rowReads) return "incremental read more rows than full at step " + step
            prev = inc
        }
        return ""
    }
    function test_incrementalEqualsFull_data() {
        var rows = []
        Golden.CASES.forEach(function (c, i) {
            if (c.compile === "ok" && c.spec.inputs.length > 0) rows.push({tag: c.tag, c: c, seed: 77 + i})
        })
        return rows
    }
    function test_incrementalEqualsFull(data) {
        var msg = incrementalMismatch(data.c.spec, data.c.env === undefined ? null : data.c.env, data.seed, 12)
        compare(msg, "", data.c.tag)
    }
    function test_incrementalEqualsFullOnTheBigSpec() {
        compare(incrementalMismatch(bigSpec(), null, 4242, 250), "")
        compare(incrementalMismatch(bigSpec(), null, 99, 250), "")
    }
    function test_incrementalFollowsChangingSourceStats() {
        var spec = {inputs: [{id: "k", unit: "", value: 2}], tables: [], cells: [
            {id: "sv", expression: "colstat(1,sum)*k", unit: "", decimals: 2}, {id: "o", expression: "k+1", unit: "", decimals: 2}]}
        var model = Calc.compileSpec(spec)
        var e1 = {stats: [{count: 3, empty: 0, min: 1, max: 5, sum: 9, mean: 3}]}
        var e2 = {stats: [{count: 3, empty: 0, min: 1, max: 5, sum: 30, mean: 10}]}
        var r1 = Calc.evaluate(model, {k: 2}, e1, null)
        var r2 = Calc.evaluate(model, {k: 2}, e2, r1)
        compare(Calc.formatCell(model, r1, "sv"), "18.00")
        compare(Calc.formatCell(model, r2, "sv"), "60.00")
        compare(snap(r2), snap(Calc.evaluate(model, {k: 2}, e2, null)))
        var r3 = Calc.evaluate(model, {k: 2}, null, r2)
        compare(codeOf(model, r3, "sv"), "SRC")
    }
    function test_incrementalReusesUnchangedNodesAndStopsPropagation() {
        var m = Calc.compileSpec({inputs: [{id: "a", unit: "", value: 1}, {id: "b", unit: "", value: 1}], tables: [], cells: [
            {id: "x", expression: "a*0", unit: "", decimals: 0}, {id: "y", expression: "x+1", unit: "", decimals: 0},
            {id: "z", expression: "b+1", unit: "", decimals: 0}]})
        var r1 = Calc.evaluate(m, {a: 1, b: 1}, null, null)
        var r2 = Calc.evaluate(m, {a: 5, b: 1}, null, r1)
        // a changed, x recomputed to the same 0, so y is not recomputed and z is reused
        compare(r2.stats.evaluated, 3)   // inputs a, b and x
        verify(r2.nodes.y === r1.nodes.y, "y reused")
        verify(r2.nodes.z === r1.nodes.z, "z reused")
        verify(r2.nodes.x !== r1.nodes.x, "x was recomputed")
    }
    function test_incrementalFallsBackToFullAcrossTheStepBudget() {
        var base = clone(caseByTag("limits-pass-budget-50000-steps-ok").spec)
        base.inputs = [{id: "x", unit: "", value: 0}]
        // x>0 selects the 81-step variant that crosses the budget
        var fin = base.cells[0]
        fin.expression = "if(x>0," + caseByTag("limits-pass-budget-50001-steps-limit-on-last-cell").spec.cells[0].expression + ",0)"
        var m = Calc.compileSpec(base)
        var cheap = Calc.evaluate(m, {x: 0}, null, null)
        compare(codeOf(m, cheap, "fin"), null)
        var hot = Calc.evaluate(m, {x: 1}, null, cheap)
        compare(codeOf(m, hot, "fin"), "LIMIT")
        compare(snap(hot), snap(Calc.evaluate(m, {x: 1}, null, null)))
        var back = Calc.evaluate(m, {x: 0}, null, hot)
        compare(snap(back), snap(cheap))
        compare(codeOf(m, back, "fin"), null)
    }
    function test_incrementalIgnoresAForeignPrev() {
        var a = Calc.compileSpec(one("1+1")), b = Calc.compileSpec(one("2+2"))
        var ra = Calc.evaluate(a, {}, null, null)
        compare(Calc.formatCell(b, Calc.evaluate(b, {}, null, ra), "r"), "4.00")
    }

    // ---- purity ---------------------------------------------------------
    function test_twoModelsInterleavedDoNotInteract() {
        var a = caseByTag("realistic-loan-one-year"), b = caseByTag("realistic-laptop-score-balanced")
        var ma = Calc.compileSpec(a.spec), mb = Calc.compileSpec(b.spec)
        var soloA = snap(Calc.evaluate(ma, a.inputs, null, null)), soloB = snap(Calc.evaluate(mb, b.inputs, null, null))
        var pa = null, pb = null
        for (var i = 0; i < 6; ++i) {
            pa = Calc.evaluate(ma, a.inputs, null, pa)
            pb = Calc.evaluate(mb, b.inputs, null, pb)
            compare(snap(pa), soloA)
            compare(snap(pb), soloB)
            Calc.evaluate(mb, {perf: i}, null, pb)   // noise on the other model must not leak
        }
    }
    function test_inputsEnvPrevAndModelAreNotMutated() {
        var spec = bigSpec(), model = Calc.compileSpec(spec)
        var inputs = {rate: 70, hours: null, n: 3}, env = {stats: [{count: 1, empty: 0, min: 1, max: 1, sum: 1, mean: 1}]}
        var prev = Calc.evaluate(model, {}, env, null)
        var before = JSON.stringify([inputs, env, prev.nodes, prev.steps, prev.order, model])
        Object.freeze(inputs); Object.freeze(env); Object.freeze(env.stats); Object.freeze(env.stats[0])
        Calc.evaluate(model, inputs, env, prev)
        Calc.evaluate(model, inputs, env, null)
        compare(JSON.stringify([inputs, env, prev.nodes, prev.steps, prev.order, model]), before)
        var specBefore = JSON.stringify(spec)
        Calc.compileSpec(spec)
        compare(JSON.stringify(spec), specBefore)
    }
    function test_evaluateIsDeterministic() {
        var model = Calc.compileSpec(bigSpec())
        var a = snap(Calc.evaluate(model, {rate: 61}, null, null)), b = snap(Calc.evaluate(model, {rate: 61}, null, null))
        compare(a, b)
    }
    function test_importerCannotChangeEngineLimitsThroughTheExports() {
        var ok80 = caseByTag("limits-nodes-80-ok").spec
        try { Calc.maxNodes = 1; Calc.maxExpressionChars = 5; Calc.maxPassSteps = 1 } catch (e) { /* read-only is fine too */ }
        verify(compileOrNull(ok80).rej === null, "the engine kept its own limits")
        verify(compileOrNull(one("1+" + new Array(60).join(" ") + "1")).rej === null)
    }

    // ---- limits at the boundary and boundary + 1 -----------------------
    function test_exportedLimitConstants() {
        compare(Calc.maxExpressionChars, 200); compare(Calc.maxTokens, 120); compare(Calc.maxNodes, 80)
        compare(Calc.maxDepth, 32); compare(Calc.maxCallArgs, 6); compare(Calc.maxInputs, 12)
        compare(Calc.maxCells, 24); compare(Calc.maxTables, 2); compare(Calc.maxColumns, 12)
        compare(Calc.maxRows, 40); compare(Calc.maxGraphNodes, 300); compare(Calc.maxPassSteps, 50000)
        compare(Calc.maxCellSteps, 5000)
    }
    function pad(n) { return new Array(n + 1).join(" ") }
    function wrapped(core, k) { return new Array(k + 1).join("(") + core + new Array(k + 1).join(")") }
    function nested(fn, depth) { var s = "1"; for (var i = 1; i < depth; ++i) s = fn + "(" + s + ")"; return s }
    function numbered(prefix, n) { var l = []; for (var i = 1; i <= n; ++i) l.push(prefix + i); return l }
    function test_expressionLength() {
        var ok = "1+" + pad(197) + "1", over = "1+" + pad(198) + "1"
        compare(ok.length, 200); compare(over.length, 201)
        compare(rejectOf(one(ok)), null)
        compare(rejectOf(one(over)).why, "length")
        compare(rejectOf(one(pad(201))).why, "length")   // raw count, no trim
        compare(rejectOf(one(pad(200))).why, "empty")
    }
    function test_tokenCount() {
        compare(rejectOf(one(wrapped("-1", 59))), null)               // 2 + 118 = 120 tokens
        compare(rejectOf(one(wrapped("1", 60))).why, "tokens")        // 121
        compare(rejectOf(one(wrapped("-1", 60))).why, "tokens")       // 122
        compare(rejectOf(one(wrapped("1", 59))), null)                // 119
    }
    function test_nodeCount() {
        var plus = function (k, lead) { var l = []; for (var i = 0; i < k; ++i) l.push(i === 0 && lead ? "-1" : "1"); return "(" + l.join("+") + ")" }
        compare(rejectOf(one(plus(20, true) + "+" + plus(20, false))), null)       // 40 + 39 + root = 80
        compare(rejectOf(one(plus(20, false) + "+" + plus(21, false))).why, "nodes")   // 81
    }
    function test_depth() {
        compare(rejectOf(one(nested("abs", 32))), null)           // depth 32
        compare(rejectOf(one(nested("abs", 33))).why, "depth")
        compare(rejectOf(one(wrapped(nested("abs", 32), 10))), null)   // parentheses add no depth
        // a long unary chain hits the depth limit, not the call stack
        compare(rejectOf(one(new Array(40).join("-") + "1")).why, "depth")
    }
    function test_callArguments() {
        compare(rejectOf(one("max(1,2,3,4,5,6)")), null)
        compare(rejectOf(one("max(1,2,3,4,5,6,7)")).why, "args")
        compare(rejectOf(one("sum(1,2,3,4,5,6)")), null)
        compare(rejectOf(one("sum(1,2,3,4,5,6,7)")).why, "args")
        compare(rejectOf(one("abs(1,2)")).why, "arity")
        compare(rejectOf(one("colstat(1,sum,3)")).why, "arity")
    }
    function sizedSpec(inputs, cells, tables, columns, rows) {
        var s = {inputs: [], tables: [], cells: []}, i, j, r
        for (i = 1; i <= inputs; ++i) s.inputs.push({id: "i" + i, unit: "", value: 1})
        for (i = 1; i <= cells; ++i) s.cells.push({id: "c" + i, expression: "1", unit: "", decimals: 0})
        for (i = 1; i <= tables; ++i) {
            var cols = [], rowsList = []
            for (j = 1; j <= columns; ++j) cols.push({id: "k" + j, kind: "number", unit: "", expression: ""})
            for (r = 0; r < rows; ++r) { var row = []; for (j = 0; j < columns; ++j) row.push("1"); rowsList.push(row) }
            s.tables.push({id: "t" + i, columns: cols, rows: rowsList})
        }
        return s
    }
    function test_specSizes() {
        compare(rejectOf(sizedSpec(12, 24, 2, 12, 40)), null)
        compare(rejectOf(sizedSpec(13, 1, 0, 0, 0)).why, "limit-inputs")
        compare(rejectOf(sizedSpec(0, 25, 0, 0, 0)).why, "limit-cells")
        compare(rejectOf(sizedSpec(0, 1, 3, 1, 1)).why, "limit-tables")
        compare(rejectOf(sizedSpec(0, 1, 1, 13, 1)).why, "limit-columns")
        compare(rejectOf(sizedSpec(0, 1, 1, 1, 41)).why, "limit-rows")
        compare(rejectOf(sizedSpec(0, 1, 1, 1, 40)), null)
    }
    function graphSpec(secondRows) {
        var s = sizedSpec(12, 24, 0, 0, 0), i, r
        function table(id, formulas, rows) {
            var cols = [{id: "n", kind: "number", unit: "", expression: ""}], list = []
            for (i = 1; i <= formulas; ++i) cols.push({id: "f" + i, kind: "formula", unit: "", expression: "n"})
            for (r = 0; r < rows; ++r) { var row = ["1"]; for (i = 0; i < formulas; ++i) row.push(""); list.push(row) }
            return {id: id, columns: cols, rows: list}
        }
        s.tables = [table("t1", 6, 40), table("t2", 1, secondRows)]
        return s
    }
    function test_graphNodes() {
        compare(rejectOf(graphSpec(24)), null)                     // 12 + 24 + 240 + 24 = 300
        compare(rejectOf(graphSpec(25)).why, "limit-graph")        // 301
    }
    function test_passBudgetBoundary() {
        var ok = caseByTag("limits-pass-budget-50000-steps-ok").spec, over = caseByTag("limits-pass-budget-50001-steps-limit-on-last-cell").spec
        var mo = Calc.compileSpec(ok), ro = Calc.evaluate(mo, {}, null, null)
        compare(ro.steps, 50000); compare(codeOf(mo, ro, "fin"), null)
        var mv = Calc.compileSpec(over), rv = Calc.evaluate(mv, {}, null, null)
        compare(rv.steps, 50000); compare(codeOf(mv, rv, "fin"), "LIMIT")
        compare(rv.nodes.fin.err.node, "fin")
    }
    function test_everythingAfterTheFirstLimitIsLimit() {
        var s = clone(caseByTag("limits-pass-budget-50001-steps-limit-on-last-cell").spec)
        s.cells.push({id: "after", expression: "1", unit: "", decimals: 0})
        s.cells.push({id: "guarded", expression: "iferror(fin,7)", unit: "", decimals: 0})
        var m = Calc.compileSpec(s), r = Calc.evaluate(m, {}, null, null)
        compare(codeOf(m, r, "fin"), "LIMIT")
        compare(codeOf(m, r, "after"), "LIMIT")
        compare(codeOf(m, r, "guarded"), "LIMIT")   // LIMIT is not catchable
    }

    // ---- step accounting ------------------------------------------------
    function stepsOf(expr, extra, inputs) {
        var m = Calc.compileSpec(one(expr, extra)), r = Calc.evaluate(m, inputs || {}, null, null)
        return r.steps
    }
    function test_stepAccounting() {
        var t3 = {tables: [{id: "t", columns: [{id: "a", kind: "number", unit: "", expression: ""}], rows: [["1"], ["2"], ["3"]]}]}
        compare(stepsOf("1+2"), 3)
        compare(stepsOf("-1"), 2)
        compare(stepsOf("(1+2)*3"), 5)
        compare(stepsOf("sum(t.a)", t3), 1 + 1 + 3)                         // call + (1 + rows)
        compare(stepsOf("sumproduct(t.a,t.a)", t3), 1 + 4 + 4)
        compare(stepsOf("if(1<2,5,1/0)"), 1 + 3 + 1)                        // call, cond (3), taken literal; dead branch free
        compare(stepsOf("if(2<1,5,1/0)"), 1 + 3 + 3)
        compare(stepsOf("iferror(5,1/0)"), 2)                               // call + a; b never evaluated
        compare(stepsOf("iferror(1/0,7)"), 1 + 3 + 1)                       // call, 1/0 (3), then b
        compare(stepsOf("to(5[kg],[g])"), 3)                                // call, literal, [unit]
        compare(stepsOf("colstat(1,sum)"), 3)                               // call, n, stat word
        compare(stepsOf("x+1", {inputs: [{id: "x", unit: "", value: 1}]}), 3)   // inputs cost 0, the reference costs 1
        compare(stepsOf("5[kg]+0[g]"), 3)
        // a formula-column instance costs its formula's steps and counts against the pass
        var col = {tables: [{id: "t", columns: [{id: "a", kind: "number", unit: "", expression: ""},
            {id: "f", kind: "formula", unit: "", expression: "a*2"}], rows: [["1", ""], ["2", ""]]}]}
        compare(stepsOf("1", col), 1 + 2 * 3)
        var m = Calc.compileSpec(one("sum(t.f)", col)), r = Calc.evaluate(m, {}, null, null)
        compare(r.nodes["t.f#1"].steps, 3)
        compare(r.nodes.r.steps, 1 + 1 + 2)
        compare(r.steps, 3 + 3 + 4)
        compare(r.stats.rowReads, 2)
    }

    // ---- display ---------------------------------------------------------
    function test_v4NumericRoundTripsMatchTheGoldenRules() {
        compare((1.005).toPrecision(15), "1.00500000000000")
        compare((2.675).toPrecision(15), "2.67500000000000")
        compare((0.1 + 0.2).toPrecision(15), "0.300000000000000")
        compare(Number((0.1 + 0.2).toPrecision(15)), 0.3)
        compare((-1.005).toPrecision(15), "-1.00500000000000")
        compare((1e22).toPrecision(15), "1.00000000000000e+22")
        compare((123456789012345678).toPrecision(15), "1.23456789012346e+17")
        compare((1e-7).toPrecision(15), "1.00000000000000e-7")
        compare((100 * 1.1).toPrecision(15), "110.000000000000")
        compare(Math.pow(10, 21), 1e21)
        compare(Math.pow(10, 308), 1e308)
        compare(Math.pow(2, 0.5), Math.SQRT2)
        // the engine itself
        compare(textOf("1.005"), "1.01"); compare(textOf("-1.005"), "-1.01"); compare(textOf("2.675"), "2.68")
        compare(textOf("0.1+0.2"), "0.30"); compare(textOf("10^22"), "10000000000000000000000.00")
        compare(textOf("123456789012345678"), "123456789012346000.00")
        compare(textOf("0*-1"), "0.00"); compare(textOf("-0.004"), "0.00")
        compare(textOf("1/10000000"), "0.00")
    }
    function test_formatBooleansAndUnitsAndErrors() {
        compare(textOf("1<2"), "true"); compare(textOf("1>2"), "false")
        compare(textOf("1/0"), "—")
        compare(textOf("5[kg]"), "5.00 kg"); compare(textOf("2[kW]*3[h]"), "6.00 kW*h")
        compare(textOf("1/(4[s])"), "0.25 1/s")
        var m = Calc.compileSpec({inputs: [], tables: [], cells: [{id: "r", expression: "123456.789", unit: "", decimals: 10}]})
        compare(Calc.formatCell(m, Calc.evaluate(m, {}, null, null), "r"), "123456.7890000000")
        compare(Calc.formatCell(m, Calc.evaluate(m, {}, null, null), "missing"), "")
    }
    function test_roundFunctionMatchesDisplayRounding() {
        compare(textOf("round(1.005,2)"), "1.01"); compare(textOf("round(-2.5,0)"), "-3.00")
        compare(textOf("round(1234.5678,2)"), "1234.57")
        compare(codeOfExpr("round(1.5,-1)"), "DOMAIN")      // OQ8: places must be a whole 0..10
        compare(codeOfExpr("round(1.5,0.5)"), "DOMAIN")
        compare(codeOfExpr("round(1.5,11)"), "DOMAIN")
        compare(codeOfExpr("round(1.5,2[kg])"), "UNIT")
        compare(textOf("floor(0.1*3*10)"), "3.00")          // OQ9: raw doubles, no clean
        compare(textOf("ceil(0.1*3*10)"), "4.00")
    }
    function codeOfExpr(expr, inputs, extra) {
        var m = Calc.compileSpec(one(expr, extra)), r = Calc.evaluate(m, inputs || {}, null, null)
        return codeOf(m, r, "r")
    }
    function test_decisionsOnOpenQuestions() {
        compare(codeOfExpr("5[kg]>0"), "UNIT")                         // OQ6: only +/- take the literal 0
        compare(textOf("0*5[kg]"), "0.00 kg")
        compare(textOf("(3[m])^2"), "9.00 m^2")                        // OQ7: whole powers of units
        compare(textOf("sqrt(9[m^2])"), "3.00 m")
        compare(codeOfExpr("sqrt(9[m])"), "UNIT")
        compare(codeOfExpr("2[m]^0.5"), "UNIT")
        compare(rejectOf(one("5[kg^10]")).why, "bad-unit")
        compare(rejectOf(one("5[ kg]")).why, "bad-unit")               // OQ16
        compare(rejectOf(one("5 [kg]")).why, "unit-position")
        compare(textOf("clamp(5,10,0)"), "10.00")                      // OQ18: lo wins, like AiFormula
        compare(textOf("(1<2)==(2<3)"), "true")
        compare(codeOfExpr("(1<2)<(2<3)"), "TYPE")
        compare(textOf("min(2,2)"), "2.00")
        compare(rejectOf(one("min(1)")).why, "arity")
        // OQ15: input min/max are metadata, not enforced
        compare(textOf("x", {x: 500}, {inputs: [{id: "x", unit: "", value: 1, min: 0, max: 10}]}), "500.00")
        compare(textOf("x", {}, {inputs: [{id: "x", unit: "", value: 1, min: 0, max: 10}]}), "1.00")
        // OQ14: a formula column with no unit keeps each row's own unit
        var col = {tables: [{id: "t", columns: [{id: "a", kind: "number", unit: "kg", expression: ""},
            {id: "f", kind: "formula", unit: "", expression: "a*2"}], rows: [["1", ""], ["2", ""]]}]}
        compare(textOf("sum(t.f)", {}, col), "6.00 kg")
        // OQ11: parentheses add no depth; OQ10: raw length
        compare(rejectOf(one(wrapped("1", 50))), null)
    }

    // ---- hostile input -----------------------------------------------------
    function test_nonAsciiNeverCompilesInAnExpression() {
        var bad = ["٣", "１", "²", "⁴", "−", " ", "​", "é", "😀", "а", "–", "\ufeff"]
        for (var i = 0; i < bad.length; ++i) {
            compare(rejectOf(one("1+" + bad[i])).why, "non-ascii", "U+" + bad[i].charCodeAt(0).toString(16))
            compare(rejectOf(one(bad[i] + "1")).why, "non-ascii")
            compare(rejectOf(one("1+1[kg" + bad[i] + "]")).why, "non-ascii")
            compare(rejectOf({inputs: [{id: "a" + bad[i], unit: "", value: 1}], tables: [], cells: []}).why, "bad-id")
            compare(rejectOf({inputs: [{id: "a", unit: "kg" + bad[i], value: 1}], tables: [], cells: []}).why, "bad-unit")
        }
        // a Unicode digit inside a table cell is not a number either
        var t = {tables: [{id: "t", columns: [{id: "a", kind: "number", unit: "", expression: ""}], rows: [["٣"], ["１"]]}]}
        compare(codeOfExpr("sum(t.a)", {}, t), "TYPE")
    }
    function test_literalForms() {
        var good = ["0", "007", "1.50", "123456789012345678901234567890"], badSyntax = [".5", "5.", "0x10", "1_000", "1 2", "1..2", "1.2.3"]
        for (var i = 0; i < good.length; ++i) compare(rejectOf(one(good[i])), null, good[i])
        for (i = 0; i < badSyntax.length; ++i) compare(rejectOf(one(badSyntax[i])).why, "syntax", badSyntax[i])
        compare(rejectOf(one("1E5")).why, "scientific-literal")
        compare(rejectOf(one("1e-5")).why, "scientific-literal")
        compare(rejectOf(one("1e")).why, "syntax")
        compare(rejectOf(one("2e+")).why, "syntax")
        // an enormous literal is a runtime RANGE, not a compile error
        compare(codeOfExpr(new Array(100).join("9") + "^4"), "RANGE")
    }
    function test_prototypeNamesAreOrdinary() {
        var names = ["__proto__", "constructor", "hasOwnProperty", "toString", "valueOf", "prototype", "__defineGetter__"]
        for (var i = 0; i < names.length; ++i) {
            var n = names[i], valid = /^[a-z][a-z0-9_]{0,23}$/.test(n)
            // as an input / cell / table / column id
            var asInput = rejectOf({inputs: [{id: n, unit: "", value: 1}], tables: [], cells: []})
            var asCell = rejectOf({inputs: [], tables: [], cells: [{id: n, expression: "1", unit: "", decimals: 0}]})
            var asTable = rejectOf({inputs: [], tables: [{id: n, columns: [{id: "v", kind: "number", unit: "", expression: ""}], rows: [["1"]]}], cells: []})
            var asColumn = rejectOf({inputs: [], tables: [{id: "t", columns: [{id: n, kind: "number", unit: "", expression: ""}], rows: [["1"]]}], cells: []})
            if (valid) {
                compare(asInput, null, n); compare(asCell, null, n); compare(asTable, null, n); compare(asColumn, null, n)
            } else {
                compare(asInput.why, "bad-id", n); compare(asCell.why, "bad-id", n)
                compare(asTable.why, "bad-id", n); compare(asColumn.why, "bad-id", n)
            }
            // as an unknown reference: always a clean reject, never a crash or a hit
            var ref = rejectOf(one(n + "+1"))
            verify(ref !== null && (ref.why === "unknown-name" || ref.why === "syntax"), n + " as a reference: " + (ref && ref.why))
            var colref = rejectOf(one("sum(" + n + ".x)"))
            verify(colref !== null && (colref.why === "unknown-table" || colref.why === "syntax"), n + " as a table reference")
            var t = {tables: [{id: "t", columns: [{id: "v", kind: "number", unit: "", expression: ""}], rows: [["1"]]}]}
            var onTable = rejectOf(one("sum(t." + n + ")", t))
            verify(onTable !== null && (onTable.why === "unknown-column" || onTable.why === "syntax"), n + " as a column reference")
            verify(rejectOf(one("1", {inputs: [{id: "a", unit: n, value: 1}]})) !== null, n + " is not a unit")
        }
        // a valid id spelled like an Object.prototype member works as a normal name everywhere
        var spec = {inputs: [{id: "constructor", unit: "kg", value: 3}], tables: [{id: "valueof", columns: [
            {id: "prototype", kind: "number", unit: "kg", expression: ""}, {id: "twice", kind: "formula", unit: "kg", expression: "prototype*2"}],
            rows: [["1", ""], ["2", ""]]}], cells: [{id: "tostring_", expression: "constructor+sum(valueof.twice)", unit: "kg", decimals: 1}]}
        var m = Calc.compileSpec(spec), r = Calc.evaluate(m, {constructor: 4}, null, null)
        compare(Calc.formatCell(m, r, "tostring_"), "10.0 kg")
        // looking up odd ids in the results and the model is a plain miss
        compare(Calc.formatCell(m, r, "__proto__"), ""); compare(Calc.formatCell(m, r, "toString"), "")
        compare(Calc.provenance(m, r, "hasOwnProperty"), null); compare(Calc.provenance(m, r, "__proto__"), null)
        verify(r.nodes.toString === undefined || typeof r.nodes.toString !== "function", "result map has no inherited members")
        // an input map that carries prototype-looking keys changes nothing
        var evil = JSON.parse('{"__proto__": 99, "constructor": 5, "toString": 1, "hasOwnProperty": 2}')
        compare(Calc.formatCell(m, Calc.evaluate(m, evil, null, null), "tostring_"), "11.0 kg")
        compare(({}).polluted, undefined)
        compare(Object.prototype.hasOwnProperty.call(Object.prototype, "polluted"), false)
    }
    function test_columnAndTableIdRules() {
        var t = function (cols) { return {tables: [{id: "t", columns: cols, rows: [cols.map(function () { return "1" })]}]} }
        var c = function (id) { return {id: id, kind: "number", unit: "", expression: ""} }
        compare(rejectOf(one("1", t([c("v"), c("w")]))), null)
        compare(rejectOf(one("1", t([c("v"), c("v")]))).why, "duplicate-id")
        compare(rejectOf(one("1", t([c("r")]))).why, "duplicate-id")      // equals the cell id
        compare(rejectOf(one("1", t([c("t")]))).why, "duplicate-id")      // equals the table id
        compare(rejectOf(one("1", t([c("kg")]))).why, "reserved-id")
        compare(rejectOf(one("1", t([c("or")]))).why, "reserved-id")
        compare(rejectOf(one("1", t([c("Upper")]))).why, "bad-id")
        compare(rejectOf(one("1", t([c(5)]))).why, "bad-id")
        compare(rejectOf(one("1", t([{id: "v", kind: "weird", unit: "", expression: ""}]))).why, "syntax")
        compare(rejectOf(one("1", t([{id: "v", kind: "formula", unit: "", expression: ""}]))).why, "empty")
    }
    function test_specShapeIsValidated() {
        compare(rejectOf(null).why, "syntax"); compare(rejectOf("x").why, "syntax"); compare(rejectOf([]).why, "syntax")
        compare(rejectOf({}) , null)
        compare(rejectOf({inputs: 5}).why, "syntax"); compare(rejectOf({inputs: {}}).why, "syntax")
        compare(rejectOf({cells: [null]}).why, "syntax"); compare(rejectOf({cells: [5]}).why, "syntax"); compare(rejectOf({cells: [{expression: "1"}]}).why, "syntax"); compare(rejectOf({cells: [{id: 5, expression: "1"}]}).why, "bad-id")
        compare(rejectOf({cells: [{id: "a", expression: 5, unit: "", decimals: 0}]}).why, "syntax")
        compare(rejectOf({cells: [{id: "a", expression: null}]}).why, "syntax")
        compare(rejectOf({inputs: [{id: "a", unit: 5, value: 1}]}).why, "bad-unit")
        compare(rejectOf({tables: [{id: "t", columns: [{id: "a", kind: "number"}], rows: [["1", "2"]]}]}).why, "row-shape")
        compare(rejectOf({tables: [{id: "t", columns: [{id: "a", kind: "number"}], rows: [[{}]]}]}).why, "row-shape")
        // decimals outside 0..10 are clamped (OQ8)
        var m = Calc.compileSpec({cells: [{id: "a", expression: "1/3", unit: "", decimals: 99}, {id: "b", expression: "1/3", unit: "", decimals: -4},
            {id: "c", expression: "1/3", unit: ""}]})
        var r = Calc.evaluate(m, {}, null, null)
        compare(Calc.formatCell(m, r, "a"), "0.3333333333"); compare(Calc.formatCell(m, r, "b"), "0"); compare(Calc.formatCell(m, r, "c"), "0.33")
    }
    function test_inputValueEdgeCases() {
        var spec = one("x+1", {inputs: [{id: "x", unit: "", value: 1}]})
        var m = Calc.compileSpec(spec)
        function code(v) { var r = Calc.evaluate(m, {x: v}, null, null); return codeOf(m, r, "r") }
        compare(code(null), "MISSING"); compare(code(undefined), "MISSING"); compare(code("5"), "TYPE")
        compare(code(NaN), "RANGE"); compare(code(Infinity), "RANGE"); compare(code(2), null)
        compare(codeOf(m, Calc.evaluate(m, null, null, null), "r"), null)
        compare(codeOf(m, Calc.evaluate(m, undefined, null, null), "r"), null)
    }

    // ---- pinned decisions D1-D10 (the golden "decisions" group runs them too; these name the rule)
    function test_decision_d1_nonFiniteConversionsAreRange() {
        compare(codeOfExpr("round(1.7976931348623157e308,5)".replace("e308", "") + "*1"), null)   // sanity: plain expression compiles
        var q = {inputs: [{id: "q", unit: "kg", value: 1e308}]}
        compare(codeOfExpr("to(q,[g])", {}, q), "RANGE"); compare(codeOfExpr("num(q,[g])", {}, q), "RANGE")
        compare(codeOfExpr("q", {}, {inputs: [{id: "q", unit: "km", value: 1e308}], cells: [{id: "r", expression: "q", unit: "m", decimals: 0}]}), "RANGE")
        var big = {inputs: [{id: "q", unit: "", value: 1.7976931348623157e308}]}
        compare(codeOfExpr("round(q,5)", {}, big), "RANGE"); compare(codeOfExpr("round(q,0)==q", {}, big), null)
        compare(textOf("round(q,0)==q", {}, big), "true")
        var edge = {inputs: [{id: "a", unit: "", value: 1e303}, {id: "b", unit: "", value: 1e304}]}
        compare(textOf("round(a,5)==a", {}, edge), "true"); compare(codeOfExpr("round(b,5)", {}, edge), "RANGE")
    }
    function test_decision_d2_textColumnKindDecidesNotRowCount() {
        var empty = {tables: [{id: "t", columns: [{id: "n", kind: "text", unit: "", expression: ""}], rows: []}]}
        var blank = {tables: [{id: "t", columns: [{id: "n", kind: "text", unit: "", expression: ""}], rows: [[""], [" "]]}]}
        var fns = ["sum(t.n)", "mean(t.n)", "median(t.n)", "sumproduct(t.n,t.n)"]
        for (var i = 0; i < fns.length; ++i) { compare(codeOfExpr(fns[i], {}, empty), "TYPE", fns[i]); compare(codeOfExpr(fns[i], {}, blank), "TYPE", fns[i]) }
        compare(textOf("count(t.n)", {}, empty), "0.00"); compare(textOf("count(t.n)", {}, blank), "0.00")
    }
    function test_decision_d3_secondArgumentOfToIsAUnitGroup() {
        compare(rejectOf(one("to(1,5)")).why, "unit-position"); compare(rejectOf(one("num(1[kg],5)")).why, "unit-position")
        compare(rejectOf(one("to(1,x)", {inputs: [{id: "x", unit: "", value: 1}]})).why, "unit-position")
        compare(rejectOf(one("to(5[kg],kg)")).why, "unit-position")
        compare(rejectOf(one("to(1,nosuch)")).why, "unit-position")
    }
    function test_decision_d4_unitChecksComeBeforeDomainAndRange() {
        compare(codeOfExpr("sqrt(0-5[cm])"), "UNIT"); compare(codeOfExpr("sqrt(0-9[m^2])"), "DOMAIN")
        compare(codeOfExpr("(2[EUR]*3[EUR])^3000"), "UNIT"); compare(textOf("(2[m])^9"), "512.00 m^9")
        compare(codeOfExpr("(2[m])^10"), "UNIT"); compare(codeOfExpr("(2[m])^0.5"), "UNIT")
        var q = {inputs: [{id: "q", unit: "m", value: 1e200}]}
        compare(codeOfExpr("q^3000", {}, q), "UNIT"); compare(codeOfExpr("q^2", {}, q), "RANGE")
    }
    function test_decision_d5_parseFaultsBeatNameResolution() {
        compare(rejectOf(one("round690.9[Wh],1)")).why, "syntax")
        compare(rejectOf(one("colstat(1,[kg])")).why, "unit-position")
        compare(rejectOf(one("nosuch +")).why, "syntax")
        compare(rejectOf(one("nosuch")).why, "unknown-name")
        compare(rejectOf(one("nosuch(1)+")).why, "syntax")
        compare(rejectOf(one("colstat(0,sum)+")).why, "syntax")
        compare(rejectOf(one("nosuch+1[ABC]")).why, "unknown-unit")      // OQ20: bad-unit, then unknown-unit, then unknown-name
        compare(rejectOf(one("nosuch+1[ABC]+2[]")).why, "bad-unit")
        compare(rejectOf(one("nosuch+1[kg^0]")).why, "bad-unit")
    }
    function test_decision_d5_bareUnitGroupIsAParseFaultEvenInAnUnknownCall() {
        compare(rejectOf(one("x1y(705.67[CHF],[CHF])")).why, "unit-position")
        compare(rejectOf(one("u(100.5[px],[px])")).why, "unit-position")
        compare(rejectOf(one("abs(1,[kg])")).why, "unit-position")
        compare(rejectOf(one("u(1)")).why, "unknown-name")
        compare(rejectOf(one("to(1[kg],[g])+u([kg])")).why, "unit-position")
    }
    function test_decision_d6_malformedShapesAreSyntax() {
        var shapes = [{cells: [5]}, {inputs: {}}, {cells: [{id: "a", expression: 5}]}, {cells: [{id: "a", expression: null}]},
                      {cells: [{id: "a", expression: ["1"]}]}, {cells: [{expression: "1"}]}, {inputs: [{value: 1}]}, null, "x"]
        for (var i = 0; i < shapes.length; ++i) compare(rejectOf(shapes[i]).why, "syntax", JSON.stringify(shapes[i]))
    }
    function test_decision_d7_nonNumberOverrideIsType() {
        var spec = one("x+1", {inputs: [{id: "x", unit: "", value: 1}]}), m = Calc.compileSpec(spec)
        var bad = ["7", true, false, [1], {a: 1}]
        for (var i = 0; i < bad.length; ++i) compare(codeOf(m, Calc.evaluate(m, {x: bad[i]}, null, null), "r"), "TYPE", JSON.stringify(bad[i]))
        compare(codeOf(m, Calc.evaluate(m, {x: null}, null, null), "r"), "MISSING")
    }
    function test_decision_d8_declaredUnitIsNotTrimmed() {
        var spaced = [" kg", "kg ", "\tkg", " ", "kg\n"]
        for (var i = 0; i < spaced.length; ++i) {
            compare(rejectOf({cells: [{id: "a", expression: "1[kg]", unit: spaced[i], decimals: 0}]}).why, "bad-unit", JSON.stringify(spaced[i]))
            compare(rejectOf({inputs: [{id: "a", unit: spaced[i], value: 1}]}).why, "bad-unit")
        }
        compare(rejectOf({cells: [{id: "a", expression: "1", unit: "%%", decimals: 0}]}).why, "unknown-unit")
        compare(rejectOf({cells: [{id: "a", expression: "1", unit: "%", decimals: 0}]}), null)
    }
    function test_decision_d9_unitGroupAlgebra() {
        compare(textOf("1[m*km]"), "1000.00 m^2"); compare(textOf("3[km/h/s]*2[s]"), "6.00 km/h")
        compare(textOf("2[s]*5[km/h/s]"), "10.00 km/h"); compare(textOf("1[kg/g]"), "1000.00")
        compare(textOf("272[kg^2/s/g]"), "272000.00 kg/s"); compare(textOf("2[km]*3[m]"), "0.01 km^2")
        compare(textOf("3[m]*2[km]"), "6000.00 m^2")
    }
    function test_decision_d10_aggregateArgumentsAreExaminedLeftToRight() {
        var t = {tables: [{id: "t", columns: [{id: "a", kind: "number", unit: "", expression: ""},
            {id: "f", kind: "formula", unit: "", expression: "sqrt(0-a)"}, {id: "n", kind: "text", unit: "", expression: ""}],
            rows: [["1", "", "x"]]}]}
        compare(codeOfExpr("sumproduct(t.f,t.n)", {}, t), "DOMAIN"); compare(codeOfExpr("sumproduct(t.n,t.f)", {}, t), "TYPE")
        compare(codeOfExpr("sum(t.f,t.n)", {}, t), "DOMAIN")
    }

    // seeded garbage: mostly well-formed random expressions, then randomly corrupted
    function randomExpr(rng, depth) {
        var r = rng(), names = ["x", "a", "q"], units = ["kg", "g", "m", "km", "h", "min", "EUR", "EUR/h", "%", "m/s^2", "lb"]
        if (depth <= 0 || r < 0.25) {
            var p = rng()
            if (p < 0.4) return String(Math.floor(rng() * 20))
            if (p < 0.55) return (Math.floor(rng() * 100) / 10).toFixed(1)
            if (p < 0.75) return Math.floor(rng() * 50) + "[" + units[Math.floor(rng() * units.length)] + "]"
            return names[Math.floor(rng() * names.length)]
        }
        var sub = function () { return randomExpr(rng, depth - 1) }
        if (r < 0.55) return sub() + ["+", "-", "*", "/", "%", "^"][Math.floor(rng() * 6)] + sub()
        if (r < 0.62) return "-" + sub()
        if (r < 0.68) return "(" + sub() + ")"
        if (r < 0.74) return sub() + ["<", "<=", ">", ">=", "==", "!="][Math.floor(rng() * 6)] + sub()
        if (r < 0.80) return "if(" + sub() + ["<", ">", "=="][Math.floor(rng() * 3)] + sub() + "," + sub() + "," + sub() + ")"
        if (r < 0.84) return "iferror(" + sub() + "," + sub() + ")"
        if (r < 0.88) return ["abs", "floor", "ceil", "sqrt"][Math.floor(rng() * 4)] + "(" + sub() + ")"
        if (r < 0.92) return ["min", "max"][Math.floor(rng() * 2)] + "(" + sub() + "," + sub() + ")"
        if (r < 0.95) return "to(" + sub() + ",[" + units[Math.floor(rng() * units.length)] + "])"
        if (r < 0.98) return ["sum", "mean", "median", "count"][Math.floor(rng() * 4)] + "(t." + ["a", "b", "q"][Math.floor(rng() * 3)] + ")"
        return "colstat(" + (1 + Math.floor(rng() * 3)) + "," + ["sum", "count", "mean"][Math.floor(rng() * 3)] + ")"
    }
    function garbageExpr(rng) {
        var junk = ["(", ")", "+", "-", "*", "/", "%", "^", ",", ".", "<", ">", "=", "!", "[", "]", "[kg]", "\u00a0", "\u0663", "\u00e9", "\"", ";", "&", "e", "1e3", "_", "$", "\n", "[]", " ", "sum(", "t.a", "x"]
        var s = randomExpr(rng, 4), mutations = rng() < 0.35 ? 0 : 1 + Math.floor(rng() * 3)
        for (var i = 0; i < mutations; ++i) {
            var at = Math.floor(rng() * (s.length + 1)), kind = rng()
            if (kind < 0.5) s = s.slice(0, at) + junk[Math.floor(rng() * junk.length)] + s.slice(at)
            else if (kind < 0.8) s = s.slice(0, at) + s.slice(at + 1 + Math.floor(rng() * 3))
            else s = s.slice(0, at)
        }
        return s
    }
    function garbageSpec(rng, expr, asColumn) {
        var spec = {inputs: [{id: "x", unit: rng() < 0.3 ? "kg" : "", value: 2}, {id: "a", unit: "", value: null}], tables: [{id: "t", columns: [
            {id: "a", kind: "number", unit: rng() < 0.3 ? "m" : "", expression: ""}, {id: "b", kind: "formula", unit: "", expression: asColumn ? expr : "a*2"}],
            rows: [["1", ""], ["", ""], ["x", ""], ["3.5", ""]]}], cells: [{id: "r", expression: asColumn ? "sum(t.b)" : expr, unit: "", decimals: 2}]}
        if (asColumn) spec.inputs.pop()
        else spec.tables[0].columns[0].id = "q"
        return spec
    }
    function test_hostileStringSmoke() {
        var rng = makeRng(20261008), started = Date.now(), compiled = 0, rejected = 0, slowest = 0, codes = {MISSING: 1, DIV0: 1, TYPE: 1, UNIT: 1,
            DOMAIN: 1, RANGE: 1, LIMIT: 1, SRC: 1}
        for (var i = 0; i < 3000; ++i) {
            var asColumn = i % 3 === 0, expr = garbageExpr(rng), t0 = Date.now()
            var out = compileOrNull(garbageSpec(rng, expr, asColumn))
            if (out.rej !== null) {
                ++rejected
                verify(typeof out.rej.why === "string" && typeof out.rej.msg === "string", "undocumented throw for " + JSON.stringify(expr) + ": " + out.rej)
                verify(out.rej.msg.indexOf("Unexpected compile failure") !== 0, "engine bug for " + JSON.stringify(expr) + ": " + out.rej.msg)
                verify(/^[a-z-]+$/.test(out.rej.why), "slug shape " + out.rej.why)
            } else {
                ++compiled
                var r1 = Calc.evaluate(out.model, {}, null, null), r2 = Calc.evaluate(out.model, {x: 7}, null, r1)
                for (var k = 0; k < r1.order.length; ++k) {
                    var e = r1.nodes[r1.order[k]].err
                    verify(e === null || codes[e.code] === 1, "bad error code for " + JSON.stringify(expr))
                    verify(e === null || e.msg.indexOf("Unexpected evaluation failure") !== 0, "engine bug at runtime for " + JSON.stringify(expr) + ": " + (e && e.msg))
                }
                compare(snap(r2), snap(Calc.evaluate(out.model, {x: 7}, null, null)), JSON.stringify(expr))
            }
            slowest = Math.max(slowest, Date.now() - t0)
        }
        verify(compiled > 100 && rejected > 100, "the generator reaches both outcomes (" + compiled + " ok / " + rejected + " rejected)")
        verify(slowest < 250, "one hostile case took " + slowest + " ms")
        verify(Date.now() - started < 20000, "smoke took " + (Date.now() - started) + " ms")
    }
    function test_hostileSpecSmoke() {
        var rng = makeRng(31337), junk = [null, undefined, 0, 1, -1, 1e999, NaN, "", " ", "a", "A", "kg", "__proto__", "constructor", "x y", "٣", "[", {}, [], true, "sum", "a.b", new Array(30).join("z")]
        function pick() { return junk[Math.floor(rng() * junk.length)] }
        for (var i = 0; i < 1500; ++i) {
            var spec = {inputs: [], tables: [], cells: []}, n = Math.floor(rng() * 4), j
            for (j = 0; j < n; ++j) spec.inputs.push({id: pick(), unit: pick(), value: pick()})
            for (j = 0; j < n; ++j) spec.cells.push({id: pick(), expression: pick(), unit: pick(), decimals: pick()})
            if (rng() < 0.5) spec.tables.push({id: pick(), columns: [{id: pick(), kind: ["number", "text", "formula", pick()][Math.floor(rng() * 4)], unit: pick(), expression: pick()}], rows: [[pick()], [pick()]]})
            if (rng() < 0.1) spec[["inputs", "cells", "tables"][Math.floor(rng() * 3)]] = pick()
            var out = compileOrNull(spec)
            if (out.rej !== null) {
                verify(typeof out.rej.why === "string" && typeof out.rej.msg === "string", "undocumented throw: " + out.rej)
                verify(out.rej.msg.indexOf("Unexpected compile failure") !== 0, "engine bug: " + out.rej.msg + " for " + JSON.stringify(spec))
            } else Calc.evaluate(out.model, {a: pick(), x: pick()}, {stats: pick()}, null)
        }
    }
    function test_deepAndWideInputsStayFast() {
        var started = Date.now()
        compare(rejectOf(one(new Array(200).join("(") )).why, "tokens")
        compare(rejectOf(one(new Array(120).join("-") + "1")).why, "depth")
        compare(rejectOf(one("sum(" + new Array(100).join("t.a,"))).why, "length")
        compare(rejectOf(one(new Array(100).join("a,"))).why, "tokens")
        compare(rejectOf(one("1,2")).why, "syntax")
        verify(Date.now() - started < 1000)
    }

    // ---- provenance --------------------------------------------------------
    function test_provenanceForAnOrdinaryCell() {
        var c = caseByTag("realistic-invoice-with-an-unfilled-hours-cell"), m = Calc.compileSpec(c.spec), r = Calc.evaluate(m, c.inputs, null, null)
        var p = Calc.provenance(m, r, "total_hours")
        compare(p.id, "total_hours"); compare(p.kind, "cell"); compare(p.formula, "sum(tasks.hours)")
        compare(p.declaredUnit, "h"); compare(p.text, "18.75 h"); compare(p.unit, "h"); compare(p.error, null)
        compare(p.refs.length, 1); compare(p.refs[0].name, "tasks.hours"); compare(p.refs[0].basis, "column, 2 of 3 rows used")
        compare(p.warnings.length, 1); compare(p.warnings[0], "tasks.hours: 2 of 3 rows used")
        verify(p.rounding.indexOf("half away from zero to 2 places: 18.75") > 0, p.rounding)
        verify(p.rounding.indexOf("18.75") > 0)
        verify(p.unitDerivation.indexOf("Result unit: h.") === 0)
        var q = Calc.provenance(m, r, "gross")
        compare(q.refs.map(function (x) { return x.name }).join(","), "taxable,vat_amount")
        compare(q.refs[0].basis, "cell")
        compare(q.chain[0], "gross"); compare(q.chain[q.chain.length - 1], "tasks.line#3"); verify(q.chain.length >= 3)
        var inp = Calc.provenance(m, r, "rate")
        compare(inp.kind, "input"); compare(inp.formula, null); compare(inp.text, "65.00 EUR/h"); compare(inp.refs.length, 0)
    }
    function test_provenanceNamesInputsUnitsAndConversions() {
        var c = caseByTag("units-inputs-carry-their-declared-unit"), m = Calc.compileSpec(c.spec), r = Calc.evaluate(m, c.inputs, null, null)
        var p = Calc.provenance(m, r, "c3")
        compare(p.formula, "price*fx")
        compare(p.refs.map(function (x) { return x.name + "=" + x.text + "/" + x.basis }).join(" "), "price=20.00 EUR/input fx=1.10 USD/EUR/input")
        verify(p.unitDerivation.indexOf("Result unit: USD.") === 0)
        verify(p.unitDerivation.indexOf("price (EUR), fx (USD/EUR)") > 0)
        var conv = Calc.compileSpec({inputs: [], tables: [], cells: [{id: "w", expression: "2.2[lb]", unit: "kg", decimals: 4}]})
        var pc = Calc.provenance(conv, Calc.evaluate(conv, {}, null, null), "w")
        verify(pc.unitDerivation.indexOf("Converted from lb to the declared unit kg.") > 0, pc.unitDerivation)
        compare(pc.text, "0.9979 kg")
    }
    function test_provenanceFollowsAnErrorChain() {
        var c = caseByTag("errors-propagate-through-cell-references"), m = Calc.compileSpec(c.spec), r = Calc.evaluate(m, c.inputs, null, null)
        var p = Calc.provenance(m, r, "e2")
        compare(p.error.code, "DIV0"); compare(p.error.node, "e1"); compare(p.text, "—")
        compare(p.chain.join(">"), "e2>e1")
        compare(p.rounding, "Not shown (error DIV0).")
        // through a column aggregate down to the failing formula-column cell
        var c2 = caseByTag("aggregates-error-cell-propagates-source-empty-is-skipped"), m2 = Calc.compileSpec(c2.spec), r2 = Calc.evaluate(m2, c2.inputs, null, null)
        var p2 = Calc.provenance(m2, r2, "c1")
        compare(p2.error.code, "MISSING"); compare(p2.error.node, "t.line#2")
        compare(p2.chain.join(">"), "c1>t.line#2")
        // a boolean cell
        var b = Calc.compileSpec(one("1<2")), pb = Calc.provenance(b, Calc.evaluate(b, {}, null, null), "r")
        compare(pb.text, "true"); compare(pb.rounding, "Not rounded (true/false).")
        // formula-column cell instances are addressable too
        var pi = Calc.provenance(m2, r2, "t.line#1")
        compare(pi.kind, "column-cell"); compare(pi.formula, "qty*price"); compare(pi.text, "4.50 EUR")
        compare(pi.refs.map(function (x) { return x.basis }).join("|"), "this row of t|this row of t")
    }
    function test_provenanceIsDeterministic() {
        var c = caseByTag("realistic-budget-in-euro-with-explicit-usd-rate"), m = Calc.compileSpec(c.spec), r = Calc.evaluate(m, c.inputs, null, null)
        compare(JSON.stringify(Calc.provenance(m, r, "spend_usd")), JSON.stringify(Calc.provenance(m, Calc.evaluate(m, c.inputs, null, r), "spend_usd")))
    }

    // ---- a realistic-size spec: 12 inputs worth of structure, two 40-row tables, 24 cells
    function bigSpec() {
        var rng = makeRng(5), rowsT = [], rowsU = [], i
        for (i = 0; i < 40; ++i) {
            rowsT.push([i % 9 === 4 ? "" : String(1 + Math.floor(rng() * 9)), String(Math.round(rng() * 9000 + 100) / 100), "", ""])
            rowsU.push([String(Math.round(rng() * 500) / 100), i % 7 === 3 ? "" : String(Math.floor(rng() * 900)), ""])
        }
        function cell(id, expression, unit, decimals) { return {id: id, expression: expression, unit: unit || "", decimals: decimals === undefined ? 2 : decimals} }
        return {
            inputs: [
                {id: "rate", unit: "EUR/h", value: 60}, {id: "hours", unit: "h", value: 8}, {id: "tax", unit: "%", value: 20},
                {id: "disc", unit: "%", value: 5}, {id: "w", unit: "kg", value: 2}, {id: "n", unit: "", value: 3},
                {id: "fx", unit: "USD/EUR", value: 1.1}, {id: "lim", unit: "EUR", value: 1000}],
            tables: [
                {id: "t", columns: [{id: "qty", kind: "number", unit: "", expression: ""}, {id: "price", kind: "number", unit: "EUR", expression: ""},
                    {id: "line", kind: "formula", unit: "EUR", expression: "qty*price*(1-disc)"},
                    {id: "flag", kind: "formula", unit: "", expression: "line>lim/40"}], rows: rowsT},
                {id: "u", columns: [{id: "a", kind: "number", unit: "kg", expression: ""}, {id: "b", kind: "number", unit: "g", expression: ""},
                    {id: "f", kind: "formula", unit: "kg", expression: "a+b+w"}], rows: rowsU}],
            cells: [
                cell("c1", "iferror(sum(t.line),0[EUR])", "EUR"), cell("c2", "iferror(mean(t.line),0[EUR])", "EUR"), cell("c3", "median(t.qty)"),
                cell("c4", "c1*(1+tax)", "EUR"), cell("c5", "c4*fx", "USD"), cell("c6", "if(c4>lim,c4*disc,0[EUR])", "EUR"),
                cell("c7", "sumproduct(t.qty,t.price)", "EUR"), cell("c8", "sum(u.f)", "kg"), cell("c9", "to(c8,[lb])", "lb"),
                cell("c10", "rate*hours", "EUR"), cell("c11", "c10+c1", "EUR"), cell("c12", "iferror(c1/(n-3),0[EUR])", "EUR"),
                cell("c13", "count(t.qty)", "", 0), cell("c14", "max(c1,c4,c10)", "EUR"), cell("c15", "clamp(c4,0[EUR],lim)", "EUR"),
                cell("c16", "round(c5,1)", "USD", 1), cell("c17", "c8/n", "kg"), cell("c18", "not (c4>lim)"), cell("c19", "hours*rate*n", "EUR"),
                cell("c20", "sqrt(n)", "", 3), cell("c21", "c2/c13", "EUR"), cell("c22", "sum(u.a,u.b)", "kg"),
                cell("c23", "if(count(t.line)>10,c1,c4)", "EUR"), cell("c24", "c7-c1", "EUR")]}
    }
    function test_theBigSpecComputesSensibleValues() {
        var spec = bigSpec(), m = Calc.compileSpec(spec), r = Calc.evaluate(m, {}, null, null)
        compare(spec.cells.length, 24)
        compare(m.nodes.length, 8 + 80 + 40 + 24)   // 8 inputs + 2x40 + 1x40 formula-column instances + 24 cells
        for (var i = 1; i <= 24; ++i) {
            var code = codeOf(m, r, "c" + i)
            verify(code === null || code === "MISSING" || code === "DIV0", "c" + i + " raised " + code)
        }
        compare(codeOf(m, r, "c12"), null)
        compare(Calc.formatCell(m, r, "c12"), "0.00 EUR")     // n = 3 -> DIV0 -> iferror -> 0 EUR
        verify(r.steps > 1000 && r.steps < 50000, "pass cost " + r.steps)
    }

    // ---- timing: p95 of single-input edits through the incremental path
    function test_incrementalEditTiming() {
        var spec = bigSpec(), model = Calc.compileSpec(spec), rng = makeRng(8128), vals = {}, i
        for (i = 0; i < spec.inputs.length; ++i) vals[spec.inputs[i].id] = spec.inputs[i].value
        var prev = Calc.evaluate(model, vals, null, null), times = [], total = 0
        for (i = 0; i < 100; ++i) {   // warm up the JIT, untimed
            var warm = spec.inputs[Math.floor(rng() * spec.inputs.length)].id
            vals[warm] = randomValue(rng, vals[warm]); prev = Calc.evaluate(model, vals, null, prev)
        }
        for (i = 0; i < 1000; ++i) {
            var id = spec.inputs[Math.floor(rng() * spec.inputs.length)].id
            vals[id] = randomValue(rng, vals[id])
            var t0 = Date.now()
            prev = Calc.evaluate(model, vals, null, prev)
            var dt = Date.now() - t0
            times.push(dt); total += dt
        }
        times.sort(function (a, b) { return a - b })
        var p50 = times[500], p95 = times[950], mean = total / 1000
        console.log("AiCalc incremental edit timing (1000 single-input edits, 24 cells + two 40-row tables, Date.now() ms resolution): p50="
            + p50 + " ms, p95=" + p95 + " ms, max=" + times[999] + " ms, mean=" + mean.toFixed(3) + " ms")
        verify(p95 < 5, "p95 " + p95 + " ms")
        // a full compile + full pass is also cheap
        var t1 = Date.now(), fullModel = Calc.compileSpec(spec), fullResult = Calc.evaluate(fullModel, vals, null, null)
        console.log("AiCalc compile + full pass: " + (Date.now() - t1) + " ms, steps " + fullResult.steps)
        verify(Date.now() - t1 < 100, "compile + full pass " + (Date.now() - t1) + " ms")
    }

    // ---- seeded differential fuzz --------------------------------------------------------
    // CalcFuzz.js is GENERATED by tests/gen_calc_fuzz.py; its expected values are what the Python
    // engine says, so every failure here is a place where the two engines drifted apart (the row
    // index and tag identify it; tests/test_ai_calc.py proves the file is never stale). Rows
    // carrying "approx" (sqrt or a non-integer-literal ^) compare the numeric prefix within that
    // relative tolerance and the unit suffix exactly; every other row compares exact text.
    function fuzzProblems(c) {
        var bad = [], out = compileOrNull(clone(c.spec))
        if (c.compile === "reject") {
            if (out.rej === null) bad.push("expected reject '" + c.why + "' but it compiled")
            else if (out.rej.why !== c.why) bad.push("reject '" + out.rej.why + "' != '" + c.why + "' (" + out.rej.msg + ")")
            return bad
        }
        if (out.rej !== null) { bad.push("unexpected reject '" + out.rej.why + "': " + out.rej.msg); return bad }
        var res = Calc.evaluate(out.model, clone(c.inputs), c.env === undefined ? null : clone(c.env), null)
        for (var id in c.expect) {
            var want = c.expect[id], got = Calc.formatCell(out.model, res, id), code = codeOf(out.model, res, id)
            if (code !== want.err) { bad.push(id + ": error " + code + " != " + want.err + " (text '" + got + "' vs '" + want.text + "')"); continue }
            if (got === want.text) continue
            var a = numericPrefix(got), b = numericPrefix(want.text)
            if (c.approx !== undefined && !isNaN(a.n) && !isNaN(b.n)
                    && Math.abs(a.n - b.n) <= c.approx * Math.max(Math.abs(a.n), Math.abs(b.n)) && a.rest === b.rest) continue
            bad.push(id + ": '" + got + "' != '" + want.text + "'")
        }
        return bad
    }
    function test_fuzz_fileIsLoadedAndSane() {
        var rows = Fuzz.CASES, tags = {}, ok = 0
        verify(rows.length >= 1500 && rows.length <= 3000, "rows " + rows.length)
        for (var i = 0; i < rows.length; ++i) {
            verify(tags[rows[i].tag] === undefined, "duplicate tag " + rows[i].tag)
            tags[rows[i].tag] = true
            if (rows[i].compile === "ok") ++ok
        }
        verify(ok >= 1400, "ok rows " + ok)
    }
    function test_fuzz_differential_data() {
        var out = [], n = Fuzz.CASES.length
        for (var i = 0; i < n; i += 100)
            out.push({tag: "rows " + i + "-" + Math.min(i + 99, n - 1), from: i, to: Math.min(i + 100, n)})
        return out
    }
    function test_fuzz_differential(data) {
        var bad = []
        for (var i = data.from; i < data.to; ++i) {
            var problems = fuzzProblems(Fuzz.CASES[i])
            if (problems.length) bad.push("#" + i + " " + Fuzz.CASES[i].tag + ": " + problems.slice(0, 3).join(" | "))
        }
        verify(bad.length === 0, bad.length + " of " + (data.to - data.from) + " rows differ from the Python engine\n" + bad.slice(0, 12).join("\n"))
    }
    // everything observable about a pass keyed by node id: [display text, error code]
    function fuzzView(model, res) {
        var out = {}
        for (var i = 0; i < res.order.length; ++i) {
            var id = res.order[i]
            out[id] = [Calc.formatCell(model, res, id), codeOf(model, res, id)]
        }
        return out
    }
    function viewKey(view) {
        return Object.keys(view).sort().map(function (id) { return id + "=" + view[id][0] + "/" + view[id][1] }).join("\n")
    }
    function viewHasLimit(view) {
        for (var id in view) if (view[id][1] === "LIMIT") return true
        return false
    }
    function test_fuzz_orderIndependenceOverShuffledDeclarations() {
        var rows = Fuzz.CASES, checked = 0, bad = []
        for (var i = 0; i < rows.length; ++i) {
            var c = rows[i]
            if (c.compile !== "ok") continue
            var rng = makeRng(i + 1), spec = clone(c.spec)
            spec.inputs = shuffled(spec.inputs, rng); spec.tables = shuffled(spec.tables, rng); spec.cells = shuffled(spec.cells, rng)
            var m1 = Calc.compileSpec(clone(c.spec)), m2 = Calc.compileSpec(spec)
            var env = c.env === undefined ? null : c.env
            var v1 = fuzzView(m1, Calc.evaluate(m1, clone(c.inputs), clone(env), null))
            var v2 = fuzzView(m2, Calc.evaluate(m2, clone(c.inputs), clone(env), null))
            if (viewHasLimit(v1) || viewHasLimit(v2)) continue
            ++checked
            if (viewKey(v1) !== viewKey(v2)) bad.push("#" + i + " " + c.tag)
        }
        verify(bad.length === 0, "declaration order changed results: " + bad.slice(0, 10).join(", "))
        verify(checked > 1300, "only " + checked + " rows checked")
    }
    function test_fuzz_incrementalEqualsFullRecompute() {
        var rows = Fuzz.CASES, pool = [null, 0, 1, -1, 2.5, 100, 1e200, 0.1, 1e-9, -3, 7], checked = 0, bad = []
        for (var i = 0; i < rows.length; i += 3) {
            var c = rows[i]
            if (c.compile !== "ok" || c.spec.inputs.length === 0) continue
            var rng = makeRng(i * 7 + 1), model = Calc.compileSpec(clone(c.spec)), env = c.env === undefined ? null : c.env
            var vals = clone(c.inputs), prev = Calc.evaluate(model, clone(vals), clone(env), null)
            for (var step = 0; step < 10; ++step) {
                var edits = 1 + Math.floor(rng() * 2)
                for (var e = 0; e < edits; ++e)
                    vals[c.spec.inputs[Math.floor(rng() * c.spec.inputs.length)].id] = pool[Math.floor(rng() * pool.length)]
                var inc = Calc.evaluate(model, clone(vals), clone(env), prev), full = Calc.evaluate(model, clone(vals), clone(env), null)
                if (JSON.stringify([fuzzView(model, inc), inc.steps]) !== JSON.stringify([fuzzView(model, full), full.steps])) {
                    bad.push("#" + i + " " + c.tag + " step " + step); break
                }
                prev = inc
            }
            ++checked
        }
        verify(bad.length === 0, "incremental != full: " + bad.slice(0, 10).join(", "))
        verify(checked > 300, "only " + checked + " rows checked")
    }
    function test_fuzz_unitRoundTripWithinAFamily() {
        var families = {
            length: ["mm", "cm", "m", "km", "in", "ft", "mi"], mass: ["g", "kg", "lb", "oz"], time: ["s", "min", "h", "d", "wk"],
            data: ["B", "kB", "MB", "GB", "TB", "KiB", "MiB", "GiB", "TiB"], energy: ["J", "Wh", "kWh"], power: ["W", "kW"],
            freq: ["Hz", "GHz"], speed: ["km/h", "m/s", "mi/h", "ft/s"], area: ["m^2", "cm^2", "km^2", "ft^2", "m*m"],
            accel: ["m/s^2"], eurkg: ["EUR/kg", "EUR/lb", "EUR/g"], usdh: ["USD/h", "USD/min"], eurh: ["EUR/h", "EUR/min", "EUR/d"],
            drate: ["MB/s", "kB/s", "GB/h", "MiB/s"]
        }
        var values = [1, 0.37, 123456.789, -42.5, 0.001, 7e5, 3.0e-7, 98765432.1], pairs = 0, bad = []
        for (var name in families) {
            var units = families[name]
            for (var a = 0; a < units.length; ++a) for (var b = 0; b < units.length; ++b) for (var k = 0; k < values.length; ++k) {
                var v = values[k], u0 = units[a], u = units[b]
                var spec = {inputs: [{id: "x", unit: u0, value: v}], tables: [], cells: [
                    {id: "own", expression: "x", unit: "", decimals: 10},
                    {id: "back", expression: "to(to(x,[" + u + "]),[" + u0 + "])", unit: "", decimals: 10}]}
                var m = Calc.compileSpec(spec), r = Calc.evaluate(m, {}, null, null)
                var own = r.nodes.own, back = r.nodes.back
                ++pairs
                if (back.err || back.unit !== own.unit || !(Math.abs(back.value - v) <= 1e-12 * Math.abs(v)))
                    bad.push(u0 + "->" + u + "->" + u0 + " of " + v + " gave " + back.value + " " + back.unit + (back.err ? " " + back.err.code : ""))
            }
        }
        verify(bad.length === 0, bad.length + " round trips off: " + bad.slice(0, 6).join("; "))
        verify(pairs > 2000, "only " + pairs + " round trips")
    }
}
