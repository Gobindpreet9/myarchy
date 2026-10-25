import QtQuick
import QtTest
import ".." as Launcher
import "../AiState.js" as AiState

// The composer chip ("About: <label>") and the pane gate for "Ask about this".
TestCase {
    id: tests
    name: "AiFocusChip"
    width: 800
    height: 900
    visible: true
    when: windowShown

    property string chip: ""
    property string longLabel: "W".repeat(80)

    Launcher.AiComposer {
        id: composer
        y: 0
        width: 660
        height: implicitHeight
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
        focusLabel: tests.chip
        onFocusCleared: tests.chip = ""
    }
    SignalSpy { id: clearedSpy; target: composer; signalName: "focusCleared" }
    SignalSpy { id: hideSpy; target: composer; signalName: "hideRequested" }
    SignalSpy { id: submitSpy; target: composer; signalName: "submitted" }

    readonly property var input: findChild(composer, "aiComposerInput")
    readonly property var back: findChild(composer, "aiComposerBack")
    readonly property var clear: findChild(composer, "aiComposerFocusClear")
    readonly property var chipItem: findChild(composer, "aiComposerFocusChip")

    // ---- A mock service shaped like AiService's focus seam -----------------
    QtObject {
        id: service
        property string agent: "codex"
        property string defaultAgent: "codex"
        property string activity: ""
        property int workElapsed: 0
        property string attachment: ""
        property string stateRoot: "/tmp/opencode/s1-media-root"
        property bool canContinue: false
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool workspaceActionPending: false
        property bool workspaceTransitionPending: false
        property var turns: []
        property var uiStates: ({})
        property var checklistStates: ({})
        property alias turnModel: turnModel
        onTurnsChanged: {
            turnModel.clear()
            turns.forEach(function(turn) { turnModel.append({payload: turn}) })
        }
        readonly property var latest: turns.length ? turns[turns.length - 1] : null
        property var focusTarget: null
        readonly property string focusLabel: focusTarget ? String(focusTarget.label) : ""
        property bool acceptFocus: true
        property int focusCalls: 0
        function clearFocus() { if (focusTarget !== null) focusTarget = null }
        function setFocus(target) {
            ++focusCalls
            if (!acceptFocus) return false
            var wire = AiState.focusWire(target)
            if (!wire || !latest || latest.id !== wire.turnId || latest.status !== "done") return false
            focusTarget = wire
            return true
        }
        function setUiState(id, key, value) { return true }
        function stop() { }
        function newConversation() { turns = [] }
        function continueInTerminal() { return false }
        function copyAnswer() { }
    }
    ListModel { id: turnModel; dynamicRoles: true }

    Launcher.AiPane {
        id: pane
        y: 160
        width: 700
        height: 600
        service: service
        foreground: "#eeeeee"
        background: "#161616"
        accent: "#9bb9e9"
    }
    SignalSpy { id: composerFocusSpy; target: pane; signalName: "composerFocusRequested" }
    SignalSpy { id: paneHideSpy; target: pane; signalName: "hideRequested" }

    function table(id, status) {
        return {id: id, prompt: "Compare", attachment: "", answer: "Here is a comparison.", blocks: [
            {type: "table", title: "Cities", columns: ["City", "Rent"], rows: [["Oslo", "1200"], ["Porto", "600"]]}],
            suggestions: [], warning: "", error: "", status: status || "done", explanation: ""}
    }

    function init() {
        tests.chip = ""
        composer.width = 660
        composer.prompt = ""
        composer.busy = false
        composer.hasConversation = false
        clearedSpy.clear(); hideSpy.clear(); submitSpy.clear()
        service.busy = false; service.stopping = false; service.loadingLatest = false
        service.workspaceActionPending = false; service.workspaceTransitionPending = false
        service.agent = "codex"; service.defaultAgent = "codex"
        service.acceptFocus = true; service.focusCalls = 0
        service.focusTarget = null
        service.turns = []
        pane.showText = false
        pane.historyExpanded = false
        composerFocusSpy.clear(); paneHideSpy.clear()
        composer.focusPrompt()
        wait(20)
    }

    // ------------------------------------------------------------- composer
    function test_noChipLeavesTheComposerExactlyAsBefore() {
        verify(!chipItem.visible)
        compare(chipItem.height, 0)
        compare(input.placeholderText, "Ask anything")
        var restHeight = composer.implicitHeight
        verify(restHeight >= 56 && restHeight <= 64, "rest height " + restHeight)
        compare(findChild(composer, "aiComposerFocusFrame").mapToItem(composer, 0, 0).y, 8)
        composer.hasConversation = true
        compare(input.placeholderText, "Ask a follow-up")
        compare(input.Accessible.description, "")
    }

    function test_chipShowsLabelNamePlaceholderAndGrowsByItsOwnHeight() {
        var rest = composer.implicitHeight
        tests.chip = "Porto"
        verify(chipItem.visible)
        compare(chipItem.height, 30)
        compare(composer.implicitHeight, rest + 30 + 8)
        compare(clear.Accessible.name, "Asking about Porto, clear")
        compare(clear.Accessible.role, Accessible.Button)
        compare(input.placeholderText, "Ask about Porto\u2026")
        compare(input.Accessible.description, "Asking about Porto")
        var text = null
        function find(item) {
            for (var i = 0; i < item.children.length; ++i) {
                if (item.children[i].text === "About: Porto") text = item.children[i]
                find(item.children[i])
            }
        }
        find(clear)
        verify(text !== null, "the chip reads About: <label>")
        compare(text.textFormat, Text.PlainText)
        // The field sits below the chip and the back arrow stays centred on it.
        var frame = findChild(composer, "aiComposerFocusFrame")
        compare(frame.mapToItem(composer, 0, 0).y, 8 + 30 + 8)
        var backCentre = back.y + back.height / 2
        var frameCentre = frame.mapToItem(composer, 0, 0).y + frame.height / 2
        verify(Math.abs(backCentre - frameCentre) <= 1, "back " + backCentre + " vs field " + frameCentre)
        tests.chip = ""
        compare(composer.implicitHeight, rest, "clearing restores the rest height")
        compare(input.placeholderText, "Ask anything")
    }

    function test_chipIsNeverATabStopAndTabRingIsUnchanged() {
        tests.chip = "Porto"
        compare(clear.activeFocusOnTab, false)
        compare(clear.focusPolicy, Qt.NoFocus)
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        keyClick(Qt.Key_Tab)
        tryCompare(back, "activeFocus", true, 8000, "empty draft: Tab still lands on Back, not on the chip")
    }

    function test_escapePeelsTheChipFirstAndKeepsTheDraft() {
        composer.prompt = "why is this one cheaper"
        tests.chip = "Porto"
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        keyClick(Qt.Key_Escape)
        compare(clearedSpy.count, 1)
        compare(hideSpy.count, 0, "the first Escape only clears the chip")
        compare(tests.chip, "")
        compare(input.text, "why is this one cheaper")
        keyClick(Qt.Key_Escape)
        compare(hideSpy.count, 1, "with no chip Escape is unchanged: hide")
        compare(clearedSpy.count, 1)
        // Escape from a focused composer button peels the chip as well.
        tests.chip = "Porto"
        back.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Escape)
        compare(clearedSpy.count, 2)
        compare(hideSpy.count, 1)
    }

    function test_clickingTheChipClearsItAndReturnsToTheField() {
        tests.chip = "Porto"
        back.forceActiveFocus(Qt.TabFocusReason)
        mouseClick(clear, clear.width / 2, clear.height / 2)
        compare(clearedSpy.count, 1)
        compare(tests.chip, "")
        tryCompare(composer, "activeInputFocus", true)
        compare(submitSpy.count, 0)
    }

    function test_longLabelIsElidedAtBothWidthsAndPlaceholderStaysShort() {
        var widths = [660, 380]
        for (var w = 0; w < widths.length; ++w) {
            composer.width = widths[w]
            tests.chip = longLabel
            wait(20)
            var field = findChild(composer, "aiComposerFocusFrame")
            verify(clear.width <= chipItem.width + 0.5, "chip fits at " + widths[w] + ": " + clear.width + " in " + chipItem.width)
            verify(clear.x + clear.width <= chipItem.width + 0.5)
            verify(chipItem.x + chipItem.width <= composer.width, "inside the card at " + widths[w])
            var label = null
            function find(item) {
                for (var i = 0; i < item.children.length; ++i) {
                    if (typeof item.children[i].text === "string" && item.children[i].text.indexOf("About: ") === 0) label = item.children[i]
                    find(item.children[i])
                }
            }
            find(clear)
            verify(label !== null)
            verify(label.width <= clear.width, "text lives inside the pill")
            if (widths[w] === 380) verify(label.truncated, "elided at the narrow width")
            verify(input.placeholderText.length <= 60, "placeholder " + input.placeholderText.length)
            verify(input.placeholderText.indexOf("Ask about WWW") === 0)
            compare(clear.Accessible.name, "Asking about " + longLabel + ", clear")
        }
    }

    // ------------------------------------------------------------ pane gate
    function ask(index) {
        var control = findChild(pane, "aiTableAsk_" + index)
        verify(control !== null, "ask control " + index)
        control.clicked()
    }

    function test_openGateOffersTheControlAndSetsTheServiceFocus() {
        service.turns = [table(41)]
        wait(60)
        var body = findChild(pane, "aiTableRows")
        verify(body !== null)
        compare(body.enabled, true)
        body.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Down)
        keyClick(Qt.Key_Question)
        compare(service.focusCalls, 1)
        compare(JSON.stringify(service.focusTarget), JSON.stringify({turnId: 41, blockIndex: 0, kind: "table", index: 1,
            label: "Porto", detail: "City: Porto; Rent: 600"}))
        compare(composerFocusSpy.count, 1, "the host moves focus to the composer")
        compare(service.focusLabel, "Porto")
        compare(service.turns.length, 1, "asking sends nothing")
        // The Ask control does the same for another row.
        ask(0)
        compare(service.focusLabel, "Oslo")
        compare(composerFocusSpy.count, 2)
    }

    function test_aRefusedFocusDoesNotMoveKeyboardFocus() {
        service.turns = [table(42)]
        wait(60)
        service.acceptFocus = false
        ask(0)
        compare(service.focusCalls, 1)
        compare(composerFocusSpy.count, 0)
        compare(service.focusLabel, "")
    }

    function test_gateIsClosedUnlessTheLatestFinishedAnswerIsIdle() {
        service.turns = [table(43)]
        wait(60)
        var flags = ["busy", "stopping", "loadingLatest", "workspaceActionPending", "workspaceTransitionPending"]
        for (var i = 0; i < flags.length; ++i) {
            service[flags[i]] = true
            wait(10)
            var body = findChild(pane, "aiTableRows")
            verify(body === null || body.enabled === false, flags[i] + " closes the gate")
            var control = findChild(pane, "aiTableAsk_0")
            verify(control === null || !control.visible)
            service[flags[i]] = false
            wait(10)
            compare(findChild(pane, "aiTableRows").enabled, true, flags[i] + " reopens it")
        }
        service.agent = ""; service.defaultAgent = ""
        wait(10)
        compare(findChild(pane, "aiTableRows").enabled, false, "no agent: nothing to send to")
        service.agent = "codex"; service.defaultAgent = "codex"
        wait(10)
        compare(findChild(pane, "aiTableRows").enabled, true)
        // An unfinished or an older answer is closed.
        service.turns = [table(44, "working")]
        wait(30)
        compare(findChild(pane, "aiTableRows").enabled, false)
        service.turns = [table(45), {id: 46, prompt: "Next", attachment: "", answer: "Later", blocks: [], suggestions: [],
            warning: "", error: "", status: "done", explanation: ""}]
        pane.historyExpanded = true
        wait(60)
        compare(findChild(pane, "aiTableRows").enabled, false, "an older answer is not the subject")
        pane.showText = true
        wait(30)
        pane.showText = false
    }

    function test_textViewAndOlderServicesShowNothing() {
        service.turns = [table(47)]
        wait(60)
        compare(findChild(pane, "aiTableRows").enabled, true)
        pane.showText = true
        wait(40)
        var body = findChild(pane, "aiTableRows")
        verify(body === null || body.enabled === false, "the text view has no parts")
        pane.showText = false
        wait(30)
        var legacy = {latest: service.latest, turns: service.turns, turnModel: turnModel, uiStates: ({}),
            busy: false, loadingLatest: false, attachment: "", canContinue: false, agent: "codex", defaultAgent: "codex"}
        try {
            pane.service = legacy
            wait(40)
            var legacyBody = findChild(pane, "aiTableRows")
            verify(legacyBody === null || legacyBody.enabled === false, "no setFocus: no control")
        } finally {
            pane.service = service
        }
        wait(30)
    }

    function test_escapeInThePaneAlsoPeelsTheChipBeforeHiding() {
        service.turns = [table(48)]
        wait(60)
        ask(0)
        compare(service.focusLabel, "Oslo")
        pane.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Escape)
        compare(service.focusLabel, "")
        compare(paneHideSpy.count, 0)
        keyClick(Qt.Key_Escape)
        compare(paneHideSpy.count, 1)
    }
}
