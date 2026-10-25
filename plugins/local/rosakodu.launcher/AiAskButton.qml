import QtQuick
import QtQuick.Controls
import "AiState.js" as AiState
import "SatinGlass.js" as Satin

// The small "Ask" control that points the next typed question at one part of
// an answer (a table row, gallery tile, diagram node, step or chart point).
// It is a MOUSE / accessibility-action affordance only: it never takes
// keyboard focus, so it adds no Tab stop. The keyboard path is the `?` key on
// the focused part (handled by each renderer). The host shows it only while
// its gate is open and the part is hovered, focused or selected.
Button {
    id: ask

    required property color foreground
    // Not named `background`: that is the Control's own (final) item property.
    required property color surface
    required property color accent
    // What the control is about (the part's label); only the accessible name.
    property string subject: ""

    implicitWidth: Math.max(40, label.implicitWidth + 2 * Satin.space.gutter)
    implicitHeight: 28
    padding: 0
    hoverEnabled: true
    focusPolicy: Qt.NoFocus
    activeFocusOnTab: false
    text: qsTr("Ask")
    Accessible.role: Accessible.Button
    Accessible.name: qsTr("Ask about ") + subject
    Accessible.description: qsTr("Your next question will be about this part. Press ? on the part for the same.")
    ToolTip.visible: hovered
    ToolTip.delay: Satin.motion.tipDelay
    ToolTip.text: qsTr("Ask about this  (?)")

    background: Rectangle {
        radius: Satin.radius.chip
        color: ask.down ? AiState.alpha(ask.accent, 0.30)
            : ask.hovered ? AiState.alpha(ask.accent, 0.20) : AiState.alpha(ask.surface, 0.94)
        border.width: 1
        border.color: AiState.alpha(ask.accent, ask.hovered ? 0.7 : 0.45)
    }
    contentItem: Text {
        id: label
        text: ask.text
        textFormat: Text.PlainText
        color: AiState.alpha(ask.foreground, 0.90)
        font.pixelSize: Satin.type.meta
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
