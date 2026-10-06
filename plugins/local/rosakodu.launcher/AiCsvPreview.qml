pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin

Item {
    id: root

    required property color foreground
    required property color background
    required property color accent
    property string status: "idle"
    property var preview: ({})
    property string error: ""
    signal retryRequested()

    // The host owns reading and cancellation. Never retain a full dataset or
    // instantiate hidden grid delegates while idle, loading or errored.
    readonly property var shownColumns: status === "ready" && preview && Array.isArray(preview.columns)
        ? preview.columns.slice(0, 20) : []
    readonly property var shownRows: status === "ready" && preview && Array.isArray(preview.rows)
        ? preview.rows.slice(0, Math.max(0, Math.min(10,
            typeof preview.previewRows === "number" ? preview.previewRows : preview.rows.length))) : []
    readonly property string countText: shownRows.length + " of "
        + (preview && typeof preview.totalRows === "number" ? preview.totalRows : "unknown")
        + " rows · " + shownColumns.length + " of "
        + (preview && typeof preview.columnCount === "number" ? preview.columnCount : shownColumns.length)
        + " columns"
    readonly property string disclosureText: {
        var lines = []
        if (preview && preview.note) lines.push(String(preview.note))
        if (preview && preview.columnsTruncated) lines.push("Only the first 20 columns are included in the snapshot.")
        if (preview && preview.cellsTruncated) lines.push("Some header or cell values were shortened in the snapshot.")
        if (preview && preview.truncated) lines.push("The snapshot is limited; it does not contain the complete source.")
        lines.push("Long values may be clipped in the grid.")
        return lines.join("\n")
    }

    implicitWidth: 660
    implicitHeight: status === "idle" ? 0 : body.implicitHeight
    visible: status !== "idle"

    Column {
        id: body
        width: root.width
        spacing: Satin.space.tip

        Text {
            objectName: "aiCsvPreviewTitle"
            width: parent.width
            text: "CSV preview"
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.foreground
            font.pixelSize: Satin.type.meta
            font.weight: Font.DemiBold
            Accessible.role: Accessible.Heading
        }

        Text {
            objectName: "aiCsvPreviewLoading"
            visible: root.status === "loading"
            width: parent.width
            text: "Reading CSV…"
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Qt.alpha(root.foreground, 0.80)
            font.pixelSize: Satin.type.meta
            Accessible.name: text
        }

        Text {
            objectName: "aiCsvPreviewError"
            visible: root.status === "error"
            width: parent.width
            text: root.error || "CSV preview is unavailable."
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.foreground
            font.pixelSize: Satin.type.meta
            Accessible.name: text
        }

        AiButton {
            objectName: "aiCsvPreviewRetry"
            visible: root.status === "error"
            enabled: visible
            text: "Retry"
            foreground: root.foreground
            accent: root.accent
            focusPolicy: Qt.StrongFocus
            onClicked: root.retryRequested()
        }

        Loader {
            id: readyLoader
            objectName: "aiCsvPreviewReady"
            active: root.status === "ready"
            visible: active
            width: parent.width
            sourceComponent: readyContent
        }
    }

    Component {
        id: readyContent

        Column {
            spacing: Satin.space.tip

            Text {
                objectName: "aiCsvPreviewCount"
                width: parent.width
                text: root.countText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Qt.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }

            ScrollView {
                id: scroll
                objectName: "aiCsvPreviewScroll"
                // Decide overflow from the minimum grid size before reserving
                // tracks, so viewport sizing and scrollbar visibility cannot
                // create a circular padding/size binding.
                readonly property real minimumGridWidth: root.shownColumns.length * 120
                readonly property bool needsVerticalBar: pan.contentHeight + padding * 2 > 192
                    || (minimumGridWidth > width - padding * 2
                        && pan.contentHeight + padding * 2 + horizontalBar.height > 192)
                readonly property bool needsHorizontalBar: minimumGridWidth
                    > width - padding * 2 - (needsVerticalBar ? verticalBar.width : 0)
                width: parent.width
                height: Math.min(192, pan.contentHeight + padding * 2
                    + (needsHorizontalBar ? horizontalBar.height : 0))
                padding: Satin.space.base
                rightPadding: padding + (needsVerticalBar ? verticalBar.width : 0)
                bottomPadding: padding + (needsHorizontalBar ? horizontalBar.height : 0)
                clip: true
                focusPolicy: Qt.NoFocus
                background: Rectangle {
                    objectName: "aiCsvPreviewFocusRing"
                    radius: Satin.radius.chip
                    color: root.background
                    border.width: pan.activeFocus ? 2 : 1
                    border.color: pan.activeFocus ? root.accent : Qt.alpha(root.foreground, Satin.keyline.hair)
                }
                ScrollBar.horizontal: ScrollBar {
                    id: horizontalBar
                    // Replacing the style's bar also replaces its geometry.
                    // Reparent to the frame and place one track outside the
                    // Flickable, rather than auto-positioning a second track.
                    parent: scroll
                    x: scroll.leftPadding
                    y: scroll.height - scroll.padding - height
                    width: scroll.availableWidth
                    height: 10
                    policy: ScrollBar.AsNeeded
                    visible: pan.contentWidth > pan.width && size < 1
                    contentItem: Rectangle {
                        implicitWidth: 32
                        implicitHeight: 6
                        radius: 3
                        color: Qt.alpha(root.foreground, horizontalBar.pressed ? 0.6 : 0.3)
                    }
                    background: Item {}
                }
                ScrollBar.vertical: ScrollBar {
                    id: verticalBar
                    parent: scroll
                    x: scroll.width - scroll.padding - width
                    y: scroll.topPadding
                    width: 10
                    height: scroll.availableHeight
                    policy: ScrollBar.AsNeeded
                    visible: pan.contentHeight > pan.height && size < 1
                    contentItem: Rectangle {
                        implicitWidth: 6
                        implicitHeight: 32
                        radius: 3
                        color: Qt.alpha(root.foreground, verticalBar.pressed ? 0.6 : 0.3)
                    }
                    background: Item {}
                }

                Flickable {
                    id: pan
                    objectName: "aiCsvPreviewViewport"
                    readonly property int columnWidth: Math.max(120,
                        Math.floor(width / Math.max(1, root.shownColumns.length)))
                    readonly property int rowHeight: 32
                    contentWidth: root.shownColumns.length * columnWidth
                    contentHeight: (root.shownRows.length + 1) * rowHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Pane
                    Accessible.name: "CSV preview. Use arrow keys or Page Up and Page Down to scroll."

                    function moveBy(dx, dy) {
                        contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), contentX + dx))
                        contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + dy))
                    }

                    Keys.onPressed: function(event) {
                        switch (event.key) {
                        case Qt.Key_Left: moveBy(-columnWidth, 0); break
                        case Qt.Key_Right: moveBy(columnWidth, 0); break
                        case Qt.Key_Up: moveBy(0, -rowHeight); break
                        case Qt.Key_Down: moveBy(0, rowHeight); break
                        case Qt.Key_PageUp: moveBy(0, -height); break
                        case Qt.Key_PageDown: moveBy(0, height); break
                        default: return
                        }
                        event.accepted = true
                    }
                    TapHandler { onTapped: pan.forceActiveFocus(Qt.MouseFocusReason) }

                    Repeater {
                        objectName: "aiCsvPreviewHeaders"
                        model: root.shownColumns.length
                        delegate: Rectangle {
                            id: headerCell
                            required property int index
                            x: index * pan.columnWidth
                            width: pan.columnWidth
                            height: pan.rowHeight
                            color: Qt.alpha(root.foreground, 0.06)
                            Text {
                                objectName: "aiCsvPreviewHeader" + headerCell.index
                                anchors.fill: parent
                                anchors.margins: Satin.space.tip
                                text: String(root.shownColumns[headerCell.index])
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: root.foreground
                                font.pixelSize: Satin.type.small
                                font.weight: Font.DemiBold
                                verticalAlignment: Text.AlignVCenter
                                Accessible.name: text
                            }
                        }
                    }

                    // Flat, bounded model: at most 200 data-cell delegates,
                    // plus at most 20 literal headers. No sorting or inference.
                    Repeater {
                        objectName: "aiCsvPreviewCells"
                        model: root.shownRows.length * root.shownColumns.length
                        delegate: Item {
                            id: dataCell
                            required property int index
                            readonly property int row: Math.floor(index / root.shownColumns.length)
                            readonly property int column: index % root.shownColumns.length
                            x: column * pan.columnWidth
                            y: (row + 1) * pan.rowHeight
                            width: pan.columnWidth
                            height: pan.rowHeight
                            Text {
                                objectName: "aiCsvPreviewCell" + dataCell.index
                                anchors.fill: parent
                                anchors.margins: Satin.space.tip
                                text: root.shownRows[dataCell.row][dataCell.column] === undefined
                                    ? "" : String(root.shownRows[dataCell.row][dataCell.column])
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Qt.alpha(root.foreground, 0.86)
                                font.pixelSize: Satin.type.small
                                verticalAlignment: Text.AlignVCenter
                                Accessible.name: text
                            }
                        }
                    }
                }
            }

            Text {
                objectName: "aiCsvPreviewFooter"
                width: parent.width
                text: "Local preview · UTF-8 · comma-separated · first row is the header. Source is read again when you send."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Qt.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }

            Text {
                objectName: "aiCsvPreviewDisclosure"
                width: parent.width
                text: root.disclosureText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Qt.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }
        }
    }
}
