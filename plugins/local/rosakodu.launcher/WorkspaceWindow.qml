import QtQuick
import QtQuick.Layouts
import Quickshell
import "AiState.js" as AiState
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
    minimumSize: Qt.size(720, 560)

    readonly property string workspaceTitle: {
        var latest = workspace.service ? workspace.service.latest : null
        return latest ? AiState.answerTitle(latest) : "New workspace"
    }

    function show() {
        visible = true
        Qt.callLater(function() { composer.focusPrompt() })
    }

    onVisibleChanged: {
        if (workspace.service) workspace.service.windowActive = visible
        if (visible) Qt.callLater(function() { composer.focusPrompt() })
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        Text {
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
            Layout.fillWidth: true
            Layout.preferredHeight: composer.implicitHeight
            showBackButton: false
            prompt: workspace.service ? workspace.service.draft : ""
            busy: workspace.service ? workspace.service.busy : false
            stopping: workspace.service ? workspace.service.stopping : false
            loading: workspace.service ? workspace.service.loadingLatest : false
            hasConversation: workspace.service ? workspace.service.turns.length > 0 : false
            foreground: workspace.foreground
            background: workspace.background
            accent: workspace.accent
            onEdited: function(text) { if (workspace.service) workspace.service.draft = text }
            onSubmitted: { if (workspace.service) workspace.service.submit(workspace.service.draft) }
            onStopRequested: { if (workspace.service) workspace.service.stop() }
        }

        AiPane {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: workspace.service && (workspace.service.turns.length > 0 || !!workspace.service.attachment || workspace.service.loadingLatest)
            allowExpand: false
            allowOpenWindow: false
            service: workspace.service
            foreground: workspace.foreground
            background: workspace.background
            accent: workspace.accent
            onFillPrompt: function(text) { if (workspace.service) workspace.service.draft = text }
        }
    }
}
