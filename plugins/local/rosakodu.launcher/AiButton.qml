import QtQuick
import QtQuick.Controls
import "AiState.js" as AiState
import "SatinGlass.js" as Satin

Button {
    id: button
    required property color foreground
    required property color accent
    property bool primary: false
    padding: 9
    horizontalPadding: 12
    implicitHeight: 34
    implicitWidth: label.implicitWidth + horizontalPadding * 2
    hoverEnabled: true
    Accessible.name: text
    // Qt Quick Controls styles/platforms disagree on Return activation. These
    // launcher actions consistently support both Return and the native Space.
    Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
    Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
    background: Rectangle {
        radius: 7
        color: button.down ? AiState.alpha(button.accent, 0.24)
            : button.hovered || button.primary ? AiState.alpha(button.accent, 0.12) : "transparent"
        border.width: button.visualFocus || button.primary ? 1 : 0
        border.color: AiState.alpha(button.accent, button.visualFocus ? 0.9 : 0.35)
    }
    contentItem: Text {
        id: label
        text: button.text
        textFormat: Text.PlainText
        color: AiState.alpha(button.primary ? button.accent : button.foreground,
            button.enabled ? button.primary || button.hovered || button.visualFocus ? 1 : 0.80 : 0.38)
        font.pixelSize: Satin.type.meta
        font.weight: button.primary ? Font.DemiBold : Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
