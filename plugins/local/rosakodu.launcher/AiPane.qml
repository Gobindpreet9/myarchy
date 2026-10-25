pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import "AiState.js" as AiState
import "CsvPage.js" as CsvPage
import "SatinGlass.js" as Satin

ColumnLayout {
    id: pane
    required property var service
    required property color foreground
    required property color background
    required property color accent
    // The displayed original is frozen only for the short, final hydration
    // transition; earlier save/clone phases still accept local edits.
    enabled: !service || typeof service.workspaceTransitionPending === "undefined" || !service.workspaceTransitionPending
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
    // Waiting status (service-provided phase and elapsed seconds). The
    // accessible name is throttled to a phase change or every 5 s.
    readonly property bool working: !!service && service.busy === true
    readonly property string workActivity: service && typeof service.activity === "string" ? service.activity : ""
    readonly property int workElapsed: service && typeof service.workElapsed === "number" ? service.workElapsed : 0
    readonly property string workingText: AiState.workingText(workActivity, workElapsed)
    property var workAnnouncement: null
    readonly property string workingName: workAnnouncement ? workAnnouncement.name : "Working"
    function refreshAnnouncement() {
        workAnnouncement = working ? AiState.workingAnnouncement(workAnnouncement, workActivity, workElapsed) : null
    }
    onWorkingChanged: refreshAnnouncement()
    onWorkActivityChanged: refreshAnnouncement()
    onWorkElapsedChanged: refreshAnnouncement()
    Component.onCompleted: refreshAnnouncement()
    // The durable CSV source (older/mock services may not have one). The peek
    // card shows only the honest count and a hint; the explorer itself lives
    // in the expanded and detached surfaces.
    readonly property var csvSource: service && typeof service.csvSource !== "undefined" ? service.csvSource : null
    readonly property bool sourceActive: !!csvSource && (csvSource.status === "ready" || csvSource.status === "registering")
    readonly property bool peek: allowExpand && !expanded
    readonly property string workspaceTitle: service && typeof service.workspaceDisplayTitle !== "undefined"
        ? String(service.workspaceDisplayTitle || "") : latest ? AiState.answerTitle(latest) : "New workspace"
    readonly property bool workspaceActionPending: !!service && typeof service.workspaceActionPending !== "undefined"
        && service.workspaceActionPending
    readonly property string workspaceActionError: service && typeof service.workspaceActionError !== "undefined"
        ? String(service.workspaceActionError || "") : ""
    readonly property bool canManageWorkspace: !!service && typeof service.canManageWorkspace !== "undefined"
        && service.canManageWorkspace === true && !workspaceActionPending
    readonly property bool workspaceNamed: !!service && typeof service.workspaceName !== "undefined" && !!service.workspaceName
    readonly property string workspaceIdentity: service && typeof service.workspaceId !== "undefined" ? String(service.workspaceId) : ""
    onWorkspaceIdentityChanged: {
        if (workspacePopup.visible && workspacePopup.openedWorkspaceId !== workspaceIdentity) workspacePopup.close()
    }
    readonly property string sourceNoticeText: {
        var notice = service && typeof service.sourceNotice !== "undefined" ? service.sourceNotice : ""
        if (notice === "originChanged") return "Original file changed since this copy."
            + (service.sourceOrigin ? "" : " Attach the file again to refresh.")
        if (notice === "originMissing") return "Original not found; using the saved copy."
        if (notice === "copyMissing") return "Saved copy is missing; attach the file again."
        return ""
    }
    readonly property string sourceErrorText: service && typeof service.sourceError !== "undefined"
        ? String(service.sourceError || "") : ""
    readonly property string sourceCountText: {
        if (!csvSource) return ""
        if (csvSource.status === "registering")
            return "Keeping full data · " + CsvPage.rowCountLabel(csvSource.progressRows, -1, true, false)
        return csvSource.meta ? "Full data kept · " + CsvPage.rowCountLabel(csvSource.meta.rows, -1, false, false) : ""
    }
    readonly property real chromeHeight:
        (restoringRow.visible ? restoringRow.implicitHeight + spacing : 0)
        + (attachmentRow.visible ? Math.max(32, attachmentRow.implicitHeight) + spacing : 0)
        + (csvPreviewLoader.visible ? csvPreviewLoader.implicitHeight + spacing : 0)
        + (sourceNotices.visible ? sourceNotices.implicitHeight + spacing : 0)
        + (sourcePeek.visible ? sourcePeek.implicitHeight + spacing : 0)
        + (explorerHost.visible ? explorerHost.hostHeight + spacing : 0)
        + (activityRow.visible ? 24 + spacing : 0)
        + (workspaceStatus.visible ? workspaceStatus.implicitHeight + spacing : 0)
        + (actionsRow.visible ? actionsRow.implicitHeight + spacing : 0)
    signal fillPrompt(string text)
    signal backToApps()
    signal handedOff()
    signal hideRequested()
    // A part of the answer was pointed at ("Ask about this"): the host moves
    // keyboard focus to its composer, where the "About: ..." chip now shows.
    signal composerFocusRequested()
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
        color: AiState.alpha(pane.foreground, 0.76)
        font.pixelSize: Satin.type.small
        wrapMode: Text.Wrap
        verticalAlignment: Text.AlignVCenter
        Accessible.name: text
    }

    Keys.onEscapePressed: {
        if (workspacePopup.visible) workspacePopup.close()
        // Escape peels the "About: ..." chip first, like the popup above.
        else if (pane.service && typeof pane.service.clearFocus === "function"
                 && typeof pane.service.focusLabel === "string" && pane.service.focusLabel.length > 0)
            pane.service.clearFocus()
        else hideRequested()
    }

    function openWorkspaceAction(duplicate) {
        if (!canManageWorkspace || !service
            || typeof service[duplicate ? "duplicateWorkspace" : "renameWorkspace"] !== "function") return
        workspacePopup.duplicate = duplicate
        workspacePopup.openedWorkspaceId = workspaceIdentity
        workspaceNameField.text = duplicate && typeof AiState.copyWorkspaceName === "function"
            ? AiState.copyWorkspaceName(workspaceTitle) : workspaceTitle
        workspacePopup.open()
    }

    // Why a follow-up block on `turn` cannot be sent right now ("" = it can):
    // kind "form" (a form block) or "choice" (an actions/compare option). The
    // service re-checks every gate in submitForm/submitChoice; this only drives
    // the controls. A turn is open while it is the latest finished answer, or
    // while every later turn is a failed response to the same follow-up.
    function sendGate(turn, kind) {
        var s = pane.service
        var choice = kind === "choice"
        if (!s || typeof s[choice ? "submitChoice" : "submitForm"] !== "function")
            return choice ? qsTr("Choosing an option is not available here.") : qsTr("Sending a form is not available here.")
        if (s.busy || s.stopping || s.loadingLatest || s.workspaceActionPending || s.workspaceTransitionPending)
            return qsTr("Wait for the current answer to finish.")
        var open = turn && turn.status === "done" && (choice ? AiState.choiceResendable(s.turns, turn.id)
            : AiState.formResendable(s.turns, turn.id))
        if (!open) return choice ? qsTr("Only the latest answer's options can be chosen.") : qsTr("Only the latest answer's form can be sent.")
        if (!AiState.resolveAgent(s.agent, s.defaultAgent)) return qsTr("Choose an AI agent in Omarchy first.")
        return ""
    }

    // Why a part of `turn`'s answer cannot be asked about right now ("" = it
    // can). Mirrors AiService.setFocus (which re-checks everything): the latest
    // FINISHED answer on an idle, settled service with a supported agent.
    function focusGate(turn) {
        var s = pane.service
        if (!s || typeof s.setFocus !== "function") return qsTr("Asking about a part is not available here.")
        if (s.busy || s.stopping || s.loadingLatest || s.workspaceActionPending || s.workspaceTransitionPending)
            return qsTr("Wait for the current answer to finish.")
        if (!turn || turn.status !== "done" || !s.latest || s.latest.id !== turn.id)
            return qsTr("Only the latest answer's parts can be asked about.")
        if (!AiState.resolveAgent(s.agent, s.defaultAgent)) return qsTr("Choose an AI agent in Omarchy first.")
        return ""
    }

    function confirmWorkspaceAction() {
        if (!workspacePopup.visible || !workspaceConfirm.enabled
            || workspacePopup.openedWorkspaceId !== workspaceIdentity) return
        var title = AiState.workspaceName(workspaceNameField.text)
        var accepted = workspacePopup.duplicate ? service.duplicateWorkspace(title) : service.renameWorkspace(title)
        // Acceptance is asynchronous; completion/errors belong to the service.
        if (accepted) workspacePopup.close()
    }

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

    Loader {
        id: csvPreviewLoader
        objectName: "aiCsvPreviewLoader"
        // Older/mock services may not implement the preview contract.
        active: !!pane.service && typeof pane.service.previewStatus !== "undefined"
            && /\.csv$/i.test(String(pane.service.attachment || ""))
        visible: active && pane.service.previewStatus !== "idle"
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? implicitHeight : 0
        sourceComponent: AiCsvPreview {
            objectName: "aiCsvPreview"
            foreground: pane.foreground
            background: pane.background
            accent: pane.accent
            // A kept source makes the 10-row sample a secondary view: start it as
            // one summary line on expanded/detached surfaces, open otherwise.
            collapsible: pane.sourceActive && !pane.peek
            status: pane.service && typeof pane.service.previewStatus !== "undefined" ? pane.service.previewStatus : "idle"
            preview: pane.service && typeof pane.service.previewData !== "undefined" ? pane.service.previewData : null
            error: pane.service && typeof pane.service.previewError !== "undefined" ? pane.service.previewError : ""
            typeOverrides: pane.service && typeof pane.service.previewTypeOverrides !== "undefined"
                ? pane.service.previewTypeOverrides : []
            onColumnTypeChosen: function(column, kind) {
                if (pane.service && typeof pane.service.setPreviewColumnType === "function")
                    pane.service.setPreviewColumnType(column, kind)
            }
            onRetryRequested: {
                if (pane.service && typeof pane.service.retryAttachmentPreview === "function")
                    pane.service.retryAttachmentPreview()
            }
            keepVisible: !!pane.service && typeof pane.service.keepOffered !== "undefined" && pane.service.keepOffered
            keepEnabled: !!pane.service && typeof pane.service.canKeepFullData !== "undefined" && pane.service.canKeepFullData
            onKeepFullDataRequested: {
                if (pane.service && typeof pane.service.keepFullData === "function")
                    pane.service.keepFullData()
            }
        }
    }

    // Source notices (verify results, refusals) stay visible on every surface.
    Column {
        id: sourceNotices
        objectName: "aiSourceNotices"
        visible: pane.sourceNoticeText.length > 0 || pane.sourceErrorText.length > 0
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? implicitHeight : 0
        spacing: Satin.space.tip
        Text {
            objectName: "aiSourceNotice"
            visible: text.length > 0
            width: parent.width
            text: pane.sourceNoticeText
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: AiState.alpha(pane.foreground, 0.80)
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
        Text {
            objectName: "aiSourceError"
            visible: text.length > 0
            width: parent.width
            text: pane.sourceErrorText
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: pane.foreground
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
        AiButton {
            objectName: "aiSourceRefresh"
            visible: !!pane.service && typeof pane.service.refreshSource === "function"
                && pane.service.sourceNotice === "originChanged" && !!pane.service.sourceOrigin
            enabled: !!pane.service && pane.service.canRefreshSource === true
            text: "Refresh"
            foreground: pane.foreground; accent: pane.accent
            onClicked: pane.service.refreshSource()
        }
    }

    // Peek card: the honest count and a pointer, never the explorer.
    Column {
        id: sourcePeek
        objectName: "aiSourcePeek"
        visible: pane.sourceActive && pane.peek && pane.sourceCountText.length > 0
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? implicitHeight : 0
        spacing: Satin.space.tip
        Text {
            objectName: "aiSourcePeekCount"
            width: parent.width
            text: pane.sourceCountText
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: AiState.alpha(pane.foreground, 0.80)
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
        Text {
            objectName: "aiSourcePeekHint"
            width: parent.width
            text: pane.turnCount > 0 ? "Open the workspace window to browse all rows"
                : "Expand to browse all rows"
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: AiState.alpha(pane.foreground, 0.80)
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
    }

    RowLayout {
        id: activityRow
        visible: !!pane.service && pane.service.busy
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? 24 : 0
        Text {
            objectName: "aiActivityText"
            Layout.fillWidth: true
            // The real phase plus (from 3 s) the shared service's whole
            // seconds; nothing here keeps a timer of its own.
            text: pane.workingText
            textFormat: Text.PlainText
            color: AiState.alpha(pane.foreground, 0.76)
            font.pixelSize: Satin.type.meta
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: pane.workingName
        }
    }

    Column {
        id: workspaceStatus
        objectName: "aiWorkspaceStatus"
        visible: pane.workspaceActionPending || pane.workspaceActionError.length > 0
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? implicitHeight : 0
        spacing: Satin.space.tip
        Text {
            objectName: "aiWorkspacePending"
            visible: pane.workspaceActionPending
            width: parent.width
            text: "Updating workspace…"
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: AiState.alpha(pane.foreground, 0.80)
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
        Text {
            objectName: "aiWorkspaceError"
            visible: text.length > 0
            width: parent.width
            text: pane.workspaceActionError
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: pane.foreground
            font.pixelSize: Satin.type.small
            Accessible.name: text
        }
    }

    Component {
        id: explorerComponent
        AiCsvExplorer {
            objectName: "aiCsvExplorer"
            source: pane.csvSource
            foreground: pane.foreground
            background: pane.background
            accent: pane.accent
            viewState: pane.service && typeof pane.service.csvViewState === "function"
                ? pane.service.csvViewState(pane.csvSource.sourceId) : ({})
            onViewStateEdited: function(state) {
                if (pane.service && typeof pane.service.setCsvViewState === "function")
                    pane.service.setCsvViewState(pane.csvSource.sourceId, state)
            }
        }
    }

    // Before the first turn there is no conversation to scroll: the explorer
    // sits directly under the preview and notices in its own capped viewport,
    // so keeping a file makes exploring possible before asking anything.
    ScrollView {
        id: explorerHost
        objectName: "aiCsvExplorerHost"
        readonly property real hostHeight: Math.min(560, hostLoader.item ? (hostLoader.item as Item).implicitHeight : 0)
        visible: pane.sourceActive && !pane.peek && pane.turnCount === 0
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? hostHeight : 0
        contentWidth: availableWidth
        contentHeight: hostLoader.item ? (hostLoader.item as Item).implicitHeight : 0
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Loader {
            id: hostLoader
            objectName: "aiCsvExplorerHostLoader"
            active: explorerHost.visible
            width: explorerHost.availableWidth
            sourceComponent: explorerComponent
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

            // With answers, the explorer scrolls with the conversation so a
            // tall page can never squeeze them; before the first turn it has
            // its own host above (explorerHost). Expanded and detached
            // surfaces only, and only while a source is live.
            Loader {
                id: explorerLoader
                objectName: "aiCsvExplorerLoader"
                active: pane.sourceActive && !pane.peek && pane.turnCount > 0
                visible: active
                width: parent.width
                sourceComponent: explorerComponent
            }

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
        // A kept source is a workspace too; only Copy needs an answer.
        visible: (pane.turnCount > 0 || pane.sourceActive || pane.workspaceNamed) && pane.service && !pane.service.busy
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
            visible: pane.turnCount > 0 || pane.sourceActive || pane.workspaceNamed
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
                    model: [pane.showText ? "Show interface" : "Show as text", "Open in window", "Continue in terminal",
                        "Rename…", "Duplicate…"]
                    MenuItem {
                        id: menuAction
                        required property string modelData
                        required property int index
                        objectName: "aiMenuAction_" + index
                        text: modelData
                        visible: index !== 1 || pane.allowOpenWindow
                        enabled: index === 0 ? pane.latest && pane.latest.blocks.length > 0
                            : index === 1 ? pane.turnCount > 0
                            : index === 2 ? pane.service && pane.service.canContinue
                            : pane.canManageWorkspace && typeof pane.service[index === 3 ? "renameWorkspace" : "duplicateWorkspace"] === "function"
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
                            else pane.openWorkspaceAction(index === 4)
                        }
                    }
                }
            }
        }
        Item { Layout.fillWidth: true }
        AiButton {
            objectName: "aiExpand"
            visible: (pane.turnCount > 0 || pane.sourceActive) && pane.allowExpand
            text: pane.expanded ? "Collapse" : "Expand"
            foreground: pane.foreground; accent: pane.accent
            onClicked: pane.expandToggled()
        }
        AiButton {
            objectName: "aiNewChat"
            text: "New chat"
            enabled: !pane.workspaceActionPending
            foreground: pane.foreground; accent: pane.accent
            onClicked: {
                pane.service.newConversation()
                pane.fillPrompt("")
                // Still in AI mode: the identical query string never fires the
                // panel's change handler, so say so or the next open lands in app search.
                pane.service.resumeOnOpen = true
            }
        }
    }

    Timer { id: copyTimer; interval: 1300; onTriggered: pane.copyFeedback = "" }

    Popup {
        id: workspacePopup
        objectName: "aiWorkspacePopup"
        property bool duplicate: false
        property string openedWorkspaceId: ""
        parent: Overlay.overlay
        width: Math.max(0, Math.min(420, pane.width, parent ? parent.width - 2 * Satin.space.section : 420))
        x: parent ? (parent.width - width) / 2 : 0
        y: parent ? Math.max(Satin.space.tip, (parent.height - height) / 2) : 0
        padding: Satin.space.section
        modal: true
        dim: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: {
            workspaceNameField.forceActiveFocus(Qt.PopupFocusReason)
            workspaceNameField.selectAll()
        }
        onClosed: {
            if (moreButton.visible && moreButton.enabled) moreButton.forceActiveFocus(Qt.PopupFocusReason)
        }
        background: Rectangle {
            radius: Satin.radius.field
            color: pane.background
            border.width: 1
            border.color: AiState.alpha(pane.foreground, Satin.keyline.hair)
        }
        contentItem: ColumnLayout {
            spacing: Satin.space.gutter
            Accessible.role: Accessible.Dialog
            Accessible.name: workspacePopup.duplicate ? "Duplicate workspace" : "Rename workspace"
            Text {
                objectName: "aiWorkspacePopupTitle"
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: workspacePopup.duplicate ? "Duplicate workspace" : "Rename workspace"
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: pane.foreground
                font.pixelSize: Satin.type.name
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
            }
            Text {
                objectName: "aiWorkspaceDuplicateNote"
                visible: workspacePopup.duplicate
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "Copies answers and inputs. Starts a fresh AI conversation. Kept CSV stays with the original."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: AiState.alpha(pane.foreground, 0.80)
                font.pixelSize: Satin.type.meta
                Accessible.name: text
            }
            TextField {
                id: workspaceNameField
                objectName: "aiWorkspaceName"
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: 40
                color: pane.foreground
                selectionColor: AiState.alpha(pane.accent, 0.35)
                selectedTextColor: pane.foreground
                font.pixelSize: Satin.type.body
                padding: Satin.space.tip
                Accessible.name: "Workspace name"
                background: Rectangle {
                    radius: Satin.radius.chip
                    color: AiState.alpha(pane.foreground, 0.03)
                    border.width: workspaceNameField.activeFocus ? 2 : 1
                    border.color: workspaceNameField.activeFocus ? pane.accent : AiState.alpha(pane.foreground, 0.2)
                }
                Keys.onReturnPressed: pane.confirmWorkspaceAction()
                Keys.onEnterPressed: pane.confirmWorkspaceAction()
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Satin.space.tip
                Item { Layout.fillWidth: true }
                AiButton {
                    objectName: "aiWorkspaceCancel"
                    text: "Cancel"
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: workspacePopup.close()
                }
                AiButton {
                    id: workspaceConfirm
                    objectName: "aiWorkspaceConfirm"
                    text: workspacePopup.duplicate ? "Duplicate" : "Save"
                    primary: true
                    enabled: pane.canManageWorkspace && typeof AiState.workspaceName === "function"
                        && AiState.workspaceName(workspaceNameField.text).length > 0
                        && typeof pane.service[workspacePopup.duplicate ? "duplicateWorkspace" : "renameWorkspace"] === "function"
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: pane.confirmWorkspaceAction()
                }
            }
        }
    }

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
                    if (list[i] && ["diagram", "slider", "steps", "check", "predict", "calc"].indexOf(list[i].type) >= 0)
                        ++count
                return count
            }
            width: host.width
            spacing: 13
            Text {
                visible: !!turnRow.modelData.attachment
                width: parent.width
                text: "Sent with · " + String(turnRow.modelData.attachment || "").split("/").pop()
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
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
                calcCanDuplicate: pane.service && !pane.service.busy && !pane.service.stopping
                    && !pane.service.loadingLatest && !pane.service.workspaceActionPending
                calcDuplicateHint: qsTr("Wait for the current request or workspace action to finish.")
                title: AiState.answerTitle(turnRow.modelData)
                failed: turnRow.modelData.status === "error"
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
                onCopyTextRequested: function(text) {
                    if (pane.service && typeof pane.service.copyText === "function") pane.service.copyText(text)
                }
                onDuplicateCalcRequested: function(baked) {
                    if (pane.service && typeof pane.service.duplicateCalc === "function") pane.service.duplicateCalc(baked)
                }
                formHint: pane.sendGate(turnRow.modelData, "form")
                formCanSubmit: formHint === ""
                onFormSubmitRequested: function(blockIndex) {
                    if (pane.service && typeof pane.service.submitForm === "function")
                        pane.service.submitForm(turnRow.modelData.id, blockIndex)
                }
                choiceHint: pane.sendGate(turnRow.modelData, "choice")
                choiceCanSubmit: choiceHint === ""
                onChoiceRequested: function(blockIndex, kind, index) {
                    if (pane.service && typeof pane.service.submitChoice === "function")
                        pane.service.submitChoice(turnRow.modelData.id, blockIndex, kind, index)
                }
                // Re-evaluated with the service's busy/latest/loading state, so
                // an older answer or a working service shows no Ask controls.
                canFocus: pane.focusGate(turnRow.modelData) === ""
                onFocusRequested: function(blockIndex, kind, index, label, detail) {
                    if (pane.service && typeof pane.service.setFocus === "function"
                            && pane.service.setFocus({turnId: turnRow.modelData.id, blockIndex: blockIndex, kind: kind,
                                                      index: index, label: label, detail: detail}))
                        pane.composerFocusRequested()
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
            readonly property var failure: turnRow.modelData.status === "error"
                ? AiState.failureAdvice(turnRow.modelData.error, turnRow.modelData.attachment) : null
            Column {
                objectName: "aiFailure"
                visible: !!turnRow.failure
                width: parent.width
                spacing: 4
                Text {
                    objectName: "aiFailureHeadline"
                    width: parent.width
                    text: turnRow.failure ? turnRow.failure.headline : ""
                    textFormat: Text.PlainText
                    color: pane.foreground
                    font.pixelSize: Satin.type.subtitle
                    font.weight: Font.DemiBold
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }
                Text {
                    objectName: "aiFailureDetail"
                    visible: text.length > 0
                    width: parent.width
                    text: turnRow.failure ? turnRow.failure.detail : ""
                    textFormat: Text.PlainText
                    color: AiState.alpha(pane.foreground, 0.80)
                    font.pixelSize: Satin.type.body
                    wrapMode: Text.WordWrap
                    lineHeight: 1.35
                    Accessible.name: text
                }
            }
            Row {
                spacing: Satin.space.base
                visible: !!turnRow.failure && turnRow.isLatest
                AiButton {
                    objectName: "aiSignIn"
                    readonly property string provider: turnRow.failure ? turnRow.failure.signInAgent : ""
                    visible: AiState.signInCommand(provider).length > 0
                    text: "Sign in to " + AiState.agentName(provider)
                    primary: !!(turnRow.failure && turnRow.failure.signInPrimary)
                    // One terminal per click: the detached window stays open after a hand-off.
                    property bool launched: false
                    enabled: !launched
                    Timer { interval: 8000; running: parent.launched; onTriggered: parent.launched = false }
                    foreground: pane.foreground; accent: pane.accent
                    onClicked: { if (pane.service.signIn(provider)) { launched = true; pane.handedOff() } }
                }
                AiButton {
                    objectName: "retryAnswer"
                    text: turnRow.failure ? turnRow.failure.retryLabel : "Try again"
                    primary: !(turnRow.failure && turnRow.failure.signInPrimary)
                    foreground: pane.foreground; accent: pane.accent
                    // A failed form answer is not a typed question: its Retry sends
                    // the same form again (new turn), or is hidden when the form is gone.
                    // The same holds for a failed picked-option answer (choiceRef).
                    readonly property var formRef: AiState.formRetryRef(turnRow.modelData)
                    readonly property var choiceRef: AiState.choiceRetryRef(turnRow.modelData)
                    visible: formRef ? AiState.formResendable(pane.service ? pane.service.turns : null, formRef.turnId)
                        : choiceRef ? AiState.choiceResendable(pane.service ? pane.service.turns : null, choiceRef.turnId)
                        : true
                    onClicked: {
                        if (formRef) {
                            if (typeof pane.service.submitForm === "function")
                                pane.service.submitForm(formRef.turnId, formRef.blockIndex)
                            return
                        }
                        if (choiceRef) {
                            if (typeof pane.service.submitChoice === "function")
                                pane.service.submitChoice(choiceRef.turnId, choiceRef.blockIndex, choiceRef.kind, choiceRef.index)
                            return
                        }
                        // Never clobber what the person has set up since the failure:
                        // a newer attachment or a draft they have started typing.
                        var keepFile = pane.service.attachment
                            && pane.service.attachment !== (turnRow.modelData.attachment || "")
                        if (!keepFile)
                            pane.service.attachment = turnRow.failure && turnRow.failure.dropAttachment
                                ? "" : (turnRow.modelData.attachment || "")
                        if (!pane.service.draft || pane.service.draft === turnRow.modelData.prompt)
                            pane.fillPrompt(turnRow.modelData.prompt)
                    }
                }
            }
            Text {
                objectName: "aiAgentFallbackNote"
                // Only under a finished answer: a failed or working turn was not "answered".
                visible: turnRow.isLatest && turnRow.modelData.status === "done" && text.length > 0
                width: parent.width
                text: pane.service ? AiState.agentFallbackNote(pane.service.agent, pane.service.defaultAgent) : ""
                textFormat: Text.PlainText
                color: AiState.alpha(pane.foreground, 0.76)
                font.pixelSize: Satin.type.small
                wrapMode: Text.WordWrap
                Accessible.name: text
            }
            Text {
                visible: turnRow.modelData.status === "stopped" || !!turnRow.modelData.warning
                width: parent.width
                text: turnRow.modelData.status === "stopped" ? "Response stopped. You can ask a follow-up." : turnRow.modelData.warning
                textFormat: Text.PlainText
                color: AiState.alpha(pane.foreground, 0.76)
                font.pixelSize: Satin.type.small
                wrapMode: Text.WordWrap
            }
        }
    }
}
