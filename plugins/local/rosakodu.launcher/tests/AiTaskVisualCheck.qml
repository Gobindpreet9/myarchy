import QtQuick
import QtTest
import ".." as Launcher

// Offline visual fixtures, NOT real products, opening hours or provider output.
// Run explicitly like AiAnswerCheck. PNGs are saved under /tmp/opencode.
TestCase {
    id: tests
    name: "AiTaskVisual"
    width: 980
    height: 1800
    visible: true
    when: windowShown
    property color ink: "#ece9e2"
    property color paper: "#191b1e"
    property color tone: "#d7b47b"
    property var current: null
    Rectangle {
        id: surface
        width: tests.width
        height: answer.height + 48
        color: tests.paper
        Launcher.AiAnswer {
            id: answer
            x: 24; y: 24
            width: surface.width - 48
            turn: tests.current
            title: tests.current ? tests.current.prompt : ""
            foreground: tests.ink
            background: tests.paper
            accent: tests.tone
            formCanSubmit: true
            choiceCanSubmit: true
            canFocus: true
        }
    }
    SignalSpy { id: sends; target: answer; signalName: "choiceRequested" }
    SignalSpy { id: edits; target: answer; signalName: "uiStateEdited" }
    function decision() {
        return {id: 1, status: "done", prompt: "Compare laptops for coding and train travel",
            answer: "Start with portability, then check your project's memory needs. These configurations are illustrative, not live product listings.",
            blocks: [{type: "text", title: "What matters", text: "A lighter bag helps every journey. Extra memory matters when your project actually needs it."},
                {type: "compare", title: "Pick your travel laptop", verdict: "Illustrative recommendation: start with the lighter configuration unless you need more memory.", options: [
                    {name: "Aero 14", summary: "Lightweight everyday coding", recommended: true,
                        facts: [{label: "Carry weight", value: "1.2 kg"}, {label: "Memory", value: "16 GB"}],
                        pros: ["Easy to carry", "Compact footprint"], cons: ["Less space for larger projects"]},
                    {name: "Studio 16", summary: "More room for demanding work", recommended: false,
                        facts: [{label: "Carry weight", value: "2.1 kg"}, {label: "Memory", value: "32 GB"}],
                        pros: ["More workspace"], cons: ["A heavier bag"]},
                    {name: "Compact 13", summary: "Keep the bag small", recommended: false,
                        facts: [{label: "Carry weight", value: "1.1 kg"}, {label: "Memory", value: "16 GB"}],
                        pros: ["Small footprint"], cons: ["Less screen space"]}]},
                {type: "checklist", title: "Before you decide", items: ["Check actual model specifications", "Try the keyboard", "Confirm the ports you use"]}], suggestions: []}
    }
    function plan() {
        return {id: 2, status: "done", prompt: "A relaxed Saturday outside",
            answer: "An illustrative plan with room to pause, not verified opening hours or transport information.", blocks: [
                {type: "timeline", title: "A slower Saturday", items: [
                    {label: "Coffee and a light breakfast", when: "09:00", minutes: 45, detail: "Start somewhere close and unhurried."},
                    {label: "Walk along the river", when: "10:00", minutes: 90, detail: "Choose an easy path; turn back when you feel like it."},
                    {label: "A long lunch", when: "12:00", minutes: 60, detail: "Leave time to linger."},
                    {label: "Choose your afternoon", when: "After lunch", minutes: 0, detail: "A book, a gallery, or simply heading home."}]},
                {type: "checklist", title: "Bring along", items: ["Water", "Comfortable shoes", "A light layer"]}], suggestions: []}
    }
    function planningForm() {
        return {id: 3, status: "done", prompt: "Build a weekend trip",
            answer: "A few details will make the plan useful. Your answers are sent only when you choose Build my plan.", blocks: [
                {type: "form", title: "Make the weekend yours", submitLabel: "Build my plan", note: "Illustrative planning form.", fields: [
                    {id: "people", label: "Who's coming?", kind: "number", unit: "people", min: 1, max: 12, step: 1, value: 2, placeholder: "", options: []},
                    {id: "budget", label: "Your total budget", kind: "number", unit: "EUR", min: 50, max: 5000, step: 50, value: 400, placeholder: "", options: []},
                    {id: "pace", label: "What pace feels right?", kind: "choice", unit: "", min: 0, max: 0, step: 1, value: 0, placeholder: "", options: ["Unhurried", "A little of both", "Pack it in"]}]},
                {type: "text", title: "Keep it flexible", text: "Start with the things that matter most. Suggestions are not confirmed bookings."},
                {type: "checklist", title: "Worth thinking about", items: ["Travel time", "Food preferences", "Accessibility needs"]}], suggestions: []}
    }
    function init() {
        failOnWarning(/TypeError:|ReferenceError:|Binding loop/)
        tests.ink = "#ece9e2"; tests.paper = "#191b1e"; tests.tone = "#d7b47b"
        answer.uiState = null
        sends.clear(); edits.clear()
    }
    function capture(name) {
        var saved = false
        verify(surface.grabToImage(function(image) {
            saved = image.saveToFile("/tmp/opencode/ai-task-" + name + ".png")
        }))
        tryVerify(function() { return saved })
    }
    function render(name, fixture) {
        tests.current = fixture
        for (var w of [980, 760, 420]) {
            tests.width = w
            wait(50)
            verify(answer.taskMode && answer.height > 0)
            verify(findChild(answer, "aiTaskPrimary").width > 0)
            capture(name + "-" + w)
        }
    }
    function test_decisionShortlistInspectsWithoutSending() {
        render("decision", decision())
        var tool = findChild(answer, "aiCompare")
        tool.moveCursor(1)
        wait(30)
        compare(tool.inspectedOption.index, 1)
        compare(sends.count + edits.count, 0)
        capture("decision-inspected-420")
    }
    function test_planAndPersistedProgress() {
        render("plan", plan())
        answer.uiState = {"plan:0": {done: [0, 1]}}
        wait(30)
        compare(findChild(answer, "aiTimeline").nextRow, 2)
        compare(edits.count, 0)
        capture("plan-progress-420")
    }
    function test_formContextReflows() {
        render("form", planningForm())
        compare(edits.count, 0)
    }
    function test_themePalettesDoNotChangeContent() {
        tests.ink = "#dbb42c"; tests.paper = "#3f0002"; tests.tone = "#dbb42c"
        render("crimson-gold", decision())
        tests.ink = "#252b32"; tests.paper = "#f3f2ec"; tests.tone = "#665134"
        render("light", decision())
        compare(sends.count + edits.count, 0)
    }
}
