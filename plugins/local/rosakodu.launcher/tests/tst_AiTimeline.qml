import QtQuick
import QtTest
import ".."
import "../AiTimelineView.js" as View

// The `timeline` block renderer and its pure helpers. The component never owns
// state: every assertion is on what it DISPLAYS or EMITS, with the host (this
// test) applying or refusing the emitted entry exactly like the pane does.
TestCase {
    id: tests
    name: "AiTimeline"
    width: 800
    height: 1200
    visible: true
    when: windowShown

    property color fg: "#f1f2f4"
    property color bg: "#1b1c20"
    property color ac: "#b4c4dc"

    property var block: tests.makeBlock()
    property var saved: undefined
    property bool refuse: false
    property var emitted: []
    property int escapes: 0
    property real boxWidth: 760
    property bool canFocus: false

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    Item {
        id: holder
        y: 20
        width: tests.boxWidth
        height: line.height
        Keys.onEscapePressed: ++tests.escapes
        AiTimeline {
            id: line
            width: holder.width
            block: tests.block
            saved: tests.saved
            foreground: tests.fg
            background: tests.bg
            accent: tests.ac
            canFocus: tests.canFocus
            onStateEdited: function (state) {
                tests.emitted = tests.emitted.concat([JSON.parse(JSON.stringify(state))])
                if (!tests.refuse) tests.saved = state
            }
        }
    }
    Item { id: after; y: 1100; activeFocusOnTab: true; width: 10; height: 10 }

    SignalSpy { id: focusSpy; target: line; signalName: "focusRequested" }

    // The real host wiring (original block indexes, `plan:<i>` keys).
    AiBlocks {
        id: host
        x: 0
        y: 600
        width: 300
        visible: false
        foreground: tests.fg
        background: tests.bg
        accent: tests.ac
        blocks: []
    }
    SignalSpy { id: hostSpy; target: host; signalName: "uiStateEdited" }

    Component {
        id: scrollFixture
        Flickable {
            id: viewport
            width: 320
            height: 240
            contentWidth: width
            contentHeight: scrollColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            property var saved: ({done: []})
            property int edits: 0
            property alias timeline: scrollLine
            Column {
                id: scrollColumn
                width: viewport.width
                Item { width: 1; height: 180 }
                AiTimeline {
                    id: scrollLine
                    width: viewport.width
                    block: tests.numbered(16, 0)
                    saved: viewport.saved
                    foreground: tests.fg
                    background: tests.bg
                    accent: tests.ac
                    onStateEdited: function(state) {
                        ++viewport.edits
                        viewport.saved = state
                    }
                }
                Item { width: 1; height: 180 }
            }
        }
    }

    // ---- fixtures ---------------------------------------------------------
    function item(label, when, minutes, detail) {
        return {label: label, when: when, minutes: minutes, detail: detail}
    }
    function makeBlock() {
        return {type: "timeline", title: "Saturday", items: [
            tests.item("Pack bags", "7:30 am", 30, "Passports first"),
            tests.item("Drive to the coast", "8:15 am", 90, "Stop for coffee on the way"),
            tests.item("Lunch", "12:00 pm", 0, ""),
            tests.item("Hike the headland", "1:00 pm", 150, "Bring water"),
            tests.item("Dinner", "", 60, "")]}
    }
    function numbered(n, minutes) {
        var items = []
        for (var i = 0; i < n; ++i) items.push(tests.item("Step " + (i + 1), "T-" + (n - i), minutes, i % 2 ? "detail " + i : ""))
        return {type: "timeline", title: "Run of show", items: items}
    }
    function setBlock(b) {
        tests.block = null
        tests.saved = undefined
        tests.settle()
        tests.settle()
        tests.block = b
        tests.settle()
    }
    // Layout (Column/Flow/Row) is polished on the next frame, not on assignment.
    function settle() { wait(50) }
    function setWidth(w) {
        tests.boxWidth = w
        tests.settle()
    }

    // ---- scene lookup (a replaced delegate lingers until the event loop) ----
    function walk(it, out) {
        if (!it || out.indexOf(it) >= 0) return out
        out.push(it)
        var kids = it.children || []
        for (var i = 0; i < kids.length; ++i) walk(kids[i], out)
        if (it.contentItem) walk(it.contentItem, out)
        if (it.background) walk(it.background, out)
        return out
    }
    function all() { return walk(line, []) }
    function child(n) {
        var items = tests.all()
        for (var i = 0; i < items.length; ++i) if (items[i].objectName === n) return items[i]
        return null
    }
    function countNamed(prefix) {
        var n = 0, items = tests.all()
        for (var i = 0; i < items.length; ++i)
            if (String(items[i].objectName || "").indexOf(prefix) === 0 && items[i].visible) ++n
        return n
    }
    function isText(it) { return typeof it.textFormat === "number" && typeof it.wrapMode === "number" && typeof it.elide === "number" }
    function visibleTexts() {
        var out = [], items = tests.all()
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (!tests.isText(it) || it.text.length === 0) continue
            var shown = true
            for (var p = it; p && p !== line.parent; p = p.parent) if (!p.visible) shown = false
            if (shown) out.push(it)
        }
        return out
    }
    // Bounds of an item in the timeline's own coordinates.
    function boundsOf(it) {
        var p = it.mapToItem(line, 0, 0)
        return {x: p.x, y: p.y, w: it.width, h: it.height}
    }
    function tabStops() {
        var out = [], items = tests.all()
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it.activeFocusOnTab === true && it.visible) out.push(it.objectName || String(it))
        }
        return out
    }
    function lum(c) {
        function f(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    function ratio(fg, back) {
        var a = fg.a, mix = {r: fg.r * a + back.r * (1 - a), g: fg.g * a + back.g * (1 - a), b: fg.b * a + back.b * (1 - a)}
        var l1 = lum(mix), l2 = lum(back), hi = Math.max(l1, l2), lo = Math.min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
    function lastDone() { return tests.emitted.length ? tests.emitted[tests.emitted.length - 1].done : null }
    function click(row) {
        var r = tests.child("aiTimelineRow_" + row)
        mouseClick(r, 40, r.height / 2)
    }
    function raw(code) { return String.fromCharCode(code) }
    function enterRows() {
        before.forceActiveFocus()
        keyClick(Qt.Key_Tab)
        if (tests.child("aiTimelineNext").visible) {
            compare(tests.child("aiTimelineNext").activeFocus, true, "the genuine header action precedes the rows")
            keyClick(Qt.Key_Tab)
        }
    }

    function init() {
        tests.fg = "#f1f2f4"
        tests.bg = "#1b1c20"
        tests.ac = "#b4c4dc"
        tests.boxWidth = 760
        tests.canFocus = false
        tests.refuse = false
        tests.emitted = []
        tests.escapes = 0
        before.forceActiveFocus()
        line.cursor = 0
        tests.setBlock(tests.makeBlock())
        focusSpy.clear()
        before.forceActiveFocus()
    }

    // ---- pure helpers -------------------------------------------------------
    function test_durationTextBoundaries() {
        var table = [[0, ""], [1, "1 min"], [30, "30 min"], [45, "45 min"], [59, "59 min"], [60, "1 h"], [61, "1 h 1 min"],
            [90, "1 h 30 min"], [119, "1 h 59 min"], [120, "2 h"], [1440, "24 h"], [23040, "384 h"],
            [0.4, ""], [0.5, "1 min"], [59.5, "1 h"], [-5, ""]]
        for (var i = 0; i < table.length; ++i)
            compare(View.durationText(table[i][0]), table[i][1], "durationText(" + table[i][0] + ")")
        compare(View.durationText(NaN), "")
        compare(View.durationText(Infinity), "")
        compare(View.durationText("30"), "", "a string is not a duration")
        compare(View.durationText(null), "")
        compare(View.durationText(undefined), "")
    }
    function test_minutesAreCleanedToWholeBoundedMinutes() {
        compare(View.cleanMinutes(30), 30)
        compare(View.cleanMinutes(29.5), 30)
        compare(View.cleanMinutes(0.4), 0)
        compare(View.cleanMinutes(-3), 0)
        compare(View.cleanMinutes(99999), 1440)
        compare(View.cleanMinutes("45"), 0)
        compare(View.cleanMinutes(NaN), 0)
        compare(View.cleanMinutes(null), 0)
    }
    function test_barFractionsAreRelativeToTheLongestItem() {
        var items = [{minutes: 1440}, {minutes: 1}, {minutes: 30}, {minutes: 0}]
        var f = View.barFractions(items)
        compare(f[0], 1)
        compare(f[1], 1 / 1440)
        compare(f[2], 30 / 1440)
        compare(f[3], 0)
        // One huge item: the 1 minute item is still a visible 6 px bar.
        compare(View.barWidth(f[0], 1440, 300), 300)
        compare(View.barWidth(f[1], 1, 300), 6)
        compare(View.barWidth(f[2], 30, 300), 6)
        compare(View.barWidth(0.5, 720, 300), 150)
        compare(View.barWidth(0, 0, 300), 0, "an unspecified item has no bar")
        compare(View.barWidth(1, 60, 4), 4, "never longer than the room")
        compare(View.barWidth(1, 60, -10), 0)
        compare(View.barWidth(NaN, 60, 300), 6)
        compare(View.barFractions([{minutes: 0}, {minutes: 0}])[0], 0)
        compare(View.barFractions([]).length, 0)
    }
    function test_totalAppearsOnlyForTwoOrMoreDurations() {
        compare(View.totalText([]), "")
        compare(View.totalText([{minutes: 45}, {minutes: 0}]), "", "one duration is not a total")
        compare(View.totalText([{minutes: 45}, {minutes: 15}]), "Total: 1 h")
        compare(View.totalText([{minutes: 45}, {minutes: 0}, {minutes: 50}]), "Total: 1 h 35 min")
        compare(View.totalText([{minutes: 20}, {minutes: 10}]), "Total: 30 min")
        compare(View.totalText([{minutes: 1440}, {minutes: 1440}]), "Total: 48 h")
        compare(View.totalMinutes([{minutes: 5}, {minutes: 0}, {minutes: 7}]), 12)
    }
    function test_normalizeBoundsAndCleansEveryField() {
        var huge = "x".repeat(500)
        var n = View.normalize({type: "timeline", title: "T" + tests.raw(0x202e) + huge, items: [
            {label: "A" + tests.raw(7) + "B" + tests.raw(0x2028) + "C", when: huge, minutes: 12.6, detail: huge},
            "text", null, 7, [1],
            {label: "", when: "x", minutes: 5},
            {label: 12, when: 9, minutes: "3", detail: {a: 1}},
            {label: "Z", when: "<b>1</b>", minutes: -4}]})
        verify(n !== null)
        compare(n.title.length, 160)
        compare(n.title.indexOf(tests.raw(0x202e)), -1)
        compare(n.items.length, 3)
        compare(n.items[0].i, 0)
        compare(n.items[0].label, "A B C")
        compare(n.items[0].when.length, 24)
        compare(n.items[0].detail.length, 160)
        compare(n.items[0].minutes, 13)
        compare(n.items[0].duration, "13 min")
        compare(n.items[1].i, 6, "an unusable entry is skipped, never renumbered")
        compare(n.items[1].label, "12")
        compare(n.items[1].when, "9")
        compare(n.items[1].minutes, 0)
        compare(n.items[1].detail, "")
        compare(n.items[2].when, "<b>1</b>")
        compare(n.items[2].minutes, 0)
        compare(View.normalize(null), null)
        compare(View.normalize("nope"), null)
        compare(View.normalize({items: "nope"}), null)
        compare(View.normalize({items: [null, 3]}), null)
        var many = []
        for (var i = 0; i < 40; ++i) many.push({label: "n" + i, when: "", minutes: 1, detail: ""})
        compare(View.normalize({items: many}).items.length, 16, "at most 16 rows ever")
    }
    function test_restoreDoneDropsStaleDuplicatesAndJunk() {
        var items = View.normalize(tests.makeBlock()).items
        compare(View.restoreDone(items, undefined), [])
        compare(View.restoreDone(items, null), [])
        compare(View.restoreDone(items, "done"), [])
        compare(View.restoreDone(items, {done: "0"}), [])
        compare(View.restoreDone(items, [0, 1]), [])
        compare(View.restoreDone(items, {done: [3, 1, 3, 1, 9, -1, 2.5, "2", null, {}, [0], NaN, 0]}), [0, 1, 3])
        var big = []
        for (var i = 0; i < 500; ++i) big.push(i % 5)
        compare(View.restoreDone(items, {done: big}), [0, 1, 2, 3, 4])
        var flood = []
        for (i = 0; i < 100; ++i) flood.push(100 + i)
        flood.push(2)
        compare(View.restoreDone(items, {done: flood}), [], "only the first 64 entries are even looked at")
        // An authored index that is no longer usable is stale.
        var gap = View.normalize({items: [{label: "a"}, {label: ""}, {label: "c"}]}).items
        compare(View.restoreDone(gap, {done: [0, 1, 2]}), [0, 2])
    }
    function test_toggledComesFromThePersistedEntry() {
        var items = View.normalize(tests.makeBlock()).items
        compare(View.toggled(items, undefined, 2), [2])
        compare(View.toggled(items, {done: [2]}, 2), [])
        compare(View.toggled(items, {done: [4, 0]}, 2), [0, 2, 4])
        compare(View.toggled(items, {done: [9, 1, 1]}, 3), [1, 3], "stale and duplicate entries are cleaned on the way out")
        compare(View.toggled(items, {done: [0]}, 7), null)
        compare(View.toggled(items, {done: [0]}, -1), null)
        compare(View.toggled(items, {done: [0]}, 1.5), null)
        var all16 = []
        for (var i = 0; i < 16; ++i) all16.push(i)
        verify(View.stateBytes({done: all16}) <= View.STATE_BYTES_MAX, "16 done rows are far below 300 B")
    }
    function test_nextUnfinishedUsesAuthoredIndexesAndOriginalOrder() {
        var items = View.normalize({items: [{label: "First"}, null, {label: "Third"}, {label: "Fourth"}, {label: "Fifth"}]}).items
        compare(View.nextUnfinished(items, undefined), 0)
        compare(View.nextUnfinished(items, {done: [4, 0, 99, 4]}), 1, "next is authored index 2, not done-list length")
        compare(items[View.nextUnfinished(items, {done: [4, 0]})].i, 2)
        compare(View.nextUnfinished(items, {done: [4, 2]}), 0, "later completions do not skip an earlier unfinished item")
        compare(View.nextUnfinished(items, {done: [0, 2, 4]}), 2)
        compare(View.nextUnfinished(items, {done: [0, 2, 3, 4]}), -1)
        compare(View.nextUnfinished(items, {done: "all"}), 0)
        compare(View.nextUnfinished([], undefined), -1)
    }
    function test_rowNameAndProgressText() {
        compare(View.rowName({when: "4:00 pm", label: "Leave", duration: "45 min"}, false), "4:00 pm, Leave, 45 min, not done")
        compare(View.rowName({when: "", label: "Leave", duration: ""}, true), "Leave, done")
        compare(View.progressText(2, 5), "2 of 5 done")
    }

    // ---- rendering ----------------------------------------------------------
    function test_rowsRenderInAuthoredOrder() {
        compare(line.usable, true)
        compare(line.items.length, 5)
        compare(tests.child("aiTimelineLabel_0").text, "Pack bags")
        compare(tests.child("aiTimelineLabel_3").text, "Hike the headland")
        compare(tests.child("aiTimelineWhen_1").text, "8:15 am")
        compare(tests.child("aiTimelineWhen_4").visible, false, "an empty `when` shows nothing")
        compare(tests.child("aiTimelineDetail_0").text, "Passports first")
        compare(tests.child("aiTimelineDetail_2").visible, false, "an empty detail shows nothing")
        compare(tests.child("aiTimelineDuration_1").text, "1 h 30 min")
        compare(tests.child("aiTimelineDuration_3").text, "2 h 30 min")
        compare(tests.child("aiTimelineSpan_2").visible, false, "an unspecified duration has no bar and no text")
        compare(tests.child("aiTimelineBar_2").visible, false)
        compare(tests.child("aiTimelineTotal").text, "Total: 5 h 30 min")
        compare(tests.child("aiTimelineProgress").text, "0 of 5 done")
        compare(tests.child("aiTimelineReset").visible, false, "Reset is hidden until something is done")
        compare(tests.child("aiTimelineLabel_0").font.weight, Font.Normal, "label keeps body weight")
        // Rows never overlap and follow each other in order.
        var prev = -1
        for (var i = 0; i < 5; ++i) {
            var b = tests.boundsOf(tests.child("aiTimelineRow_" + i))
            verify(b.y >= prev, "row " + i + " starts below the previous one")
            verify(b.h >= 36, "row " + i + " is at least a 36 px hit target: " + b.h)
            prev = b.y + b.h
        }
    }
    function test_executionHeaderShowsNextAndSingleProgressSummary() {
        compare(line.nextRow, 0)
        compare(line.nextItem.i, 0)
        compare(tests.child("aiTimelineNextLabel").text, "Pack bags")
        compare(tests.child("aiTimelineNext").visible, true)
        compare(tests.child("aiTimelineProgressFill").width, 0)
        compare(tests.countNamed("aiTimelineProgress"), 3, "one text summary plus the decorative track and fill")
        var header = tests.boundsOf(tests.child("aiTimelineHeader"))
        var list = tests.boundsOf(tests.child("aiTimelineList"))
        verify(header.y + header.h <= list.y, "execution summary precedes the intact full timeline")
        compare(tests.emitted.length, 0, "rendering makes no local edit")
    }
    function test_headerTracksNoncontiguousCompletionAndGappedAuthoredItems() {
        tests.setBlock({items: [{label: "First"}, {label: ""}, {label: "Third"}, {label: "Fourth"}, {label: "Fifth"}]})
        tests.saved = {done: [0, 4, 1, 99, 4]}
        tests.settle()
        compare(line.nextRow, 1)
        compare(line.nextItem.i, 2)
        compare(tests.child("aiTimelineNextLabel").text, "Third")
        compare(tests.child("aiTimelineProgress").text, "2 of 4 done")
        compare(tests.child("aiTimelineProgressFill").width, tests.child("aiTimelineProgressTrack").width / 2)
        var next = tests.child("aiTimelineNext")
        mouseClick(next, next.width / 2, next.height / 2)
        tryCompare(tests.child("aiTimelineRow_1"), "activeFocus", true)
        compare(tests.emitted.length, 0, "jumping is navigation, not completion")
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [0, 2, 4], "the actual row toggles its authored index")
        compare(tests.child("aiTimelineNextLabel").text, "Fourth")
        compare(tests.child("aiTimelineLabel_1").text, "Third", "no persisted item or row is reordered")
    }
    function test_allDoneHasClearCompletionAndResetReopensFirstRow() {
        tests.saved = {done: [4, 2, 0, 3, 1]}
        tests.settle()
        compare(line.allDone, true)
        compare(line.nextRow, -1)
        compare(line.nextItem, null)
        compare(tests.child("aiTimelineNextHeading").text, "COMPLETED")
        compare(tests.child("aiTimelineNextLabel").text, "All items done")
        compare(tests.child("aiTimelineNext").visible, false)
        compare(tests.child("aiTimelineProgress").text, "5 of 5 done")
        compare(tests.child("aiTimelineProgressFill").width, tests.child("aiTimelineProgressTrack").width)
        compare(tests.countNamed("aiTimelineRow_"), 5)
        compare(tests.tabStops(), ["aiTimelineRow_0", "aiTimelineReset"])
        line.cursor = 4
        var reset = tests.child("aiTimelineReset")
        mouseClick(reset, reset.width / 2, reset.height / 2)
        tryCompare(tests.child("aiTimelineRow_0"), "activeFocus", true)
        compare(line.allDone, false)
        compare(tests.child("aiTimelineNextLabel").text, "Pack bags")
        compare(tests.lastDone(), [])
    }
    function checkRevealed(viewport, row) {
        var top = row.mapToItem(viewport, 0, 0).y
        verify(top >= -0.5, "focused actual row starts inside the viewport: " + top)
        verify(top + row.height <= viewport.height + 0.5, "focused actual row is fully visible")
        verify(viewport.contentY >= 0)
        verify(viewport.contentY <= Math.max(0, viewport.contentHeight - viewport.height), "scroll remains bounded")
    }
    function test_nextKeyboardActionRevealsActualRowInFlickableWithoutEditing() {
        var viewport = createTemporaryObject(scrollFixture, tests)
        verify(viewport !== null)
        var marks = []
        for (var i = 0; i < 16; ++i) if (i !== 14) marks.push(i)
        viewport.saved = {done: marks}
        tests.settle()
        var next = findChild(viewport, "aiTimelineNext")
        var target = findChild(viewport, "aiTimelineRow_14")
        verify(target.mapToItem(viewport, 0, 0).y > viewport.height, "target really starts offscreen")
        next.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        tryCompare(target, "activeFocus", true)
        tests.settle()
        tests.checkRevealed(viewport, target)
        compare(viewport.timeline.cursor, 14)
        compare(viewport.edits, 0, "navigation makes no persistence or provider request")
        keyClick(Qt.Key_End)
        tests.settle()
        tests.checkRevealed(viewport, findChild(viewport, "aiTimelineRow_15"))
        keyClick(Qt.Key_Home)
        tests.settle()
        tests.checkRevealed(viewport, findChild(viewport, "aiTimelineRow_0"))
        next.forceActiveFocus()
        keyClick(Qt.Key_Space)
        tests.settle()
        tests.checkRevealed(viewport, target)
        keyClick(Qt.Key_Space)
        compare(viewport.edits, 1, "only toggling the actual row edits")
        compare(viewport.timeline.allDone, true)
        var reset = findChild(viewport, "aiTimelineReset")
        reset.forceActiveFocus()
        keyClick(Qt.Key_Space)
        tests.settle()
        var first = findChild(viewport, "aiTimelineRow_0")
        compare(first.activeFocus, true)
        tests.checkRevealed(viewport, first)
        compare(viewport.edits, 2)
    }
    function test_revealingTallerThanViewportAlignsTopAndStaysBounded() {
        var viewport = createTemporaryObject(scrollFixture, tests, {height: 40})
        verify(viewport !== null)
        tests.settle()
        viewport.saved = {done: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]}
        tests.settle()
        viewport.timeline.goToNext()
        tests.settle()
        var target = findChild(viewport, "aiTimelineRow_15")
        verify(target.height > viewport.height)
        compare(target.activeFocus, true)
        compare(target.mapToItem(viewport, 0, 0).y, 0, "oversized actual row aligns at its top, not below the viewport")
        verify(viewport.contentY >= 0 && viewport.contentY <= viewport.contentHeight - viewport.height)
        compare(viewport.edits, 0)
    }
    function test_restoringAndReplacingStateNeverEditsOrMovesFocus() {
        var entries = [undefined, {done: [0, 2, 4]}, {done: [0, 1, 2, 3, 4]}, {done: [999]}, null]
        for (var i = 0; i < entries.length; ++i) {
            tests.saved = entries[i]
            tests.settle()
            compare(tests.emitted.length, 0)
            compare(before.activeFocus, true, "restoration does not grab focus")
            compare(focusSpy.count, 0)
        }
        tests.block = {items: [null, {label: "Restored first"}, {label: "Restored next"}]}
        tests.saved = {done: [1]}
        tests.settle()
        compare(tests.child("aiTimelineNextLabel").text, "Restored next")
        compare(tests.emitted.length, 0)
        compare(before.activeFocus, true)
    }
    function test_barsAreProportionalToTheLongestItem() {
        var longest = tests.child("aiTimelineBar_3"), mid = tests.child("aiTimelineBar_1"), small = tests.child("aiTimelineBar_0")
        verify(longest.width > mid.width && mid.width > small.width)
        // 150 min is the longest: 90 / 150 and 30 / 150 of its bar.
        compare(Math.round(mid.width), Math.round(longest.width * 90 / 150))
        compare(Math.round(small.width), Math.round(longest.width * 30 / 150))
        compare(longest.width, line.barRoom, "the longest bar uses all the room beside its own duration text")
        var b = tests.boundsOf(longest), t = tests.boundsOf(tests.child("aiTimelineDuration_3"))
        verify(b.x + b.w <= t.x + 0.5, "the bar ends before its duration text")
        verify(t.x + t.w <= line.width + 0.5, "the duration text stays inside")
    }
    function test_aTinyDurationBesideAHugeOneStaysVisible() {
        tests.setBlock({type: "timeline", title: "x", items: [tests.item("Overnight", "", 1440, ""), tests.item("Blink", "", 1, "")]})
        var tiny = tests.child("aiTimelineBar_1")
        compare(tiny.width, 6)
        compare(tests.child("aiTimelineDuration_1").text, "1 min", "the duration is also text")
        compare(tests.child("aiTimelineDuration_0").text, "24 h")
        compare(tests.child("aiTimelineTotal").text, "Total: 24 h 1 min")
    }
    function test_totalIsHiddenWithFewerThanTwoDurations() {
        tests.setBlock({type: "timeline", title: "x", items: [tests.item("A", "", 45, ""), tests.item("B", "", 0, "")]})
        compare(tests.child("aiTimelineTotal").visible, false)
        compare(tests.child("aiTimelineDuration_0").text, "45 min")
        tests.setBlock({type: "timeline", title: "x", items: [tests.item("A", "", 45, ""), tests.item("B", "", 15, "")]})
        compare(tests.child("aiTimelineTotal").visible, true)
        compare(tests.child("aiTimelineTotal").text, "Total: 1 h")
    }

    // ---- layout at three widths ------------------------------------------------
    function checkFits(w) {
        var items = tests.all(), bad = []
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (!it.visible || it.width <= 0 || it === line) continue
            var b = tests.boundsOf(it)
            if (b.x < -0.5 || b.x + b.w > w + 0.5) bad.push((it.objectName || it.text || String(it)) + " x=" + b.x + " w=" + b.w)
        }
        compare(bad, [], "no horizontal overflow at " + w)
    }
    function test_layoutAt760IsWide() {
        tests.setWidth(760)
        compare(line.narrow, false)
        var when = tests.boundsOf(tests.child("aiTimelineWhen_0"))
        var node = tests.boundsOf(tests.child("aiTimelineNode_0"))
        var label = tests.boundsOf(tests.child("aiTimelineLabel_0"))
        verify(when.x < node.x && node.x + node.w < label.x, "when | rail | label, left to right")
        compare(when.w, line.whenW)
        verify(line.whenW <= Math.floor(760 * 0.30))
        verify(line.whenW >= Math.ceil(tests.child("aiTimelineWhen_1").implicitWidth) - 1, "sized to the widest `when`")
        // The `when` column is shared: every row's rail sits at the same x.
        compare(tests.boundsOf(tests.child("aiTimelineNode_3")).x, node.x)
        compare(tests.boundsOf(tests.child("aiTimelineLabel_4")).x, label.x)
        // An item without `when` keeps the same column.
        tests.checkFits(760)
    }
    function test_layoutAt420IsStillWide() {
        tests.setWidth(420)
        compare(line.narrow, false)
        verify(line.whenW <= Math.floor(420 * 0.30))
        tests.checkFits(420)
    }
    function test_layoutBelow420MovesWhenAboveTheLabel() {
        tests.setWidth(419)
        compare(line.narrow, true)
        compare(line.whenW, 0)
        var when = tests.boundsOf(tests.child("aiTimelineWhen_0"))
        var label = tests.boundsOf(tests.child("aiTimelineLabel_0"))
        compare(when.x, label.x, "when shares the label's left edge")
        verify(when.y + when.h <= label.y + 0.5, "when sits above the label")
        var row = tests.boundsOf(tests.child("aiTimelineRow_0"))
        verify(label.y + label.h <= row.y + row.h + 0.5, "the label stays inside its row")
        tests.checkFits(419)
        // Without a `when` the label is the first line.
        var bare = tests.boundsOf(tests.child("aiTimelineLabel_4"))
        var bareRow = tests.boundsOf(tests.child("aiTimelineRow_4"))
        verify(bare.y - bareRow.y < label.y - row.y, "no empty `when` line is reserved")
    }
    function test_layoutAt320FitsAndRowsGrowToTheirContent() {
        tests.setWidth(760)
        var wideHeight = line.height
        tests.setWidth(320)
        compare(line.narrow, true)
        verify(line.height > wideHeight, "narrow rows are taller: " + line.height + " vs " + wideHeight)
        tests.checkFits(320)
        var rows = 0, footer = tests.child("aiTimelineFooter")
        for (var i = 0; i < 5; ++i) {
            var r = tests.child("aiTimelineRow_" + i)
            verify(r.height >= 36)
            var d = tests.child("aiTimelineDetail_" + i), l = tests.child("aiTimelineLabel_" + i)
            var b = tests.boundsOf(l)
            verify(b.y + b.h <= tests.boundsOf(r).y + r.height + 0.5, "label " + i + " inside its row")
            if (d.visible) verify(tests.boundsOf(d).y + d.height <= tests.boundsOf(r).y + r.height + 0.5, "detail " + i + " inside its row")
            rows += r.height
        }
        var list = tests.child("aiTimelineList")
        compare(list.height, rows)
        compare(line.height, tests.child("aiTimelineHeader").height + list.height + line.spacing * 2 + footer.height)
        verify(tests.boundsOf(footer).y + footer.height <= line.height + 0.5)
    }
    function test_longUnbrokenTextWrapsInsteadOfOverflowing() {
        var run = "W".repeat(80), when = "V".repeat(24), detail = "D".repeat(160)
        tests.setBlock({type: "timeline", title: "x", items: [tests.item(run, when, 90, detail), tests.item("short", "", 5, "")]})
        var widths = [320, 420, 760]
        for (var i = 0; i < widths.length; ++i) {
            tests.setWidth(widths[i])
            tests.checkFits(widths[i])
            var l = tests.child("aiTimelineLabel_0")
            verify(l.lineCount > 1, "the 80 character label wraps at " + widths[i])
            var row = tests.child("aiTimelineRow_0")
            verify(tests.boundsOf(l).y + l.height <= tests.boundsOf(row).y + row.height + 0.5)
            verify(row.height > 36)
            var next = tests.child("aiTimelineNextLabel")
            verify(next.lineCount > 1, "next label wraps naturally at " + widths[i])
            verify(tests.boundsOf(next).y + next.height <= tests.boundsOf(tests.child("aiTimelineNext")).y, "wrapped next label stays above its action")
        }
    }
    function test_tinyWidthsHaveNoHorizontalOverflowOrInventedDurations() {
        tests.setBlock({items: [{label: "A long unfinished item that needs to wrap naturally without a clock time"},
            {label: "Another item", minutes: 30}]})
        var widths = [200, 240, 320, 420, 760]
        for (var i = 0; i < widths.length; ++i) {
            tests.setWidth(widths[i])
            tests.checkFits(widths[i])
            compare(tests.child("aiTimelineTotal").visible, false, "one stated duration is not a total")
            compare(tests.child("aiTimelineSpan_0").visible, false)
            compare(tests.child("aiTimelineWhen_0").visible, false)
            compare(line.nextItem.minutes, 0)
        }
        tests.setBlock({items: [{label: "No durations"}, {label: "Still unspecified"}]})
        compare(tests.child("aiTimelineFooter").visible, false, "no empty duplicate footer summary")
        compare(tests.child("aiTimelineTotal").visible, false)
        compare(tests.child("aiTimelineProgress").text, "0 of 2 done")
    }
    function test_twoItemsAndSixteenItems() {
        tests.setBlock(tests.numbered(2, 10))
        compare(line.items.length, 2)
        compare(tests.countNamed("aiTimelineRow_"), 2)
        compare(tests.child("aiTimelineTotal").text, "Total: 20 min")
        tests.setBlock(tests.numbered(16, 90))
        compare(line.items.length, 16)
        compare(tests.countNamed("aiTimelineRow_"), 16)
        compare(tests.child("aiTimelineTotal").text, "Total: 24 h")
        tests.setWidth(320)
        tests.checkFits(320)
        tests.setWidth(760)
        tests.checkFits(760)
        // Tab, End, Space reaches and checks the last of 16.
        tests.enterRows()
        keyClick(Qt.Key_End)
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [15])
        compare(tests.child("aiTimelineProgress").text, "1 of 16 done")
    }
    function test_hasNoMoreThanSixteenRowsEvenForAHostileBlock() {
        var many = []
        for (var i = 0; i < 64; ++i) many.push(tests.item("n" + i, "", 1, ""))
        tests.setBlock({type: "timeline", title: "x", items: many})
        compare(line.items.length, 16)
        compare(tests.countNamed("aiTimelineRow_"), 16)
    }
    function test_anUnusableBlockShowsOneLine() {
        tests.setBlock({type: "timeline", title: "x", items: "nope"})
        compare(line.usable, false)
        compare(tests.child("aiTimelineInvalid").visible, true)
        compare(tests.child("aiTimelineInvalid").text, "This timeline can't be shown.")
        compare(tests.countNamed("aiTimelineRow_"), 0)
        compare(tests.child("aiTimelineFooter").visible, false)
        compare(tests.tabStops(), [])
        tests.setBlock(null)
        compare(line.usable, false)
        tests.setBlock(tests.makeBlock())
        compare(line.usable, true)
        compare(tests.child("aiTimelineInvalid").visible, false)
    }

    function test_worksInsideTheBlocksHostWithOriginalIndexes() {
        host.visible = true
        host.blockIndices = [0, 4]
        host.uiState = {"plan:4": {done: [1, 99]}, "plan:0": {done: [0]}}
        host.blocks = [{type: "text", text: "intro"}, tests.makeBlock()]
        tests.settle()
        var view = findChild(host, "aiTimeline")
        verify(view !== null, "the host instantiates the real renderer")
        compare(view.blockIndex, 4)
        compare(view.doneList, [1], "the entry of ITS original index, stale entry dropped")
        compare(findChild(host, "aiTimelineProgress").text, "1 of 5 done")
        var row = findChild(host, "aiTimelineRow_3")
        mouseClick(row, 40, row.height / 2)
        compare(hostSpy.count, 1)
        var args = Array.prototype.slice.call(hostSpy.signalArguments[0])
        compare(args[0], 4)
        compare(args[1], "plan:4")
        compare(JSON.stringify(args[2]), JSON.stringify({done: [1, 3]}))
        host.visible = false
        host.blocks = []
    }

    // ---- model text is data ---------------------------------------------------------
    function test_modelTextIsPlainEverywhere() {
        tests.setBlock({type: "timeline", title: "<b>x</b>", items: [
            tests.item("<script>alert(1)</script>", "<i>now</i>", 5, "<a href=x>go</a> &amp;"),
            tests.item("&lt;two&gt;", "", 7, "<u>d</u>")]})
        compare(tests.child("aiTimelineLabel_0").text, "<script>alert(1)</script>")
        compare(tests.child("aiTimelineWhen_0").text, "<i>now</i>")
        compare(tests.child("aiTimelineDetail_0").text, "<a href=x>go</a> &amp;")
        compare(tests.child("aiTimelineLabel_1").text, "&lt;two&gt;")
        var texts = tests.visibleTexts()
        verify(texts.length >= 8)
        for (var i = 0; i < texts.length; ++i)
            compare(texts[i].textFormat, Text.PlainText, "PlainText: " + texts[i].text)
        verify(tests.child("aiTimelineRow_0").Accessible.name.indexOf("<script>") >= 0, "the name carries the text, not markup")
    }
    function test_controlAndBidiCharactersNeverReachTheScene() {
        tests.setBlock({type: "timeline", title: "x", items: [
            tests.item("a" + tests.raw(0x202e) + "b" + tests.raw(0x2028) + "c" + tests.raw(0x0085) + "d" + tests.raw(0xfeff) + "e", "t" + tests.raw(7), 3, "x" + tests.raw(0x2029) + "y"),
            tests.item("ok", "", 0, "")]})
        compare(tests.child("aiTimelineLabel_0").text, "a b c d e")
        compare(tests.child("aiTimelineWhen_0").text, "t")
        compare(tests.child("aiTimelineDetail_0").text, "x y")
        compare(tests.child("aiTimelineRow_0").Accessible.name, "t, a b c d e, 3 min, not done")
    }

    // ---- done state -------------------------------------------------------------------
    function test_clickTogglesDoneAndEmitsTheFullState() {
        tests.click(1)
        compare(tests.emitted.length, 1)
        compare(tests.emitted[0], {done: [1]})
        compare(tests.child("aiTimelineRow_1").done, true)
        compare(tests.child("aiTimelineCheck_1").visible, true)
        compare(tests.child("aiTimelineCheck_1").text, tests.raw(0x2713))
        compare(tests.child("aiTimelineDone_1").visible, true)
        compare(tests.child("aiTimelineDone_1").text, "Done")
        compare(tests.child("aiTimelineProgress").text, "1 of 5 done")
        compare(tests.child("aiTimelineReset").visible, true)
        compare(tests.child("aiTimelineDone_0").visible, false)
        tests.click(3)
        compare(tests.lastDone(), [1, 3])
        tests.click(0)
        compare(tests.lastDone(), [0, 1, 3], "sorted")
        tests.click(1)
        compare(tests.lastDone(), [0, 3])
        compare(tests.child("aiTimelineProgress").text, "2 of 5 done")
        for (var i = 0; i < tests.emitted.length; ++i) {
            compare(Object.keys(tests.emitted[i]), ["done"])
            verify(View.stateBytes(tests.emitted[i]) <= 300)
        }
        compare(focusSpy.count, 0, "nothing asks the host about a part from here")
    }
    function test_doneStateIsNotColourAlone() {
        tests.saved = {done: [0]}
        tests.settle()
        var done = tests.child("aiTimelineRow_0"), open = tests.child("aiTimelineRow_1")
        compare(done.Accessible.name, "7:30 am, Pack bags, 30 min, done")
        compare(open.Accessible.name, "8:15 am, Drive to the coast, 1 h 30 min, not done")
        compare(tests.child("aiTimelineCheck_0").visible, true)
        compare(tests.child("aiTimelineDone_0").visible, true)
        compare(tests.child("aiTimelineCheck_1").visible, false)
        compare(tests.child("aiTimelineDone_1").visible, false)
        compare(tests.child("aiTimelineLabel_0").font.strikeout, false, "no strike-through")
        compare(tests.child("aiTimelineLabel_0").font.strikeout, false)
        verify(tests.child("aiTimelineLabel_0").color.a < tests.child("aiTimelineLabel_1").color.a, "dimmed")
        verify(tests.child("aiTimelineLabel_0").color.a >= 0.76)
    }
    function test_savedStateIsRestoredCleanly() {
        tests.saved = {done: [3, 1, 3, 9, -1, 2.5, "x", null, 0]}
        tests.settle()
        compare(line.doneList, [0, 1, 3])
        compare(tests.child("aiTimelineProgress").text, "3 of 5 done")
        compare(tests.child("aiTimelineRow_2").done, false)
        // The next edit is composed from the persisted entry and cleans it.
        tests.click(4)
        compare(tests.lastDone(), [0, 1, 3, 4])
        tests.saved = {done: "all"}
        tests.settle()
        compare(tests.child("aiTimelineProgress").text, "0 of 5 done")
        tests.saved = null
        tests.settle()
        compare(line.doneCount, 0)
        tests.saved = {}
        tests.settle()
        compare(line.doneCount, 0)
    }
    function test_aRefusedEditLeavesWhatIsStored() {
        tests.refuse = true
        tests.saved = {done: [2]}
        tests.settle()
        tests.click(0)
        compare(tests.emitted.length, 1)
        compare(tests.lastDone(), [0, 2])
        compare(tests.child("aiTimelineRow_0").done, false, "the display follows the stored entry")
        compare(tests.child("aiTimelineRow_2").done, true)
        compare(tests.child("aiTimelineNextLabel").text, "Pack bags", "next follows persisted state, not the refused edit")
        // The second try is composed from the same stored entry again.
        tests.click(1)
        compare(tests.lastDone(), [1, 2])
    }
    function test_resetClearsEverythingAndKeepsFocus() {
        tests.saved = {done: [0, 2, 4]}
        tests.settle()
        var reset = tests.child("aiTimelineReset")
        compare(reset.visible, true)
        compare(reset.text, "Reset")
        line.cursor = 2
        mouseClick(reset, reset.width / 2, reset.height / 2)
        compare(tests.emitted.length, 1)
        compare(tests.emitted[0], {done: []})
        compare(line.doneCount, 0)
        compare(tests.child("aiTimelineReset").visible, false)
        compare(tests.child("aiTimelineProgress").text, "0 of 5 done")
        tryCompare(tests.child("aiTimelineRow_0"), "activeFocus", true, 5000, "Reset restarts at the first row")
    }
    function test_resetIsReachableByKeyboardAfterTheRows() {
        tests.saved = {done: [1]}
        tests.settle()
        tests.enterRows()
        compare(tests.child("aiTimelineRow_0").activeFocus, true)
        keyClick(Qt.Key_Tab)
        compare(tests.child("aiTimelineReset").activeFocus, true)
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [])
        tryCompare(tests.child("aiTimelineRow_0"), "activeFocus", true)
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true, "the preceding header action does not add row stops")
    }
    function test_replacingTheBlockDropsStaleStateNotTheRows() {
        tests.saved = {done: [0, 1, 4]}
        tests.settle()
        var two = {type: "timeline", title: "y", items: [tests.item("One", "", 1, ""), tests.item("Two", "", 2, "")]}
        tests.block = two
        tests.settle()
        compare(line.doneList, [0, 1])
        compare(tests.child("aiTimelineProgress").text, "2 of 2 done")
    }

    // ---- keyboard --------------------------------------------------------------------
    function test_oneTabStopWithRovingFocus() {
        compare(tests.tabStops(), ["aiTimelineNext", "aiTimelineRow_0"])
        keyClick(Qt.Key_Tab)
        compare(tests.child("aiTimelineNext").activeFocus, true)
        keyClick(Qt.Key_Tab)
        compare(tests.child("aiTimelineRow_0").activeFocus, true)
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true, "the whole list is ONE stop (Reset is hidden)")
        keyClick(Qt.Key_Backtab)
        compare(tests.child("aiTimelineRow_0").activeFocus, true)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Down)
        compare(tests.child("aiTimelineRow_2").activeFocus, true)
        compare(tests.tabStops(), ["aiTimelineNext", "aiTimelineRow_2"], "one genuine jump button and one cursor row")
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true)
        keyClick(Qt.Key_Backtab)
        compare(tests.child("aiTimelineRow_2").activeFocus, true, "Shift+Tab returns to the cursor row")
    }
    function test_arrowsHomeEndAndClamping() {
        tests.enterRows()
        keyClick(Qt.Key_Up)
        compare(tests.child("aiTimelineRow_0").activeFocus, true, "Up at the top stays")
        keyClick(Qt.Key_End)
        compare(tests.child("aiTimelineRow_4").activeFocus, true)
        keyClick(Qt.Key_Down)
        compare(tests.child("aiTimelineRow_4").activeFocus, true, "Down at the bottom stays")
        keyClick(Qt.Key_Up)
        compare(tests.child("aiTimelineRow_3").activeFocus, true)
        keyClick(Qt.Key_Home)
        compare(tests.child("aiTimelineRow_0").activeFocus, true)
        compare(tests.emitted.length, 0, "moving never toggles")
    }
    function test_spaceAndEnterToggleTheFocusedRow() {
        tests.enterRows()
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [1])
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [])
        keyClick(Qt.Key_Return)
        compare(tests.lastDone(), [1])
        keyClick(Qt.Key_Enter)
        compare(tests.lastDone(), [])
        compare(tests.child("aiTimelineRow_1").activeFocus, true, "focus stays on the row")
        compare(tests.emitted.length, 4)
    }
    function test_escapeAndOtherKeysAreNotCaptured() {
        tests.enterRows()
        keyClick(Qt.Key_Escape)
        compare(tests.escapes, 1, "Escape bubbles to the surface")
        keyClick(Qt.Key_Left)
        keyClick(Qt.Key_PageDown)
        keyClick(Qt.Key_A)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        keyClick(Qt.Key_Space, Qt.ControlModifier)
        compare(tests.emitted.length, 0)
        compare(tests.child("aiTimelineRow_0").activeFocus, true)
    }
    function test_theClickedRowBecomesTheCursor() {
        tests.click(3)
        compare(tests.child("aiTimelineRow_3").activeFocus, true)
        compare(line.cursor, 3)
        compare(tests.tabStops(), ["aiTimelineNext", "aiTimelineRow_3", "aiTimelineReset"], "one jump button, one row and Reset")
        keyClick(Qt.Key_Up)
        compare(tests.child("aiTimelineRow_2").activeFocus, true)
    }
    function test_focusRingIsTwoPixelAccent() {
        tests.enterRows()
        var ring = tests.child("aiTimelineRow_0").children[0]
        compare(ring.border.width, 2)
        compare(ring.border.color, tests.ac)
        keyClick(Qt.Key_Down)
        compare(tests.child("aiTimelineRow_0").children[0].border.width, 0)
        compare(tests.child("aiTimelineRow_1").children[0].border.width, 2)
    }

    // ---- ask about a row (`?`) ----------------------------------------------------
    function asked(i) { return Array.prototype.slice.call(focusSpy.signalArguments[i]) }
    function test_askPartIsAuthoredIndexLabelAndJoinedDetail() {
        var items = View.normalize(tests.makeBlock()).items
        compare(View.askPart(items[1]), {index: 1, label: "Drive to the coast",
            detail: "8:15 am; 1 h 30 min; Stop for coffee on the way"})
        compare(View.askPart(items[2]), {index: 2, label: "Lunch", detail: "12:00 pm"})
        compare(View.askPart(items[4]), {index: 4, label: "Dinner", detail: "1 h"})
        compare(View.askPart({i: 3, label: "Bare", when: "", duration: "", detail: ""}), {index: 3, label: "Bare", detail: ""})
        var long = View.askPart({i: 0, label: "x", when: "w", duration: "1 min", detail: "d".repeat(400)})
        compare(long.detail.length, 240, "clamped to the seam's detail bound")
        // A clamp never leaves half a surrogate pair.
        var pair = tests.raw(0xd83d) + tests.raw(0xde00)
        var cut = View.askPart({i: 0, label: "x", when: "", duration: "", detail: "a".repeat(239) + pair})
        compare(cut.detail, "a".repeat(239))
        // Hostile text is cleaned by normalize before it gets here.
        var n = View.normalize({items: [{label: "<b>A" + tests.raw(0x202e) + "</b>", when: "t" + tests.raw(7), minutes: 5,
            detail: "x" + tests.raw(0x2028) + "y"}]}).items[0]
        compare(View.askPart(n), {index: 0, label: "<b>A </b>", detail: "t; 5 min; x y"})
    }
    function test_questionMarkIsInertWhileTheGateIsClosed() {
        tests.canFocus = false
        tests.enterRows()
        keyClick(Qt.Key_Question, Qt.ShiftModifier)
        keyClick("?")
        compare(focusSpy.count, 0)
        compare(tests.emitted.length, 0)
    }
    function test_questionMarkAsksAboutTheCursorRowWhenOpen() {
        tests.canFocus = true
        tests.enterRows()
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Question, Qt.ShiftModifier)
        compare(focusSpy.count, 1)
        compare(tests.asked(0), [1, "Drive to the coast", "8:15 am; 1 h 30 min; Stop for coffee on the way"])
        keyClick(Qt.Key_End)
        keyClick("?")
        compare(focusSpy.count, 2)
        compare(tests.asked(1), [4, "Dinner", "1 h"])
        compare(tests.child("aiTimelineRow_4").activeFocus, true, "asking does not move focus")
        compare(tests.escapes, 0)
    }
    function test_questionMarkWithCtrlAltMetaIsIgnored() {
        tests.canFocus = true
        tests.enterRows()
        keyClick(Qt.Key_Question, Qt.ControlModifier | Qt.ShiftModifier)
        keyClick(Qt.Key_Question, Qt.AltModifier | Qt.ShiftModifier)
        keyClick(Qt.Key_Question, Qt.MetaModifier | Qt.ShiftModifier)
        keyClick("?", Qt.ControlModifier)
        compare(focusSpy.count, 0)
    }
    function test_askingNeverChangesDoneAndToggleStillWorks() {
        tests.canFocus = true
        tests.saved = {done: [0]}
        tests.settle()
        tests.enterRows()
        keyClick(Qt.Key_Question, Qt.ShiftModifier)
        compare(focusSpy.count, 1)
        compare(tests.asked(0)[0], 0)
        compare(tests.emitted.length, 0, "a question is not an edit")
        compare(line.doneList, [0])
        keyClick(Qt.Key_Space)
        compare(tests.lastDone(), [])
        compare(focusSpy.count, 1)
    }
    function test_askedRowCarriesCleanedHostileText() {
        tests.canFocus = true
        tests.setBlock({type: "timeline", title: "x", items: [
            tests.item("<i>Go</i>" + tests.raw(0x202e), "t" + tests.raw(0x2029), 0, "d".repeat(300)),
            tests.item("b", "", 0, "")]})
        tests.enterRows()
        keyClick("?")
        compare(focusSpy.count, 1)
        var a = tests.asked(0)
        compare(a[0], 0)
        compare(a[1], "<i>Go</i>")
        compare(a[2], "t; " + "d".repeat(160))
        compare(a[2].length <= 240, true)
    }

    // ---- accessibility ---------------------------------------------------------------
    function test_rowsAreCheckBoxesWithTheFullName() {
        var row = tests.child("aiTimelineRow_1")
        compare(row.Accessible.role, Accessible.CheckBox)
        compare(row.Accessible.checkable, true)
        compare(row.Accessible.checked, false)
        compare(row.Accessible.name, "8:15 am, Drive to the coast, 1 h 30 min, not done")
        compare(row.Accessible.description, "Stop for coffee on the way")
        compare(tests.child("aiTimelineRow_2").Accessible.name, "12:00 pm, Lunch, not done")
        compare(tests.child("aiTimelineRow_4").Accessible.name, "Dinner, 1 h, not done")
        tests.saved = {done: [1]}
        tests.settle()
        compare(row.Accessible.checked, true)
        compare(row.Accessible.name, "8:15 am, Drive to the coast, 1 h 30 min, done")
        compare(line.Accessible.role, Accessible.List)
        compare(line.Accessible.name, "Saturday")
        compare(tests.child("aiTimelineProgress").Accessible.name, "1 of 5 done")
        compare(tests.child("aiTimelineTotal").Accessible.name, "Total: 5 h 30 min")
        compare(tests.child("aiTimelineReset").Accessible.name, "Reset")
        var next = tests.child("aiTimelineNext")
        compare(next.Accessible.role, Accessible.Button)
        compare(next.Accessible.name, "Go to next unfinished")
        compare(next.Accessible.description, "Focus Pack bags in the timeline; does not mark it done")
        compare(tests.child("aiTimelineNextLabel").Accessible.name, "Next unfinished: Pack bags")
        compare(tests.child("aiTimelineProgressTrack").Accessible.ignored, true)
    }
    function test_anEditAnnouncesWithoutThrowing() {
        // The polite announcement is an assistive-technology call that offscreen
        // cannot observe; the guarded call must never break the edit itself.
        tests.click(0)
        compare(tests.lastDone(), [0])
        tests.settle()
        var reset = tests.child("aiTimelineReset")
        mouseClick(reset, reset.width / 2, reset.height / 2)
        compare(tests.lastDone(), [])
    }

    // ---- contrast --------------------------------------------------------------------
    function checkContrast(label, withDone) {
        var back = tests.bg, texts = tests.visibleTexts(), seen = 0
        for (var i = 0; i < texts.length; ++i) {
            var t = texts[i]
            if (t.objectName.indexOf("aiTimelineCheck_") === 0) continue   // glyph on the accent fill, below
            ++seen
            verify(t.color.a >= 0.76 - 1e-9, label + ": alpha floor " + t.color.a + " for " + t.text)
            verify(tests.ratio(t.color, back) >= 4.5, label + ": contrast " + tests.ratio(t.color, back) + " for " + t.text)
        }
        verify(seen >= 12, label + ": the matrix saw the timeline's text: " + seen)
        // Non-text: the bar, the open node's outline and the check on the accent fill.
        var bar = tests.child("aiTimelineBar_1")
        verify(tests.ratio(bar.color, back) >= 3, label + ": bar contrast " + tests.ratio(bar.color, back))
        var open = tests.child("aiTimelineNode_2")
        verify(tests.ratio(open.border.color, back) >= 3, label + ": open node outline")
        if (withDone !== false) {
            var doneNode = tests.child("aiTimelineNode_0")
            verify(tests.ratio(doneNode.color, back) >= 3, label + ": done node fill")
        }
    }
    function test_everyTextStateMeetsTheContrastFloor() {
        tests.checkContrast("idle", false)
        tests.saved = {done: [0, 1, 3]}
        tests.settle()
        tests.checkContrast("some done")
        tests.saved = {done: [0, 1, 2, 3, 4]}
        tests.settle()
        tests.checkContrast("all done")
        // The check glyph sits on the accent fill.
        var glyph = tests.child("aiTimelineCheck_0")
        verify(glyph.visible)
        verify(tests.ratio(glyph.color, tests.ac) >= 3, "check on accent: " + tests.ratio(glyph.color, tests.ac))
        verify(tests.ratio(tests.child("aiTimelineBar_1").color, tests.bg) >= 3, "dimmed bar of a done row")
        tests.setWidth(320)
        tests.checkContrast("narrow")
        // The same floors on a light surface.
        tests.fg = "#1b1c20"
        tests.bg = "#f1f2f4"
        tests.ac = "#2b4a7a"
        wait(10)
        tests.saved = undefined
        tests.settle()
        tests.checkContrast("light idle", false)
        tests.saved = {done: [0, 1, 3]}
        tests.settle()
        tests.checkContrast("light done")
        verify(tests.ratio(tests.child("aiTimelineCheck_0").color, tests.ac) >= 3)
    }
}
