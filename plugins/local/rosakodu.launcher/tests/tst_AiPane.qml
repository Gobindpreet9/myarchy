import QtQuick
import QtTest
import ".."

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
        property string attachment: ""
        property string sessionId: ""
        property string stateRoot: "/tmp/opencode"
        property string lastSource: ""
        property bool canContinue: false
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool latestRequested: false
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
        function copyAnswer() { }
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
    }

    ListModel { id: turnModel; dynamicRoles: true }
    SignalSpy { id: hideSpy; target: pane; signalName: "hideRequested" }
    SignalSpy { id: handoffSpy; target: pane; signalName: "handedOff" }
    SignalSpy { id: expandSpy; target: pane; signalName: "expandToggled" }
    SignalSpy { id: windowSpy; target: pane; signalName: "openWindowRequested" }
    SignalSpy { id: fillSpy; target: pane; signalName: "fillPrompt" }

    AiPane {
        id: pane
        width: 760
        height: 620
        service: service
        foreground: "#eeeeee"
        background: "#161616"
        accent: "#9bb9e9"
    }

    function cleanup() { service.turns = []; service.busy = false; service.attachment = ""; service.lastSource = ""; service.checklistStates = ({}); service.loadingLatest = false; service.latestRequested = false; service.stateRoot = "/tmp/opencode"; pane.showText = false }
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
        mouseClick(findChild(pane, "aiDepthSimpler"), 5, 5)
        compare(service.lastExplain, "simpler")
        mouseClick(findChild(pane, "aiDepthDeeper"), 5, 5)
        compare(service.lastExplain, "deeper")
        mouseClick(findChild(pane, "aiDepthExample"), 5, 5)
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
        compare(menu.count, 3)
        var action = menu.itemAt(0)
        verify(action !== null)
        compare(action.text, "Show as text")
        compare(menu.itemAt(1).text, "Open in window")
        compare(menu.itemAt(2).text, "Continue in terminal")
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
}
