import QtQuick
import QtTest
import ".."
import "../AiCalc.js" as Calc
import "../AiCalcEdit.js" as Edit
import "../AiCalcView.js" as View

// The scenarios component is driven with REAL plans, scenario lists and results
// from the real engine (AiCalcView.scenarioResults); nothing here mocks state.
// The component never mutates anything, so signals are the whole contract.
TestCase {
    id: tests
    name: "AiCalcScenarios"
    width: 1100
    height: 1400
    visible: true
    when: windowShown

    // ---- fixtures ---------------------------------------------------------------
    // The worked example from ai_catalog.CALC_EXAMPLE (keep in step with it).
    function example() {
        return JSON.parse('{"type":"calc","title":"Laptop score","inputs":[{"id":"w_perf","label":"Speed weight","unit":"","min":0,"max":10,"step":1,"value":5,"basis":"assumption"},{"id":"w_batt","label":"Battery weight","unit":"","min":0,"max":10,"step":1,"value":3,"basis":"assumption"},{"id":"w_price","label":"Price weight","unit":"","min":0,"max":10,"step":1,"value":2,"basis":"assumption"}],"tables":[{"id":"laptops","label":"Laptops","columns":[{"id":"name","label":"Laptop","unit":"","kind":"text","expression":""},{"id":"perf","label":"Speed (0-10)","unit":"","kind":"number","expression":""},{"id":"batt","label":"Battery","unit":"h","kind":"number","expression":""},{"id":"price","label":"Price","unit":"EUR","kind":"number","expression":""},{"id":"score","label":"Score","unit":"","kind":"formula","expression":"if(wsum==0,0,(w_perf*perf/10+w_batt*batt/20[h]+w_price*clamp(1-price/2000[EUR],0,1))/wsum*100)"}],"rows":[["Air 13","7","15","1100",""],["Pro 14","9","11","1800",""],["Budget 15","5","8","650",""]]}],"cells":[{"id":"wsum","label":"Total weight","expression":"w_perf+w_batt+w_price","unit":"","decimals":0,"note":""},{"id":"mean_score","label":"Average score","expression":"mean(laptops.score)","unit":"","decimals":1,"note":""},{"id":"avg_price","label":"Average price","expression":"mean(laptops.price)","unit":"EUR","decimals":0,"note":""}],"note":"Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."}')
    }
    function weights(a, b, c) {
        return {w_perf: {v: a, u: ""}, w_batt: {v: b, u: ""}, w_price: {v: c, u: ""}}
    }
    // Exact fractions, computed outside the engine (score = 100 * (wp*perf/10 + wb*batt/20 + wc*(1-price/2000)) / wsum):
    //  5/3/2   (Current): Air 13 66.5, Pro 14 63.5, Budget 15 50.5; mean 180.5/3 = 60.1667 -> "60.2";
    //                     mean price 3550/3 = 1183.33 -> "1183 EUR"; total weight 10
    //  10/0/0  "Speed":   70, 90, 50 -> "70.00","90.00","50.00"; mean 210/3 = 70 -> "70.0"; total 10
    //  0/0/10  "Price":   45 (1-1100/2000 = .45), 10 (1-.9), 67.5 (1-.325) -> mean 122.5/3 = 40.8333 -> "40.8"; total 10
    function harness(block, current, named) {
        var scn = []
        for (var i = 0; i < named.length; ++i) {
            var r = Edit.saveScenario(scn, named[i][0], named[i][1])
            verify(r.ok === true, "fixture scenario " + named[i][0])
            scn = r.scenarios
        }
        var entry = Edit.compose(current, {}, scn), plan = View.build(block, entry)
        verify(plan !== null, "fixture builds")
        return {plan: plan, entry: entry, scenarios: View.scenarioResults(plan, entry), inputs: block.inputs}
    }
    function setup(h) {
        view.plan = h.plan
        view.model = h.plan.model
        view.scenarios = h.scenarios
        view.inputs = h.inputs
        waitForRendering(view)
    }
    function exampleThree() {
        return harness(example(), {}, [["Speed", weights(10, 0, 0)], ["Price", weights(0, 0, 10)], ["Even", weights(4, 4, 4)]])
    }
    function exampleTwo() {
        return harness(example(), {}, [["Speed", weights(10, 0, 0)], ["Price", weights(0, 0, 10)]])
    }

    // A block that divides by an input: n = 0 is an error value in the engine.
    function errorBlock() {
        return {type: "calc", title: "Split", inputs: [
            {id: "n", label: "Hours", unit: "h", min: 0, max: 10, step: 1, value: 4, basis: "assumption"},
            {id: "k", label: "Extra", unit: "", min: 0, max: 10, step: 1, value: 2, basis: "assumption"}],
            tables: [{id: "items", label: "Items", columns: [
                {id: "name", label: "Item", unit: "", kind: "text", expression: ""},
                {id: "qty", label: "Qty", unit: "", kind: "number", expression: ""},
                {id: "share", label: "Share", unit: "", kind: "formula", expression: "qty*1[h]/n"}],
                rows: [["A", "2", ""], ["B", "5", ""]]}],
            cells: [{id: "per", label: "Per head", expression: "100[h]/n", unit: "", decimals: 1, note: ""},
                    {id: "tot", label: "Total", expression: "num(n,[h])+k", unit: "", decimals: 0, note: ""}],
            note: ""}
    }

    // Worst case: 12 inputs, 24 cells and a 40-row table with two formula columns.
    function bigBlock(tableRows) {
        var inputs = [], cells = [], rows = [], k
        for (k = 0; k < 12; ++k)
            inputs.push({id: "i" + k, label: "Input " + k, unit: "", min: 0, max: 10, step: 1, value: 5, basis: "assumption"})
        for (k = 0; k < 24; ++k)
            cells.push({id: "c" + k, label: "Cell " + k, expression: "i" + (k % 12) + "*" + (k + 1), unit: "", decimals: 1, note: ""})
        for (k = 0; k < tableRows; ++k) rows.push(["Row " + k, String(k + 1), "", ""])
        return {type: "calc", title: "Big", inputs: inputs, cells: cells, note: "", tables: [{id: "t", label: "Big table", columns: [
            {id: "name", label: "Name", unit: "", kind: "text", expression: ""},
            {id: "qty", label: "Qty", unit: "", kind: "number", expression: ""},
            {id: "f1", label: "Times first", unit: "", kind: "formula", expression: "qty*i0"},
            {id: "f2", label: "Plus second", unit: "", kind: "formula", expression: "qty+i1"}], rows: rows}]}
    }
    function bigHarness(tableRows) {
        var all = {}, a = {}, b = {}, c = {}
        for (var k = 0; k < 12; ++k) { a["i" + k] = {v: 1, u: ""}; b["i" + k] = {v: 2, u: ""}; c["i" + k] = {v: 3, u: ""} }
        return harness(bigBlock(tableRows), {}, [["One", a], ["Two", b], ["Three", c]])
    }

    AiCalcScenarios {
        id: view
        plan: null
        model: null
        scenarios: []
        inputs: []
        width: 660
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
    }

    Item { id: before; activeFocusOnTab: true }
    SignalSpy { id: saves; target: view; signalName: "saveRequested" }
    SignalSpy { id: loads; target: view; signalName: "loadRequested" }
    SignalSpy { id: deletes; target: view; signalName: "deleteRequested" }

    // ---- helpers ------------------------------------------------------------------
    function walk(item, fn) {
        fn(item)
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) walk(kids[i], fn)
    }
    function child(name) {
        var found = null
        walk(view, function(it) { if (found === null && it.objectName === name) found = it })
        return found
    }
    function isText(it) { return /^QQuick(Placeholder)?Text/.test(it.toString()) }
    function texts() {
        var out = []
        walk(view, function(it) { if (isText(it)) out.push(it) })
        return out
    }
    function visibleTexts() {
        return texts().filter(function(t) { return t.visible && t.text.length > 0 })
    }
    function open() {
        view.expanded = true
        tryVerify(function() { return child("aiCalcScenariosName") !== null })
        waitForRendering(view)
    }
    function compare_() {
        open()
        view.comparing = true
        tryVerify(function() { return child("aiCalcScenariosScroll") !== null })
        waitForRendering(view)
    }
    function cell(r, c) { return child("aiCalcScenariosCell_" + r + "_" + c) }
    function cellTexts(r, cols) {
        var out = []
        for (var c = 0; c < cols; ++c) out.push(cell(r, c) ? cell(r, c).text : null)
        return out
    }
    function bold(t) { return t.font.weight === Font.Bold }
    function flags(r, cols) {
        var out = []
        for (var c = 0; c < cols; ++c) out.push(bold(cell(r, c)))
        return out
    }
    function setName(text) {
        var f = child("aiCalcScenariosName")
        f.text = text
        return f
    }

    function init() {
        view.expanded = false
        view.comparing = false
        view.busy = false
        view.width = 660
        view.plan = null
        view.model = null
        view.scenarios = []
        view.inputs = []
        before.forceActiveFocus()
        saves.clear(); loads.clear(); deletes.clear()
        wait(0)
    }

    // ---- collapsed by default -------------------------------------------------------
    function test_collapsedByDefault() {
        setup(exampleTwo())
        var toggle = child("aiCalcScenariosToggle")
        verify(toggle.visible)
        verify(!view.expanded)
        compare(child("aiCalcScenariosPanelLoader").item, null, "the panel is not instantiated")
        compare(child("aiCalcScenariosName"), null)
        compare(toggle.text.indexOf("Scenarios (2)") >= 0, true, toggle.text)
        compare(toggle.Accessible.name, "Scenarios (2), collapsed")
        verify(view.implicitHeight > 20 && view.implicitHeight < 50, "collapsed height " + view.implicitHeight)
        // only the toggle's own label is a Text delegate
        compare(texts().length, 1)
    }

    function test_toggleByKeyboardAndLabelFollowsTheCount() {
        setup(harness(example(), {}, []))
        var toggle = child("aiCalcScenariosToggle")
        verify(toggle.text.indexOf("Scenarios (0)") >= 0)
        toggle.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(toggle, "activeFocus", true)
        keyClick(Qt.Key_Space)
        verify(view.expanded)
        tryVerify(function() { return child("aiCalcScenariosName") !== null })
        compare(toggle.Accessible.name, "Scenarios (0), expanded")
        keyClick(Qt.Key_Return)
        verify(!view.expanded)
        tryVerify(function() { return child("aiCalcScenariosName") === null })
        mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        verify(view.expanded)
        setup(exampleTwo())
        verify(toggle.text.indexOf("Scenarios (2)") >= 0)
        compare(saves.count + loads.count + deletes.count, 0, "toggling emits nothing")
    }

    function test_tabOrderIsLogical() {
        setup(exampleTwo())
        open()
        var order = ["aiCalcScenariosToggle", "aiCalcScenariosName", "aiCalcScenariosLoad_0", "aiCalcScenariosDelete_0",
            "aiCalcScenariosLoad_1", "aiCalcScenariosDelete_1", "aiCalcScenariosCompare"]
        child("aiCalcScenariosToggle").forceActiveFocus(Qt.TabFocusReason)
        tryCompare(child("aiCalcScenariosToggle"), "activeFocus", true)
        // the disabled Save button is skipped; with a name it joins the ring after the field
        var seen = ["aiCalcScenariosToggle"]
        for (var i = 1; i < order.length; ++i) {
            keyClick(Qt.Key_Tab)
            var focused = null
            walk(view, function(it) { if (it.activeFocus && it.objectName) focused = it.objectName })
            seen.push(focused)
        }
        compare(seen, order)
        setName("x")
        keyClick(Qt.Key_Tab)   // Compare -> leaves the component or stays in the ring; never lands on a hidden item
        child("aiCalcScenariosName").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(child("aiCalcScenariosSave"), "activeFocus", true)
    }

    // ---- save ---------------------------------------------------------------------
    function test_saveByButtonAndEnterEmitsTheTrimmedName() {
        setup(harness(example(), {}, []))
        open()
        var save = child("aiCalcScenariosSave")
        verify(!save.enabled, "no name: disabled")
        compare(save.text, "Save")
        compare(child("aiCalcScenariosReason").text, "Enter a name to save.")
        verify(child("aiCalcScenariosReason").visible)
        compare(save.Accessible.description, "Enter a name to save.")
        var field = setName("   ")
        verify(!save.enabled, "blank name: disabled")
        field = setName("  Speed first ")
        verify(save.enabled)
        verify(!child("aiCalcScenariosReason").visible)
        mouseClick(save, save.width / 2, save.height / 2)
        compare(saves.count, 1)
        compare(saves.signalArguments[0][0], "Speed first")
        compare(field.text, "", "the field clears after a request")
        // Enter in the field saves too
        field.forceActiveFocus(Qt.TabFocusReason)
        for (var ch of "Even") keyClick(ch)
        compare(field.text, "Even")
        keyClick(Qt.Key_Return)
        compare(saves.count, 2)
        compare(saves.signalArguments[1][0], "Even")
        // Enter on an empty field does nothing
        keyClick(Qt.Key_Return)
        compare(saves.count, 2)
        compare(loads.count + deletes.count, 0)
    }

    function test_nameFieldIsCappedAtThirtyTwoUnits() {
        setup(harness(example(), {}, []))
        open()
        var field = child("aiCalcScenariosName")
        compare(field.maximumLength, 32)
        compare(field.placeholderText, "Scenario name")
        field.forceActiveFocus(Qt.TabFocusReason)
        for (var i = 0; i < 40; ++i) keyClick("a")
        compare(field.text.length, 32)
        keyClick(Qt.Key_Return)
        compare(saves.count, 1)
        compare(saves.signalArguments[0][0].length, 32)
    }

    function test_threeScenariosBlockANewNameButAllowAReplace() {
        setup(harness(example(), {}, [["A", weights(1, 0, 0)], ["B", weights(0, 1, 0)], ["C", weights(0, 0, 1)]]))
        open()
        var save = child("aiCalcScenariosSave"), reason = child("aiCalcScenariosReason")
        compare(child("aiCalcScenariosToggle").text.indexOf("Scenarios (3)") >= 0, true)
        verify(!save.enabled)
        verify(reason.visible && reason.text.indexOf("3 scenarios are saved") === 0, reason.text)
        setName("D")
        verify(!save.enabled, "a fourth distinct name is refused")
        verify(reason.text.indexOf("Delete one") >= 0, reason.text)
        compare(save.Accessible.description, reason.text)
        child("aiCalcScenariosName").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        compare(saves.count, 0, "Enter cannot bypass the limit")
        setName("B")
        verify(save.enabled, "a saved name replaces")
        compare(save.text, "Save (Replaces)")
        verify(save.Accessible.name.indexOf("replaces the saved scenario named B") >= 0)
        verify(!reason.visible)
        mouseClick(save, save.width / 2, save.height / 2)
        compare(saves.signalArguments[0][0], "B")
        // under the limit, an existing name is still a replace, a new one a plain save
        setup(harness(example(), {}, [["A", weights(1, 0, 0)]]))
        setName("A")
        compare(save.text, "Save (Replaces)")
        setName("a")
        compare(save.text, "Save", "names are exact: another case is a new scenario")
    }

    function test_busyDisablesEveryMutation() {
        setup(exampleTwo())
        open()
        setName("Z")
        view.busy = true
        verify(!child("aiCalcScenariosSave").enabled)
        verify(!child("aiCalcScenariosLoad_0").enabled)
        verify(!child("aiCalcScenariosDelete_1").enabled)
        verify(child("aiCalcScenariosReason").text.indexOf("Busy") === 0)
        verify(child("aiCalcScenariosLoad_0").Accessible.description.indexOf("Busy") === 0)
        child("aiCalcScenariosName").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        compare(saves.count, 0)
        view.busy = false
        verify(child("aiCalcScenariosSave").enabled)
        verify(child("aiCalcScenariosLoad_0").enabled)
    }

    function test_escapeInTheNameFieldLeavesIt() {
        setup(exampleTwo())
        open()
        var field = child("aiCalcScenariosName")
        field.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(field, "activeFocus", true)
        field.text = "draft"
        keyClick(Qt.Key_Escape)
        tryCompare(field, "activeFocus", false)
        tryCompare(child("aiCalcScenariosToggle"), "activeFocus", true)
        compare(field.text, "draft", "Escape leaves the draft alone")
        compare(saves.count, 0)
    }

    // ---- load / delete ----------------------------------------------------------------
    function test_loadAndDeleteEmitExactIndexes() {
        setup(harness(example(), {}, [["Alpha", weights(1, 0, 0)], ["Beta", weights(0, 1, 0)], ["Gamma", weights(0, 0, 1)]]))
        open()
        compare(child("aiCalcScenariosItem_0").text, "Alpha")
        compare(child("aiCalcScenariosItem_2").text, "Gamma")
        compare(child("aiCalcScenariosLoad_1").Accessible.name, "Load scenario Beta")
        compare(child("aiCalcScenariosDelete_2").Accessible.name, "Delete scenario Gamma")
        var load = child("aiCalcScenariosLoad_1")
        load.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(loads.count, 1)
        compare(loads.signalArguments[0][0], 1)
        mouseClick(child("aiCalcScenariosLoad_2"), 5, 5)
        compare(loads.signalArguments[1][0], 2)
        var del = child("aiCalcScenariosDelete_0")
        del.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        tryCompare(deletes, "count", 1)    // emitted from the next event-loop turn: the owner may drop the button
        compare(deletes.signalArguments[0][0], 0)
        mouseClick(child("aiCalcScenariosDelete_2"), 5, 5)
        tryCompare(deletes, "count", 2)
        compare(deletes.signalArguments[1][0], 2)
        compare(saves.count, 0)
        // nothing was changed by asking: the component only reports
        compare(view.scenarios.length, 4)
        compare(child("aiCalcScenariosItem_0").text, "Alpha")
    }

    function test_deleteMovesFocusToTheNextButtonThenTheField() {
        setup(harness(example(), {}, [["Alpha", weights(1, 0, 0)], ["Beta", weights(0, 1, 0)]]))
        open()
        // the owner handles the signal synchronously, like AiCalc will: the list shrinks inside the click
        var next = [harness(example(), {}, [["Beta", weights(0, 1, 0)]]), harness(example(), {}, [])]
        var step = 0
        var owner = function(index) { setup(next[step++]) }
        view.deleteRequested.connect(owner)
        var del = child("aiCalcScenariosDelete_0")
        del.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        tryCompare(deletes, "count", 1)
        compare(deletes.signalArguments[0][0], 0)
        tryVerify(function() { return child("aiCalcScenariosDelete_0") !== null && child("aiCalcScenariosDelete_0").activeFocus })
        compare(child("aiCalcScenariosItem_0").text, "Beta")
        keyClick(Qt.Key_Space)
        tryCompare(deletes, "count", 2)
        compare(deletes.signalArguments[1][0], 0)
        tryCompare(child("aiCalcScenariosName"), "activeFocus", true)
        verify(child("aiCalcScenariosEmpty").visible)
        view.deleteRequested.disconnect(owner)
    }

    // ---- compare: content ---------------------------------------------------------------
    function test_compareIsAnInactiveLoaderUntilOpened() {
        setup(exampleTwo())
        open()
        var loader = child("aiCalcScenariosCompareLoader")
        verify(!loader.active)
        compare(loader.item, null)
        compare(child("aiCalcScenariosScroll"), null)
        verify(child("aiCalcScenariosCompare").enabled)
        compare(child("aiCalcScenariosCompare").text.indexOf("Compare") >= 0, true)
        compare(child("aiCalcScenariosCompare").Accessible.name, "Compare scenarios, collapsed")
        child("aiCalcScenariosCompare").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        tryVerify(function() { return loader.active && child("aiCalcScenariosScroll") !== null })
        verify(view.comparing)
        compare(child("aiCalcScenariosCompare").Accessible.name, "Compare scenarios, expanded")
        keyClick(Qt.Key_Return)
        tryVerify(function() { return child("aiCalcScenariosScroll") === null })
        verify(!loader.active)
    }

    function test_compareNeedsASavedScenario() {
        setup(harness(example(), {}, []))
        open()
        var compareButton = child("aiCalcScenariosCompare")
        verify(!compareButton.enabled)
        compare(compareButton.Accessible.description, "Save a scenario first.")
        verify(child("aiCalcScenariosEmpty").visible)
        view.comparing = true
        wait(0)
        compare(child("aiCalcScenariosScroll"), null, "no saved scenario: nothing to compare")
    }

    function test_compareColumnsRowsAndValues() {
        setup(exampleTwo())
        compare_()
        var names = []
        for (var c = 0; c < 4; ++c) {
            var h = child("aiCalcScenariosColumn_" + c)
            if (h) names.push(h.text)
        }
        compare(names, ["Current", "Speed", "Price"], "Current first, then the saved ones in order")
        compare(child("aiCalcScenariosColumn_3"), null)
        // rows: 0 section, 1-3 differing inputs, 4 section, 5-7 cells, 8 section, 9-11 the Score column
        compare(child("aiCalcScenariosSection_0").text, "Inputs that differ")
        compare(child("aiCalcScenariosLabel_1").text, "Speed weight")
        compare(cellTexts(1, 3), ["5", "10", "0"])
        compare(cellTexts(2, 3), ["3", "0", "0"])
        compare(child("aiCalcScenariosLabel_3").text, "Price weight")
        compare(cellTexts(3, 3), ["2", "0", "10"])
        compare(child("aiCalcScenariosSection_4").text, "Results")
        compare(child("aiCalcScenariosLabel_5").text, "Total weight")
        compare(cellTexts(5, 3), ["10", "10", "10"])
        compare(cellTexts(6, 3), ["60.2", "70.0", "40.8"])
        compare(child("aiCalcScenariosLabel_7").text, "Average price")
        compare(cellTexts(7, 3), ["1183 EUR", "1183 EUR", "1183 EUR"])
        compare(child("aiCalcScenariosSection_8").text, "Laptops: Score")
        compare(child("aiCalcScenariosLabel_9").text, "Air 13")
        compare(cellTexts(9, 3), ["66.50", "70.00", "45.00"])
        compare(cellTexts(10, 3), ["63.50", "90.00", "10.00"])
        compare(child("aiCalcScenariosLabel_11").text, "Budget 15")
        compare(cellTexts(11, 3), ["50.50", "50.00", "67.50"])
        compare(cell(12, 0), null, "no more rows")
        // one picked formula column and no ranking or delta text anywhere
        compare(child("aiCalcScenariosPick_0_0"), null, "a single formula column needs no picker")
        var all = visibleTexts().map(function(t) { return t.text }).join("\n")
        verify(!/rank|best|worst|winner|[+-]\d+(\.\d+)?%|delta/i.test(all), all)
    }

    function test_onlyValuesThatDifferFromCurrentAreBold() {
        setup(exampleTwo())
        compare_()
        compare(flags(1, 3), [false, true, true])
        compare(flags(2, 3), [false, true, true])
        compare(flags(3, 3), [false, true, true])
        compare(flags(5, 3), [false, false, false], "total weight is 10 everywhere")
        compare(flags(6, 3), [false, true, true])
        compare(flags(7, 3), [false, false, false])
        compare(flags(9, 3), [false, true, true])
        compare(flags(10, 3), [false, true, true])
        compare(flags(11, 3), [false, true, true], "50.00 and 67.50 differ from 50.50")
        compare(cell(6, 1).Accessible.description, "differs from current")
        compare(cell(6, 0).Accessible.description, "")
        compare(cell(7, 1).Accessible.description, "")
        compare(cell(6, 2).Accessible.name, "Average score, Price: 40.8")
        compare(cell(6, 0).Accessible.name, "Average score, Current: 60.2")
        // the Current column alone never carries emphasis
        for (var r = 1; r <= 11; ++r) {
            var t = cell(r, 0)
            if (t) verify(!bold(t), "row " + r)
        }
    }

    function test_inputsThatMatchAreHidden() {
        // Only the speed weight differs: Battery and Price weights equal the defaults.
        setup(harness(example(), {}, [["Speed", {w_perf: {v: 10, u: ""}, w_batt: {v: 3, u: ""}, w_price: {v: 2, u: ""}}]]))
        compare_()
        compare(child("aiCalcScenariosSection_0").text, "Inputs that differ")
        compare(child("aiCalcScenariosLabel_1").text, "Speed weight")
        compare(child("aiCalcScenariosSection_2").text, "Results", "the next row after the single differing input")
        // no differing inputs at all
        setup(harness(example(), {}, [["Same", {}]]))
        tryCompare(child("aiCalcScenariosSection_0"), "text", "All inputs are the same")
        compare(child("aiCalcScenariosSection_1").text, "Results")
    }

    function test_errorScenarioShowsEmDashWithTheCode() {
        var h = harness(errorBlock(), {}, [["Nobody", {n: {v: 0, u: "h"}}]])
        setup(h)
        var zero = Calc.evaluate(h.plan.model, h.scenarios[1].values, null, null)
        var code = zero.nodes.per.err.code
        compare(code, "DIV0", "division by zero is the DIV0 error value")
        verify(h.scenarios[0].result.nodes.per.err === null || h.scenarios[0].result.nodes.per.err === undefined)
        compare_()
        // 0 section, 1 Head count, 2 section, 3 Per head, 4 Total, 5 section, 6-7 the Share column
        compare(child("aiCalcScenariosLabel_1").text, "Hours")
        compare(cellTexts(1, 2), ["4 h", "0 h"], "label + value with its unit")
        compare(child("aiCalcScenariosLabel_3").text, "Per head")
        compare(cell(3, 0).text, "25.0")                              // 100 / 4
        compare(cell(3, 1).text, "\u2014 " + code)
        verify(cell(3, 1).text.charAt(0) === "\u2014")
        compare(cell(3, 1).Accessible.name, "Per head, Nobody: no value, error " + code)
        verify(bold(cell(3, 1)), "an error differs from a value")
        compare(cell(3, 1).Accessible.description, "differs from current")
        compare(cell(3, 0).Accessible.description, "")
        compare(cellTexts(4, 2), ["6", "2"], "an unaffected cell still shows its value")
        verify(!bold(cell(4, 0)) && bold(cell(4, 1)))
        compare(child("aiCalcScenariosLabel_6").text, "A")
        compare(cell(6, 1).text, "\u2014 " + code)
        compare(cell(7, 1).text, "\u2014 " + code)
        compare(cell(6, 0).text.charAt(0) === "\u2014", false)
        // an error in Current and the saved scenario alike: equal error codes are not a difference
        var h2 = harness(errorBlock(), {n: {v: 0, u: "h"}}, [["Nobody", {n: {v: 0, u: "h"}}]])
        setup(h2)
        // no input differs, so: 0 section, 1 section, 2 Per head, 3 Total
        tryCompare(child("aiCalcScenariosSection_0"), "text", "All inputs are the same")
        compare(child("aiCalcScenariosLabel_2").text, "Per head")
        compare(cell(2, 0).text, "\u2014 " + code)
        compare(cell(2, 1).text, "\u2014 " + code)
        verify(!bold(cell(2, 1)), "identical error: not different")
        verify(!bold(cell(3, 1)))
    }

    function test_failedResultShowsNotAvailable() {
        var h = exampleTwo()
        h.scenarios[2].result = null    // an evaluate() that threw
        setup(h)
        compare_()
        compare(cell(9, 2).text, "\u2014 N/A")
        compare(cell(9, 2).Accessible.name, "Air 13, Price: no value, error N/A")
    }

    function test_aLongScenarioNameStaysInsideItsColumn() {
        var longName = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"   // 32 wide letters, no break opportunity
        compare(longName.length, 32)
        setup(harness(example(), {}, [[longName, weights(10, 0, 0)], ["Price", weights(0, 0, 10)]]))
        compare_()
        var head = child("aiCalcScenariosColumn_1")
        compare(head.text, longName)
        compare(head.width, cell(1, 1).width, "the header is exactly as wide as its column")
        verify(head.contentWidth <= head.width + 0.5, "it wraps or elides instead of widening")
        verify(head.lineCount <= 2, "at most two lines, got " + head.lineCount)
        verify(head.height < 3 * head.font.pixelSize * 1.6)
        compare(head.Accessible.name, "Scenario " + longName, "the full name stays available")
        compare(child("aiCalcScenariosItem_0").text, longName)
        verify(child("aiCalcScenariosItem_0").width >= 40)
    }

    // ---- compare: show all / picker / caps ----------------------------------------------------
    // 12 inputs + 24 cells leave room for only 4 table rows under the 40-row cap: say so, and keep Show all honest.
    function test_theRowCapIsDisclosed() {
        setup(bigHarness(20))
        compare_()
        var cut = child("aiCalcScenariosCut")
        verify(cut.visible)
        compare(cut.text, "Showing the first 40 rows.")
        compare(child("aiCalcScenariosSection_38").text, "Big table: Plus second")
        compare(child("aiCalcScenariosLabel_42").text, "Row 3")
        compare(child("aiCalcScenariosLabel_43"), null)
        verify(child("aiCalcScenariosMore") === null || !child("aiCalcScenariosMore").visible, "Show all cannot add rows past the cap")
        // a table that fits the cap shows no disclosure
        setup(rowsHarness(3))
        verify(!child("aiCalcScenariosCut").visible)
    }

    // One input, one saved scenario (a = 6), a table of `tableRows` rows with two formula columns.
    function rowsHarness(tableRows) {
        var rows = []
        for (var r = 0; r < tableRows; ++r) rows.push(["Row " + r, String(r + 1), "", ""])
        var block = {type: "calc", title: "Rows", inputs: [
            {id: "a", label: "A", unit: "", min: 0, max: 10, step: 1, value: 5, basis: "assumption"}],
            cells: [], note: "", tables: [{id: "t", label: "Rows", columns: [
                {id: "name", label: "Name", unit: "", kind: "text", expression: ""},
                {id: "qty", label: "Qty", unit: "", kind: "number", expression: ""},
                {id: "f1", label: "Times A", unit: "", kind: "formula", expression: "qty*a"},
                {id: "f2", label: "Plus A", unit: "", kind: "formula", expression: "qty+a"}], rows: rows}]}
        return harness(block, {}, [["Six", {a: {v: 6, u: ""}}]])
    }

    function test_showAllLiftsTheTwelveRowLimitAndPickerChoosesTheColumn() {
        var h = rowsHarness(20)
        setup(h)
        compare_()
        // 0 section "Inputs that differ", 1 A (5 vs 6), then the table: section + 12 rows, no cells
        compare(child("aiCalcScenariosLabel_1").text, "A")
        compare(cellTexts(1, 2), ["5", "6"])
        compare(child("aiCalcScenariosSection_2").text, "Rows: Plus A", "the last formula column is the default")
        compare(child("aiCalcScenariosLabel_3").text, "Row 0")
        compare(cellTexts(3, 2), ["6.00", "7.00"] )   // qty 1 + a: 1+5, 1+6 (no decimals declared: engine default)
        compare(child("aiCalcScenariosLabel_14").text, "Row 11")
        compare(child("aiCalcScenariosLabel_15"), null, "twelve rows until Show all")
        var more = child("aiCalcScenariosMore")
        verify(more.visible)
        compare(more.text, "Show all rows")
        verify(!child("aiCalcScenariosCut").visible)
        more.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        tryVerify(function() { return child("aiCalcScenariosLabel_22") !== null })
        compare(child("aiCalcScenariosLabel_22").text, "Row 19")
        compare(child("aiCalcScenariosLabel_23"), null)
        compare(more.text, "Show fewer rows")
        keyClick(Qt.Key_Return)
        tryVerify(function() { return child("aiCalcScenariosLabel_15") === null })
        // two formula columns: a picker, default the last, choosing the first swaps the rows
        compare(child("aiCalcScenariosPick_0_0").text, "Times A")
        compare(child("aiCalcScenariosPick_0_1").text, "Plus A")
        verify(!child("aiCalcScenariosPick_0_0").selected && child("aiCalcScenariosPick_0_1").selected)
        mouseClick(child("aiCalcScenariosPick_0_0"), 5, 5)
        tryCompare(child("aiCalcScenariosSection_2"), "text", "Rows: Times A")
        compare(cellTexts(3, 2), ["5.00", "6.00"])   // qty 1 * a
        verify(child("aiCalcScenariosPick_0_0").selected && !child("aiCalcScenariosPick_0_1").selected)
        // a table of 12 rows or fewer needs no Show all
        setup(rowsHarness(12))
        tryVerify(function() { return child("aiCalcScenariosMore") === null || !child("aiCalcScenariosMore").visible })
    }

    // ---- bounds ---------------------------------------------------------------------
    function test_worstCaseStaysUnderTheDelegateBound() {
        setup(bigHarness(40))
        compare_()
        var all = texts().length
        console.log("worst-case Text delegates (12 inputs, 24 cells, 40-row table, 4 columns): " + all)
        verify(all <= 240, "Text delegates " + all)
        verify(child("aiCalcScenariosMore") === null || !child("aiCalcScenariosMore").visible, "the cap leaves nothing to expand")
        // 4 value columns x 40 data rows
        var rows = 0
        for (var r = 0; r < 60; ++r) if (child("aiCalcScenariosLabel_" + r)) ++rows
        compare(rows, 40, "hard cap of 40 data rows")
        compare(child("aiCalcScenariosColumn_3").text, "Three")
        compare(child("aiCalcScenariosColumn_4"), null)
        compare(child("aiCalcScenariosCut").text, "Showing the first 40 rows.")
        // every one of the 12 inputs differs
        compare(child("aiCalcScenariosLabel_12").text, "Input 11")
        compare(child("aiCalcScenariosSection_13").text, "Results")
        compare(child("aiCalcScenariosLabel_14").text, "Cell 0")
        compare(child("aiCalcScenariosLabel_37").text, "Cell 23")
    }

    function test_atMostFourValueColumns() {
        var h = bigHarness(3)
        // a fifth entry (cannot be produced by the real list, but the grid must still cap itself)
        var extra = h.scenarios.slice()
        extra.push({name: "Extra", index: 3, values: h.scenarios[1].values, result: h.scenarios[1].result})
        h.scenarios = extra
        setup(h)
        compare_()
        compare(child("aiCalcScenariosColumn_3").text, "Three")
        compare(child("aiCalcScenariosColumn_4"), null)
        compare(child("aiCalcScenariosToggle").text.indexOf("Scenarios (3)") >= 0, true, "saved count is capped at three")
    }

    // ---- geometry ---------------------------------------------------------------------
    function inside(item, width) {
        var p = item.mapToItem(view, 0, 0)
        return p.x >= -0.5 && p.x + item.width <= width + 0.5
    }
    function checkGeometry(width) {
        view.width = width
        setup(exampleThree())
        waitForRendering(view)
        var collapsedHeight = view.implicitHeight
        view.expanded = true
        view.comparing = true
        tryVerify(function() { return child("aiCalcScenariosScroll") !== null })
        waitForRendering(view)
        var scroll = child("aiCalcScenariosScroll"), open = view.implicitHeight
        verify(open > collapsedHeight)
        var names = ["aiCalcScenariosToggle", "aiCalcScenariosName", "aiCalcScenariosSave", "aiCalcScenariosLoad_0",
            "aiCalcScenariosDelete_0", "aiCalcScenariosLoad_1", "aiCalcScenariosDelete_1", "aiCalcScenariosCompare",
            "aiCalcScenariosScroll", "aiCalcScenariosLegend", "aiCalcScenariosNote", "aiCalcScenariosItem_0"]
        for (var i = 0; i < names.length; ++i) verify(inside(child(names[i]), width), names[i] + " at " + width)
        verify(scroll.width <= width + 0.5)
        var labelW = Math.max(120, Math.round(width * 0.4))
        compare(child("aiCalcScenariosLabel_1").width, labelW, "label column about 40%")
        var content = scroll.contentWidth, fits = labelW + 4 * 80 <= width
        // value columns: four value columns share what is left, never narrower than 80 px
        verify(cell(1, 0).width >= 80 - 0.5)
        if (fits) {
            compare(content, width, "no horizontal scrolling when it fits at " + width)
            verify(!scroll.activeFocusOnTab)
            verify(cell(1, 3).mapToItem(view, 0, 0).x + cell(1, 3).width <= width + 0.5, "last column inside")
        } else {
            verify(content > width)
            verify(scroll.activeFocusOnTab)
        }
        // wrapped text never spills past its own cell
        for (var r = 1; r <= 11; ++r)
            for (var c = 0; c < 4; ++c)
                if (cell(r, c)) verify(cell(r, c).contentWidth <= cell(r, c).width + 0.5, "cell " + r + "," + c)
        // all of the component's content ends at its implicit height
        var note = child("aiCalcScenariosNote")
        verify(note.mapToItem(view, 0, 0).y + note.height <= open + 0.5)
        console.log("scenarios height at width " + width + " (4 value columns): collapsed " + collapsedHeight + ", compare open " + open
            + ", grid " + scroll.height + ", content width " + content)
        return {collapsed: collapsedHeight, open: open, scrolls: !fits}
    }
    function test_fitsTheDetachedWindowAt1000() { verify(!checkGeometry(1000).scrolls) }
    function test_fitsThePeekCardAt660() { verify(!checkGeometry(660).scrolls) }
    function test_scrollsInsideItsOwnAreaAt420() {
        var g = checkGeometry(420)
        verify(g.scrolls, "narrow width scrolls horizontally")
        var scroll = child("aiCalcScenariosScroll")
        scroll.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(scroll, "activeFocus", true)
        compare(child("aiCalcScenariosFocusRing").border.width, 2)
        compare(child("aiCalcScenariosFocusRing").border.color.toString(), view.accent.toString())
        keyClick(Qt.Key_End)
        compare(scroll.contentX, scroll.contentWidth - scroll.width)
        keyClick(Qt.Key_Home)
        compare(scroll.contentX, 0)
        keyClick(Qt.Key_Right)
        verify(scroll.contentX > 0)
    }
    function test_fourValueColumnsFitTheSixSixtyPeekCard() {
        view.width = 660
        setup(bigHarness(3))
        compare_()
        var scroll = child("aiCalcScenariosScroll")
        compare(scroll.contentWidth, scroll.width, "264 + 4 x 99 fits 660 without a scrollbar")
        verify(!scroll.activeFocusOnTab)
        var last = cell(1, 3)
        verify(last.mapToItem(view, 0, 0).x + last.width <= 660.5)
        compare(child("aiCalcScenariosFocusRing").border.width, 0, "no ring until focused")
        console.log("scenarios height at 660 with 4 value columns: " + view.implicitHeight)
    }
    function test_tallerContentGrowsTheImplicitHeightOnly() {
        setup(exampleTwo())
        open()
        var h1 = view.implicitHeight
        view.comparing = true
        tryVerify(function() { return child("aiCalcScenariosScroll") !== null })
        tryVerify(function() { return view.implicitHeight > h1 })
        view.comparing = false
        tryVerify(function() { return child("aiCalcScenariosScroll") === null })
        tryCompare(view, "implicitHeight", h1)
    }

    // ---- contrast ----------------------------------------------------------------------
    function luminance(c) {
        function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
    function contrast(fg, bg) {
        var a = Qt.rgba(fg.r * fg.a + bg.r * (1 - fg.a), fg.g * fg.a + bg.g * (1 - fg.a), fg.b * fg.a + bg.b * (1 - fg.a), 1)
        var l1 = luminance(a), l2 = luminance(bg)
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
    }
    function test_informationalTextMeetsTheContrastFloor() {
        setup(exampleTwo())
        compare_()
        // the Save reason and the compare notes are informational text: >= 0.80
        var expected = Qt.alpha(view.foreground, 0.80).toString()
        var names = ["aiCalcScenariosLegend", "aiCalcScenariosNote"]
        for (var i = 0; i < names.length; ++i) {
            var t = child(names[i])
            verify(t.visible, names[i])
            compare(t.color.toString(), expected, names[i])
            verify(t.color.a >= 0.76)
        }
        compare(child("aiCalcScenariosNote").text, "Table edits apply to all scenarios.")
        compare(child("aiCalcScenariosName").placeholderTextColor.toString(), expected)
        // Save reason (empty name) and the empty hint
        var reason = child("aiCalcScenariosReason")
        verify(reason.visible)
        compare(reason.color.toString(), expected)
        setup(harness(example(), {}, []))
        compare(child("aiCalcScenariosEmpty").color.toString(), expected)
        // every visible Text that is not part of a disabled control is at least 0.80 opaque;
        // grid headers and values are full strength, row labels 0.85
        setup(exampleTwo())
        var low = []
        visibleTexts().forEach(function(t) {
            // a disabled control is exempt (its reason is separate text); everything else is >= 0.80
            if (t.parent && t.parent.enabled === false) return
            if (t.color.a < 0.80 - 1e-6) low.push((t.objectName || t.text) + " " + t.color.a)
        })
        compare(low, [], "no informational text below 0.80")
        // computed ratio on the real surface colours
        var ratio = contrast(Qt.alpha(view.foreground, 0.80), view.background)
        verify(ratio >= 4.5, "0.80 foreground over the surface is " + ratio)
        console.log("contrast of 0.80 foreground on the test surface: " + ratio.toFixed(2))
    }

    function test_disabledButtonsNeverCarryTheOnlyExplanation() {
        setup(harness(example(), {}, []))
        open()
        var save = child("aiCalcScenariosSave")
        verify(!save.enabled)
        verify(child("aiCalcScenariosReason").visible, "the reason is visible text, not only a dimmed button")
        verify(child("aiCalcScenariosReason").color.a >= 0.80)
        var compareButton = child("aiCalcScenariosCompare")
        verify(!compareButton.enabled)
        verify(child("aiCalcScenariosEmpty").visible)
    }

    function test_focusRingIsTwoPixelsOnEveryButton() {
        setup(exampleTwo())
        compare_()
        var names = ["aiCalcScenariosToggle", "aiCalcScenariosLoad_0", "aiCalcScenariosDelete_1", "aiCalcScenariosCompare"]
        for (var i = 0; i < names.length; ++i) {
            var b = child(names[i])
            b.forceActiveFocus(Qt.TabFocusReason)
            tryCompare(b, "visualFocus", true, 1000, names[i])
            compare(b.background.border.width, 2, names[i])
            compare(b.background.border.color.toString(), view.accent.toString(), names[i])
        }
        before.forceActiveFocus()
        compare(child("aiCalcScenariosToggle").background.border.width, 1)
        var field = child("aiCalcScenariosName")
        field.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(field, "activeFocus", true)
        compare(field.background.border.width, 2)
        compare(field.background.border.color.toString(), view.accent.toString())
    }

    // ---- plain text ---------------------------------------------------------------------
    function test_everyStringIsPlainTextAndNamesStayLiteral() {
        var hostile = "<b>x</b>"
        var h = harness(example(), {}, [[hostile, weights(10, 0, 0)], ["&amp; <i>y</i>", weights(0, 0, 10)]])
        setup(h)
        compare_()
        walk(view, function(it) {
            if (isText(it) && it.toString().indexOf("QQuickPlaceholderText") !== 0)
                compare(it.textFormat, Text.PlainText, it.objectName || it.text)
        })
        compare(child("aiCalcScenariosItem_0").text, hostile)
        compare(child("aiCalcScenariosColumn_1").text, hostile)
        compare(child("aiCalcScenariosColumn_2").text, "&amp; <i>y</i>")
        compare(child("aiCalcScenariosItem_0").textFormat, Text.PlainText)
        compare(child("aiCalcScenariosColumn_1").Accessible.name, "Scenario <b>x</b>")
        compare(child("aiCalcScenariosLoad_0").Accessible.name, "Load scenario <b>x</b>")
        compare(cell(6, 1).Accessible.name, "Average score, <b>x</b>: 70.0")
        // the name is passed through verbatim when saving
        var field = setName("<b>x</b>")
        mouseClick(child("aiCalcScenariosSave"), 5, 5)
        compare(saves.signalArguments[0][0], "<b>x</b>")
        compare(child("aiCalcScenariosSave").text, "Save", "setup reset the field after the request")
        // an existing hostile name is a replace
        field = setName("<b>x</b>")
        compare(child("aiCalcScenariosSave").text, "Save (Replaces)")
    }

    function test_theComponentNeverChangesItsInputs() {
        var h = exampleTwo()
        setup(h)
        compare_()
        var before_ = JSON.stringify(view.scenarios.map(function(s) { return [s.name, s.index, s.values] }))
        var list = view.scenarios
        setName("New")
        mouseClick(child("aiCalcScenariosSave"), 5, 5)
        mouseClick(child("aiCalcScenariosLoad_0"), 5, 5)
        mouseClick(child("aiCalcScenariosDelete_1"), 5, 5)
        tryCompare(deletes, "count", 1)
        verify(view.scenarios === list)
        compare(JSON.stringify(view.scenarios.map(function(s) { return [s.name, s.index, s.values] })), before_)
        compare(saves.count + loads.count + deletes.count, 3)
        // switching width and closing keep the signal count
        view.expanded = false
        view.expanded = true
        compare(saves.count + loads.count + deletes.count, 3)
    }

    function test_theOwnerSeesChangesImmediately() {
        setup(exampleTwo())
        compare_()
        compare(cellTexts(6, 3), ["60.2", "70.0", "40.8"])
        // the owner moves a Current input: the grid re-reads the next scenarioResults
        var entry = Edit.compose(weights(0, 0, 10), {}, Edit.saveScenario(Edit.saveScenario([], "Speed", weights(10, 0, 0)).scenarios, "Price", weights(0, 0, 10)).scenarios)
        var plan = View.build(example(), entry)
        view.plan = plan
        view.model = plan.model
        view.scenarios = View.scenarioResults(plan, entry)
        // Battery weight is 0 in all three columns now, so that input row disappears
        tryCompare(child("aiCalcScenariosLabel_5"), "text", "Average score")
        tryCompare(cell(5, 0), "text", "40.8")
        compare(cellTexts(5, 3), ["40.8", "70.0", "40.8"])
        compare(flags(5, 3), [false, true, false], "Price now equals Current")
    }

    // The owner (AiCalc) replaces the whole scenario list from inside a Load click: the button must survive.
    function test_loadHandlerMayReplaceTheScenarioList() {
        var h = exampleTwo()
        setup(h)
        open()
        var load = child("aiCalcScenariosLoad_1")
        var owner = function(index) { setup({plan: h.plan, inputs: h.inputs, scenarios: View.scenarioResults(h.plan, h.entry)}) }
        view.loadRequested.connect(owner)
        load.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        compare(loads.signalArguments[0][0], 1)
        verify(child("aiCalcScenariosLoad_1") === load, "the same delegate is kept")
        tryCompare(load, "activeFocus", true)
        view.loadRequested.disconnect(owner)
    }
}
