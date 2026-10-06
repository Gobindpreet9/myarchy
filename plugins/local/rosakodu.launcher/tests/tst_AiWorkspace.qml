import QtQuick
import QtQuick.Layouts
import QtTest
import ".." as Launcher
import "../AiLayout.js" as AiLayout
import "../AiState.js" as AiState

TestCase {
    id: tests
    name: "AiWorkspace"
    width: 860
    height: 900
    visible: true
    when: windowShown
    property string query: "ai: "

    function test_restoreHintKeepsTheInitialPaneVisible() {
        var loading = {turns: [], attachment: "", loadingLatest: true}
        verify(AiLayout.paneVisible(true, loading))
        verify(!AiLayout.paneVisible(false, loading))
        verify(!AiLayout.paneVisible(true, {turns: [], attachment: "", loadingLatest: false}))
        compare(AiLayout.idleCardHeight(false, 60, 40), 140,
                "The initial card reserves measured loading chrome")
    }

    QtObject {
        id: mockService
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool canContinue: false
        property string stateRoot: "/tmp/opencode"
        property string attachment: ""
        property string activity: "Illustrative activity"
        property var checklistStates: ({})
        property var turns: []
        property alias turnModel: model
        readonly property var latest: turns.length ? turns[turns.length - 1] : null
        onTurnsChanged: {
            model.clear()
            turns.forEach(function(turn) { model.append({payload: turn}) })
        }
        function copyAnswer() { }
        function newConversation() { turns = [] }
        function openSource(url) { return true }
        function continueInTerminal() { return false }
        function stop() { stopping = true }
    }
    ListModel { id: model }
    Rectangle {
        id: card
        width: 820
        height: AiLayout.answerHeight(pane.responseHeight, pane.chromeHeight, composer.implicitHeight)
        color: "#1b1c20"
        radius: 20
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 14
            Launcher.AiComposer {
                id: composer
                Layout.fillWidth: true
                Layout.preferredHeight: AiLayout.composerHeight
                Layout.maximumHeight: AiLayout.composerMaxHeight
                foreground: "#f1f2f4"
                background: card.color
                accent: "#b4c4dc"
                prompt: AiState.draft(tests.query)
                busy: mockService.busy
                stopping: mockService.stopping
                hasConversation: mockService.turns.length > 0
                onEdited: text => tests.query = "ai: " + text
                onStopRequested: mockService.stop()
            }
            Launcher.AiPane {
                id: pane
                Layout.fillWidth: true
                Layout.fillHeight: true
                service: mockService
                foreground: "#f1f2f4"
                background: card.color
                accent: "#b4c4dc"
                onFillPrompt: text => tests.query = "ai: " + text
            }
        }
    }
    function init() {
        card.width = 820
        tests.query = "ai: "
        mockService.busy = false
        mockService.stopping = false
        mockService.attachment = ""
        mockService.turns = [{id: 1, prompt: "Illustrative topic", attachment: "", status: "done", error: "", warning: "",
            answer: "Illustrative brief: a compact overview accompanies a contextual figure.",
            blocks: [{type: "image", title: "Illustrative topic", query: "Illustrative figure", error: "Illustrative offline image"},
                {type: "sources", items: [{label: "Illustrative reference", url: "https://example.com/reference"}]}], suggestions: []}]
        wait(20)
    }
    function test_shortAnswerFitsAboveToolbar_data() {
        return [{tag: "wide", width: 820}, {tag: "narrow", width: 420}]
    }
    function test_shortAnswerFitsAboveToolbar(data) {
        card.width = data.width
        wait(20)
        verify(card.height < 720)
        var source = findChild(pane, "aiSource_0")
        var toolbar = findChild(pane, "aiMore")
        verify(source !== null && toolbar !== null)
        verify(source.mapToItem(card, 0, source.height).y <= toolbar.mapToItem(card, 0, 0).y - pane.spacing,
            "Content-measured card sizing must include the toolbar, not clip its final source")
        compare(findChild(pane, "aiImage").mediaRoot, mockService.stateRoot + "/media")
        compare(findChild(pane, "aiAnswerTitle").text, "Illustrative topic")
        verify(composer.y + composer.height <= pane.y - 14)
    }
    function test_attachmentAndBusyChromeAreMeasured() {
        var initialHeight = card.height
        var initialChrome = pane.chromeHeight
        mockService.attachment = "/fixtures/test-home/illustrative.txt"
        wait(20)
        verify(pane.chromeHeight >= initialChrome + 48)
        verify(card.height >= initialHeight + 48)
        mockService.busy = true
        wait(20)
        verify(findChild(composer, "aiComposerStop").visible)
        verify(!findChild(pane, "aiMore").visible)
        verify(pane.chromeHeight >= 88, "Attachment and activity remain accounted for while the toolbar is hidden")
    }
    function test_answerHeightIsBoundedAndRoundsUp() {
        compare(AiLayout.answerHeight(0, 0), 260)
        compare(AiLayout.answerHeight(300.25, 50), 465)
        compare(AiLayout.answerHeight(10000, 50), 720)
        verify(AiLayout.answerHeight(0, 0, 105) >= Math.ceil(40 + 105 + 14), "A taller composer adds exactly its growth")
        compare(AiLayout.answerHeight(10000, 50), 720, "The default cap stays at the peek height")
        compare(AiLayout.answerHeight(10000, 50, 60, 940), 940, "The Explore surface honours a taller cap")
        compare(AiLayout.idleCardHeight(false, 60), 100)
        compare(AiLayout.idleCardHeight(true, 60), 148)
        verify(AiLayout.idleCardHeight(false, 170) === 210, "A fully grown multiline draft grows the idle card")
    }
}
