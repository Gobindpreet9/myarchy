import QtQuick
import QtTest
import ".."
import "../AiState.js" as AiState
import "../AiCalcEdit.js" as Edit
import "TestJson.js" as TestJson

// The `form` block renderer. The component never owns state: every assertion is
// on what it DISPLAYS or EMITS, with the host (this test) applying or refusing
// the emitted entry exactly like the pane does.
TestCase {
    id: tests
    name: "AiForm"
    width: 800
    height: 1000
    visible: true
    when: windowShown

    property var block: tests.makeBlock()
    property var saved: undefined
    property bool canSubmit: true
    property string hint: ""
    property bool refuse: false
    property var emitted: []
    property int escapes: 0
    // The pane applies `sent` synchronously inside the submit signal.
    property bool autoSend: false

    Item { id: before; activeFocusOnTab: true; width: 10; height: 10 }
    Item {
        id: holder
        y: 20
        width: 760
        height: form.height
        Keys.onEscapePressed: ++tests.escapes
        AiForm {
            id: form
            width: 420
            block: tests.block
            saved: tests.saved
            canSubmit: tests.canSubmit
            submitHint: tests.hint
            foreground: "#f1f2f4"
            background: "#1b1c20"
            accent: "#b4c4dc"
            onStateEdited: function (state) {
                tests.emitted = tests.emitted.concat([JSON.parse(JSON.stringify(state))])
                if (!tests.refuse) tests.saved = state
            }
            onSubmitRequested: {
                if (tests.autoSend) tests.saved = {v: tests.lastV() || ({}), sent: true}
            }
        }
    }
    Item { id: after; y: 960; activeFocusOnTab: true; width: 10; height: 10 }

    SignalSpy { id: submitSpy; target: form; signalName: "submitRequested" }

    // ---- fixtures ---------------------------------------------------------
    function field(id, label, kind, extra) {
        return Object.assign({id: id, label: label, kind: kind, unit: "", min: 0, max: 0, step: 0, value: 0,
            options: [], placeholder: ""}, extra || {})
    }
    function makeBlock() {
        return {type: "form", title: "Trip details", submitLabel: "Send answers", note: "Used to tailor the plan.",
            fields: [
                tests.field("budget", "Budget", "number", {unit: "EUR", min: 100, max: 5000, step: 50, value: 1000}),
                tests.field("style", "Travel style", "choice", {options: ["Relaxed", "Balanced", "Packed"], value: 1}),
                tests.field("notes", "Anything to avoid", "text", {placeholder: "Optional"}),
                tests.field("flex", "Flexible dates", "toggle", {value: 0})
            ]}
    }
    // Last field is typed text (Enter there is the submit path).
    function textLastBlock() {
        return {type: "form", title: "Contact", submitLabel: "Send", note: "",
            fields: [tests.field("age", "Age", "number", {min: 0, max: 120, step: 1, value: 30}),
                     tests.field("name", "Name", "text", {placeholder: "Your name"})]}
    }
    // Replacing a block with an equal field list reuses the delegates (and their
    // typed text), so a hard reset goes through an unusable block first.
    function setBlock(b) {
        tests.block = null
        tests.saved = undefined
        wait(20)
        tests.block = b
        wait(20)
        tryVerify(function() { return tests.countNamed("aiFormField_0") === (form.usable ? 1 : 0) }, 2000)
    }
    // Visual lookup: a replaced delegate is detached at once but only deleted
    // later, and findChild would still return that stale object.
    function child(n) {
        var items = tests.all()
        for (var i = 0; i < items.length; ++i) if (items[i].objectName === n) return items[i]
        return null
    }
    function walk(item, out) {
        if (!item || out.indexOf(item) >= 0) return out
        out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) walk(kids[i], out)
        if (item.contentItem) walk(item.contentItem, out)
        if (item.background) walk(item.background, out)
        return out
    }
    function all() { return walk(form, []) }
    function countNamed(name) {
        var n = 0, items = tests.all()
        for (var i = 0; i < items.length; ++i) if (items[i].objectName === name) ++n
        return n
    }
    function isText(it) { return typeof it.textFormat === "number" && typeof it.wrapMode === "number" && typeof it.elide === "number" }
    function isField(it) { return typeof it.selectByMouse === "boolean" && typeof it.placeholderText === "string" }
    function typeText(s) { for (var i = 0; i < s.length; ++i) keyClick(s.charAt(i)) }
    function enterText(item, s) {
        item.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(item, "activeFocus", true)
        item.selectAll()
        tests.typeText(s)
    }
    function lastV() { return tests.emitted.length ? tests.emitted[tests.emitted.length - 1].v : null }
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
        form.width = 420
        form.issues = ({})
        form.notes = ({})
        tests.canSubmit = true
        tests.hint = ""
        tests.refuse = false
        tests.emitted = []
        tests.escapes = 0
        tests.autoSend = false
        tests.setBlock(tests.makeBlock())
        submitSpy.clear()
        before.forceActiveFocus()
        wait(0)
    }

    // ---- rendering ----------------------------------------------------------
    function test_fieldsRenderInOrderWithDefaults() {
        compare(form.usable, true)
        compare(form.delegateCount, 4)
        compare(child("aiFormLabel_0").text, "Budget")
        compare(child("aiFormLabel_1").text, "Travel style")
        compare(child("aiFormLabel_2").text, "Anything to avoid")
        compare(child("aiFormLabel_3").visible, false, "a toggle's label is its own text")
        compare(child("aiFormInput_0").text, "1000")
        compare(child("aiFormUnit_0").text, "EUR")
        compare(child("aiFormRange_0").text, "Allowed: 100 to 5000 EUR")
        compare(child("aiFormInput_2").text, "")
        compare(child("aiFormPlaceholder_2").text, "Optional")
        compare(child("aiFormPlaceholder_2").visible, true)
        compare(child("aiFormChip_1_1").picked, true)
        compare(child("aiFormChip_1_0").picked, false)
        compare(child("aiFormToggle_3").on, false)
        compare(child("aiFormSubmit").text, "Send answers")
        compare(child("aiFormSubmit").enabled, true)
        compare(child("aiFormBlockNote").text, "Used to tailor the plan.")
        compare(child("aiFormSent").visible, false)
        compare(child("aiFormHint").visible, false)
        tryVerify(function () {
            return child("aiFormField_0").y < child("aiFormField_1").y && child("aiFormField_1").y < child("aiFormField_2").y
                && child("aiFormField_2").y < child("aiFormField_3").y
        }, 1000, "authored order")
    }
    function test_untouchedFormEmitsNothing() {
        wait(30)
        compare(tests.emitted.length, 0)
    }

    // ---- number -------------------------------------------------------------
    function test_numberTypingEmitsOnlyValidInRangeValues() {
        var input = child("aiFormInput_0")
        tests.enterText(input, "2500")
        var v = tests.lastV()
        verify(v !== null)
        compare(v.budget, 2500)
        compare(tests.emitted[tests.emitted.length - 1].sent, false)
        for (var i = 0; i < tests.emitted.length; ++i) {
            var n = tests.emitted[i].v.budget
            verify(typeof n === "number" && isFinite(n) && n >= 100 && n <= 5000, "only valid numbers leave the field: " + n)
        }
        compare(form.hasIssues, false)
        compare(child("aiFormSubmit").enabled, true)
    }
    function test_invalidNumberIsNeverStoredOrEmitted() {
        var input = child("aiFormInput_0")
        var cases = ["12abc", "1,5", "abc", "1e", "--3", "1 2", "0x10"]
        for (var c = 0; c < cases.length; ++c) {
            tests.emitted = []
            tests.saved = undefined
            tests.enterText(input, cases[c])
            for (var i = 0; i < tests.emitted.length; ++i) {
                var b = tests.emitted[i].v.budget
                verify(b === undefined || (typeof b === "number" && b >= 100 && b <= 5000), cases[c] + " leaked " + b)
            }
            verify(child("aiFormMessage_0").visible && child("aiFormMessage_0").text.length > 0, cases[c] + " shows a message")
            compare(child("aiFormSubmit").enabled, false, cases[c] + " blocks sending")
            verify(child("aiFormHint").visible && child("aiFormHint").text.indexOf("Fix") === 0)
        }
        // Empty is invalid too (a number is required), and nothing is emitted.
        tests.emitted = []
        input.forceActiveFocus(Qt.TabFocusReason)
        input.selectAll()
        keyClick(Qt.Key_Delete)
        compare(tests.emitted.length, 0)
        compare(child("aiFormMessage_0").text, "Enter a number.")
        // Fixing it clears the message and re-enables sending.
        tests.typeText("350")
        compare(tests.lastV().budget, 350)
        compare(child("aiFormMessage_0").visible, false)
        compare(child("aiFormSubmit").enabled, true)
    }
    function test_invalidTextStaysVisibleAfterFocusLeaves() {
        var input = child("aiFormInput_0")
        tests.enterText(input, "12abc")
        child("aiFormInput_2").forceActiveFocus(Qt.TabFocusReason)
        compare(input.text, "12abc", "the person's text is never silently reverted")
        compare(child("aiFormMessage_0").visible, true)
        compare(child("aiFormSubmit").enabled, false)
        compare(tests.emitted.length, 0, JSON.stringify(tests.emitted))
    }
    function test_outOfRangeIsClampedOnCommitWithANote() {
        var input = child("aiFormInput_0")
        tests.enterText(input, "99999")
        for (var i = 0; i < tests.emitted.length; ++i)
            verify(tests.emitted[i].v.budget <= 5000, "an out-of-range number is never emitted: " + tests.emitted[i].v.budget)
        compare(child("aiFormMessage_0").text.indexOf("Outside the allowed range of 100 to 5000 EUR"), 0)
        compare(child("aiFormSubmit").enabled, false)
        keyClick(Qt.Key_Return)
        compare(tests.lastV().budget, 5000)
        compare(input.text, "5000")
        compare(child("aiFormNote_0").visible, true)
        compare(child("aiFormNote_0").text, "Adjusted to 5000.")
        compare(child("aiFormMessage_0").visible, false)
        compare(child("aiFormSubmit").enabled, true)
        wait(30)
        compare(submitSpy.count, 0, "an adjusted Enter is not also a submit")
        // Below the minimum, committed by leaving the field.
        tests.enterText(input, "5")
        child("aiFormInput_2").forceActiveFocus(Qt.TabFocusReason)
        compare(tests.lastV().budget, 100)
        compare(input.text, "100")
        compare(child("aiFormNote_0").text, "Adjusted to 100.")
        // A later valid edit removes the note.
        tests.enterText(input, "400")
        compare(child("aiFormNote_0").visible, false)
    }

    // ---- text ---------------------------------------------------------------
    function test_textValidationAndLimits() {
        var input = child("aiFormInput_2")
        tests.enterText(input, "Vegan food, no night buses")
        compare(tests.lastV().notes, "Vegan food, no night buses")
        compare(form.hasIssues, false)
        var count = tests.emitted.length
        tests.enterText(input, "x".repeat(201))
        compare(tests.emitted.length > count ? tests.lastV().notes.length <= 200 : true, true)
        compare(child("aiFormMessage_2").text, "Too long. Use at most 200 characters.")
        compare(child("aiFormSubmit").enabled, false)
        tests.enterText(input, "y".repeat(200))
        compare(tests.lastV().notes.length, 200)
        compare(child("aiFormMessage_2").visible, false)
        // A control character (pasted) is rejected, never stored.
        input.forceActiveFocus(Qt.TabFocusReason)
        input.text = ""
        count = tests.emitted.length
        input.insert(0, "a\u0007b")
        input.textEdited()
        compare(tests.emitted.length, count)
        verify(child("aiFormMessage_2").text.indexOf("control or invisible") >= 0)
    }
    function test_textPolicyMatchesTheCalcCellPolicyUpTo64() {
        var samples = ["", " ", "plain", "tab\there", "bidi\u202eevil", "zero\u200bwidth", "lone\ud800half", "emoji \ud83d\ude00",
            "a\u0085b", "nbsp\u00a0ok", "x".repeat(64), "x".repeat(65)]
        for (var i = 0; i < samples.length; ++i) {
            var mine = AiState.formParseText(samples[i]), theirs = Edit.parseCell(samples[i], "text")
            if (samples[i].length <= 64) compare(mine.ok, theirs.ok, JSON.stringify(samples[i]))
            else compare(mine.ok, true, "the form allows up to 200 characters")
        }
        compare(AiState.formParseText("x".repeat(200)).ok, true)
        compare(AiState.formParseText("x".repeat(201)).ok, false)
        compare(AiState.formParseText("  padded  ").text, "padded")
    }

    // ---- choice ---------------------------------------------------------------
    function test_choiceIsOneTabStopWithArrowsAndSpace() {
        var chips = []
        for (var k = 0; k < 3; ++k) chips.push(child("aiFormChip_1_" + k))
        var stops = 0, items = tests.all()
        var groupItem = child("aiFormChoice_1")
        verify(groupItem !== null)
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it.activeFocusOnTab === true && walkContains(groupItem, it)) ++stops
        }
        compare(stops, 1, "the whole choice group is one Tab stop")
        groupItem.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(groupItem, "activeFocus", true)
        compare(groupItem.cursor, 1, "the cursor starts on the selection")
        keyClick(Qt.Key_Right)
        compare(groupItem.cursor, 2)
        compare(tests.emitted.length, 0, "arrows move the cursor, they do not select")
        keyClick(Qt.Key_Right)
        compare(groupItem.cursor, 2, "no wrap past the last option")
        keyClick(Qt.Key_Space)
        compare(tests.lastV().style, 2)
        compare(chips[2].picked, true)
        keyClick(Qt.Key_Home)
        compare(groupItem.cursor, 0)
        keyClick(Qt.Key_Return)
        compare(tests.lastV().style, 0)
        keyClick(Qt.Key_End)
        keyClick(Qt.Key_Enter)
        compare(tests.lastV().style, 2)
        compare(submitSpy.count, 0, "Enter on a choice selects, never submits")
        compare(chips[2].border.width, 2, "the cursor chip has a 2 px ring while focused")
    }
    function walkContains(root, item) {
        for (var p = item; p; p = p.parent) if (p === root) return true
        return false
    }
    function test_choiceMouseSelectsAndEmitsOnce() {
        var chip = child("aiFormChip_1_2")
        mouseClick(chip, chip.width / 2, chip.height / 2)
        compare(tests.emitted.length, 1)
        compare(tests.lastV().style, 2)
        mouseClick(chip, chip.width / 2, chip.height / 2)
        compare(tests.emitted.length, 1, "choosing the selected option again is not an edit")
    }

    // ---- toggle ---------------------------------------------------------------
    function test_toggleKeysFlipTheValue() {
        var toggle = child("aiFormToggle_3")
        toggle.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(toggle, "activeFocus", true)
        keyClick(Qt.Key_Space)
        compare(tests.lastV().flex, 1)
        compare(toggle.on, true)
        keyClick(Qt.Key_Return)
        compare(tests.lastV().flex, 0)
        compare(toggle.on, false)
        compare(toggle.Accessible.name, "Flexible dates")
        compare(toggle.Accessible.role, Accessible.CheckBox)
    }

    // ---- keyboard-only completion and submit ------------------------------------
    function test_keyboardOnlyCompletionReachesSubmit() {
        keyClick(Qt.Key_Tab)
        var budget = child("aiFormInput_0")
        verify(budget.activeFocus, "Tab from before the form lands on the first field")
        budget.selectAll()
        tests.typeText("1800")
        keyClick(Qt.Key_Tab)
        var group = child("aiFormChoice_1")
        verify(group.activeFocus, "the choice group is the next stop")
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_Tab)
        var notes = child("aiFormInput_2")
        verify(notes.activeFocus)
        tests.typeText("No hostels")
        keyClick(Qt.Key_Tab)
        verify(child("aiFormToggle_3").activeFocus)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_Tab)
        var submit = child("aiFormSubmit")
        verify(submit.activeFocus, "the submit button follows the last field")
        compare(submit.enabled, true)
        keyClick(Qt.Key_Space)
        tryCompare(submitSpy, "count", 1)
        var v = tests.lastV()
        compare(v.budget, 1800)
        compare(v.style, 2)
        compare(v.notes, "No hostels")
        compare(v.flex, 1)
    }
    function test_enterInTheLastFieldSubmitsOnlyWhenValid() {
        tests.setBlock(tests.textLastBlock())
        var name = child("aiFormInput_1")
        tests.enterText(name, "Ada")
        keyClick(Qt.Key_Return)
        tryCompare(submitSpy, "count", 1, 2000, "Enter in the last field submits a valid form")
        // Invalid sibling: no submit.
        submitSpy.clear()
        tests.saved = undefined
        tests.enterText(child("aiFormInput_0"), "x1")
        tests.enterText(name, "Ada")
        keyClick(Qt.Key_Return)
        wait(30)
        compare(submitSpy.count, 0, "an invalid form never submits from Enter")
        // The host's gate closed: no submit either.
        tests.enterText(child("aiFormInput_0"), "31")
        tests.canSubmit = false
        name.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        wait(30)
        compare(submitSpy.count, 0)
        // Enter in a non-last field only commits.
        tests.canSubmit = true
        child("aiFormInput_0").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        wait(30)
        compare(submitSpy.count, 0)
        // When the last field is not a text entry, Enter in a text field never submits.
        tests.setBlock(tests.makeBlock())
        tests.enterText(child("aiFormInput_2"), "x")
        keyClick(Qt.Key_Return)
        wait(30)
        compare(submitSpy.count, 0)
    }
    function test_enterAdjustingANumberDoesNotAlsoSubmit() {
        tests.setBlock({type: "form", title: "T", submitLabel: "Go", note: "",
            fields: [tests.field("n", "N", "number", {min: 1, max: 10, step: 1, value: 5})]})
        var input = child("aiFormInput_0")
        tests.enterText(input, "50")
        keyClick(Qt.Key_Return)
        wait(30)
        compare(submitSpy.count, 0)
        compare(input.text, "10")
        keyClick(Qt.Key_Return)
        tryCompare(submitSpy, "count", 1, 2000, "a second Enter on the now-valid value submits")
    }

    // ---- gating matrix --------------------------------------------------------
    function test_submitGatingMatrix() {
        var submit = child("aiFormSubmit")
        compare(submit.enabled, true)
        tests.canSubmit = false
        tests.hint = "Wait for the current answer to finish."
        compare(submit.enabled, false)
        compare(child("aiFormHint").visible, true)
        compare(child("aiFormHint").text, "Wait for the current answer to finish.")
        mouseClick(submit, 5, 5)
        keyClick(Qt.Key_Space)
        wait(30)
        compare(submitSpy.count, 0, "a closed gate never emits")
        tests.canSubmit = true
        tests.hint = ""
        compare(submit.enabled, true)
        compare(child("aiFormHint").visible, false)
        mouseClick(submit, submit.width / 2, submit.height / 2)
        tryCompare(submitSpy, "count", 1)
        // too many bytes for the broker: sending is blocked with a reason
        tests.setBlock({type: "form", title: "T".repeat(160), submitLabel: "Send", note: "", fields: [
            tests.field("a", "A", "text"), tests.field("b", "B", "text"), tests.field("c", "C", "text"),
            tests.field("d", "D", "text"), tests.field("e", "E", "text"), tests.field("f", "F", "text")]})
        var big = "\u4e2d".repeat(200)
        tests.saved = {v: {a: big, b: big, c: big, d: big, e: big, f: big}, sent: false}
        compare(form.hasIssues, false)
        compare(form.fits, false)
        compare(child("aiFormSubmit").enabled, false)
        verify(child("aiFormHint").text.indexOf("too long") >= 0)
        tests.saved = {v: {a: big, b: big}, sent: false}
        compare(form.fits, true)
        compare(child("aiFormSubmit").enabled, true)
    }

    // ---- sent / change answers ----------------------------------------------
    function test_sentFormShowsReadOnlyValuesAndChangeAnswers() {
        tests.saved = {v: {budget: 1800, style: 2, notes: "No hostels", flex: 1}, sent: true}
        compare(form.sent, true)
        compare(child("aiFormSubmit").visible, false)
        compare(child("aiFormSent").visible, true)
        compare(child("aiFormSent").text, "\u2713 Sent")
        compare(child("aiFormSentLine_0").text, "Budget: 1800 EUR")
        compare(child("aiFormSentLine_1").text, "Travel style: Packed")
        compare(child("aiFormSentLine_2").text, "Anything to avoid: No hostels")
        compare(child("aiFormSentLine_3").text, "Flexible dates: Yes")
        var editors = 0, items = tests.all()
        for (var i = 0; i < items.length; ++i) if (tests.isField(items[i]) && items[i].visible) ++editors
        compare(editors, 0, "no editor stays reachable while the values are read-only")
        compare(child("aiFormChange").visible, true)
        compare(child("aiFormChange").enabled, true)
        // Change answers clears `sent` only and keeps the values.
        tests.emitted = []
        var change = child("aiFormChange")
        wait(30)
        mouseMove(change, change.width / 2, change.height / 2)
        mouseClick(change, change.width / 2, change.height / 2)
        compare(tests.emitted.length, 1)
        // QML/QVariant boundaries may reorder object keys; compare the values,
        // not an incidental serialized property order.
        verify(TestJson.equal(tests.emitted[0], {v: {budget: 1800, style: 2, notes: "No hostels", flex: 1}, sent: false}),
            "Change answers preserves every value exactly: " + JSON.stringify(tests.emitted[0]))
        compare(form.sent, false)
        compare(child("aiFormInput_0").text, "1800")
        compare(child("aiFormChip_1_2").picked, true)
        compare(child("aiFormSubmit").visible, true)
        compare(child("aiFormSent").visible, false)
        tryCompare(child("aiFormInput_0"), "activeFocus", true)
        // Closed gate: Change answers is disabled and explains why.
        tests.saved = {v: {budget: 1800}, sent: true}
        tests.canSubmit = false
        compare(child("aiFormChange").enabled, false)
    }
    function test_sentAndFocusLandsOnTheSentMarker() {
        tests.autoSend = true
        var submit = child("aiFormSubmit")
        submit.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(submit, "activeFocus", true)
        keyClick(Qt.Key_Space)
        tryCompare(submitSpy, "count", 1)
        compare(form.sent, true)
        tryCompare(child("aiFormSent"), "activeFocus", true)
    }
    function test_aSendTheHostDidNotAcceptIsReportedNotSilent() {
        compare(child("aiFormHint").visible, false)
        var submit = child("aiFormSubmit")
        submit.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        tryCompare(submitSpy, "count", 1)
        tryCompare(child("aiFormHint"), "visible", true)
        compare(child("aiFormHint").text, "Couldn't send these answers. Try again in a moment.")
        compare(form.sent, false)
        // The next edit clears it.
        child("aiFormToggle_3").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(child("aiFormHint").visible, false)
    }
    function test_doubleActivationIsOneRequest() {
        tests.autoSend = true
        var submit = child("aiFormSubmit")
        submit.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        keyClick(Qt.Key_Space)
        wait(60)
        compare(submitSpy.count, 1, "two quick activations are one request")
    }

    // ---- restore rules ----------------------------------------------------------
    function test_restoreDropsUnknownAndOutOfRangeValues() {
        tests.saved = JSON.parse('{"v": {"budget": 99999, "style": 7, "notes": 5, "flex": 2, "ghost": 1, "__proto__": 3}, "sent": true}')
        compare(form.sent, false, "a sent mark does not survive dropped values")
        compare(form.dropped >= 5, true)
        compare(child("aiFormRestoreNote").visible, true)
        compare(child("aiFormRestoreNote").text, "Some saved values no longer match this form and were reset.")
        compare(child("aiFormInput_0").text, "1000", "out of range is reset to the default, never clamped")
        compare(child("aiFormChip_1_1").picked, true)
        compare(child("aiFormToggle_3").on, false)
        // Valid values restore, including a stored draft that was never sent.
        tests.saved = {v: {budget: 750, style: 0, notes: "Quiet", flex: 1}, sent: false}
        compare(form.dropped, 0)
        compare(child("aiFormRestoreNote").visible, false)
        compare(child("aiFormInput_0").text, "750")
        compare(child("aiFormChip_1_0").picked, true)
        compare(child("aiFormToggle_3").on, true)
    }
    function test_hostileEntriesNeverThrow() {
        var hostile = [null, 7, "x", [1, 2], {v: null}, {v: [1]}, {v: "x"}, {v: {budget: "12"}}, {v: {budget: NaN}},
            {v: {budget: Infinity}}, {v: {budget: {}}}, {v: {notes: {a: 1}}}, {sent: "yes"}, {sent: 1}, {v: {}, sent: 1}]
        for (var i = 0; i < hostile.length; ++i) {
            tests.saved = hostile[i]
            compare(form.usable, true, JSON.stringify(hostile[i]))
            compare(form.sent, false)
            compare(child("aiFormInput_0").text, "1000")
        }
        var big = {}
        for (var k = 0; k < 200; ++k) big["k" + k] = k
        tests.saved = {v: big}
        compare(form.usable, true)
    }
    function test_hostileBlocksDegradeToOneLine() {
        var blocks = [null, 5, "x", [], {type: "form"}, {type: "form", fields: "x"}, {type: "form", fields: []},
            {type: "form", fields: [null, 3, "x", {}, {id: "A", label: "x", kind: "text"}]},
            {type: "form", fields: [{id: "a", label: "", kind: "text"}]},
            {type: "form", fields: [{id: "a", label: "x", kind: "number", min: 5, max: 1}]},
            {type: "form", fields: [{id: "a", label: "x", kind: "choice", options: ["only"]}]},
            {type: "form", fields: [{id: "a", label: "x", kind: "choice", options: ["same", "same"]}]},
            {type: "form", fields: [{id: "a", label: "x", kind: "slider"}]}]
        for (var i = 0; i < blocks.length; ++i) {
            tests.block = blocks[i]
            wait(0)
            compare(form.usable, false, JSON.stringify(blocks[i]))
            compare(child("aiFormInvalid").visible, true)
            compare(child("aiFormInvalid").text, "This form can't be shown.")
            compare(child("aiFormSubmit").visible && child("aiFormSubmit").enabled, false)
            compare(form.delegateCount, 0)
        }
    }
    function test_extraFieldsAndDuplicateIdsAreBounded() {
        var fields = []
        for (var i = 0; i < 9; ++i) fields.push(tests.field("f" + (i % 7), "Field " + i, "text"))
        tests.setBlock({type: "form", title: "Many", submitLabel: "Go", note: "", fields: fields})
        // 7 distinct ids, 6 kept (first six); the duplicates (f0, f1 repeats) are skipped.
        compare(form.delegateCount, 6)
        var inputs = 0, items = tests.all()
        for (var j = 0; j < items.length; ++j) if (tests.isField(items[j])) ++inputs
        compare(inputs, 6, "one editor per field, never more")
        // Prototype-named ids are ordinary ids.
        tests.setBlock({type: "form", title: "P", submitLabel: "Go", note: "", fields: [
            tests.field("constructor", "C", "toggle"), tests.field("valueof", "V", "text")]})
        compare(form.delegateCount, 2)
        mouseClick(child("aiFormToggle_0"), 5, 5)
        compare(tests.lastV().constructor, 1)
        compare(form.hasIssues, false)
    }

    // ---- model text is plain, readable and bounded ---------------------------
    function test_modelTextIsPlainEverywhere() {
        tests.setBlock({type: "form", title: "<b>x</b>", submitLabel: "<i>Go</i>", note: "<u>note</u> &amp;", fields: [
            tests.field("a", "<script>alert(1)</script>", "text", {placeholder: "<b>p</b>"}),
            tests.field("b", "<h1>Pick</h1>", "choice", {options: ["<b>one</b>", "&lt;two&gt;"]}),
            tests.field("c", "<a href=x>Toggle</a>", "toggle")]})
        compare(child("aiFormLabel_0").text, "<script>alert(1)</script>")
        compare(child("aiFormBlockNote").text, "<u>note</u> &amp;")
        compare(child("aiFormSubmit").text, "<i>Go</i>")
        var items = tests.all(), texts = 0
        for (var i = 0; i < items.length; ++i) {
            if (!tests.isText(items[i]) || items[i].text === "") continue   // TextField's own empty placeholder
            ++texts
            compare(items[i].textFormat, Text.PlainText, "every Text is PlainText: " + items[i].text)
        }
        verify(texts > 8)
    }
    function test_informationalTextMeetsTheContrastFloor() {
        // Idle and disabled states, messages, hints and placeholders.
        tests.saved = undefined
        tests.canSubmit = false
        tests.hint = "Only the latest answer's form can be sent."
        tests.enterText(child("aiFormInput_0"), "zz")
        var bg = Qt.color("#1b1c20"), items = tests.all(), seen = 0
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (tests.isText(it) && it.visible && it.text.length > 0) {
                ++seen
                verify(it.color.a >= 0.76 - 1e-9, "alpha floor " + it.color.a + " for " + it.text)
                verify(tests.ratio(it.color, bg) >= 4.5, "contrast " + tests.ratio(it.color, bg) + " for " + it.text)
            }
            if (tests.isField(it)) verify(it.placeholderTextColor.a >= 0.76 - 1e-9, "placeholder alpha")
        }
        verify(seen >= 8, "the matrix saw the form's text: " + seen)
        tests.saved = {v: {}, sent: true}
        for (i = 0, items = tests.all(); i < items.length; ++i) {
            it = items[i]
            if (tests.isText(it) && it.visible && it.text.length > 0)
                verify(it.color.a >= 0.76 - 1e-9 && tests.ratio(it.color, bg) >= 4.5, "sent state: " + it.text)
        }
    }
    function test_focusRingsAreTwoPixelAccent() {
        var input = child("aiFormInput_0")
        input.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(input, "activeFocus", true)
        compare(input.background.border.width, 2)
        compare(input.background.border.color, form.accent)
        input.focus = false
        var submit = child("aiFormSubmit")
        submit.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(submit, "activeFocus", true)
        compare(submit.background.border.width, 2)
        compare(submit.background.border.color, form.accent)
        var toggle = child("aiFormToggle_3")
        toggle.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(toggle, "activeFocus", true)
        compare(toggle.background.border.width, 2)
        compare(toggle.background.border.color, form.accent)
    }
    function test_escapeIsNotConsumed() {
        var targets = [child("aiFormInput_0"), child("aiFormChoice_1"), child("aiFormInput_2"),
            child("aiFormToggle_3"), child("aiFormSubmit")]
        for (var i = 0; i < targets.length; ++i) {
            targets[i].forceActiveFocus(Qt.TabFocusReason)
            tryCompare(targets[i], "activeFocus", true)
            var before = tests.escapes
            keyClick(Qt.Key_Escape)
            compare(tests.escapes, before + 1, "Escape reaches the host from field " + i)
        }
    }
    function test_accessibleNamesAndRoles() {
        compare(child("aiFormInput_0").Accessible.name, "Budget (EUR)")
        compare(child("aiFormInput_0").Accessible.description, "Allowed: 100 to 5000 EUR")
        compare(child("aiFormInput_2").Accessible.name, "Anything to avoid")
        var group = child("aiFormChoice_1")
        compare(group.Accessible.name, "Travel style: Balanced")
        compare(group.Accessible.role, Accessible.RadioButton)
        compare(child("aiFormChip_1_1").Accessible.checked, true)
        compare(child("aiFormChip_1_1").Accessible.role, Accessible.RadioButton)
        compare(child("aiFormSubmit").Accessible.name, "Send answers")
        tests.enterText(child("aiFormInput_0"), "x")
        verify(child("aiFormInput_0").Accessible.description.indexOf("Not a plain number") >= 0)
        compare(child("aiFormMessage_0").Accessible.role, Accessible.AlertMessage)
    }

    // ---- host refusal and delegates ---------------------------------------------
    function test_refusedEditNeverShowsAsStored() {
        tests.refuse = true
        mouseClick(child("aiFormChip_1_2"), 5, 5)
        compare(tests.emitted.length, 1)
        compare(child("aiFormChip_1_1").picked, true, "the selection follows the stored state")
        compare(child("aiFormChip_1_2").picked, false)
        mouseClick(child("aiFormToggle_3"), 5, 5)
        compare(child("aiFormToggle_3").on, false)
        tests.refuse = false
        mouseClick(child("aiFormToggle_3"), 5, 5)
        compare(child("aiFormToggle_3").on, true)
    }
    function test_valueEditsNeverRebuildTheFieldDelegates() {
        var row = child("aiFormField_0")
        var input = child("aiFormInput_0")
        tests.enterText(input, "1234")
        verify(child("aiFormField_0") === row, "the delegate survives value edits")
        verify(child("aiFormInput_0") === input)
        verify(input.activeFocus, "focus is never dropped by an edit")
        compare(input.text, "1234")
    }
    function test_replacingTheBlockWithEqualContentKeepsEditingLive() {
        var input = child("aiFormInput_0")
        tests.enterText(input, "99999")
        compare(child("aiFormSubmit").enabled, false)
        // The same form arrives again as a new object (a re-wrapped turn payload).
        tests.block = tests.makeBlock()
        wait(30)
        verify(child("aiFormInput_0") === input, "equal content keeps the delegates")
        compare(input.text, "99999", "typed text is kept")
        compare(child("aiFormSubmit").enabled, false, "and so is its invalid state")
        child("aiFormInput_2").forceActiveFocus(Qt.TabFocusReason)
        compare(tests.lastV().budget, 5000, "leaving the field still commits and clamps")
        compare(input.text, "5000")
    }
    function test_aLateBlurFromAReplacedBlockNeverWrites() {
        var input = child("aiFormInput_0")
        tests.enterText(input, "99999")
        compare(tests.emitted.length > 0 ? tests.lastV().budget <= 5000 : true, true)
        var count = tests.emitted.length
        // A different form (the budget field is gone) replaces it while the field has focus.
        tests.block = {type: "form", title: "Other", submitLabel: "Go", note: "", fields: [
            tests.field("only", "Only", "toggle")]}
        wait(30)
        before.forceActiveFocus()
        wait(30)
        compare(tests.emitted.length, count, "nothing is written for the replaced field")
        compare(form.delegateCount, 1)
        compare(form.hasIssues, false, "a stale entry never blocks the new form")
        compare(child("aiFormSubmit").enabled, true)
    }

    function test_widthsFourTwentyAndSevenSixty() {
        var long80 = "W".repeat(80), fields = []
        for (var i = 0; i < 6; ++i) {
            var kind = ["number", "choice", "text", "toggle", "choice", "number"][i]
            fields.push(tests.field("f" + i, long80, kind, kind === "number" ? {min: 0, max: 999999999, step: 1, value: 123456789, unit: "UNITUNITUNITUNIT"}
                : kind === "choice" ? {options: ["O".repeat(48), "P".repeat(48), "Q".repeat(48), "R".repeat(48), "S".repeat(48), "T".repeat(48)], value: 2} : {placeholder: "p".repeat(60)}))
        }
        tests.setBlock({type: "form", title: "Wide", submitLabel: "S".repeat(32), note: "N".repeat(240), fields: fields})
        compare(form.delegateCount, 6)
        var widths = [420, 760]
        for (var w = 0; w < widths.length; ++w) {
            form.width = widths[w]
            wait(0)
            var items = tests.all()
            for (var j = 0; j < items.length; ++j) {
                var it = items[j]
                if (!it.visible || it === form || typeof it.width !== "number" || it.width <= 0) continue
                var p = it.mapToItem(form, 0, 0)
                verify(p.x + it.width <= form.width + 1.5, "width " + widths[w] + ": " + (it.objectName || it) + " ends at " + (p.x + it.width))
                verify(p.x >= -0.5)
            }
            verify(form.implicitHeight > 0 && form.height > 0)
        }
        // The chip group's items stay bounded: 6 fields, at most 2 choices x 6 chips.
        var chips = 0
        items = tests.all()
        for (var c = 0; c < items.length; ++c) if ((items[c].objectName || "").indexOf("aiFormChip_") === 0) ++chips
        compare(chips, 12)
    }
}
