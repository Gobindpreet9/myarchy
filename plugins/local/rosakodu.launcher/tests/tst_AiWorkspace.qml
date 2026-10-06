import QtQuick
import QtQuick.Layouts
import QtTest
import ".." as Launcher
import "../AiLayout.js" as AiLayout
import "../AiState.js" as AiState
import "../SatinGlass.js" as Satin

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
        property bool attachmentBlocked: false
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

    // The detached window needs a service with the full preview contract; the
    // shared mock above deliberately LACKS it (legacy-mock safety is pinned
    // by test_previewAndRestoreAreIndependentComposerGates).
    ListModel { id: detachedTurnModel }
    QtObject {
        id: detachedService
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool attachmentBlocked: false
        property bool canContinue: false
        property bool windowActive: false
        property string stateRoot: "/tmp/opencode"
        property string attachment: ""
        property string activity: ""
        property string draft: ""
        property string previewStatus: "idle"
        property var previewData: null
        property string previewError: ""
        property var checklistStates: ({})
        property var turns: []
        property var uiStates: ({})
        property alias turnModel: detachedTurnModel
        readonly property var latest: turns.length ? turns[turns.length - 1] : null
        function retryAttachmentPreview() { }
        function submit() { }
        function stop() { }
        function newConversation() { turns = [] }
    }
    Component {
        id: detachedProbe
        // Mirrors WorkspaceWindow's column exactly — 20px insets, 14px
        // spacing, title row, composer, pane — but without the Quickshell
        // FloatingWindow, which only loads inside the quickshell binary
        // (AiDetachedWindowCheck.qml exercises the real window).
        Item {
            id: probe
            width: 720
            visible: true
            readonly property real floor: AiLayout.detachedMinimumHeight(
                probeTitle.implicitHeight, probeComposer.implicitHeight, probePane.chromeHeight,
                probePane.turnCount > 0 || detachedService.loadingLatest ? 160 : 0)
            height: floor
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 14
                Text {
                    id: probeTitle
                    objectName: "detachedProbeTitle"
                    Layout.fillWidth: true
                    text: "New workspace"
                    textFormat: Text.PlainText
                    // Mirror WorkspaceWindow's title exactly (Satin token,
                    // not a hardcoded size) so the replica floor cannot drift
                    // from the real window's measurement.
                    font.pixelSize: Satin.type.result
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Launcher.AiComposer {
                    id: probeComposer
                    objectName: "detachedProbeComposer"
                    Layout.fillWidth: true
                    Layout.preferredHeight: implicitHeight
                    showBackButton: false
                    foreground: "#f1f2f4"
                    background: "#1b1c20"
                    accent: "#b4c4dc"
                    prompt: detachedService.draft
                    busy: detachedService.busy
                    stopping: detachedService.stopping
                    loading: detachedService.loadingLatest
                    attachmentBlocked: detachedService.attachmentBlocked
                    hasConversation: detachedService.turns.length > 0
                    onEdited: function(text) { detachedService.draft = text }
                    onStopRequested: detachedService.stop()
                }
                Launcher.AiPane {
                    id: probePane
                    objectName: "detachedProbePane"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: detachedService.turns.length > 0 || !!detachedService.attachment
                        || detachedService.loadingLatest
                    allowExpand: false
                    allowOpenWindow: false
                    service: detachedService
                    foreground: "#f1f2f4"
                    background: "#1b1c20"
                    accent: "#b4c4dc"
                    onFillPrompt: function(text) { detachedService.draft = text }
                }
            }
        }
    }
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
                loading: mockService.loadingLatest
                attachmentBlocked: mockService.attachmentBlocked
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
        mockService.loadingLatest = false
        mockService.attachmentBlocked = false
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
    function test_previewAndRestoreAreIndependentComposerGates() {
        tests.query = "ai: Review the CSV"
        mockService.attachmentBlocked = true
        verify(!composer.canSubmit && !findChild(composer, "aiComposerStop").visible)
        mockService.loadingLatest = true
        mockService.attachmentBlocked = false
        verify(!composer.canSubmit)
        mockService.loadingLatest = false
        verify(composer.canSubmit)
        var loader = findChild(pane, "aiCsvPreviewLoader")
        mockService.attachment = "/fixtures/legacy.csv"
        wait(20)
        verify(!loader.active && loader.item === null, "Legacy service mocks without preview fields stay safe")
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

    function test_detachedMinimumHeightTracksMeasuredContent() {
        compare(AiLayout.detachedMinimumHeight(30, 220, 300, 160), 40 + 28 + 30 + 220 + 300 + 160,
            "Title, composer, pane chrome and conversation room all feed the floor")
        compare(AiLayout.detachedMinimumHeight(0, 0, 0, 0), 560,
            "Empty content keeps the declared 720x560 floor")
        compare(AiLayout.detachedMinimumHeight(NaN, -5, NaN, NaN), 560,
            "Invalid measurements never shrink the floor")
        verify(AiLayout.detachedMinimumHeight(40, 220, 400, 0) > 560,
            "Full preview chrome alone lifts the floor above the old fixed minimum")
    }

    function test_detachedColumnFitsPreviewDisclosuresAtItsFloor() {
        var probe = createTemporaryObject(detachedProbe, tests)
        verify(probe !== null)
        wait(50)
        compare(probe.floor, 560, "Without preview chrome the declared floor is unchanged")

        detachedService.attachment = "/fixtures/rents.csv"
        var cols = [], rows = []
        for (var ci = 0; ci < 20; ++ci) cols.push("Column " + ci)
        for (var ri = 0; ri < 10; ++ri) {
            var row = []
            for (var cj = 0; cj < 20; ++cj) row.push(ri + "/" + cj)
            rows.push(row)
        }
        detachedService.previewData = {
            columns: cols, rows: rows,
            previewRows: 10, sampleRows: 10, columnCount: 1000, totalRows: 99999,
            truncated: true, columnsTruncated: true, cellsTruncated: true,
            note: "Sampled from a much larger source file; this is not a complete copy."
        }
        detachedService.previewStatus = "ready"
        detachedService.draft = "line one\nline two\nline three\nline four\nline five\n"
            + "line six\nline seven\nline eight\nline nine\nline ten"
        wait(150)
        verify(probe.floor > 560,
            "Full disclosures plus a capped long draft must raise the measured floor")
        verify(probe.floor >= 660 && probe.floor <= 680,
            "Measured floor stays in the pinned band (real window: 669 at width 720), got " + probe.floor)
        compare(probe.height, probe.floor, "The column is sized by its floor, not a fixed 560px")

        var disclosure = findChild(probe, "aiCsvPreviewDisclosure")
        verify(disclosure !== null && disclosure.visible)
        var bottom = disclosure.mapToItem(probe, 0, disclosure.height).y
        verify(bottom <= probe.height,
            "Disclosure bottom " + bottom + " must fit in the floor height " + probe.height)
        var loader = findChild(probe, "aiCsvPreviewLoader")
        verify(loader !== null)
        var loaderBottom = loader.mapToItem(probe, 0, loader.height).y
        verify(loaderBottom <= probe.height,
            "Preview chrome bottom " + loaderBottom + " must stay inside the floor")

        // Cleanup so later cases start from rest.
        detachedService.attachment = ""
        detachedService.previewStatus = "idle"
        detachedService.previewData = null
        detachedService.draft = ""
        wait(30)
        compare(probe.floor, 560, "Removing the attachment restores the plain floor")
    }
}
