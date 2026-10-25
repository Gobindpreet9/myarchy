import QtQuick
import QtTest
import ".." as Launcher

// The block seams for the dynamic vocabulary (actions / compare / timeline):
// the stub components must show the block's real content and nothing
// interactive, and the signals must reach the host with ORIGINAL block indexes.
TestCase {
    id: tests
    name: "AiSeams"
    width: 760
    height: 700
    visible: true
    when: windowShown

    property var actionsBlock: ({type: "actions", title: "Next steps", options: [
        {label: "Book the trip", hint: "Opens the checklist"}, {label: "Compare hotels", hint: ""},
        {label: "Skip this", hint: "Nothing changes"}]})
    property var compareBlock: ({type: "compare", title: "Two laptops", options: [
        {name: "Aero 14", summary: "Light and quiet", facts: [{label: "Weight", value: "1.2 kg"}, {label: "Price", value: 999}],
         pros: ["Battery lasts"], cons: ["One port"], recommended: true},
        {name: "Forge 16", summary: "Fast", facts: [], pros: [], cons: ["Heavy"], recommended: false}],
        verdict: "Aero 14 suits travel."})
    property var timelineBlock: ({type: "timeline", title: "Saturday", items: [
        {label: "Pack bags", when: "08:00", minutes: 30, detail: "Passports first"},
        {label: "Leave", when: "09:00", minutes: 0, detail: ""}]})

    Flickable {
        id: viewport
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: renderer.implicitHeight
        Launcher.AiBlocks {
            id: renderer
            width: viewport.width
            foreground: "#eeeeee"
            background: "#222222"
            accent: "#88bbff"
            blocks: []
        }
    }
    SignalSpy { id: choiceSpy; target: renderer; signalName: "choiceRequested" }
    SignalSpy { id: focusSpy; target: renderer; signalName: "focusRequested" }
    SignalSpy { id: stateSpy; target: renderer; signalName: "uiStateEdited" }

    Launcher.AiAnswer {
        id: answer
        width: 700
        visible: false
        turn: null
        title: "Seams"
        foreground: "#eeeeee"
        background: "#222222"
        accent: "#88bbff"
    }
    SignalSpy { id: answerChoiceSpy; target: answer; signalName: "choiceRequested" }
    SignalSpy { id: answerFocusSpy; target: answer; signalName: "focusRequested" }
    SignalSpy { id: answerStateSpy; target: answer; signalName: "uiStateEdited" }

    function init() {
        tests.width = 760
        renderer.uiState = null
        renderer.blockIndices = []
        renderer.choiceCanSubmit = false
        renderer.choiceHint = ""
        renderer.blocks = [actionsBlock, compareBlock, timelineBlock]
        choiceSpy.clear(); focusSpy.clear(); stateSpy.clear()
        answerChoiceSpy.clear(); answerFocusSpy.clear(); answerStateSpy.clear()
        wait(30)
    }

    function args(spy, index) { return Array.prototype.slice.call(spy.signalArguments[index]) }

    // Every Item below `item` (the stub must contribute no Tab stop).
    function tabStops(item) {
        var found = []
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            if (child.activeFocusOnTab === true) found.push(child)
            found = found.concat(tabStops(child))
        }
        return found
    }

    // Every `text` string below `item`, so a test can read what a renderer shows.
    function textsOf(item) {
        var found = []
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            if (typeof child.text === "string" && child.text.length) found.push(child.text)
            found = found.concat(textsOf(child))
        }
        return found
    }

    function test_everyNewBlockRendersItsRealContent() {
        var actions = findChild(renderer, "aiActions")
        var cards = findChild(renderer, "aiCompare")
        var timeline = findChild(renderer, "aiTimeline")
        verify(actions !== null && cards !== null && timeline !== null, "no new block may disappear")
        var a = textsOf(actions).join("\n"), c = textsOf(cards).join("\n"), t = textsOf(timeline).join("\n")
        verify(a.indexOf("Book the trip") >= 0 && a.indexOf("Skip this") >= 0, "actions show their labels")
        verify(c.indexOf("Aero 14") >= 0 && c.indexOf("Forge 16") >= 0, "compare shows its options")
        verify(c.indexOf("1.2 kg") >= 0 && c.indexOf("Aero 14 suits travel.") >= 0, "compare shows facts and verdict")
        verify(t.indexOf("Pack bags") >= 0 && t.indexOf("08:00") >= 0, "timeline shows its items")
        verify(actions.implicitHeight > 0 && cards.implicitHeight > 0 && timeline.implicitHeight > 0)
    }

    function test_newBlocksFitTwoWidthsAndWrap() {
        var wide = renderer.implicitHeight
        verify(wide > 0)
        tests.width = 240
        renderer.width = 240
        wait(60)
        verify(renderer.implicitHeight > wide, "narrow content wraps taller")
        var names = ["aiActions", "aiCompare", "aiTimeline"]
        for (var i = 0; i < names.length; ++i) {
            var item = findChild(renderer, names[i])
            verify(item.width <= 240 && item.width > 0, names[i] + " fits the width")
            verify(item.implicitHeight > 0)
        }
        renderer.width = Qt.binding(function() { return viewport.width })
    }

    function allNamed(item, name) {
        var found = []
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            if (child.objectName === name) found.push(child)
            found = found.concat(allNamed(child, name))
        }
        return found
    }

    function test_hostileBlocksNeverBreakTheRenderers() {
        var huge = "x".repeat(5000)
        var options = []
        for (var i = 0; i < 40; ++i) options.push({label: "Option " + i + " " + huge, hint: huge})
        renderer.blocks = [
            {type: "actions", title: null, options: "nope"},
            {type: "compare", options: [null, 7, {name: {x: 1}, facts: "z", pros: [1, {}], cons: null}], verdict: 5},
            {type: "timeline", items: [{label: "A\u0007B\u202e", when: huge, minutes: -4}, "str", null]},
            {type: "actions", options: options},
            {type: "timeline"}]
        wait(60)
        // Five blocks, five renderers: nothing disappears and nothing throws.
        compare(allNamed(renderer, "aiActions").length, 2)
        compare(allNamed(renderer, "aiCompare").length, 1)
        compare(allNamed(renderer, "aiTimeline").length, 2)
        var shown = textsOf(allNamed(renderer, "aiTimeline")[0]).join("\n")
        compare(shown.indexOf("\u0007"), -1)
        compare(shown.indexOf("\u202e"), -1)
        var bounded = allNamed(renderer, "aiActions")[1]
        verify(bounded.height < 3000, "a huge actions block stays bounded, got " + bounded.height)
        verify(bounded.width <= renderer.width)
    }

    function test_choicesFocusAndStateRideOriginalBlockIndexes() {
        renderer.blockIndices = [4, 2, 5]
        renderer.choiceCanSubmit = true
        wait(30)
        var actions = findChild(renderer, "aiActions")
        var cards = findChild(renderer, "aiCompare")
        var timeline = findChild(renderer, "aiTimeline")
        verify(actions.canChoose && cards.canChoose)
        actions.choiceRequested(2)
        cards.choiceRequested(0)
        compare(choiceSpy.count, 2)
        compare(args(choiceSpy, 0), [4, "actions", 2])
        compare(args(choiceSpy, 1), [2, "compare", 0])
        actions.focusRequested(1, "Compare hotels", "A hint")
        timeline.focusRequested(-1, "Saturday", "")
        compare(focusSpy.count, 2)
        compare(args(focusSpy, 0), [4, "actions", 1, "Compare hotels", "A hint"])
        compare(args(focusSpy, 1), [5, "timeline", -1, "Saturday", ""])
        cards.stateEdited({open: [0]})
        timeline.stateEdited({done: [1]})
        compare(stateSpy.count, 2)
        compare(args(stateSpy, 0).slice(0, 2), [2, "compare:2"])
        compare(JSON.stringify(args(stateSpy, 0)[2]), JSON.stringify({open: [0]}))
        compare(args(stateSpy, 1).slice(0, 2), [5, "plan:5"])
    }

    function test_gateAndPersistedStateReachTheComponents() {
        renderer.blockIndices = [3, 0, 1]
        renderer.choiceCanSubmit = false
        renderer.choiceHint = "Wait for the current answer to finish."
        renderer.uiState = {"act:3": {picked: 1}, "act:0": {picked: 1.5}, "compare:0": {open: [1]}, "plan:1": {done: [0]}}
        wait(30)
        var actions = findChild(renderer, "aiActions")
        var cards = findChild(renderer, "aiCompare")
        var timeline = findChild(renderer, "aiTimeline")
        compare(actions.picked, 1)
        compare(actions.canChoose, false)
        compare(actions.chooseHint, "Wait for the current answer to finish.")
        compare(cards.picked, -1, "a fractional pick is not an index")
        compare(cards.saved.open[0], 1)
        compare(timeline.saved.done[0], 0)
        renderer.uiState = {"act:3": {picked: "1"}, "act:0": {picked: -2}, "act:1": null}
        wait(30)
        compare(findChild(renderer, "aiActions").picked, -1)
        compare(findChild(renderer, "aiCompare").picked, -1)
    }

    function test_answerForwardsTheSeamsWithRemappedIndexes() {
        // The hero image is lifted out and sources go last: the actions block is
        // original index 2 although it is the first body block.
        answer.turn = {id: 9, prompt: "Plan", answer: "Here", status: "done", blocks: [
            {type: "sources", items: [{label: "Ref", url: "https://example.com/r"}]},
            {type: "image", query: "Illustrative figure", imageUrl: "file:///tmp/opencode/none.png"},
            actionsBlock, timelineBlock]}
        answer.choiceCanSubmit = true
        answer.choiceHint = ""
        wait(60)
        var actions = findChild(answer, "aiActions")
        var timeline = findChild(answer, "aiTimeline")
        verify(actions !== null && timeline !== null)
        verify(actions.canChoose, "the gate reaches the component")
        actions.choiceRequested(0)
        compare(answerChoiceSpy.count, 1)
        compare(args(answerChoiceSpy, 0), [2, "actions", 0])
        timeline.focusRequested(1, "Leave", "")
        compare(args(answerFocusSpy, 0), [3, "timeline", 1, "Leave", ""])
        timeline.stateEdited({done: [0]})
        compare(args(answerStateSpy, 0).slice(0, 2), [3, "plan:3"])
        // Existing seams are untouched: the form gate still travels separately.
        answer.formHint = "Only the latest answer's form can be sent."
        compare(answer.formCanSubmit, false)
        answer.turn = null
    }

    function test_theTextExportListsTheNewBlocks() {
        answer.turn = {id: 10, prompt: "Plan", answer: "Intro", status: "done",
            blocks: [actionsBlock, compareBlock, timelineBlock]}
        answer.showText = true
        wait(30)
        var summary = findChild(answer, "aiAnswerSummary")
        verify(summary.text.indexOf("Next steps\n\n\u00b7 Book the trip \u2014 Opens the checklist") >= 0)
        verify(summary.text.indexOf("Aero 14 (recommended) \u2014 Light and quiet\nWeight: 1.2 kg") >= 0)
        verify(summary.text.indexOf("08:00 - Pack bags (30 min)\n09:00 - Leave") >= 0)
        answer.showText = false
        answer.turn = null
    }
}
