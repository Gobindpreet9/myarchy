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
    SignalSpy { id: chosenSpy; target: preview; signalName: "columnTypeChosen" }

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
        tryVerify(function() { return child("aiCsvPreviewReady").item !== null })
        waitForRendering(preview)
        return child("aiCsvPreviewViewport")
    }

    function init() {
        preview.status = "idle"
        preview.preview = ({})
        preview.error = ""
        preview.width = 660
        preview.typeOverrides = []
        preview.collapsible = false
        preview.detailOpen = false
        before.forceActiveFocus()
        retrySpy.clear()
        chosenSpy.clear()
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

    function test_errorHintSaysWhatToDoWithoutChangingTheMessage() {
        preview.status = "error"
        preview.error = "Attachment is unavailable or is a symbolic link."
        waitForRendering(preview)
        compare(child("aiCsvPreviewError").text, preview.error, "the static error stays verbatim")
        var hint = child("aiCsvPreviewHint")
        verify(hint.visible)
        compare(hint.textFormat, Text.PlainText)
        verify(hint.text.indexOf("remove the attachment") >= 0)
        verify(child("aiCsvPreviewError").y + child("aiCsvPreviewError").height <= hint.y)
        verify(hint.y + hint.height <= child("aiCsvPreviewRetry").y)
        preview.error = "CSV preview timed out. Retry to read the file again."
        verify(!child("aiCsvPreviewHint").visible, "no hint when the message already says what to do")
        preview.status = "loading"
        verify(!child("aiCsvPreviewHint").visible)
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

    // ---- column types: inference indicators and correction ----

    function typesFixture() {
        var data = fixture(0, 0)
        data.columns = ["City", "Rent", "Since", "Zip", "Share", "Seen"]
        data.rows = [
            ["Oslo", "1200", "2024-01-02", "01234", "12%", "01/02/03"],
            ["Porto", "600", "2023-05-17", "02134", "7.5%", "04/05/06"],
            ["Lisbon", "", "2022-11-30", "90210", "9%", "07/08/09"]
        ]
        data.previewRows = 3
        data.sampleRows = 3
        data.totalRows = 3
        data.columnCount = 6
        return data
    }

    function typeButton(i) { return child("aiCsvPreviewType" + i) }

    function test_everyHeaderShowsItsInferredType() {
        ready(typesFixture())
        compare(child("aiCsvPreviewHeaders").count, 6)
        var expected = ["abc", "123", "date", "abc", "123", "?"]
        var names = ["Text", "Number", "Date", "Text", "Number", "Unsure"]
        for (var i = 0; i < 6; ++i) {
            var button = typeButton(i)
            verify(button !== null && button.visible, "header " + i + " has a type control")
            compare(button.text, expected[i])
            verify(button.Accessible.name.indexOf("type: " + names[i]) >= 0, button.Accessible.name)
            verify(button.Accessible.name.indexOf("inferred") >= 0)
            verify(button.Accessible.name.indexOf("Column " + typesFixture().columns[i]) === 0)
            compare(button.corrected, false)
            verify(button.Accessible.description.length > 0)
            compare(button.Accessible.role, Accessible.Button)
        }
        verify(typeButton(1).Accessible.description.indexOf("2 non-empty values in the rows shown (1 empty)") >= 0,
            typeButton(1).Accessible.description)
        verify(typeButton(5).Accessible.description.indexOf("Day/month order is unclear") >= 0)
        verify(typeButton(3).Accessible.description.indexOf("Leading zeros") >= 0, "postcodes are kept as text")
        compare(chosenSpy.count, 0, "Showing the preview never emits a correction")
    }

    function test_typeNoteDisclosesSampleOnlyInference() {
        ready(typesFixture())
        var note = child("aiCsvPreviewTypeNote")
        verify(note.visible)
        compare(note.textFormat, Text.PlainText)
        verify(note.text.indexOf("inferred from the rows shown, not the whole file") >= 0, note.text)
        verify(note.text.indexOf("Corrected:") < 0, "no corrections yet")
        compare(note.color.toString(), Qt.alpha(preview.foreground, 0.80).toString())
        verify(note.color.a >= 0.76)
        verify(!note.truncated)
        var scroll = child("aiCsvPreviewScroll")
        var footer = child("aiCsvPreviewFooter")
        verify(scroll.y + scroll.height <= note.y)
        verify(note.y + note.height <= footer.y)
    }

    function test_typeIndicatorsStayReadableAndBounded() {
        ready(fixture(10, 20))
        for (var i = 0; i < 20; ++i) {
            var button = typeButton(i)
            verify(button !== null)
            verify(button.width >= 36 && button.height >= 22, "indicator keeps a usable target")
            var label = button.contentItem
            verify(label.color.a >= 0.76, "informational text keeps contrast, got " + label.color.a)
            compare(label.textFormat, Text.PlainText)
            verify(button.x + button.width <= child("aiCsvPreviewViewport").columnWidth + 0.5 + button.parent.x,
                "indicator stays inside its header cell")
        }
        compare(typeButton(20), null, "never more than twenty controls")
        // The header name never overlaps its indicator.
        var header = child("aiCsvPreviewHeader0")
        verify(header.width > 0)
        verify(header.x + header.width <= typeButton(0).x)
    }

    function test_hostCorrectionsAreShownAndNeverInventedByTheComponent() {
        ready(typesFixture())
        compare(typeButton(5).text, "?")
        preview.typeOverrides = ["", "", "", "number", "", "date"]
        compare(typeButton(3).text, "123")
        compare(typeButton(3).corrected, true)
        compare(typeButton(5).text, "date")
        compare(typeButton(5).corrected, true)
        compare(typeButton(1).corrected, false)
        verify(typeButton(3).Accessible.name.indexOf("corrected by you") >= 0)
        verify(typeButton(3).Accessible.description.indexOf("corrected by you") >= 0)
        verify(typeButton(3).Accessible.description.indexOf("Inferred") >= 0, "the inference stays visible")
        compare(typeButton(3).contentItem.color.toString(), preview.accent.toString())
        verify(child("aiCsvPreviewTypeNote").text.indexOf("Corrected: 2 (sent with your question).") >= 0,
            child("aiCsvPreviewTypeNote").text)
        // Unknown or unsafe values are ignored, never displayed.
        preview.typeOverrides = ["bogus", "unsure", "<b>date</b>", 7, null, "Number"]
        for (var i = 0; i < 6; ++i) compare(typeButton(i).corrected, false)
        compare(typeButton(5).text, "?")
        verify(child("aiCsvPreviewTypeNote").text.indexOf("Corrected:") < 0)
        compare(chosenSpy.count, 0)
    }

    function test_correctionByMouse() {
        var pan = ready(typesFixture())
        var button = typeButton(1)
        mouseClick(button, button.width / 2, button.height / 2)
        var menu = child("aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        compare(menu.column, 1)
        compare(chosenSpy.count, 0, "Opening the menu is not a correction")
        var item = menu.itemAt(1)
        compare(item.text, "Date")
        mouseClick(item, item.width / 2, item.height / 2)
        compare(chosenSpy.count, 1)
        compare(chosenSpy.signalArguments[0][0], 1)
        compare(chosenSpy.signalArguments[0][1], "date")
        tryCompare(menu, "opened", false)
        compare(preview.typeOverrides.length, 0, "The component only asks; the host owns corrections")
        compare(typeButton(1).corrected, false)
        tryCompare(typeButton(1), "activeFocus", true)
    }

    function test_correctionByKeyboardOnly() {
        ready(typesFixture())
        child("aiCsvPreviewViewport").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(typeButton(0), "activeFocus", true)
        verify(typeButton(0).visualFocus, "keyboard focus draws the focus ring")
        compare(typeButton(0).background.border.width, 2)
        compare(typeButton(0).background.border.color.toString(), preview.accent.toString())
        // The badges are one Tab stop: Right (not Tab) moves to the next one.
        keyClick(Qt.Key_Right)
        tryCompare(typeButton(1), "activeFocus", true)
        keyClick(Qt.Key_Space)
        var menu = child("aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        compare(menu.column, 1)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Return)
        compare(chosenSpy.count, 1)
        compare(chosenSpy.signalArguments[0][0], 1)
        compare(chosenSpy.signalArguments[0][1], "date")
        tryCompare(menu, "opened", false)
        tryCompare(typeButton(1), "activeFocus", true)
        // Return opens it too; Escape closes without choosing.
        keyClick(Qt.Key_Return)
        tryCompare(menu, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(menu, "opened", false)
        compare(chosenSpy.count, 1, "Escape never corrects a column")
        tryCompare(typeButton(1), "activeFocus", true)
    }

    function test_menuOffersAllThreeTypesAndTheInferredChoice() {
        ready(typesFixture())
        preview.typeOverrides = ["", "", "", "", "", "number"]
        // Column 5 sits partly past the right edge; keyboard focus scrolls it in.
        typeButton(5).forceActiveFocus(Qt.TabFocusReason)
        tryCompare(typeButton(5), "activeFocus", true)
        keyClick(Qt.Key_Space)
        var menu = child("aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        compare(menu.count, 4)
        compare(menu.itemAt(0).text, "Number")
        compare(menu.itemAt(1).text, "Date")
        compare(menu.itemAt(2).text, "Text")
        compare(menu.itemAt(3).text, "Use the inferred type (Unsure)")
        verify(menu.itemAt(0).chosen && !menu.itemAt(1).chosen)
        verify(menu.itemAt(0).Accessible.name.indexOf("selected") >= 0)
        verify(menu.itemAt(0).contentItem.text.indexOf("\u2713") === 0)
        menu.itemAt(3).triggered()
        compare(chosenSpy.signalArguments[0][0], 5)
        compare(chosenSpy.signalArguments[0][1], "", "choosing the inferred type clears the correction")
        menu.close()
        tryCompare(menu, "opened", false)
    }

    function test_focusedLastIndicatorScrollsIntoView() {
        preview.width = 320
        var pan = ready(fixture(10, 20))
        compare(pan.contentX, 0)
        typeButton(19).forceActiveFocus(Qt.TabFocusReason)
        tryCompare(typeButton(19), "activeFocus", true)
        compare(pan.contentX, Math.max(0, pan.contentWidth - pan.width))
        var mapped = typeButton(19).mapToItem(pan, 0, 0)
        verify(mapped.x >= 0 && mapped.x + typeButton(19).width <= pan.width + 0.5,
            "focused control is inside the viewport, x=" + mapped.x)
        typeButton(0).forceActiveFocus(Qt.TabFocusReason)
        tryCompare(typeButton(0), "activeFocus", true)
        compare(pan.contentX, 0)
    }

    function test_typeControlsLeaveWithTheReadyState() {
        ready(typesFixture())
        verify(typeButton(0) !== null)
        preview.status = "loading"
        tryVerify(function() { return typeButton(0) === null })
        tryVerify(function() { return child("aiCsvPreviewTypeNote") === null })
        compare(preview.inferences.length, 0, "no inference outside the ready state")
        compare(chosenSpy.count, 0)
    }

    function test_headerNamesStayLiteralNextToTheIndicator() {
        var data = typesFixture()
        data.columns[0] = "<b>City</b>"
        ready(data)
        compare(child("aiCsvPreviewHeader0").text, "<b>City</b>")
        compare(child("aiCsvPreviewHeader0").textFormat, Text.PlainText)
        verify(typeButton(0).Accessible.name.indexOf("Column <b>City</b> type:") === 0)
    }

    // ---- roving focus: the type badges are ONE Tab stop ----

    function tabStops() {
        var n = 0
        for (var i = 0; i < 20; ++i)
            if (typeButton(i) && (typeButton(i).focusPolicy & Qt.TabFocus)) ++n
        return n
    }

    function test_badgesAreOneTabStopWithTabEnteringOnceAndLeaving() {
        var pan = ready(fixture(10, 20))
        compare(tabStops(), 1, "only the roving badge takes Tab")
        compare(typeButton(0).focusPolicy & Qt.TabFocus, Qt.TabFocus)
        // Grid viewport first, then the badge strip, then the next control.
        after.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(pan, "activeFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(typeButton(0), "activeFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(before, "activeFocus", true)
        for (var i = 0; i < 20; ++i)
            verify(!typeButton(i).activeFocus, "Tab skipped badge " + i)
        compare(chosenSpy.count, 0)
        // The whole walk from the composer side costs three stops, not twenty-two.
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(typeButton(0), "activeFocus", true)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(pan, "activeFocus", true)
    }

    function test_arrowsHomeEndMoveBetweenBadgesAndShiftTabReturnsToTheSame() {
        preview.width = 320
        var pan = ready(fixture(10, 20))
        pan.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        tryCompare(typeButton(0), "activeFocus", true)
        keyClick(Qt.Key_Left)
        tryCompare(typeButton(0), "activeFocus", true, 500, "Left stops at the first badge")
        for (var i = 1; i <= 3; ++i) {
            keyClick(Qt.Key_Right)
            tryCompare(typeButton(i), "activeFocus", true)
            verify(typeButton(i).visualFocus, "focus ring on badge " + i)
            compare(typeButton(i).background.border.width, 2)
        }
        compare(tabStops(), 1)
        compare(typeButton(3).focusPolicy & Qt.TabFocus, Qt.TabFocus, "the Tab stop follows the focus")
        verify(!(typeButton(0).focusPolicy & Qt.TabFocus))
        keyClick(Qt.Key_Tab)
        tryCompare(before, "activeFocus", true)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(typeButton(3), "activeFocus", true)
        keyClick(Qt.Key_End)
        tryCompare(typeButton(19), "activeFocus", true)
        compare(pan.contentX, Math.max(0, pan.contentWidth - pan.width), "End scrolls the last badge into view")
        keyClick(Qt.Key_Right)
        tryCompare(typeButton(19), "activeFocus", true, 500, "Right stops at the last badge")
        keyClick(Qt.Key_Home)
        tryCompare(typeButton(0), "activeFocus", true)
        compare(pan.contentX, 0)
        compare(chosenSpy.count, 0, "Moving between badges never corrects a column")
    }

    function test_downSpaceAndReturnOpenTheMenuAndEscapeReturnsToTheBadge() {
        ready(typesFixture())
        var menu = child("aiCsvPreviewTypeMenu")
        typeButton(2).forceActiveFocus(Qt.TabFocusReason)
        tryCompare(typeButton(2), "activeFocus", true)
        keyClick(Qt.Key_Down)
        tryCompare(menu, "opened", true)
        compare(menu.column, 2)
        keyClick(Qt.Key_Escape)
        tryCompare(menu, "opened", false)
        tryCompare(typeButton(2), "activeFocus", true)
        verify(typeButton(2).visualFocus, "ring is back after the menu")
        compare(chosenSpy.count, 0)
        keyClick(Qt.Key_Space)
        tryCompare(menu, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(menu, "opened", false)
        keyClick(Qt.Key_Return)
        tryCompare(menu, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(menu, "opened", false)
        tryCompare(typeButton(2), "activeFocus", true)
        // Arrows still work after the menu; Tab is still a single stop.
        keyClick(Qt.Key_Right)
        tryCompare(typeButton(3), "activeFocus", true)
        compare(tabStops(), 1)
        compare(chosenSpy.count, 0)
    }

    function test_mouseFocusMakesThatBadgeTheTabStopAndNamesSurvive() {
        ready(typesFixture())
        var button = typeButton(4)
        mouseClick(button, button.width / 2, button.height / 2)
        var menu = child("aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        menu.close()
        tryCompare(menu, "opened", false)
        tryCompare(typeButton(4), "activeFocus", true)
        verify(!typeButton(4).visualFocus, "a mouse-opened menu does not draw the keyboard ring")
        compare(tabStops(), 1)
        compare(typeButton(4).focusPolicy & Qt.TabFocus, Qt.TabFocus)
        keyClick(Qt.Key_Tab)
        tryCompare(before, "activeFocus", true)
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(typeButton(4), "activeFocus", true)
        // Accessible names are unchanged for roving and non-roving badges alike.
        verify(typeButton(0).Accessible.name.indexOf("Column City type: Text, inferred. Press to change.") === 0,
            typeButton(0).Accessible.name)
        verify(typeButton(4).Accessible.description.length > 0)
        compare(typeButton(0).Accessible.role, Accessible.Button)
    }

    function test_rovingIndexIsClampedWhenColumnsShrink() {
        ready(fixture(10, 20))
        typeButton(15).forceActiveFocus(Qt.TabFocusReason)
        tryCompare(typeButton(15), "activeFocus", true)
        ready(fixture(3, 2))
        compare(tabStops(), 1, "one Tab stop even after the strip shrank")
        compare(typeButton(1).focusPolicy & Qt.TabFocus, Qt.TabFocus)
    }

    // ---- collapsible form (a durable source makes the sample secondary) ----

    function test_notCollapsibleStaysFullyOpenLikeBefore() {
        ready(fixture(10, 20))
        verify(!preview.collapsed)
        verify(child("aiCsvPreviewTitle").visible)
        verify(child("aiCsvPreviewCount").visible)
        compare(child("aiCsvPreviewSummary").visible, false)
        verify(child("aiCsvPreviewScroll") !== null)
        verify(!child("aiCsvPreviewToggle").visible)
    }

    function test_collapsibleStartsAsOneSummaryLineWithAToggle() {
        var data = fixture(10, 20)
        data.totalRows = null
        preview.collapsible = true
        ready(data)
        verify(preview.collapsed)
        compare(child("aiCsvPreviewSummary").text, "CSV preview · 10 of unknown rows · 20 of 20 columns")
        compare(child("aiCsvPreviewSummary").textFormat, Text.PlainText)
        verify(child("aiCsvPreviewSummary").color.a >= 0.76)
        verify(!child("aiCsvPreviewTitle").visible, "the summary carries the title")
        tryVerify(function() { return child("aiCsvPreviewScroll") === null }, 1000, "no grid while collapsed")
        compare(child("aiCsvPreviewCells"), null)
        compare(child("aiCsvPreviewType0"), null)
        compare(child("aiCsvPreviewFooter"), null)
        compare(child("aiCsvPreviewDisclosure"), null)
        compare(child("aiCsvPreviewTypeNote"), null)
        var toggle = child("aiCsvPreviewToggle")
        verify(toggle.visible && toggle.enabled)
        compare(toggle.text, "Show")
        compare(toggle.Accessible.name, "CSV preview, collapsed")
        verify(toggle.Accessible.description.length > 0)
        compare(toggle.focusPolicy, Qt.StrongFocus)
        verify(preview.implicitHeight <= 40, "one line, got " + preview.implicitHeight)
    }

    function test_toggleShowsAndHidesByKeyboardAndMouseKeepingTypeCorrectionReachable() {
        preview.collapsible = true
        ready(typesFixture())
        var toggle = child("aiCsvPreviewToggle")
        var collapsedHeight = preview.implicitHeight
        toggle.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(toggle, "activeFocus", true)
        keyClick(Qt.Key_Space)
        tryVerify(function() { return child("aiCsvPreviewViewport") !== null })
        verify(!preview.collapsed)
        compare(child("aiCsvPreviewToggle").text, "Hide")
        compare(child("aiCsvPreviewToggle").Accessible.name, "CSV preview, expanded")
        tryVerify(function() { return preview.implicitHeight > collapsedHeight + 150 })
        verify(!child("aiCsvPreviewCount").visible, "the summary already carries the count")
        verify(child("aiCsvPreviewSummary").visible)
        verify(typeButton(1) !== null, "type correction is reachable once shown")
        tryCompare(child("aiCsvPreviewToggle"), "activeFocus", true)
        // Tab order: toggle -> grid viewport -> the one badge stop.
        keyClick(Qt.Key_Tab)
        tryCompare(child("aiCsvPreviewViewport"), "activeFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(typeButton(0), "activeFocus", true)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Down)
        var menu = child("aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        compare(menu.column, 1)
        menu.itemAt(0).triggered()
        compare(chosenSpy.signalArguments[0][1], "number")
        tryCompare(menu, "opened", false)
        // Hide again with the mouse; focus stays on the toggle.
        toggle = child("aiCsvPreviewToggle")
        mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        verify(preview.collapsed)
        tryVerify(function() { return child("aiCsvPreviewViewport") === null })
        compare(child("aiCsvPreviewToggle").text, "Show")
        tryCompare(preview, "implicitHeight", collapsedHeight)
    }

    function test_collapsedSummaryDisclosesCorrectionsThatStillReachTheModel() {
        preview.collapsible = true
        ready(typesFixture())
        compare(child("aiCsvPreviewSummary").text, "CSV preview · 3 of 3 rows · 6 of 6 columns")
        preview.typeOverrides = ["", "", "", "number", "", "date"]
        compare(child("aiCsvPreviewSummary").text,
            "CSV preview · 3 of 3 rows · 6 of 6 columns · 2 corrected")
        compare(child("aiCsvPreviewType3"), null)
    }

    function test_leavingCollapsibleForgetsTheOpenChoiceAndReopensFully() {
        preview.collapsible = true
        ready(typesFixture())
        preview.detailOpen = true
        tryVerify(function() { return child("aiCsvPreviewViewport") !== null })
        preview.collapsible = false
        verify(!preview.detailOpen)
        verify(child("aiCsvPreviewViewport") !== null, "no source: fully open as before")
        verify(child("aiCsvPreviewCount").visible)
        preview.collapsible = true
        verify(preview.collapsed, "back to the collapsed default")
        tryVerify(function() { return child("aiCsvPreviewViewport") === null })
    }

    function test_collapsedErrorAndLoadingStatesAreUnaffected() {
        preview.collapsible = true
        preview.status = "loading"
        waitForRendering(preview)
        verify(child("aiCsvPreviewTitle").visible)
        verify(child("aiCsvPreviewLoading").visible)
        preview.status = "error"
        preview.error = "CSV attachment is empty."
        waitForRendering(preview)
        verify(child("aiCsvPreviewTitle").visible)
        verify(child("aiCsvPreviewRetry").visible)
        compare(child("aiCsvPreviewToggle"), null)
    }
}
