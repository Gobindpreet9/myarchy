import QtQuick
import "AiOpenUiNative.js" as Native

// Native presentation surface only. The outer controller owns worker lifetime,
// mount identity, validation, state, actions and persistence. Never import a
// retained launcher service here: this file can run using Qt modules alone.
Item {
    id: view
    property var tree: null
    property bool busy: false
    property color foreground: "#ece9e1"
    property color background: "#202124"
    property color accent: "#a8bbeb"
    property var palette: ({})
    readonly property bool controlsEnabled: enabled && !busy
    property int mountRevision: 0
    readonly property alias rootNode: root
    signal eventRequested(string target, string event, var value)

    implicitHeight: root.implicitHeight
    implicitWidth: root.implicitWidth

    // Call only on a NEW program/workspace identity, never on a state frame.
    // This resets draft/focus and child identity even if structural IDs repeat.
    function reset() { mountRevision += 1; root.reset(); }
    function dispatch(target, event, value) {
        if (controlsEnabled) eventRequested(target, event, value);
    }
    AiOpenUiNode {
        id: root
        width: view.width
        node: view.tree
        theme: view
    }
}
