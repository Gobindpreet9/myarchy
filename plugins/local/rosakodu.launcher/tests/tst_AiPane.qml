import QtQuick
import QtTest
import ".."
import "../AiState.js" as AiState
import "TestJson.js" as TestJson

TestCase {
    id: tests
    name: "AiPane"
    width: 800
    height: 660
    visible: true
    when: windowShown

    QtObject {
        id: service
        property string agent: "codex"
        property string defaultAgent: "codex"
        property string activity: "Thinking…"
        property int workElapsed: 0
        property string attachment: ""
        property string draft: ""
        property string workspaceId: "ws-fixture"
        property bool workspaceTransitionPending: false
        property bool resumeOnOpen: false
        property string previewStatus: "idle"
        property var previewData: null
        property string previewError: ""
        property int previewRetries: 0
        function retryAttachmentPreview() { ++previewRetries }
        property var previewTypeOverrides: []
        property var typeChoices: []
        function setPreviewColumnType(column, kind) {
            typeChoices = typeChoices.concat([[column, kind]])
            var next = previewTypeOverrides.slice()
            while (next.length <= column) next.push("")
            next[column] = kind
            previewTypeOverrides = next
            return true
        }
        property string sessionId: ""
        property string stateRoot: "/tmp/opencode"
        property string lastSource: ""
        property bool canContinue: false
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool latestRequested: false
        property string workspaceDisplayTitle: "Illustrative workspace"
        property string workspaceName: ""
        property bool workspaceReady: true
        property string keepPhase: ""
        readonly property bool canManageWorkspace: workspaceReady && !busy && !loadingLatest && !stopping
            && keepPhase.length === 0 && !workspaceActionPending
        property bool workspaceActionPending: false
        property string workspaceActionError: ""
        property bool workspaceActionAccepted: true
        property string lastRename: ""
        property string lastDuplicate: ""
        function renameWorkspace(title) {
            lastRename = title
            if (workspaceActionAccepted) workspaceActionPending = true
            return workspaceActionAccepted
        }
        function duplicateWorkspace(title) {
            lastDuplicate = title
            if (workspaceActionAccepted) workspaceActionPending = true
            return workspaceActionAccepted
        }
        property var turns: []
        property var uiStates: ({})
        property var checklistStates: ({})
        property alias turnModel: turnModel
        onTurnsChanged: {
            turnModel.clear()
            turns.forEach(function(turn) { turnModel.append({payload: turn}) })
        }
        readonly property var latest: turns.length ? turns[turns.length - 1] : null
        function stop() { busy = false }
        function newConversation() { turns = [] }
        function continueInTerminal() { return false }
        property string lastSignIn: ""
        function signIn(provider) { lastSignIn = provider; return true }
        property int answerCopies: 0
        function copyAnswer() { ++answerCopies }
        property var copiedTexts: []
        property var duplicated: []
        function copyText(text) { copiedTexts = copiedTexts.concat([text]); return true }
        function duplicateCalc(baked) { duplicated = duplicated.concat([baked]); return true }
        property var submittedForms: []
        // formAdvances mimics the real service: the answer turn is appended and the
        // form's own row is torn down inside the same call that marks it sent.
        property bool formAdvances: false
        function submitForm(turnId, blockIndex) {
            submittedForms = submittedForms.concat([[turnId, blockIndex]])
            if (formAdvances) {
                turns = turns.concat([{id: turnId + 1, prompt: "Answers to the form on the previous answer.", attachment: "",
                    answer: "", blocks: [], suggestions: [], warning: "", error: "", status: "working", explanation: "",
                    formRef: {turnId: turnId, blockIndex: blockIndex}, formAnswers: [{label: "Budget", text: "1000 EUR"}]}])
                busy = true
                var all = Object.assign({}, uiStates)
                all[String(turnId)] = Object.assign({}, all[String(turnId)] || {}, {["form:" + blockIndex]: {v: {}, sent: true}})
                uiStates = all
            }
            return true
        }
        // submitChoice mimics the real service the same way (turn appended, busy).
        property var submittedChoices: []
        property bool choiceAdvances: false
        function submitChoice(turnId, blockIndex, kind, index) {
            submittedChoices = submittedChoices.concat([[turnId, blockIndex, kind, index]])
            if (choiceAdvances) {
                turns = turns.concat([{id: turnId + 1, prompt: "Choice made on the previous answer.", attachment: "",
                    answer: "", blocks: [], suggestions: [], warning: "", error: "", status: "working", explanation: "",
                    choiceRef: {turnId: turnId, blockIndex: blockIndex, kind: kind, index: index}, choiceText: "Picked: Skip"}])
                busy = true
                var all = Object.assign({}, uiStates)
                all[String(turnId)] = Object.assign({}, all[String(turnId)] || {}, {["act:" + blockIndex]: {picked: index}})
                uiStates = all
            }
            return true
        }
        property var focusRequests: []
        function setFocus(target) { focusRequests = focusRequests.concat([target]); return true }
        function openSource(url) { lastSource = url; return true }
        function setChecklist(id, block, item, checked) {
            var all = Object.assign({}, checklistStates)
            var state = Object.assign({}, all[String(id)] || {})
            state[block + ":" + item] = checked
            all[String(id)] = state
            checklistStates = all
        }
        function requestLatest() {
            latestRequested = true
            loadingLatest = true
        }
        property string lastExplain: ""
        function explainLatest(mode) {
            lastExplain = mode
            return true
        }
        // Durable CSV source surface (the real service owns an AiCsvSource).
        property var csvSource: csvMock
        property bool keepOffered: false
        property bool canKeepFullData: true
        property int keepCalls: 0
        function keepFullData() { ++keepCalls; return true }
        property string sourceNotice: ""
        property string sourceOrigin: ""
        property string sourceError: ""
        property bool canRefreshSource: true
        property int refreshCalls: 0
        function refreshSource() { ++refreshCalls; return true }
        property var csvViews: ({})
        function csvViewState(id) { return csvViews[id] || ({}) }
        function setCsvViewState(id, state) {
            var next = Object.assign({}, csvViews)
            next[id] = state
            csvViews = next
            return true
        }
    }
    QtObject {
        id: csvMock
        property string status: "idle"
        property var meta: null
        property int progressRows: 0
        property int viewRows: -1
        property string sourceId: ""
        property var page: null
        property bool busy: false
        property bool viewPending: false
        property string error: ""
        property bool retryable: false
        property string verifyState: ""
        function setView(sort, dir, filter) { return true }
        function goPage(n) { return true }
        function close() { }
        function invalidate() { }
    }

    ListModel { id: turnModel; dynamicRoles: true }
    SignalSpy { id: hideSpy; target: pane; signalName: "hideRequested" }
    SignalSpy { id: handoffSpy; target: pane; signalName: "handedOff" }
    SignalSpy { id: expandSpy; target: pane; signalName: "expandToggled" }
    SignalSpy { id: windowSpy; target: pane; signalName: "openWindowRequested" }
    SignalSpy { id: fillSpy; target: pane; signalName: "fillPrompt" }

    Item { id: tabStart; activeFocusOnTab: true; width: 10; height: 10 }

    AiPane {
        id: pane
        width: 760
        height: 620
        service: service
        foreground: "#eeeeee"
        background: "#161616"
        accent: "#9bb9e9"
    }

    function cleanup() { service.turns = []; service.busy = false; service.activity = "Thinking\u2026"; service.workElapsed = 0; service.attachment = ""; service.lastSource = ""; service.checklistStates = ({}); service.copiedTexts = []; service.duplicated = []; service.loadingLatest = false; service.latestRequested = false; service.stateRoot = "/tmp/opencode"; service.previewStatus = "idle"; service.previewData = null; service.previewError = ""; service.previewRetries = 0; service.previewTypeOverrides = []; service.typeChoices = []; pane.showText = false
        service.keepOffered = false; service.canKeepFullData = true; service.keepCalls = 0; service.sourceNotice = ""; service.sourceOrigin = ""
        service.sourceError = ""; service.canRefreshSource = true; service.refreshCalls = 0; service.csvViews = ({})
        csvMock.status = "idle"; csvMock.meta = null; csvMock.progressRows = 0; csvMock.viewRows = -1; csvMock.sourceId = ""
        findChild(pane, "aiWorkspacePopup").close(); findChild(pane, "aiMoreMenu").close()
        service.workspaceDisplayTitle = "Illustrative workspace"; service.workspaceName = ""
        service.workspaceReady = true; service.keepPhase = ""; service.stopping = false
        service.workspaceActionPending = false; service.workspaceActionError = ""; service.workspaceActionAccepted = true
        service.lastRename = ""; service.lastDuplicate = ""
        pane.width = 760; pane.expanded = false; pane.allowExpand = true }
    function test_csvPreviewIsLazyMeasuredAndUsesServiceRetry() {
        var loader = findChild(pane, "aiCsvPreviewLoader")
        verify(!loader.active && loader.item === null)
        service.attachment = "/fixtures/notes.txt"
        wait(30)
        var attachmentChrome = pane.chromeHeight
        service.attachment = "/fixtures/rents.CSV"
        service.previewStatus = "loading"
        wait(30)
        verify(loader.active && loader.visible && loader.item !== null)
        compare(findChild(pane, "aiCsvPreviewLoading").visible, true)
        compare(pane.chromeHeight, attachmentChrome + loader.implicitHeight + pane.spacing)
        var loadingHeight = pane.chromeHeight
        service.previewData = {columns: ["City", "Rent"], rows: [["Oslo", "1200"], ["Porto", "600"]],
            previewRows: 2, sampleRows: 2, columnCount: 2, totalRows: 2,
            truncated: false, columnsTruncated: false, cellsTruncated: false, note: ""}
        service.previewStatus = "ready"
        wait(30)
        compare(findChild(pane, "aiCsvPreviewCell0").text, "Oslo")
        compare(findChild(pane, "aiCsvPreviewCount").text, "2 of 2 rows · 2 of 2 columns")
        verify(pane.chromeHeight > loadingHeight)
        compare(pane.chromeHeight, attachmentChrome + loader.implicitHeight + pane.spacing)
        verify(findChild(pane, "aiCsvPreviewFooter").text.indexOf("read again when you send") >= 0)
        service.previewStatus = "error"
        service.previewData = null
        service.previewError = "CSV attachment is empty."
        wait(30)
        compare(findChild(pane, "aiCsvPreviewError").text, service.previewError)
        verify(findChild(pane, "aiCsvPreviewCell0") === null)
        var retry = findChild(pane, "aiCsvPreviewRetry")
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(service.previewRetries, 1)
        service.attachment = "/fixtures/notes.txt"
        wait(30)
        verify(!loader.active && loader.item === null)
        compare(pane.chromeHeight, attachmentChrome)
        service.attachment = ""
        wait(30)
        compare(pane.chromeHeight, 0)
    }
    function test_columnTypeCorrectionsFlowThroughTheServiceOnly() {
        service.attachment = "/fixtures/rents.csv"
        service.previewData = {columns: ["City", "Rent"], rows: [["Oslo", "1,200"], ["Porto", "600"]],
            previewRows: 2, sampleRows: 2, columnCount: 2, totalRows: 2,
            truncated: false, columnsTruncated: false, cellsTruncated: false, note: ""}
        service.previewStatus = "ready"
        wait(30)
        var rent = findChild(pane, "aiCsvPreviewType1")
        compare(rent.text, "?", "locale-ambiguous thousands separator is not guessed")
        mouseClick(rent, rent.width / 2, rent.height / 2)
        var menu = findChild(pane, "aiCsvPreviewTypeMenu")
        tryCompare(menu, "opened", true)
        mouseClick(menu.itemAt(0), 10, 10)
        compare(JSON.stringify(service.typeChoices), JSON.stringify([[1, "number"]]),
            "the pane forwards the choice to the service and nothing else")
        wait(30)
        compare(findChild(pane, "aiCsvPreviewType1").text, "123")
        compare(findChild(pane, "aiCsvPreviewType1").corrected, true)
        compare(service.turns.length, 0, "A correction never submits")
        // A service without the new surface (older mocks) stays safe.
        service.previewTypeOverrides = []
        wait(30)
        compare(findChild(pane, "aiCsvPreviewType1").corrected, false)
        service.attachment = ""
        service.previewStatus = "idle"
        service.previewData = null
        wait(30)
    }
    function readyCsv() {
        service.attachment = "/fixtures/rents.csv"
        service.previewData = {columns: ["City", "Rent"], rows: [["Oslo", "1200"], ["Porto", "600"]],
            previewRows: 2, sampleRows: 2, columnCount: 2, totalRows: 2,
            truncated: false, columnsTruncated: false, cellsTruncated: false, note: ""}
        service.previewStatus = "ready"
        wait(30)
    }
    function wideCsv() {
        var columns = [], row = [], rows = []
        for (var c = 0; c < 20; ++c) { columns.push("Column " + c); row.push("v" + c) }
        for (var r = 0; r < 10; ++r) rows.push(row)
        service.attachment = "/fixtures/big.csv"
        service.previewData = {columns: columns, rows: rows, previewRows: 10, sampleRows: 10,
            columnCount: 20, totalRows: null, truncated: true, columnsTruncated: false,
            cellsTruncated: false, note: "Sampled the first rows."}
        service.previewStatus = "ready"
    }
    function readySource() {
        csvMock.sourceId = "src-0123456789abcdef"
        csvMock.meta = {rows: 100000}
        csvMock.status = "ready"
    }
    function test_previewCollapsesOnlyWhenADurableSourceIsOnAnExpandedSurface() {
        wideCsv()
        wait(30)
        var preview = findChild(pane, "aiCsvPreview")
        var loader = findChild(pane, "aiCsvPreviewLoader")
        verify(!preview.collapsible && findChild(pane, "aiCsvPreviewViewport") !== null, "no source: open as before")
        var openHeight = loader.implicitHeight
        readySource()
        wait(30)
        verify(!preview.collapsible && findChild(pane, "aiCsvPreviewViewport") !== null, "the peek card keeps the full preview")
        pane.expanded = true
        wait(60)
        verify(preview.collapsible && preview.collapsed, "expanded + ready source: collapsed by default")
        verify(findChild(pane, "aiCsvPreviewViewport") === null && findChild(pane, "aiCsvPreviewType0") === null)
        compare(findChild(pane, "aiCsvPreviewSummary").text, "CSV preview · 10 of unknown rows · 20 of 20 columns")
        verify(loader.implicitHeight <= 40, "one line, got " + loader.implicitHeight)
        verify(openHeight - loader.implicitHeight > 250, "the card shrinks by the whole sample")
        var toggle = findChild(pane, "aiCsvPreviewToggle")
        mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        wait(60)
        verify(!preview.collapsed && findChild(pane, "aiCsvPreviewType19") !== null, "Show brings type correction back")
        compare(pane.chromeHeight > 250, true)
        csvMock.status = "registering"
        wait(30)
        verify(preview.collapsible && !preview.collapsed, "registering keeps the user's choice")
        mouseClick(findChild(pane, "aiCsvPreviewToggle"), 10, 10)
        wait(60)
        verify(preview.collapsed, "Hide")
        pane.expanded = false
        pane.allowExpand = false
        wait(60)
        verify(preview.collapsible && preview.collapsed, "the detached window collapses too")
        csvMock.status = "idle"
        wait(60)
        verify(!preview.collapsible && findChild(pane, "aiCsvPreviewViewport") !== null,
            "losing the source reopens the preview and forgets the choice")
    }
    function tabStopsToExplorerToggle() {
        tabStart.forceActiveFocus(Qt.TabFocusReason)
        for (var n = 1; n <= 40; ++n) {
            keyClick(Qt.Key_Tab)
            var focused = tests.Window.window.activeFocusItem
            if (focused && focused.objectName === "aiCsvExplorerToggle") return n
        }
        return -1
    }
    function test_explorerToggleIsAFewTabStopsAwayNotTwentyThree() {
        pane.height = 1400
        wideCsv()
        readySource()
        pane.expanded = true
        wait(80)
        var collapsedStops = tabStopsToExplorerToggle()
        compare(collapsedStops, 3, "Remove, preview Show, Explore all rows")
        mouseClick(findChild(pane, "aiCsvPreviewToggle"), 10, 10)
        wait(80)
        var openStops = tabStopsToExplorerToggle()
        compare(openStops, 5, "Remove, Hide, grid viewport, ONE badge stop, Explore all rows (was 23)")
        // Shift+Tab walks the same ring back through the same badge.
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        compare(tests.Window.window.activeFocusItem.objectName, "aiCsvPreviewType0")
        pane.height = 620
    }
    function test_keepFullDataIsAnExplicitGatedButton() {
        readyCsv()
        var keep = findChild(pane, "aiCsvPreviewKeep")
        verify(keep === null || !keep.visible, "Not offered unless the service offers it")
        service.keepOffered = true
        wait(30)
        compare(csvMock.status, "idle", "No source exists yet")
        keep = findChild(pane, "aiCsvPreviewKeep")
        verify(keep !== null && keep.visible && keep.enabled, "A ready preview with no source offers Keep full data")
        compare(keep.text, "Keep full data")
        var note = findChild(pane, "aiCsvPreviewKeepNote")
        verify(note.visible)
        compare(note.text, "Copies this file into private launcher storage so you can browse and sort every row.")
        verify(note.color.a >= 0.76, "disclosure text keeps the contrast floor")
        compare(service.keepCalls, 0, "Readiness alone never keeps anything")
        mouseClick(keep, keep.width / 2, keep.height / 2)
        compare(service.keepCalls, 1, "The click is the only trigger")
        service.canKeepFullData = false
        wait(30)
        verify(findChild(pane, "aiCsvPreviewKeep").visible && !findChild(pane, "aiCsvPreviewKeep").enabled,
            "Busy/loading disables the offer without hiding it")
        mouseClick(keep, keep.width / 2, keep.height / 2)
        compare(service.keepCalls, 1, "A disabled button does nothing")
        service.canKeepFullData = true
        service.keepOffered = false
        wait(30)
        verify(!findChild(pane, "aiCsvPreviewKeep").visible, "Hidden once a copy exists or while registering")
        verify(!findChild(pane, "aiCsvPreviewKeepNote").visible)
        // A preview that is not ready never shows it, whatever the service says.
        service.keepOffered = true
        service.previewStatus = "error"
        service.previewData = null
        service.previewError = "CSV attachment is empty."
        wait(30)
        verify(findChild(pane, "aiCsvPreviewKeep") === null || !findChild(pane, "aiCsvPreviewKeep").visible)
    }
    function test_peekCardShowsOnlyTheHonestCountAndAHint() {
        service.turns = [{id: 1, prompt: "Q", attachment: "", answer: "A", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        csvMock.sourceId = "src-0123456789abcdef"
        csvMock.meta = {rows: 1234567}
        csvMock.status = "ready"
        wait(30)
        var peek = findChild(pane, "aiSourcePeek")
        verify(peek !== null && peek.visible)
        compare(findChild(pane, "aiSourcePeekCount").text, "Full data kept · 1,234,567 rows")
        compare(findChild(pane, "aiSourcePeekHint").text, "Open the workspace window to browse all rows")
        verify(findChild(pane, "aiSourcePeekHint").color.a >= 0.76)
        verify(!findChild(pane, "aiCsvExplorerLoader").active && findChild(pane, "aiCsvExplorer") === null,
            "The 660 px peek card never instantiates the explorer")
        var withPeek = pane.chromeHeight
        csvMock.status = "registering"
        csvMock.progressRows = 5000
        wait(30)
        compare(findChild(pane, "aiSourcePeekCount").text, "Keeping full data · Counting… 5,000 rows so far")
        csvMock.status = "idle"
        wait(30)
        verify(!findChild(pane, "aiSourcePeek").visible, "No source, no card")
        verify(withPeek > pane.chromeHeight, "The peek count is part of the measured chrome")
        // No turn yet: the window cannot open, so the hint says what comes first.
        service.turns = []
        csvMock.status = "ready"
        wait(30)
        compare(findChild(pane, "aiSourcePeekHint").text,
            "Expand to browse all rows")
    }
    function test_explorerLivesInExpandedAndDetachedSurfacesOnly() {
        service.turns = [{id: 1, prompt: "Q", attachment: "", answer: "A", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        csvMock.sourceId = "src-0123456789abcdef"
        csvMock.meta = {rows: 90}
        csvMock.status = "ready"
        pane.expanded = true
        wait(30)
        var loader = findChild(pane, "aiCsvExplorerLoader")
        verify(loader.active, "Expanded surfaces host the explorer")
        var explorer = findChild(pane, "aiCsvExplorer")
        verify(explorer !== null && explorer.source === csvMock)
        verify(!findChild(pane, "aiSourcePeek").visible, "The peek summary steps aside")
        pane.expanded = false
        wait(30)
        verify(!loader.active, "Collapsing releases the explorer")
        pane.allowExpand = false
        wait(30)
        verify(loader.active, "The detached window (no Expand) hosts the explorer")
        csvMock.status = "idle"
        wait(30)
        verify(!loader.active, "No live source, no explorer instance")
    }
    function test_explorerIsReachableBeforeTheFirstTurn() {
        compare(service.turns.length, 0)
        csvMock.sourceId = "src-0123456789abcdef"
        csvMock.meta = {rows: 90}
        csvMock.status = "ready"
        wait(30)
        // Peek: only the count and the hint, and Expand is on offer without turns.
        verify(findChild(pane, "aiSourcePeek").visible)
        verify(!findChild(pane, "aiCsvExplorerHost").visible && findChild(pane, "aiCsvExplorer") === null,
            "The peek card never hosts the explorer")
        var expand = findChild(pane, "aiExpand")
        verify(expand.visible && expand.enabled, "Expand is available with a ready source and no turns")
        verify(findChild(pane, "aiMore").visible, "Source-only workspaces offer Rename and Duplicate through More")
        var peekChrome = pane.chromeHeight
        expandSpy.clear()
        mouseClick(expand, expand.width / 2, expand.height / 2)
        compare(expandSpy.count, 1)
        pane.expanded = true
        wait(60)
        var host = findChild(pane, "aiCsvExplorerHost")
        verify(host.visible, "Expanded: the explorer has its own host without a conversation")
        var explorer = findChild(pane, "aiCsvExplorer")
        verify(explorer !== null && explorer.source === csvMock)
        verify(!findChild(pane, "aiSourcePeek").visible)
        verify(!findChild(pane, "aiCsvExplorerLoader").active, "The in-conversation host stays off without turns")
        compare(pane.chromeHeight, peekChrome - findChild(pane, "aiSourcePeek").implicitHeight - pane.spacing
            + host.hostHeight + pane.spacing, "Chrome height accounts for the host instead of the peek card")
        // Detached surface (no Expand) behaves the same.
        pane.expanded = false
        pane.allowExpand = false
        wait(60)
        verify(findChild(pane, "aiCsvExplorerHost").visible && findChild(pane, "aiCsvExplorer") !== null)
        verify(!findChild(pane, "aiExpand").visible)
        // The first answer moves it into the conversation: exactly one instance.
        service.turns = [{id: 1, prompt: "Q", attachment: "", answer: "A", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(60)
        verify(!findChild(pane, "aiCsvExplorerHost").visible)
        verify(findChild(pane, "aiCsvExplorerLoader").active)
        verify(findChild(pane, "aiCsvExplorer") !== null)
        // Closing the source retires everything.
        service.turns = []
        csvMock.status = "idle"
        wait(60)
        verify(findChild(pane, "aiCsvExplorer") === null && !findChild(pane, "aiCsvExplorerHost").visible)
        verify(!findChild(pane, "aiExpand").visible, "No turns and no source: nothing to expand")
    }
    function test_explorerViewStateRoundTripsThroughTheService() {
        service.turns = [{id: 1, prompt: "Q", attachment: "", answer: "A", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        csvMock.sourceId = "src-0123456789abcdef"
        csvMock.meta = {rows: 90}
        csvMock.status = "ready"
        pane.expanded = true
        service.csvViews = {"src-0123456789abcdef": {sort: 2, dir: -1, filter: "oslo", page: 3}}
        wait(30)
        var explorer = findChild(pane, "aiCsvExplorer")
        verify(TestJson.equal(explorer.viewState, {sort: 2, dir: -1, filter: "oslo", page: 3}),
            "A restored state reaches the explorer")
        explorer.viewStateEdited({sort: 0, dir: 1, filter: "", page: 0})
        verify(TestJson.equal(service.csvViews["src-0123456789abcdef"],
            {sort: 0, dir: 1, filter: "", page: 0}), "Edits are written through the service under the source id")
        wait(30)
        verify(TestJson.equal(findChild(pane, "aiCsvExplorer").viewState, {sort: 0, dir: 1, filter: "", page: 0}))
    }
    function test_sourceNoticesAreStaticAndRefreshIsGated() {
        var base = pane.chromeHeight
        verify(!findChild(pane, "aiSourceNotices").visible)
        service.sourceNotice = "originChanged"
        service.sourceOrigin = "/scratch/u/rents.csv"
        wait(30)
        compare(findChild(pane, "aiSourceNotice").text, "Original file changed since this copy.")
        var refresh = findChild(pane, "aiSourceRefresh")
        verify(refresh.visible && refresh.enabled)
        verify(pane.chromeHeight > base, "Notices are part of the measured chrome")
        mouseClick(refresh, refresh.width / 2, refresh.height / 2)
        compare(service.refreshCalls, 1)
        service.canRefreshSource = false
        wait(30)
        verify(!findChild(pane, "aiSourceRefresh").enabled, "Busy disables Refresh")
        service.sourceOrigin = ""
        wait(30)
        verify(!findChild(pane, "aiSourceRefresh").visible, "Without a known original there is nothing to refresh")
        compare(findChild(pane, "aiSourceNotice").text,
            "Original file changed since this copy. Attach the file again to refresh.")
        service.sourceNotice = "originMissing"
        wait(30)
        compare(findChild(pane, "aiSourceNotice").text, "Original not found; using the saved copy.")
        service.sourceNotice = "copyMissing"
        wait(30)
        compare(findChild(pane, "aiSourceNotice").text, "Saved copy is missing; attach the file again.")
        service.sourceNotice = "<script>"
        wait(30)
        verify(!findChild(pane, "aiSourceNotice").visible, "Unknown notice codes render nothing")
        service.sourceNotice = ""
        service.sourceError = "Kept CSV copies already fill the 1 GiB limit, so this file was not copied."
        wait(30)
        compare(findChild(pane, "aiSourceError").text, service.sourceError)
        compare(findChild(pane, "aiSourceError").textFormat, Text.PlainText)
        service.sourceError = ""
        wait(30)
        verify(!findChild(pane, "aiSourceNotices").visible)
    }
    function test_restoringHintReflectsTheLoadState() {
        // While the lazy latest-workspace load is in flight the pane discloses
        // the restore instead of pretending the conversation is gone.
        var hidden = findChild(pane, "aiRestoring")
        verify(hidden === null || !hidden.visible, "The restoring hint must not show at rest")
        service.loadingLatest = true
        wait(20)
        var hint = findChild(pane, "aiRestoring")
        verify(hint !== null && hint.visible)
        service.loadingLatest = false
        wait(20)
        var settled = findChild(pane, "aiRestoring")
        verify(settled === null || !settled.visible, "Settled restores hide the hint")
    }
    function test_adaptiveDepthActionsAndSidecar() {
        // Learning answers offer prose-only depth controls; plain answers do
        // not; the sidecar renders only the stored explanation.
        service.turns = [{id: 11, prompt: "Scene", attachment: "", answer: "A", blocks: [
            {type: "diagram", title: "Scene", parts: []}],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        wait(30)
        var actions = findChild(pane, "aiDepthActions")
        verify(actions !== null && actions.visible, "learning answers show depth actions")
        service.lastExplain = ""
        // Task-first layouts give the diagram a work area. Focus reveals these
        // actions even when they are below the first viewport.
        findChild(pane, "aiDepthSimpler").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(service.lastExplain, "simpler")
        findChild(pane, "aiDepthDeeper").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(service.lastExplain, "deeper")
        findChild(pane, "aiDepthExample").forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(service.lastExplain, "example")
        service.turns = [{id: 12, prompt: "Plain", attachment: "", answer: "B", blocks: [],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        wait(30)
        compare(findChild(pane, "aiDepthActions").visible, false, "plain answers hide depth actions")
        service.turns = [{id: 13, prompt: "Deep", attachment: "", answer: "C", blocks: [
            {type: "steps", title: "Steps", steps: []}],
            suggestions: [], warning: "", error: "", status: "done",
            explanation: "Simpler: keep the overview; the loops come later."}]
        wait(30)
        verify(findChild(pane, "aiDepthText").visible)
        compare(findChild(pane, "aiDepthTextLabel").text,
            "Simpler: keep the overview; the loops come later.")
        service.turns = []
        wait(20)
    }
    function test_restoringHintContributesMeasuredWrappedChrome() {
        try {
            pane.width = 760
            service.loadingLatest = true
            wait(30)
            var hint = findChild(pane, "aiRestoring")
            verify(hint.visible && hint.height > 0)
            compare(pane.chromeHeight, hint.implicitHeight + pane.spacing)
            var wideHeight = pane.chromeHeight
            pane.width = 160
            wait(30)
            verify(hint.lineCount > 1, "The restoring status must wrap at narrow widths")
            compare(hint.height, hint.implicitHeight)
            verify(pane.chromeHeight > wideHeight, "Host sizing must include every restoring-status line")
            compare(pane.chromeHeight, hint.height + pane.spacing)
            service.loadingLatest = false
            wait(30)
            compare(pane.chromeHeight, 0)
        } finally {
            pane.width = 760
        }
    }
    function test_explorationTrailRendersPersistedInteractions() {
        // The trail line under a turn reflects its persisted uiStates map.
        service.checklistStates = ({})
        service.turns = [{id: 21, prompt: "Trail", attachment: "", answer: "A", blocks: [
            {type: "steps", title: "Steps", steps: []}],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = {"21": {"step:0": 2, "gallery:0:1": 1}}
        wait(30)
        var trail = findChild(pane, "aiTrail")
        verify(trail !== null)
        compare(trail.text, "Stepped through · 1 example replaced")
        service.turns = [{id: 22, prompt: "Clean", attachment: "", answer: "B", blocks: [],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = ({})
        wait(30)
        compare(findChild(pane, "aiTrail").visible, false, "untouched answers show no trail")
        service.turns = []
        wait(20)
    }
    function test_calcCountsAsLearningBlockForDepthActions() {
        // A calc is an interactive what-if object like a slider: the Simpler /
        // More depth / Another example actions apply to the latest answer that
        // has one, and the trail shows "Adjusted" only while an input differs
        // from its authored default.
        var calc = {type: "calc", title: "Trip cost", note: "", tables: [],
            inputs: [{id: "dist", label: "Distance", unit: "km", min: 0, max: 100, step: 1, value: 10, basis: "assumption"}],
            cells: [{id: "cost", label: "Cost", expression: "dist * 2", unit: "", decimals: 2}]}
        service.checklistStates = ({})
        service.turns = [{id: 31, prompt: "Cost", attachment: "", answer: "A", blocks: [calc],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = ({})
        wait(30)
        verify(findChild(pane, "aiDepthActions").visible, "a calc answer offers depth actions")
        compare(findChild(pane, "aiTrail").visible, false, "untouched calc shows no trail")
        service.uiStates = {"31": {"calc:0": {dist: {v: 40, u: "km"}}}}
        wait(30)
        compare(findChild(pane, "aiTrail").text, "Adjusted")
        // The row's blocks reach the helpers as QML V4 wrappers (Array.isArray is
        // false); the export must still compile and read the changed input.
        var wrapped = findChild(pane, "aiTrail").parent.modelData
        verify(!Array.isArray(wrapped.blocks), "the pane really passes wrapped blocks")
        var exported = AiState.textAnswer(wrapped, service.uiStates["31"])
        verify(exported.indexOf("Distance: 40 km (assumption)") >= 0 && exported.indexOf("Cost: 80.00") >= 0, exported)
        service.uiStates = {"31": {"calc:0": {dist: {v: 10, u: "km"}}}}
        wait(30)
        compare(findChild(pane, "aiTrail").visible, false, "restoring the default removes the label")
        service.turns = [{id: 32, prompt: "Hostile", attachment: "", answer: "B", blocks: [
            {type: "calc", title: "X", inputs: 5, cells: [null], tables: [7]}],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = {"32": {"calc:0": {dist: {v: 4}}, "calc:7": 3}}
        wait(30)
        compare(findChild(pane, "aiTrail").visible, false, "a hostile calc never invents a trail")
        service.turns = []
        service.uiStates = ({})
        wait(20)
    }
    function copyButton(item) {
        if (item.text === "Copy" && item.visible) return item
        for (var i = 0; i < item.children.length; ++i) {
            var found = copyButton(item.children[i])
            if (found) return found
        }
        return null
    }
    function test_emptyAnswerCalcCopyTurnRendersCopiesAndExports() {
        // A duplicated calculation is a done local turn with NO answer text: it
        // must show its prompt as the title, the calculator, depth actions, and
        // keep Copy/export working (nothing waits for text).
        var calc = {type: "calc", title: "Copy of Trip cost", note: "", tables: [],
            inputs: [{id: "dist", label: "Distance", unit: "km", min: 0, max: 100, step: 1, value: 10, basis: "assumption"}],
            cells: [{id: "cost", label: "Cost", expression: "dist * 2", unit: "", decimals: 2}]}
        service.turns = [{id: 41, prompt: "Copy of Trip cost", attachment: "", answer: "", blocks: [calc],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = ({})
        service.answerCopies = 0
        wait(30)
        compare(findChild(pane, "aiAnswerTitle").text, "Copy of Trip cost")
        compare(findChild(pane, "aiAnswerSummary").visible, false, "no answer text, no empty summary box")
        compare(findChild(pane, "aiAnswerPlaceholder").visible, false, "a done copy is never shown as preparing")
        verify(findChild(pane, "aiCalc") !== null && findChild(pane, "aiNativeBlocks_0").visible, "the calculator renders")
        verify(findChild(pane, "aiDepthActions").visible, "depth actions apply to the copy")
        var button = copyButton(pane)
        verify(button !== null && button.enabled, "Copy is offered for a blocks-only turn")
        mouseClick(button, button.width / 2, button.height / 2)
        compare(service.answerCopies, 1)
        var exported = AiState.textAnswer(findChild(pane, "aiTrail").parent.modelData, ({}))
        verify(exported.indexOf("Distance: 10 km") >= 0 && exported.indexOf("Cost: 20.00") >= 0, exported)
        service.turns = []
        wait(20)
    }
    function test_calcCopyAndDuplicateSignalsReachTheService() {
        var calc = {type: "calc", title: "Trip cost", note: "", tables: [],
            inputs: [{id: "dist", label: "Distance", unit: "km", min: 0, max: 100, step: 1, value: 10, basis: "assumption"}],
            cells: [{id: "cost", label: "Cost", expression: "dist * 2", unit: "", decimals: 2}]}
        service.turns = [{id: 42, prompt: "Cost", attachment: "", answer: "A", blocks: [calc],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = ({})
        service.copiedTexts = []
        service.duplicated = []
        wait(30)
        // AiBlocks -> AiAnswer -> AiPane -> service (independent of AiCalc).
        var blocks = findChild(pane, "aiNativeBlocks_0")
        verify(blocks !== null)
        blocks.copyTextRequested("Total: 20")
        blocks.duplicateCalcRequested({block: {type: "calc", title: "Copy of Trip cost"}, entry: {}})
        compare(service.copiedTexts, ["Total: 20"])
        compare(service.duplicated.length, 1)
        compare(service.duplicated[0].block.title, "Copy of Trip cost")
        service.turns = []
        wait(20)
    }
    function test_calcComponentSignalsAreForwarded() {
        var calc = {type: "calc", title: "Trip cost", note: "", tables: [],
            inputs: [{id: "dist", label: "Distance", unit: "km", min: 0, max: 100, step: 1, value: 10, basis: "assumption"}],
            cells: [{id: "cost", label: "Cost", expression: "dist * 2", unit: "", decimals: 2}]}
        service.turns = [{id: 43, prompt: "Cost", attachment: "", answer: "A", blocks: [calc],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        service.uiStates = ({})
        service.copiedTexts = []
        service.duplicated = []
        wait(30)
        var view = findChild(pane, "aiCalc")
        verify(view !== null)
        if (typeof view.copyRequested !== "function" || typeof view.duplicateRequested !== "function")
            skip("AiCalc does not declare copyRequested/duplicateRequested yet")
        view.copyRequested("Total: 20")
        view.duplicateRequested({block: {type: "calc", title: "Copy of Trip cost"}, entry: {_s: []}})
        compare(service.copiedTexts, ["Total: 20"])
        compare(service.duplicated.length, 1)
        compare(service.duplicated[0].block.title, "Copy of Trip cost")
        service.turns = []
        wait(20)
    }
    function test_depthSidecarMeasuresWrappedTextAndPadding() {
        var explanation = "Illustrative explanation: the overview stays readable as the answer narrows. ".repeat(16)
        service.turns = [{id: 14, prompt: "Depth", attachment: "", answer: "Overview", blocks: [],
            suggestions: [], warning: "", error: "", status: "done", explanation: explanation}]
        try {
            pane.width = 760
            wait(30)
            var box = findChild(pane, "aiDepthText")
            var label = findChild(pane, "aiDepthTextLabel")
            verify(box !== null && box.visible)
            verify(label.height > 0, "The explanation must have positive measured geometry")
            compare(label.height, label.implicitHeight)
            verify(label.lineCount > 1, "Long prose must wrap rather than overflow")
            compare(box.height, box.implicitHeight)
            compare(box.height, label.height + 2 * label.x)
            compare(label.y, label.x, "The existing padding stays equal on every side")
            compare(label.width, box.width - 2 * label.x)
            verify(pane.responseHeight >= box.parent.y + box.y + box.height,
                "The scroll content must include the entire explanation box")
            var wideHeight = box.height
            var wideResponseHeight = pane.responseHeight
            pane.width = 420
            wait(30)
            verify(box.height > wideHeight, "Narrow answers must grow to fit additional wrapped lines")
            compare(label.height, label.implicitHeight)
            compare(box.height, label.height + 2 * label.y)
            verify(pane.responseHeight > wideResponseHeight,
                "Wrapped sidecar height must reach the conversation measurement")
        } finally {
            pane.width = 760
        }
    }
    function test_collapsedHistoryDoesNotInstantiateHeavyAnswers() {
        // Older turns are heavyweight native trees (blocks, images). While
        // history is collapsed they must not exist at all; expanding and
        // collapsing must materialise and release them.
        service.turns = [
            {id: 1, prompt: "First", attachment: "", answer: "One", blocks: [
                {type: "checklist", title: "Older", items: ["A", "B"]}],
                suggestions: [], warning: "", error: "", status: "done"},
            {id: 2, prompt: "Second", attachment: "", answer: "Two", blocks: [],
                suggestions: [], warning: "", error: "", status: "done"}]
        wait(30)
        verify(findChild(pane, "aiCheck_0_0") === null, "Collapsed history must not instantiate older answer trees")
        verify(findChild(pane, "aiAnswerHero") !== null, "The latest answer always renders")
        pane.historyExpanded = true
        wait(30)
        verify(findChild(pane, "aiCheck_0_0") !== null, "Expanding history materialises the older answer")
        pane.historyExpanded = false
        wait(30)
        verify(findChild(pane, "aiCheck_0_0") === null, "Collapsing history releases the older answer tree")
        service.turns = []
        pane.historyExpanded = false
        wait(20)
    }
    function test_emptyAndNarrow() {
        pane.width = 420
        wait(20)
        verify(pane.height > 0)
        compare(pane.turnCount, 0)
        verify(pane.implicitHeight < 100, "Empty AI mode must remain compact, without onboarding copy")
        pane.width = 760
    }
    function test_answerAndCards() {
        service.turns = [{prompt: "An illustrative checklist fixture", attachment: "", answer: "Example answer",
            blocks: [{type: "checklist", title: "Example checklist", items: ["First", "Second"]}],
            suggestions: ["Explain the first item"], warning: "", error: "", status: "done"}]
        wait(20)
        compare(pane.turnCount, 1)
        verify(pane.latest.blocks.length === 1)
        pane.showText = true
        wait(20)
        verify(pane.showText)
    }
    function test_backgroundAndFailureStates() {
        service.busy = true
        service.turns = [{prompt: "Example", attachment: "", answer: "", blocks: [], suggestions: [],
            warning: "", error: "", status: "working"}]
        wait(20)
        service.busy = false
        service.turns = [{prompt: "Example", attachment: "", answer: "", blocks: [], suggestions: [],
            warning: "", error: "Illustrative offline error", status: "error"}]
        wait(20)
        compare(pane.latest.status, "error")
    }
    function test_sourceNavigationRequiresExplicitSignal() {
        handoffSpy.clear()
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Sourced answer", blocks: [
            {type: "sources", title: "Sources", items: [{label: "Example", url: "https://example.com"}]}],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        compare(service.lastSource, "", "Displaying a citation must not open the browser")
        compare(handoffSpy.count, 0)
        var blocks = findChild(pane, "aiNativeBlocks_0")
        verify(blocks !== null)
        blocks.openUrl("https://example.com")
        compare(service.lastSource, "https://example.com")
        compare(handoffSpy.count, 1, "Opening a source hands focus to the browser instead of leaving the launcher over it")
    }
    function test_imageUsesBrokerCacheRootThroughTheActualPane() {
        service.turns = [{id: 1, prompt: "Blue whale fixture", attachment: "", answer: "Illustrative answer", blocks: [
            {type: "image", title: "Whale", query: "Blue whale", error: "Illustrative unavailable image"}],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var image = findChild(pane, "aiImage")
        verify(image !== null)
        compare(image.mediaRoot, service.stateRoot + "/media")
        var url = "file:///tmp/opencode/media/ai-fixture.png"
        compare(image.validatedSource(url), url)
        compare(image.validatedSource("file:///etc/fixture.png"), "")
    }
    function test_responseHeightUsesRenderedRowsNotBlockCount() {
        var turn = {id: 1, prompt: "Compare", attachment: "", answer: "Summary", blocks: [
            {type: "table", title: "Options", columns: ["Option", "Tradeoff"], rows: [["Train", "Comfort"]]}],
            suggestions: [], warning: "", error: "", status: "done"}
        service.turns = [turn]
        wait(20)
        var shortHeight = pane.responseHeight
        turn.blocks[0].rows = [["Train", "Comfort"], ["Bus", "Cost"], ["Car", "Flexibility"], ["Bike", "Exercise"]]
        service.turns = [Object.assign({}, turn)]
        wait(20)
        verify(pane.responseHeight > shortHeight + 30, "More table rows must expand the response even with the same block count")
    }
    function test_retryRestoresAttachment() {
        service.turns = [{id: 1, prompt: "Explain this file", attachment: "/fixtures/test-home/example.txt", answer: "", blocks: [],
            suggestions: [], warning: "", error: "Offline fixture", status: "error"}]
        wait(20)
        var retry = findChild(pane, "retryAnswer")
        verify(retry !== null)
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(service.attachment, "/fixtures/test-home/example.txt")
    }
    function test_idleToolbarButtonsMeetTheQualifiedTextOpacity() {
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "Hello", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var newChat = findChild(pane, "aiNewChat")
        verify(newChat !== null && !newChat.hovered)
        // 0.80 is the opacity the plan qualifies at 4.5:1 on the opaque surface.
        verify(Math.abs(newChat.contentItem.color.a - 0.80) < 0.01, "idle text alpha " + newChat.contentItem.color.a)
    }
    function test_authFailureNamesTheFixAndKeepsRetry() {
        service.attachment = ""
        service.turns = [{id: 1, prompt: "Summarize this CSV", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error",
            error: "Codex could not complete the answer. Check authentication in the terminal."}]
        wait(20)
        compare(findChild(pane, "aiFailureHeadline").text, "Codex couldn't complete the answer")
        verify(findChild(pane, "aiFailureDetail").text.indexOf("usage limit") >= 0)
        var title = findChild(pane, "aiAnswerTitle")
        compare(title.text, "Summarize this CSV")
        verify(title.font.pixelSize < 20, "a failed turn must not shout its prompt as the display headline")
        compare(findChild(pane, "retryAnswer").text, "Try again")
        var signIn = findChild(pane, "aiSignIn")
        verify(signIn.visible)
        compare(signIn.text, "Sign in to Codex")
        verify(!signIn.primary && findChild(pane, "retryAnswer").primary, "an uncertain cause keeps Try again primary")
        mouseClick(signIn, signIn.width / 2, signIn.height / 2)
        compare(service.lastSignIn, "codex")
        verify(!signIn.enabled, "one terminal per click")
        service.lastSignIn = ""
        mouseClick(signIn, signIn.width / 2, signIn.height / 2)
        compare(service.lastSignIn, "", "a second click while launched is ignored")
    }
    function test_neverSignedInOffersSignInAsThePrimaryAction() {
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error", error: "Sign in to Codex before using launcher AI."}]
        wait(20)
        compare(findChild(pane, "aiFailureHeadline").text, "Sign in to Codex")
        verify(findChild(pane, "aiSignIn").primary)
        verify(!findChild(pane, "retryAnswer").primary)
    }
    function test_otherFailuresOfferNoSignIn() {
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error", error: "Offline fixture"}]
        wait(20)
        verify(!findChild(pane, "aiSignIn").visible)
        verify(findChild(pane, "retryAnswer").primary)
        // Hermes has no verified sign-in command, so it only gets the guidance.
        service.turns = [{id: 2, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error",
            error: "Hermes could not complete the answer. Check authentication in the terminal."}]
        wait(20)
        compare(findChild(pane, "aiFailureHeadline").text, "Hermes couldn't complete the answer")
        verify(!findChild(pane, "aiSignIn").visible)
    }
    function test_missingFileRetryDropsTheAttachment() {
        service.turns = [{id: 1, prompt: "Explain this file", attachment: "/fixtures/test-home/gone.csv", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error",
            error: "Attachment is unavailable or is a symbolic link."}]
        wait(20)
        compare(findChild(pane, "aiFailureHeadline").text, "That file isn't available")
        var retry = findChild(pane, "retryAnswer")
        compare(retry.text, "Try again without the file")
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(service.attachment, "", "the vanished file must not be re-attached")
    }
    function test_fallbackAgentIsDisclosedOnTheLatestTurn() {
        service.agent = "codex"
        service.defaultAgent = "claude"
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "Hello", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var note = findChild(pane, "aiAgentFallbackNote")
        verify(note.visible)
        compare(note.text, "Answered by Codex: the launcher doesn't support claude yet.")
        service.defaultAgent = "codex"
        wait(20)
        verify(!findChild(pane, "aiAgentFallbackNote").visible, "no note when the default is the agent in use")
        // A later default change must not leave a pinned conversation silent.
        service.defaultAgent = "hermes"
        wait(20)
        compare(findChild(pane, "aiAgentFallbackNote").text,
                "This conversation uses Codex; your default is Hermes. Start a new chat to switch.")
        // A failed turn was not "answered by" anyone.
        service.defaultAgent = "claude"
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error", error: "Offline fixture"}]
        wait(20)
        verify(!findChild(pane, "aiAgentFallbackNote").visible, "no 'Answered by' under a failed turn")
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "working", error: ""}]
        wait(20)
        verify(!findChild(pane, "aiAgentFallbackNote").visible, "nor while still working")
        service.defaultAgent = "codex"
    }
    function test_newChatKeepsTheNextOpenInAiMode() {
        service.resumeOnOpen = false
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "Hello", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var newChat = findChild(pane, "aiNewChat")
        mouseClick(newChat, newChat.width / 2, newChat.height / 2)
        verify(service.resumeOnOpen, "New chat leaves the person in AI mode, so the next open resumes it")
    }
    function test_retryNeverClobbersNewerInput() {
        service.attachment = "/fixtures/test-home/newer.txt"
        service.draft = "Something I already started typing"
        service.turns = [{id: 1, prompt: "Old failed prompt", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error", error: "Offline fixture"}]
        wait(20)
        var retry = findChild(pane, "retryAnswer")
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(service.attachment, "/fixtures/test-home/newer.txt", "a newer attachment survives Try again")
        verify(service.draft === "Something I already started typing", "a started draft survives Try again")
        service.attachment = ""
        service.draft = ""
    }
    function test_unknownFailureKeepsRawMessage() {
        service.turns = [{id: 1, prompt: "Hi", attachment: "", answer: "", blocks: [],
            suggestions: [], warning: "", status: "error", error: "Offline fixture"}]
        wait(20)
        compare(findChild(pane, "aiFailureHeadline").text, "Couldn't get an answer")
        compare(findChild(pane, "aiFailureDetail").text, "Offline fixture")
    }
    function test_checklistAndPresentationSurviveFollowup() {
        var first = {id: 1, prompt: "List", attachment: "", answer: "Example", blocks: [
            {type: "checklist", title: "Fixture", items: ["One"]}], suggestions: [], warning: "", error: "", status: "done"}
        service.turns = [first]
        wait(20)
        var check = findChild(pane, "aiCheck_0_0")
        var answer = findChild(pane, "aiAnswerHero").parent
        compare(answer.answerBlocks.length, 1, "ListModel role sequences must render like ordinary arrays")
        verify(check !== null)
        mouseClick(check, check.width / 2, check.height / 2)
        verify(check.checked)
        check.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Return)
        verify(!check.checked)
        compare(service.checklistStates["1"]["0:0"], false)
        keyClick(Qt.Key_Return)
        compare(service.checklistStates["1"]["0:0"], true, "Enter toggles must be saved before delegate recreation")
        pane.showText = true
        service.turns = [first, {id: 2, prompt: "Follow-up", attachment: "", answer: "Second", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        verify(!pane.showText, "New responses must automatically render native interfaces")
        pane.historyExpanded = true
        wait(20)
        check = findChild(pane, "aiCheck_0_0")
        verify(check.checked, "Checklist state must survive model recreation and follow-ups")
        pane.showText = true
        wait(20)
        verify(check.visible, "Showing latest response as text must not hide earlier native cards")
    }
    function test_moreMenuDisclosesSecondaryActions() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Example", blocks: [
            {type: "text", title: "", text: "Fixture body"}], suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var more = findChild(pane, "aiMore")
        mouseClick(more, more.width / 2, more.height / 2)
        var menu = findChild(pane, "aiMoreMenu")
        tryCompare(menu, "opened", true)
        compare(menu.count, 5)
        var action = menu.itemAt(0)
        verify(action !== null)
        compare(action.text, "Show as text")
        compare(menu.itemAt(1).text, "Open in window")
        compare(menu.itemAt(2).text, "Continue in terminal")
        compare(menu.itemAt(3).text, "Rename…")
        compare(menu.itemAt(4).text, "Duplicate…")
        windowSpy.clear()
        menu.itemAt(1).triggered()
        compare(windowSpy.count, 1, "Open in window is an explicit action")
        tryCompare(menu, "opened", false)
        // Escape on a freshly opened menu closes only the menu.
        mouseClick(more, more.width / 2, more.height / 2)
        tryCompare(menu, "opened", true)
        hideSpy.clear()
        keyClick(Qt.Key_Escape)
        tryCompare(menu, "opened", false)
        compare(hideSpy.count, 0, "Escape should close the menu before hiding the launcher")
    }
    function workspaceFixture() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Example", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(30)
    }
    function openWorkspacePopup(index) {
        var more = findChild(pane, "aiMore")
        mouseClick(more, more.width / 2, more.height / 2)
        var menu = findChild(pane, "aiMoreMenu")
        tryCompare(menu, "opened", true)
        verify(menu.itemAt(index).enabled)
        mouseClick(menu.itemAt(index), 10, 10)
        var popup = findChild(pane, "aiWorkspacePopup")
        tryCompare(popup, "opened", true)
        tryCompare(findChild(pane, "aiWorkspaceName"), "activeFocus", true)
        return popup
    }
    function test_workspaceRenameSaveIsExplicitAndAcceptedAsynchronously() {
        workspaceFixture()
        service.workspaceDisplayTitle = "Renamed illustrative workspace"
        var beforeChrome = pane.chromeHeight
        var popup = openWorkspacePopup(3)
        compare(popup.width, 420, "Wide panes keep the editor small")
        var field = findChild(pane, "aiWorkspaceName")
        compare(field.text, service.workspaceDisplayTitle)
        compare(findChild(pane, "aiWorkspacePopupTitle").text, "Rename workspace")
        compare(findChild(pane, "aiWorkspaceConfirm").text, "Save")
        verify(!findChild(pane, "aiWorkspaceDuplicateNote").visible)
        compare(field.selectedText, field.text, "The prefill is selected for immediate replacement")
        compare(service.lastRename, "", "Opening the form never writes")
        compare(pane.chromeHeight, beforeChrome, "The form adds no permanent peek chrome")
        field.text = "  My reusable workspace  "
        var save = findChild(pane, "aiWorkspaceConfirm")
        mouseClick(save, save.width / 2, save.height / 2)
        compare(service.lastRename, "My reusable workspace")
        compare(service.lastDuplicate, "")
        tryCompare(popup, "opened", false)
        tryCompare(findChild(pane, "aiMore"), "activeFocus", true)
        verify(service.workspaceActionPending, "Accepted does not mean completed")
        verify(!findChild(pane, "aiNewChat").enabled, "Pending writes gate New chat")
        mouseClick(findChild(pane, "aiNewChat"), 10, 10)
        compare(service.turns.length, 1, "A pending write cannot be interrupted by New chat")
        verify(findChild(pane, "aiWorkspacePending").visible)
        compare(findChild(pane, "aiWorkspacePending").text, "Updating workspace…")
        compare(service.workspaceDisplayTitle, "Renamed illustrative workspace", "UI never changes service state optimistically")
    }
    function test_workspaceDuplicateExplainsCSVAndUsesCopyDefault() {
        readySource()
        service.workspaceDisplayTitle = "Illustrative CSV workspace"
        wait(30)
        verify(findChild(pane, "aiMore").visible, "More is reachable before the first answer")
        var popup = openWorkspacePopup(4)
        var menu = findChild(pane, "aiMoreMenu")
        verify(!menu.itemAt(0).enabled && !menu.itemAt(1).enabled && !menu.itemAt(2).enabled,
            "Original answer-dependent actions keep their original indexes and gates")
        var field = findChild(pane, "aiWorkspaceName")
        compare(field.text, AiState.copyWorkspaceName(service.workspaceDisplayTitle))
        var note = findChild(pane, "aiWorkspaceDuplicateNote")
        verify(note.visible && note.color.a >= 0.76)
        compare(note.text, "Copies answers and inputs. Starts a fresh AI conversation. Kept CSV stays with the original.")
        compare(note.textFormat, Text.PlainText)
        compare(findChild(pane, "aiWorkspaceConfirm").text, "Duplicate")
        keyClick(Qt.Key_Return)
        compare(service.lastDuplicate, AiState.copyWorkspaceName(service.workspaceDisplayTitle))
        compare(service.lastRename, "")
        tryCompare(popup, "opened", false)
        tryCompare(findChild(pane, "aiMore"), "activeFocus", true)
        compare(csvMock.status, "ready", "The UI leaves the original CSV resource alone")
        compare(service.turns.length, 0, "No provider request or conversation is generated by the UI")
    }
    function test_workspacePopupCancelAndEscapeReturnFocusWithoutHiding() {
        workspaceFixture()
        var popup = openWorkspacePopup(3)
        findChild(pane, "aiWorkspaceName").text = "Discarded name"
        var cancel = findChild(pane, "aiWorkspaceCancel")
        mouseClick(cancel, cancel.width / 2, cancel.height / 2)
        tryCompare(popup, "opened", false)
        tryCompare(findChild(pane, "aiMore"), "activeFocus", true)
        compare(service.lastRename, "")
        popup = openWorkspacePopup(4)
        hideSpy.clear()
        keyClick(Qt.Key_Escape)
        tryCompare(popup, "opened", false)
        compare(hideSpy.count, 0, "Escape cancels the popup, not the pane")
        tryCompare(findChild(pane, "aiMore"), "activeFocus", true)
        compare(service.lastDuplicate, "")
        openWorkspacePopup(3)
        compare(findChild(pane, "aiWorkspaceName").text, service.workspaceDisplayTitle,
            "Cancelled drafts never leak into the next form")
    }
    function test_workspaceNameValidationGatesSaveAndBothEnterKeys() {
        workspaceFixture()
        var popup = openWorkspacePopup(3)
        var field = findChild(pane, "aiWorkspaceName")
        var save = findChild(pane, "aiWorkspaceConfirm")
        var invalid = ["", "   ", "x".repeat(97), "a\u0001b", "a\u0085b", "a\u202eb", "a\ud800b"]
        for (var i = 0; i < invalid.length; ++i) {
            field.text = invalid[i]
            verify(!save.enabled, "Invalid name " + i + " cannot be saved")
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Enter)
            compare(service.lastRename, "")
            verify(popup.opened)
        }
        field.text = "x".repeat(96)
        verify(save.enabled, "96 JS units is a valid boundary")
        keyClick(Qt.Key_Enter)
        compare(service.lastRename, "x".repeat(96))
        tryCompare(popup, "opened", false)
    }
    function test_workspaceManagementGatesAreRecheckedWithTheFormOpen() {
        workspaceFixture()
        var popup = openWorkspacePopup(3)
        var field = findChild(pane, "aiWorkspaceName")
        var save = findChild(pane, "aiWorkspaceConfirm")
        var menu = findChild(pane, "aiMoreMenu")
        var gates = ["busy", "loadingLatest", "stopping", "workspaceActionPending", "keepPhase", "workspaceReady"]
        for (var i = 0; i < gates.length; ++i) {
            var gate = gates[i]
            service[gate] = gate === "keepPhase" ? "registering" : gate !== "workspaceReady"
            verify(!save.enabled)
            verify(!menu.itemAt(3).enabled && !menu.itemAt(4).enabled)
            field.forceActiveFocus()
            keyClick(Qt.Key_Return)
            compare(service.lastRename, "", "A gate changing after opening blocks confirmation")
            verify(popup.opened)
            service[gate] = gate === "keepPhase" ? "" : gate === "workspaceReady"
            verify(save.enabled)
        }
        service.workspaceActionAccepted = false
        field.text = "Rejected illustrative name"
        keyClick(Qt.Key_Return)
        compare(service.lastRename, "Rejected illustrative name")
        verify(popup.opened, "A rejected request keeps the form for correction")
        verify(!service.workspaceActionPending)
    }
    function test_workspaceFeedbackIsStaticWrappedAndMeasuredOnlyWhenPresent() {
        workspaceFixture()
        var baseline = pane.chromeHeight
        var status = findChild(pane, "aiWorkspaceStatus")
        verify(!status.visible)
        service.workspaceActionError = "Couldn't duplicate this workspace. <b>Try again.</b>"
        wait(30)
        var error = findChild(pane, "aiWorkspaceError")
        verify(error.visible)
        compare(error.text, service.workspaceActionError)
        compare(error.textFormat, Text.PlainText)
        compare(pane.chromeHeight, baseline + status.implicitHeight + pane.spacing)
        pane.width = 260
        wait(30)
        verify(error.lineCount > 1 && error.height === error.implicitHeight)
        service.workspaceActionError = ""
        pane.width = 760
        wait(30)
        compare(pane.chromeHeight, baseline)
        verify(!status.visible)
    }
    function test_workspacePopupFitsNarrowPaneAndLongCopyDefault() {
        workspaceFixture()
        service.workspaceDisplayTitle = "x".repeat(96)
        pane.width = 320
        var baseline = pane.chromeHeight
        var popup = openWorkspacePopup(4)
        var field = findChild(pane, "aiWorkspaceName")
        var note = findChild(pane, "aiWorkspaceDuplicateNote")
        tryVerify(function() { return note.lineCount > 1 && Math.abs(note.height - note.implicitHeight) < 1 },
            1000, "Wrapped disclosure is fully measured")
        verify(popup.width <= 420 && popup.width <= pane.width)
        verify(popup.x >= 0 && popup.x + popup.width <= popup.parent.width)
        verify(popup.y >= 0 && popup.y + popup.height <= popup.parent.height)
        verify(field.width > 0 && field.width <= popup.availableWidth)
        verify(note.width <= popup.availableWidth)
        verify(field.text.length <= 96 && AiState.workspaceName(field.text).length > 0)
        verify(findChild(pane, "aiWorkspaceConfirm").enabled)
        compare(pane.chromeHeight, baseline, "A popup never becomes pane chrome")
    }
    function test_workspaceToolsAreSafeWithAnOlderService() {
        workspaceFixture()
        var legacy = {latest: service.latest, turns: service.turns, turnModel: turnModel,
            busy: false, loadingLatest: false, attachment: "", canContinue: false,
            agent: "codex", defaultAgent: "codex"}
        try {
            pane.service = legacy
            wait(30)
            var more = findChild(pane, "aiMore")
            mouseClick(more, more.width / 2, more.height / 2)
            var menu = findChild(pane, "aiMoreMenu")
            tryCompare(menu, "opened", true)
            compare(menu.count, 5)
            verify(!menu.itemAt(3).enabled && !menu.itemAt(4).enabled)
            verify(!findChild(pane, "aiWorkspaceStatus").visible)
            pane.openWorkspaceAction(false)
            verify(!findChild(pane, "aiWorkspacePopup").visible)
            menu.close()
        } finally {
            pane.service = service
        }
    }
    function test_workspaceFormIsInvalidatedBySharedWorkspaceSwitch() {
        workspaceFixture()
        service.workspaceId = "ws-original"
        var popup = openWorkspacePopup(3)
        findChild(pane, "aiWorkspaceName").text = "Stale form name"
        service.workspaceId = "ws-other"
        tryCompare(popup, "opened", false)
        keyClick(Qt.Key_Return)
        compare(service.lastRename, "")
        popup = openWorkspacePopup(4)
        service.workspaceId = "ws-third"
        tryCompare(popup, "opened", false)
        compare(service.lastDuplicate, "")
        service.workspaceId = "ws-fixture"
    }
    function test_namedEmptyWorkspaceKeepsManagementReachable() {
        service.workspaceName = "Empty saved tool"
        service.workspaceDisplayTitle = service.workspaceName
        wait(30)
        verify(findChild(pane, "aiMore").visible)
        var popup = openWorkspacePopup(3)
        compare(findChild(pane, "aiWorkspaceName").text, "Empty saved tool")
        popup.close()
        service.workspaceTransitionPending = true
        verify(!pane.enabled, "Final hydration freezes the outgoing controls")
        service.workspaceTransitionPending = false
    }
    function test_newChatIsADirectReachableAction() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Example", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        var action = findChild(pane, "aiNewChat")
        verify(action !== null && action.visible)
        mouseClick(action, action.width / 2, action.height / 2)
        compare(service.turns.length, 0)
    }
    function test_expandTogglesTheExploreSurface() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Example", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(20)
        expandSpy.clear()
        var expand = findChild(pane, "aiExpand")
        verify(expand !== null && expand.visible)
        compare(expand.text, "Expand")
        mouseClick(expand, expand.width / 2, expand.height / 2)
        compare(expandSpy.count, 1, "Expand is an explicit user action")
        pane.expanded = true
        compare(expand.text, "Collapse")
        pane.expanded = false
        compare(expand.text, "Expand")
    }
    function test_hostFlagsHideUnavailableSurfaceActions() {
        service.turns = [{id: 33, prompt: "Fixture", attachment: "", answer: "Example", blocks: [],
            suggestions: [], warning: "", error: "", status: "done"}]
        try {
            pane.allowExpand = false
            pane.allowOpenWindow = false
            wait(30)
            verify(!findChild(pane, "aiExpand").visible, "Detached hosts must not offer a dead Expand action")
            var more = findChild(pane, "aiMore")
            mouseClick(more, more.width / 2, more.height / 2)
            var menu = findChild(pane, "aiMoreMenu")
            tryCompare(menu, "opened", true)
            verify(!menu.itemAt(1).visible, "Detached hosts must not offer Open in window again")
            compare(menu.itemAt(0).text, "Show as text")
            compare(menu.itemAt(2).text, "Continue in terminal", "Hiding an action must not remap its neighbours")
            menu.close()
            tryCompare(menu, "opened", false)
            pane.allowExpand = true
            pane.allowOpenWindow = true
            wait(30)
            verify(findChild(pane, "aiExpand").visible)
            mouseClick(more, more.width / 2, more.height / 2)
            tryCompare(menu, "opened", true)
            verify(menu.itemAt(1).visible)
            menu.close()
            tryCompare(menu, "opened", false)
        } finally {
            pane.allowExpand = true
            pane.allowOpenWindow = true
        }
    }
    function test_galleryCellsEnterTheKeyboardChain() {
        // A keyboard user must be able to reach a gallery example itself
        // (viewer) and its replacement control — not only the toolbar.
        // This tiny in-tree raster makes the ready-image keyboard test
        // reproducible without a previously generated scratch PNG.
        service.stateRoot = decodeURIComponent(Qt.resolvedUrl("fixtures").toString().replace(/^file:\/\//, ""))
        var fixtureUrl = Qt.resolvedUrl("fixtures/media/gallery.png").toString()
        service.turns = [{id: 31, prompt: "Gallery", attachment: "", answer: "A", blocks: [
            {type: "gallery", title: "Styles", items: [
                {query: "Gothic", caption: "Pointed", error: "",
                  imageUrl: fixtureUrl,
                 attribution: "A · CC0", sourceUrl: "https://example.com/a",
                  alternatives: [{imageUrl: fixtureUrl,
                                 attribution: "B · CC0", sourceUrl: "https://example.com/b"}]}]}],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(30)
        var gallery = findChild(pane, "aiGallery")
        verify(gallery !== null)
        var image = findChild(gallery, "aiImage")
        verify(image !== null)
        tryCompare(image, "imageReady", true)
        var frame = findChild(gallery, "aiImageFrame")
        verify(frame !== null)
        var more = findChild(pane, "aiMore")
        more.forceActiveFocus(Qt.TabFocusReason)
        var reachedFrame = frame.activeFocus
        for (var i = 0; i < 24 && !reachedFrame; ++i) {
            keyClick(Qt.Key_Tab)
            reachedFrame = frame.activeFocus
        }
        verify(reachedFrame, "Tab traversal must reach a gallery example")
        var next = findChild(gallery, "aiImageNext")
        var reachedNext = next.activeFocus
        for (var j = 0; j < 24 && !reachedNext; ++j) {
            keyClick(Qt.Key_Tab)
            reachedNext = next.activeFocus
        }
        verify(reachedNext, "Tab traversal must reach the example's replacement control")
        service.turns = []
        wait(20)
    }
    function test_keyboardTabReachesAnswerContent() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Readable summary",
            blocks: [{type: "steps", title: "Stages", steps: [
                {label: "One", detail: ""}, {label: "Two", detail: ""}]}],
            suggestions: [], warning: "", error: "", status: "done"}]
        wait(30)
        var step = findChild(pane, "aiStep_0_0")
        verify(step !== null && step.visible)
        var more = findChild(pane, "aiMore")
        more.forceActiveFocus(Qt.TabFocusReason)
        windowSpy.clear()
        var reached = step.activeFocus
        for (var i = 0; i < 24 && !reached; ++i) {
            keyClick(Qt.Key_Tab)
            reached = step.activeFocus
        }
        verify(reached, "Tab traversal must reach interactive answer blocks, not only the toolbar")
        compare(windowSpy.count, 0, "Tab must never activate a destructive or context-changing action")
    }
    function test_keyboardFocusScrollsLongChecklistIntoView() {
        var items = []
        for (var i = 0; i < 40; ++i) items.push("Illustrative checklist item " + (i + 1))
        service.turns = [{id: 32, prompt: "Checklist", attachment: "", answer: "Overview",
            blocks: [{type: "checklist", title: "Long checklist", items: items}],
            suggestions: [], warning: "", error: "", status: "done"}]
        try {
            pane.height = 260
            wait(30)
            var first = findChild(pane, "aiCheck_0_0")
            var last = findChild(pane, "aiCheck_0_39")
            verify(first !== null && last !== null)
            first.forceActiveFocus(Qt.TabFocusReason)
            for (var j = 0; j < 40 && !last.activeFocus; ++j) keyClick(Qt.Key_Tab)
            verify(last.activeFocus, "Actual Tab traversal must focus the final checkbox")
            var viewport = last.parent
            while (viewport && viewport.contentY === undefined) viewport = viewport.parent
            verify(viewport !== null, "The checklist belongs to the conversation's Flickable")
            tryVerify(function() {
                var top = last.mapToItem(viewport, 0, 0).y
                return viewport.contentY > 0 && top >= 0 && top + last.height <= viewport.height
            }, 1000, "The focused checkbox must lie inside the actual clipped viewport")
            verify(viewport.contentY <= Math.max(0, viewport.contentHeight - viewport.height),
                "Focus scrolling must stay within content bounds")
            var scrolledY = viewport.contentY
            findChild(pane, "aiMore").forceActiveFocus(Qt.TabFocusReason)
            wait(30)
            compare(viewport.contentY, scrolledY, "Toolbar focus must not reset the conversation's scroll position")
        } finally {
            pane.height = 620
        }
    }
    function test_contextualSuggestionsFillTheComposer() {
        service.turns = [{id: 1, prompt: "Fixture", attachment: "", answer: "Example",
            blocks: [], suggestions: ["Explain the tilt", "Show another example"],
            warning: "", error: "", status: "done"}]
        wait(30)
        var chips = findChild(pane, "aiSuggestions")
        verify(chips !== null && chips.visible)
        fillSpy.clear()
        var chip = findChild(pane, "aiSuggestion_0")
        verify(chip !== null && chip.visible)
        compare(chip.text, "Explain the tilt")
        mouseClick(chip, chip.width / 2, chip.height / 2)
        compare(fillSpy.count, 1, "choosing a suggestion fills the composer without sending")
        compare(fillSpy.signalArguments[0][0], "Explain the tilt")
        compare(service.turns.length, 1, "suggestions never generate on their own")
        // Older turns keep their history but do not show stale suggestion chips.
        service.turns = [
            {id: 1, prompt: "Old", attachment: "", answer: "Old", blocks: [],
             suggestions: ["Stale"], warning: "", error: "", status: "done"},
            {id: 2, prompt: "New", attachment: "", answer: "New", blocks: [],
             suggestions: [], warning: "", error: "", status: "done"}]
        wait(30)
        var staleChip = findChild(pane, "aiSuggestion_0")
        verify(staleChip === null || !staleChip.visible,
            "only the latest turn offers suggestions")
    }

    // Honest waiting: the real phase, an elapsed counter from 3 s, and an
    // accessible name that changes per phase or per 5 s, never at 1 Hz. The
    // pane owns no timer: `workElapsed` comes from the shared service.
    function test_waitingShowsRealPhaseThenElapsedAndThrottlesTheName() {
        var row = findChild(pane, "aiActivityText")
        compare(row.visible, false, "no activity text while idle")
        service.activity = "Searching the web\u2026"
        service.workElapsed = 0
        service.busy = true
        wait(20)
        compare(row.visible, true)
        compare(row.text, "Searching the web\u2026")
        compare(row.Accessible.name, "Working, searching the web")
        service.workElapsed = 2
        wait(5)
        compare(row.text, "Searching the web\u2026", "no counter before 3 s")
        service.workElapsed = 3
        wait(5)
        compare(row.text, "Searching the web\u2026 \u00b7 3 s", "the counter appears at 3 s")
        compare(row.Accessible.name, "Working, searching the web", "the name is not updated every second")
        service.workElapsed = 4
        wait(5)
        compare(row.Accessible.name, "Working, searching the web")
        service.workElapsed = 5
        wait(5)
        compare(row.Accessible.name, "Working, 5 seconds, searching the web")
        service.workElapsed = 9
        wait(5)
        compare(row.text, "Searching the web\u2026 \u00b7 9 s", "the visible counter still moves each second")
        compare(row.Accessible.name, "Working, 5 seconds, searching the web")
        service.workElapsed = 12
        wait(5)
        compare(row.Accessible.name, "Working, 12 seconds, searching the web")
        // A real phase change is announced at once; contrast stays above the floor.
        service.activity = "Loading visuals\u2026"
        wait(5)
        compare(row.Accessible.name, "Working, 12 seconds, loading visuals")
        verify(row.color.a >= 0.76, "the waiting text keeps the 0.76 contrast floor")
        service.busy = false
        wait(20)
        compare(row.visible, false, "the row disappears when work ends")
        compare(row.Accessible.name, "Working", "no stale phase is left behind")
        service.busy = true
        service.workElapsed = 0
        service.activity = "Thinking\u2026"
        wait(20)
        compare(row.Accessible.name, "Working, thinking", "a new turn starts from a fresh announcement")
    }
    function test_waitingTextIsPlainBoundedAndNeverGuessesAMedium() {
        service.busy = true
        service.workElapsed = 0
        service.activity = "<b>Drawing a chart</b>\u2026 ".repeat(5)
        wait(20)
        var row = findChild(pane, "aiActivityText")
        compare(row.textFormat, Text.PlainText)
        verify(row.text.length <= 40 + 1 + 6, "the phase is bounded: " + row.text.length)
        service.activity = ""
        wait(5)
        compare(row.text, "Thinking\u2026", "an empty phase reads as Thinking, never as a medium")
    }

    // ---- forms ----------------------------------------------------------------
    function formBlock() {
        return {type: "form", title: "Trip details", submitLabel: "Send answers", note: "Used to plan.", fields: [
            {id: "budget", label: "Budget", kind: "number", unit: "EUR", min: 100, max: 5000, step: 50, value: 1000, options: [], placeholder: ""},
            {id: "style", label: "Travel style", kind: "choice", unit: "", min: 0, max: 0, step: 0, value: 1,
                options: ["Relaxed", "Balanced", "Packed"], placeholder: ""}]}
    }
    function formTurn(id, extra) {
        return Object.assign({id: id, prompt: "Plan a trip", attachment: "", answer: "Tell me a little more.",
            blocks: [formBlock()], suggestions: [], warning: "", error: "", status: "done", explanation: ""}, extra || {})
    }
    function resetFormService() {
        service.submittedForms = []
        service.submittedChoices = []; service.focusRequests = []; service.choiceAdvances = false
        service.busy = false; service.stopping = false; service.loadingLatest = false
        service.workspaceActionPending = false; service.workspaceTransitionPending = false
        service.agent = "codex"; service.defaultAgent = "codex"
        service.uiStates = ({})
        pane.historyExpanded = false
    }
    function test_formSubmitReachesTheServiceFromTheLatestAnswer() {
        resetFormService()
        service.turns = [formTurn(51)]
        service.uiStates = {"51": {"form:0": {v: {budget: 1800}, sent: false}}}
        wait(30)
        var submit = findChild(pane, "aiFormSubmit")
        verify(submit !== null && submit.visible, "the form renders in the answer")
        compare(submit.text, "Send answers")
        compare(submit.enabled, true)
        compare(findChild(pane, "aiFormInput_0").text, "1800", "the stored draft is shown")
        mouseClick(submit, submit.width / 2, submit.height / 2)
        tryCompare(service, "submittedForms", [[51, 0]])
        verify(findChild(pane, "aiDepthActions").visible === false, "a form is not a learning block")
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_sendingAFormTearsItsRowDownSafely() {
        resetFormService()
        service.formAdvances = true
        service.turns = [formTurn(70)]
        wait(30)
        var submit = findChild(pane, "aiFormSubmit")
        mouseClick(submit, submit.width / 2, submit.height / 2)
        tryCompare(service, "submittedForms", [[70, 0]])
        wait(60)
        compare(service.turns.length, 2)
        compare(findChild(pane, "aiAnswerFormSent").text, "Budget: 1000 EUR", "the new turn lists what was sent")
        verify(service.busy, "the service is working on the answer")
        service.formAdvances = false
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_formGateFollowsTheServiceState() {
        resetFormService()
        service.turns = [formTurn(52)]
        wait(30)
        var submit = findChild(pane, "aiFormSubmit")
        var hint = findChild(pane, "aiFormHint")
        compare(submit.enabled, true)
        var gates = [["busy", "Wait for the current answer to finish."], ["stopping", "Wait for the current answer to finish."],
            ["loadingLatest", "Wait for the current answer to finish."], ["workspaceActionPending", "Wait for the current answer to finish."],
            ["workspaceTransitionPending", "Wait for the current answer to finish."]]
        for (var i = 0; i < gates.length; ++i) {
            service[gates[i][0]] = true
            wait(10)
            compare(findChild(pane, "aiFormSubmit").enabled, false, gates[i][0] + " closes the form")
            compare(hint.text, gates[i][1], gates[i][0] + " says why")
            service[gates[i][0]] = false
            wait(10)
            compare(findChild(pane, "aiFormSubmit").enabled, true, gates[i][0] + " reopens it")
        }
        service.agent = ""; service.defaultAgent = ""
        wait(10)
        compare(findChild(pane, "aiFormSubmit").enabled, false)
        compare(hint.text, "Choose an AI agent in Omarchy first.")
        service.agent = "codex"; service.defaultAgent = "codex"
        wait(10)
        // A turn that is not done cannot send its form.
        service.turns = [formTurn(52, {status: "working"})]
        wait(30)
        compare(findChild(pane, "aiFormSubmit").enabled, false)
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_onlyTheLatestAnswersFormCanBeSent() {
        resetFormService()
        service.turns = [formTurn(53), {id: 54, prompt: "Next", attachment: "", answer: "Later answer", blocks: [],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}]
        pane.historyExpanded = true
        wait(50)
        var submit = findChild(pane, "aiFormSubmit")
        verify(submit !== null, "history expanded shows the earlier form")
        compare(submit.enabled, false)
        compare(findChild(pane, "aiFormHint").text, "Only the latest answer's form can be sent.")
        mouseClick(submit, 5, 5)
        wait(30)
        compare(service.submittedForms.length, 0)
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_sentFormShowsSentMarkerAndAnsweredTrail() {
        resetFormService()
        service.turns = [formTurn(55)]
        service.uiStates = {"55": {"form:0": {v: {budget: 1800, style: 2}, sent: true}}}
        wait(30)
        compare(findChild(pane, "aiFormSent").visible, true)
        compare(findChild(pane, "aiFormSentLine_0").text, "Budget: 1800 EUR")
        compare(findChild(pane, "aiFormSentLine_1").text, "Travel style: Packed")
        compare(findChild(pane, "aiTrail").text, "Answered")
        compare(findChild(pane, "aiFormChange").enabled, true)
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_formAnswerTurnListsWhatWasSent() {
        resetFormService()
        service.turns = [formTurn(56), {id: 57, prompt: "Answers to the form on the previous answer.", attachment: "",
            answer: "Here is a plan.", blocks: [], suggestions: [], warning: "", error: "", status: "done", explanation: "",
            formRef: {turnId: 56, blockIndex: 0},
            formAnswers: [{label: "Budget", text: "1800 EUR"}, {label: "Travel style", text: "Packed"}]}]
        wait(30)
        compare(findChild(pane, "aiAnswerTitle").text, "Answers to the form on the previous answer.")
        var sent = findChild(pane, "aiAnswerFormSent")
        verify(sent !== null && sent.visible)
        compare(sent.text, "Budget: 1800 EUR\nTravel style: Packed")
        compare(sent.textFormat, Text.PlainText)
        service.turns = [formTurn(58)]
        wait(30)
        compare(findChild(pane, "aiAnswerFormSent").visible, false, "an ordinary turn lists nothing")
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_failedFormAnswerRetriesTheFormNotTheSentence() {
        resetFormService()
        service.turns = [formTurn(60), {id: 61, prompt: "Answers to the form on the previous answer.", attachment: "",
            answer: "", blocks: [], suggestions: [], warning: "", error: "Codex could not complete the answer. Check authentication in the terminal.",
            status: "error", explanation: "", formRef: {turnId: 60, blockIndex: 0}, formAnswers: [{label: "Budget", text: "1000 EUR"}]}]
        service.uiStates = {"60": {"form:0": {v: {}, sent: true}}}
        fillSpy.clear()
        wait(50)
        var retry = findChild(pane, "retryAnswer")
        verify(retry !== null && retry.visible, "a failed form answer offers a retry")
        mouseClick(retry, retry.width / 2, retry.height / 2)
        tryCompare(service, "submittedForms", [[60, 0]])
        compare(fillSpy.count, 0, "the fixed sentence is never put in the composer")
        // The form it came from is gone from the window: no retry that could send nothing.
        service.submittedForms = []
        service.turns = [{id: 62, prompt: "Answers to the form on the previous answer.", attachment: "", answer: "",
            blocks: [], suggestions: [], warning: "", error: "Boom", status: "error", explanation: "",
            formRef: {turnId: 9, blockIndex: 0}, formAnswers: []}]
        wait(30)
        compare(findChild(pane, "retryAnswer").visible, false)
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_formSignalsAreForwardedAndSafeWithAnOlderService() {
        resetFormService()
        service.turns = [formTurn(63)]
        wait(30)
        var blocks = findChild(pane, "aiNativeBlocks_0")
        verify(blocks !== null)
        blocks.formSubmitRequested(0)
        compare(service.submittedForms, [[63, 0]])
        // A service without submitForm leaves the form closed with a reason.
        var legacy = {latest: service.latest, turns: service.turns, turnModel: turnModel, uiStates: ({}),
            busy: false, loadingLatest: false, attachment: "", canContinue: false, agent: "codex", defaultAgent: "codex"}
        try {
            pane.service = legacy
            wait(30)
            compare(findChild(pane, "aiFormSubmit").enabled, false)
            compare(findChild(pane, "aiFormHint").text, "Sending a form is not available here.")
        } finally {
            pane.service = service
        }
        service.turns = []
        resetFormService()
        wait(20)
    }

    // ---- Dynamic vocabulary seams: picked options and focus ----
    function actionsTurn(id, extra, blocks) {
        return Object.assign({id: id, prompt: "What now", attachment: "", answer: "Pick one.",
            blocks: blocks || [{type: "actions", title: "Next steps", options: [{label: "Book", hint: "Now"},
                {label: "Wait", hint: ""}, {label: "Skip", hint: ""}]}],
            suggestions: [], warning: "", error: "", status: "done", explanation: ""}, extra || {})
    }
    function choiceTurn(id, status, ref) {
        return {id: id, prompt: "Choice made on the previous answer.", attachment: "", answer: status === "done" ? "Booked." : "",
            blocks: [], suggestions: [], warning: "", error: status === "error" ? "Boom" : "", status: status, explanation: "",
            choiceRef: ref, choiceText: "Picked: Skip"}
    }
    function test_choiceGateEqualsTheFormGateInEveryState() {
        resetFormService()
        service.turns = [actionsTurn(81, {}, [{type: "form", title: "Trip", submitLabel: "Send", note: "", fields: [
            {id: "budget", label: "Budget", kind: "number", unit: "EUR", min: 0, max: 5000, step: 50, value: 1000,
             options: [], placeholder: ""}]}, {type: "actions", title: "Next", options: [{label: "Book", hint: ""}]}])]
        wait(40)
        var form = findChild(pane, "aiFormSubmit")
        var actions = findChild(pane, "aiActions")
        verify(form !== null && actions !== null)
        compare(actions.canChoose, true)
        compare(form.enabled, true)
        var flags = ["busy", "stopping", "loadingLatest", "workspaceActionPending", "workspaceTransitionPending"]
        for (var i = 0; i < flags.length; ++i) {
            service[flags[i]] = true
            wait(10)
            compare(findChild(pane, "aiActions").canChoose, false, flags[i] + " closes the pick")
            compare(findChild(pane, "aiActions").chooseHint, "Wait for the current answer to finish.")
            compare(findChild(pane, "aiFormSubmit").enabled, findChild(pane, "aiActions").canChoose, flags[i] + ": form === choice")
            service[flags[i]] = false
            wait(10)
            compare(findChild(pane, "aiActions").canChoose, true, flags[i] + " reopens it")
        }
        service.agent = ""; service.defaultAgent = ""
        wait(10)
        compare(findChild(pane, "aiActions").canChoose, false)
        compare(findChild(pane, "aiActions").chooseHint, "Choose an AI agent in Omarchy first.")
        compare(findChild(pane, "aiFormSubmit").enabled, false)
        service.agent = "codex"; service.defaultAgent = "codex"
        wait(10)
        // A turn that is not done, and an earlier turn, are both closed with the same reason.
        service.turns = [actionsTurn(81, {status: "working"})]
        wait(30)
        compare(findChild(pane, "aiActions").canChoose, false)
        compare(findChild(pane, "aiActions").chooseHint, "Only the latest answer's options can be chosen.")
        service.turns = [actionsTurn(81), {id: 82, prompt: "Next", attachment: "", answer: "Later", blocks: [], suggestions: [],
            warning: "", error: "", status: "done", explanation: ""}]
        pane.historyExpanded = true
        wait(50)
        compare(findChild(pane, "aiActions").canChoose, false)
        compare(findChild(pane, "aiActions").chooseHint, "Only the latest answer's options can be chosen.")
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_choiceAndFocusRequestsReachTheServiceWithTheTurnIdentity() {
        resetFormService()
        service.turns = [actionsTurn(83)]
        wait(30)
        var actions = findChild(pane, "aiActions")
        actions.choiceRequested(2)
        compare(JSON.stringify(service.submittedChoices), JSON.stringify([[83, 0, "actions", 2]]))
        actions.focusRequested(1, "Wait", "A hint")
        compare(service.focusRequests.length, 1)
        compare(JSON.stringify(service.focusRequests[0]), JSON.stringify({turnId: 83, blockIndex: 0, kind: "actions",
            index: 1, label: "Wait", detail: "A hint"}))
        // Nothing here sends a typed question or edits the composer.
        compare(service.turns.length, 1)
        compare(service.draft, "")
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_olderServicesWithoutTheSeamsStaySafe() {
        resetFormService()
        service.turns = [actionsTurn(84)]
        wait(30)
        var legacy = {latest: service.latest, turns: service.turns, turnModel: turnModel, uiStates: ({}),
            busy: false, loadingLatest: false, attachment: "", canContinue: false, agent: "codex", defaultAgent: "codex"}
        try {
            pane.service = legacy
            wait(30)
            var actions = findChild(pane, "aiActions")
            compare(actions.canChoose, false)
            compare(actions.chooseHint, "Choosing an option is not available here.")
            actions.choiceRequested(0)   // no submitChoice: ignored, no throw
            actions.focusRequested(0, "Book", "")
        } finally {
            pane.service = service
        }
        compare(service.submittedChoices.length, 0)
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_pickedOptionTurnShowsItsTextAndTearsTheRowDownSafely() {
        resetFormService()
        service.choiceAdvances = true
        service.turns = [actionsTurn(85)]
        wait(30)
        findChild(pane, "aiActions").choiceRequested(2)
        wait(60)
        compare(JSON.stringify(service.submittedChoices), JSON.stringify([[85, 0, "actions", 2]]))
        compare(service.turns.length, 2)
        compare(findChild(pane, "aiAnswerChoice").text, "Picked: Skip")
        compare(findChild(pane, "aiAnswerTitle").text, "Choice made on the previous answer.")
        verify(service.busy)
        service.choiceAdvances = false
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_failedPickRetriesTheSamePickNotTheSentence() {
        resetFormService()
        var ref = {turnId: 86, blockIndex: 0, kind: "actions", index: 1}
        service.turns = [actionsTurn(86), choiceTurn(87, "error", ref)]
        service.uiStates = {"86": {"act:0": {picked: 1}}}
        fillSpy.clear()
        wait(50)
        var retry = findChild(pane, "retryAnswer")
        verify(retry !== null && retry.visible, "a failed pick offers a retry")
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(JSON.stringify(service.submittedChoices), JSON.stringify([[86, 0, "actions", 1]]))
        compare(fillSpy.count, 0, "the fixed sentence is never put in the composer")
        // A failed pick whose options are no longer in the window offers no retry.
        service.turns = [choiceTurn(89, "error", {turnId: 7, blockIndex: 0, kind: "actions", index: 0})]
        wait(40)
        compare(findChild(pane, "retryAnswer").visible, false, "the options it came from are gone from the window")
        service.turns = []
        resetFormService()
        wait(20)
    }
    function test_chosenTrailShowsOnTheAnswerThatHadTheOptions() {
        resetFormService()
        service.turns = [actionsTurn(90), choiceTurn(91, "done", {turnId: 90, blockIndex: 0, kind: "actions", index: 2})]
        service.uiStates = {"90": {"act:0": {picked: 2}}}
        pane.historyExpanded = true
        wait(60)
        var trails = []
        function collect(item) {
            for (var i = 0; i < item.children.length; ++i) {
                if (item.children[i].objectName === "aiTrail") trails.push(item.children[i].text)
                collect(item.children[i])
            }
        }
        collect(pane)
        verify(trails.indexOf("Chose") >= 0, "trail: " + JSON.stringify(trails))
        service.turns = []
        resetFormService()
        wait(20)
    }
}
