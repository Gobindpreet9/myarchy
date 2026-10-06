import QtQuick
import QtQuick.Controls
import QtTest
import ".."

TestCase {
    id: tests
    name: "AiCsvPreview"
    width: 800
    height: 650
    visible: true
    when: windowShown

    AiCsvPreview {
        id: preview
        width: 660
        height: implicitHeight
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
    }

    Item { id: before; activeFocusOnTab: true }
    Item { id: after; activeFocusOnTab: true }
    SignalSpy { id: retrySpy; target: preview; signalName: "retryRequested" }

    function child(name) { return findChild(preview, name) }

    function fixture(rowCount, columnCount) {
        var columns = [], rows = []
        for (var c = 0; c < columnCount; ++c) columns.push("Column " + c)
        for (var r = 0; r < rowCount; ++r) {
            var row = []
            for (c = 0; c < columnCount; ++c) row.push("r" + r + "c" + c)
            rows.push(row)
        }
        return {columns: columns, rows: rows, previewRows: rowCount,
            sampleRows: rowCount, totalRows: rowCount, columnCount: columnCount,
            cellsTruncated: false, columnsTruncated: false, truncated: false, note: ""}
    }

    function ready(data) {
        preview.preview = data
        preview.status = "ready"
        tryVerify(function() { return child("aiCsvPreviewViewport") !== null })
        waitForRendering(preview)
        return child("aiCsvPreviewViewport")
    }

    function init() {
        preview.status = "idle"
        preview.preview = ({})
        preview.error = ""
        preview.width = 660
        before.forceActiveFocus()
        retrySpy.clear()
        wait(0)
    }

    function test_idleIsZeroHeightAndHasNoGrid() {
        compare(preview.implicitHeight, 0)
        compare(preview.height, 0)
        verify(!preview.visible)
        verify(!child("aiCsvPreviewReady").active)
        compare(child("aiCsvPreviewCells"), null)
        ready(fixture(10, 20))
        preview.status = "idle"
        compare(preview.implicitHeight, 0)
        verify(!preview.visible)
        tryVerify(function() { return child("aiCsvPreviewCells") === null })
    }

    function test_readyCountsAndLiteralValues() {
        var data = fixture(2, 2)
        data.columns = ["<b>Name</b>", "Amount & unit"]
        data.rows = [["<img src='x'>", " 001.00 "], ["=SUM(A1:A2)", "line\nbreak"]]
        data.sampleRows = 200
        data.totalRows = 5000
        ready(data)
        compare(child("aiCsvPreviewTitle").text, "CSV preview")
        compare(child("aiCsvPreviewCount").text, "2 of 5000 rows · 2 of 2 columns")
        compare(child("aiCsvPreviewHeaders").count, 2)
        compare(child("aiCsvPreviewCells").count, 4)
        compare(child("aiCsvPreviewHeader0").text, data.columns[0])
        compare(child("aiCsvPreviewHeader0").textFormat, Text.PlainText)
        for (var i = 0; i < 4; ++i) {
            var cell = child("aiCsvPreviewCell" + i)
            compare(cell.text, data.rows[Math.floor(i / 2)][i % 2])
            compare(cell.textFormat, Text.PlainText)
        }
        compare(child("aiCsvPreviewFooter").text,
            "Local preview · UTF-8 · comma-separated · first row is the header. Source is read again when you send.")
        compare(child("aiCsvPreviewCount").textFormat, Text.PlainText)
        compare(child("aiCsvPreviewFooter").textFormat, Text.PlainText)
        compare(child("aiCsvPreviewLoading").color.toString(), Qt.alpha(preview.foreground, 0.80).toString())
        compare(child("aiCsvPreviewCount").color.toString(), Qt.alpha(preview.foreground, 0.80).toString())
        compare(child("aiCsvPreviewFooter").color.toString(), Qt.alpha(preview.foreground, 0.80).toString())
        compare(child("aiCsvPreviewDisclosure").color.toString(), Qt.alpha(preview.foreground, 0.80).toString())
        compare(retrySpy.count, 0)
    }

    function test_loadingDoesNotKeepReadyDelegates() {
        ready(fixture(10, 20))
        preview.status = "loading"
        tryCompare(child("aiCsvPreviewReady"), "active", false)
        tryVerify(function() { return child("aiCsvPreviewCells") === null })
        verify(child("aiCsvPreviewLoading").visible)
        compare(child("aiCsvPreviewLoading").text, "Reading CSV…")
        compare(child("aiCsvPreviewLoading").textFormat, Text.PlainText)
        verify(!child("aiCsvPreviewRetry").visible)
        verify(preview.implicitHeight > 0)
        compare(retrySpy.count, 0)
    }

    function test_errorIsLiteralAndRetryWorksByKeyboardAndMouse() {
        preview.status = "error"
        preview.error = "Cannot read <b>CSV</b> & retry."
        waitForRendering(preview)
        compare(child("aiCsvPreviewError").text, preview.error)
        compare(child("aiCsvPreviewError").textFormat, Text.PlainText)
        verify(child("aiCsvPreviewError").visible)
        var retry = child("aiCsvPreviewRetry")
        verify(retry.visible && retry.enabled)
        retry.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(retry, "activeFocus", true)
        keyClick(Qt.Key_Space)
        compare(retrySpy.count, 1)
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(retrySpy.count, 2)
        compare(preview.status, "error", "Retry emits only; the host owns the next read")
        compare(child("aiCsvPreviewCells"), null)
        preview.error = ""
        compare(child("aiCsvPreviewError").text, "CSV preview is unavailable.")
    }

    function test_unknownTotalsAndSnapshotDisclosures() {
        var data = fixture(10, 20)
        data.totalRows = null
        data.columnCount = 24
        data.sampleRows = 140
        data.columnsTruncated = true
        data.cellsTruncated = true
        data.truncated = true
        data.note = "<b>Sampled 140 rows</b>; source continues."
        ready(data)
        compare(child("aiCsvPreviewCount").text, "10 of unknown rows · 20 of 24 columns")
        var disclosure = child("aiCsvPreviewDisclosure")
        compare(disclosure.textFormat, Text.PlainText)
        verify(disclosure.text.indexOf(data.note) === 0)
        verify(disclosure.text.indexOf("first 20 columns") >= 0)
        verify(disclosure.text.indexOf("values were shortened") >= 0)
        verify(disclosure.text.indexOf("does not contain the complete source") >= 0)
        verify(disclosure.text.indexOf("clipped in the grid") >= 0)
    }

    function test_viewportAndDelegateCountsAreBounded() {
        var pan = ready(fixture(10, 20))
        compare(child("aiCsvPreviewCells").count, 200)
        compare(child("aiCsvPreviewHeaders").count, 20)
        verify(child("aiCsvPreviewScroll").height >= 180)
        verify(child("aiCsvPreviewScroll").height <= 200)
        verify(pan.height <= 200)
        verify(pan.contentWidth > pan.width)
        verify(pan.contentHeight > pan.height)
        // Even malformed oversized UI input cannot instantiate a whole dataset.
        ready(fixture(30, 30))
        compare(child("aiCsvPreviewCells").count, 200)
        compare(child("aiCsvPreviewHeaders").count, 20)
        compare(child("aiCsvPreviewCell200"), null)
    }

    function test_fewColumnsFitAndHeaderOnlyCountsAreHonest() {
        preview.width = 320
        var pan = ready(fixture(0, 2))
        compare(child("aiCsvPreviewCount").text, "0 of 0 rows · 2 of 2 columns")
        compare(child("aiCsvPreviewCells").count, 0)
        verify(pan.columnWidth >= 120)
        verify(pan.contentWidth <= pan.width)
        verify(pan.contentHeight <= pan.height)
    }

    function test_narrowGeometryAndKeyboardScrolling() {
        preview.width = 320
        var pan = ready(fixture(10, 20))
        var scroll = child("aiCsvPreviewScroll")
        compare(scroll.width, 320)
        verify(pan.width > 0 && pan.width <= 320)
        verify(pan.columnWidth >= 120)
        var count = child("aiCsvPreviewCount")
        var footer = child("aiCsvPreviewFooter")
        var disclosure = child("aiCsvPreviewDisclosure")
        verify(count.y + count.height <= scroll.y)
        verify(scroll.y + scroll.height <= footer.y)
        verify(footer.y + footer.height <= disclosure.y)
        compare(footer.width, 320)
        compare(disclosure.width, 320)
        verify(!footer.truncated && !disclosure.truncated)

        // Entry and exit use the native Tab chain, not a custom key trap.
        after.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(pan, "activeFocus", true)
        compare(child("aiCsvPreviewFocusRing").border.width, 2)
        compare(child("aiCsvPreviewFocusRing").border.color, preview.accent)
        waitForRendering(scroll)
        var image = grabImage(scroll)
        compare(image.width, 320)
        compare(image.pixel(1, Math.floor(scroll.height / 2)), preview.accent)
        keyClick(Qt.Key_Right)
        compare(pan.contentX, pan.columnWidth)
        keyClick(Qt.Key_Left)
        compare(pan.contentX, 0)
        keyClick(Qt.Key_Left)
        compare(pan.contentX, 0)
        keyClick(Qt.Key_Down)
        compare(pan.contentY, pan.rowHeight)
        keyClick(Qt.Key_Up)
        compare(pan.contentY, 0)
        keyClick(Qt.Key_Up)
        compare(pan.contentY, 0)
        keyClick(Qt.Key_PageDown)
        verify(pan.contentY > 0)
        for (var i = 0; i < 30; ++i) {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_PageDown)
        }
        compare(pan.contentX, Math.max(0, pan.contentWidth - pan.width))
        compare(pan.contentY, Math.max(0, pan.contentHeight - pan.height))
        var beforePageUp = pan.contentY
        keyClick(Qt.Key_PageUp)
        compare(pan.contentY, Math.max(0, beforePageUp - pan.height))
        keyClick(Qt.Key_PageUp)
        compare(pan.contentY, 0)
        keyClick(Qt.Key_Tab)
        tryVerify(function() { return !pan.activeFocus })
        compare(child("aiCsvPreviewFocusRing").border.width, 1)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(pan, "activeFocus", true)
    }

    function test_narrowErrorStacksMessageAndRetry() {
        preview.width = 320
        preview.status = "error"
        preview.error = "CSV could not be parsed near line 123456 (invalid quotes or oversized field)."
        waitForRendering(preview)
        var message = child("aiCsvPreviewError")
        var retry = child("aiCsvPreviewRetry")
        verify(message.y + message.height <= retry.y)
        verify(retry.x + retry.width <= preview.width)
        verify(!message.truncated)
    }

    function test_scrollbarTracksFollowViewport_data() {
        return [
            {tag: "narrow-overflow", width: 320, rows: 10, columns: 20},
            {tag: "wide-overflow", width: 660, rows: 10, columns: 20},
            {tag: "header-only-fits", width: 320, rows: 0, columns: 2},
            {tag: "rows-fit", width: 320, rows: 2, columns: 2},
            {tag: "horizontal-only", width: 320, rows: 0, columns: 20},
            {tag: "vertical-only", width: 320, rows: 10, columns: 2}
        ]
    }

    function test_scrollbarTracksFollowViewport(data) {
        preview.width = data.width
        var pan = ready(fixture(data.rows, data.columns))
        var scroll = child("aiCsvPreviewScroll")
        var horizontal = scroll.ScrollBar.horizontal
        var vertical = scroll.ScrollBar.vertical
        var viewport = pan.mapToItem(scroll, 0, 0)
        compare(horizontal.visible, pan.contentWidth > pan.width && horizontal.size < 1)
        compare(vertical.visible, pan.contentHeight > pan.height && vertical.size < 1)
        if (horizontal.visible) {
            var h = horizontal.mapToItem(scroll, 0, 0)
            compare(h.x, viewport.x)
            compare(horizontal.width, pan.width)
            verify(h.y >= viewport.y + pan.height, "Horizontal track must not cover cells or headers")
            verify(h.y + horizontal.height <= scroll.height)
            verify(horizontal.size > 0 && horizontal.size < 1)
        }
        if (vertical.visible) {
            var v = vertical.mapToItem(scroll, 0, 0)
            compare(v.y, viewport.y)
            compare(vertical.height, pan.height)
            verify(v.x >= viewport.x + pan.width, "Vertical track must not cover cells or headers")
            verify(v.x + vertical.width <= scroll.width)
            verify(vertical.size > 0 && vertical.size < 1)
        }
    }

    function dragThumb(bar, dx, dy) {
        var thumb = bar.contentItem
        var start = thumb.mapToItem(bar, thumb.width / 2, thumb.height / 2)
        mousePress(bar, start.x, start.y)
        verify(bar.pressed, "A real mouse press must engage the native scrollbar")
        mouseMove(bar, start.x + dx, start.y + dy, 20)
        mouseRelease(bar, start.x + dx, start.y + dy)
    }

    function test_scrollbarMouseDraggingMovesContent() {
        preview.width = 320
        var pan = ready(fixture(10, 20))
        var scroll = child("aiCsvPreviewScroll")
        compare(pan.contentX, 0)
        compare(pan.contentY, 0)
        dragThumb(scroll.ScrollBar.horizontal, 80, 0)
        verify(pan.contentX > 0, "Dragging the horizontal thumb must move the data")
        verify(pan.contentX <= pan.contentWidth - pan.width)
        dragThumb(scroll.ScrollBar.vertical, 0, 40)
        verify(pan.contentY > 0, "Dragging the vertical thumb must move the data")
        verify(pan.contentY <= pan.contentHeight - pan.height)
        var x = pan.contentX, y = pan.contentY
        dragThumb(scroll.ScrollBar.horizontal, -80, 0)
        verify(pan.contentX < x, "Dragging back must move the horizontal content back")
        dragThumb(scroll.ScrollBar.vertical, 0, -40)
        verify(pan.contentY < y, "Dragging back must move the vertical content back")
    }
}
