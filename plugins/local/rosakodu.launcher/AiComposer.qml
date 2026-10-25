import QtQuick
import QtQuick.Controls
import "AiLayout.js" as AiLayout
import "SatinGlass.js" as Satin

FocusScope {
    id: composer

    required property color foreground
    required property color background
    required property color accent
    property string prompt: ""
    property bool busy: false
    property bool stopping: false
    property bool loading: false
    property bool attachmentBlocked: false
    property bool hasConversation: false
    // The part of the latest answer the next question is about ("" = none).
    // The host owns it (AiService.focusLabel) and clears it on `focusCleared`.
    property string focusLabel: ""
    // The detached workspace window hides the back-to-apps affordance.
    property bool showBackButton: true
    readonly property bool activeInputFocus: promptInput.activeFocus
    readonly property bool canSubmit: promptInput.text.trim().length > 0 && !busy && !stopping && !loading && !attachmentBlocked
    // The multiline editor consumes Tab (indent) and must not trap focus:
    // Escape stays in the field's own handler, and buttons stay Tab-reachable.
    readonly property bool editorTabTrapped: false

    signal edited(string text)
    signal submitted()
    signal hideRequested()
    signal backToApps()
    signal stopRequested()
    // The person dismissed the "About: ..." chip (its x control or Esc).
    signal focusCleared()

    // Grows with the field (and the optional chip above it) so the card frame
    // and sender read naturally.
    implicitWidth: 660
    implicitHeight: promptField.y + promptField.height + 8

    function focusPrompt() {
        promptInput.forceActiveFocus(Qt.OtherFocusReason)
        // TextArea needs an explicit caret move; cursorPosition = length alone
        // can leave a stale vertical position after growth.
        promptInput.moveCursorSelection(promptInput.length, TextEdit.MoveAnchor)
        // The host may update its query binding and request focus in one turn.
        Qt.callLater(function() {
            if (promptInput.activeFocus) {
                promptInput.moveCursorSelection(promptInput.length, TextEdit.MoveAnchor)
                promptInput.cursorPosition = promptInput.length
            }
        })
    }

    // Plain Tab steps through the composer's own buttons, then leaves the
    // composer for the answer content instead of trapping focus forever.
    function moveFocusForward() {
        if (sendButton.visible) { sendButton.forceActiveFocus(Qt.TabFocusReason); return }
        if (stopButton.visible) { stopButton.forceActiveFocus(Qt.TabFocusReason); return }
        var next = promptInput.nextItemInFocusChain()
        if (next && next !== promptInput) next.forceActiveFocus(Qt.TabFocusReason)
    }

    function moveFocusBackward() {
        if (backButton.visible && backButton.enabled) {
            backButton.forceActiveFocus(Qt.BacktabFocusReason)
            return
        }
        var previous = promptInput.nextItemInFocusChain(false)
        for (var i = 0; i < 64 && previous && previous !== promptInput; ++i) {
            if (previous.visible && previous.enabled && previous.activeFocusOnTab) {
                previous.forceActiveFocus(Qt.BacktabFocusReason)
                return
            }
            previous = previous.nextItemInFocusChain(false)
        }
    }

    // Escape peels the "About: ..." chip first (the draft stays), and only a
    // second Escape asks the host to hide; with no chip it is unchanged.
    Keys.onEscapePressed: function(event) {
        if (composer.focusLabel.length > 0) composer.focusCleared()
        else composer.hideRequested()
        event.accepted = true
    }

    // "About: <label>  x" above the field. The whole pill is one mouse /
    // accessibility-action button; it is not a Tab stop (Esc is the keyboard
    // path), so it adds nothing to the composer's focus ring.
    Item {
        id: focusChip
        objectName: "aiComposerFocusChip"
        visible: composer.focusLabel.length > 0
        x: promptField.x
        y: 8
        width: promptField.width
        height: visible ? 30 : 0

        Button {
            id: chipButton
            objectName: "aiComposerFocusClear"
            readonly property string shown: qsTr("About: ") + composer.focusLabel
            width: Math.min(parent.width, chipText.implicitWidth + clearGlyph.width + 3 * Satin.space.tip)
            height: 28
            padding: 0
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            activeFocusOnTab: false
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Asking about ") + composer.focusLabel + qsTr(", clear")
            Accessible.description: qsTr("Remove the part this question is about. Escape does the same.")
            onClicked: {
                composer.focusCleared()
                composer.focusPrompt()
            }
            background: Rectangle {
                radius: Satin.radius.chip
                color: Qt.alpha(composer.accent, chipButton.down ? 0.26 : chipButton.hovered ? 0.18 : 0.12)
                border.width: 1
                border.color: Qt.alpha(composer.accent, 0.5)
            }
            contentItem: Item {
                Text {
                    id: chipText
                    anchors.left: parent.left
                    anchors.leftMargin: Satin.space.tip
                    anchors.right: clearGlyph.left
                    anchors.rightMargin: Satin.space.base
                    anchors.verticalCenter: parent.verticalCenter
                    text: chipButton.shown
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    color: Qt.alpha(composer.foreground, 0.90)
                    font.pixelSize: Satin.type.meta
                    font.weight: Font.Medium
                }
                Text {
                    id: clearGlyph
                    anchors.right: parent.right
                    anchors.rightMargin: Satin.space.tip
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    text: "\u00d7"
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    color: Qt.alpha(composer.foreground, 0.90)
                    font.pixelSize: Satin.type.name
                }
            }
        }
    }

    Button {
        id: backButton
        objectName: "aiComposerBack"
        visible: composer.showBackButton
        x: 8
        y: promptField.y + (promptField.height - height) / 2
        width: 32
        height: 32
        padding: 0
        text: "←"
        hoverEnabled: true
        focusPolicy: Qt.StrongFocus
        Accessible.name: "Return to apps"
        ToolTip.visible: hovered
        ToolTip.delay: 700
        ToolTip.text: "Return to apps"
        onClicked: composer.backToApps()
        background: Rectangle {
            radius: 8
            color: Qt.alpha(composer.foreground, backButton.down ? 0.10 : backButton.hovered ? 0.06 : 0)
            border.width: backButton.visualFocus ? 1 : 0
            border.color: composer.accent
        }
        contentItem: Text {
            text: backButton.text
            color: composer.foreground
            font.pixelSize: Satin.type.prompt
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Item {
        id: promptField
        x: backButton.visible ? 48 : 8
        y: 8 + (focusChip.visible ? focusChip.height + Satin.space.tip : 0)
        width: Math.max(0, parent.width - x - 8)
        // Grow the viewport, not the editor: longer drafts scroll natively and
        // TextArea.flickable keeps the caret visible during editing/navigation.
        height: Math.max(AiLayout.composerHeight - 16,
            Math.min(AiLayout.composerMaxHeight - 16, Math.round(promptInput.contentHeight) + 16))

        // The focus frame and actions belong to the viewport, never its content.
        Rectangle {
            objectName: "aiComposerFocusFrame"
            anchors.fill: parent
            radius: Satin.radius.field
            color: Qt.alpha(composer.foreground, 0.075)
            border.width: promptInput.activeFocus ? 1 : 0
            border.color: Qt.alpha(composer.accent, 0.72)
        }

        Flickable {
            id: promptViewport
            objectName: "aiComposerViewport"
            anchors.fill: parent
            clip: true
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds

            TextArea.flickable: TextArea {
                id: promptInput
                objectName: "aiComposerInput"
                wrapMode: TextEdit.Wrap
                leftPadding: 12
                topPadding: 5
                bottomPadding: 5
                rightPadding: (stopButton.visible ? stopButton.width : sendButton.visible ? sendButton.width : 0) + 16
                text: composer.prompt
                placeholderText: composer.focusLabel.length > 0
                    ? "Ask about " + (composer.focusLabel.length > 48 ? composer.focusLabel.slice(0, 47) + "\u2026" : composer.focusLabel) + "\u2026"
                    : composer.hasConversation ? "Ask a follow-up" : "Ask anything"
                color: composer.foreground
                placeholderTextColor: Qt.alpha(composer.foreground, 0.76)
                selectionColor: Qt.alpha(composer.accent, 0.35)
                selectedTextColor: composer.foreground
                font.pixelSize: Satin.type.search
                selectByMouse: true
                activeFocusOnTab: true
                hoverEnabled: true
                persistentSelection: false
                inputMethodHints: Qt.ImhMultiLine | Qt.ImhNoAutoUppercase | Qt.ImhPreferLowercase
                    | Qt.ImhNoPredictiveText
                Accessible.name: "AI prompt"
                Accessible.description: composer.focusLabel.length > 0 ? "Asking about " + composer.focusLabel : ""
                // Suppress the QQC2 style's default box; the fixed frame is above.
                background: null
                Keys.onPressed: function(event) {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && (event.modifiers & Qt.ShiftModifier)) {
                        // Shift+Enter inserts a newline; IME composing is left untouched.
                        promptInput.insert(promptInput.cursorPosition, "\n")
                        event.accepted = true
                        return
                    }
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && !event.modifiers) {
                        if (composer.canSubmit) composer.submitted()
                        event.accepted = true
                        return
                    }
                    // Tab/Backtab escape the editor for the composer's buttons instead
                    // of inserting an indent character; when no composer button is
                    // available, plain Tab continues into the answer content.
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        event.accepted = true
                        if (event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)) composer.moveFocusBackward()
                        else composer.moveFocusForward()
                    }
                }
                onTextEdited: composer.edited(text)
            }
        }

        Button {
            id: sendButton
            objectName: "aiComposerSend"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 32
            padding: 0
            text: "↑"
            visible: composer.canSubmit
            enabled: composer.canSubmit
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            Accessible.name: "Send prompt"
            ToolTip.visible: hovered
            ToolTip.delay: 700
            ToolTip.text: "Send prompt"
            onClicked: {
                composer.submitted()
                // The host may hide this button as submission starts.
                composer.focusPrompt()
            }
            background: Rectangle {
                radius: 16
                color: Qt.alpha(composer.foreground, sendButton.down ? 0.78 : sendButton.hovered ? 0.90 : 1)
                border.width: sendButton.visualFocus ? 1 : 0
                border.color: composer.accent
            }
            contentItem: Text {
                text: sendButton.text
                color: composer.background
                font.pixelSize: Satin.type.prompt
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        Button {
            id: stopButton
            objectName: "aiComposerStop"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: composer.stopping ? 92 : 58
            height: 32
            padding: 0
            text: composer.stopping ? "Stopping…" : "Stop"
            visible: composer.busy || composer.stopping
            enabled: composer.busy && !composer.stopping
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            Accessible.name: text
            ToolTip.visible: hovered
            ToolTip.delay: 700
            ToolTip.text: "Stop response"
            onClicked: {
                composer.stopRequested()
                // Stop is disabled while cancellation finishes; keep typing usable.
                composer.focusPrompt()
            }
            background: Rectangle {
                radius: 7
                color: Qt.alpha(composer.foreground, stopButton.down ? 0.14 : stopButton.hovered ? 0.10 : 0.06)
                border.width: stopButton.visualFocus ? 1 : 0
                border.color: composer.accent
            }
            contentItem: Text {
                text: stopButton.text
                color: Qt.alpha(composer.foreground, stopButton.enabled ? 1 : 0.58)
                font.pixelSize: Satin.type.meta
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
