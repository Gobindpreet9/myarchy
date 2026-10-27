import QtQuick
import QtQuick.Shapes
import "AiOpenUiNative.js" as Native

Item {
    id: svg
    required property var node
    required property var theme
    readonly property var p: node && node.props ? node.props : ({})
    readonly property string kind: node ? node.kind : ""
    readonly property bool isRoot: kind === "Svg"
    readonly property bool isGroup: kind === "G"
    readonly property var box: Native.viewBox(p.viewBox)
    readonly property real naturalWidth: Math.max(280, box[2] * 1.5)
    readonly property real drawingWidth: isRoot ? Math.min(width, Native.length(p.width, width, naturalWidth)) : width
    readonly property real zoom: isRoot ? Math.min(drawingWidth / box[2], height / box[3]) : 1
    implicitWidth: naturalWidth
    implicitHeight: isRoot ? Native.length(p.height, width * box[3] / box[2], drawingWidth * box[3] / box[2]) : 0
    height: implicitHeight
    clip: isRoot
    Accessible.role: isRoot ? Accessible.Graphic : Accessible.NoRole
    Accessible.name: Native.text(p.label || p.title || "Diagram")

    ListModel { id: childrenModel }
    onNodeChanged: Native.reconcile(childrenModel, node ? node.children : [])
    Component.onCompleted: Native.reconcile(childrenModel, node ? node.children : [])

    Item {
        id: coordinates
        x: svg.isRoot ? (svg.width - svg.box[2] * svg.zoom) / 2 - svg.box[0] * svg.zoom : 0
        y: svg.isRoot ? (svg.height - svg.box[3] * svg.zoom) / 2 - svg.box[1] * svg.zoom : 0
        width: svg.isRoot ? svg.box[2] : svg.width
        height: svg.isRoot ? svg.box[3] : svg.height
        scale: svg.zoom
        transformOrigin: Item.TopLeft
        opacity: Math.max(0, Math.min(1, Native.number(svg.p.opacity, 1)))
        transform: Matrix4x4 { matrix: Native.transform(svg.isGroup ? svg.p.transform : "") }

        Repeater {
            model: childrenModel
            delegate: Loader {
                id: child
                required property string nodeSpec
                readonly property var spec: JSON.parse(nodeSpec)
                width: coordinates.width
                height: coordinates.height
                Component.onCompleted: setSource("AiOpenUiSvg.qml", {
                    node: Qt.binding(function() { return child.spec; }),
                    theme: Qt.binding(function() { return svg.theme; })
                })
            }
        }
        Shape {
            visible: !svg.isRoot && !svg.isGroup && svg.kind !== "SvgText"
            width: coordinates.width
            height: coordinates.height
            ShapePath {
                fillColor: Native.fill(svg.kind, svg.p, svg.theme)
                strokeColor: Native.stroke(svg.kind, svg.p, svg.theme)
                strokeWidth: Math.max(0, Native.number(svg.p.strokeWidth, Native.filled(svg.kind, svg.p) ? 1 : 2))
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                fillRule: ShapePath.WindingFill
                PathSvg { path: Native.shapePath(svg.kind, svg.p) }
            }
        }
        Text {
            visible: svg.kind === "SvgText"
            text: Native.text(svg.p.text)
            textFormat: Text.PlainText
            x: Native.number(svg.p.x, 0) - (svg.p.anchor === "middle" ? implicitWidth / 2 : svg.p.anchor === "end" ? implicitWidth : 0)
            y: Native.number(svg.p.y, 0) - baselineOffset
            color: Native.color(svg.p.fill, svg.theme, svg.theme.foreground)
            font.pixelSize: Math.max(1, Native.number(svg.p.size, 12))
            font.weight: svg.p.weight === "semibold" ? Font.DemiBold : svg.p.weight === "medium" ? Font.Medium : Font.Normal
            Accessible.name: text
        }
    }
}
