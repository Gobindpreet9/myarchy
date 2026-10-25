import QtQuick
import QtTest
import ".."
import "../AiCompareView.js" as View
import "TestJson.js" as TestJson

// The `compare` block renderer and its pure view helpers. The component owns
// no durable state: every assertion is on what it DISPLAYS or EMITS, with the
// host (this test) applying or refusing the emitted entry like the pane does.
TestCase {
    id: tests
    name: "AiCompare"
    width: 1100
    height: 900
    visible: true
    when: windowShown

    property var block: tests.laptops()
    property var saved: undefined
    property bool canChoose: true
    property bool canFocus: false
    property string hint: ""
    property int picked: -1
    property bool refuse: false
    property int cw: 760
    property int vh: 700
    property var emitted: []
    property int downs: 0
    property int ups: 0
    readonly property color fg: "#f1f2f4"
    readonly property color bg: "#1b1c20"
    readonly property color ac: "#b4c4dc"

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    Flickable {
        id: flick
        y: 20
        width: 1000
        height: tests.vh
        clip: true
        contentWidth: width
        contentHeight: holder.height
        Item {
            id: holder
            width: tests.cw
            height: cmp.height
            Keys.onDownPressed: ++tests.downs
            Keys.onUpPressed: ++tests.ups
            AiCompare {
                id: cmp
                width: tests.cw
                block: tests.block
                saved: tests.saved
                picked: tests.picked
                canChoose: tests.canChoose
                canFocus: tests.canFocus
                chooseHint: tests.hint
                foreground: tests.fg
                background: tests.bg
                accent: tests.ac
                onStateEdited: function (state) {
                    tests.emitted = tests.emitted.concat([JSON.parse(JSON.stringify(state))])
                    if (!tests.refuse) tests.saved = state
                }
            }
        }
    }
    Item { id: after; y: 840; activeFocusOnTab: true; width: 10; height: 10 }

    SignalSpy { id: choiceSpy; target: cmp; signalName: "choiceRequested" }
    SignalSpy { id: focusSpy; target: cmp; signalName: "focusRequested" }

    // ---- fixtures -------------------------------------------------------------
    function opt(name, extra) {
        return Object.assign({name: name, summary: name + " in short", facts: [], pros: [], cons: [], recommended: false}, extra || {})
    }
    function fact(label, value) { return {label: label, value: value} }
    function laptops() {
        return {type: "compare", title: "Two laptops", options: [
            tests.opt("Aero 14", {summary: "Light and quiet", recommended: true,
                facts: [tests.fact("Weight", "1.2 kg"), tests.fact("Price", "999")],
                pros: ["Battery lasts", "Great screen"], cons: ["One port"]}),
            tests.opt("Forge 16", {summary: "Fast",
                facts: [tests.fact("Price", "1499"), tests.fact("Battery", "6 h")],
                pros: ["Fast"], cons: ["Heavy", "Loud"]}),
            tests.opt("Nova 13", {summary: "Cheap", facts: [tests.fact("Weight", "1.4 kg")]})],
            verdict: "Aero 14 suits travel."}
    }
    function many(count, factCount) {
        var options = []
        for (var i = 0; i < count; ++i) {
            var facts = []
            for (var f = 0; f < factCount; ++f) facts.push(tests.fact("Fact " + f, "v" + i + "." + f))
            options.push(tests.opt("Option " + i, {facts: facts, pros: ["Pro " + i], cons: ["Con " + i], recommended: i === 1}))
        }
        return {type: "compare", title: "Many", options: options, verdict: ""}
    }
    function setBlock(b) {
        tests.saved = undefined
        tests.block = b
        wait(20)
    }

    // ---- tree helpers ------------------------------------------------------------
    function walk(item, out) {
        if (!item || out.indexOf(item) >= 0) return out
        out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) tests.walk(kids[i], out)
        return out
    }
    function all() { return tests.walk(cmp, []) }
    function named(name, root) {
        var items = tests.walk(root || cmp, []), out = []
        for (var i = 0; i < items.length; ++i) if (items[i].objectName === name && items[i].visible) out.push(items[i])
        return out
    }
    function one(name, root) {
        var found = tests.named(name, root)
        verify(found.length === 1, name + " x" + found.length)
        return found[0]
    }
    function isText(it) { return typeof it.textFormat === "number" && typeof it.wrapMode === "number" && typeof it.elide === "number" }
    function texts() {
        var items = tests.all(), out = []
        for (var i = 0; i < items.length; ++i) if (tests.isText(items[i]) && items[i].visible && items[i].text !== "") out.push(items[i])
        return out
    }
    function shownTexts() { return tests.texts().map(function (t) { return t.text }) }
    // The option container: a matrix column header or a stacked card.
    function holderOf(k) {
        var h = tests.named("aiCompareColumn_" + k)
        if (h.length === 1) return h[0]
        return tests.one("aiCompareCard_" + k)
    }
    function inspect(k) {
        if (cmp.matrix) return
        var candidate = tests.one("aiCompareCandidate_" + k)
        View.reveal(candidate, flick)
        wait(10)
        mouseClick(candidate)
        wait(10)
    }
    function chip(kind, k) {
        var footer = tests.named("aiCompareActions_" + k)
        if (!cmp.matrix && cmp.inspectedPos !== k) tests.inspect(k)
        var button = tests.one("aiCompare" + kind, footer.length ? footer[0] : tests.holderOf(k))
        // Mouse tests must reach the real visible footer, not click through the
        // Flickable's clip at an old, header-level action position.
        View.reveal(button, flick)
        wait(5)
        return button
    }
    function nameOf(k) {
        if (!cmp.matrix) return tests.one("aiCompareCandidateName", tests.one("aiCompareCandidate_" + k)).text
        return tests.one("aiCompareName", tests.holderOf(k)).text
    }
    function order() {
        var out = [], i = 0
        while (true) {
            var h = tests.named("aiCompareColumn_" + i)
            if (h.length === 0) h = tests.named("aiCompareCandidate_" + i)
            if (h.length === 0) break
            out.push(tests.nameOf(i))
            ++i
        }
        return out
    }
    function stubs() { return tests.named("aiCompareStubName").map(function (t) { return t.text }) }
    function last() { return tests.emitted.length ? tests.emitted[tests.emitted.length - 1] : null }
    function focusCompare() {
        before.forceActiveFocus()
        cmp.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(cmp, "activeFocus", true)
    }
    function lum(c) {
        function f(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    function ratio(c, back) {
        var a = c.a, mix = {r: c.r * a + back.r * (1 - a), g: c.g * a + back.g * (1 - a), b: c.b * a + back.b * (1 - a)}
        var l1 = tests.lum(mix), l2 = tests.lum(back), hi = Math.max(l1, l2), lo = Math.min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
    function rightEdge(item) { return item.mapToItem(cmp, 0, 0).x + item.width }
    function contentBottom() {
        var items = tests.all(), bottom = 0
        for (var i = 0; i < items.length; ++i) {
            if (!items[i].visible || items[i] === cmp || items[i].width <= 0 || items[i].height <= 0) continue
            bottom = Math.max(bottom, items[i].mapToItem(cmp, 0, 0).y + items[i].height)
        }
        return bottom
    }

    function init() {
        tests.cw = 760
        tests.vh = 700
        tests.canChoose = true
        tests.canFocus = false
        tests.hint = ""
        tests.picked = -1
        tests.refuse = false
        tests.emitted = []
        tests.downs = 0
        tests.ups = 0
        tests.setBlock(tests.laptops())
        cmp.cursor = -1
        choiceSpy.clear()
        focusSpy.clear()
        flick.contentY = 0
        before.forceActiveFocus()
        wait(0)
    }

    // ---- pure helpers ---------------------------------------------------------
    function test_modelKeepsRawIndexesAndFirstRecommendation() {
        var m = View.model({type: "compare", options: [null, tests.opt("A"), {name: "  "}, tests.opt("B", {recommended: true}),
            tests.opt("C", {recommended: true})], verdict: " ok\n"})
        compare(m.options.map(function (o) { return o.index }), [1, 3, 4])
        compare(m.options.map(function (o) { return o.recommended }), [false, true, false])
        compare(m.verdict, "ok")
        compare(View.model({type: "actions", options: [tests.opt("A")]}).options.length, 0)
        compare(View.model(null).options.length, 0)
        compare(View.model("x").options.length, 0)
        compare(View.model({type: "compare", options: "nope"}).options.length, 0)
    }

    function test_factRowsUnionInFirstSeenOrder() {
        var opts = View.model(tests.laptops()).options
        var rows = View.factRows(opts)
        compare(rows.map(function (r) { return r.label }), ["Weight", "Price", "Battery"])
        compare(rows[0].values, ["1.2 kg", null, "1.4 kg"])
        compare(rows[1].values, ["999", "1499", null])
        compare(rows[2].values, [null, "6 h", null])
        // Display order does not reshuffle the rows; values follow the display order.
        var pinned = [opts[1], opts[0], opts[2]]
        var again = View.factRows(pinned)
        compare(again.map(function (r) { return r.label }), ["Weight", "Price", "Battery"])
        compare(again[1].values, ["1499", "999", null])
        // Case-insensitive match; a repeated label fills a further row, nothing is dropped.
        var tricky = View.model({type: "compare", options: [
            tests.opt("A", {facts: [tests.fact("Price", "1"), tests.fact("price", "2")]}),
            tests.opt("B", {facts: [tests.fact("PRICE", "3")]})]}).options
        var t = View.factRows(tricky)
        compare(t.length, 2)
        compare(t[0].values, ["1", "3"])
        compare(t[1].values, ["2", null])
        compare(View.factRows(null), [])
    }

    function test_stateSanitising() {
        var idx = [0, 1, 2]
        compare(View.sanitizeState(undefined, idx), {pin: -1, hide: []})
        compare(View.sanitizeState({pin: 1, hide: [2, 0, 2]}, idx), {pin: 1, hide: [0, 2]})
        compare(View.sanitizeState({pin: 9, hide: [7, -1, 1.5, "1", null, 2]}, idx), {pin: -1, hide: [2]}, "stale and malformed indices")
        compare(View.sanitizeState({pin: 0, hide: [0]}, idx), {pin: -1, hide: [0]}, "a hidden option is not pinned")
        compare(View.sanitizeState({pin: -1, hide: [0, 1, 2]}, idx), {pin: -1, hide: [1, 2]}, "never every option hidden")
        compare(View.sanitizeState({pin: 5, hide: [0, 1]}, [5]), {pin: 5, hide: []}, "a single option cannot be hidden")
        compare(View.sanitizeState({pin: 0}, []), {pin: -1, hide: []})
        compare(View.sanitizeState("junk", idx), {pin: -1, hide: []})
        compare(View.sanitizeState({hide: "0"}, idx), {pin: -1, hide: []})
        var sparse = View.sanitizeState({pin: 3, hide: [0, 2]}, [0, 2, 3])
        compare(sparse, {pin: 3, hide: [0, 2]}, "indices are raw option indexes, not positions")
    }

    function test_togglesAndTheLastVisibleRule() {
        var idx = [0, 1, 2]
        var s = {pin: -1, hide: []}
        compare(View.togglePin(s, 1, idx), {pin: 1, hide: []})
        compare(View.togglePin({pin: 1, hide: []}, 1, idx), {pin: -1, hide: []})
        compare(View.togglePin({pin: 1, hide: []}, 2, idx), {pin: 2, hide: []})
        compare(View.togglePin({pin: -1, hide: [1]}, 1, idx), null, "a hidden option cannot be pinned")
        compare(View.togglePin(s, 7, idx), null)
        compare(View.toggleHide(s, 1, idx), {pin: -1, hide: [1]})
        compare(View.toggleHide({pin: 1, hide: []}, 1, idx), {pin: -1, hide: [1]}, "hiding the pinned option unpins it")
        compare(View.toggleHide({pin: -1, hide: [1]}, 1, idx), {pin: -1, hide: []}, "show")
        compare(View.toggleHide({pin: -1, hide: [0, 1]}, 2, idx), null, "the last visible option stays")
        compare(View.toggleHide({pin: -1, hide: []}, 0, [0]), null)
        compare(View.toggleHide(s, 9, idx), null)
        compare(View.toggleHide({pin: -1, hide: [2]}, 0, idx), {pin: -1, hide: [0, 2]}, "ascending")
    }

    function test_arrangePinsFirstAndKeepsAuthoredOrder() {
        var opts = View.model(tests.many(4, 0)).options
        var names = function (list) { return list.map(function (o) { return o.name }) }
        var a = View.arrange(opts, {pin: -1, hide: []})
        compare(names(a.visible), ["Option 0", "Option 1", "Option 2", "Option 3"])
        a = View.arrange(opts, {pin: 2, hide: [1]})
        compare(names(a.visible), ["Option 2", "Option 0", "Option 3"])
        compare(names(a.hidden), ["Option 1"])
        compare(View.arrange(null, null), {visible: [], hidden: []})
    }

    function test_compositionAndStateSizeBounds() {
        compare(View.composition(559, 2), "stacked")
        compare(View.composition(560, 2), "matrix")
        compare(View.composition(560, 3), "stacked")
        compare(View.composition(759, 3), "stacked")
        compare(View.composition(760, 3), "matrix")
        compare(View.composition(959, 4), "stacked")
        compare(View.composition(960, 4), "matrix")
        compare(View.composition(1400, 4), "matrix")
        compare(View.composition(1400, 5), "stacked")
        compare(View.composition(1400, 1), "stacked")
        compare(View.composition(1400, 0), "stacked")
        compare(View.composition(undefined, 2), "stacked")
        compare(View.composition(Infinity, 2), "stacked")
        var idx = []
        for (var i = 0; i < 16; ++i) idx.push(i)
        var worst = View.sanitizeState({pin: 15, hide: idx.slice(0, 15)}, idx)
        compare(worst.hide.length, 15)
        verify(View.stateBytes(worst) <= View.MAX_STATE_BYTES, "worst state " + View.stateBytes(worst) + " B")
        verify(View.stateBytes(worst) < 100)
    }

    // ---- composition and layout ----------------------------------------------------
    function test_widthDecidesTheComposition() {
        var widths = [360, 420, 559, 560, 759, 760, 980]
        var heights = {}
        for (var i = 0; i < widths.length; ++i) {
            tests.cw = widths[i]
            wait(30)
            var matrix = widths[i] >= 760
            compare(cmp.matrix, matrix, "width " + widths[i])
            compare(tests.named("aiCompareMatrix").length, matrix ? 1 : 0)
            compare(tests.named("aiCompareCards").length, matrix ? 0 : 1)
            verify(cmp.width === widths[i])
            // Nothing sticks out of the block, nothing is cut off, height is measured.
            var items = tests.all()
            for (var k = 0; k < items.length; ++k) {
                if (!items[k].visible || items[k] === cmp || items[k].width <= 0) continue
                verify(tests.rightEdge(items[k]) <= widths[i] + 0.5,
                    "w" + widths[i] + " " + items[k].objectName + " right " + tests.rightEdge(items[k]))
                verify(items[k].mapToItem(cmp, 0, 0).x >= -0.5, "left edge of " + items[k].objectName)
            }
            verify(cmp.height > 0)
            verify(Math.abs(cmp.height - tests.contentBottom()) <= 1,
                "w" + widths[i] + " height " + cmp.height + " vs content " + tests.contentBottom())
            compare(cmp.height, cmp.implicitHeight)
            heights[widths[i]] = cmp.height
        }
        verify(heights[360] > heights[760], "stacked is taller than the matrix: " + heights[360] + " vs " + heights[760])
    }

    function test_matrixColumnsAndFactAlignment() {
        tests.cw = 760
        wait(30)
        var heads = ["Aero 14", "Forge 16", "Nova 13"]
        compare(tests.order(), heads)
        var colX = [0, 1, 2].map(function (k) { return tests.holderOf(k).mapToItem(cmp, 0, 0).x })
        verify(colX[0] < colX[1] && colX[1] < colX[2])
        compare(tests.holderOf(0).width, cmp.columnWidth)
        var nameY = [0, 1, 2].map(function (k) { return tests.one("aiCompareName", tests.holderOf(k)).mapToItem(cmp, 0, 0).y })
        compare(nameY[0], nameY[1], "names share the first baseline, badges do not push one option down")
        compare(nameY[1], nameY[2])
        // Three fact rows, one cell per column, every cell of a row on one baseline.
        var rows = tests.named("aiCompareFact_0")
        compare(rows.length, 3)
        compare(tests.named("aiCompareFact_0").concat(tests.named("aiCompareFact_1"), tests.named("aiCompareFact_2")).length, 9)
        var y0 = tests.named("aiCompareFact_0").map(function (c) { return c.mapToItem(cmp, 0, 0).y })
        var y1 = tests.named("aiCompareFact_1").map(function (c) { return c.mapToItem(cmp, 0, 0).y })
        var y2 = tests.named("aiCompareFact_2").map(function (c) { return c.mapToItem(cmp, 0, 0).y })
        compare(y0, y1)
        compare(y1, y2)
        verify(y0[0] < y0[1] && y0[1] < y0[2], "fact rows run top to bottom")
        // Headers are as tall as the tallest, so the buttons line up across columns.
        var tall = tests.laptops()
        tall.options[1].name = "Forge 16 Pro Max Ultra Extended Edition"
        tests.setBlock(tall)
        wait(30)
        var pinY = [0, 1, 2].map(function (k) { return tests.chip("Pin", k).mapToItem(cmp, 0, 0).y })
        compare(pinY[0], pinY[1])
        compare(pinY[1], pinY[2])
        var hideY = [0, 1, 2].map(function (k) { return tests.chip("Hide", k).mapToItem(cmp, 0, 0).y })
        compare(hideY[0], hideY[2])
        tests.setBlock(tests.laptops())
        wait(30)
        // Missing facts are an em dash with a spoken reason.
        var weightRow = tests.named("aiCompareFact_1").filter(function (c) { return c.Accessible.name.indexOf("Weight") === 0 })[0]
        compare(weightRow.Accessible.name, "Weight: not stated (Forge 16)")
        var dash = tests.shownTexts().filter(function (t) { return t === "\u2014" })
        verify(dash.length >= 3, "em dashes for the missing facts")
        // Row labels in first-seen order.
        var labels = tests.shownTexts().filter(function (t) { return t === "Weight" || t === "Price" || t === "Battery" })
        compare(labels, ["Weight", "Price", "Battery"])
    }

    function test_shortlistInspectsTheSameContentOneDetailAtATime() {
        tests.cw = 360
        wait(30)
        compare(tests.order(), ["Aero 14", "Forge 16", "Nova 13"])
        var texts = []
        for (var k = 0; k < 3; ++k) {
            tests.inspect(k)
            texts = texts.concat(tests.shownTexts())
            compare(tests.named("aiCompareName").length, 1, "one detail tree, not hidden duplicate cards")
        }
        var expected = ["Light and quiet", "Weight", "1.2 kg", "Price", "999", "Battery lasts", "Great screen", "One port",
            "Fast", "1499", "Battery", "6 h", "Heavy", "Loud", "Cheap", "1.4 kg", "AI recommendation", "Aero 14 suits travel."]
        for (var i = 0; i < expected.length; ++i) verify(texts.indexOf(expected[i]) >= 0, "missing " + expected[i])
        // A card lists only what its option states (no placeholder rows).
        var nova = tests.holderOf(2)
        var inNova = tests.walk(nova, []).filter(function (it) { return tests.isText(it) && it.visible }).map(function (t) { return t.text })
        verify(inNova.indexOf("\u2014") < 0)
        verify(inNova.indexOf("Weight") >= 0 && inNova.indexOf("Battery") < 0)
    }

    function test_recommendedIsTextAndGlyphNotColourAlone() {
        for (var width = 0; width < 2; ++width) {
            tests.cw = width ? 360 : 760
            wait(30)
            var badges = tests.named("aiCompareRecommended")
            compare(badges.length, 1, "one recommendation")
            compare(badges[0].text, "Recommended")
            var holder = tests.holderOf(0)
            var inHolder = tests.walk(holder, []).filter(function (it) { return tests.isText(it) && it.text === "\u2605" })
            compare(inHolder.length, 1, "star glyph next to the word")
            compare(holder.Accessible.name === "Aero 14, recommended" || holder.children[0].Accessible.name === "Aero 14, recommended", true)
        }
        // Another option is not marked.
        var b = tests.laptops()
        b.options[0].recommended = false
        b.options[2].recommended = true
        tests.setBlock(b)
        tests.inspect(2)
        var again = tests.named("aiCompareRecommended")
        compare(again.length, 1)
        var h2 = tests.holderOf(2)
        verify(tests.walk(h2, []).indexOf(again[0]) >= 0)
    }

    function test_optionsAreGroupsWithSpokenState() {
        tests.cw = 760
        wait(30)
        var head = tests.named("aiCompareColumn_0")[0].children[0]
        compare(head.Accessible.role, Accessible.Grouping)
        compare(head.Accessible.name, "Aero 14, recommended")
        tests.picked = 0
        tests.saved = {pin: 0, hide: []}
        wait(30)
        compare(tests.named("aiCompareColumn_0")[0].children[0].Accessible.name, "Aero 14, recommended, chosen, pinned")
        compare(cmp.Accessible.focusable, true)
        verify(cmp.Accessible.description.indexOf("Left and Right") >= 0)
        tests.cw = 360
        wait(30)
        compare(tests.one("aiCompareCard_0").Accessible.name, "Aero 14, recommended, chosen, pinned")
        compare(tests.one("aiCompareCard_0").Accessible.role, Accessible.Grouping)
    }

    function test_twoAndFourOptionsWithZeroAndFourFacts() {
        var cases = [[2, 0], [2, 4], [4, 0], [4, 4]]
        for (var c = 0; c < cases.length; ++c) {
            tests.setBlock(tests.many(cases[c][0], cases[c][1]))
            for (var w = 0; w < 2; ++w) {
                tests.cw = w ? 420 : (cases[c][0] === 2 ? 560 : 980)
                wait(30)
                compare(cmp.usable, true)
                compare(cmp.matrix, w === 0)
                compare(tests.order().length, cases[c][0])
                compare(cmp.rows.length, cases[c][1])
                compare(tests.named("aiCompareFact_0").length, w === 0 ? cases[c][1] : 0)
                verify(cmp.height > 0)
                verify(Math.abs(cmp.height - tests.contentBottom()) <= 1, "height " + cases[c] + " " + tests.cw)
                var items = tests.all()
                for (var k = 0; k < items.length; ++k) {
                    if (!items[k].visible || items[k] === cmp || items[k].width <= 0) continue
                    verify(tests.rightEdge(items[k]) <= tests.cw + 0.5, items[k].objectName + " overflows")
                }
            }
        }
        tests.cw = 560
        tests.setBlock(tests.many(4, 4))
        wait(30)
        compare(cmp.matrix, false, "four options at 560 need readable cards, not four tiny columns")
        compare(tests.named("aiCompareCandidate_3").length, 1)
        compare(tests.named("aiCompareName").length, 1)
        compare(tests.named("aiComparePointsCell_pros").length, 0)
    }

    function test_moreThanFourOptionsStackWhateverTheWidth() {
        tests.setBlock(tests.many(6, 1))
        tests.cw = 1000
        wait(30)
        compare(cmp.matrix, false)
        compare(tests.order().length, 6)
    }

    function test_readableVisibleOptionCounts_data() {
        var rows = []
        for (var count = 2; count <= 4; ++count) {
            for (var w of [420, 560, 760, 980]) rows.push({tag: count + "-at-" + w, count: count, width: w,
                matrix: w >= 560 + (count - 2) * 200})
        }
        return rows
    }
    function test_readableVisibleOptionCounts(data) {
        tests.setBlock(tests.many(data.count, 4))
        tests.cw = data.width
        wait(20)
        compare(cmp.matrix, data.matrix)
        compare(tests.order().length, data.count)
        if (data.matrix) {
            verify(cmp.columnWidth >= View.MATRIX_COLUMN_MIN, "legible column width: " + cmp.columnWidth)
            compare(tests.named("aiCompareFact_0").length, 4)
        } else {
            compare(tests.named("aiCompareCandidateName").length, data.count)
            compare(tests.all().filter(function (it) { return /^aiCompareCard_/.test(it.objectName) }).length, 1,
                "only one instantiated detail card, not a pile of invisible trees")
            var names = tests.named("aiCompareCandidateName")
            var detailTop = tests.holderOf(0).mapToItem(cmp, 0, 0).y
            for (var name of names) {
                var bottom = name.mapToItem(cmp, 0, 0).y + name.height
                verify(bottom < detailTop, "all names before detail")
                verify(bottom < tests.vh, "all names in the first viewport")
            }
        }
    }

    function test_verdictLeadsEvidenceAndActionsComeLast() {
        for (var width of [420, 760]) {
            tests.cw = width
            wait(20)
            var verdict = tests.one("aiCompareVerdict")
            compare(tests.one("aiCompareRecommendationLabel").text, "AI recommendation")
            compare(verdict.Accessible.name, "AI recommendation: Aero 14 suits travel.")
            var verdictBottom = verdict.mapToItem(cmp, 0, 0).y + verdict.height
            var firstName = tests.one("aiCompareName", tests.holderOf(0))
            verify(verdictBottom < firstName.mapToItem(cmp, 0, 0).y)
            var evidence = cmp.matrix ? tests.named("aiCompareFact_0").concat(tests.named("aiComparePointsCell_pros"), tests.named("aiComparePointsCell_cons"))
                : tests.named("aiCompareFactLine").concat(tests.named("aiComparePoint"))
            verify(evidence.length > 0)
            var bottom = Math.max.apply(null, evidence.map(function (it) { return it.mapToItem(cmp, 0, 0).y + it.height }))
            for (var kind of ["Choose", "Pin", "Hide"]) {
                var action = tests.chip(kind, 0)
                verify(action.mapToItem(cmp, 0, 0).y >= bottom, kind + " follows all evidence")
            }
            compare(firstName.font.pixelSize, cmp.matrix ? 17 : 20)
            compare(tests.one("aiCompareSummary", tests.holderOf(0)).font.pixelSize, 14)
            verify(tests.chip("Pin", 0).quiet)
            verify(tests.chip("Hide", 0).quiet)
        }
        cmp.toggleHide(0)
        wait(20)
        compare(tests.one("aiCompareRecommendationLabel").text, "Original AI recommendation")
        compare(tests.one("aiCompareVerdict").text, "Aero 14 suits travel.", "local hiding never invents a new verdict")
    }

    function test_shortlistInspectionIsLocalAndKeepsRawIndicesAcrossLayouts() {
        tests.setBlock({type: "compare", options: [null, tests.opt("A"), {name: ""}, tests.opt("B"), tests.opt("C"), tests.opt("D")]})
        tests.cw = 420
        wait(20)
        var original = JSON.parse(JSON.stringify(tests.block))
        tests.inspect(2)
        compare(cmp.cursorOption.index, 4)
        compare(tests.one("aiCompareName").text, "C")
        compare(tests.order(), ["A", "B", "C", "D"])
        compare(choiceSpy.count, 0)
        compare(focusSpy.count, 0)
        compare(tests.emitted.length, 0)
        compare(tests.saved, undefined)
        verify(TestJson.equal(tests.block, original), "inspection never edits model data")
        compare(tests.all().filter(function (it) { return /^aiCompareCard_/.test(it.objectName) }).length, 1)
        tests.cw = 980
        wait(20)
        compare(cmp.matrix, true)
        compare(cmp.cursorOption.index, 4, "resize keeps raw-index inspection")
        tests.cw = 420
        wait(20)
        compare(tests.one("aiCompareName").text, "C")
        tests.focusCompare()
        keyClick(Qt.Key_P)
        wait(20)
        verify(TestJson.equal(tests.last(), {pin: 4, hide: []}))
        compare(cmp.inspectedPos, 0)
        compare(tests.one("aiCompareName").text, "C")
        keyClick(Qt.Key_H)
        wait(20)
        verify(TestJson.equal(tests.last(), {pin: -1, hide: [4]}))
        compare(cmp.cursorHidden, true)
        compare(tests.one("aiCompareStub_0").border.width, 2)
        compare(tests.order(), ["A", "B", "D"])
        keyClick(Qt.Key_Return)
        wait(20)
        verify(TestJson.equal(tests.last(), {pin: -1, hide: []}))
        compare(cmp.cursorOption.index, 4)
        compare(tests.one("aiCompareName").text, "C")
        compare(choiceSpy.count, 0, "Enter on a hidden stub restores, never continues")
        keyClick(Qt.Key_Left)
        compare(cmp.cursorOption.index, 3)
        keyClick(Qt.Key_Return)
        compare(choiceSpy.count, 1)
        compare(choiceSpy.signalArguments[0][0], 3, "continuation still carries the raw index")
    }

    function test_hidingChangesCompositionByVisibleCount() {
        tests.setBlock(tests.many(4, 4))
        tests.cw = 760
        wait(20)
        compare(cmp.matrix, false)
        tests.inspect(3)
        tests.focusCompare()
        keyClick(Qt.Key_H)
        wait(20)
        compare(cmp.matrix, true, "three visible at 760")
        compare(cmp.cursorOption.index, 3)
        compare(cmp.cursorHidden, true)
        compare(tests.named("aiCompareShow").length, 1)
        tests.cw = 560
        wait(20)
        compare(cmp.matrix, false, "three visible at 560")
        keyClick(Qt.Key_Home)
        keyClick(Qt.Key_H)
        wait(20)
        compare(cmp.matrix, true, "two visible at 560")
        keyClick(Qt.Key_Home)
        keyClick(Qt.Key_H)
        wait(20)
        compare(cmp.matrix, false, "a single visible option is a detail card")
        compare(cmp.shown.length, 1)
        keyClick(Qt.Key_Home)
        var n = tests.emitted.length
        keyClick(Qt.Key_H)
        wait(20)
        compare(tests.emitted.length, n, "the last visible option still cannot hide")
        compare(tests.named("aiCompareShow").length, 3)
    }

    function test_followupLabelStaysConciseAndHonestWithLongNames() {
        tests.setBlock({type: "compare", options: [tests.opt("N".repeat(80)), tests.opt("B")]})
        tests.cw = 560
        wait(20)
        var button = tests.chip("Choose", 0)
        compare(button.label, "Continue")
        compare(button.Accessible.name, "Continue with " + "N".repeat(80))
        compare(button.Accessible.description, "Sends an AI follow-up about " + "N".repeat(80) + ".")
        compare(tests.named("aiCompareFollowupHint")[0].text, "Sends an AI follow-up.")
        var caption = tests.walk(button, []).filter(tests.isText)[0]
        compare(caption.lineCount, 1, "a long name never creates a multi-line primary action")
    }

    function test_keyboardHelpAppearsOnlyOnFocusWithoutMovingContent() {
        var states = [{pin: -1, hide: []}, {pin: 1, hide: [2]}, {pin: -1, hide: [0, 1]}]
        for (var width of [420, 560, 760, 980]) {
            for (var state of states) {
                tests.cw = width
                tests.saved = state
                tests.canChoose = state.hide.length === 0
                tests.canFocus = state.hide.length === 1
                before.forceActiveFocus()
                wait(20)
                var height = cmp.height
                compare(tests.named("aiCompareKeyboardHelp").length, 0)
                var firstName = tests.named("aiCompareName")[0]
                var top = firstName.mapToItem(cmp, 0, 0).y
                tests.focusCompare()
                var help = tests.one("aiCompareKeyboardHelp")
                verify(help.text.indexOf("P pin") >= 0)
                compare(help.text.indexOf("? ask AI") >= 0, tests.canFocus)
                compare(help.text.indexOf("AI follow-up unavailable") >= 0, !tests.canChoose)
                compare(cmp.height, height)
                compare(firstName.mapToItem(cmp, 0, 0).y, top)
                compare(tests.all().filter(function (it) { return it.activeFocusOnTab === true }), [cmp])
                if (state.hide.length > 0) {
                    keyClick(Qt.Key_End)
                    compare(cmp.cursorHidden, true)
                    verify(help.text.indexOf("Enter show option") >= 0)
                }
                before.forceActiveFocus()
                compare(tests.named("aiCompareKeyboardHelp").length, 0)
                compare(cmp.height, height)
                cmp.cursor = -1
            }
        }
    }

    function test_maximumTextAndEvidenceRemainUnclipped() {
        var b = tests.many(4, 4)
        b.verdict = "Recommendation ".repeat(30).slice(0, 240)
        for (var i = 0; i < 4; ++i) {
            b.options[i].name = ("Candidate " + i + " ").repeat(12).slice(0, 80)
            b.options[i].summary = "Summary ".repeat(25).slice(0, 160)
            b.options[i].pros = new Array(4).fill("Pro ".repeat(40))
            b.options[i].cons = new Array(4).fill("Con ".repeat(40))
            for (var f = 0; f < 4; ++f) b.options[i].facts[f] = tests.fact(("Label " + i + f + " ").repeat(10).slice(0, 60), "Value ".repeat(24))
        }
        tests.setBlock(b)
        for (var width of [420, 560, 760, 980]) {
            tests.cw = width
            wait(30)
            compare(cmp.matrix, width === 980)
            compare(cmp.rows.length, 16)
            compare(tests.named("aiComparePoint").length, cmp.matrix ? 32 : 8)
            var items = tests.all()
            for (var item of items) {
                if (!item.visible || item.width <= 0) continue
                verify(tests.rightEdge(item) <= width + 0.5, "right edge " + item.objectName)
                if (tests.isText(item)) {
                    compare(item.elide, Text.ElideNone)
                    verify(item.height + 0.5 >= item.contentHeight, "full text height: " + item.objectName)
                }
            }
            verify(Math.abs(cmp.height - tests.contentBottom()) <= 1)
        }
    }

    function test_unusableBlockShowsOneLine() {
        tests.setBlock({type: "compare", options: [null, 7, {name: {x: 1}}], verdict: "orphan"})
        compare(cmp.usable, false)
        compare(tests.one("aiCompareInvalid").text, "This comparison can't be shown.")
        compare(tests.named("aiCompareVerdict").length, 0)
        compare(cmp.activeFocusOnTab, false)
        tests.setBlock(null)
        compare(cmp.usable, false)
        compare(tests.emitted.length, 0)
    }

    // ---- pin and hide ------------------------------------------------------------------
    function test_pinMovesFirstAndPersistsATinyState() {
        tests.cw = 760
        wait(30)
        mouseClick(tests.chip("Pin", 1))
        tryCompare(tests, "saved", {pin: 1, hide: []})
        compare(tests.emitted.length, 1)
        compare(tests.last(), {pin: 1, hide: []})
        wait(30)
        compare(tests.order(), ["Forge 16", "Aero 14", "Nova 13"])
        compare(tests.named("aiComparePinned").length, 1)
        compare(tests.chip("Pin", 0).Accessible.name, "Unpin Forge 16")
        // Authored facts rows do not reshuffle; the values follow the columns.
        var labels = tests.shownTexts().filter(function (t) { return t === "Weight" || t === "Price" || t === "Battery" })
        compare(labels, ["Weight", "Price", "Battery"])
        // Unpin.
        mouseClick(tests.chip("Pin", 0))
        tryCompare(tests, "saved", {pin: -1, hide: []})
        wait(30)
        compare(tests.order(), ["Aero 14", "Forge 16", "Nova 13"])
        verify(JSON.stringify(tests.last()).length <= 400)
    }

    function test_pinInStackedCards() {
        tests.cw = 360
        wait(30)
        mouseClick(tests.chip("Pin", 2))
        tryCompare(tests, "saved", {pin: 2, hide: []})
        wait(30)
        compare(tests.order(), ["Nova 13", "Aero 14", "Forge 16"])
    }

    function test_hideCollapsesToAStubAndShowRestores() {
        tests.cw = 760
        wait(30)
        mouseClick(tests.chip("Hide", 1))
        tryCompare(tests, "saved", {pin: -1, hide: [1]})
        wait(30)
        compare(tests.order(), ["Aero 14", "Nova 13"])
        compare(tests.stubs(), ["Forge 16 \u2014 hidden"])
        compare(tests.named("aiCompareStubs").length, 1)
        // The hidden option's own facts leave the rows (Battery was only Forge's).
        compare(cmp.rows.map(function (r) { return r.label }), ["Weight", "Price"])
        var show = tests.one("aiCompareShow")
        compare(show.Accessible.name, "Show Forge 16")
        mouseClick(show)
        tryCompare(tests, "saved", {pin: -1, hide: []})
        wait(30)
        compare(tests.order(), ["Aero 14", "Forge 16", "Nova 13"])
        compare(tests.named("aiCompareStubs").length, 0)
    }

    function test_hidingThePinnedOptionUnpinsAndTheLastVisibleStays() {
        tests.saved = {pin: 0, hide: []}
        wait(30)
        mouseClick(tests.chip("Hide", 0))
        tryCompare(tests, "saved", {pin: -1, hide: [0]})
        wait(30)
        compare(tests.order(), ["Forge 16", "Nova 13"])
        mouseClick(tests.chip("Hide", 0))
        tryCompare(tests, "saved", {pin: -1, hide: [0, 1]})
        wait(30)
        compare(tests.order(), ["Nova 13"])
        var last = tests.chip("Hide", 0)
        compare(last.enabled, false)
        compare(last.canAct, false)
        compare(last.Accessible.description, "At least one option stays visible.")
        var n = tests.emitted.length
        mouseClick(last)
        wait(40)
        compare(tests.emitted.length, n, "the last visible option cannot be hidden")
        // The keyboard obeys the same rule.
        tests.focusCompare()
        keyClick(Qt.Key_H)
        wait(40)
        compare(tests.emitted.length, n)
        compare(tests.order(), ["Nova 13"])
    }

    function test_savedStateRestoresAndStaleIndicesAreIgnored() {
        tests.saved = {pin: 2, hide: [1]}
        wait(30)
        compare(tests.order(), ["Nova 13", "Aero 14"])
        compare(tests.stubs(), ["Forge 16 \u2014 hidden"])
        tests.saved = {pin: 9, hide: [8, -1, 2.5, "0", 1]}
        wait(30)
        compare(tests.order(), ["Aero 14", "Nova 13"])
        compare(tests.stubs(), ["Forge 16 \u2014 hidden"], "only the valid index counts")
        tests.saved = {pin: -1, hide: [0, 1, 2]}
        wait(30)
        compare(tests.order().length, 1, "never every option hidden")
        tests.saved = "junk"
        wait(30)
        compare(tests.order(), ["Aero 14", "Forge 16", "Nova 13"])
        compare(tests.emitted.length, 0, "restoring never writes")
    }

    function test_aBlockChangeKeepsSavedStateAgainstTheNewOptions() {
        tests.saved = {pin: 2, hide: [0]}
        wait(30)
        compare(tests.order(), ["Nova 13", "Forge 16"])
        tests.block = tests.many(2, 0)
        wait(30)
        // Index 2 is stale in a two-option block; index 0 is still valid.
        compare(tests.order(), ["Option 1"])
        compare(tests.stubs(), ["Option 0 \u2014 hidden"])
    }

    function test_aRefusedEditStaysVisibleUntilSavedChanges() {
        tests.refuse = true
        tests.cw = 760
        wait(30)
        mouseClick(tests.chip("Pin", 2))
        tryCompare(cmp, "local", {pin: 2, hide: []})
        wait(30)
        compare(tests.order(), ["Nova 13", "Aero 14", "Forge 16"])
        compare(tests.saved, undefined)
        // Another surface changes the persisted entry: that wins.
        tests.saved = {pin: 1, hide: []}
        wait(30)
        compare(cmp.local, null)
        compare(tests.order(), ["Forge 16", "Aero 14", "Nova 13"])
    }

    // ---- choosing --------------------------------------------------------------------------
    function test_chooseEmitsTheRawOptionIndexWhenOpen() {
        tests.setBlock({type: "compare", options: [null, tests.opt("A"), {name: ""}, tests.opt("B")], verdict: ""})
        tests.cw = 760
        wait(30)
        var button = tests.chip("Choose", 1)
        compare(button.label, "Continue with B")
        compare(button.Accessible.name, "Continue with B")
        compare(button.Accessible.description, "Sends an AI follow-up about B.")
        compare(button.Accessible.role, Accessible.Button)
        compare(button.enabled, true)
        mouseClick(button)
        compare(choiceSpy.count, 1)
        compare(choiceSpy.signalArguments[0][0], 3)
        mouseClick(tests.chip("Choose", 0))
        compare(choiceSpy.signalArguments[1][0], 1)
        compare(tests.named("aiCompareHint").length, 0)
    }

    function test_chooseIsGatedWithTheHostsReason() {
        tests.canChoose = false
        tests.hint = "Only the latest answer's options can be chosen."
        wait(30)
        var button = tests.chip("Choose", 0)
        compare(button.enabled, false)
        compare(button.Accessible.description, "Sends an AI follow-up about Aero 14. " + tests.hint)
        mouseClick(button)
        tests.focusCompare()
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_Space)
        wait(30)
        compare(choiceSpy.count, 0)
        compare(tests.one("aiCompareHint").text, tests.hint)
        // A pick already made needs no excuse.
        tests.picked = 1
        wait(30)
        compare(tests.named("aiCompareHint").length, 0)
    }

    function test_chosenIsMarkedWithGlyphAndWordAndOthersStayReadable() {
        tests.canChoose = false
        tests.picked = 1
        for (var w = 0; w < 2; ++w) {
            tests.cw = w ? 360 : 760
            wait(30)
            if (!cmp.matrix) tests.inspect(1)
            var marks = tests.named("aiCompareChosen")
            compare(marks.length, 1)
            compare(marks[0].text, "Chosen")
            verify(tests.walk(tests.holderOf(1), []).indexOf(marks[0]) >= 0, "the mark sits on the chosen option")
            var check = tests.walk(tests.holderOf(1), []).filter(function (it) { return tests.isText(it) && it.text === "\u2713" })
            compare(check.length, 1)
            // Everything else still reads at the contrast floor.
            tests.checkContrast()
        }
        // The chosen option's content is still all there.
        tests.inspect(1)
        verify(tests.shownTexts().indexOf("Fast") >= 0)
        verify(tests.shownTexts().indexOf("Aero 14") >= 0)
    }

    // ---- keyboard ----------------------------------------------------------------------------------
    function test_oneTabStopForTheWholeBlock() {
        for (var w = 0; w < 2; ++w) {
            tests.cw = w ? 360 : 760
            wait(30)
            var stops = tests.all().filter(function (it) { return it.activeFocusOnTab === true })
            compare(stops, [cmp], "only the block itself is a Tab stop")
            before.forceActiveFocus()
            keyClick(Qt.Key_Tab)
            tryCompare(cmp, "activeFocus", true)
            keyClick(Qt.Key_Tab)
            tryCompare(after, "activeFocus", true)
            keyClick(Qt.Key_Tab, Qt.ShiftModifier)
            tryCompare(cmp, "activeFocus", true)
            keyClick(Qt.Key_Tab, Qt.ShiftModifier)
            tryCompare(before, "activeFocus", true)
        }
    }

    function test_arrowsMoveTheCursorAndRingFollows() {
        tests.cw = 760
        wait(30)
        tests.focusCompare()
        compare(cmp.cursorPos, 0)
        var ring = tests.one("aiCompareRing")
        var x0 = ring.x
        keyClick(Qt.Key_Right)
        compare(cmp.cursorPos, 1)
        verify(ring.x > x0)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Right)
        compare(cmp.cursorPos, 2, "no wrap")
        keyClick(Qt.Key_Left)
        compare(cmp.cursorPos, 1)
        keyClick(Qt.Key_Home)
        compare(cmp.cursorPos, 0)
        keyClick(Qt.Key_End)
        compare(cmp.cursorPos, 2)
        compare(ring.visible, true)
        compare(ring.border.width, 2)
        verify(ring.x + ring.width <= cmp.width, "the ring stays inside the block")
        verify(ring.x >= 0)
        before.forceActiveFocus()
        wait(20)
        compare(ring.visible, false)
        // Up/Down are not ours: they reach the pane to scroll.
        tests.focusCompare()
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Up)
        compare(tests.downs, 1)
        compare(tests.ups, 1)
    }

    function test_enterAndSpaceChooseTheOptionUnderTheCursor() {
        tests.cw = 760
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Return)
        compare(choiceSpy.count, 1)
        compare(choiceSpy.signalArguments[0][0], 1)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Space)
        compare(choiceSpy.signalArguments[1][0], 2)
        keyClick(Qt.Key_Enter)
        compare(choiceSpy.count, 3)
        // Modifier chords are not ours.
        keyClick(Qt.Key_P, Qt.ControlModifier)
        keyClick(Qt.Key_H, Qt.AltModifier)
        wait(30)
        compare(tests.emitted.length, 0)
    }

    function test_pAndHToggleAndTheCursorStaysOnTheOption() {
        tests.cw = 760
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_P)
        tryCompare(tests, "saved", {pin: 1, hide: []})
        wait(20)
        compare(tests.order(), ["Forge 16", "Aero 14", "Nova 13"])
        compare(cmp.cursorPos, 0, "the cursor follows the option to its new place")
        compare(cmp.cursorOption.name, "Forge 16")
        keyClick(Qt.Key_P)
        tryCompare(tests, "saved", {pin: -1, hide: []})
        wait(20)
        keyClick(Qt.Key_H)
        tryCompare(tests, "saved", {pin: -1, hide: [1]})
        wait(20)
        compare(tests.order(), ["Aero 14", "Nova 13"])
        // The cursor is on the stub now: P does nothing, Enter shows, H shows.
        compare(cmp.cursorHidden, true)
        keyClick(Qt.Key_P)
        wait(20)
        compare(tests.emitted.length, 3)
        keyClick(Qt.Key_Return)
        tryCompare(tests, "saved", {pin: -1, hide: []})
        wait(20)
        compare(tests.order(), ["Aero 14", "Forge 16", "Nova 13"])
        keyClick(Qt.Key_H)
        tryCompare(tests, "saved", {pin: -1, hide: [1]})
        keyClick(Qt.Key_H)
        tryCompare(tests, "saved", {pin: -1, hide: []})
        compare(choiceSpy.count, 0)
    }

    function test_theCursorReachesHiddenStubsAtTheEnd() {
        tests.saved = {pin: -1, hide: [0]}
        tests.cw = 360
        wait(30)
        tests.focusCompare()
        compare(cmp.cursorOption.name, "Forge 16")
        keyClick(Qt.Key_End)
        compare(cmp.cursorOption.name, "Aero 14")
        compare(cmp.cursorHidden, true)
        compare(tests.one("aiCompareStub_0").border.width, 2)
        keyClick(Qt.Key_Left)
        compare(cmp.cursorOption.name, "Nova 13")
    }

    function test_keyboardRevealsTheCursorCardWhenStacked() {
        tests.setBlock(tests.many(4, 4))
        tests.cw = 360
        tests.vh = 220
        wait(60)
        tests.focusCompare()
        compare(flick.contentY, 0)
        keyClick(Qt.Key_End)
        tryVerify(function () { return flick.contentY > 0 }, 1000)
        var card = tests.one("aiCompareCard_3")
        var top = card.mapToItem(flick.contentItem, 0, 0).y
        verify(top >= flick.contentY - 0.5, "the card top is not above the viewport")
        verify(top < flick.contentY + flick.height)
        keyClick(Qt.Key_Home)
        tryVerify(function () { return tests.named("aiCompareCard_0").length === 1 }, 1000)
        var firstTop = tests.one("aiCompareCard_0").mapToItem(flick.contentItem, 0, 0).y
        tryCompare(flick, "contentY", firstTop, 1000)
    }

    function test_leftRightInspectAndRevealOnlyTheSelectedDetail() {
        tests.cw = 420
        tests.vh = 180
        wait(30)
        tests.focusCompare()
        for (var key of [Qt.Key_Right, Qt.Key_Left]) {
            keyClick(key)
            var raw = key === Qt.Key_Right ? 1 : 0
            tryVerify(function () { return tests.named("aiCompareCard_" + raw).length === 1 }, 1000)
            var card = tests.one("aiCompareCard_" + raw)
            var top = card.mapToItem(flick.contentItem, 0, 0).y
            tryCompare(flick, "contentY", top, 1000)
            compare(tests.one("aiCompareName").text, raw === 1 ? "Forge 16" : "Aero 14")
            compare(tests.all().filter(function (it) { return /^aiCompareCard_/.test(it.objectName) }).length, 1)
        }
        compare(choiceSpy.count, 0)
        compare(focusSpy.count, 0)
        compare(tests.emitted.length, 0)
    }

    function test_matrixKeyboardAlsoRevealsAHiddenStub() {
        tests.setBlock(tests.many(4, 4))
        tests.cw = 980
        tests.vh = 180
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_H)
        tryCompare(cmp, "cursorHidden", true)
        var stub = tests.one("aiCompareStub_0")
        tryVerify(function () {
            var top = stub.mapToItem(flick.contentItem, 0, 0).y
            return top >= flick.contentY - 0.5 && top + stub.height <= flick.contentY + flick.height + 0.5
        }, 1000)
        keyClick(Qt.Key_Left)
        compare(cmp.cursorHidden, false)
        var matrixTop = tests.one("aiCompareMatrix").mapToItem(flick.contentItem, 0, 0).y
        tryCompare(flick, "contentY", matrixTop, 1000)
        compare(choiceSpy.count, 0)
    }

    function test_mouseOnAnOptionParksTheCursorThere() {
        tests.cw = 760
        wait(30)
        mouseClick(tests.chip("Pin", 2))
        tryCompare(tests, "saved", {pin: 2, hide: []})
        wait(30)
        compare(cmp.activeFocus, true)
        compare(cmp.cursorOption.name, "Nova 13")
    }

    // ---- text safety ----------------------------------------------------------------------------------
    function test_everyTextIsPlainAndHostileStringsAreCleaned() {
        var huge = "x".repeat(5000)
        var b = {type: "compare", title: "<b>x</b>", options: [
            tests.opt("<b>Bold</b> A\u0007B\u202e\u2028C", {summary: "<i>s</i>\nline\u0085two", recommended: true,
                facts: [tests.fact("<label>", "a\u0000b"), tests.fact(huge, huge)], pros: ["[link](http://x) <u>p</u>", huge], cons: ["\u200b"]}),
            tests.opt("N" + huge)], verdict: "<h1>V</h1>\u2029" + huge}
        tests.setBlock(b)
        for (var w = 0; w < 2; ++w) {
            tests.cw = w ? 360 : 760
            wait(30)
            var items = tests.all()
            for (var i = 0; i < items.length; ++i) {
                if (!tests.isText(items[i])) continue
                compare(items[i].textFormat, Text.PlainText, items[i].objectName)
                verify(items[i].text.length <= 250, "bounded text " + items[i].text.length)
                verify(!/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u202a-\u202e\u2028\u2029\u200b\u0085]/.test(items[i].text), "control character in " + items[i].objectName)
            }
            var texts = tests.shownTexts()
            verify(texts.indexOf("<b>Bold</b> A B C") >= 0, "markup stays literal: " + JSON.stringify(texts.slice(0, 6)))
            verify(texts.indexOf("<i>s</i> line two") >= 0)
            verify(texts.indexOf("[link](http://x) <u>p</u>") >= 0)
            verify(texts.some(function (t) { return t.indexOf("<h1>V</h1> ") === 0 }))
            verify(Math.abs(cmp.height - tests.contentBottom()) <= 1)
            var edges = tests.all()
            for (var k = 0; k < edges.length; ++k) {
                if (!edges[k].visible || edges[k] === cmp || edges[k].width <= 0) continue
                verify(tests.rightEdge(edges[k]) <= tests.cw + 0.5, edges[k].objectName + " overflows")
            }
        }
        // The empty-after-cleaning point is dropped, not shown as a bare glyph row.
        compare(cmp.options[0].cons.length, 0)
    }

    function test_shapesThatAreNotTheDocumentedOnesNeverThrow() {
        var shapes = [
            {type: "compare", options: [{name: "A", facts: "x", pros: {a: 1}, cons: [null, 4, {}], recommended: "yes"}, {name: "B", facts: [null, {label: 3, value: {}}]}]},
            {type: "compare", options: [{name: "A", facts: [{label: "n", value: 5}, {label: "z", value: 0}]}, {name: "B"}]},
            {type: "compare"},
            {type: "compare", options: new Array(40).fill({name: "A"})}]
        for (var i = 0; i < shapes.length; ++i) {
            tests.setBlock(shapes[i])
            wait(20)
            verify(cmp.height >= 0)
        }
        tests.setBlock(shapes[1])
        verify(tests.shownTexts().indexOf("5") >= 0, "a numeric value reads as text")
        verify(tests.shownTexts().indexOf("0") >= 0)
    }

    // ---- contrast -------------------------------------------------------------------------------------
    function checkContrast() {
        var items = tests.texts()
        verify(items.length > 5)
        for (var i = 0; i < items.length; ++i) {
            var c = items[i].color
            var sameInk = Math.abs(c.r - tests.fg.r) < 0.01 && Math.abs(c.g - tests.fg.g) < 0.01 && Math.abs(c.b - tests.fg.b) < 0.01
            if (sameInk) verify(c.a >= 0.76 - 1e-6, "text alpha " + c.a + " for " + items[i].text)
            verify(tests.ratio(c, tests.bg) >= 4.5, "contrast " + tests.ratio(c, tests.bg) + " for " + items[i].text)
        }
    }

    function test_textKeepsTheContrastFloorInEveryState() {
        var variants = [
            function () { tests.canChoose = true; tests.picked = -1 },
            function () { tests.canChoose = false; tests.picked = -1; tests.hint = "Wait for the current answer to finish." },
            function () { tests.canChoose = false; tests.picked = 0; tests.saved = {pin: 1, hide: [2]} },
            function () { tests.canChoose = true; tests.picked = 2; tests.saved = {pin: 2, hide: [0]} }]
        for (var v = 0; v < variants.length; ++v) {
            for (var w = 0; w < 2; ++w) {
                tests.saved = undefined
                variants[v]()
                tests.cw = w ? 360 : 760
                wait(30)
                tests.checkContrast()
                tests.focusCompare()
                tests.checkContrast()
                before.forceActiveFocus()
            }
        }
        // A disabled button keeps its ink at the floor and a quieter border, not a faded label.
        tests.canChoose = false
        tests.saved = undefined
        wait(30)
        var button = tests.chip("Choose", 0)
        var label = tests.walk(button, []).filter(function (it) { return tests.isText(it) })[0]
        verify(label.color.a >= 0.76)
        verify(button.border.color.a < 0.5)
    }

    function test_untouchedBlockEmitsNothing() {
        tests.cw = 760
        wait(60)
        tests.focusCompare()
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Left)
        wait(30)
        compare(tests.emitted.length, 0)
        compare(focusSpy.count, 0)
    }

    // ---- ask about an option (`?`) --------------------------------------------------------
    function test_askAboutDescriptorBuildsLabelAndDetail() {
        var opts = View.model(tests.laptops()).options
        var a = View.askAbout(opts[0])
        compare(a.index, 0)
        compare(a.label, "Aero 14")
        compare(a.detail, "Light and quiet; Facts: Weight: 1.2 kg, Price: 999; Pros: Battery lasts, Great screen; Cons: One port")
        // Empty parts are skipped.
        var b = View.askAbout(opts[2])
        compare(b.detail, "Cheap; Facts: Weight: 1.4 kg")
        var bare = View.askAbout({index: 7, name: "Solo", summary: "", facts: [], pros: [], cons: []})
        compare(bare.index, 7)
        compare(bare.detail, "")
        compare(View.askAbout(null), null)
        // The detail is clamped to 240 and the label to 80.
        var long = View.model({type: "compare", options: [tests.opt("N".repeat(300), {summary: "s".repeat(400),
            pros: ["p".repeat(100), "q".repeat(100)]})]}).options[0]
        var c = View.askAbout(long)
        verify(c.label.length <= 80)
        compare(c.detail.length, 240)
    }

    function test_askIsGatedAndEmitsTheRawIndexOnce() {
        tests.setBlock({type: "compare", options: [null, tests.opt("A", {summary: "first"}), {name: ""},
            tests.opt("B", {summary: "second", pros: ["fast"]})], verdict: ""})
        tests.cw = 760
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_Question, Qt.ShiftModifier)
        keyClick(Qt.Key_Question)
        compare(focusSpy.count, 0, "closed gate emits nothing")
        tests.canFocus = true
        wait(20)
        keyClick(Qt.Key_Question, Qt.ShiftModifier, 0, "?")
        compare(focusSpy.count, 1)
        compare(Array.prototype.slice.call(focusSpy.signalArguments[0]), [1, "A", "first"])
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Question, Qt.ShiftModifier, 0, "?")
        compare(Array.prototype.slice.call(focusSpy.signalArguments[1]), [3, "B", "second; Pros: fast"])
        compare(focusSpy.count, 2)
        compare(choiceSpy.count, 0)
        compare(tests.emitted.length, 0)
        // Modifier chords are not ours.
        keyClick(Qt.Key_Question, Qt.ControlModifier)
        keyClick(Qt.Key_Question, Qt.AltModifier)
        keyClick(Qt.Key_Question, Qt.MetaModifier)
        compare(focusSpy.count, 2)
    }

    function test_askOnAHiddenStubAsksAboutItsOwnOption() {
        tests.canFocus = true
        tests.saved = {pin: -1, hide: [1]}
        tests.cw = 360
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_End)
        compare(cmp.cursorHidden, true)
        keyClick(Qt.Key_Question, Qt.ShiftModifier, 0, "?")
        compare(focusSpy.count, 1)
        compare(focusSpy.signalArguments[0][0], 1)
        compare(focusSpy.signalArguments[0][1], "Forge 16")
        compare(focusSpy.signalArguments[0][2], "Fast; Facts: Price: 1499, Battery: 6 h; Pros: Fast; Cons: Heavy, Loud")
    }

    function test_askTextIsCleanedAndBounded() {
        tests.canFocus = true
        tests.setBlock({type: "compare", options: [
            tests.opt("<b>X</b>\u0007\u202e\u2028Y", {summary: "a\u0085b", facts: [tests.fact("k\u0000", "v\n2")],
                pros: ["\u200b", "p".repeat(500)]}), tests.opt("Z")]})
        wait(30)
        tests.focusCompare()
        keyClick(Qt.Key_Question, Qt.ShiftModifier, 0, "?")
        compare(focusSpy.count, 1)
        var args = focusSpy.signalArguments[0]
        compare(args[1], "<b>X</b> Y")
        verify(args[2].length <= 240)
        verify(args[2].indexOf("a b; Facts: k: v 2; Pros: ") === 0, args[2])
        verify(!/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u202a-\u202e\u2028\u2029\u200b\u0085]/.test(args[2]))
        // An unusable block asks about nothing.
        before.forceActiveFocus()
        tests.setBlock({type: "compare", options: [null]})
        cmp.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Question, Qt.ShiftModifier, 0, "?")
        compare(focusSpy.count, 1)
    }
}
