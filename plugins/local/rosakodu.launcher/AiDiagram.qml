import QtQuick
import "SatinGlass.js" as Satin

// A declarative schematic: percentage-grid primitives with selectable parts.
// The model defines the whole scene, so there is no grounding problem; parts
// are plain native items (no canvas, layers or shapes churn the scene graph).
Column {
    id: root
    objectName: "aiDiagram"

    property var block: ({})
    property int blockIndex: 0
    property int selectedPart: -1
    // Evaluated slider->diagram links: { "<partIndex>": { x: number, ... } }.
    property var links: ({})
    required property color foreground
    required property color background
    required property color accent
    signal partSelected(int partIndex)

    // Qt model roles wrap nested arrays; normalize to plain values in one
    // function-call binding (the AiChart pattern that works across the Loader).
    readonly property var sceneParts: normalizedParts()
    function linkedPartValue(link, name, fallback) {
        var value = link ? link[name] : undefined;
        return typeof value === "number" && isFinite(value) ? value : fallback;
    }
    function normalizedParts() {
        var result = [], source = block ? block.parts : null;
        if (!source) return result;
        for (var i = 0; i < source.length; ++i) {
            var part = source[i];
            if (!part) continue;
            var link = root.links ? root.links[String(i)] : undefined;
            result.push({
                shape: String(part.shape || ""),
                x: clampPercent(linkedPartValue(link, "x", Number(part.x) || 0)),
                y: clampPercent(linkedPartValue(link, "y", Number(part.y) || 0)),
                w: clampPercent(linkedPartValue(link, "w", Number(part.w) || 0)),
                h: clampPercent(linkedPartValue(link, "h", Number(part.h) || 0)),
                label: String(part.label || ""),
                detail: String(part.detail || ""),
                tone: String(part.tone || "foreground"),
                fill: part.fill === true,
                rotation: Math.max(-180, Math.min(180, linkedPartValue(link, "rotation", Number(part.rotation) || 0)))
            });
        }
        return result;
    }
    function clampPercent(value) { return Math.max(-100, Math.min(100, value)); }
    readonly property real aspect: {
        var value = Number(block.aspect)
        return isFinite(value) && value >= 0.8 && value <= 2.2 ? value : 1.6
    }
    readonly property color mutedColor: alpha(foreground, 0.55)
    spacing: Satin.space.tip

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function toneColor(tone) {
        return tone === "accent" ? accent : tone === "muted" ? mutedColor : foreground
    }
    function selectable(part) { return String(part.detail || "").length > 0 }
    function select(index) { root.partSelected(index) }

    function partX(part, width) { return Math.max(0, Math.min(width, Number(part.x) / 100 * width)); }
    function partY(part, height) { return Math.max(0, Math.min(height, Number(part.y) / 100 * height)); }

    Rectangle {
        id: canvas
        objectName: "aiDiagramCanvas"
        // Cap the height (and therefore the width, preserving aspect) so the
        // schematic, its controls and its readouts can share one viewport.
        readonly property real maxHeight: 420
        width: Math.min(root.width, Math.round(maxHeight * root.aspect))
        height: Math.round(width / root.aspect)
        anchors.horizontalCenter: parent.horizontalCenter
        radius: Satin.radius.field
        color: root.alpha(root.foreground, 0.03)
        border.width: 1
        border.color: root.alpha(root.foreground, Satin.keyline.inner)
        clip: true

        readonly property real pad: 6
        readonly property real innerW: Math.max(0, width - pad * 2)
        readonly property real innerH: Math.max(0, height - pad * 2)

        Repeater {
            model: root.sceneParts
            delegate: Item {
                id: partHost
                required property var modelData
                required property int index
                objectName: "aiDiagramPart_" + root.blockIndex + "_" + index
                width: canvas.width
                height: canvas.height
                readonly property bool interactive: root.selectable(modelData)
                readonly property bool selected: index === root.selectedPart
                readonly property color color: root.toneColor(modelData.tone)

                // Geometry inside the padded canvas.
                readonly property real px: canvas.pad + root.partX(modelData, canvas.innerW)
                readonly property real py: canvas.pad + root.partY(modelData, canvas.innerH)
                readonly property real pw: Number(modelData.w) / 100 * canvas.innerW
                readonly property real ph: Number(modelData.h) / 100 * canvas.innerH

                // Shared selection ring for circles/rects; also shows focus.
                Rectangle {
                    visible: (modelData.shape === "circle" || modelData.shape === "rect")
                        && (partHost.selected || partHost.activeFocus)
                    x: partHost.px - 4
                    y: partHost.py - 4
                    width: Math.max(0, Math.abs(partHost.pw)) + 8
                    height: modelData.shape === "circle"
                        ? Math.min(Math.abs(partHost.pw), Math.abs(partHost.ph)) + 8
                        : Math.max(0, Math.abs(partHost.ph)) + 8
                    radius: modelData.shape === "circle" ? width / 2 : Satin.radius.chip
                    color: "transparent"
                    border.width: 2
                    border.color: root.accent
                }

                // A start-point marker keeps line/arrow/text selection visible.
                Rectangle {
                    visible: (modelData.shape === "line" || modelData.shape === "arrow" || modelData.shape === "text")
                        && (partHost.selected || partHost.activeFocus)
                    x: partHost.px - 5
                    y: partHost.py - 5
                    width: 10
                    height: 10
                    radius: 5
                    color: "transparent"
                    border.width: 2
                    border.color: root.accent
                }

                // Circle: diameter follows the smaller box dimension.
                Rectangle {
                    objectName: "aiDiagramCircle_" + root.blockIndex + "_" + partHost.index
                    visible: modelData.shape === "circle"
                    x: partHost.px
                    y: partHost.py
                    width: Math.min(Math.abs(partHost.pw), Math.abs(partHost.ph))
                    height: width
                    radius: width / 2
                    color: modelData.fill ? root.alpha(partHost.color, 0.16) : "transparent"
                    border.width: 2
                    border.color: partHost.color
                }

                Rectangle {
                    objectName: "aiDiagramRect_" + root.blockIndex + "_" + partHost.index
                    visible: modelData.shape === "rect"
                    x: partHost.px
                    y: partHost.py
                    width: Math.max(0, Math.abs(partHost.pw))
                    height: Math.max(0, Math.abs(partHost.ph))
                    radius: Math.min(6, Math.min(Math.abs(partHost.pw), Math.abs(partHost.ph)) / 3)
                    rotation: Number(modelData.rotation) || 0
                    transformOrigin: Item.Center
                    color: modelData.fill ? root.alpha(partHost.color, 0.16) : "transparent"
                    border.width: 2
                    border.color: partHost.color
                }

                // line/arrow: from (px,py) toward (px+pw, py+ph).
                Item {
                    visible: modelData.shape === "line" || modelData.shape === "arrow"
                    anchors.fill: parent

                    readonly property real ex: partHost.px + partHost.pw
                    readonly property real ey: partHost.py + partHost.ph
                    readonly property real length: Math.hypot(partHost.pw, partHost.ph)
                    readonly property real angle: Math.atan2(partHost.ph, partHost.pw) * 180 / Math.PI
                    readonly property real midX: (partHost.px + ex) / 2
                    readonly property real midY: (partHost.py + ey) / 2

                    Rectangle {
                        width: parent.length
                        height: 2
                        color: partHost.color
                        x: parent.midX - width / 2
                        y: parent.midY - height / 2
                        rotation: parent.angle
                        transformOrigin: Item.Center
                    }
                    // Arrow heads: two short barbs from the tip, swept back.
                    Item {
                        visible: modelData.shape === "arrow" && parent.length > 14
                        Rectangle {
                            width: 10
                            height: 2
                            color: partHost.color
                            x: parent.parent.ex
                            y: parent.parent.ey - 1
                            rotation: parent.parent.angle + 180 - 26
                            transformOrigin: Item.Left
                        }
                        Rectangle {
                            width: 10
                            height: 2
                            color: partHost.color
                            x: parent.parent.ex
                            y: parent.parent.ey - 1
                            rotation: parent.parent.angle + 180 + 26
                            transformOrigin: Item.Left
                        }
                    }
                }

                Text {
                    visible: modelData.shape === "text" && String(modelData.label || "").length > 0
                    x: partHost.px
                    y: partHost.py
                    width: Math.max(0, canvas.width - x - canvas.pad)
                    text: modelData.label || ""
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: partHost.color
                    font.pixelSize: Math.max(10, Math.min(24, Math.round(Number(modelData.h) / 100 * canvas.innerH)))
                    font.weight: modelData.tone === "accent" ? Font.DemiBold : Font.Medium
                }

                // Labels for shapes sit under the shape.
                Text {
                    visible: modelData.shape !== "text" && String(modelData.label || "").length > 0
                    x: partHost.px - 6
                    y: partHost.py + (modelData.shape === "circle" ? Math.min(Math.abs(partHost.pw), Math.abs(partHost.ph)) : Math.abs(partHost.ph)) + 2
                    width: Math.max(0, canvas.width - x - canvas.pad)
                    text: modelData.label || ""
                    textFormat: Text.PlainText
                    color: root.alpha(partHost.color, 0.9)
                    font.pixelSize: Satin.type.label
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: partHit
                    enabled: partHost.interactive
                    cursorShape: Qt.PointingHandCursor
                    x: modelData.shape === "text" ? partHost.px : Math.min(partHost.px, partHost.px + partHost.pw) - 8
                    y: modelData.shape === "text" ? partHost.py : Math.min(partHost.py, partHost.py + partHost.ph) - 8
                    width: modelData.shape === "text"
                        ? Math.max(40, canvas.width - partHost.px - canvas.pad)
                        : Math.abs(partHost.pw) + 16
                    height: modelData.shape === "text"
                        ? Math.max(16, Math.abs(partHost.ph) / 100 * canvas.innerH)
                        : Math.abs(partHost.ph) + 16
                    onClicked: root.select(partHost.index)
                }

                focus: partHost.interactive
                activeFocusOnTab: partHost.interactive
                Keys.onSpacePressed: root.select(partHost.index)
                Keys.onReturnPressed: root.select(partHost.index)
                Accessible.role: partHost.interactive ? Accessible.Button : Accessible.Graphic
                Accessible.name: String(modelData.label || modelData.shape)
                Accessible.description: String(modelData.detail || "")
            }
        }
    }

    Text {
        objectName: "aiDiagramDetail"
        width: parent.width
        visible: text.length > 0
        text: {
            if (root.selectedPart >= 0 && root.selectedPart < root.sceneParts.length) {
                var part = root.sceneParts[root.selectedPart]
                return (part.label ? part.label + " — " : "") + String(part.detail || "")
            }
            return String(root.block.caption || "")
        }
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.selectedPart >= 0 ? root.foreground : root.alpha(root.foreground, 0.7)
        font.pixelSize: Satin.type.meta
        Accessible.name: text
    }
}
