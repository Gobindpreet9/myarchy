import QtQuick
import QtTest
import ".."
import "../AiCalc.js" as Calc
import "../AiCalcEdit.js" as Edit
import "../AiCalcView.js" as View

// The editable calc table grid. The component never mutates data, so the
// fixtures are real engine output (AiCalcView.run) handed in as plain props and
// every assertion is on what the grid DISPLAYS or EMITS.
TestCase {
    id: tests
    name: "AiCalcGrid"
    width: 800
    height: 900
    visible: true
    when: windowShown

    property var fx: tests.itemsFixture()

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    AiCalcGrid {
        id: grid
        y: 20
        width: 420
        table: tests.fx.table
        nodes: tests.fx.nodes
        formatText: tests.fx.formatText
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
    }
    Item { id: after; y: 880; activeFocusOnTab: true; width: 10; height: 10 }

    SignalSpy { id: commitSpy; target: grid; signalName: "cellCommitted" }
    SignalSpy { id: clearSpy; target: grid; signalName: "clearRequested" }
    SignalSpy { id: addSpy; target: grid; signalName: "addRowRequested" }
    SignalSpy { id: removeSpy; target: grid; signalName: "removeRowRequested" }

    // ---- fixtures -------------------------------------------------------
    // Items / Price (EUR) / Qty / Total (calculated), rows ids 0,1,2 and an added n1.
    function build(columns, rows, rowIds) {
        var block = {inputs: [], cells: [], note: "", tables: [{id: "t", label: "Order", columns: columns, rows: rows}]}
        var run = View.run(block, undefined)
        verify(run.plan !== null, "fixture compiles")
        var plan = run.plan, tb = plan.tables[0], res = run.result
        return {
            table: {id: tb.id, label: tb.label, columns: tb.cols, rows: tb.rows, rowIds: rowIds || tb.rowIds},
            nodes: res.nodes,
            formatText: function (id) { return Calc.formatCell(plan.model, res, id) }
        }
    }
    function itemsFixture() {
        return build([
            {id: "item", label: "Item", kind: "text", unit: "", expression: ""},
            {id: "price", label: "Price", kind: "number", unit: "EUR", expression: ""},
            {id: "qty", label: "Qty", kind: "number", unit: "", expression: ""},
            {id: "total", label: "Total", kind: "formula", unit: "EUR", expression: "price*qty"}
        ], [["Chair", "1800", "2", ""], ["Desk", "250.5", "1", ""], ["Lamp", "40", "3", ""], ["", "", "", ""]],
            ["0", "1", "2", "n1"])
    }
    function wideFixture(rows, cols) {
        var columns = [], data = []
        for (var c = 0; c < cols; ++c) columns.push({id: "c" + c, label: "Col " + c, kind: "text", unit: "", expression: ""})
        for (var r = 0; r < rows; ++r) {
            var row = []
            for (c = 0; c < cols; ++c) row.push("r" + r + "c" + c)
            data.push(row)
        }
        return build(columns, data)
    }
    function setFx(f) {
        tests.fx = f
        waitForRendering(grid)
    }
    function child(n) { return findChild(grid, n) }
    function cell(r, c) { return child("aiCalcGridCell_" + r + "_" + c) }
    function scroller() { return child("aiCalcGridScroll") }
    function editor() { return child("aiCalcGridEditor") }
    function walk(item, out) {
        if (!item || out.indexOf(item) >= 0) return out
        out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) walk(kids[i], out)
        if (item.contentItem) walk(item.contentItem, out)
        return out
    }
    function descendants() { return walk(grid, []) }
    function countNamed(prefix) {
        var n = 0, all = descendants()
        for (var i = 0; i < all.length; ++i)
            if (all[i].objectName && all[i].objectName.indexOf(prefix) === 0) ++n
        return n
    }
    function count(typeName) {
        var n = 0, all = descendants()
        for (var i = 0; i < all.length; ++i)
            if (typeName === "TextField" ? typeof all[i].selectByMouse === "boolean" : false) ++n
        return n
    }
    function typeText(s) { for (var i = 0; i < s.length; ++i) keyClick(s.charAt(i)) }
    function focusGrid() {
        scroller().forceActiveFocus(Qt.TabFocusReason)
        tryCompare(scroller(), "activeFocus", true)
    }
    function go(r, c) {
        focusGrid()
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        for (var i = 0; i < r; ++i) keyClick(Qt.Key_Down)
        for (i = 0; i < c; ++i) keyClick(Qt.Key_Right)
        compare(grid.activeRow, r)
        compare(grid.activeCol, c)
    }
    function lum(c) {
        function f(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    function ratio(fg, bg) {
        var a = fg.a, mix = {r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a)}
        var l1 = lum(mix), l2 = lum(bg), hi = Math.max(l1, l2), lo = Math.min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    function init() {
        grid.width = 420
        grid.canAdd = true
        grid.addBlockedReason = ""
        grid.editedKeys = ({})
        grid.expanded = false
        grid.wantRow = 0
        grid.wantCol = 0
        // Tests assign grid.table directly; put the bindings back.
        grid.table = Qt.binding(function () { return tests.fx.table })
        grid.nodes = Qt.binding(function () { return tests.fx.nodes })
        grid.formatText = Qt.binding(function () { return tests.fx.formatText })
        tests.fx = tests.itemsFixture()
        before.forceActiveFocus()
        commitSpy.clear(); clearSpy.clear(); addSpy.clear(); removeSpy.clear()
        wait(0)
        if (grid.editing) grid.closeEditor()
        scroller().contentX = 0
        before.forceActiveFocus()
    }

    // ---- display ---------------------------------------------------------
    function test_showsHeadersCellsAndEngineTextForFormulaColumn() {
        compare(grid.colCount, 4)
        compare(grid.shownRows, 4)
        compare(child("aiCalcGridHeader_1").text, "Price (EUR)")
        compare(child("aiCalcGridHeader_3").text, "Total (EUR)")
        compare(cell(0, 0).text, "Chair")
        compare(cell(1, 1).text, "250.5")
        compare(cell(0, 3).text, tests.fx.formatText("t.total#1"))
        verify(cell(0, 3).text.indexOf("3600") === 0, "price*qty from the engine: " + cell(0, 3).text)
        compare(cell(3, 0).text, "")
        verify(editor() !== null)
        verify(!editor().visible)
    }

    function test_hostUpdatesAreDisplayedAndGridNeverMutatesItsInput() {
        var before0 = JSON.stringify(grid.table)
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("2500")
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 1)
        compare(JSON.stringify(grid.table), before0, "grid left the table alone")
        compare(cell(0, 1).text, "1800", "still the host's value until it hands back a new table")
        var next = JSON.parse(JSON.stringify(grid.table))
        next.rows[0][1] = "2500"
        grid.table = next
        compare(cell(0, 1).text, "2500")
    }

    // ---- Tab stop ----------------------------------------------------------
    function test_gridIsOneRovingTabStopEnteredOnceAndLeftOnce() {
        verify(scroller().activeFocusOnTab)
        verify(!editor().activeFocusOnTab, "the editor is never a Tab stop")
        for (var i = 0; i < 4; ++i)
            for (var j = 0; j < 4; ++j) verify(!cell(i, j).activeFocusOnTab, "cell " + i + "," + j)
        var visited = []
        before.forceActiveFocus(Qt.TabFocusReason)
        for (var k = 0; k < 8 && !after.activeFocus; ++k) {
            keyClick(Qt.Key_Tab)
            if (scroller().activeFocus) visited.push("grid")
            else if (child("aiCalcGridAdd").activeFocus) visited.push("add")
            else if (child("aiCalcGridRemove").activeFocus) visited.push("remove")
            else if (after.activeFocus) visited.push("after")
            else visited.push("other")
        }
        compare(visited.join(","), "grid,add,remove,after", "one stop for the whole grid, then the buttons")
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(child("aiCalcGridRemove"), "activeFocus", true)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(scroller(), "activeFocus", true)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(before, "activeFocus", true)
        compare(commitSpy.count + clearSpy.count + addSpy.count + removeSpy.count, 0)
    }

    function test_tabStopFollowsActiveCellAndHasRing() {
        go(1, 2)
        var ring = child("aiCalcGridRing")
        verify(ring.visible)
        compare(ring.border.width, 2)
        compare(ring.border.color.toString(), Qt.color(grid.accent).toString())
        compare(ring.x, grid.cellX(2))
        compare(ring.y, grid.cellY(1))
        before.forceActiveFocus()
        verify(!ring.visible, "no ring when the grid has no focus")
        keyClick(Qt.Key_Tab)
        tryCompare(scroller(), "activeFocus", true)
        compare(grid.activeRow, 1, "Tab re-enters at the last active cell")
        compare(grid.activeCol, 2)
    }

    // ---- navigation ------------------------------------------------------------
    function test_arrowsHomeEndAndCtrlHomeEndMoveTheActiveCell() {
        focusGrid()
        compare(grid.activeRow, 0)
        compare(grid.activeCol, 0)
        keyClick(Qt.Key_Left); keyClick(Qt.Key_Up)
        compare(grid.activeRow, 0); compare(grid.activeCol, 0)
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
        compare(grid.activeRow, 2); compare(grid.activeCol, 1)
        keyClick(Qt.Key_End)
        compare(grid.activeCol, 3); compare(grid.activeRow, 2)
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
        compare(grid.activeCol, 3); compare(grid.activeRow, 3, "stops at the edges")
        keyClick(Qt.Key_Home)
        compare(grid.activeCol, 0); compare(grid.activeRow, 3)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        compare(grid.activeRow, 0); compare(grid.activeCol, 0)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        compare(grid.activeRow, 3); compare(grid.activeCol, 3)
        compare(commitSpy.count + clearSpy.count, 0, "moving never edits")
    }

    function test_horizontalScrollFollowsTheActiveCell() {
        setFx(wideFixture(5, 12))
        compare(grid.colCount, 12)
        var sc = scroller()
        compare(sc.contentWidth, 12 * 72 + 11 * 4)
        verify(sc.contentWidth > sc.width)
        focusGrid()
        compare(sc.contentX, 0)
        for (var i = 0; i < 5; ++i) keyClick(Qt.Key_Right)
        compare(grid.activeCol, 5)
        compare(sc.contentX, 5 * 76 + 72 - sc.width, "scrolled just enough to show column 5")
        keyClick(Qt.Key_End)
        compare(grid.activeCol, 11)
        compare(sc.contentX, sc.contentWidth - sc.width)
        keyClick(Qt.Key_Left)
        compare(sc.contentX, sc.contentWidth - sc.width, "column 10 is still inside")
        keyClick(Qt.Key_Home)
        compare(sc.contentX, 0)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        compare(grid.activeRow, 4)
        compare(sc.contentX, sc.contentWidth - sc.width)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        compare(sc.contentX, 0)
    }

    function test_collapsedNavigationStopsAtTheShownRows() {
        setFx(wideFixture(30, 3))
        focusGrid()
        keyClick(Qt.Key_End, Qt.ControlModifier)
        compare(grid.activeRow, 11, "12 rows shown while collapsed")
        child("aiCalcGridToggle").clicked()
        compare(grid.shownRows, 30)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        compare(grid.activeRow, 29)
        child("aiCalcGridToggle").clicked()
        compare(grid.shownRows, 12)
        compare(grid.activeRow, 11, "collapsing keeps the active row visible")
    }

    // ---- editing -----------------------------------------------------------------
    function test_enterOpensEditorOverTheCellAndEnterCommitsAndMovesDown() {
        go(0, 1)
        keyClick(Qt.Key_Return)
        verify(grid.editing)
        verify(editor().visible)
        tryCompare(editor(), "activeFocus", true)
        compare(editor().text, "1800")
        compare(editor().x, grid.cellX(1))
        compare(editor().y, grid.cellY(0))
        compare(editor().width, grid.colWidth)
        compare(editor().background.border.width, 2)
        compare(editor().background.border.color.toString(), Qt.color(grid.accent).toString())
        editor().selectAll()
        typeText("2500")
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][0], "0")
        compare(commitSpy.signalArguments[0][1], "price")
        compare(commitSpy.signalArguments[0][2], "2500")
        verify(!grid.editing)
        verify(!editor().visible)
        tryCompare(scroller(), "activeFocus", true)
        compare(grid.activeRow, 1, "Enter moved down")
        compare(grid.activeCol, 1)
    }

    function test_f2OpensAndEnterOnLastRowStays() {
        go(3, 0)
        keyClick(Qt.Key_F2)
        verify(grid.editing)
        typeText("Stool")
        keyClick(Qt.Key_Enter)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][0], "n1", "added row ids pass through")
        compare(commitSpy.signalArguments[0][1], "item")
        compare(commitSpy.signalArguments[0][2], "Stool")
        compare(grid.activeRow, 3, "no row below")
    }

    function test_printableKeyStartsAnEditWithThatCharacter() {
        go(1, 1)
        keyClick("7")
        verify(grid.editing)
        compare(editor().text, "7")
        compare(editor().cursorPosition, 1)
        keyClick(Qt.Key_Escape)
        go(1, 0)
        keyClick("x")
        verify(grid.editing)
        compare(editor().text, "x")
        keyClick(Qt.Key_Escape)
        go(1, 1)
        keyClick("a", Qt.ControlModifier)
        verify(!grid.editing, "Ctrl+key is not typing")
        compare(commitSpy.count, 0)
    }

    function test_escapeCancelsAndRevertsWithoutEmitting() {
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("99")
        keyClick(Qt.Key_Escape)
        verify(!grid.editing)
        verify(!editor().visible)
        tryCompare(scroller(), "activeFocus", true)
        compare(cell(0, 1).text, "1800")
        compare(commitSpy.count, 0)
        keyClick(Qt.Key_Return)
        compare(editor().text, "1800", "the reverted cell reopens with its own text")
        keyClick(Qt.Key_Escape)
    }

    function test_unchangedCommitEmitsNothing() {
        go(0, 0)
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 0)
        verify(!grid.editing)
    }

    function test_tabCommitsThenLeavesTheGridForwardAndBackward() {
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("3")
        keyClick(Qt.Key_Tab)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][2], "3")
        verify(!grid.editing)
        tryCompare(child("aiCalcGridAdd"), "activeFocus", true)
        verify(!scroller().activeFocus, "no Tab trap")
        go(1, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("4")
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        compare(commitSpy.count, 2)
        tryCompare(before, "activeFocus", true)
        verify(!grid.editing)
    }

    function test_losingFocusCommitsAValidValue() {
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("5")
        child("aiCalcGridAdd").forceActiveFocus(Qt.MouseFocusReason)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][2], "5")
        verify(!grid.editing)
    }

    function test_invalidValueKeepsTheEditorOpenWithMessageAndEmitsNothing() {
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("abc")
        keyClick(Qt.Key_Return)
        verify(grid.editing)
        verify(editor().visible)
        tryCompare(editor(), "activeFocus", true)
        compare(commitSpy.count, 0)
        var msg = Edit.parseCell("abc", "number").msg
        compare(msg, "Not a plain number. Use a decimal point, e.g. 1.5")
        compare(child("aiCalcGridMessage").text, msg)
        verify(child("aiCalcGridMessageRow").visible)
        compare(child("aiCalcGridMessage").textFormat, Text.PlainText)
        // Not red-only: a 2 px accent border, a glyph and bold text.
        compare(editor().background.border.width, 2)
        verify(child("aiCalcGridEditorGlyph").visible)
        verify(child("aiCalcGridMessageGlyph").visible)
        compare(editor().font.weight, Font.Bold)
        keyClick(Qt.Key_Tab)
        verify(grid.editing, "Tab will not discard or half-commit an invalid value")
        compare(commitSpy.count, 0)
        // Typing again clears the message; a comma is also refused.
        typeText("x")
        verify(!child("aiCalcGridMessageRow").visible)
        editor().selectAll()
        typeText("1,5")
        keyClick(Qt.Key_Return)
        verify(grid.editing)
        compare(commitSpy.count, 0)
        editor().selectAll()
        typeText("1.5")
        verify(!child("aiCalcGridMessageRow").visible)
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][2], "1.5")
        verify(!grid.editing)
        verify(!child("aiCalcGridMessageRow").visible)
    }

    function test_numberCommitIsTheTrimmedTextExactlyOnce() {
        go(1, 2)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("  1e3 ")
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0].length, 3)
        compare(commitSpy.signalArguments[0][0], "1")
        compare(commitSpy.signalArguments[0][1], "qty")
        compare(commitSpy.signalArguments[0][2], "1e3")
        compare(typeof commitSpy.signalArguments[0][2], "string")
        go(1, 2)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText(".5")
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 2)
        compare(commitSpy.signalArguments[1][2], ".5")
    }

    function test_textColumnCommitHonoursTheSixtyFourCharacterCap() {
        var long65 = "", ok64 = ""
        for (var i = 0; i < 64; ++i) ok64 += "a"
        long65 = ok64 + "b"
        go(0, 0)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText(long65)
        keyClick(Qt.Key_Return)
        verify(grid.editing)
        compare(commitSpy.count, 0)
        compare(child("aiCalcGridMessage").text, Edit.parseCell(long65, "text").msg)
        compare(child("aiCalcGridMessage").text, "Too long. Use at most 64 characters.")
        editor().selectAll()
        typeText(ok64)
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 1)
        compare(commitSpy.signalArguments[0][2], ok64)
        // An emptied text cell is a valid, empty commit.
        go(1, 0)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        keyClick(Qt.Key_Delete)
        keyClick(Qt.Key_Return)
        compare(commitSpy.count, 2)
        compare(commitSpy.signalArguments[1][0], "1")
        compare(commitSpy.signalArguments[1][2], "")
    }

    function test_deleteEmitsClearOnEditableCellsOnly() {
        go(2, 1)
        keyClick(Qt.Key_Delete)
        compare(clearSpy.count, 1)
        compare(clearSpy.signalArguments[0][0], "2")
        compare(clearSpy.signalArguments[0][1], "price")
        compare(commitSpy.count, 0)
        verify(!grid.editing)
        go(2, 3)
        keyClick(Qt.Key_Delete)
        compare(clearSpy.count, 1, "calculated cells cannot be cleared")
    }

    function test_formulaCellsAreReadOnly() {
        go(0, 3)
        var before0 = cell(0, 3).text
        keyClick(Qt.Key_Return)
        verify(!grid.editing)
        keyClick(Qt.Key_F2)
        verify(!grid.editing)
        keyClick("5")
        typeText("123")
        verify(!grid.editing)
        verify(!editor().visible)
        compare(cell(0, 3).text, before0)
        compare(commitSpy.count + clearSpy.count, 0)
        compare(scroller().Accessible.name, "Row 1, Total (EUR), " + before0 + ", calculated")
        tryCompare(scroller(), "activeFocus", true)
    }

    function test_mouseClickSelectsAndDoubleClickEdits() {
        var sc = scroller()
        mouseClick(sc, grid.cellX(1) + 10, grid.cellY(2) + 10)
        compare(grid.activeRow, 2)
        compare(grid.activeCol, 1)
        verify(sc.activeFocus)
        verify(!grid.editing)
        mouseClick(sc, 3, grid.rowsTop - 40)
        compare(grid.activeRow, 2, "a click on the header keeps the active cell")
        mouseClick(sc, grid.cellX(0) + 10, grid.cellY(1) + 10)
        verify(!grid.editing)
        mouseClick(sc, grid.cellX(0) + 10, grid.cellY(1) + 10)
        compare(grid.activeRow, 1)
        compare(grid.activeCol, 0)
        verify(grid.editing, "double click opens the editor")
        keyClick(Qt.Key_Escape)
    }

    function test_hostTableChangeClosesAStaleEditor() {
        go(1, 1)
        keyClick(Qt.Key_Return)
        verify(grid.editing)
        var next = JSON.parse(JSON.stringify(grid.table))
        next.rows.splice(0, 1)
        next.rowIds.splice(0, 1)
        grid.table = next
        verify(!grid.editing, "row 1 is now a different row")
        compare(commitSpy.count, 0)
    }

    // ---- buttons -----------------------------------------------------------------
    function test_addAndRemoveButtons() {
        var add = child("aiCalcGridAdd"), rem = child("aiCalcGridRemove")
        compare(add.text, "Add row")
        compare(rem.text, "Remove row")
        verify(add.enabled && rem.enabled)
        verify(!child("aiCalcGridBlockedReason").visible)
        add.clicked()
        compare(addSpy.count, 1)
        go(2, 0)
        rem.clicked()
        compare(removeSpy.count, 1)
        compare(removeSpy.signalArguments[0][0], "2", "Remove acts on the active row")
        go(3, 0)
        rem.clicked()
        compare(removeSpy.signalArguments[1][0], "n1")
        compare(commitSpy.count, 0)
    }

    function test_blockedAddShowsTheReasonAndSkipsTab() {
        grid.canAdd = false
        grid.addBlockedReason = "At most 40 rows."
        var add = child("aiCalcGridAdd"), reason = child("aiCalcGridBlockedReason")
        verify(!add.enabled)
        verify(reason.visible)
        compare(reason.text, "At most 40 rows.")
        compare(reason.textFormat, Text.PlainText)
        compare(add.Accessible.description, "At most 40 rows.")
        before.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(scroller(), "activeFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(child("aiCalcGridRemove"), "activeFocus", true)
        verify(!add.activeFocus)
        compare(addSpy.count, 0)
        grid.canAdd = true
        verify(add.enabled)
        verify(!reason.visible)
        grid.canAdd = false
        grid.addBlockedReason = ""
        verify(!reason.visible, "nothing to say without a reason")
    }

    function test_removeIsDisabledWithoutRows() {
        setFx(build([{id: "a", label: "A", kind: "text", unit: "", expression: ""}], []))
        compare(grid.shownRows, 0)
        verify(!child("aiCalcGridRemove").enabled)
        verify(!scroller().activeFocusOnTab, "an empty grid has no cell to stop on")
        compare(scroller().Accessible.name, "Order")
    }

    // ---- bounds ------------------------------------------------------------------
    function test_delegatesAreBoundedAt40By12PlusOneTextField() {
        setFx(wideFixture(40, 12))
        compare(grid.rowTotal, 40)
        compare(grid.colCount, 12)
        compare(grid.shownRows, 12, "collapsed to 12 rows")
        compare(countNamed("aiCalcGridCell_"), 12 * 12)
        compare(grid.delegateCount, 144)
        compare(count("TextField"), 1, "one shared editor")
        var toggle = child("aiCalcGridToggle")
        verify(toggle.visible)
        compare(toggle.text, "Show all 40 rows")
        toggle.clicked()
        compare(grid.shownRows, 40)
        tryCompare(grid, "delegateCount", 480)
        compare(countNamed("aiCalcGridCell_"), 480)
        compare(count("TextField"), 1)
        compare(toggle.text, "Show fewer rows")
        toggle.clicked()
        tryCompare(grid, "delegateCount", 144)
        compare(countNamed("aiCalcGridCell_"), 144)
    }

    function test_oversizedTablesAreCappedNotRendered() {
        setFx(wideFixture(40, 12))
        var big = JSON.parse(JSON.stringify(grid.table))
        for (var r = 0; r < 12; ++r) big.rows.push(big.rows[0].slice())
        for (var c = 0; c < 8; ++c) {
            big.columns.push({id: "x" + c, label: "X", kind: "text", unit: ""})
            for (r = 0; r < big.rows.length; ++r) big.rows[r].push("v")
        }
        grid.table = big
        grid.expanded = true
        compare(grid.rowTotal, 40)
        compare(grid.colCount, 12)
        tryCompare(grid, "delegateCount", 480)
        compare(countNamed("aiCalcGridCell_"), 480)
        compare(countNamed("aiCalcGridHeader_"), 12)
        compare(count("TextField"), 1)
    }

    function test_noToggleForTwelveRowsOrFewer() {
        verify(!child("aiCalcGridToggle").visible)
        setFx(wideFixture(12, 2))
        verify(!child("aiCalcGridToggle").visible)
        compare(grid.shownRows, 12)
    }

    // ---- marks, errors, safety -----------------------------------------------------
    function test_editedCellsGetAVisibleMarkBoldTextAndAnAccessibleDescription() {
        for (var r = 0; r < 4; ++r)
            for (var c = 0; c < 4; ++c) verify(!child("aiCalcGridEdited_" + r + "_" + c).visible)
        grid.editedKeys = {"1|price": true, "n1|item": true, "t|nope": true}
        var m1 = child("aiCalcGridEdited_1_1"), m2 = child("aiCalcGridEdited_3_0")
        verify(m1.visible)
        verify(m2.visible)
        compare(m1.color.toString(), Qt.color(grid.accent).toString())
        var visibleMarks = 0
        for (r = 0; r < 4; ++r)
            for (c = 0; c < 4; ++c) if (child("aiCalcGridEdited_" + r + "_" + c).visible) ++visibleMarks
        compare(visibleMarks, 2)
        compare(cell(1, 1).font.weight, Font.Bold)
        compare(cell(1, 2).font.weight, Font.Normal)
        compare(cell(1, 1).Accessible.description, "edited")
        compare(cell(1, 2).Accessible.description, "editable")
        compare(cell(1, 3).Accessible.description, "calculated")
        go(1, 1)
        compare(scroller().Accessible.name, "Row 2, Price (EUR), 250.5, editable, edited")
        grid.editedKeys = ({})
        verify(!m1.visible)
        compare(cell(1, 1).font.weight, Font.Normal)
    }

    function test_errorLineSummarisesTheFirstThreeAndShowsAnEmDash() {
        var f = build([
            {id: "a", label: "A", kind: "number", unit: "", expression: ""},
            {id: "r", label: "Ratio", kind: "formula", unit: "", expression: "1/a"}
        ], [["0", ""], ["1", ""], ["0", ""], ["0", ""], ["0", ""]])
        setFx(f)
        var errs = child("aiCalcGridErrors")
        verify(errs.visible)
        compare(grid.errorList.length, 4)
        verify(errs.text.indexOf("Row 1, Ratio: Cannot compute: ") === 0, errs.text)
        verify(errs.text.indexOf("Row 3, Ratio: ") > 0)
        verify(errs.text.indexOf("Row 4, Ratio: ") > 0)
        verify(errs.text.indexOf("Row 5, Ratio: ") < 0, "only the first three are listed")
        verify(errs.text.indexOf(" \u00b7 and 1 more") > 0)
        compare(errs.textFormat, Text.PlainText)
        compare(cell(0, 1).text, "\u2014")
        compare(cell(1, 1).text, "1.00")
        compare(cell(0, 1).Accessible.name, "Ratio, row 1: \u2014")
        verify(cell(0, 1).Accessible.description.length > 0)
        // No errors: the line is gone.
        setFx(wideFixture(2, 2))
        verify(!errs.visible)
    }

    function test_everythingIsPlainText() {
        var f = wideFixture(2, 2)
        f.table.columns[0].label = "<b>H</b>"
        f.table.label = "<i>t</i>"
        f.table.rows[0][0] = "<b>x</b>"
        f.table.rows[1][1] = "<img src='x'>"
        setFx(f)
        compare(cell(0, 0).text, "<b>x</b>")
        compare(cell(0, 0).textFormat, Text.PlainText)
        compare(cell(1, 1).text, "<img src='x'>")
        compare(child("aiCalcGridHeader_0").text, "<b>H</b>")
        compare(child("aiCalcGridHeader_0").textFormat, Text.PlainText)
        compare(child("aiCalcGridErrors").textFormat, Text.PlainText)
        compare(child("aiCalcGridMessage").textFormat, Text.PlainText)
        compare(child("aiCalcGridBlockedReason").textFormat, Text.PlainText)
        var all = descendants()
        for (var i = 0; i < all.length; ++i)
            if (all[i].objectName && all[i].objectName.indexOf("aiCalcGridCell_") === 0)
                compare(all[i].textFormat, Text.PlainText, all[i].objectName)
        go(0, 0)
        keyClick(Qt.Key_Return)
        compare(editor().text, "<b>x</b>")
        keyClick(Qt.Key_Escape)
    }

    // ---- accessibility ---------------------------------------------------------------
    function test_accessibleNamesAndRoles() {
        compare(scroller().Accessible.role, Accessible.Table)
        compare(scroller().Accessible.name, "Row 1, Item, Chair, editable")
        go(1, 1)
        compare(scroller().Accessible.name, "Row 2, Price (EUR), 250.5, editable")
        keyClick(Qt.Key_End)
        verify(scroller().Accessible.name.indexOf("Row 2, Total (EUR), ") === 0)
        verify(scroller().Accessible.name.indexOf(", calculated") > 0)
        compare(cell(1, 1).Accessible.name, "Price (EUR), row 2: 250.5")
        compare(cell(0, 0).Accessible.name, "Item, row 1: Chair")
        compare(cell(0, 0).Accessible.role, Accessible.Cell)
        go(3, 0)
        compare(scroller().Accessible.name, "Row 4, Item, empty, editable")
        keyClick(Qt.Key_Return)
        verify(editor().Accessible.name.indexOf("Item, row 4") === 0)
        keyClick(Qt.Key_Escape)
        compare(child("aiCalcGridAdd").Accessible.name, "Add row")
        compare(child("aiCalcGridRemove").Accessible.name, "Remove row")
    }

    function test_everyFocusableShowsATwoPixelAccentRing() {
        var add = child("aiCalcGridAdd"), rem = child("aiCalcGridRemove")
        add.forceActiveFocus(Qt.TabFocusReason)
        verify(add.visualFocus)
        compare(add.background.border.width, 2)
        compare(add.background.border.color.toString(), Qt.color(grid.accent).toString())
        rem.forceActiveFocus(Qt.TabFocusReason)
        verify(rem.visualFocus)
        compare(rem.background.border.width, 2)
        verify(!add.visualFocus)
        compare(add.background.border.width, 1)
        setFx(wideFixture(20, 2))
        var toggle = child("aiCalcGridToggle")
        toggle.forceActiveFocus(Qt.TabFocusReason)
        verify(toggle.visualFocus)
        compare(toggle.background.border.width, 2)
        compare(toggle.background.border.color.toString(), Qt.color(grid.accent).toString())
    }

    // ---- contrast ----------------------------------------------------------------------
    function test_informationalTextMeetsTheContrastFloor() {
        grid.canAdd = false
        grid.addBlockedReason = "Row limit reached."
        go(0, 1)
        keyClick(Qt.Key_Return)
        editor().selectAll()
        typeText("zz")
        keyClick(Qt.Key_Return)
        var bg = Qt.color(grid.background)
        function pin(item, floor, name) {
            var a = item.color.a
            verify(a >= floor - 1e-9, name + " opacity " + a + " >= " + floor)
            verify(ratio(item.color, bg) >= 4.5, name + " contrast " + ratio(item.color, bg))
        }
        pin(cell(0, 0), 0.80, "cell")
        pin(cell(0, 3), 0.80, "calculated cell")
        pin(child("aiCalcGridHeader_0"), 0.80, "header")
        pin(child("aiCalcGridMessage"), 0.80, "message")
        pin(child("aiCalcGridBlockedReason"), 0.80, "reason")
        pin(child("aiCalcGridAdd").contentItem, 0.76, "disabled add label")
        pin(child("aiCalcGridRemove").contentItem, 0.80, "remove label")
        keyClick(Qt.Key_Escape)
        grid.canAdd = true
        pin(child("aiCalcGridAdd").contentItem, 0.80, "add label")
        setFx(wideFixture(20, 2))
        pin(child("aiCalcGridToggle").contentItem, 0.80, "toggle label")
        // Non-text cues need 3:1 against the surface.
        verify(ratio(Qt.color(grid.accent), bg) >= 3, "accent ring " + ratio(Qt.color(grid.accent), bg))
        verify(ratio(Qt.rgba(1, 1, 1, 1), Qt.color("#ffffff")) < 1.01, "ratio helper sanity")
        verify(ratio(Qt.color("#000000"), Qt.color("#ffffff")) > 20, "ratio helper sanity 2")
    }

    function test_missingOrOddInputsDoNotThrowOrRenderCells() {
        grid.nodes = null
        grid.formatText = null
        compare(cell(0, 3).text, "", "no engine text without nodes and a formatter")
        grid.table = null
        compare(grid.shownRows, 0)
        compare(grid.colCount, 0)
        compare(grid.delegateCount, 0)
        verify(!scroller().activeFocusOnTab)
        verify(!child("aiCalcGridErrors").visible)
        grid.table = ({id: "t", label: "", columns: [], rows: [], rowIds: []})
        compare(grid.delegateCount, 0)
        compare(scroller().Accessible.name, "Calculation table")
        // rowIds shorter than rows fall back to the row index.
        var f = tests.itemsFixture()
        grid.nodes = f.nodes
        grid.formatText = f.formatText
        var t = JSON.parse(JSON.stringify(f.table))
        t.rowIds = ["0"]
        grid.table = t
        go(2, 1)
        keyClick(Qt.Key_Delete)
        compare(clearSpy.signalArguments[0][0], "2")
    }

    // ---- widths --------------------------------------------------------------------------
    function test_worksAt420And760WithoutOverflow() {
        var heights = {}, widths = [420, 760], f, w, i
        for (i = 0; i < widths.length; ++i) {
            w = widths[i]
            grid.width = w
            setFx(wideFixture(12, 12))
            compare(scroller().width, w)
            compare(scroller().contentWidth, Math.max(w, 12 * 72 + 11 * 4))
            verify(grid.childrenRect.width <= w + 0.5, "grid content width " + grid.childrenRect.width + " at " + w)
            if (w === 420) verify(scroller().contentWidth > w, "the grid scrolls in its own Flickable")
            heights[w] = grid.height
            go(0, 0)
            keyClick(Qt.Key_Return)
            editor().selectAll()
            typeText("<<<<<")
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            verify(grid.childrenRect.width <= w + 0.5, "message row fits at " + w)
        }
        verify(heights[420] > 0 && heights[760] > 0)
        // The normal 4-column table fits the card width with no horizontal scrolling at 760.
        setFx(tests.itemsFixture())
        compare(scroller().contentWidth, 760)
        grid.width = 420
        waitForRendering(grid)
        compare(scroller().contentWidth, 420)
        setFx(wideFixture(40, 12))
        grid.expanded = true
        tryCompare(grid, "delegateCount", 480)
        waitForRendering(grid)
        var tall = grid.height
        verify(tall > 40 * grid.rowHeight, "expanded height " + tall)
    }
}
