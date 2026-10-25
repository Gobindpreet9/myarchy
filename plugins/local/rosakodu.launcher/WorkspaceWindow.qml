import QtQuick
import QtQuick.Layouts
import Quickshell
import "AiState.js" as AiState
import "AiLayout.js" as AiLayout
import "SatinGlass.js" as Satin

// The detached AI workspace: a normal desktop window sharing the retained
// service, so the conversation, draft, checklists and jobs are the same
// objects as the launcher's peek view. Closing the window never destroys the
// workspace; Esc is deliberately not wired to close it.
FloatingWindow {
    id: workspace

    required property var service
    required property color foreground
    required property color background
    required property color accent

    title: "AI Workspace · " + workspaceTitle
    color: workspace.background
    // Quickshell windows default to visible; this one opens explicitly.
    visible: false
    implicitWidth: 1080
    implicitHeight: 820
    // The 720x560 floor follows measured content: full CSV-preview
    // disclosures plus a capped long draft exceed a fixed 560px minimum and
    // would otherwise be clipped beyond the window edge with no scroll path.
    readonly property real contentMinimumHeight: AiLayout.detachedMinimumHeight(
        titleText.implicitHeight, composer.implicitHeight, pane.chromeHeight,
        pane.turnCount > 0 || (pane.service && pane.service.loadingLatest) ? 160 : 0)
    minimumSize: Qt.size(720, contentMinimumHeight)

    function ensureFits() {
        // Grow a visible window when chrome appears; never shrink it here.
        if (visible && height < contentMinimumHeight) height = contentMinimumHeight
    }
    onContentMinimumHeightChanged: ensureFits()

    readonly property string workspaceTitle: {
        if (workspace.service && typeof workspace.service.workspaceDisplayTitle !== "undefined")
            return String(workspace.service.workspaceDisplayTitle || "")
        var latest = workspace.service ? workspace.service.latest : null
        return latest ? AiState.answerTitle(latest) : "New workspace"
    }

    function show() {
        visible = true
        Qt.callLater(function() { composer.focusPrompt() })
    }

    onVisibleChanged: {
        if (workspace.service) workspace.service.windowActive = visible
        if (visible) {
            ensureFits()
            Qt.callLater(function() { composer.focusPrompt() })
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        Text {
            id: titleText
            objectName: "aiWorkspaceWindowTitle"
            Layout.fillWidth: true
            text: workspace.workspaceTitle
            textFormat: Text.PlainText
            color: workspace.foreground
            font.pixelSize: Satin.type.result
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        AiComposer {
            id: composer
            objectName: "aiWorkspaceWindowComposer"
            enabled: !workspace.service || typeof workspace.service.workspaceTransitionPending === "undefined"
                || !workspace.service.workspaceTransitionPending
            Layout.fillWidth: true
            Layout.preferredHeight: composer.implicitHeight
            showBackButton: false
            prompt: workspace.service ? workspace.service.draft : ""
            busy: workspace.service ? workspace.service.busy : false
            stopping: workspace.service ? workspace.service.stopping : false
            loading: !!workspace.service && (workspace.service.loadingLatest
                || (typeof workspace.service.workspaceActionPending !== "undefined" && workspace.service.workspaceActionPending))
            attachmentBlocked: !!workspace.service && typeof workspace.service.attachmentBlocked !== "undefined"
                && workspace.service.attachmentBlocked
            hasConversation: workspace.service ? workspace.service.turns.length > 0 : false
            focusLabel: workspace.service && typeof workspace.service.focusLabel === "string" ? workspace.service.focusLabel : ""
            foreground: workspace.foreground
            background: workspace.background
            accent: workspace.accent
            onEdited: function(text) { if (workspace.service) workspace.service.draft = text }
            onSubmitted: { if (workspace.service) workspace.service.submit(workspace.service.draft) }
            onStopRequested: { if (workspace.service) workspace.service.stop() }
            onFocusCleared: { if (workspace.service && typeof workspace.service.clearFocus === "function") workspace.service.clearFocus() }
        }

        AiPane {
            id: pane
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: AiLayout.paneVisible(true, workspace.service)
            allowExpand: false
            allowOpenWindow: false
            service: workspace.service
            foreground: workspace.foreground
            background: workspace.background
            accent: workspace.accent
            onFillPrompt: function(text) { if (workspace.service) workspace.service.draft = text }
            onComposerFocusRequested: composer.focusPrompt()
        }
    }
}
