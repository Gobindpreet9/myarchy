import QtQuick
import QtTest
import ".."
import "../AiState.js" as AiState
import "../AiLayout.js" as AiLayout

TestCase {
    id: tests
    name: "AiComposer"
    width: 800
    height: 260
    visible: true
    when: windowShown

    // Model the host's hidden mode prefix without teaching the field about it.
    property string query: "ai: "
    property bool simulateHostActions: false
    readonly property var input: findChild(composer, "aiComposerInput")
    readonly property var send: findChild(composer, "aiComposerSend")
    readonly property var stop: findChild(composer, "aiComposerStop")
    readonly property var back: findChild(composer, "aiComposerBack")
    readonly property var viewport: findChild(composer, "aiComposerViewport")

    AiComposer {
        id: composer
        width: 660
        height: implicitHeight
        foreground: "#f1f2f4"
        background: "#1b1c20"
        accent: "#b4c4dc"
        prompt: AiState.draft(tests.query)
        onEdited: function(text) { tests.query = "ai: " + text }
        onSubmitted: {
            if (tests.simulateHostActions) {
                composer.busy = true
                tests.query = "ai: "
            }
        }
        onStopRequested: { if (tests.simulateHostActions) composer.stopping = true }
    }

    SignalSpy { id: editSpy; target: composer; signalName: "edited" }
    SignalSpy { id: submitSpy; target: composer; signalName: "submitted" }
    SignalSpy { id: hideSpy; target: composer; signalName: "hideRequested" }
    SignalSpy { id: backSpy; target: composer; signalName: "backToApps" }
    SignalSpy { id: stopSpy; target: composer; signalName: "stopRequested" }

    function typeText(text) {
        for (var i = 0; i < text.length; i++)
            keyClick(text.charAt(i))
    }

    function typeLongDraft() {
        var lines = []
        for (var i = 0; i < 10; ++i) {
            if (i > 0) keyClick(Qt.Key_Return, Qt.ShiftModifier)
            var line = "Line " + i
            typeText(line)
            lines.push(line)
        }
        keyClick(Qt.Key_Return, Qt.ShiftModifier)
        typeText("X")
        return lines.join("\n") + "\nX"
    }

    function caretIsVisible() {
        var caret = input.mapToItem(composer, input.cursorRectangle.x, input.cursorRectangle.y)
        return caret.y >= 8 - 1 && caret.y + input.cursorRectangle.height <= composer.height - 8 + 1
    }

    function init() {
        tests.simulateHostActions = false
        tests.query = "ai: "
        composer.busy = false
        composer.stopping = false
        composer.hasConversation = false
        composer.showBackButton = true
        composer.width = 660
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        wait(0)
        editSpy.clear()
        submitSpy.clear()
        hideSpy.clear()
        backSpy.clear()
        stopSpy.clear()
    }

    function test_compactIdleAndFollowupPlaceholder() {
        verify(composer.implicitHeight >= 56 && composer.implicitHeight <= 64)
        compare(input.text, "")
        compare(input.placeholderText, "Ask anything")
        verify(!send.visible)
        verify(!send.enabled)
        verify(!stop.visible)
        composer.hasConversation = true
        compare(input.placeholderText, "Ask a follow-up")
        compare(input.text, "")
    }

    function test_typingIsOnlyDraftEditing() {
        typeText("Tell me about Stanley Park")
        compare(input.text, "Tell me about Stanley Park")
        compare(composer.prompt, input.text)
        compare(tests.query, "ai: Tell me about Stanley Park")
        verify(editSpy.count > 0)
        compare(submitSpy.count, 0, "Typing must never submit a request")
        verify(send.visible && send.enabled)
        keyClick(Qt.Key_Return)
        compare(submitSpy.count, 1)
    }

    function test_literalAiIsOrdinaryPromptText() {
        typeText("Tell me about ai: syntax")
        compare(input.text, "Tell me about ai: syntax")
        compare(tests.query, "ai: Tell me about ai: syntax")
        compare(backSpy.count, 0)
        compare(submitSpy.count, 0)
    }

    function test_nativeCopyPasteEditsWithoutSubmitting() {
        tests.query = "ai: Copied question"
        keyClick(Qt.Key_A, Qt.ControlModifier)
        compare(input.selectedText, "Copied question")
        keyClick(Qt.Key_C, Qt.ControlModifier)
        tests.query = "ai: "
        editSpy.clear()
        keyClick(Qt.Key_V, Qt.ControlModifier)
        compare(input.text, "Copied question")
        compare(composer.prompt, "Copied question")
        compare(editSpy.count, 1)
        compare(submitSpy.count, 0)
    }

    function test_shiftEnterInsertsNewlineAndEnterSubmits() {
        tests.query = "ai: Question"
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        tryCompare(input, "cursorPosition", input.length)
        keyClick(Qt.Key_Return, Qt.ShiftModifier)
        tryCompare(input, "text", "Question\n")
        compare(submitSpy.count, 0, "Shift+Enter inserts a newline instead of submitting")
        typeText("Second line")
        tryCompare(input, "text", "Question\nSecond line")
        compare(composer.prompt, "Question\nSecond line")
        verify(editSpy.count >= 2)
        keyClick(Qt.Key_Return)
        compare(submitSpy.count, 1)
        compare(input.text, "Question\nSecond line", "Submission keeps the draft for review")
    }

    function test_enterSubmitsWithoutReshapingMultilineDraft() {
        tests.query = "ai: First\nSecond"
        keyClick(Qt.Key_Return)
        compare(submitSpy.count, 1)
    }

    function test_programmaticPromptUpdatesDoNotEmitEdited() {
        tests.query = "ai: Prefilled question"
        compare(input.text, "Prefilled question")
        compare(editSpy.count, 0)
        compare(submitSpy.count, 0)
        tests.query = "ai: "
        compare(input.text, "")
        compare(editSpy.count, 0)
    }

    function test_focusPromptFollowsHostBindingAndPlacesCaretAtEnd() {
        tests.query = "ai: First prompt"
        back.forceActiveFocus(Qt.TabFocusReason)
        verify(!composer.activeInputFocus)
        tests.query = "ai: Changed prompt from host"
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        tryCompare(input, "cursorPosition", input.length)
        wait(0, "The caret settling callback runs after the host binding update")
        typeText("!")
        compare(input.text, "Changed prompt from host!")
        compare(editSpy.count, 1)
    }

    function test_blankAndWhitespaceCannotSubmit() {
        keyClick(Qt.Key_Return)
        typeText("   ")
        verify(!send.visible && !send.enabled)
        keyClick(Qt.Key_Return)
        compare(submitSpy.count, 0)
        compare(input.text, "   ", "The editable draft must not be trimmed")
    }

    function test_busyAllowsNextDraftButOnlyStopAction() {
        composer.busy = true
        typeText("Next question")
        compare(input.text, "Next question")
        compare(composer.prompt, "Next question")
        verify(input.enabled && !input.readOnly)
        verify(!send.visible && !send.enabled)
        keyClick(Qt.Key_Return)
        compare(submitSpy.count, 0)
        verify(stop.visible && stop.enabled)
        compare(stop.text, "Stop")
        mouseClick(stop, stop.width / 2, stop.height / 2)
        compare(stopSpy.count, 1)
        compare(submitSpy.count, 0)
        compare(input.text, "Next question")
        composer.stopping = true
        verify(stop.visible && !stop.enabled)
        compare(stop.text, "Stopping…")
        mouseClick(stop, stop.width / 2, stop.height / 2)
        compare(stopSpy.count, 1)
        composer.busy = false
        composer.stopping = false
        verify(send.visible && send.enabled)
        verify(!stop.visible)
    }

    function test_sendClickIsExplicitSubmission() {
        tests.query = "ai: Question"
        compare(submitSpy.count, 0)
        mouseClick(send, send.width / 2, send.height / 2)
        compare(submitSpy.count, 1)
        compare(editSpy.count, 0)
        compare(input.text, "Question")
    }
    function test_actionLifecycleReturnsFocusToEditableDraft_data() {
        return [{tag: "keyboard", keyboard: true}, {tag: "mouse", keyboard: false}]
    }
    function test_actionLifecycleReturnsFocusToEditableDraft(data) {
        tests.simulateHostActions = true
        tests.query = "ai: Question"
        send.forceActiveFocus(Qt.TabFocusReason)
        if (data.keyboard) keyClick(Qt.Key_Space)
        else mouseClick(send, send.width / 2, send.height / 2)
        compare(submitSpy.count, 1)
        verify(composer.busy && !send.visible)
        tryCompare(composer, "activeInputFocus", true)
        typeText("Next question")
        compare(input.text, "Next question")
        stop.forceActiveFocus(Qt.TabFocusReason)
        if (data.keyboard) keyClick(Qt.Key_Space)
        else mouseClick(stop, stop.width / 2, stop.height / 2)
        compare(stopSpy.count, 1)
        verify(composer.stopping && !stop.enabled)
        tryCompare(composer, "activeInputFocus", true)
        typeText("!")
        compare(input.text, "Next question!")
    }
    function test_hostDraftRoundTripPreservesLeadingWhitespace() {
        tests.query = "ai:   Indented draft  "
        compare(input.text, "  Indented draft  ")
        var retainedDraft = AiState.draft(tests.query)
        tests.query = ""
        tests.query = "ai: " + retainedDraft
        compare(input.text, "  Indented draft  ")
        compare(editSpy.count, 0)
        compare(submitSpy.count, 0)
    }
    function test_detachedWindowHidesBackAndKeepsFieldInside() {
        composer.showBackButton = false
        wait(0)
        verify(!back.visible, "The detached window has no back-to-apps affordance")
        compare(viewport.mapToItem(composer, 0, 0).x, 8, "Without the back button the viewport reclaims the margin")
        verify(input.width > 0)
        composer.focusPrompt()
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        verify(!back.activeFocus, "Reverse traversal must not focus the hidden Back button")
        // With no other eligible controls, leaving focus in the editor is safe.
        verify(input.activeFocus || send.activeFocus || stop.activeFocus)
        composer.showBackButton = true
        wait(0)
        verify(back.visible)
        compare(viewport.mapToItem(composer, 0, 0).x, 48)
    }

    function test_escapeHidesFromInputAndButtons() {
        keyClick(Qt.Key_Escape)
        compare(hideSpy.count, 1)
        back.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Escape)
        compare(hideSpy.count, 2)
        composer.busy = true
        stop.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Escape)
        compare(hideSpy.count, 3)
        compare(backSpy.count, 0)
        compare(stopSpy.count, 0)
    }

    function test_tabTraversesNativeControls() {
        tests.query = "ai: Question: "
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        wait(0)
        // Tab always moves focus into the editor; the editor consumes Tab and
        // inserts spaces, so the buttons are reached by Tab from the editor's
        // own focus chain: Shift+Tab reaches Back, plain Tab reaches Send/Stop.
        keyClick(Qt.Key_Tab, Qt.ShiftModifier)
        tryCompare(back, "activeFocus", true, 8000, "Shift+Tab from the editor reaches the Back button")
        compare(back.Accessible.name, "Return to apps")
        keyClick(Qt.Key_Tab)
        tryCompare(input, "activeFocus", true)
        wait(0)
        // From the editor, one plain Tab reaches the Send button (the editor
        // consumes Tab; no double hop needed).
        keyClick(Qt.Key_Tab)
        tryCompare(send, "activeFocus", true, 8000, "Send button receives focus after the multiline field")
        compare(send.Accessible.name, "Send prompt")
        keyClick(Qt.Key_Space)
        compare(submitSpy.count, 1)
        composer.busy = true
        composer.focusPrompt()
        keyClick(Qt.Key_Tab)
        tryCompare(stop, "activeFocus", true)
        compare(stop.Accessible.name, "Stop")
        keyClick(Qt.Key_Space)
        compare(stopSpy.count, 1)
        compare(input.text, "Question: ", "Tab is navigation, not prompt text")
    }

    function test_plainTabWithEmptyDraftReachesBack() {
        tests.query = "ai: "
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        wait(0)
        // Empty draft: Send and Stop are hidden, so Tab must land on Back.
        // (A stale id here once made every Tab silently fail live.)
        keyClick(Qt.Key_Tab)
        tryCompare(back, "activeFocus", true, 8000, "Tab with an empty draft reaches the Back button")
        keyClick(Qt.Key_Space)
        compare(backSpy.count, 1)
    }

    function test_multilineDraftGrowsAndStaysScrollBound() {
        tests.query = "ai: Line one"
        composer.focusPrompt()
        tryCompare(composer, "activeInputFocus", true)
        tryCompare(input, "cursorPosition", input.length)
        compare(composer.implicitHeight, AiLayout.composerHeight, "A single line stays at rest height")
        for (var i = 0; i < 4; ++i) {
            keyClick(Qt.Key_Return, Qt.ShiftModifier)
        }
        typeText("tail")
        tryCompare(input, "lineCount", 5, 8000, "Enter key events must reach the TextArea and insert newlines")
        verify(composer.implicitHeight > AiLayout.composerHeight, "Newlines grow the composer")
        verify(composer.implicitHeight <= AiLayout.composerMaxHeight + 1, "Growth is bounded")
        verify(viewport.height < AiLayout.composerMaxHeight - 16, "Five lines still fit below the viewport cap")
        tests.query = "ai: Short"
        tryCompare(input, "lineCount", 1)
        wait(0, "Height bindings settle after the text change")
        compare(composer.implicitHeight, AiLayout.composerHeight, "Shortening returns to the rest height")
    }

    function test_typingPastHeightCapKeepsCaretVisibleAndFollowsHomeEnd() {
        var draft = typeLongDraft()
        compare(input.text, draft)
        compare(composer.prompt, draft)
        compare(input.lineCount, 11)
        compare(submitSpy.count, 0)
        tryCompare(composer, "implicitHeight", AiLayout.composerMaxHeight)
        verify(composer.height <= 170)
        tryVerify(caretIsVisible, 2000, "Typing beyond the height cap must scroll the caret into view")
        verify(viewport.contentY > 0)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        tryCompare(input, "cursorPosition", 0)
        tryVerify(caretIsVisible)
        tryCompare(viewport, "contentY", 0)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        tryCompare(input, "cursorPosition", input.length)
        tryVerify(caretIsVisible)
        verify(viewport.contentY > 0)
        keyClick(Qt.Key_Home)
        tryCompare(input, "cursorPosition", input.length - 1)
        tryVerify(caretIsVisible)
        keyClick(Qt.Key_End)
        tryCompare(input, "cursorPosition", input.length)
        tryVerify(caretIsVisible)
        compare(input.text, draft, "Caret navigation must preserve the entire draft")
    }

    function test_longDraftWheelScrollingKeepsActionsAndFocusFramePinned() {
        var draft = typeLongDraft()
        tryVerify(caretIsVisible)
        var sendPosition = send.mapToItem(composer, 0, 0)
        var frame = findChild(composer, "aiComposerFocusFrame")
        compare(frame.border.width, 1, "The focused editor has a visible fixed frame")
        compare(frame.height, viewport.height)
        verify(viewport.contentHeight > viewport.height)
        var endY = viewport.contentY
        mouseWheel(viewport, 20, viewport.height / 2, 0, 120)
        tryVerify(function() { return viewport.contentY < endY }, 2000, "Wheel-up scrolls the draft")
        compare(send.mapToItem(composer, 0, 0).y, sendPosition.y)
        var startY = viewport.contentY
        mouseWheel(viewport, 20, viewport.height / 2, 0, -120)
        tryVerify(function() { return viewport.contentY > startY }, 2000, "Wheel-down scrolls the draft")
        compare(send.mapToItem(composer, 0, 0).y, sendPosition.y)
        verify(input.rightPadding > send.width)

        composer.busy = true
        verify(stop.visible && !send.visible)
        var stopPosition = stop.mapToItem(composer, 0, 0)
        compare(stopPosition.y, sendPosition.y)
        keyClick(Qt.Key_Home, Qt.ControlModifier)
        tryCompare(viewport, "contentY", 0)
        compare(stop.mapToItem(composer, 0, 0).y, stopPosition.y)
        keyClick(Qt.Key_End, Qt.ControlModifier)
        tryVerify(caretIsVisible)
        verify(viewport.contentY > 0)
        compare(stop.mapToItem(composer, 0, 0).y, stopPosition.y)
        composer.stopping = true
        verify(stop.visible && !stop.enabled)
        verify(input.rightPadding > stop.width, "Stopping reserves the wider fixed action's space")
        mouseWheel(viewport, 20, viewport.height / 2, 0, 120)
        tryVerify(function() { return viewport.contentY < endY })
        compare(stop.mapToItem(composer, 0, 0).y, stopPosition.y)
        compare(frame.border.width, 1)
        compare(frame.mapToItem(composer, 0, 0).y, 8)
        compare(input.text, draft)
        compare(composer.prompt, draft)
        compare(submitSpy.count, 0)
        compare(stopSpy.count, 0)
    }

    function test_backButtonIsDirectAccessibleExit() {
        tests.query = "ai: Retain this draft"
        compare(back.Accessible.name, "Return to apps")
        mouseClick(back, back.width / 2, back.height / 2)
        compare(backSpy.count, 1)
        compare(tests.query, "ai: Retain this draft")
        compare(submitSpy.count, 0)
        back.forceActiveFocus(Qt.TabFocusReason)
        keyClick(Qt.Key_Space)
        compare(backSpy.count, 2)
    }

    function test_narrowComposerKeepsControlsInsideField() {
        composer.width = 360
        tests.query = "ai: A longer editable draft for the narrow composer"
        verify(input.width > 200)
        var sendPosition = send.mapToItem(viewport, 0, 0)
        verify(sendPosition.x >= 0 && sendPosition.x + send.width <= viewport.width)
        composer.busy = true
        composer.stopping = true
        var stopPosition = stop.mapToItem(viewport, 0, 0)
        verify(stopPosition.x >= 0 && stopPosition.x + stop.width <= viewport.width)
        compare(input.text, "A longer editable draft for the narrow composer")
        verify(input.rightPadding > stop.width)
    }
}
