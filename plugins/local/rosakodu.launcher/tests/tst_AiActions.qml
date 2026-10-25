import QtQuick
import QtTest
import ".."
import "../AiState.js" as AiState

// The `actions` block renderer. The component never owns state: every
// assertion is on what it DISPLAYS or EMITS, with the host (this test) applying
// or refusing the pick exactly like the pane does (the service marks the block
// picked and closes the gate with "Wait for the current answer to finish.").
TestCase {
    id: tests
    name: "AiActions"
    width: 800
    height: 1300
    visible: true
    when: windowShown

    property var block: tests.makeBlock(4)
    property int picked: -1
    property bool canChoose: true
    property string hint: ""
    property bool accept: true
    property color fg: "#f1f2f4"
    property color bg: "#1b1c20"
    property color acc: "#b4c4dc"
    property var emitted: []
    property int escapes: 0
    property var seenKeys: []
    readonly property int keysSeen: seenKeys.length

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    Item {
        id: holder
        y: 20
        width: 760
        height: actions.height
        Keys.onEscapePressed: ++tests.escapes
        Keys.onPressed: function (event) { tests.seenKeys = tests.seenKeys.concat([event.key]) }
        AiActions {
            id: actions
            width: 420
            block: tests.block
            picked: tests.picked
            canChoose: tests.canChoose
            chooseHint: tests.hint
            foreground: tests.fg
            background: tests.bg
            accent: tests.acc
            onChoiceRequested: function (index) {
                tests.emitted = tests.emitted.concat([index])
                if (tests.accept) {
                    tests.picked = index
                    tests.canChoose = false
                    tests.hint = "Wait for the current answer to finish."
                }
            }
        }
    }
    Item { id: after; y: 700; activeFocusOnTab: true; width: 10; height: 10 }
    Item { id: hostBox; y: 760; width: 420; height: 300 }

    SignalSpy { id: choiceSpy; target: actions; signalName: "choiceRequested" }
    SignalSpy { id: focusSpy; target: actions; signalName: "focusRequested" }
    SignalSpy { id: hostSpy }

    // ---- fixtures ---------------------------------------------------------
    function makeBlock(n) {
        var names = ["Book the trip", "Compare hotels", "Skip this", "Pack a bag", "Call a friend", "Plan lunch"]
        var hints = ["Opens the checklist", "", "Nothing changes", "A short list", "", "Near the station"]
        var options = []
        for (var i = 0; i < n; ++i) options.push({label: names[i], hint: hints[i]})
        return {type: "actions", title: "Next steps", options: options}
    }
    function walk(item, out) {
        if (!item || out.indexOf(item) >= 0) return out
        out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) walk(kids[i], out)
        return out
    }
    function all() { return walk(actions, []) }
    function child(name) {
        var items = tests.all()
        for (var i = 0; i < items.length; ++i) if (items[i].objectName === name) return items[i]
        return null
    }
    function isText(it) { return typeof it.textFormat === "number" && typeof it.wrapMode === "number" && typeof it.elide === "number" }
    function tabStops() {
        var n = 0, items = tests.all()
        for (var i = 0; i < items.length; ++i) if (items[i].activeFocusOnTab === true) ++n
        return n
    }
    function chips() {
        var out = []
        for (var i = 0; child("aiActionsOption_" + i); ++i) out.push(child("aiActionsOption_" + i))
        return out
    }
    function lum(c) {
        function f(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    function mix(top, under, a) {
        return {r: top.r * a + under.r * (1 - a), g: top.g * a + under.g * (1 - a), b: top.b * a + under.b * (1 - a), a: 1}
    }
    function ratio(fg, under) {
        var flat = tests.mix(fg, under, fg.a)
        var l1 = tests.lum(flat), l2 = tests.lum(under), hi = Math.max(l1, l2), lo = Math.min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }
    function applyBlock(b) {
        tests.block = null
        wait(10)
        tests.block = b
        wait(10)
    }
    function step() { wait(30) }

    function init() {
        // Qt refuses to clear activeFocusOnTab on the focus holder and warns:
        // the roving Tab stop must never trigger that.
        failOnWarning(/activeFocusOnTab/)
        actions.width = 420
        tests.fg = "#f1f2f4"
        tests.bg = "#1b1c20"
        tests.acc = "#b4c4dc"
        tests.picked = -1
        tests.canChoose = true
        tests.hint = ""
        tests.accept = true
        tests.emitted = []
        tests.escapes = 0
        tests.seenKeys = []
        tests.block = tests.makeBlock(4)
        actions.cursor = 0
        actions.sendFailed = false
        actions.canFocus = false
        before.forceActiveFocus(Qt.TabFocusReason)
        choiceSpy.clear(); focusSpy.clear()
        wait(30)
    }

    // ---- rendering ----------------------------------------------------------
    function test_optionsRenderLabelsHintsAndNumbers() {
        var c = tests.chips()
        compare(c.length, 4)
        compare(actions.delegateCount, 4)
        compare(child("aiActionsLabel_0").text, "Book the trip")
        compare(child("aiActionsHint_0").text, "Opens the checklist")
        compare(child("aiActionsHint_0").visible, true)
        compare(child("aiActionsHint_1").visible, false, "an option without a hint has no second line")
        compare(child("aiActionsMarker_2").text, "3")
        compare(child("aiActionsStatus_0").visible, false)
        compare(child("aiActionsHint").visible, false, "an open group shows no reason line")
        compare(actions.interactive, true)
    }
    function test_twoToSixOptionsAndAHardCap() {
        for (var n = 2; n <= 6; ++n) {
            tests.applyBlock(tests.makeBlock(n))
            compare(tests.chips().length, n, n + " options")
            verify(tests.tabStops() === 1, "one Tab stop for " + n)
        }
        var many = []
        for (var i = 0; i < 40; ++i) many.push({label: "Option " + i, hint: "hint"})
        tests.applyBlock({type: "actions", title: "T", options: many})
        compare(tests.chips().length, 6, "never more than six shown")
    }
    function test_blocksWithNoUsableOptionShowOneLine() {
        var bad = [null, "nope", 7, {type: "actions"}, {type: "actions", options: "nope"},
                   {type: "actions", options: [null, 3, "x", {label: ""}, {label: "\u0007\u202e"}, {hint: "only a hint"}]}]
        for (var i = 0; i < bad.length; ++i) {
            tests.applyBlock(bad[i])
            compare(tests.chips().length, 0, "case " + i)
            compare(child("aiActionsInvalid").visible, true, "case " + i)
            compare(child("aiActionsInvalid").text, "These options can't be shown.")
            compare(tests.tabStops(), 0)
        }
        tests.applyBlock(tests.makeBlock(3))
        compare(child("aiActionsInvalid").visible, false)
    }
    function test_unlabelledOptionsAreSkippedButIndexesStayOriginal() {
        tests.applyBlock({type: "actions", title: "T", options: [{label: "First"}, {label: ""}, {label: "Third", hint: "x"}, null, {label: "Fifth"}]})
        var c = tests.chips()
        compare(c.length, 3)
        compare(child("aiActionsLabel_1").text, "Third")
        c[1].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_3)
        step()
        // Return picked the shown 2nd option (original index 2); the number key
        // 3 was dropped as a double activation or re-picked: the first emission
        // is the one that matters and it carries the ORIGINAL index.
        compare(tests.emitted[0], 2)
        tests.accept = false
        tests.picked = -1
        tests.canChoose = true
        tests.hint = ""
        tests.emitted = []
        step()
        c[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_3)
        step()
        compare(tests.emitted, [4], "key 3 is the third SHOWN option: original index 4")
    }

    // ---- picking --------------------------------------------------------------
    function test_clickEmitsOnceWithTheRightIndex() {
        var chip = child("aiActionsOption_2")
        mouseClick(chip, chip.width / 2, chip.height / 2)
        step()
        compare(tests.emitted, [2])
        compare(choiceSpy.count, 1)
        mouseClick(chip, chip.width / 2, chip.height / 2)
        step()
        compare(tests.emitted.length, 1, "a second click on a picked block is inert")
    }
    function test_deliveryHappensAfterTheHandlerReturned() {
        var chip = child("aiActionsOption_1")
        mouseClick(chip, chip.width / 2, chip.height / 2)
        compare(choiceSpy.count, 0, "nothing is emitted from inside the press handler")
        tryCompare(choiceSpy, "count", 1)
    }
    function test_doubleActivationIsOneRequest() {
        // Two activations before the first is delivered are one request.
        compare(actions.requestChoice(0), true)
        compare(actions.requestChoice(1), false, "dropped while the first is pending")
        step()
        compare(tests.emitted, [0])
        compare(actions.interactive, false, "the host marked it picked: inert")
        compare(actions.requestChoice(2), false)
        // Quick keys against a host that accepts: still exactly one pick.
        tests.picked = -1
        tests.canChoose = true
        tests.hint = ""
        tests.emitted = []
        step()
        var c = tests.chips()
        c[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_2)
        step()
        compare(tests.emitted, [0], "four quick activations are one request")
    }
    function test_aPickTheHostRefusedIsReportedAndRetryable() {
        tests.accept = false
        var chip = child("aiActionsOption_0")
        mouseClick(chip, 10, 10)
        step()
        compare(tests.emitted, [0])
        compare(child("aiActionsHint").visible, true)
        compare(child("aiActionsHint").text, "Couldn't send this choice. Try again in a moment.")
        compare(actions.interactive, true, "the options stay open")
        mouseClick(chip, 10, 10)
        step()
        compare(tests.emitted, [0, 0], "a refused pick can be retried")
        tests.picked = 0
        tests.canChoose = false
        step()
        compare(child("aiActionsHint").visible, false, "once picked the message is gone")
    }

    // ---- picked / dimmed / inert ---------------------------------------------------
    function test_pickedStateIsMarkedByGlyphAndWordNotColourAlone() {
        tests.picked = 1
        tests.canChoose = false
        tests.hint = "Only the latest answer's options can be chosen."
        step()
        compare(child("aiActionsMarker_1").text, "\u2713")
        compare(child("aiActionsStatus_1").visible, true)
        compare(child("aiActionsStatus_1").text, "Picked")
        compare(child("aiActionsMarker_0").text, "1", "the others keep their number")
        compare(child("aiActionsStatus_0").visible, false)
        var chosen = child("aiActionsOption_1"), other = child("aiActionsOption_0")
        compare(chosen.isPicked, true)
        compare(other.dimmed, true)
        compare(chosen.dimmed, false)
        verify(child("aiActionsLabel_0").color.a < child("aiActionsLabel_1").color.a, "the others are quieter")
        verify(child("aiActionsLabel_0").color.a >= 0.76 - 1e-9, "dimmed text keeps the floor")
        verify(chosen.height > other.height || child("aiActionsHint_0").visible !== child("aiActionsHint_1").visible
               || child("aiActionsStatus_1").visible, "the picked option has an extra line")
        compare(child("aiActionsHint").visible, false, "a picked block shows no reason line")
        before.forceActiveFocus(Qt.TabFocusReason)
        compare(tests.tabStops(), 0, "an inert group is not a Tab stop")
    }
    function test_pickedOptionsAreInertForMouseAndKeys() {
        tests.picked = 1
        tests.canChoose = false
        step()
        var c = tests.chips()
        compare(actions.cursor, 1, "the cursor follows the pick")
        mouseClick(c[0], 10, 10)
        c[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_1)
        keyClick(Qt.Key_Right)
        step()
        compare(tests.emitted.length, 0)
        compare(actions.cursor, 0, "arrows are inert: the cursor stays on the focus holder")
        tests.picked = -1
        tests.canChoose = true
        tests.hint = ""
        step()
        compare(actions.interactive, true, "a failed answer reopens the options")
        compare(tests.tabStops(), 1)
    }
    function test_closedGateShowsTheReasonAndIsInert() {
        var reasons = ["Wait for the current answer to finish.", "Only the latest answer's options can be chosen.", ""]
        for (var r = 0; r < reasons.length; ++r) {
            tests.canChoose = false
            tests.hint = reasons[r]
            step()
            compare(child("aiActionsHint").visible, true)
            compare(child("aiActionsHint").text, reasons[r] !== "" ? reasons[r] : "Choosing is not available right now.")
            compare(child("aiActionsHint").textFormat, Text.PlainText)
            before.forceActiveFocus(Qt.TabFocusReason)
            compare(tests.tabStops(), 0)
            var c = tests.chips()
            for (var i = 0; i < c.length; ++i) compare(c[i].dimmed, true)
            mouseClick(c[1], 10, 10)
            c[1].forceActiveFocus(Qt.TabFocusReason)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_2)
            step()
            compare(tests.emitted.length, 0, "gate closed: " + reasons[r])
        }
        tests.canChoose = true
        tests.hint = ""
        step()
        compare(child("aiActionsHint").visible, false)
        compare(tests.tabStops(), 1)
    }
    function test_pickedIndexOutsideTheShownOptionsDimsEverything() {
        tests.picked = 9
        tests.canChoose = false
        step()
        var c = tests.chips()
        for (var i = 0; i < c.length; ++i) {
            compare(c[i].isPicked, false)
            compare(c[i].dimmed, true)
        }
        compare(tests.emitted.length, 0)
    }

    // ---- keyboard ----------------------------------------------------------------
    function test_theGroupIsOneTabStopAndNeverTraps() {
        compare(tests.tabStops(), 1)
        before.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Tab)
        var c = tests.chips()
        compare(c[0].activeFocus, true, "Tab enters on the first option")
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true, "the next Tab leaves the group")
        keyClick(Qt.Key_Backtab)
        compare(c[0].activeFocus, true, "Shift+Tab comes back to the cursor")
        keyClick(Qt.Key_Backtab)
        compare(before.activeFocus, true)
        // Roving: after moving the cursor, Tab re-enters at the new cursor.
        keyClick(Qt.Key_Tab)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Right)
        compare(c[2].activeFocus, true)
        compare(tests.tabStops(), 1, "still exactly one Tab stop")
        compare(c[2].activeFocusOnTab, true)
        compare(c[0].activeFocusOnTab, false)
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true)
        keyClick(Qt.Key_Backtab)
        compare(c[2].activeFocus, true, "re-entry lands on the roving cursor")
        compare(tests.emitted.length, 0, "moving never picks")
    }
    function test_arrowsHomeEndMoveAndClamp() {
        var c = tests.chips()
        c[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Left)
        compare(actions.cursor, 0, "no wrap before the first")
        keyClick(Qt.Key_Right); compare(actions.cursor, 1); compare(c[1].activeFocus, true)
        keyClick(Qt.Key_Down); compare(actions.cursor, 2)
        keyClick(Qt.Key_Up); compare(actions.cursor, 1)
        keyClick(Qt.Key_Left); compare(actions.cursor, 0)
        keyClick(Qt.Key_End); compare(actions.cursor, 3); compare(c[3].activeFocus, true)
        keyClick(Qt.Key_Right); compare(actions.cursor, 3, "no wrap past the last")
        keyClick(Qt.Key_Home); compare(actions.cursor, 0)
        compare(tests.emitted.length, 0)
        compare(tests.keysSeen, 0, "handled keys do not bubble")
    }
    function test_enterAndSpacePickTheCursorOption() {
        tests.accept = false
        var c = tests.chips()
        c[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Return)
        step()
        keyClick(Qt.Key_End)
        keyClick(Qt.Key_Space)
        step()
        keyClick(Qt.Key_Home)
        keyClick(Qt.Key_Enter)
        step()
        compare(tests.emitted, [1, 3, 0])
    }
    function test_numberKeysPickTheNthOption() {
        tests.accept = false
        var c = tests.chips()
        c[2].forceActiveFocus(Qt.TabFocusReason)
        var keys = [Qt.Key_1, Qt.Key_2, Qt.Key_3, Qt.Key_4]
        for (var i = 0; i < keys.length; ++i) {
            keyClick(keys[i])
            step()
        }
        compare(tests.emitted, [0, 1, 2, 3])
        tests.emitted = []
        tests.seenKeys = []
        keyClick(Qt.Key_5)
        keyClick(Qt.Key_6)
        keyClick(Qt.Key_0)
        keyClick(Qt.Key_7)
        keyClick(Qt.Key_1, Qt.ControlModifier)
        keyClick(Qt.Key_1, Qt.AltModifier)
        step()
        compare(tests.emitted.length, 0, "no such option / modified keys never pick")
        var digits = tests.seenKeys.filter(function(k) { return k >= Qt.Key_0 && k <= Qt.Key_9 })
        compare(digits, [Qt.Key_5, Qt.Key_6, Qt.Key_0, Qt.Key_7, Qt.Key_1, Qt.Key_1], "unhandled keys keep bubbling")
        tests.applyBlock(tests.makeBlock(6))
        tests.chips()[0].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_6)
        step()
        compare(tests.emitted, [5])
    }
    function test_escapeAndTabAreNeverConsumed() {
        var c = tests.chips()
        c[1].forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Escape)
        compare(tests.escapes, 1)
        keyClick(Qt.Key_PageDown)
        compare(tests.seenKeys.indexOf(Qt.Key_PageDown) >= 0, true, "paging keys reach the pane")
        keyClick(Qt.Key_Tab)
        compare(after.activeFocus, true, "Tab leaves")
    }
    function test_focusRingIsTwoPixelAccent() {
        var c = tests.chips()
        compare(c[0].border.width, 1)
        c[0].forceActiveFocus(Qt.TabFocusReason)
        tryCompare(c[0], "activeFocus", true)
        compare(c[0].border.width, 2)
        compare(c[0].border.color, actions.accent)
        keyClick(Qt.Key_Right)
        compare(c[0].border.width, 1, "the ring moves with the cursor")
        compare(c[1].border.width, 2)
        compare(c[1].border.color, actions.accent)
    }
    function test_mouseClickMovesTheCursorAndFocus() {
        tests.accept = false
        var c = tests.chips()
        mouseClick(c[2], 10, 10)
        tryCompare(c[2], "activeFocus", true)
        compare(actions.cursor, 2)
        step()
        compare(tests.emitted, [2])
    }

    function test_questionMarkAsksAboutTheFocusedOptionOnlyWhenTheHostOpensTheGate() {
        tests.applyBlock({type: "actions", title: "T", options: [{label: "First", hint: "h1"}, {label: ""}, {label: "Third", hint: "h3"}]})
        var c = tests.chips()
        c[1].forceActiveFocus(Qt.TabFocusReason)
        keyClick("?")
        compare(focusSpy.count, 0, "closed by default")
        compare(tests.seenKeys.indexOf(Qt.Key_Question) >= 0, true, "and the key bubbles")
        actions.canFocus = true
        keyClick("?")
        compare(focusSpy.count, 1)
        compare(Array.prototype.slice.call(focusSpy.signalArguments[0]), [2, "Third", "h3"], "ORIGINAL index, label, hint")
        compare(tests.emitted.length, 0, "asking never picks")
        compare(actions.interactive, true)
        keyClick("?", Qt.ControlModifier)
        compare(focusSpy.count, 1)
    }

    // ---- layout ----------------------------------------------------------------------
    function longBlock() {
        var options = []
        for (var i = 0; i < 6; ++i)
            options.push({label: "W".repeat(40), hint: "H".repeat(60)})
        return {type: "actions", title: "Wide", options: options}
    }
    function test_wrapsAtTwoEightyAndSevenSixtyWithoutOverflow() {
        tests.applyBlock(tests.longBlock())
        var widths = [280, 760]
        var heights = []
        for (var w = 0; w < widths.length; ++w) {
            actions.width = widths[w]
            wait(30)
            var c = tests.chips()
            compare(c.length, 6)
            for (var i = 0; i < c.length; ++i) {
                var chip = c[i], label = child("aiActionsLabel_" + i), hint = child("aiActionsHint_" + i)
                verify(chip.x >= -0.5 && chip.x + chip.width <= widths[w] + 0.5, "width " + widths[w] + " chip " + i + " fits")
                verify(chip.height >= 36, "tap height")
                verify(label.truncated === false && hint.truncated === false, "wrapped, never truncated")
                verify(label.contentWidth <= label.width + 0.5, "label inside its box")
                verify(hint.contentWidth <= hint.width + 0.5, "hint inside its box")
                verify(label.y + label.height + (hint.visible ? hint.height + 2 : 0) + 8 <= chip.height + 0.5, "text inside the chip")
            }
            heights.push(actions.implicitHeight)
            if (widths[w] === 280) verify(child("aiActionsLabel_0").lineCount > 1, "a 40 character label wraps at 280")
        }
        verify(heights[0] > heights[1], "narrow is taller: " + heights)
        actions.width = 420
    }
    function test_shortLabelsSitSideBySideWhenThereIsRoom() {
        actions.width = 760
        wait(30)
        var c = tests.chips()
        verify(c[1].x > c[0].x && Math.abs(c[1].y - c[0].y) < 1, "chips share a row")
    }

    // ---- accessibility -----------------------------------------------------------------
    function test_accessibleNamesRolesAndState() {
        compare(actions.Accessible.name, "Next steps")
        compare(actions.Accessible.role, Accessible.Grouping)
        var c = tests.chips()
        compare(c[0].Accessible.name, "Book the trip, Opens the checklist")
        compare(c[1].Accessible.name, "Compare hotels")
        for (var i = 0; i < c.length; ++i) {
            compare(c[i].Accessible.role, Accessible.Button)
            compare(c[i].Accessible.checkable, true)
            compare(c[i].Accessible.checked, false)
        }
        compare(actions.Accessible.description.indexOf("number keys 1 to 4") >= 0, true)
        tests.picked = 0
        tests.canChoose = false
        step()
        compare(c[0].Accessible.checked, true)
        compare(c[0].Accessible.description, "Picked")
        compare(c[1].Accessible.checked, false)
        tests.applyBlock({type: "actions", options: [{label: "A"}, {label: "B"}]})
        compare(actions.Accessible.name, "Follow-up options", "an untitled block still names its group")
    }

    // ---- hostile text --------------------------------------------------------------------
    function test_modelTextIsPlainCleanedAndBounded() {
        var huge = "x".repeat(5000)
        tests.applyBlock({type: "actions", title: "<b>T</b>", options: [
            {label: "<b>Bold</b> &amp; <img src=x>", hint: "<a href='https://x'>link</a>"},
            {label: "A\u0007B\u202eC\u2028D", hint: "\u0085\u200bq"},
            {label: huge, hint: huge}]})
        var c = tests.chips()
        compare(c.length, 3)
        compare(child("aiActionsLabel_0").text, "<b>Bold</b> &amp; <img src=x>")
        compare(child("aiActionsLabel_0").textFormat, Text.PlainText)
        compare(child("aiActionsHint_0").textFormat, Text.PlainText)
        compare(child("aiActionsStatus_0").textFormat, Text.PlainText)
        compare(child("aiActionsMarker_0").textFormat, Text.PlainText)
        compare(child("aiActionsLabel_1").text, "A B C D")
        compare(child("aiActionsHint_1").text, "q")
        compare(child("aiActionsLabel_2").text.length, 40)
        compare(child("aiActionsHint_2").text.length, 60)
        compare(c[2].Accessible.name.length, 40 + 2 + 60)
        verify(c[2].height < 200, "a hostile option stays bounded: " + c[2].height)
        // What is shown is what choiceWire would send.
        var wire = AiState.choiceWire(tests.block, 1, 0, "actions", 2)
        compare(wire.label, child("aiActionsLabel_2").text)
    }
    function test_theBlockIsNeverMutatedAndNothingIsEmittedAtCreation() {
        var snapshot = JSON.stringify(tests.block)
        var c = tests.chips()
        mouseClick(c[0], 10, 10)
        step()
        compare(JSON.stringify(tests.block), snapshot)
        compare(focusSpy.count, 0, "this renderer has no focus affordance")
        compare(choiceSpy.count, 1)
    }
    function test_replacingTheBlockKeepsTheCursorInRange() {
        tests.chips()[3].forceActiveFocus(Qt.TabFocusReason)
        compare(actions.cursor, 3)
        tests.block = tests.makeBlock(2)
        wait(30)
        compare(actions.cursor, 1)
        compare(tests.chips().length, 2)
        compare(tests.tabStops(), 1)
    }

    // ---- contrast ---------------------------------------------------------------------------
    // The surfaces a text can sit on: dimmed options only the card, the picked
    // one its tint, an open option also hover / focus / pressed tints.
    function surfacesOf(it) {
        var chip = null
        for (var p = it; p; p = p.parent) if ((p.objectName || "").indexOf("aiActionsOption_") === 0) { chip = p; break }
        if (!chip) return [tests.bg]
        if (chip.isPicked) return [tests.mix(tests.acc, tests.bg, 0.12)]
        if (chip.dimmed) return [tests.bg]
        return [tests.bg, tests.mix(tests.fg, tests.bg, 0.045), tests.mix(tests.acc, tests.bg, 0.08),
                tests.mix(tests.acc, tests.bg, 0.20)]
    }
    function checkContrast(label) {
        var items = tests.all(), seen = 0
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (!tests.isText(it) || !it.visible || it.text.length === 0) continue
            ++seen
            var glyph = it.text === "\u2713"
            if (!glyph) verify(it.color.a >= 0.76 - 1e-9, label + ": alpha floor " + it.color.a + " for " + it.text)
            var under = tests.surfacesOf(it)
            for (var u = 0; u < under.length; ++u) {
                var r = tests.ratio(it.color, under[u])
                verify(r >= (glyph ? 3.0 : 4.5), label + ": contrast " + r.toFixed(2) + " for '" + it.text + "' over " + u)
            }
        }
        return seen
    }
    function test_textMeetsTheContrastFloorInEveryStateAndTheme() {
        var themes = [
            {fg: "#f1f2f4", bg: "#1b1c20", acc: "#b4c4dc"},
            {fg: "#dbb42c", bg: "#360003", acc: "#e8c05a"},
            {fg: "#1c1c20", bg: "#f4f4f6", acc: "#2a5db0"}]
        for (var t = 0; t < themes.length; ++t) {
            tests.fg = themes[t].fg; tests.bg = themes[t].bg; tests.acc = themes[t].acc
            tests.picked = -1; tests.canChoose = true; tests.hint = ""
            step()
            var open = tests.checkContrast("open " + t)
            verify(open >= 8, "open state text seen: " + open)
            tests.canChoose = false; tests.hint = "Only the latest answer's options can be chosen."
            step()
            verify(tests.checkContrast("gate closed " + t) >= 9)
            tests.picked = 2
            step()
            verify(tests.checkContrast("picked " + t) >= 9)
            // The same with the open state's focus ring (tint) present.
            tests.picked = -1; tests.canChoose = true; tests.hint = ""
            step()
            tests.chips()[1].forceActiveFocus(Qt.TabFocusReason)
            verify(tests.checkContrast("focused " + t) >= 8)
        }
    }

    // ---- through the block host ------------------------------------------------------------
    // Created on demand so a problem elsewhere in AiBlocks's import chain fails
    // only this test, loudly, instead of the whole file.
    function test_theBlockHostInstantiatesItAndForwardsTheOriginalIndex() {
        var component = Qt.createComponent("../AiBlocks.qml")
        verify(component.status === Component.Ready, "AiBlocks: " + component.errorString())
        var host = component.createObject(hostBox, {
            width: 420, foreground: "#f1f2f4", background: "#1b1c20", accent: "#b4c4dc",
            blocks: [{type: "actions", title: "Next steps", options: [
                {label: "Book the trip", hint: "Opens the checklist"}, {label: "Compare hotels", hint: ""}]}],
            blockIndices: [5], choiceCanSubmit: true})
        verify(host !== null)
        var spy = hostSpy
        spy.clear()
        spy.target = host
        spy.signalName = "choiceRequested"
        wait(60)
        var rendered = findChild(host, "aiActions")
        verify(rendered !== null)
        compare(rendered.canChoose, true)
        var chip = findChild(rendered, "aiActionsOption_1")
        verify(chip !== null)
        mouseClick(chip, chip.width / 2, chip.height / 2)
        tryCompare(spy, "count", 1)
        compare(Array.prototype.slice.call(spy.signalArguments[0]), [5, "actions", 1])
        spy.target = null
        host.destroy()
    }
}
