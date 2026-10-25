import QtQuick
import QtQuick.Controls
import QtTest
import ".."

// The explorer is driven by a mock source that records the calls it receives,
// so no worker process runs and the debounce stays the source's business.
TestCase {
    id: tests
    name: "AiCsvExplorer"
    width: 800
    height: 900
    visible: true
    when: windowShown

    QtObject {
        id: mock
        property string status: "idle"
        property var meta: null
        property var page: null
        property int viewRows: -1
        property string error: ""
        property bool retryable: false
        property bool viewPending: false
        property int progressRows: 0
        readonly property bool busy: viewPending
        property var calls: []
        function setView(sort, dir, filter) { calls.push(["setView", sort, dir, filter]); return true }
        function goPage(n) { calls.push(["goPage", n]); return true }
    }

    AiCsvExplorer {
        id: explorer
        source: mock
        width: 660
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
    }

    Item { id: before; activeFocusOnTab: true }
    SignalSpy { id: edited; target: explorer; signalName: "viewStateEdited" }

    function child(name) { return findChild(explorer, name) }

    function makeMeta(columnCount, rows, numericColumns) {
        var columns = [], stats = []
        for (var c = 0; c < columnCount; ++c) {
            columns.push("Col " + c)
            var numeric = numericColumns && numericColumns.indexOf(c) >= 0
            stats.push({name: "Col " + c, nonEmpty: 5, empty: 0,
                typeCounts: {number: numeric ? 5 : 0, date: 0, text: numeric ? 0 : 5, unsure: 0}})
        }
        return {sourceId: "src-0123456789abcdef", rows: rows, columnCount: columnCount, columns: columns,
            columnsTruncated: false, bytes: 100, stats: stats}
    }

    function makePage(pageIndex, viewRows, columnCount, cellsTruncated) {
        var count = Math.max(0, Math.min(25, viewRows - pageIndex * 25))
        var rows = []
        for (var r = 0; r < count; ++r) {
            var row = []
            for (var c = 0; c < columnCount; ++c) row.push("p" + pageIndex + "r" + r + "c" + c)
            rows.push(row)
        }
        return {gen: 1, page: pageIndex, pageSize: 25, pageCount: Math.ceil(viewRows / 25), viewRows: viewRows,
            firstRow: count ? pageIndex * 25 + 1 : 0, rows: rows, cellsTruncated: !!cellsTruncated}
    }

    // A ready source: viewRows rows in the view, `columns` columns.
    function ready(viewRows, columns, total) {
        var n = columns === undefined ? 4 : columns
        mock.meta = makeMeta(n, total === undefined ? viewRows : total, [0])
        mock.viewRows = viewRows
        mock.page = makePage(0, viewRows, n, false)
        mock.status = "ready"
        waitForRendering(explorer)
    }

    function expand() {
        explorer.expanded = true
        tryVerify(function() { return child("aiCsvExplorerViewport") !== null || child("aiCsvExplorerEmpty") !== null })
        waitForRendering(explorer)
    }

    function init() {
        explorer.expanded = false
        explorer.viewState = ({})
        explorer.width = 660
        mock.status = "idle"
        mock.meta = null
        mock.page = null
        mock.viewRows = -1
        mock.error = ""
        mock.retryable = false
        mock.viewPending = false
        mock.progressRows = 0
        mock.calls = []
        explorer._appliedMeta = null
        explorer._sort = -1
        explorer._dir = 1
        explorer._filter = ""
        explorer._page = 0
        before.forceActiveFocus()
        edited.clear()
        wait(0)
        mock.calls = []
    }

    function cellDelegates() {
        var grid = child("aiCsvExplorerViewport")
        var rows = 0, cells = 0
        var items = grid ? grid.contentItem.children : []
        for (var i = 0; i < items.length; ++i) {
            if (String(items[i].objectName).indexOf("aiCsvExplorerRow") !== 0) continue
            ++rows
            for (var k = 0; k < items[i].children.length; ++k)
                if (items[i].children[k].objectName === "aiCsvExplorerCell") ++cells
        }
        return {rows: rows, cells: cells}
    }

    function visibleCell(text) {
        var grid = child("aiCsvExplorerViewport")
        for (var i = 0; i < grid.contentItem.children.length; ++i) {
            var row = grid.contentItem.children[i]
            for (var k = 0; k < row.children.length; ++k)
                if (row.children[k].objectName === "aiCsvExplorerCell" && row.children[k].text === text)
                    return row.children[k]
        }
        return null
    }

    function lastCall(kind) {
        for (var i = mock.calls.length - 1; i >= 0; --i) if (mock.calls[i][0] === kind) return mock.calls[i]
        return null
    }

    // ---- visibility and collapse -------------------------------------------------

    function test_hiddenUntilReadyAndRegisteringShowsProgress() {
        verify(!explorer.visible)
        compare(explorer.implicitHeight, 0)
        compare(explorer.height, 0)
        mock.status = "registering"
        mock.progressRows = 12345
        verify(explorer.visible)
        compare(child("aiCsvExplorerCount").text, "Counting… 12,345 rows so far")
        verify(!child("aiCsvExplorerToggle").visible)
        verify(child("aiCsvExplorerTitle").visible)
        verify(explorer.implicitHeight > 0)
        compare(child("aiCsvExplorerBody").active, false)
        mock.status = "error"
        verify(!explorer.visible)
        compare(explorer.implicitHeight, 0)
    }

    function test_collapsedByDefaultTogglesByKeyboardAndMouse() {
        ready(100)
        var toggle = child("aiCsvExplorerToggle")
        verify(toggle.visible)
        verify(!explorer.expanded)
        verify(!child("aiCsvExplorerBody").active)
        compare(child("aiCsvExplorerViewport"), null)
        compare(toggle.Accessible.name, "Explore all rows, collapsed")
        compare(child("aiCsvExplorerCount").text, "100 rows")
        toggle.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(toggle, "activeFocus", true)
        keyClick(Qt.Key_Space)
        verify(explorer.expanded)
        tryVerify(function() { return child("aiCsvExplorerViewport") !== null })
        compare(toggle.Accessible.name, "Explore all rows, expanded")
        keyClick(Qt.Key_Return)
        verify(!explorer.expanded)
        tryVerify(function() { return child("aiCsvExplorerViewport") === null })
        mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        verify(explorer.expanded)
        mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        verify(!explorer.expanded)
        compare(edited.count, 0, "toggling is not a view edit")
        compare(mock.calls.length, 0)
    }

    // ---- bounded rendering -------------------------------------------------------

    function test_pageRendersAtMost25By20DelegatesEvenWithHugeViews() {
        ready(500000, 20, 500000)
        expand()
        var grid = child("aiCsvExplorerViewport")
        compare(grid.count, 25)
        var counted = cellDelegates()
        verify(counted.rows > 0 && counted.rows <= 25)
        verify(counted.cells > 0 && counted.cells <= 25 * 20, "cells " + counted.cells)
        compare(counted.cells, counted.rows * 20)
        compare(child("aiCsvExplorerHeaders").count, 20)
        compare(child("aiCsvExplorerCount").text, "500,000 rows")
        compare(child("aiCsvExplorerPage").text, "Page 1 of 20,000")
        compare(child("aiCsvExplorerRange").text, "Rows 1–25 of 500,000")
        // A page of 500 cells is the ceiling; the viewport shows only the rows that fit.
        verify(grid.height <= 8 * grid.rowH + grid.bottomMargin)
        // A new page replaces the delegates, it does not accumulate them.
        mock.page = makePage(3, 500000, 20, false)
        waitForRendering(explorer)
        verify(cellDelegates().cells <= 25 * 20)
        verify(visibleCell("p3r0c0") !== null)
        compare(visibleCell("p0r0c0"), null)
        // Collapsing releases every delegate.
        explorer.expanded = false
        tryVerify(function() { return child("aiCsvExplorerViewport") === null })
    }

    function test_cellsAndHeadersAreLiteralPlainText() {
        mock.meta = makeMeta(2, 2, [])
        mock.meta.columns = ["<b>Name</b>", "Amount & unit"]
        mock.viewRows = 2
        var page = makePage(0, 2, 2, false)
        page.rows = [["<b>x</b>", "<img src='y'>"], ["=SUM(A1)", "line"]]
        mock.page = page
        mock.status = "ready"
        expand()
        var cell = visibleCell("<b>x</b>")
        verify(cell !== null)
        compare(cell.textFormat, Text.PlainText)
        compare(child("aiCsvExplorerHeader0").text, "<b>Name</b>")
        compare(child("aiCsvExplorerHeader0").contentItem.textFormat, Text.PlainText)
        compare(child("aiCsvExplorerHeader1").Accessible.name, "Amount & unit")
    }

    // A quoted field may contain CR/LF; it must stay on one 28 px line instead of
    // painting extra lines over the neighbouring rows.
    function test_multilineCellsStayOnOneLine() {
        mock.meta = makeMeta(2, 2, [])
        mock.viewRows = 2
        var page = makePage(0, 2, 2, false)
        page.rows = [["first\nsecond\r\nthird", "a\rb\u2028c"], ["plain", "\n\n"]]
        mock.page = page
        mock.status = "ready"
        expand()
        var cell = visibleCell("first \u23ce second \u23ce third")
        verify(cell !== null, "line breaks are shown as one return glyph per run")
        compare(cell.height, 28)
        compare(cell.lineCount, 1)
        compare(cell.maximumLineCount, 1)
        compare(cell.textFormat, Text.PlainText)
        verify(cell.contentHeight <= 28, "single-line content height " + cell.contentHeight)
        verify(cell.text.indexOf("\n") < 0 && cell.text.indexOf("\r") < 0)
        var other = visibleCell("a \u23ce b \u23ce c")
        verify(other !== null && other.lineCount === 1, "CR and U+2028 are single-lined too")
        var blank = visibleCell(" \u23ce ")
        verify(blank !== null && blank.lineCount === 1)
        var grid = child("aiCsvExplorerViewport")
        for (var i = 0; i < grid.contentItem.children.length; ++i) {
            var row = grid.contentItem.children[i]
            if (String(row.objectName).indexOf("aiCsvExplorerRow") === 0) compare(row.height, 28)
        }
        compare(visibleCell("plain").lineCount, 1)
    }

    // ---- count label -------------------------------------------------------------

    function test_countLabelStates() {
        ready(1000)
        compare(child("aiCsvExplorerCount").text, "1,000 rows")
        mock.viewPending = true
        compare(child("aiCsvExplorerCount").text, "Counting…")
        mock.viewPending = false
        mock.viewRows = -1
        compare(child("aiCsvExplorerCount").text, "Counting…")
        mock.viewRows = 1000
        expand()
        var filter = child("aiCsvExplorerFilter")
        filter.forceActiveFocus()
        keyClick("o")
        mock.viewRows = 37
        compare(child("aiCsvExplorerCount").text, "37 of 1,000 rows")
        mock.meta = makeMeta(4, 1, [0])
        compare(child("aiCsvExplorerCount").text, "1 row", "a new source starts unfiltered")
    }

    // ---- sort --------------------------------------------------------------------

    function test_sortCyclesNoneAscendingDescendingAndEmitsFullState() {
        ready(100)
        expand()
        var header = child("aiCsvExplorerHeader1")
        header.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(header, "activeFocus", true)
        keyClick(Qt.Key_Return)
        compare(lastCall("setView"), ["setView", 1, 1, ""])
        compare(edited.count, 1)
        compare(edited.signalArguments[0][0], {sort: 1, dir: 1, filter: "", page: 0})
        compare(header.text, "Col 1  ↑")
        compare(header.Accessible.name, "Col 1, sorted ascending")
        keyClick(Qt.Key_Space)
        compare(lastCall("setView"), ["setView", 1, -1, ""])
        compare(edited.signalArguments[1][0], {sort: 1, dir: -1, filter: "", page: 0})
        compare(header.text, "Col 1  ↓")
        compare(header.Accessible.name, "Col 1, sorted descending")
        mouseClick(header, header.width / 2, header.height / 2)
        compare(lastCall("setView"), ["setView", -1, 1, ""])
        compare(edited.signalArguments[2][0], {sort: -1, dir: 1, filter: "", page: 0})
        compare(header.text, "Col 1")
        // Another column starts ascending, and sorting returns to the first page.
        mock.page = makePage(2, 100, 4, false)
        explorer._page = 2
        mouseClick(child("aiCsvExplorerHeader2"), 20, 10)
        compare(lastCall("setView"), ["setView", 2, 1, ""])
        compare(edited.signalArguments[3][0], {sort: 2, dir: 1, filter: "", page: 0})
    }

    function test_sortHintNamesCharacterCodeForTextColumnsOnly() {
        ready(100)
        expand()
        var numeric = child("aiCsvExplorerHeader0")
        var text = child("aiCsvExplorerHeader1")
        verify(text.Accessible.description.indexOf("character code") >= 0)
        verify(text.ToolTip.text.indexOf("character code") >= 0)
        verify(numeric.Accessible.description.indexOf("numerically") >= 0)
        verify(numeric.Accessible.description.indexOf("character code") < 0)
        compare(child("aiCsvExplorerSortNote").visible, false)
        mouseClick(numeric, 10, 10)
        compare(child("aiCsvExplorerSortNote").visible, false, "a numeric sort needs no disclosure")
        mouseClick(text, 10, 10)
        compare(child("aiCsvExplorerSortNote").text, "Sorted by character code")
        compare(child("aiCsvExplorerSortNote").color.toString(), Qt.alpha(explorer.foreground, 0.80).toString())
    }

    // ---- filter ------------------------------------------------------------------

    function test_filterEditCallsSetViewPerEditWithoutOwnDebounce() {
        ready(100)
        expand()
        var filter = child("aiCsvExplorerFilter")
        compare(filter.placeholderText, "Filter rows…")
        filter.forceActiveFocus(Qt.TabFocusReason)
        keyClick("a")
        keyClick("|")
        compare(mock.calls.length, 2)
        compare(mock.calls[0], ["setView", -1, 1, "a"])
        compare(mock.calls[1], ["setView", -1, 1, "a|"])
        compare(edited.count, 2)
        compare(edited.signalArguments[1][0], {sort: -1, dir: 1, filter: "a|", page: 0})
        compare(child("aiCsvExplorerSortNote").text, "Filtered rows are counted over the whole file")
        keyClick(Qt.Key_Backspace)
        keyClick(Qt.Key_Backspace)
        compare(lastCall("setView"), ["setView", -1, 1, ""])
        compare(child("aiCsvExplorerSortNote").visible, false)
        // Sorting keeps the filter and the filter keeps the sort.
        keyClick("z")
        mouseClick(child("aiCsvExplorerHeader3"), 10, 10)
        compare(lastCall("setView"), ["setView", 3, 1, "z"])
        compare(edited.signalArguments[edited.count - 1][0], {sort: 3, dir: 1, filter: "z", page: 0})
        compare(child("aiCsvExplorerSortNote").text, "Sorted by character code; filtered rows are counted over the whole file")
    }

    function test_noMatchesSaysSo() {
        mock.meta = makeMeta(2, 10, [])
        mock.viewRows = 0
        mock.page = makePage(0, 0, 2, false)
        mock.status = "ready"
        expand()
        verify(child("aiCsvExplorerEmpty").visible)
        compare(child("aiCsvExplorerEmpty").text, "No rows match.")
        compare(child("aiCsvExplorerPage").text, "No rows")
        verify(!child("aiCsvExplorerFocusRing").visible)
        compare(child("aiCsvExplorerViewport").count, 0)
        verify(!child("aiCsvExplorerNext").enabled)
        verify(!child("aiCsvExplorerFirst").enabled)
    }

    // ---- paging ------------------------------------------------------------------

    function test_pagingButtonsClampAndCallGoPage() {
        ready(100)
        expand()
        var first = child("aiCsvExplorerFirst"), prev = child("aiCsvExplorerPrev")
        var next = child("aiCsvExplorerNext"), last = child("aiCsvExplorerLast")
        compare(child("aiCsvExplorerPage").text, "Page 1 of 4")
        verify(!first.enabled && !prev.enabled && next.enabled && last.enabled)
        mouseClick(next, 5, 5)
        compare(mock.calls[mock.calls.length - 1], ["goPage", 1])
        compare(edited.signalArguments[0][0], {sort: -1, dir: 1, filter: "", page: 1})
        // Two quick clicks before the page arrives advance from the requested page.
        mouseClick(next, 5, 5)
        compare(mock.calls[mock.calls.length - 1], ["goPage", 2])
        mock.page = makePage(2, 100, 4, false)
        compare(child("aiCsvExplorerPage").text, "Page 3 of 4")
        compare(child("aiCsvExplorerRange").text, "Rows 51–75 of 100")
        mouseClick(last, 5, 5)
        compare(mock.calls[mock.calls.length - 1], ["goPage", 3])
        mock.page = makePage(3, 100, 4, false)
        verify(!next.enabled && !last.enabled && first.enabled && prev.enabled)
        var before = mock.calls.length
        explorer.goToPage(99)
        compare(mock.calls.length, before, "already on the last page: no call")
        mouseClick(prev, 5, 5)
        compare(mock.calls[mock.calls.length - 1], ["goPage", 2])
        mock.page = makePage(2, 100, 4, false)
        mouseClick(first, 5, 5)
        compare(mock.calls[mock.calls.length - 1], ["goPage", 0])
        explorer.goToPage(-5)
        explorer.goToPage(2.5)
        compare(lastCall("goPage"), ["goPage", 0])
    }

    function test_goToRowClampsToTheViewAndPages() {
        ready(100)
        expand()
        var field = child("aiCsvExplorerGoto")
        compare(field.placeholderText, "Row #")
        field.forceActiveFocus(Qt.TabFocusReason)
        keyClick("5"); keyClick("1"); keyClick(Qt.Key_Return)
        compare(lastCall("goPage"), ["goPage", 2])
        compare(field.text, "")
        compare(edited.signalArguments[edited.count - 1][0].page, 2)
        mock.page = makePage(2, 100, 4, false)
        for (var d = 0; d < 6; ++d) keyClick("9")
        keyClick(Qt.Key_Return)
        compare(lastCall("goPage"), ["goPage", 3], "a row past the end lands on the last page")
        mock.page = makePage(3, 100, 4, false)
        keyClick("1"); keyClick(Qt.Key_Return)
        compare(lastCall("goPage"), ["goPage", 0])
        mock.page = makePage(0, 100, 4, false)
        var count = mock.calls.length
        keyClick("0"); keyClick(Qt.Key_Return)
        compare(mock.calls.length, count, "row 0 is not a row")
        keyClick("x")
        compare(field.text, "", "digits only")
        keyClick(Qt.Key_Return)
        compare(mock.calls.length, count)
    }

    // ---- keyboard in the grid ----------------------------------------------------

    function test_gridKeysScrollThenPage() {
        ready(100, 20)
        expand()
        var grid = child("aiCsvExplorerViewport")
        grid.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(grid, "activeFocus", true)
        compare(child("aiCsvExplorerFocusRing").border.width, 2)
        compare(child("aiCsvExplorerFocusRing").border.color, explorer.accent)
        verify(grid.maxY > 0 && grid.maxX > 0)
        keyClick(Qt.Key_Right)
        compare(grid.contentX, grid.colWidth)
        keyClick(Qt.Key_Left)
        compare(grid.contentX, 0)
        keyClick(Qt.Key_Down)
        compare(grid.contentY, grid.rowH)
        keyClick(Qt.Key_Up)
        compare(grid.contentY, 0)
        // PageDown scrolls a viewport, and only at the bottom turns the page.
        keyClick(Qt.Key_PageDown)
        compare(grid.contentY, Math.min(grid.maxY, grid.height))
        compare(mock.calls.length, 0)
        keyClick(Qt.Key_End)
        compare(grid.contentY, grid.maxY)
        keyClick(Qt.Key_PageDown)
        compare(lastCall("goPage"), ["goPage", 1])
        mock.page = makePage(1, 100, 20, false)
        compare(grid.contentY, 0, "a new page starts at its first row")
        keyClick(Qt.Key_PageUp)
        compare(lastCall("goPage"), ["goPage", 0], "PageUp at the top of a page goes back a page")
        mock.page = makePage(0, 100, 20, false)
        keyClick(Qt.Key_PageUp)
        compare(mock.calls.filter(function(c) { return c[0] === "goPage" }).length, 2, "no page before the first")
        keyClick(Qt.Key_Right); keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Home)
        compare(grid.contentX, 0)
        compare(grid.contentY, 0)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        compare(lastCall("goPage"), ["goPage", 3])
        mock.page = makePage(3, 100, 20, false)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        compare(lastCall("goPage"), ["goPage", 0])
        compare(edited.signalArguments[edited.count - 1][0].page, 0)
    }

    function test_tabOrderRunsToggleFilterGridHeadersFooter() {
        ready(100, 3)
        expand()
        var chain = ["aiCsvExplorerToggle", "aiCsvExplorerFilter", "aiCsvExplorerViewport",
            "aiCsvExplorerHeader0", "aiCsvExplorerHeader1", "aiCsvExplorerHeader2",
            "aiCsvExplorerNext", "aiCsvExplorerLast", "aiCsvExplorerGoto"]
        child("aiCsvExplorerToggle").forceActiveFocus(Qt.TabFocusReason)
        for (var i = 1; i < chain.length; ++i) {
            keyClick(Qt.Key_Tab)
            tryCompare(child(chain[i]), "activeFocus", true, 1000, "tab stop " + chain[i])
        }
    }

    // ---- restore -----------------------------------------------------------------

    function test_restoreAppliesViewStateOnceWithoutEchoing() {
        explorer.viewState = {sort: 2, dir: -1, filter: "lis", page: 3}
        mock.meta = makeMeta(4, 100, [0])
        mock.viewRows = 100
        mock.page = makePage(0, 100, 4, false)
        compare(mock.calls.length, 0, "nothing before the source is ready")
        mock.status = "ready"
        waitForRendering(explorer)
        compare(mock.calls, [["setView", 2, -1, "lis"], ["goPage", 3]])
        compare(edited.count, 0)
        // The owner echoing its own stored state back changes nothing.
        explorer.viewState = {sort: 2, dir: -1, filter: "lis", page: 3}
        explorer.viewState = ({sort: 2, dir: -1, filter: "lis", page: 3})
        mock.status = "ready"
        mock.viewPending = true
        mock.viewPending = false
        compare(mock.calls.length, 2)
        compare(edited.count, 0)
        expand()
        compare(child("aiCsvExplorerFilter").text, "lis")
        compare(child("aiCsvExplorerHeader2").text, "Col 2  ↓")
        compare(child("aiCsvExplorerSortNote").text, "Sorted by character code; filtered rows are counted over the whole file")
        compare(edited.count, 0)
    }

    function test_defaultStateNeedsNoRestoreCalls() {
        explorer.viewState = ({})
        ready(100)
        compare(mock.calls.length, 0)
        compare(edited.count, 0)
    }

    function test_restoreRunsAgainForANewSourceAndSanitisesState() {
        explorer.viewState = {sort: 99, dir: 7, filter: 5, page: -2}
        ready(100)
        compare(mock.calls.length, 0, "an out-of-range state is the default state")
        explorer.viewState = {sort: 1, dir: 1, filter: "", page: 0}
        compare(mock.calls, [["setView", 1, 1, ""], ["goPage", 0]], "later owner changes apply")
        // A re-registered source starts at the default view again.
        mock.calls = []
        mock.meta = makeMeta(4, 100, [0])
        compare(mock.calls, [["setView", 1, 1, ""], ["goPage", 0]])
        compare(edited.count, 0)
        mock.status = "registering"
        mock.status = "ready"
        compare(mock.calls.length, 2, "same meta object: not applied again")
    }

    // ---- errors ------------------------------------------------------------------

    function test_errorIsShownAsGivenWithRetry() {
        ready(100)
        expand()
        explorer._sort = 1
        explorer._dir = -1
        explorer._filter = "x"
        explorer._page = 2
        mock.error = "Stale view."
        mock.retryable = false
        var message = child("aiCsvExplorerError")
        verify(message.visible)
        compare(message.text, "Stale view.")
        compare(message.textFormat, Text.PlainText)
        verify(!child("aiCsvExplorerRetry").visible)
        mock.retryable = true
        var retry = child("aiCsvExplorerRetry")
        verify(retry.visible && retry.enabled)
        retry.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(mock.calls, [["setView", 1, -1, "x"], ["goPage", 2]])
        compare(edited.count, 0, "a retry repeats the state, it is not an edit")
        mock.error = ""
        verify(!message.visible)
        verify(!retry.visible)
    }

    // ---- contrast and disclosure -------------------------------------------------

    function test_informationalTextMeetsTheContrastFloor() {
        ready(100)
        mock.page = makePage(0, 100, 4, true)
        mock.error = "CSV source timed out. Try again."
        explorer.expanded = true
        tryVerify(function() { return child("aiCsvExplorerViewport") !== null })
        var expected = Qt.alpha(explorer.foreground, 0.80).toString()
        var names = ["aiCsvExplorerCount", "aiCsvExplorerPage", "aiCsvExplorerRange", "aiCsvExplorerClipNote"]
        for (var i = 0; i < names.length; ++i) {
            verify(child(names[i]).visible, names[i])
            compare(child(names[i]).color.toString(), expected, names[i])
            compare(child(names[i]).textFormat, Text.PlainText)
        }
        compare(child("aiCsvExplorerClipNote").text, "Long values are clipped")
        compare(child("aiCsvExplorerFilter").placeholderTextColor.toString(), expected)
        compare(child("aiCsvExplorerGoto").placeholderTextColor.toString(), expected)
        mock.page = makePage(0, 100, 4, false)
        verify(!child("aiCsvExplorerClipNote").visible)
    }

    // ---- geometry ----------------------------------------------------------------

    function inside(item, width) {
        var p = item.mapToItem(explorer, 0, 0)
        return p.x >= 0 && p.x + item.width <= width + 0.5
    }

    function checkGeometry(width) {
        explorer.width = width
        ready(4000, 20)
        explorer.expanded = false
        waitForRendering(explorer)
        var collapsed = explorer.implicitHeight
        verify(collapsed > 0 && collapsed < 60, "collapsed " + collapsed)
        expand()
        var grid = child("aiCsvExplorerViewport")
        var frame = child("aiCsvExplorerFocusRing")
        var open = explorer.implicitHeight
        verify(open > collapsed)
        compare(frame.width, width)
        // Everything except the grid's scrolled content fits the width.
        var names = ["aiCsvExplorerToggle", "aiCsvExplorerFilter", "aiCsvExplorerFirst", "aiCsvExplorerPrev",
            "aiCsvExplorerPage", "aiCsvExplorerNext", "aiCsvExplorerLast", "aiCsvExplorerRange", "aiCsvExplorerGoto",
            "aiCsvExplorerFooter", "aiCsvExplorerCount"]
        for (var i = 0; i < names.length; ++i) verify(inside(child(names[i]), width), names[i])
        verify(grid.width <= width)
        verify(grid.contentWidth > grid.width, "twenty columns scroll horizontally")
        verify(grid.needsHorizontalBar)
        // Vertical order: header line, filter, grid, footer, no overlap, all inside the card.
        var count = child("aiCsvExplorerCount")
        var filter = child("aiCsvExplorerFilter")
        var footer = child("aiCsvExplorerFooter")
        verify(count.y + count.height <= filter.mapToItem(explorer, 0, 0).y + 0.5)
        verify(filter.mapToItem(explorer, 0, 0).y + filter.height <= frame.mapToItem(explorer, 0, 0).y + 0.5)
        verify(frame.mapToItem(explorer, 0, 0).y + frame.height <= footer.mapToItem(explorer, 0, 0).y + 0.5)
        verify(footer.mapToItem(explorer, 0, 0).y + footer.height <= open + 0.5)
        console.log("explorer height at width " + width + ": collapsed " + collapsed + ", expanded " + open)
        return {collapsed: collapsed, open: open}
    }

    function test_fitsThePeekCardAt660() { checkGeometry(660) }
    function test_fitsTheDetachedWindowAt720() { checkGeometry(720) }

    function test_footerWrapsInsteadOfOverflowingWhenNarrow() {
        var wide = checkGeometry(660)
        var narrow = checkGeometry(320)
        verify(narrow.open > wide.open, "narrow wraps onto more lines")
    }
}
