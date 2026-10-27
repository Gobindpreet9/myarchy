import QtQuick
import "SatinGlass.js" as Satin

// Disposable presentation only. AiService owns the retained worker and commits
// acknowledgements even after this surface is hidden or destroyed.
Column {
    id: root
    property var service: null
    property int turnId: -1
    property int blockIndex: -1
    required property color foreground
    required property color background
    required property color accent
    readonly property var runtime: service && service.openUiRuntime ? service.openUiRuntime : null
    readonly property string mountKey: service && typeof service.openUiIdentity === "function"
        ? service.openUiIdentity(turnId, blockIndex) : ""
    readonly property bool selected: !!runtime && mountKey !== "" && runtime.identity === mountKey
    readonly property bool ready: selected && runtime.ready
    readonly property bool surfaceVisible: visible && !!service && (service.panelActive || service.windowActive)
    spacing: Satin.space.base
    objectName: "aiOpenUiSurface_" + blockIndex

    function refresh() {
        if (surfaceVisible && service && typeof service.isPreferredOpenUi === "function"
                && service.isPreferredOpenUi(turnId, blockIndex))
            service.activateOpenUi(turnId, blockIndex)
    }
    onSurfaceVisibleChanged: Qt.callLater(refresh)
    onMountKeyChanged: Qt.callLater(refresh)
    Component.onCompleted: Qt.callLater(refresh)
    Connections {
        target: root.runtime
        ignoreUnknownSignals: true
        function onDrained() { Qt.callLater(root.refresh) }
    }

    Text {
        width: root.width
        visible: text.length > 0
        text: !root.runtime ? qsTr("Interactive tools are unavailable in this view.")
            : root.selected ? root.runtime.error || root.runtime.warning
                || (!root.ready ? qsTr("Opening your tool\u2026") : "")
            : qsTr("Open this saved tool to use its controls.")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.foreground
        opacity: 0.85
        font.pixelSize: Satin.type.meta
        Accessible.name: text
    }
    AiButton {
        objectName: "aiOpenUiActivate"
        visible: !!root.runtime && (!root.selected || !!root.runtime.error)
        enabled: root.service && !root.service.busy && !root.runtime.busy
            && !root.service.loadingLatest && !root.service.workspaceActionPending
        text: root.selected ? qsTr("Try opening again") : qsTr("Use this tool")
        foreground: root.foreground
        accent: root.accent
        onClicked: root.service.activateOpenUi(root.turnId, root.blockIndex, true)
    }
    AiOpenUiView {
        id: presentation
        objectName: "aiOpenUiView"
        width: root.width
        visible: root.ready
        tree: root.ready ? root.runtime.tree : null
        // Do not disable/focus-teardown on every edit acknowledgement. The
        // retained controller serialises/coalesces events while a frame is busy.
        busy: !root.ready
        enabled: !root.service || (!root.service.loadingLatest && !root.service.workspaceTransitionPending
            && !root.service.busy && !root.service.stopping && !root.service.workspaceActionPending)
        foreground: root.foreground
        background: root.background
        accent: root.accent
        onEventRequested: (target, event, value) => {
            if (root.selected && root.service && typeof root.service.dispatchOpenUi === "function")
                root.service.dispatchOpenUi(root.turnId, root.blockIndex, target, event, value)
        }
    }
    AiButton {
        objectName: "aiOpenUiResetSaved"
        visible: root.selected && !!root.runtime.error
        enabled: !root.runtime.busy && !root.service.busy && !root.service.loadingLatest
        text: qsTr("Reset saved inputs")
        foreground: root.foreground
        accent: root.accent
        Accessible.description: qsTr("Discard this tool's saved inputs and reopen its authored defaults.")
        onClicked: root.service.resetOpenUi(root.turnId, root.blockIndex)
    }
    onSelectedChanged: presentation.reset()
}
