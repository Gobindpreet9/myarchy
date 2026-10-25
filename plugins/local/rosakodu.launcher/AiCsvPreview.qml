pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "AiState.js" as AiState
import "CsvTypes.js" as CsvTypes
import "SatinGlass.js" as Satin

Item {
    id: root

    required property color foreground
    required property color background
    required property color accent
    property string status: "idle"
    property var preview: ({})
    property string error: ""
    // Per-column corrections for THIS preview only ("" = use the inference).
    // The host owns them and resets them with the attachment; this component
    // only displays them and asks (columnTypeChosen) for a change.
    property var typeOverrides: []
    // The host decides whether keeping the full data is on offer (a ready CSV
    // whose copy is not already kept) and whether it can start right now.
    // This component only shows the explicit action and emits the request.
    property bool keepVisible: false
    property bool keepEnabled: true
    // The host sets this when a durable source is ready or registering on an
    // expanded/detached surface: the card then starts as one summary line with a
    // Show/Hide toggle. Without a source the preview is always fully open.
    property bool collapsible: false
    property bool detailOpen: false
    readonly property bool collapsed: collapsible && !detailOpen
    onCollapsibleChanged: { if (!collapsible) detailOpen = false }
    signal retryRequested()
    signal keepFullDataRequested()
    signal columnTypeChosen(int column, string kind)

    // The host owns reading and cancellation. Never retain a full dataset or
    // instantiate hidden grid delegates while idle, loading or errored.
    readonly property var shownColumns: status === "ready" && preview && Array.isArray(preview.columns)
        ? preview.columns.slice(0, 20) : []
    readonly property var shownRows: status === "ready" && preview && Array.isArray(preview.rows)
        ? preview.rows.slice(0, Math.max(0, Math.min(10,
            typeof preview.previewRows === "number" ? preview.previewRows : preview.rows.length))) : []
    // Inferred from the rows shown (at most 10 x 20), never the whole file.
    readonly property var inferences: status === "ready" ? CsvTypes.inferColumns(shownColumns, shownRows) : []
    readonly property int correctedCount: CsvTypes.correctedCount(
        CsvTypes.normalizeOverrides(typeOverrides, shownColumns.length))
    readonly property string typeNote: "Types are inferred from the rows shown, not the whole file. Choose a header's type to correct it."
        + (correctedCount > 0 ? " Corrected: " + correctedCount + " (sent with your question)." : "")

    function overrideAt(column) {
        return typeOverrides && CsvTypes.isType(typeOverrides[column]) ? typeOverrides[column] : ""
    }
    readonly property string countText: shownRows.length + " of "
        + (preview && typeof preview.totalRows === "number" ? preview.totalRows : "unknown")
        + " rows · " + shownColumns.length + " of "
        + (preview && typeof preview.columnCount === "number" ? preview.columnCount : shownColumns.length)
        + " columns"
    readonly property string summaryText: "CSV preview · " + countText
        + (correctedCount > 0 ? " · " + correctedCount + " corrected" : "")
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
            visible: !(root.status === "ready" && root.collapsible)
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

        Text {
            objectName: "aiCsvPreviewHint"
            visible: root.status === "error" && text.length > 0
            width: parent.width
            text: AiState.previewAdvice(root.error)
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Qt.alpha(root.foreground, 0.80)
            font.pixelSize: Satin.type.small
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

            // Collapsible form: the title, counts and toggle share one line.
            RowLayout {
                objectName: "aiCsvPreviewSummaryRow"
                visible: root.collapsible
                width: parent.width
                spacing: Satin.space.tip

                Text {
                    objectName: "aiCsvPreviewSummary"
                    Layout.fillWidth: true
                    text: root.summaryText
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Qt.alpha(root.foreground, 0.80)
                    font.pixelSize: Satin.type.small
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }

                AiButton {
                    objectName: "aiCsvPreviewToggle"
                    text: root.collapsed ? "Show" : "Hide"
                    foreground: root.foreground
                    accent: root.accent
                    focusPolicy: Qt.StrongFocus
                    Accessible.name: "CSV preview, " + (root.collapsed ? "collapsed" : "expanded")
                    Accessible.description: root.collapsed
                        ? "Show the rows, column types and disclosures."
                        : "Hide the rows, column types and disclosures."
                    onClicked: root.detailOpen = !root.detailOpen
                }
            }

            // Rows, type controls and disclosures exist only while shown.
            Loader {
                objectName: "aiCsvPreviewDetail"
                active: !root.collapsed
                visible: active
                width: parent.width
                sourceComponent: detailContent
            }
        }
    }

    Component {
        id: detailContent

        Column {
            spacing: Satin.space.tip

            Text {
                objectName: "aiCsvPreviewCount"
                visible: !root.collapsible
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

                    // Roving focus: the type badges are ONE Tab stop (the badge
                    // last used, the first at the start). Arrows, Home and End
                    // move between them; Space/Return/Down open the type menu.
                    property int badgeIndex: 0
                    readonly property int tabBadge: Math.max(0, Math.min(badgeIndex, root.shownColumns.length - 1))

                    signal badgeFocusRequested(int column)
                    function focusBadge(column) { badgeFocusRequested(column) }

                    // Returns true when the key belonged to the badge strip.
                    function roveFrom(column, key) {
                        var last = root.shownColumns.length - 1
                        switch (key) {
                        case Qt.Key_Left: focusBadge(Math.max(0, column - 1)); return true
                        case Qt.Key_Right: focusBadge(Math.min(last, column + 1)); return true
                        case Qt.Key_Home: focusBadge(0); return true
                        case Qt.Key_End: focusBadge(last); return true
                        }
                        return false
                    }

                    function moveBy(dx, dy) {
                        contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), contentX + dx))
                        contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + dy))
                    }

                    // Keep a keyboard-focused header control inside the viewport.
                    function revealColumn(column) {
                        var left = column * columnWidth
                        var next = contentX
                        if (left < contentX) next = left
                        else if (left + columnWidth > contentX + width) next = left + columnWidth - width
                        contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), next))
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
                            readonly property var inference: root.inferences[index]
                            readonly property string override: root.overrideAt(index)
                            readonly property string shown: CsvTypes.effectiveType(inference, override)
                            Text {
                                objectName: "aiCsvPreviewHeader" + headerCell.index
                                anchors.left: parent.left
                                anchors.right: typeButton.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: Satin.space.tip
                                anchors.rightMargin: Satin.space.tip
                                text: String(root.shownColumns[headerCell.index])
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: root.foreground
                                font.pixelSize: Satin.type.small
                                font.weight: Font.DemiBold
                                verticalAlignment: Text.AlignVCenter
                                Accessible.name: text
                            }
                            // The type indicator doubles as the correction control:
                            // a real Button, so Tab/Space/Return and the mouse both work.
                            Button {
                                id: typeButton
                                objectName: "aiCsvPreviewType" + headerCell.index
                                readonly property bool corrected: headerCell.override !== ""
                                anchors.right: parent.right
                                anchors.rightMargin: Satin.space.tip
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(36, typeLabel.implicitWidth + 14)
                                height: 22
                                padding: 0
                                hoverEnabled: true
                                // Only the roving badge is a Tab stop; the rest are
                                // reached by arrows or the mouse.
                                focusPolicy: headerCell.index === pan.tabBadge ? Qt.StrongFocus : Qt.ClickFocus
                                text: CsvTypes.shortLabel(headerCell.shown)
                                Accessible.role: Accessible.Button
                                Accessible.name: "Column " + String(root.shownColumns[headerCell.index]) + " type: "
                                    + CsvTypes.label(headerCell.shown) + (corrected ? ", corrected by you" : ", inferred")
                                    + ". Press to change."
                                Accessible.description: CsvTypes.describe(headerCell.inference, headerCell.override)
                                background: Rectangle {
                                    radius: Satin.radius.chip
                                    color: typeButton.down ? Qt.alpha(root.accent, 0.24)
                                        : typeButton.corrected ? Qt.alpha(root.accent, 0.14)
                                        : typeButton.hovered ? Qt.alpha(root.foreground, 0.10) : "transparent"
                                    border.width: typeButton.visualFocus ? 2 : 1
                                    border.color: typeButton.visualFocus ? root.accent
                                        : typeButton.corrected ? Qt.alpha(root.accent, 0.9)
                                        : Qt.alpha(root.foreground, 0.30)
                                }
                                contentItem: Text {
                                    id: typeLabel
                                    text: typeButton.text + " ▾"
                                    textFormat: Text.PlainText
                                    color: typeButton.corrected ? root.accent : Qt.alpha(root.foreground, 0.86)
                                    font.pixelSize: Satin.type.label
                                    font.weight: typeButton.corrected ? Font.DemiBold : Font.Medium
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                Connections {
                                    target: pan
                                    function onBadgeFocusRequested(column) {
                                        if (column === headerCell.index) typeButton.forceActiveFocus(Qt.TabFocusReason)
                                    }
                                }
                                onClicked: typeMenu.openFor(typeButton, headerCell.index)
                                onActiveFocusChanged: {
                                    if (!activeFocus) return
                                    pan.badgeIndex = headerCell.index
                                    pan.revealColumn(headerCell.index)
                                }
                                Keys.onPressed: function(event) {
                                    if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        typeMenu.openFor(typeButton, headerCell.index)
                                        event.accepted = true
                                    } else if (pan.roveFrom(headerCell.index, event.key)) {
                                        event.accepted = true
                                    }
                                }
                            }
                        }
                    }

                    // Flat, bounded model: at most 200 data-cell delegates,
                    // plus at most 20 literal headers, each with one type control.
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

            Menu {
                id: typeMenu
                objectName: "aiCsvPreviewTypeMenu"
                property int column: -1
                // The ring comes back only if the menu was opened from the keyboard.
                property int returnReason: Qt.TabFocusReason
                readonly property string current: column >= 0 ? root.overrideAt(column) : ""
                readonly property string inferredLabel: column >= 0 && root.inferences[column]
                    ? CsvTypes.label(root.inferences[column].type) : ""
                function openFor(button, index) {
                    returnReason = button.visualFocus ? Qt.TabFocusReason : Qt.MouseFocusReason
                    column = index
                    parent = button
                    x = 0
                    y = button.height + 2
                    open()
                }
                width: 250
                padding: 6
                margins: 4
                background: Rectangle {
                    color: root.background
                    radius: Satin.radius.chip
                    border.width: 1
                    border.color: Qt.alpha(root.foreground, 0.3)
                }
                // Return focus to the header control that opened the menu.
                onClosed: {
                    if (parent && typeof parent.forceActiveFocus === "function") {
                        // Drop first so the focus reason is set again instead of
                        // keeping the popup's restored "other" reason.
                        parent.focus = false
                        parent.forceActiveFocus(returnReason)
                    }
                }
                Repeater {
                    model: ["number", "date", "text", ""]
                    MenuItem {
                        id: typeItem
                        required property string modelData
                        required property int index
                        objectName: "aiCsvPreviewTypeItem" + index
                        readonly property bool chosen: typeMenu.current === modelData
                        text: modelData === "" ? "Use the inferred type (" + typeMenu.inferredLabel + ")"
                            : CsvTypes.label(modelData)
                        implicitHeight: 34
                        Accessible.name: text + (chosen ? ", selected" : "")
                        contentItem: Text {
                            text: (typeItem.chosen ? "\u2713 " : "    ") + typeItem.text
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.pixelSize: Satin.type.meta
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: Satin.radius.chip
                            color: typeItem.highlighted ? Qt.alpha(root.accent, 0.18) : "transparent"
                            border.width: typeItem.visualFocus ? 2 : 0
                            border.color: root.accent
                        }
                        onTriggered: root.columnTypeChosen(typeMenu.column, modelData)
                    }
                }
            }

            Text {
                objectName: "aiCsvPreviewTypeNote"
                width: parent.width
                text: root.typeNote
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Qt.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.name: text
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

            AiButton {
                objectName: "aiCsvPreviewKeep"
                visible: root.keepVisible
                enabled: root.keepEnabled
                text: "Keep full data"
                foreground: root.foreground
                accent: root.accent
                focusPolicy: Qt.StrongFocus
                onClicked: root.keepFullDataRequested()
            }

            Text {
                objectName: "aiCsvPreviewKeepNote"
                visible: root.keepVisible
                width: parent.width
                text: "Copies this file into private launcher storage so you can browse and sort every row."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Qt.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }
        }
    }
}
