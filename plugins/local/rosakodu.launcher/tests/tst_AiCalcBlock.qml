import QtQuick
import QtTest
import ".."
import "../AiCalc.js" as Calc
import "../AiCalcEdit.js" as Edit
import "../AiCalcExport.js" as Export
import "../AiCalcView.js" as View

// AiCalc as one block: the editable grid, scenarios, toolbar, undo/redo and the
// commit pipeline. The host is simulated by the `hostSaved` property that
// `calc.saved` is bound to; `echo` says whether the host applies an emit (true) or
// refuses/lags it (false). Assertions are on emitted states and on what is shown.
TestCase {
    id: tests
    name: "AiCalcBlock"
    width: 800
    height: 1500
    visible: true
    when: windowShown

    property var hostSaved: undefined
    property bool echo: false
    property var blockData: tests.laptops()
    property var calc: null

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    Component {
        id: calcComponent
        AiCalc {
            y: 20
            width: 660
            foreground: "#f1f2f4"
            background: "#1b1c20"
            accent: "#b4c4dc"
        }
    }
    SignalSpy { id: stateSpy; signalName: "stateEdited" }
    SignalSpy { id: copySpy; signalName: "copyRequested" }
    SignalSpy { id: dupSpy; signalName: "duplicateRequested" }
    Connections {
        target: tests.calc
        function onStateEdited(state) { if (tests.echo) tests.hostSaved = JSON.parse(JSON.stringify(state)) }
    }

    // ---- fixtures ---------------------------------------------------------
    function laptops() {
        return JSON.parse('{"type":"calc","title":"Laptop score","inputs":[{"id":"w_perf","label":"Speed weight","unit":"","min":0,"max":10,"step":1,"value":5,"basis":"assumption"},{"id":"w_batt","label":"Battery weight","unit":"","min":0,"max":10,"step":1,"value":3,"basis":"assumption"},{"id":"w_price","label":"Price weight","unit":"","min":0,"max":10,"step":1,"value":2,"basis":"assumption"}],"tables":[{"id":"laptops","label":"Laptops","columns":[{"id":"name","label":"Laptop","unit":"","kind":"text","expression":""},{"id":"perf","label":"Speed (0-10)","unit":"","kind":"number","expression":""},{"id":"batt","label":"Battery","unit":"h","kind":"number","expression":""},{"id":"price","label":"Price","unit":"EUR","kind":"number","expression":""},{"id":"score","label":"Score","unit":"","kind":"formula","expression":"if(wsum==0,0,(w_perf*perf/10+w_batt*batt/20[h]+w_price*clamp(1-price/2000[EUR],0,1))/wsum*100)"}],"rows":[["Air 13","7","15","1100",""],["Pro 14","9","11","1800",""],["Budget 15","5","8","650",""]]}],"cells":[{"id":"wsum","label":"Total weight","expression":"w_perf+w_batt+w_price","unit":"","decimals":0,"note":""},{"id":"mean_score","label":"Average score","expression":"mean(laptops.score)","unit":"","decimals":1,"note":""},{"id":"avg_price","label":"Average price","expression":"mean(laptops.price)","unit":"EUR","decimals":0,"note":""}],"note":"Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."}')
    }
    // A fresh component per call, as a new turn gets one (the local entry is part of its state).
    function reset(echo, saved, block) {
        if (tests.calc) { tests.calc.destroy(); tests.calc = null }
        tests.echo = echo === true
        tests.blockData = block || tests.laptops()
        tests.hostSaved = saved
        var made = calcComponent.createObject(tests, {block: tests.blockData, saved: tests.hostSaved})
        made.block = Qt.binding(function () { return tests.blockData })
        made.saved = Qt.binding(function () { return tests.hostSaved })
        tests.calc = made
        stateSpy.target = made; copySpy.target = made; dupSpy.target = made
        stateSpy.clear(); copySpy.clear(); dupSpy.clear()
        waitForRendering(made)
    }
    function init() { reset(false, undefined) }
    function cleanup() { if (tests.calc) { tests.calc.destroy(); tests.calc = null } }

    function child(name) { return findChild(calc, name) }
    function grid(i) { return findChild(calc, "aiCalcGrid_" + (i || 0)) }
    function gridPart(name, i) { return findChild(grid(i), name) }
    function cellText(r, c) { return gridPart("aiCalcGridCell_" + r + "_" + c).text }
    function canon(v) { return calc.canonical(JSON.parse(JSON.stringify(v))) }
    function last() { return stateSpy.signalArguments[stateSpy.count - 1][0] }
    function focusGrid() {
        var s = gridPart("aiCalcGridScroll")
        s.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(s, "activeFocus", true)
    }
    function go(r, c) {
        focusGrid()
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        for (var i = 0; i < r; ++i) keyClick(Qt.Key_Down)
        for (i = 0; i < c; ++i) keyClick(Qt.Key_Right)
    }
    function typeCell(r, c, text) {
        go(r, c)
        keyClick(Qt.Key_Return)
        gridPart("aiCalcGridEditor").selectAll()
        for (var i = 0; i < text.length; ++i) keyClick(text.charAt(i))
        keyClick(Qt.Key_Return)
    }
    function slide(i, key) {
        var s = child("aiCalcSlider_" + i)
        s.forceActiveFocus(Qt.TabFocusReason)
        keyClick(key)
    }
    function click(name) { var b = child(name); verify(b !== null, name); verify(b.enabled, name + " enabled"); b.clicked() }
    function openScenarios() {
        var t = child("aiCalcScenariosToggle")
        if (child("aiCalcScenariosName") === null) t.clicked()
        tryVerify(function () { return child("aiCalcScenariosName") !== null })
    }
    function saveScenario(name) {
        openScenarios()
        var f = child("aiCalcScenariosName")
        f.forceActiveFocus(Qt.TabFocusReason)
        for (var i = 0; i < name.length; ++i) keyClick(name.charAt(i))
        keyClick(Qt.Key_Return)
    }
    function walk(item, out) {
        if (!item || out.indexOf(item) >= 0) return out
        out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) walk(kids[i], out)
        if (item.contentItem) walk(item.contentItem, out)
        return out
    }
    function jsonBytes(v) { return Edit.sizeOf(v) }

    // ---- editing through the grid -------------------------------------------
    function test_aGridEditEmitsExactlyOneStateWithTheData() {
        compare(cellText(0, 1), "7")
        compare(cellText(0, 4), "66.50")
        typeCell(0, 1, "8")
        compare(stateSpy.count, 1)
        var want = Edit.compose({}, Edit.setCell({}, tests.blockData, "laptops", "0", "perf", "8").data, [])
        compare(canon(last()), canon(want))
        compare(JSON.stringify(Object.keys(last())), '["_d"]')
        compare(cellText(0, 1), "8", "the edited value is shown at once (the host has not answered)")
        compare(cellText(0, 4), "71.50", "the calculated column follows: (5*8/10+3*15/20+2*0.45)/10*100")
        compare(calc.editedCount, 1)
        verify(gridPart("aiCalcGridEdited_0_1").visible)
        // typing the authored value back removes the edit entirely
        typeCell(0, 1, "7")
        compare(stateSpy.count, 2)
        compare(canon(last()), "{}")
        compare(calc.editedCount, 0)
    }
    function test_invalidValueEmitsNothing() {
        go(0, 2)
        keyClick("x")
        keyClick(Qt.Key_Return)
        compare(stateSpy.count, 0)
        verify(gridPart("aiCalcGridEditor").visible, "the editor stays open")
        compare(gridPart("aiCalcGridMessage").text, Edit.parseCell("x", "number").msg)
        keyClick(Qt.Key_Escape)
        compare(stateSpy.count, 0)
        compare(cellText(0, 2), "15")
        compare(calc.undoStack.length, 0, "no history for a refused value")
        // clearing a number cell with Delete is an edit too (the empty cell is an engine error value)
        go(1, 2)
        keyClick(Qt.Key_Delete)
        compare(stateSpy.count, 1)
        compare(canon(last()._d), canon({laptops: {e: {"1|batt": ""}}}))
    }
    function test_addAndRemoveRows() {
        click("aiCalcGridAdd")
        compare(stateSpy.count, 1)
        compare(canon(last()._d), canon({laptops: {a: ["n1"], n: 2}}))
        compare(grid(0).rowTotal, 4)
        compare(calc.plan.tables[0].rowIds.join(","), "0,1,2,n1")
        typeCell(3, 0, "Fresh")
        compare(canon(last()._d.laptops.e), canon({"n1|name": "Fresh"}))
        go(1, 0)
        click("aiCalcGridRemove")       // grid(0) clicks work through the same signal
        compare(stateSpy.count, 3)
        compare(canon(last()._d.laptops.x), canon(["1"]))
        compare(grid(0).rowTotal, 3)
        compare(calc.plan.tables[0].rowIds.join(","), "0,2,n1")
        compare(cellText(1, 0), "Budget 15")
        compare(calc.editedCount, 2, "one edited cell is gone with its row; the added row and the removed row count")
    }
    function test_addIsBlockedWithAReason() {
        // 37 rows already added -> 40 effective rows
        for (var i = 0; i < 37; ++i) calc.addRow("laptops")
        compare(calc.plan.tables[0].rows.length, 40)
        var add = gridPart("aiCalcGridAdd")
        verify(!add.enabled)
        verify(gridPart("aiCalcGridBlockedReason").visible)
        compare(gridPart("aiCalcGridBlockedReason").text, "This table already has 40 rows.")
        var n = stateSpy.count
        calc.addRow("laptops")
        compare(stateSpy.count, n, "a refused add emits nothing")
    }
    function test_discardEditsKeepsInputs() {
        slide(0, Qt.Key_Right)
        typeCell(0, 1, "9")
        click("aiCalcGridAdd")
        compare(child("aiCalcDiscard").text, "Discard my edits (2)")
        stateSpy.clear()
        click("aiCalcDiscard")
        compare(stateSpy.count, 1)
        compare(canon(last()), canon({w_perf: {v: 6, u: ""}}))
        verify(!child("aiCalcDiscard").visible, "hidden at zero")
        compare(cellText(0, 1), "7")
        compare(calc.undoStack.length, 4)
    }
    function test_resetToDefaultsIsInputsOnly() {
        typeCell(0, 1, "9")
        verify(!child("aiCalcReset").enabled, "a table edit alone is not an input change")
        slide(1, Qt.Key_End)
        verify(child("aiCalcReset").enabled)
        stateSpy.clear()
        click("aiCalcReset")
        compare(canon(last()), canon({_d: {laptops: {e: {"0|perf": "9"}}}}))
        verify(!child("aiCalcReset").enabled)
        compare(calc.current.w_batt, 3)
    }

    // ---- scenarios -----------------------------------------------------------
    function test_scenarioSaveLoadDeleteRoundtrip() {
        slide(0, Qt.Key_Home)        // w_perf 0
        stateSpy.clear()
        saveScenario("Price first")
        compare(stateSpy.count, 1)
        compare(canon(last()), canon({w_perf: {v: 0, u: ""}, _s: [{n: "Price first", v: {w_perf: {v: 0, u: ""}}}]}))
        compare(child("aiCalcScenariosToggle").text.indexOf("Scenarios (1)") >= 0, true)
        slide(0, Qt.Key_End)
        slide(1, Qt.Key_Home)
        compare(calc.current.w_perf, 10)
        stateSpy.clear()
        child("aiCalcScenariosLoad_0").clicked()
        compare(stateSpy.count, 1)
        compare(canon(last().w_perf), canon({v: 0, u: ""}))
        verify(last().w_batt === undefined, "loading sets the inputs part: unlisted inputs go back to defaults")
        compare(calc.current.w_batt, 3)
        compare(calc.current.w_perf, 0)
        verify(last()._s.length === 1)
        // the compare view shows Current next to the scenario
        child("aiCalcScenariosCompare").clicked()
        tryVerify(function () { return child("aiCalcScenariosCompareView") !== null })
        compare(child("aiCalcScenariosNote").text, "Table edits apply to all scenarios.")
        compare(child("aiCalcScenariosColumn_0").text, "Current")
        compare(child("aiCalcScenariosColumn_1").text, "Price first")
        // delete (the component emits from the next event-loop turn)
        stateSpy.clear()
        child("aiCalcScenariosDelete_0").clicked()
        tryCompare(stateSpy, "count", 1)
        verify(last()._s === undefined)
        compare(canon(last()), canon({w_perf: {v: 0, u: ""}}))
        compare(child("aiCalcScenariosToggle").text.indexOf("Scenarios (0)") >= 0, true)
    }
    function test_tableEditsApplyToAllScenarios() {
        slide(0, Qt.Key_Home)
        saveScenario("Zero")
        slide(0, Qt.Key_End)
        typeCell(0, 1, "10")
        child("aiCalcScenariosCompare").clicked()
        tryVerify(function () { return child("aiCalcScenariosCompareView") !== null })
        var s = calc.scenarioList
        compare(s.length, 2)
        // both columns were computed on the edited table: Air 13 now has speed 10.
        // Current 10/3/2: (10 + 3*15/20 + 2*0.45)/15*100 = 87.67; "Zero" 0/3/2: (2.25 + 0.9)/5*100 = 63.00
        compare(Calc.formatCell(calc.plan.model, s[0].result, "laptops.score#1"), "87.67")
        compare(Calc.formatCell(calc.plan.model, s[1].result, "laptops.score#1"), "63.00")
        compare(canon(last()._s), canon([{n: "Zero", v: {w_perf: {v: 0, u: ""}}}]), "scenarios stay input sets only")
    }

    // ---- undo / redo -----------------------------------------------------------
    function test_undoRedoEveryActionKind() {
        reset(true, undefined)
        var steps = [], snaps = [calc.canonical(calc.entry)]
        function after(label) { snaps.push(calc.canonical(calc.entry)); steps.push(label); verify(snaps[snaps.length - 1] !== snaps[snaps.length - 2], label + " changed the state") }
        slide(0, Qt.Key_Right); after("input")
        typeCell(0, 1, "9"); after("cell")
        click("aiCalcGridAdd"); after("add row")
        go(1, 0); click("aiCalcGridRemove"); after("remove row")
        saveScenario("S1"); after("scenario save")
        slide(1, Qt.Key_Home); after("input 2")
        child("aiCalcScenariosLoad_0").clicked(); after("scenario load")
        child("aiCalcScenariosDelete_0").clicked(); tryVerify(function () { return calc.restored.scenarios.length === 0 }); after("scenario delete")
        click("aiCalcReset"); after("reset")
        click("aiCalcDiscard"); after("discard")
        compare(steps.length, 10)
        compare(calc.undoStack.length, 10)
        for (var i = 9; i >= 0; --i) {
            click("aiCalcUndo")
            compare(calc.canonical(calc.entry), snaps[i], "undo of " + steps[i])
            compare(canon(last()), snaps[i], "undo emits the snapshot of " + steps[i])
            compare(calc.canonical(calc.normalize(tests.hostSaved)), snaps[i], "and the host holds it")
        }
        verify(!child("aiCalcUndo").enabled)
        compare(calc.redoStack.length, 10)
        for (i = 1; i <= 10; ++i) {
            click("aiCalcRedo")
            compare(calc.canonical(calc.entry), snaps[i], "redo of " + steps[i - 1])
        }
        verify(!child("aiCalcRedo").enabled)
        compare(calc.undoStack.length, 10, "an echo of our own emits keeps the history")
        // a new edit clears redo
        click("aiCalcUndo"); click("aiCalcUndo")
        compare(calc.redoStack.length, 2)
        typeCell(1, 1, "3")
        compare(calc.redoStack.length, 0)
    }
    function test_sliderDragAndRepeatedKeysCoalesce() {
        slide(0, Qt.Key_Right)
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right); keyClick(Qt.Key_End)
        compare(stateSpy.count, 4, "every step is still emitted")
        compare(calc.undoStack.length, 1, "but they are ONE history entry")
        slide(1, Qt.Key_Right)
        compare(calc.undoStack.length, 2, "another input is a new entry")
        slide(1, Qt.Key_Right)
        compare(calc.undoStack.length, 2)
        wait(650)
        slide(1, Qt.Key_Right)
        compare(calc.undoStack.length, 3, "after 600 ms of quiet it is a new entry")
        click("aiCalcUndo")
        compare(calc.current.w_batt, 5, "undo steps back over the whole coalesced run")
        click("aiCalcUndo")
        compare(calc.current.w_perf, 10)
        compare(calc.current.w_batt, 3)
        click("aiCalcUndo")
        compare(calc.current.w_perf, 5)
        compare(canon(calc.entry), "{}")
    }
    function test_historyIsBoundedByCount() {
        for (var i = 1; i <= 35; ++i) calc.editCell("laptops", "0", "perf", String(i))
        compare(stateSpy.count, 35)
        compare(calc.undoStack.length, 30)
        for (i = 0; i < 30; ++i) calc.undo()
        compare(canon(last()._d.laptops.e["0|perf"]), canon("5"), "the oldest 5 states were dropped")
        compare(calc.undoStack.length, 0)
        compare(calc.redoStack.length, 30)
    }
    function test_historyIsBoundedByBytesAndTooLargeIsRefused() {
        for (var i = 0; i < 37; ++i) calc.addRow("laptops")
        var junk = "x".repeat(64), refused = -1, id = 0
        var ids = calc.plan.tables[0].rowIds
        for (var k = 0; k < ids.length && refused < 0; ++k) {
            for (var c = 0; c < 4 && refused < 0; ++c) {
                var col = ["name", "perf", "batt", "price"][c]
                var v = c === 0 ? junk : "0." + "1".repeat(60)
                var n = stateSpy.count
                calc.editCell("laptops", ids[k], col, v)
                if (stateSpy.count === n) refused = k * 4 + c
            }
        }
        verify(refused > 0, "the 10 KiB cap refuses an edit")
        verify(child("aiCalcTooLarge").visible)
        verify(child("aiCalcTooLarge").text.indexOf("Too many edits to keep") === 0)
        verify(jsonBytes(last()) <= 10240)
        var lastEmit = stateSpy.count
        calc.editCell("laptops", "0", "name", junk + "y".substring(0, 0))   // still too large: nothing emitted
        compare(stateSpy.count, lastEmit)
        var total = 0
        for (var u = 0; u < calc.undoStack.length; ++u) total += Edit.utf8Bytes(calc.undoStack[u])
        verify(total <= 102400, "history bytes " + total)
        verify(calc.undoStack.length < 30, "the 100 KiB budget bites before 30 entries: " + calc.undoStack.length)
        verify(calc.undoStack.length >= 10)
        // a smaller action works again and clears the message
        calc.discardEdits()
        verify(!child("aiCalcTooLarge").visible)
    }
    // An entry a few bytes under the 10 KiB cap, built with the edit API.
    function nearlyFull() {
        var b = tests.laptops(), data = {}, ids = ["0", "1", "2"], cols = ["name", "perf", "batt", "price"], n = 0
        for (var i = 0; i < 1000; ++i) {
            var r = Edit.addRow(data, b, "laptops")
            if (!r.ok) break
            data = r.data; ids.push(r.rowId)
        }
        for (var k = 0; k < ids.length * 4; ++k) {
            var text = k % 4 === 0 ? "x".repeat(64) : "0." + "1".repeat(60)
            var e = Edit.setCell(data, b, "laptops", ids[Math.floor(k / 4)], cols[k % 4], text)
            if (Edit.sizeOf(Edit.compose({}, e.data, [])) > 10240 - 4) break
            data = e.data
        }
        for (var len = 60; len >= 1; --len) {
            var try1 = Edit.setCell(data, b, "laptops", ids[ids.length - 1], "name", "y".repeat(len))
            var sz = Edit.sizeOf(Edit.compose({}, try1.data, []))
            if (try1.ok && sz <= 10240 - 3) return Edit.compose({}, try1.data, [])
        }
        return Edit.compose({}, data, [])
    }
    function test_aRefusedActionResyncsTheControlsAndSaysSo() {
        var big = nearlyFull()
        verify(Edit.sizeOf(big) > 10200 && Edit.sizeOf(big) <= 10240, "fixture size " + Edit.sizeOf(big))
        reset(false, big)
        verify(!child("aiCalcRestoreNote").visible, "the near-full entry is itself valid")
        slide(0, Qt.Key_Right)
        compare(stateSpy.count, 0, "refused: nothing is emitted")
        verify(child("aiCalcTooLarge").visible)
        compare(calc.current.w_perf, 5)
        compare(child("aiCalcSlider_0").value, 5, "the handle snaps back to the kept value")
        compare(child("aiCalcField_0").text, "5")
        compare(calc.undoStack.length, 0, "and no history entry")
        // discarding makes room: the next action works and the message goes
        click("aiCalcDiscard")
        verify(!child("aiCalcTooLarge").visible)
        compare(stateSpy.count, 1)
    }
    function test_toolbarKeepsKeyboardFocusWhenAButtonDisables() {
        slide(0, Qt.Key_Right)
        var undo = child("aiCalcUndo")
        undo.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        verify(!undo.enabled)
        verify(child("aiCalcRedo").enabled)
        verify(child("aiCalcRedo").activeFocus, "focus moved to the nearest working button")
        keyClick(Qt.Key_Space)
        verify(!child("aiCalcRedo").enabled)
        verify(child("aiCalcUndo").enabled)
        verify(child("aiCalcUndo").activeFocus || child("aiCalcReset").activeFocus)
        compare(calc.current.w_perf, 6)
    }
    function test_externalChangeClearsHistoryAndIsAdopted() {
        reset(true, undefined)
        slide(0, Qt.Key_Right)
        typeCell(0, 1, "9")
        compare(calc.undoStack.length, 2)
        // another surface writes a different state
        tests.hostSaved = {w_batt: {v: 8, u: ""}}
        compare(calc.undoStack.length, 0)
        compare(calc.redoStack.length, 0)
        verify(!child("aiCalcUndo").enabled)
        compare(calc.current.w_batt, 8)
        compare(calc.current.w_perf, 5)
        compare(cellText(0, 1), "7")
        stateSpy.clear()
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(stateSpy.count, 0, "nothing left to undo, nothing clobbered")
    }
    function test_aHostThatRefusesNeverMakesTheViewLie() {
        reset(false, undefined)
        slide(0, Qt.Key_Right)
        typeCell(0, 1, "9")
        compare(stateSpy.count, 2)
        compare(calc.current.w_perf, 6, "the display keeps the local state")
        compare(cellText(0, 1), "9")
        compare(tests.hostSaved, undefined)
        // the host catches up with the FIRST emit only, later the second: both are echoes
        tests.hostSaved = JSON.parse(JSON.stringify(stateSpy.signalArguments[0][0]))
        compare(calc.undoStack.length, 2)
        compare(cellText(0, 1), "9", "an older echo does not roll the display back")
        tests.hostSaved = JSON.parse(JSON.stringify(stateSpy.signalArguments[1][0]))
        compare(calc.undoStack.length, 2)
        // the next emit still carries the whole entry
        slide(2, Qt.Key_Right)
        compare(canon(last()), canon({w_perf: {v: 6, u: ""}, w_price: {v: 3, u: ""}, _d: {laptops: {e: {"0|perf": "9"}}}}))
    }
    function test_ctrlZOnlyUndoesOutsideTextEditors() {
        typeCell(0, 1, "9")
        typeCell(0, 2, "12")
        compare(calc.undoStack.length, 2)
        // inside the grid editor Ctrl+Z is the text field's own undo
        stateSpy.clear()
        go(1, 1)
        keyClick("4")
        verify(gridPart("aiCalcGridEditor").visible)
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(calc.undoStack.length, 2)
        compare(stateSpy.count, 0)
        keyClick(Qt.Key_Escape)
        // a number field of the block, too
        var field = child("aiCalcField_0")
        field.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Z, Qt.ControlModifier)      // nothing for the field itself to undo
        compare(calc.undoStack.length, 2, "an idle text field does not hand Ctrl+Z to the block")
        compare(stateSpy.count, 0)
        field.selectAll()
        keyClick("7")
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(calc.undoStack.length, 2)
        compare(stateSpy.count, 0)
        field.sync()
        // navigation mode: Ctrl+Z undoes, Ctrl+Shift+Z and Ctrl+Y redo
        focusGrid()
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        compare(calc.undoStack.length, 1)
        compare(canon(last()._d.laptops.e), canon({"0|perf": "9"}))
        keyClick(Qt.Key_Z, Qt.ControlModifier | Qt.ShiftModifier)
        compare(calc.undoStack.length, 2)
        keyClick(Qt.Key_Z, Qt.ControlModifier)
        keyClick(Qt.Key_Y, Qt.ControlModifier)
        compare(calc.undoStack.length, 2)
        compare(cellText(0, 2), "12")
        // the toolbar buttons describe the lifetime of the history
        compare(child("aiCalcUndo").Accessible.description, "Undo is kept while this view is open.")
    }

    // ---- export ------------------------------------------------------------
    function test_copyAsCsvEqualsTheExportForTheSameView() {
        typeCell(0, 1, "9")
        slide(0, Qt.Key_Right)
        click("aiCalcCopy")
        compare(copySpy.count, 1)
        var run = View.run(tests.blockData, calc.entry)
        var view = Export.viewFromRun(tests.blockData, run.plan, run.result, {values: run.current})
        compare(copySpy.signalArguments[0][0], Export.csv(tests.blockData, view))
        verify(copySpy.signalArguments[0][0].length <= 65536)
        verify(copySpy.signalArguments[0][0].indexOf("Laptop score") >= 0)
        compare(stateSpy.count, 2, "copying changes nothing")
        // with saved scenarios the CSV carries the comparison
        saveScenario("Speed")
        copySpy.clear()
        click("aiCalcCopy")
        verify(copySpy.signalArguments[0][0].indexOf("Scenarios") >= 0)
        verify(copySpy.signalArguments[0][0].indexOf("Speed") >= 0)
    }
    function test_duplicateEmitsTheBakedBlock() {
        typeCell(0, 1, "9")
        slide(0, Qt.Key_End)
        saveScenario("Max")
        click("aiCalcDuplicate")
        compare(dupSpy.count, 1)
        var want = Edit.bake(tests.blockData, calc.entry)
        compare(canon(dupSpy.signalArguments[0][0]), canon(want))
        compare(dupSpy.signalArguments[0][0].block.title, "Copy of Laptop score")
        compare(dupSpy.signalArguments[0][0].block.tables[0].rows[0][1], "9")
        compare(dupSpy.signalArguments[0][0].block.inputs[0].value, 10)
        compare(stateSpy.count, 3, "duplicating changes nothing")
        // an unbuildable block offers no toolbar
        tests.blockData = {type: "calc", title: "Broken", inputs: [], tables: [], cells: [{id: "x", label: "X", expression: "frob(1)", unit: "", decimals: 0, note: ""}], note: ""}
        waitForRendering(calc)
        compare(child("aiCalcDuplicate"), null)
        calc.duplicate()
        compare(dupSpy.count, 1)
    }

    // ---- restore -------------------------------------------------------------
    function test_staleOrTamperedDataResetsWithTheNote() {
        var cases = [
            {_d: {laptops: {e: {"9|perf": "5"}}}},
            {_d: {laptops: {e: {"0|perf": "abc"}}}},
            {_d: {ghost: {a: ["n1"], n: 2}}},
            {_d: 7},
            {_s: [{n: "Bad", v: {ghost: {v: 1, u: ""}}}]},
            {_s: [{n: "Big", v: {w_perf: {v: 99, u: ""}}}]},
            {_s: "nope"}]
        for (var i = 0; i < cases.length; ++i) {
            reset(false, cases[i])
            verify(child("aiCalcRestoreNote").visible, "case " + i)
            compare(child("aiCalcRestoreNote").text, "Some saved values no longer match this calculation and were reset.")
            compare(cellText(0, 1), "7", "case " + i + " shows the authored data")
            compare(calc.editedCount, 0)
        }
        // a partly valid record applies what is valid and says so
        reset(false, {_d: {laptops: {x: ["0", "0"]}}})
        verify(child("aiCalcRestoreNote").visible)
        compare(calc.plan.tables[0].rows.length, 2)
        compare(cellText(0, 0), "Pro 14")
        // a good one shows no note, and the first edit rewrites the entry without the bad parts
        reset(false, {w_perf: {v: 6, u: ""}, _d: {laptops: {e: {"0|perf": "8"}, x: ["5"]}}})
        verify(child("aiCalcRestoreNote").visible)
        compare(cellText(0, 1), "8", "the valid part of the data still applies")
        slide(1, Qt.Key_Right)
        compare(canon(last()), canon({w_perf: {v: 6, u: ""}, w_batt: {v: 4, u: ""}, _d: {laptops: {e: {"0|perf": "8"}}}}))
        verify(!child("aiCalcRestoreNote").visible)
        // restoring good data
        reset(false, {_d: {laptops: {e: {"1|price": "700"}}}, _s: [{n: "Even", v: {w_perf: {v: 4, u: ""}}}]})
        verify(!child("aiCalcRestoreNote").visible)
        compare(cellText(1, 3), "700")
        compare(child("aiCalcScenariosToggle").text.indexOf("Scenarios (1)") >= 0, true)
        compare(gridPart("aiCalcGridCell_1_3").font.weight, Font.Bold, "edited cells are bold")
    }
    function test_sliderMovesDoNotRecompile() {
        var plan = calc.plan, builds = calc.meter.builds
        verify(builds >= 1)
        slide(0, Qt.Key_Right); slide(1, Qt.Key_End); click("aiCalcReset")
        saveScenario("One")
        verify(calc.plan === plan, "same plan object")
        compare(calc.meter.builds, builds, "no compile for inputs, reset or scenarios")
        typeCell(0, 1, "9")
        compare(calc.meter.builds, builds + 1, "a table edit compiles once")
        click("aiCalcUndo")
        compare(calc.meter.builds, builds + 2)
    }
    function test_blockChangeStartsFresh() {
        slide(0, Qt.Key_Right)
        compare(calc.undoStack.length, 1)
        tests.blockData = tests.laptops()
        compare(calc.undoStack.length, 0)
    }

    // ---- layout ----------------------------------------------------------------
    function threeScenarios() {
        return {w_perf: {v: 3, u: ""}, _s: [
            {n: "Speed", v: {w_perf: {v: 10, u: ""}, w_batt: {v: 0, u: ""}}},
            {n: "Battery", v: {w_perf: {v: 1, u: ""}, w_batt: {v: 10, u: ""}}},
            {n: "Price", v: {w_price: {v: 10, u: ""}}}]}
    }
    function test_widthsHaveNoHorizontalOverflowAndTheToolbarWraps() {
        reset(false, threeScenarios())
        compare(calc.restored.scenarios.length, 3)
        var closed = {}
        for (var cw = 0; cw < 2; ++cw) {
            calc.width = cw === 0 ? 420 : 760
            waitForRendering(calc)
            wait(50)
            closed[calc.width] = calc.implicitHeight
        }
        console.log("calc block heights, 3-row table + 3 saved scenarios, scenarios collapsed: 420px=" + closed[420] + " 760px=" + closed[760])
        child("aiCalcScenariosToggle").clicked()
        tryVerify(function () { return child("aiCalcScenariosCompare") !== null })
        child("aiCalcScenariosCompare").clicked()
        tryVerify(function () { return child("aiCalcScenariosCompareView") !== null })
        typeCell(0, 1, "9")
        var heights = {}
        var widths = [420, 760]
        for (var w = 0; w < widths.length; ++w) {
            calc.width = widths[w]
            waitForRendering(calc)
            wait(50)
            heights[widths[w]] = calc.implicitHeight
            verify(calc.childrenRect.width <= calc.width + 0.5, "content within " + widths[w])
            var tb = child("aiCalcToolbar"), rows = {}
            var kids = tb.children
            for (var k = 0; k < kids.length; ++k) if (kids[k].visible && kids[k].width > 0) rows[Math.round(kids[k].y)] = true
            if (w === 0) verify(Object.keys(rows).length >= 2, "the toolbar wraps at 420")
            else compare(Object.keys(rows).length, 1, "and fits one line at 760")
            var all = walk(calc, [])
            for (var i = 0; i < all.length; ++i) {
                var t = all[i]
                if (t.text === undefined || t.textFormat === undefined || !t.visible || t.width === undefined || t.text.length === 0) continue
                var scrolled = false
                for (var p = t.parent; p && p !== calc; p = p.parent)
                    if (p.objectName === "aiCalcGridScroll" || p.objectName === "aiCalcScenariosScroll") scrolled = true
                if (scrolled) continue
                var pos = t.mapToItem(calc, 0, 0)
                verify(pos.x + t.width <= widths[w] + 1, (t.objectName || t.text) + " overflows at " + widths[w])
            }
            // bounded delegates: grid <= 40x12 cells + 1 editor, compare <= ~240
            var cells = 0, texts = 0, edits = 0
            for (i = 0; i < all.length; ++i) {
                if (all[i].objectName && all[i].objectName.indexOf("aiCalcGridCell_") === 0) ++cells
                if (all[i].objectName && all[i].objectName === "aiCalcGridEditor") ++edits
                if (all[i].objectName && all[i].objectName.indexOf("aiCalcScenariosCell_") === 0) ++texts
            }
            verify(cells <= 480 && edits === 1 && texts <= 240, "delegates " + cells + "/" + edits + "/" + texts)
        }
        verify(heights[420] > heights[760], "narrower is taller: " + heights[420] + " vs " + heights[760])
        console.log("calc block heights, 3-row table + 3 scenarios open + compare open: 420px=" + heights[420] + " 760px=" + heights[760])
    }
    function test_everyVisibleEnabledTextMeetsTheContrastFloor() {
        reset(false, threeScenarios())
        child("aiCalcScenariosToggle").clicked()
        tryVerify(function () { return child("aiCalcScenariosCompare") !== null })
        child("aiCalcScenariosCompare").clicked()
        typeCell(0, 1, "9")
        click("aiCalcProvToggle_0")
        var all = walk(calc, []), checked = 0
        for (var i = 0; i < all.length; ++i) {
            var t = all[i]
            if (t.text === undefined || t.textFormat === undefined || !t.visible || !t.enabled || t.text.length === 0 || t.color === undefined) continue
            verify(t.color.a >= 0.76, (t.objectName || t.text) + " alpha " + t.color.a)
            ++checked
        }
        verify(checked > 40, "texts checked: " + checked)
    }
    function test_tabOrderFollowsTheReadingOrder() {
        slide(0, Qt.Key_Right)
        typeCell(0, 1, "9")
        var cur = child("aiCalcSlider_0"), order = []
        cur.forceActiveFocus(Qt.TabFocusReason)
        for (var i = 0; i < 40 && cur; ++i) {
            if (cur.objectName.indexOf("aiCalc") === 0 && order.indexOf(cur.objectName) < 0) order.push(cur.objectName)
            cur = cur.nextItemInFocusChain(true)
        }
        compare(order.join(","), ["aiCalcSlider_0", "aiCalcField_0", "aiCalcSlider_1", "aiCalcField_1", "aiCalcSlider_2", "aiCalcField_2",
            "aiCalcReset", "aiCalcUndo", "aiCalcDiscard", "aiCalcCopy", "aiCalcDuplicate",
            "aiCalcProvToggle_0", "aiCalcProvToggle_1", "aiCalcProvToggle_2",
            "aiCalcGridScroll", "aiCalcGridAdd", "aiCalcGridRemove", "aiCalcScenariosToggle"].join(","))
        verify(child("aiCalcGridScroll").activeFocusOnTab)
        verify(!gridPart("aiCalcGridEditor").activeFocusOnTab)
    }
}
