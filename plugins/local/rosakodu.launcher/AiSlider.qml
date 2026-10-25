import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiFormula.js" as Formula

// A parameter control coupled to locally computed readouts. The formula
// engine is a bounded arithmetic parser (see AiFormula.js / ai_formula.py):
// no model round trip while the user scrubs, and no dynamic evaluation of
// arbitrary text.
Column {
    id: root
    objectName: "aiSlider"

    property var block: ({})
    property int blockIndex: 0
    property real value: control.value
    required property color foreground
    required property color background
    required property color accent
    signal valueEdited(real value)

    readonly property var control: block.control || ({})
    readonly property var readouts: block.readouts || []
    readonly property bool hasLabels: control.labels && control.labels.length > 0
    readonly property int stepIndex: {
        if (control.step > 0) return Math.round((value - control.min) / control.step);
        return 0;
    }
    readonly property string currentText: {
        if (root.hasLabels && root.stepIndex >= 0 && root.stepIndex < root.control.labels.length)
            return String(root.control.labels[root.stepIndex]);
        return Formula.formatValue(root.value, String(root.control.unit || ""));
    }
    spacing: Satin.space.tip

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }

    // The host drives `value` (from persisted interaction state); user
    // interaction reports upward and this keeps the track in sync when the
    // host round-trips the value.
    Connections {
        target: root
        function onValueChanged() {
            if (Math.abs(slider.value - root.value) > 1e-9) slider.value = root.value
        }
    }

    Text {
        width: parent.width
        visible: text.length > 0
        text: String(root.control.label || "")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.foreground
        font.pixelSize: Satin.type.result
    }

    Slider {
        id: slider
        objectName: "aiSliderTrack"
        width: parent.width
        implicitHeight: 28
        from: Number(root.control.min) || 0
        to: Number(root.control.max) || 1
        stepSize: Number(root.control.step) || 1
        snapMode: Slider.SnapAlways
        value: root.value
        activeFocusOnTab: true
        hoverEnabled: true
        onMoved: root.valueEdited(value)
        Keys.onPressed: function(event) {
            // QQC2 Slider handles arrows and PageUp/Down but not Home/End.
            if (event.key === Qt.Key_Home) {
                slider.value = slider.from
                root.valueEdited(slider.value)
                event.accepted = true
            } else if (event.key === Qt.Key_End) {
                slider.value = slider.to
                root.valueEdited(slider.value)
                event.accepted = true
            }
        }
        Accessible.name: String(root.control.label || qsTr("Parameter")) + ": " + root.currentText
        Accessible.description: qsTr("Use Left and Right to adjust; Home and End jump to the ends.")

        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth
            height: 4
            implicitHeight: 4
            radius: 2
            color: root.alpha(root.foreground, 0.15)

            Rectangle {
                width: slider.visualPosition * parent.width
                height: parent.height
                radius: 2
                color: root.accent
            }
        }
        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 18
            height: 18
            implicitWidth: 18
            implicitHeight: 18
            radius: 9
            color: root.accent
            border.width: slider.activeFocus ? 2 : 0
            border.color: root.foreground
        }
    }

    Text {
        objectName: "aiSliderValue"
        width: parent.width
        text: root.currentText
        textFormat: Text.PlainText
        color: root.accent
        font.pixelSize: Satin.type.result
        font.weight: Font.DemiBold
        Accessible.name: String(root.control.label || "") + ": " + root.currentText
    }

    Repeater {
        model: root.readouts
        delegate: Row {
            id: readoutRow
            required property var modelData
            required property int index
            width: root.width
            spacing: Satin.space.base

            readonly property var compiled: Formula.compile(String(modelData.expression || ""))
            readonly property var computed: Formula.evaluate(compiled, root.value)

            Text {
                objectName: "aiSliderReadoutLabel_" + root.blockIndex + "_" + readoutRow.index
                width: Math.max(0, readoutRow.width * 0.55)
                text: String(readoutRow.modelData.label || "")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.alpha(root.foreground, 0.75)
                font.pixelSize: Satin.type.meta
            }
            Text {
                objectName: "aiSliderReadout_" + root.blockIndex + "_" + readoutRow.index
                width: Math.max(0, readoutRow.width - parent.width * 0.55 - readoutRow.spacing)
                text: Formula.formatValue(readoutRow.computed, String(readoutRow.modelData.unit || ""))
                textFormat: Text.PlainText
                color: readoutRow.computed === null ? root.alpha(root.foreground, 0.4) : root.foreground
                font.pixelSize: Satin.type.meta
                font.weight: Font.Medium
                Accessible.name: String(readoutRow.modelData.label || "") + ": " + text
            }
        }
    }

    Text {
        objectName: "aiSliderNote"
        width: parent.width
        visible: text.length > 0
        text: String(root.block.note || "")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.alpha(root.foreground, 0.76)
        font.pixelSize: Satin.type.label
    }
}
