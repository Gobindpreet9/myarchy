import QtQuick
import QtTest
import ".." as Launcher
import "../AiState.js" as AiState

// "Ask about this": the descriptor helper (label/detail rules), the per-part
// controls on the existing renderers, the gate, the `?` keyboard path and the
// composer chip. The service side (setFocus validation, one-shot attach,
// clearing) is pinned by AiSeamsServiceCheck.
TestCase {
    id: tests
    name: "AiFocus"
    width: 760
    height: 700
    visible: true
    when: windowShown

    readonly property string bel: String.fromCharCode(7)
    readonly property string rlo: String.fromCharCode(0x202e)
    readonly property string zwsp: String.fromCharCode(0x200b)
    readonly property string lsep: String.fromCharCode(0x2028)

    // ---------------------------------------------------------------- fixtures
    property var tableBlock: ({type: "table", title: "Cities", columns: ["City", "Rent", "Notes"], rows: [
        ["Oslo", "1200", "Pricey"], ["Porto", "600", ""], ["Lisbon", "900", "Sunny"], ["Berlin", "1000", "Big"]]})
    property var stepsBlock: ({type: "steps", title: "Boil an egg", steps: [
        {label: "Fill the pot", detail: "Cover the egg by 2 cm."}, {label: "Boil", detail: "Gentle, 7 minutes."},
        {label: "Cool", detail: ""}]})
    property var galleryBlock: ({type: "gallery", title: "Arches", items: [
        {query: "pointed gothic arch", caption: "Pointed arches"}, {query: "roman round arch", caption: ""}]})
    property var diagramBlock: ({type: "diagram", title: "Cell", caption: "A cell", aspect: 1.6, parts: [
        {shape: "circle", x: 10, y: 10, w: 40, h: 40, label: "Nucleus", detail: "Holds the DNA.", tone: "accent", fill: true, rotation: 0},
        {shape: "rect", x: 60, y: 10, w: 20, h: 20, label: "", detail: "A membrane-bound sac.", tone: "foreground", fill: false, rotation: 0},
        {shape: "text", x: 10, y: 70, w: 50, h: 10, label: "Decoration", detail: "", tone: "muted", fill: false, rotation: 0}]})
    property var chartBlock: ({type: "chart", title: "Sales", unit: "units", labels: ["Jan", "Feb", "Mar"], values: [3, 7, 5],
        source: "", asOf: ""})
    property var marketBlock: ({type: "market", title: "ACME", symbol: "ACME", range: "1mo",
        points: [{label: "Mon", value: 1}, {label: "Tue", value: 2}], source: "", asOf: ""})

    // Original block indexes are deliberately NOT the list positions.
    readonly property var originalIndexes: [2, 3, 4, 0, 1, 5]

    Flickable {
        id: viewport
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: renderer.implicitHeight
        Launcher.AiBlocks {
            id: renderer
            width: viewport.width
            mediaRoot: "/tmp/opencode/s1-media"
            foreground: "#eeeeee"
            background: "#222222"
            accent: "#88bbff"
            blocks: []
        }
    }
    SignalSpy { id: focusSpy; target: renderer; signalName: "focusRequested" }
    SignalSpy { id: stateSpy; target: renderer; signalName: "uiStateEdited" }

    function init() {
        tests.width = 760
        renderer.canFocus = false
        renderer.uiState = null
        renderer.blocks = []
        wait(10)
        renderer.blockIndices = tests.originalIndexes
        renderer.blocks = [tableBlock, stepsBlock, galleryBlock, diagramBlock, chartBlock, marketBlock]
        focusSpy.clear(); stateSpy.clear()
        wait(40)
    }

    function args(spy, index) { return Array.prototype.slice.call(spy.signalArguments[index]) }
    function tabStops(item) {
        var found = []
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            if (child.activeFocusOnTab === true && child.visible && child.enabled) found.push(child)
            found = found.concat(tabStops(child))
        }
        return found
    }
    function plainDescriptors(block) { return JSON.parse(JSON.stringify(AiState.askParts(block))) }
    function wireOf(descriptor) {
        return AiState.focusWire({turnId: 7, blockIndex: 1, kind: descriptor.kind, index: descriptor.index,
            label: descriptor.label, detail: descriptor.detail})
    }

    // ------------------------------------------------- descriptor rules (pure)
    function test_tableRowLabelIsTheFirstNonEmptyCellAndDetailPairsHeaders() {
        var parts = plainDescriptors(tableBlock)
        compare(parts.length, 4)
        compare(parts[0].kind, "table")
        compare(parts[0].index, 0)
        compare(parts[0].label, "Oslo")
        compare(parts[0].detail, "City: Oslo; Rent: 1200; Notes: Pricey")
        compare(parts[1].detail, "City: Porto; Rent: 600", "an empty cell is left out")
        var leading = plainDescriptors({type: "table", columns: ["A", "B"], rows: [["", "second"], ["  ", "\n"]]})
        compare(leading[0].label, "second", "the first NON-EMPTY cell")
        compare(leading[0].detail, "B: second")
        compare(leading[1], null, "an all-blank row offers nothing")
        var missing = plainDescriptors({type: "table", columns: ["Only"], rows: [["a", "b"]]})
        compare(missing[0].detail, "Only: a; Column 2: b", "a missing header is named by position")
    }

    function test_tableCellsAreCleanedAndEveryClampHolds() {
        var hostile = plainDescriptors({type: "table", columns: ["Na" + bel + "me", rlo + "Value"], rows: [
            [bel + "Ev" + rlo + "il" + zwsp + lsep + "row", "x\ny"],
            ["L".repeat(300), "V".repeat(300)], [null, {a: 1}], 42, "not a row", [1234, true]]})
        compare(hostile.length, 6)
        compare(hostile[0].label, "Ev il row")
        compare(hostile[0].detail, "Na me: Ev il row; Value: x y")
        for (var i = 0; i < hostile.length; ++i) {
            if (!hostile[i]) continue
            verify(hostile[i].label.length <= 80, "label clamp " + i)
            verify(hostile[i].detail.length <= 240, "detail clamp " + i)
            verify(!/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e]/.test(hostile[i].label + hostile[i].detail), "controls stripped " + i)
        }
        compare(hostile[1].label.length, 80)
        compare(hostile[1].detail.length, 240)
        compare(hostile[2], null, "null / object cells are not text")
        compare(hostile[3], null)
        compare(hostile[4], null)
        compare(hostile[5].label, "1234", "a number cell is read as its text")
        compare(plainDescriptors({type: "table", columns: null, rows: "nope"}).length, 0)
        compare(plainDescriptors(null).length, 0)
        compare(plainDescriptors("x").length, 0)
    }

    function test_rowsBeyondTheWireBoundAreNotAddressable() {
        var rows = []
        for (var i = 0; i < 90; ++i) rows.push(["r" + i])
        var parts = plainDescriptors({type: "table", columns: ["C"], rows: rows})
        compare(parts.length, 64, "at most index 63")
        compare(parts[63].index, 63)
        verify(wireOf(parts[63]) !== null)
    }

    function test_stepsGalleryDiagramChartDescriptors() {
        var steps = plainDescriptors(stepsBlock)
        compare(steps[1].kind, "steps")
        compare(steps[1].index, 1)
        compare(steps[1].label, "Boil")
        compare(steps[1].detail, "Step 2 of 3. Gentle, 7 minutes.")
        compare(steps[2].detail, "Step 3 of 3", "no detail: just the position")
        compare(plainDescriptors({type: "steps", steps: [{label: "", detail: "x"}]})[0], null)

        var gallery = plainDescriptors(galleryBlock)
        compare(gallery[0].kind, "gallery")
        compare(gallery[0].label, "Pointed arches")
        compare(gallery[0].detail, "Example 1 of 2. Image of: pointed gothic arch")
        compare(gallery[1].label, "roman round arch", "no caption: the query names it")
        compare(gallery[1].detail, "Example 2 of 2")

        var diagram = plainDescriptors(diagramBlock)
        compare(diagram[0].kind, "diagram")
        compare(diagram[0].label, "Nucleus")
        compare(diagram[0].detail, "Holds the DNA.")
        compare(diagram[1].label, "rect", "an unlabelled node is named by its shape")
        compare(diagram[2], null, "a node without a detail is not selectable, so not askable")

        var chart = plainDescriptors(chartBlock)
        compare(chart.length, 3)
        compare(chart[2].kind, "chart")
        compare(chart[2].index, 2)
        compare(chart[2].label, "Mar")
        compare(chart[2].detail, "Sales: Mar = 5 units. Observation 3 of 3")
        compare(plainDescriptors(marketBlock).length, 0, "market is not a focus kind")
        compare(plainDescriptors({type: "text", text: "x"}).length, 0)
        compare(plainDescriptors({type: "calc", title: "c"}).length, 0, "calc is not offered here")
    }

    function test_chartPointsMatchTheRendererAndLongSeriesStayWithinTheWireBound() {
        var labels = [], values = []
        for (var i = 0; i < 100; ++i) { labels.push("P" + i); values.push(i) }
        values[3] = null          // a non-finite point is dropped by the renderer too
        var parts = plainDescriptors({type: "chart", title: "Long", unit: "", labels: labels, values: values})
        compare(parts.length, 99)
        compare(parts[3].label, "P4", "position follows the filtered series, like AiChart.points")
        compare(parts[62].index, 62)
        compare(parts[63].index, 63)
        compare(parts[64].index, -1, "past the bound the point is addressed by label and detail")
        compare(parts[98].label, "P99")
        verify(parts[98].detail.indexOf("P99 = 99") > 0)
        for (var k = 0; k < parts.length; ++k) verify(wireOf(parts[k]) !== null, "wire " + k)
        // The renderer keeps the first 120 observations; so does the helper.
        var many = []
        for (var m = 0; m < 200; ++m) many.push(m)
        compare(plainDescriptors({type: "chart", labels: [], values: many}).length, 120)
    }

    function test_everyDescriptorIsAcceptedByTheServiceValidator() {
        var blocks = [tableBlock, stepsBlock, galleryBlock, diagramBlock, chartBlock]
        for (var b = 0; b < blocks.length; ++b) {
            var parts = plainDescriptors(blocks[b])
            for (var p = 0; p < parts.length; ++p) {
                if (!parts[p]) continue
                var wire = wireOf(parts[p])
                verify(wire !== null, blocks[b].type + " " + p)
                compare(wire.kind, blocks[b].type)
                compare(wire.label, parts[p].label)
                compare(wire.detail, parts[p].detail)
            }
        }
    }

    // ------------------------------------------------------------- renderers
    function test_gateClosedShowsNothingAndTheKeyIsInert() {
        verify(!renderer.canFocus)
        var asks = ["aiTableAsk_0", "aiStepAsk_3_0", "aiGalleryAsk_4_0", "aiDiagramAsk", "aiChartAsk"]
        for (var i = 0; i < asks.length; ++i) {
            var control = findChild(renderer, asks[i])
            verify(control === null || !control.visible, asks[i] + " must not be shown")
        }
        var body = findChild(renderer, "aiTableRows")
        verify(body !== null)
        compare(body.enabled, false, "no Tab stop for the rows")
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        var step = findChild(renderer, "aiStep_3_1")
        step.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        findChild(renderer, "aiChart").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        findChild(renderer, "aiDiagramPart_0_0").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, 0, "a closed gate sends nothing")
    }

    function test_openGateAddsOneRowStopPerTableNeverOnePerRow() {
        var before = tabStops(renderer).length
        renderer.canFocus = true
        wait(40)
        var after = tabStops(renderer)
        compare(after.length, before + 1, "one roving stop for the whole table")
        var body = findChild(renderer, "aiTableRows")
        compare(body.enabled, true)
        var ask = findChild(renderer, "aiTableAsk_0")
        verify(ask !== null)
        compare(ask.activeFocusOnTab, false, "the Ask control is never a Tab stop")
        compare(ask.focusPolicy, Qt.NoFocus)
        // A table with 24 rows still adds exactly one.
        var rows = []
        for (var i = 0; i < 24; ++i) rows.push(["Row " + i, "" + i])
        renderer.canFocus = false
        renderer.blocks = [{type: "table", title: "Big", columns: ["Name", "N"], rows: rows}]
        renderer.blockIndices = [0]
        wait(40)
        var closed = tabStops(renderer).length
        renderer.canFocus = true
        wait(40)
        compare(tabStops(renderer).length, closed + 1)
    }

    function test_tableKeyboardMovesTheRowAndAsksWithTheOriginalIndex() {
        renderer.canFocus = true
        wait(40)
        var body = findChild(renderer, "aiTableRows")
        body.forceActiveFocus(Qt.TabFocusReason)
        compare(body.current, 0)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, 1)
        compare(args(focusSpy, 0), [2, "table", 0, "Oslo", "City: Oslo; Rent: 1200; Notes: Pricey"],
            "ORIGINAL block index 2, row 0")
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Down)
        compare(body.current, 2)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 1), [2, "table", 2, "Lisbon", "City: Lisbon; Rent: 900; Notes: Sunny"])
        keyClick(Qt.Key_End)
        compare(body.current, 3)
        keyClick(Qt.Key_Down)
        compare(body.current, 3, "clamped at the last row")
        keyClick(Qt.Key_Home)
        compare(body.current, 0)
        keyClick(Qt.Key_Up)
        compare(body.current, 0)
        compare(stateSpy.count, 0, "moving the row cursor never edits persisted state")
    }

    function test_sortedAndFilteredRowsKeepTheirAuthoredIndex() {
        renderer.canFocus = true
        // Sort by Rent ascending: Porto (authored 1), Lisbon (2), Berlin (3), Oslo (0).
        renderer.uiState = {"table:2": {sort: 1, dir: 1, filter: ""}}
        wait(40)
        compare(findChild(renderer, "aiTableRow_0").children[0].text, "Porto")
        var body = findChild(renderer, "aiTableRows")
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 0).slice(1, 4), ["table", 1, "Porto"], "the first VIEW row is authored row 1")
        keyClick(Qt.Key_End)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 1).slice(1, 4), ["table", 0, "Oslo"])
        // Filter to "o": Oslo, Porto, Lisbon (Notes: Sunny has no o... "Lisbon" has o), Berlin has no o.
        renderer.uiState = {"table:2": {sort: -1, dir: 1, filter: "lis"}}
        wait(40)
        compare(findChild(renderer, "aiTableCount").text, "1 of 4 rows")
        body.forceActiveFocus(Qt.TabFocusReason)
        compare(body.current, 0, "the cursor is clamped into the filtered view")
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 2).slice(1, 4), ["table", 2, "Lisbon"])
        renderer.uiState = {"table:2": {sort: -1, dir: 1, filter: "zzz"}}
        wait(40)
        var before = focusSpy.count
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, before, "an empty view has nothing to ask about")
        compare(body.enabled, false)
    }

    function test_tableAskControlIsVisibleOnTheCursorRowAndClickAsks() {
        renderer.canFocus = true
        wait(40)
        var ask = findChild(renderer, "aiTableAsk_1")
        verify(ask !== null)
        verify(!ask.visible, "idle: nothing is drawn")
        compare(ask.Accessible.name, "Ask about Porto")
        var body = findChild(renderer, "aiTableRows")
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Down)
        tryCompare(ask, "visible", true)
        verify(!findChild(renderer, "aiTableAsk_0").visible, "only the cursor row")
        ask.clicked()
        compare(focusSpy.count, 1)
        compare(args(focusSpy, 0), [2, "table", 1, "Porto", "City: Porto; Rent: 600"])
        // Hovering a row shows its control too.
        body.focus = false
        var rowItem = findChild(renderer, "aiTableRow_3")
        mouseMove(rowItem, 10, 4)
        tryCompare(findChild(renderer, "aiTableAsk_3"), "visible", true)
    }

    function test_stepsAskOnTheFocusedStepAndSpaceStillSelects() {
        renderer.canFocus = true
        wait(40)
        var step = findChild(renderer, "aiStep_3_1")
        step.forceActiveFocus(Qt.TabFocusReason)
        var ask = findChild(renderer, "aiStepAsk_3_1")
        tryCompare(ask, "visible", true)
        compare(ask.Accessible.name, "Ask about Boil")
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 0), [3, "steps", 1, "Boil", "Step 2 of 3. Gentle, 7 minutes."])
        compare(stateSpy.count, 0, "asking does not select the step")
        keyClick(Qt.Key_Space)
        compare(stateSpy.count, 1, "Space still selects")
        compare(args(stateSpy, 0), [3, "step:3", 1])
        ask.clicked()
        compare(focusSpy.count, 2)
        compare(stateSpy.count, 1, "the Ask control does not trigger the row's own click")
        verify(!findChild(renderer, "aiStepAsk_3_0").visible)
    }

    function framesIn(item) {
        var found = []
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            if (child.objectName === "aiImageFrame") found.push(child)
            found = found.concat(framesIn(child))
        }
        return found
    }

    function test_galleryAskOnTheFocusedCell() {
        renderer.canFocus = true
        wait(40)
        var frames = framesIn(findChild(renderer, "aiGallery"))
        compare(frames.length, 2)
        frames[1].forceActiveFocus(Qt.TabFocusReason)
        var ask = findChild(renderer, "aiGalleryAsk_4_1")
        tryCompare(ask, "visible", true)
        verify(!findChild(renderer, "aiGalleryAsk_4_0").visible)
        compare(ask.Accessible.name, "Ask about roman round arch")
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 0), [4, "gallery", 1, "roman round arch", "Example 2 of 2"])
        ask.clicked()
        compare(args(focusSpy, 1), [4, "gallery", 1, "roman round arch", "Example 2 of 2"])
        frames[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 2), [4, "gallery", 0, "Pointed arches", "Example 1 of 2. Image of: pointed gothic arch"])
        compare(stateSpy.count, 0)
        renderer.canFocus = false
        wait(30)
        var before = focusSpy.count
        frames[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, before)
        verify(!ask.visible)
    }

    function test_diagramAskOnTheFocusedOrSelectedNode() {
        renderer.canFocus = true
        wait(40)
        var ask = findChild(renderer, "aiDiagramAsk")
        verify(!ask.visible, "no node focused or selected")
        var part = findChild(renderer, "aiDiagramPart_0_0")
        part.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(ask, "visible", true)
        compare(ask.Accessible.name, "Ask about Nucleus")
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 0), [0, "diagram", 0, "Nucleus", "Holds the DNA."])
        compare(stateSpy.count, 0)
        ask.clicked()
        compare(focusSpy.count, 2)
        // A non-selectable node is not askable.
        var plain = findChild(renderer, "aiDiagramPart_0_2")
        plain.forceActiveFocus(Qt.TabFocusReason)
        var before = focusSpy.count
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, before)
        // A selected node (persisted `diagram:<block>`) shows the control without focus.
        findChild(renderer, "aiChart").forceActiveFocus(Qt.TabFocusReason)
        renderer.uiState = {"diagram:0": 1}
        wait(40)
        tryCompare(ask, "visible", true)
        compare(ask.Accessible.name, "Ask about rect")
        ask.clicked()
        compare(args(focusSpy, focusSpy.count - 1), [0, "diagram", 1, "rect", "A membrane-bound sac."])
    }

    function test_chartAsksAboutTheSelectedPointAndMarketHasNoControl() {
        renderer.canFocus = true
        wait(40)
        var chart = findChild(renderer, "aiChart")
        var ask = findChild(renderer, "aiChartAsk")
        verify(ask.visible, "the last observation is selected by default")
        compare(ask.Accessible.name, "Ask about Mar")
        chart.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Left)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 0), [1, "chart", 1, "Feb", "Sales: Feb = 7 units. Observation 2 of 3"])
        keyClick(Qt.Key_Home)
        keyClick(Qt.Key_Question)
        compare(args(focusSpy, 1).slice(1, 4), ["chart", 0, "Jan"])
        ask.clicked()
        compare(args(focusSpy, 2).slice(1, 4), ["chart", 0, "Jan"])
        // The market block (a different type) never carries the control.
        var charts = []
        function collect(item) {
            for (var i = 0; i < item.children.length; ++i) {
                if (item.children[i].objectName === "aiChart") charts.push(item.children[i])
                collect(item.children[i])
            }
        }
        collect(renderer)
        compare(charts.length, 2)
        var market = charts[0] === chart ? charts[1] : charts[0]
        compare(market.canFocus, false)
        market.forceActiveFocus(Qt.TabFocusReason)
        var before = focusSpy.count
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, before)
    }

    function test_hostileBlocksNeverThrowOrOfferAControl() {
        renderer.canFocus = true
        renderer.blockIndices = [0, 1, 2, 3]
        renderer.blocks = [
            {type: "table", title: "T", columns: ["A"], rows: [[]]},
            {type: "steps", title: "S", steps: [{label: bel, detail: "x"}, {label: "ok", detail: ""}]},
            {type: "diagram", title: "D", parts: [{shape: "circle", x: 0, y: 0, w: 10, h: 10, label: "", detail: "", tone: "foreground", fill: false, rotation: 0}]},
            {type: "chart", title: "C", labels: ["a", "b"], values: [1, 2]}]
        wait(40)
        compare(findChild(renderer, "aiTableAsk_0").visible, false)
        verify(findChild(renderer, "aiStepAsk_1_0") === null || !findChild(renderer, "aiStepAsk_1_0").visible)
        var step = findChild(renderer, "aiStep_1_0")
        step.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, 0, "a step whose label cleans to nothing is not askable")
        findChild(renderer, "aiStep_1_1").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, 1)
        compare(args(focusSpy, 0).slice(1, 4), ["steps", 1, "ok"])
    }

    function test_blockIndexIsTheOriginalOneThroughTheAnswerAndTextViewHidesEverything() {
        failOnWarning(/TypeError:|ReferenceError:|Binding loop/)
        var turn = {id: 9, prompt: "p", attachment: "", answer: "Here.", blocks: [
            {type: "image", title: "Hero", query: "a cat"}, tableBlock], suggestions: [], warning: "", error: "",
            status: "done", explanation: ""}
        answer.turn = turn
        answer.canFocus = true
        answer.showText = false
        answerSpy.clear()
        wait(60)
        var body = findChild(answer, "aiTableRows")
        verify(body !== null)
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question)
        compare(answerSpy.count, 1)
        compare(Array.prototype.slice.call(answerSpy.signalArguments[0]).slice(0, 4), [1, "table", 0, "Oslo"],
            "the task and illustration have separate hosts but retain their authored indices")
        answer.showText = true
        wait(40)
        var blocks = findChild(answer, "aiNativeBlocks_0")
        compare(blocks.canFocus, false, "text view: no parts to point at")
        compare(findChild(answer, "aiTableRows").enabled, false)
        answer.showText = false
        answer.canFocus = false
        answer.turn = null
    }

    Launcher.AiAnswer {
        id: answer
        width: 700
        visible: false
        turn: null
        title: "Focus"
        mediaRoot: "/tmp/opencode/s1-media"
        foreground: "#eeeeee"
        background: "#222222"
        accent: "#88bbff"
    }
    SignalSpy { id: answerSpy; target: answer; signalName: "focusRequested" }

    function test_bothWidthsKeepTheControlsInsideTheirRows() {
        renderer.canFocus = true
        var widths = [760, 330]
        for (var w = 0; w < widths.length; ++w) {
            tests.width = widths[w]
            wait(60)
            var body = findChild(renderer, "aiTableRows")
            body.forceActiveFocus(Qt.TabFocusReason)
            keyClick(Qt.Key_Home)
            var ask = findChild(renderer, "aiTableAsk_0")
            tryCompare(ask, "visible", true)
            var row = ask.parent
            verify(ask.x >= 0 && ask.x + ask.width <= row.width + 0.5, "table ask inside its row at " + widths[w])
            var step = findChild(renderer, "aiStep_3_0")
            step.forceActiveFocus(Qt.TabFocusReason)
            var stepAsk = findChild(renderer, "aiStepAsk_3_0")
            tryCompare(stepAsk, "visible", true)
            verify(stepAsk.x >= 0 && stepAsk.x + stepAsk.width <= step.width + 0.5, "step ask inside its row at " + widths[w])
            var chartAsk = findChild(renderer, "aiChartAsk")
            var chart = findChild(renderer, "aiChart")
            verify(chartAsk.x >= 0 && chartAsk.x + chartAsk.width <= chart.width + 0.5, "chart ask inside the card at " + widths[w])
            verify(chartAsk.visible)
        }
    }
}
