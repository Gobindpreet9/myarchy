pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiState.js" as AiState

Item {
    id: root
    objectName: "aiChart"
    property var block: ({})
    required property color foreground
    required property color background
    required property color accent
    signal openUrl(string url)
    // The host's "Ask about this" gate (latest finished answer, idle service,
    // and a plain `chart` block). Closed, there is no Ask control and `?` does
    // nothing. The part is the selected observation (the chart is ONE Tab stop).
    property bool canFocus: false
    // The person wants to ask about observation `index` (user-initiated).
    signal focusRequested(int index, string label, string detail)
    readonly property var askParts: root.canFocus ? AiState.askParts(root.block) : []
    readonly property var askPart: root.canFocus && root.selectedIndex >= 0 && root.selectedIndex < root.askParts.length
        ? root.askParts[root.selectedIndex] : null
    function askAbout() {
        var part = root.askPart;
        if (part) root.focusRequested(part.index, part.label, part.detail);
    }
    readonly property bool market: block.type === "market"
    readonly property string sourceUrl: String(block.sourceUrl || (/^https?:\/\//i.test(String(block.source || "")) ? block.source : ""))
    readonly property var points: normalizedPoints()
    property int selectedIndex: Math.max(0, points.length - 1)
    readonly property var selectedPoint: points.length ? points[Math.min(points.length - 1, Math.max(0, selectedIndex))] : null
    readonly property real minimum: points.length ? Math.min.apply(null, points.map(function(p) { return p.value; })) : 0
    readonly property real maximum: points.length ? Math.max.apply(null, points.map(function(p) { return p.value; })) : 1
    readonly property real paddingValue: Math.max((maximum - minimum) * 0.12, Math.abs(maximum) * 0.005, 0.01)
    readonly property real scaleMin: minimum - paddingValue
    readonly property real scaleMax: maximum + paddingValue
    readonly property real change: points.length ? points[points.length - 1].value - points[0].value : 0
    readonly property string changeText: !points.length ? "" : (change > 0 ? "+" : change < 0 ? "−" : "±") + number(Math.abs(change))
        + (points[0].value !== 0 ? " (" + (change > 0 ? "+" : change < 0 ? "−" : "±") + (Math.abs(change / points[0].value) * 100).toFixed(2) + "%)" : "") + qsTr(" over period")
    readonly property string errorText: String(block.error || (points.length ? "" : market ? qsTr("Historical prices have not been loaded.") : qsTr("No finite chart data is available.")))
    readonly property string summary: points.length ? String(block.title || qsTr("Chart")) + ". " + points.length + qsTr(" observations. First: ") + points[0].label + ", " + format(points[0].value)
        + qsTr(". Last: ") + points[points.length - 1].label + ", " + format(points[points.length - 1].value) + ". " + changeText : errorText
    implicitHeight: 276
    height: implicitHeight
    activeFocusOnTab: points.length > 0
    Accessible.role: Accessible.Chart
    Accessible.name: summary
    Accessible.description: qsTr("Use Left and Right to inspect observations; Home and End select the first and last.")

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    function number(v) {
        var precision = v !== 0 && Math.abs(v) < 1 ? Math.min(6, Math.max(2, Math.ceil(-Math.log10(Math.abs(v))) + 2)) : 2;
        return Number(v).toLocaleString(Qt.locale(), 'f', precision);
    }
    function format(v) { return number(v) + (block.unit ? " " + block.unit : ""); }
    function normalizedPoints() {
        var raw = market ? (block.points || []) : (block.values || []).map(function(v, i) { return {label: String((root.block.labels || [])[i] || (i + 1)), value: v}; });
        return raw.slice(0, 120).filter(function(p) { return p && typeof p.value === "number" && isFinite(p.value); }).map(function(p) { return {label: String(p.label || ""), value: p.value}; });
    }
    function pointX(i) { return plot.x + (points.length > 1 ? i / (points.length - 1) : 0.5) * plot.width; }
    function pointY(v) { return plot.y + (1 - (v - scaleMin) / (scaleMax - scaleMin)) * plot.height; }
    function select(i) { selectedIndex = Math.max(0, Math.min(points.length - 1, i)); }
    onPointsChanged: { selectedIndex = Math.max(0, points.length - 1); canvas.requestPaint(); }
    onWidthChanged: canvas.requestPaint()
    onForegroundChanged: canvas.requestPaint()
    onAccentChanged: canvas.requestPaint()
    Keys.onLeftPressed: select(selectedIndex - 1)
    Keys.onRightPressed: select(selectedIndex + 1)
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Question || event.text === "?") {
            if (root.askPart) { root.askAbout(); event.accepted = true; }
        }
        else if (event.key === Qt.Key_Home) { select(0); event.accepted = true; }
        else if (event.key === Qt.Key_End) { select(points.length - 1); event.accepted = true; }
    }

    Text {
        id: headline
        x: Satin.space.gutter
        y: Satin.space.tip
        width: parent.width - 2 * x - (askButton.visible ? askButton.width + Satin.space.tip : 0)
        text: root.selectedPoint ? root.format(root.selectedPoint.value) : qsTr("Chart unavailable")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.pixelSize: Satin.type.search
        font.weight: Font.DemiBold
        color: root.foreground
    }
    Text {
        x: headline.x
        y: 38
        width: headline.width
        text: root.selectedPoint ? (root.market && root.block.symbol ? String(root.block.symbol) + "  ·  " : "") + root.selectedPoint.label + "  ·  " + root.changeText : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.alpha(root.foreground, 0.76)
        font.pixelSize: Satin.type.label
    }
    AiAskButton {
        id: askButton
        objectName: "aiChartAsk"
        z: 2
        x: root.width - width - Satin.space.gutter
        y: Satin.space.tip
        visible: root.askPart !== null
        subject: root.askPart ? root.askPart.label : ""
        foreground: root.foreground
        surface: root.background
        accent: root.accent
        onClicked: root.askAbout()
    }
    Item {
        id: plot
        x: 72
        y: 76
        width: Math.max(1, root.width - x - Satin.space.gutter)
        height: 130
    }
    Canvas {
        id: canvas
        anchors.fill: parent
        visible: root.points.length > 0 && !root.block.error
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            if (!root.points.length) return;
            ctx.lineWidth = 1;
            ctx.strokeStyle = root.alpha(root.foreground, Satin.keyline.inner);
            for (var j = 0; j < 3; j++) {
                var gy = plot.y + j * plot.height / 2;
                ctx.beginPath(); ctx.moveTo(plot.x, gy); ctx.lineTo(plot.x + plot.width, gy); ctx.stroke();
            }
            var fill = ctx.createLinearGradient(0, plot.y, 0, plot.y + plot.height);
            fill.addColorStop(0, root.alpha(root.accent, 0.14));
            fill.addColorStop(1, root.alpha(root.accent, 0.01));
            ctx.beginPath();
            ctx.moveTo(root.pointX(0), plot.y + plot.height);
            for (var i = 0; i < root.points.length; i++) ctx.lineTo(root.pointX(i), root.pointY(root.points[i].value));
            ctx.lineTo(root.pointX(root.points.length - 1), plot.y + plot.height);
            ctx.closePath(); ctx.fillStyle = fill; ctx.fill();
            ctx.beginPath();
            for (var k = 0; k < root.points.length; k++) {
                if (k === 0) ctx.moveTo(root.pointX(k), root.pointY(root.points[k].value));
                else ctx.lineTo(root.pointX(k), root.pointY(root.points[k].value));
            }
            ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.strokeStyle = root.accent; ctx.stroke();
        }
    }
    Repeater {
        model: root.points.length && !root.block.error ? 3 : 0
        delegate: Text {
            required property int index
            x: Satin.space.base
            y: plot.y + index * plot.height / 2 - height / 2
            width: plot.x - Satin.space.tip
            text: root.number(root.scaleMax - index * (root.scaleMax - root.scaleMin) / 2)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
            font.pixelSize: Satin.type.label
            color: root.alpha(root.foreground, 0.76)
        }
    }
    Row {
        x: plot.x
        y: plot.y + plot.height + Satin.space.tip
        width: plot.width
        visible: root.points.length > 0 && !root.block.error
        Repeater {
            model: 2
            delegate: Text {
                required property int index
                width: plot.width / 2
                text: root.points.length ? root.points[index === 0 ? 0 : root.points.length - 1].label : ""
                textFormat: Text.PlainText
                horizontalAlignment: index === 0 ? Text.AlignLeft : Text.AlignRight
                elide: Text.ElideRight
                font.pixelSize: Satin.type.label
                color: root.alpha(root.foreground, 0.76)
            }
        }
    }
    Rectangle {
        visible: root.selectedPoint !== null && !root.block.error
        x: root.pointX(root.selectedIndex)
        y: plot.y
        width: 1
        height: plot.height
        color: root.alpha(root.foreground, 0.25)
    }
    Rectangle {
        visible: root.selectedPoint !== null && !root.block.error
        x: root.pointX(root.selectedIndex) - width / 2
        y: (root.selectedPoint ? root.pointY(root.selectedPoint.value) : plot.y) - height / 2
        width: 8
        height: width
        radius: width / 2
        color: root.accent
        border.width: 2
        border.color: root.background
    }
    MouseArea {
        id: scrub
        x: plot.x
        y: plot.y
        width: plot.width
        height: plot.height
        enabled: root.points.length > 0 && !root.block.error
        hoverEnabled: true
        onPositionChanged: function(mouse) { root.select(Math.round(mouse.x / width * (root.points.length - 1))); }
        onClicked: root.forceActiveFocus(Qt.MouseFocusReason)
        ToolTip.visible: containsMouse && root.selectedPoint !== null
        ToolTip.text: root.selectedPoint ? root.selectedPoint.label + " · " + root.format(root.selectedPoint.value) : ""
        ToolTip.delay: Satin.motion.tipDelay
    }
    Text {
        objectName: "aiChartError"
        x: Satin.space.gutter
        y: plot.y
        width: root.width - 2 * x
        height: plot.height
        visible: root.errorText.length > 0
        text: root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        color: root.alpha(root.foreground, 0.76)
        font.pixelSize: Satin.type.meta
        Accessible.name: text
    }
    Button {
        id: source
        objectName: "aiChartSource"
        x: Satin.space.base
        y: 238
        width: root.width - 2 * x
        height: 36
        padding: Satin.space.tip
        text: (root.market ? qsTr("Historical · not live") + (root.sourceUrl ? " · " + root.sourceUrl.replace(/^https?:\/\//i, "").split("/")[0] : "") : qsTr("Source: ") + String(root.sourceUrl || qsTr("not provided")))
            + (root.block.asOf ? " · " + String(root.block.asOf) : "")
        enabled: AiState.sourceCommand(root.sourceUrl).length > 0
        activeFocusOnTab: true
        onClicked: root.openUrl(root.sourceUrl)
        Accessible.name: text + (enabled ? qsTr(". Open source") : "")
        contentItem: Text {
            text: source.text + (source.enabled ? " ↗" : "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.pixelSize: Satin.type.label
            color: root.alpha(root.foreground, 0.76)
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: Satin.radius.chip
            color: source.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
            border.width: source.visualFocus ? 2 : 0
            border.color: root.accent
        }
    }
    Rectangle {
        anchors.fill: parent
        z: -1
        radius: Satin.radius.field
        color: root.alpha(root.foreground, 0.025)
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)
    }
}
