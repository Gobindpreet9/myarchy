import QtQuick
import QtTest
import ".."
import "../AiLayout.js" as Layout
import "../AiState.js" as AiState
import "TestJson.js" as TestJson

TestCase {
    id: tests
    name: "AiComposition"
    width: 980
    height: 1200
    visible: true
    when: windowShown

    AiAnswer {
        id: answer
        width: tests.width
        turn: null
        title: "The original question"
        foreground: "#ece9e2"
        background: "#191b1e"
        accent: "#d7b47b"
        formCanSubmit: true
        choiceCanSubmit: true
        canFocus: true
    }
    SignalSpy { id: edits; target: answer; signalName: "uiStateEdited" }
    SignalSpy { id: checks; target: answer; signalName: "checkChanged" }
    SignalSpy { id: choices; target: answer; signalName: "choiceRequested" }
    SignalSpy { id: forms; target: answer; signalName: "formSubmitRequested" }

    function comparison() {
        return {type: "compare", title: "Pick your travel laptop", verdict: "Illustrative options.", options: [
            {name: "Aero", summary: "Light", recommended: true, facts: [{label: "Weight", value: "1.2 kg"}], pros: ["Portable"], cons: []},
            {name: "Studio", summary: "Roomy", recommended: false, facts: [{label: "Weight", value: "2 kg"}], pros: [], cons: ["Heavy"]}]}
    }
    function form() {
        return {type: "form", title: "Shape your weekend", note: "Illustrative trip planner.", submitLabel: "Build my plan", fields: [
            {id: "party", label: "People", kind: "number", unit: "", min: 1, max: 10, step: 1, value: 2, placeholder: "", options: []}]}
    }
    function learning() {
        return [
            {type: "text", title: "What to notice", text: "Move the control to change the diagram."},
            {type: "slider", title: "Try a position", control: {label: "Position", min: 0, max: 100, value: 20, step: 1, unit: "", labels: []},
                readouts: [{label: "Position", expression: "x", unit: ""}], note: "Illustrative schematic.", links: [{part: 0, property: "x", expression: "x"}]},
            {type: "diagram", title: "Explore the motion", aspect: 1.6, caption: "Illustrative, not to scale.", parts: [
                {shape: "circle", x: 20, y: 30, w: 12, h: 12, label: "Object", detail: "Position responds to the control.", tone: "accent", fill: true, rotation: 0}]},
            {type: "sources", items: [{label: "Fixture", url: "https://example.com/fixture"}]}]
    }
    function setTurn(blocks, text) {
        answer.turn = {id: 7, prompt: "Original question", answer: text || "A short orientation.", status: "done", blocks: blocks, suggestions: []}
        wait(30)
    }
    function init() {
        tests.width = 980
        answer.turn = null
        answer.uiState = null
        answer.checkedState = ({})
        answer.showText = false
        answer.failed = false
        answer.explanationExpanded = false
        edits.clear(); checks.clear(); choices.clear(); forms.clear()
    }
    function test_compositionPreservesOriginalIndicesAndSourcesLast() {
        var blocks = [{type: "text"}, {type: "sources"}, {type: "checklist"}, comparison()]
        var before = JSON.stringify(blocks)
        var plan = Layout.answerComposition(blocks)
        verify(TestJson.equal(plan, {blocks: blocks, kind: "compare", title: "Pick your travel laptop", primary: [3], controls: [], support: [0, 2], sources: [1]}))
        compare(JSON.stringify(blocks), before)
        compare(Layout.blocksAt(blocks, plan.primary)[0], blocks[3])
    }
    function test_plainAndImageAnswersKeepTheirExistingComposition() {
        for (var blocks of [[], [{type: "text"}], [{type: "image"}, {type: "checklist"}], [null]])
            compare(Layout.answerComposition(blocks).kind, "")
        setTurn([{type: "text", text: "Plain body"}])
        compare(answer.taskMode, false)
        verify(findChild(answer, "aiNativeBlocks_0").visible)
        compare(findChild(answer, "aiTaskSurface"), null)
    }
    function test_oversizedLegacyAnswersNeverLoseTheirTail() {
        var blocks = [comparison()]
        for (var i = 0; i < 64; ++i) blocks.push({type: "text", text: "Detail " + i})
        var composition = Layout.answerComposition(blocks)
        compare(composition.kind, "", "Use the existing view instead of silently omitting blocks")
        compare(composition.blocks, blocks)
        compare(composition.blocks.length, 65)
    }
    function test_taskFamilies_data() {
        return ["calc", "compare", "form", "timeline", "diagram", "gallery", "chart", "market", "steps", "check", "predict", "table", "actions"]
            .map(function(kind) { return {tag: kind, kind: kind}; })
    }
    function test_taskFamilies(data) {
        var plan = Layout.answerComposition([{type: "text"}, {type: data.kind, title: "Purposeful title"}])
        compare(plan.kind, data.kind)
        verify(TestJson.equal(plan.primary, [1]))
        verify(TestJson.equal(plan.support, [0]))
    }
    function test_actualTaskPrecedesSupportingTextAtEverySize() {
        setTurn([{type: "text", title: "Details", text: "The explanation used to come first."}, comparison(),
            {type: "checklist", title: "Check these", items: ["Review the ports"]}])
        for (var w of [420, 760, 980]) {
            tests.width = w
            wait(20)
            var primary = findChild(answer, "aiTaskPrimary"), context = findChild(answer, "aiTaskContext")
            verify(primary.mapToItem(answer, 0, 0).y < context.mapToItem(answer, 0, 0).y)
            verify(findChild(answer, "aiTaskSurfaceLoader").y < 220, "The main object starts in the first viewport at " + w)
            compare(findChild(answer, "aiAnswerTitle").text, "Pick your travel laptop")
            compare(answer.title, "The original question", "Do not rename the stored answer/workspace")
            verify(primary.width > 0 && primary.width <= answer.width)
        }
    }
    function test_longProseHasAnExplicitLosslessDisclosure() {
        var prose = "Illustrative context remains available in full. ".repeat(18)
        setTurn([comparison()], prose)
        var summary = findChild(answer, "aiAnswerSummary"), more = findChild(answer, "aiAnswerReadMore")
        verify(more.visible)
        verify(summary.text.length < 260 && summary.text.endsWith("\u2026"))
        compare(answer.summary, prose)
        more.clicked()
        compare(summary.text, prose)
        summary.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_A, Qt.ControlModifier)
        compare(summary.selectedText, prose)
        more.clicked()
        verify(summary.text.length < 260)
        compare(answer.turn.answer, prose)
        compare(edits.count + choices.count + forms.count, 0)
    }
    function test_disclosureResetsForANewTurnNotAResize() {
        setTurn([comparison()], "Long explanation. ".repeat(30))
        answer.explanationExpanded = true
        tests.width = 420
        compare(answer.explanationExpanded, true)
        answer.turn = Object.assign({}, answer.turn, {id: 8})
        compare(answer.explanationExpanded, false)
    }
    function test_textViewAndResizeKeepTheActualToolInstance() {
        setTurn([comparison()])
        var tool = findChild(answer, "aiCompare")
        tool.cursor = 1
        tests.width = 420
        wait(20)
        compare(findChild(answer, "aiCompare"), tool)
        answer.showText = true
        verify(!findChild(answer, "aiTaskSurfaceLoader").visible)
        compare(findChild(answer, "aiAnswerSummary").text, AiState.textAnswer(answer.turn, answer.uiState))
        answer.showText = false
        compare(findChild(answer, "aiCompare"), tool)
        compare(tool.cursor, 1)
        compare(choices.count + edits.count, 0)
    }
    function test_stateAndFollowUpSignalsKeepAuthoredIndices() {
        setTurn([{type: "checklist", title: "Checklist", items: ["Review"]}, comparison()])
        var box = findChild(answer, "aiCheck_0_0")
        verify(box !== null)
        box.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(checks.count, 1)
        compare(checks.signalArguments[0][0], 0)
        var tool = findChild(answer, "aiCompare")
        tool.choiceRequested(1)
        compare(choices.count, 1)
        var sent = choices.signalArguments[0]
        verify(sent[0] === 1 && sent[1] === "compare" && sent[2] === 1)
    }
    function test_diagramAndSliderStayCoupledAcrossColumns() {
        answer.uiState = {"slider:1": 65}
        setTurn(learning())
        var surface = findChild(answer, "aiTaskSurface"), diagram = findChild(answer, "aiDiagram")
        var primary = findChild(answer, "aiTaskPrimary"), controls = findChild(answer, "aiTaskControls")
        compare(surface.splitControls, true)
        verify(controls.x > primary.x + primary.width)
        compare(diagram.sceneParts[0].x, 65)
        answer.uiState = {"slider:1": 35}
        compare(diagram.sceneParts[0].x, 35)
        tests.width = 420
        wait(20)
        compare(surface.splitControls, false)
        verify(controls.y > primary.y + primary.height)
        compare(findChild(answer, "aiDiagram"), diagram)
        compare(diagram.sceneParts[0].x, 35)
        compare(edits.count, 0, "Reflow and restoration must never write state")
    }
    function test_formUsesSideContextOnlyWhenItFits() {
        setTurn([form(), {type: "text", title: "Before you start", text: "Illustrative advice."}])
        var surface = findChild(answer, "aiTaskSurface"), formItem = findChild(answer, "aiForm")
        compare(surface.sideContext, true)
        verify(findChild(answer, "aiTaskContext").x > 0)
        tests.width = 420
        wait(20)
        compare(surface.sideContext, false)
        compare(findChild(answer, "aiForm"), formItem)
        compare(findChild(answer, "aiTaskContext").x, 0)
        compare(edits.count + forms.count, 0)
    }
    function test_excerptNeverSplitsAnEmoji() {
        var excerpt = Layout.orientationExcerpt("a".repeat(239) + "\ud83d\ude80 more", 240)
        verify(!/[\ud800-\udbff]\u2026$/.test(excerpt))
        compare(Layout.orientationExcerpt("Short", 240), "Short")
    }
    function test_replacingTaskShapesNeverExposesStaleBlockIndices() {
        failOnWarning(/TypeError:|ReferenceError:|Binding loop/)
        var shapes = [learning(), [form(), {type: "text", title: "Help", text: "A short note."}],
            [{type: "text", title: "Context", text: "Illustrative."}, comparison(),
                {type: "checklist", title: "Check", items: ["Review"]}]]
        for (var pass = 0; pass < 3; ++pass) {
            for (var i = 0; i < shapes.length; ++i) {
                setTurn(shapes[i])
                verify(findChild(answer, "aiTaskSurface").height > 0)
            }
        }
        compare(edits.count + checks.count + choices.count + forms.count, 0)
    }
}
