pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import "AiState.js" as AiState
import "SatinGlass.js" as Satin

ColumnLayout {
    id: pane
    required property var service
    required property color foreground
    required property color background
    required property color accent
    property bool showText: false
    property bool historyExpanded: false
    property string copyFeedback: ""
    // Explore surface: expanded presentation, state unchanged.
    property bool expanded: false
    property bool allowExpand: true
    property bool allowOpenWindow: true
    signal expandToggled()
    signal openWindowRequested()
    readonly property var latest: service ? service.latest : null
    readonly property int turnCount: service ? service.turns.length : 0
    readonly property int latestId: latest && latest.id !== undefined ? latest.id : turnCount
    readonly property real responseHeight: conversationContent.implicitHeight
    readonly property real chromeHeight:
        (restoringRow.visible ? restoringRow.implicitHeight + spacing : 0)
        + (attachmentRow.visible ? Math.max(32, attachmentRow.implicitHeight) + spacing : 0)
        + (activityRow.visible ? 24 + spacing : 0)
        + (actionsRow.visible ? actionsRow.implicitHeight + spacing : 0)
    signal fillPrompt(string text)
    signal backToApps()
    signal handedOff()
    signal hideRequested()
    spacing: 16

    onLatestIdChanged: {
        showText = false
        historyExpanded = false
        Qt.callLater(function() { if (scroll.contentItem) scroll.contentItem.contentY = 0 })
    }

    function ensureConversationFocusVisible() {
        var focused = pane.Window.window ? pane.Window.window.activeFocusItem : null
        var ancestor = focused
        while (ancestor && ancestor !== conversationContent) ancestor = ancestor.parent
        var viewport = scroll.contentItem
        if (!ancestor || !viewport || !viewport.contentItem || viewport.height <= 0) return
        var top = focused.mapToItem(viewport.contentItem, 0, 0).y
        var bottom = top + focused.height
        var nextY = viewport.contentY
        if (top < nextY || focused.height > viewport.height) nextY = top
        else if (bottom > nextY + viewport.height) nextY = bottom - viewport.height
        viewport.contentY = Math.max(0, Math.min(nextY, Math.max(0, viewport.contentHeight - viewport.height)))
    }

    Connections {
        target: pane.Window.window
        function onActiveFocusItemChanged() {
            // Focus can move before the answer tree's layout has settled.
            Qt.callLater(pane.ensureConversationFocusVisible)
        }
    }

    Text {
        id: restoringRow
        objectName: "aiRestoring"
        visible: pane.service && pane.service.loadingLatest
        Layout.fillWidth: true
        text: qsTr("Loading your last conversation…")
        textFormat: Text.PlainText
        color: AiState.alpha(pane.foreground, 0.6)
        font.pixelSize: Satin.type.small
        wrapMode: Text.Wrap
        verticalAlignment: Text.AlignVCenter
        Accessible.name: text
    }

    Keys.onEscapePressed: hideRequested()

    RowLayout {
        id: attachmentRow
        visible: !!pane.service && !!pane.service.attachment
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? 32 : 0
        Text {
            Layout.fillWidth: true
            text: pane.service && pane.service.attachment ? "Attached · " + pane.service.attachment.split("/").pop() : ""
            textFormat: Text.PlainText
            color: pane.accent
            font.pixelSize: Satin.type.meta
            elide: Text.ElideMiddle
        }
        AiButton {
            text: "Remove"
            foreground: pane.foreground; accent: pane.accent
            onClicked: pane.service.attachment = ""
        }
    }

    RowLayout {
        id: activityRow
        visible: !!pane.service && pane.service.busy
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? 24 : 0
        Text {
            Layout.fillWidth: true
            text: pane.service ? pane.service.activity || "Thinking…" : ""
            textFormat: Text.PlainText
            color: AiState.alpha(pane.foreground, 0.62)
            font.pixelSize: Satin.type.meta
            elide: Text.ElideRight
            Accessible.name: text
        }
    }

    ScrollView {
        id: scroll
        visible: pane.turnCount > 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Column {
            id: conversationContent
            width: scroll.availableWidth
            spacing: 18

            AiButton {
                visible: pane.turnCount > 1
                text: (pane.historyExpanded ? "Hide earlier answers" : "Earlier answers") + " · " + Math.max(0, pane.turnCount - 1)
                foreground: pane.foreground; accent: pane.accent
                onClicked: pane.historyExpanded = !pane.historyExpanded
            }

            Repeater {
                model: pane.service ? pane.service.turnModel : null
                // Historical turns stay uninstantiated while collapsed: their
                // native answer trees, sibling images and delegates are real
                // resources, and `visible: false` alone would keep them live.
                // Expanding history or the newest turn materialises a row.
                delegate: Loader {
                    id: turnLoader
                    required property int index
                    required property var payload
                    readonly property bool isLatest: index === pane.turnCount - 1
                    active: turnLoader.isLatest || pane.historyExpanded
                    visible: active
                    width: scroll.availableWidth
                    sourceComponent: turnRowComponent
                }
            }
        }
    }

    RowLayout {
        id: actionsRow
        Layout.fillWidth: true
        visible: pane.turnCount > 0 && pane.service && !pane.service.busy
        spacing: 4
        AiButton {
            text: pane.copyFeedback || "Copy"
            visible: pane.latest && (pane.latest.answer.length > 0 || pane.latest.blocks.length > 0)
            enabled: pane.latest && (pane.latest.answer || pane.latest.blocks.length > 0)
            foreground: pane.foreground; accent: pane.accent
            onClicked: {
                // Clipboard ownership is retained by the persistent service.
                pane.service.copyAnswer()
                pane.copyFeedback = "Copied"
                copyTimer.restart()
            }
        }
        AiButton {
            id: moreButton
            objectName: "aiMore"
            text: "More"
            foreground: pane.foreground; accent: pane.accent
            onClicked: moreMenu.open()
            Menu {
                id: moreMenu
                objectName: "aiMoreMenu"
                y: -height
                width: 220
                padding: 6
                background: Rectangle {
                    color: pane.background
                    radius: 9
                    border.width: 1
                    border.color: AiState.alpha(pane.foreground, 0.2)
                }
                Repeater {
                    model: [pane.showText ? "Show interface" : "Show as text", "Open in window", "Continue in terminal"]
                    MenuItem {
                        id: menuAction
                        required property string modelData
                        required property int index
                        objectName: "aiMenuAction_" + index
                        text: modelData
                        visible: index !== 1 || pane.allowOpenWindow
                        enabled: index === 0 ? pane.latest && pane.latest.blocks.length > 0
                            : index === 1 ? pane.turnCount > 0
                            : pane.service && pane.service.canContinue
                        implicitHeight: 36
                        contentItem: Text {
                            text: menuAction.text
                            color: AiState.alpha(pane.foreground, menuAction.enabled ? 1 : 0.38)
                            font.pixelSize: Satin.type.meta
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: 5
                            color: menuAction.highlighted ? AiState.alpha(pane.accent, 0.15) : "transparent"
                        }
                        onTriggered: {
                            if (index === 0) pane.showText = !pane.showText
                            else if (index === 1) pane.openWindowRequested()
                            else if (index === 2) { if (pane.service.continueInTerminal()) pane.handedOff() }
                        }
                    }
                }
            }
        }
        Item { Layout.fillWidth: true }
        AiButton {
            objectName: "aiExpand"
            visible: pane.turnCount > 0 && pane.allowExpand
            text: pane.expanded ? "Collapse" : "Expand"
            foreground: pane.foreground; accent: pane.accent
            onClicked: pane.expandToggled()
        }
        AiButton {
            objectName: "aiNewChat"
            text: "New chat"
            foreground: pane.foreground; accent: pane.accent
            onClicked: {
                pane.service.newConversation()
                pane.fillPrompt("")
            }
        }
    }

    Timer { id: copyTimer; interval: 1300; onTriggered: pane.copyFeedback = "" }

    // One row per turn, instantiated only while visible (see the loader in
    // the conversation Repeater). Per-row data arrives through the visual
    // parent — the component boundary rule that also governs AiBlocks; the
    // root-level `pane` id stays reachable for shared surface state.
    Component {
        id: turnRowComponent
        Column {
            id: turnRow
            readonly property var host: parent
            property int index: host.index
            property var payload: host.payload
            readonly property var modelData: payload
            readonly property bool isLatest: host.isLatest
            readonly property int learningBlocks: {
                var count = 0
                var list = payload ? payload.blocks : []
                for (var i = 0; i < list.length; ++i)
                    if (list[i] && ["diagram", "slider", "steps", "check", "predict"].indexOf(list[i].type) >= 0)
                        ++count
                return count
            }
            width: host.width
            spacing: 13
            Text {
                visible: !!turnRow.modelData.attachment
                width: parent.width
                text: "Context · " + String(turnRow.modelData.attachment || "").split("/").pop()
                textFormat: Text.PlainText
                color: pane.accent
                font.pixelSize: Satin.type.small
            }
            Text {
                objectName: "aiTrail"
                visible: text.length > 0
                width: parent.width
                text: AiState.trailSummary(turnRow.modelData, pane.service && pane.service.uiStates
                    ? pane.service.uiStates[String(turnRow.modelData.id)] || ({}) : null)
                textFormat: Text.PlainText
                color: AiState.alpha(pane.accent, 0.8)
                font.pixelSize: Satin.type.label
                Accessible.name: text
            }
            AiAnswer {
                width: parent.width
                turn: turnRow.modelData
                turnIndex: turnRow.index
                title: AiState.answerTitle(turnRow.modelData)
                showText: pane.showText && turnRow.isLatest
                mediaRoot: pane.service && pane.service.stateRoot ? pane.service.stateRoot + "/media" : ""
                checkedState: pane.service && pane.service.checklistStates
                    ? pane.service.checklistStates[String(turnRow.modelData.id)] || ({}) : null
                uiState: pane.service && pane.service.uiStates
                    ? pane.service.uiStates[String(turnRow.modelData.id)] || ({}) : null
                onCheckChanged: function(blockIndex, itemIndex, checked) {
                    if (pane.service && typeof pane.service.setChecklist === "function")
                        pane.service.setChecklist(turnRow.modelData.id, blockIndex, itemIndex, checked)
                }
                onUiStateEdited: function(blockIndex, key, value) {
                    if (pane.service && typeof pane.service.setUiState === "function")
                        pane.service.setUiState(turnRow.modelData.id, key, value)
                }
                foreground: pane.foreground; background: pane.background; accent: pane.accent
                onOpenUrl: function(url) {
                    if (pane.service && typeof pane.service.openSource === "function" && pane.service.openSource(url))
                        pane.handedOff()
                }
            }
            Flow {
                objectName: "aiSuggestions"
                visible: turnRow.isLatest && !(pane.service && pane.service.busy)
                    && (turnRow.modelData.suggestions || []).length > 0
                width: parent.width
                spacing: Satin.space.base
                Repeater {
                    model: turnRow.modelData.suggestions || []
                    delegate: AiButton {
                        required property string modelData
                        required property int index
                        objectName: "aiSuggestion_" + index
                        text: modelData
                        foreground: pane.foreground; accent: pane.accent
                        onClicked: pane.fillPrompt(modelData)
                    }
                }
            }
            Row {
                objectName: "aiDepthActions"
                visible: turnRow.isLatest && !(pane.service && pane.service.busy)
                    && turnRow.learningBlocks > 0
                spacing: Satin.space.base
                AiButton {
                    objectName: "aiDepthSimpler"
                    text: "Simpler"
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: { if (pane.service) pane.service.explainLatest("simpler") }
                }
                AiButton {
                    objectName: "aiDepthDeeper"
                    text: "More depth"
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: { if (pane.service) pane.service.explainLatest("deeper") }
                }
                AiButton {
                    objectName: "aiDepthExample"
                    text: "Another example"
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: { if (pane.service) pane.service.explainLatest("example") }
                }
            }
            Rectangle {
                id: depthText
                objectName: "aiDepthText"
                visible: !!turnRow.modelData.explanation
                width: parent.width
                implicitHeight: depthTextLabel.implicitHeight + 2 * Satin.space.section
                height: implicitHeight
                radius: Satin.radius.field
                color: AiState.alpha(pane.foreground, 0.03)
                border.width: 1
                border.color: AiState.alpha(pane.foreground, 0.12)
                Text {
                    id: depthTextLabel
                    objectName: "aiDepthTextLabel"
                    x: Satin.space.section
                    y: Satin.space.section
                    width: Math.max(0, depthText.width - 2 * Satin.space.section)
                    text: String(turnRow.modelData.explanation || "")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: AiState.alpha(pane.foreground, 0.82)
                    font.pixelSize: Satin.type.meta
                    lineHeight: 1.3
                }
            }
            Text {
                visible: turnRow.modelData.status === "error"
                width: parent.width
                text: "Couldn't get an answer\n" + turnRow.modelData.error
                textFormat: Text.PlainText
                color: pane.foreground
                font.pixelSize: Satin.type.body
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
            AiButton {
                objectName: "retryAnswer"
                visible: turnRow.modelData.status === "error" && turnRow.isLatest
                text: "Try again"
                primary: true
                foreground: pane.foreground; accent: pane.accent
                onClicked: {
                    pane.service.attachment = turnRow.modelData.attachment || ""
                    pane.fillPrompt(turnRow.modelData.prompt)
                }
            }
            Text {
                visible: turnRow.modelData.status === "stopped" || !!turnRow.modelData.warning
                width: parent.width
                text: turnRow.modelData.status === "stopped" ? "Response stopped. You can ask a follow-up." : turnRow.modelData.warning
                textFormat: Text.PlainText
                color: AiState.alpha(pane.foreground, 0.65)
                font.pixelSize: Satin.type.small
                wrapMode: Text.WordWrap
            }
        }
    }
}
