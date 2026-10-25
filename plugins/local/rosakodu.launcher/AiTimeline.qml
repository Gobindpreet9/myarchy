pragma ComponentBehavior: Bound

import QtQuick
import "SatinGlass.js" as Satin
import "AiTimelineView.js" as View
import "AiCompareView.js" as Scroll

// A model-authored schedule / itinerary / route / recipe (2..16 items with a
// free-text `when`, an optional duration in minutes and a detail line). The
// model supplies text and numbers only; every parse, bound and restore rule is
// AiTimelineView.js (pure, tested). Block text is model text: PlainText only.
//
// Layout. A vertical rail with one node per item. Wide (>= 420 px): the `when`
// column (sized to the widest `when`, capped at 30% of the width, wrapping) sits
// left of the rail, the label (regular weight), a quiet detail and a duration
// line (bar + the duration as TEXT) to its right. Narrow: `when` moves above the
// label inside the same row. Bars are proportional to the LONGEST item and never
// thinner than 6 px; the line under the list ('Total: N h M min', only when two
// or more items state a duration) is the plain sum - no clock times are derived.
//
// State. `saved` is the persisted `plan:<blockIndex>` entry {done: [index...]}
// (authored item indexes, deduped, ascending). This component keeps no second
// copy: a click or Space composes the full next entry from the PERSISTED one
// and emits it (stateEdited); the display follows `saved`, so a host that
// refuses an edit leaves the timeline showing what is stored. Done is a check
// glyph, the word 'Done' and a dimmed (never below 0.76) row, never colour,
// strike-through or position alone.
//
// Execution header: next unfinished is derived from persisted authored indexes,
// never a new saved cursor or a second actionable list. Its button reveals and
// focuses the actual row. Progress lives here, once; stated totals stay below.
// Keyboard: ONE row Tab stop (the cursor; roving, real focus moves). Up/Down
// move between rows, Home/End jump, Space/Enter toggle done, `?` asks about the
// row when the host opens `canFocus`. The header jump and footer Reset are real
// additional button stops. Escape
// and every other key are not handled here.
Column {
    id: root
    objectName: "aiTimeline"
    spacing: Satin.space.tip

    property var block: ({})
    property int blockIndex: 0
    // The persisted `plan:<blockIndex>` entry (undefined when untouched).
    property var saved: undefined
    required property color foreground
    required property color background
    required property color accent

    // The complete next `plan:<blockIndex>` object.
    signal stateEdited(var state)
    // Ask about one row (the shared `?`-on-the-focused-part convention, like
    // AiActions): the AUTHORED item index, its label and '<when>; <duration>;
    // <detail>'. Inert unless the host opens `canFocus` (its ask gate); with the
    // default false nothing is emitted. Space/Enter keep toggling done.
    property bool canFocus: false
    signal focusRequested(int index, string label, string detail)

    readonly property string invalidText: qsTr("This timeline can't be shown.")
    // Depends on the block only: a done toggle must never rebuild the rows.
    readonly property var spec: View.normalize(root.block)
    readonly property bool usable: root.spec !== null
    readonly property var items: root.usable ? root.spec.items : []
    readonly property var fractions: View.barFractions(root.items)
    readonly property var doneList: View.restoreDone(root.items, root.saved)
    readonly property var doneSet: {
        var set = {};
        for (var i = 0; i < root.doneList.length; ++i) set[root.doneList[i]] = true;
        return set;
    }
    readonly property int doneCount: root.doneList.length
    readonly property int nextRow: View.nextUnfinished(root.items, root.saved)
    readonly property var nextItem: root.nextRow >= 0 ? root.items[root.nextRow] : null
    readonly property bool allDone: root.usable && root.nextRow < 0
    readonly property string totalText: View.totalText(root.items)
    // Roving cursor: the one row that is a Tab stop.
    property int cursor: 0
    readonly property int cursorRow: Math.min(Math.max(0, root.cursor), Math.max(0, root.items.length - 1))

    // ---- geometry -----------------------------------------------------------
    readonly property bool narrow: root.width < 420
    readonly property real hpad: Satin.space.tip
    readonly property real vpad: Satin.space.tip
    readonly property real nodeSize: Satin.type.result
    readonly property real minRow: 36
    readonly property real barHeight: 6
    // One height for every footer item, so Reset appearing never moves a line.
    readonly property real footerRow: 30
    readonly property real whenNatural: {
        var widest = 0;
        for (var i = 0; i < root.items.length; ++i)
            if (root.items[i].when !== "") widest = Math.max(widest, Math.ceil(whenMetrics.advanceWidth(root.items[i].when)));
        return widest;
    }
    readonly property real whenW: root.narrow || root.whenNatural <= 0 ? 0
        : Math.min(root.whenNatural + 1, Math.floor(root.width * 0.30))
    readonly property real railX: root.hpad + (root.whenW > 0 ? root.whenW + Satin.space.gutter : 0)
    readonly property real contentX: root.railX + root.nodeSize + Satin.space.gutter
    readonly property real contentW: Math.max(0, root.width - root.contentX - root.hpad)
    readonly property real durationW: {
        var widest = 0;
        for (var i = 0; i < root.items.length; ++i)
            if (root.items[i].duration !== "") widest = Math.max(widest, Math.ceil(durationMetrics.advanceWidth(root.items[i].duration)));
        return widest;
    }
    readonly property string doneText: qsTr("Done")
    readonly property real doneW: Math.ceil(doneMetrics.advanceWidth(root.doneText))
    // Room for the longest bar: the content width minus its own duration text
    // and the 'Done' text, so a checked row keeps both on one line.
    readonly property real barRoom: Math.max(0, root.contentW - root.durationW - root.doneW
        - Satin.space.tip - Satin.space.gutter)

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }

    // The cursor follows focus (a row's onActiveFocusChanged): Qt refuses to
    // clear `activeFocusOnTab` on the row that still holds the focus.
    function moveTo(row) {
        if (row < 0 || row >= root.items.length) return;
        var target = rows.itemAt(row);
        if (target) {
            target.forceActiveFocus(Qt.TabFocusReason);
            Scroll.reveal(target, root.parent);
        }
    }
    function revealCursor() {
        Scroll.reveal(rows.itemAt(root.cursorRow), root.parent);
    }
    function goToNext() { if (root.nextRow >= 0) root.moveTo(root.nextRow); }
    function reopenFirst() { root.moveTo(0); }
    // Polite live text: the progress line is announced after a person's change.
    function announce(count) {
        try {
            var attached = progress.Accessible;
            if (attached && typeof attached.announce === "function")
                attached.announce(View.progressText(count, root.items.length), Accessible.Polite);
        } catch (e) {}
    }
    function toggle(itemIndex) {
        var next = View.toggled(root.items, root.saved, itemIndex);
        if (next === null) return;
        root.stateEdited({done: next});
        root.announce(next.length);
    }
    function reset() {
        if (root.doneCount === 0) return;
        root.stateEdited({done: []});
        root.announce(0);
        // Reset reopens the plan at its first actual row, including after all
        // items were completed. It is the user's action, never restore work.
        Qt.callLater(root.reopenFirst);
    }

    Accessible.role: Accessible.List
    Accessible.name: root.usable && root.spec.title !== "" ? root.spec.title : qsTr("Timeline")

    FontMetrics {
        id: whenMetrics
        font.pixelSize: Satin.type.meta
    }
    FontMetrics {
        id: durationMetrics
        font.pixelSize: Satin.type.meta
    }
    FontMetrics {
        id: doneMetrics
        font.pixelSize: Satin.type.meta
        font.weight: Font.DemiBold
    }

    Text {
        objectName: "aiTimelineInvalid"
        width: root.width
        visible: !root.usable
        text: root.invalidText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.body
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    Column {
        id: header
        objectName: "aiTimelineHeader"
        x: root.hpad
        width: Math.max(0, root.width - root.hpad * 2)
        visible: root.usable
        spacing: Satin.space.tip

        Flow {
            width: header.width
            spacing: Satin.space.gutter

            Text {
                objectName: "aiTimelineNextHeading"
                width: Math.min(implicitWidth, header.width)
                text: root.allDone ? qsTr("COMPLETED") : qsTr("NEXT UNFINISHED")
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.header
                font.letterSpacing: 1
                font.weight: Font.DemiBold
                Accessible.ignored: true
            }
            Text {
                id: progress
                objectName: "aiTimelineProgress"
                width: Math.min(implicitWidth, header.width)
                text: View.progressText(root.doneCount, root.items.length)
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.meta
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }
        Text {
            objectName: "aiTimelineNextLabel"
            width: header.width
            text: root.nextItem ? root.nextItem.label : qsTr("All items done")
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: root.foreground
            font.pixelSize: Satin.type.prompt
            font.weight: Font.Medium
            Accessible.role: Accessible.StaticText
            Accessible.name: root.nextItem ? qsTr("Next unfinished: %1").arg(text) : text
        }
        AiButton {
            id: nextButton
            objectName: "aiTimelineNext"
            visible: root.nextRow >= 0
            width: Math.min(implicitWidth, header.width)
            implicitHeight: Math.max(34, contentItem.implicitHeight + topPadding + bottomPadding)
            text: qsTr("Go to next unfinished")
            foreground: root.foreground
            accent: root.accent
            Accessible.role: Accessible.Button
            Accessible.description: root.nextItem ? qsTr("Focus %1 in the timeline; does not mark it done").arg(root.nextItem.label) : ""
            contentItem: Text {
                text: nextButton.text
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, nextButton.hovered || nextButton.visualFocus ? 1 : 0.80)
                font.pixelSize: Satin.type.meta
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: root.goToNext()
        }
        Rectangle {
            objectName: "aiTimelineProgressTrack"
            width: header.width
            height: Satin.rail.height
            radius: height / 2
            color: root.alpha(root.foreground, Satin.keyline.hair)
            Accessible.ignored: true
            Rectangle {
                objectName: "aiTimelineProgressFill"
                width: parent.width * (root.items.length > 0 ? root.doneCount / root.items.length : 0)
                height: parent.height
                radius: height / 2
                color: root.accent
            }
        }
    }

    Column {
        id: list
        objectName: "aiTimelineList"
        width: root.width
        visible: root.usable
        spacing: 0

        Repeater {
            id: rows
            model: root.items

            delegate: Item {
                id: row
                required property var modelData
                required property int index

                readonly property bool done: root.doneSet[modelData.i] === true
                readonly property bool first: index === 0
                readonly property bool last: index === root.items.length - 1
                readonly property bool hovered: hover.hovered
                readonly property real labelLine: label.contentHeight / Math.max(1, label.lineCount)
                readonly property real whenLine: whenText.contentHeight / Math.max(1, whenText.lineCount)
                readonly property real contentTop: root.vpad + (root.narrow && whenText.visible ? whenText.height + 2 : 0)
                readonly property real nodeCenter: contentTop + labelLine / 2
                readonly property real whenBottom: !root.narrow && whenText.visible ? whenText.y + whenText.height : 0

                objectName: "aiTimelineRow_" + index
                width: list.width
                height: Math.max(root.minRow, Math.max(contentTop + body.height, whenBottom) + root.vpad)
                activeFocusOnTab: index === root.cursorRow
                onActiveFocusChanged: {
                    if (activeFocus) {
                        root.cursor = index;
                        Qt.callLater(root.revealCursor);
                    }
                }

                Accessible.role: Accessible.CheckBox
                Accessible.name: View.rowName(modelData, done)
                Accessible.description: modelData.detail
                Accessible.checkable: true
                Accessible.checked: done
                Accessible.focusable: true
                Accessible.onPressAction: root.toggle(modelData.i)
                Accessible.onToggleAction: root.toggle(modelData.i)

                Keys.onPressed: function(event) {
                    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
                    if (event.key === Qt.Key_Question || event.text === "?") {
                        if (!root.canFocus) return;
                        if (!event.isAutoRepeat) {
                            var part = View.askPart(row.modelData);
                            root.focusRequested(part.index, part.label, part.detail);
                        }
                        event.accepted = true;
                        return;
                    }
                    var last = root.items.length - 1;
                    switch (event.key) {
                    case Qt.Key_Up: root.moveTo(Math.max(0, row.index - 1)); break;
                    case Qt.Key_Down: root.moveTo(Math.min(last, row.index + 1)); break;
                    case Qt.Key_Home: root.moveTo(0); break;
                    case Qt.Key_End: root.moveTo(last); break;
                    case Qt.Key_Space:
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        if (!event.isAutoRepeat) root.toggle(row.modelData.i);
                        break;
                    default: return;
                    }
                    event.accepted = true;
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Satin.radius.chip
                    color: row.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                    border.width: row.activeFocus ? 2 : 0
                    border.color: root.accent
                }

                // The rail: a hairline through every node, ending at the first
                // and last node.
                Rectangle {
                    objectName: "aiTimelineRail_" + row.index
                    x: root.railX + (root.nodeSize - width) / 2
                    y: row.first ? row.nodeCenter : 0
                    width: 2
                    height: Math.max(0, (row.last ? row.nodeCenter : row.height) - y)
                    color: root.alpha(root.foreground, 0.30)
                }

                Rectangle {
                    id: node
                    objectName: "aiTimelineNode_" + row.index
                    x: root.railX
                    y: row.nodeCenter - height / 2
                    width: root.nodeSize
                    height: width
                    radius: width / 2
                    color: row.done ? root.accent : root.background
                    border.width: 2
                    border.color: row.done ? root.accent : root.alpha(root.foreground, 0.76)
                    Text {
                        objectName: "aiTimelineCheck_" + row.index
                        anchors.centerIn: parent
                        visible: row.done
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.background
                        font.pixelSize: Satin.type.label
                        font.weight: Font.Bold
                        Accessible.ignored: true
                    }
                }

                Text {
                    id: whenText
                    objectName: "aiTimelineWhen_" + row.index
                    x: root.narrow ? root.contentX : root.hpad
                    y: root.vpad + (root.narrow ? 0 : Math.max(0, (row.labelLine - row.whenLine) / 2))
                    width: root.narrow ? root.contentW : root.whenW
                    visible: row.modelData.when !== ""
                    text: row.modelData.when
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: root.alpha(root.foreground, row.done ? 0.76 : 0.80)
                    font.pixelSize: Satin.type.meta
                    Accessible.ignored: true
                }

                Column {
                    id: body
                    x: root.contentX
                    y: row.contentTop
                    width: root.contentW
                    spacing: 2

                    Text {
                        id: label
                        objectName: "aiTimelineLabel_" + row.index
                        width: body.width
                        text: row.modelData.label
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: root.alpha(root.foreground, row.done ? 0.80 : 1.0)
                        font.pixelSize: Satin.type.result
                        Accessible.ignored: true
                    }
                    Text {
                        objectName: "aiTimelineDetail_" + row.index
                        width: body.width
                        visible: text.length > 0
                        text: row.modelData.detail
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: root.alpha(root.foreground, row.done ? 0.76 : 0.80)
                        font.pixelSize: Satin.type.meta
                        Accessible.ignored: true
                    }
                    Flow {
                        id: meta
                        width: body.width
                        visible: row.modelData.minutes > 0 || row.done
                        spacing: Satin.space.gutter

                        Row {
                            objectName: "aiTimelineSpan_" + row.index
                            visible: row.modelData.minutes > 0
                            spacing: Satin.space.tip
                            Rectangle {
                                objectName: "aiTimelineBar_" + row.index
                                anchors.verticalCenter: parent.verticalCenter
                                width: View.barWidth(root.fractions[row.index], row.modelData.minutes, root.barRoom)
                                height: root.barHeight
                                radius: height / 2
                                color: root.alpha(root.accent, row.done ? 0.60 : 0.90)
                            }
                            Text {
                                objectName: "aiTimelineDuration_" + row.index
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.duration
                                textFormat: Text.PlainText
                                color: root.alpha(root.foreground, row.done ? 0.76 : 0.80)
                                font.pixelSize: Satin.type.meta
                                Accessible.ignored: true
                            }
                        }
                        Text {
                            objectName: "aiTimelineDone_" + row.index
                            visible: row.done
                            text: root.doneText
                            textFormat: Text.PlainText
                            color: root.alpha(root.foreground, 0.80)
                            font.pixelSize: Satin.type.meta
                            font.weight: Font.DemiBold
                            Accessible.ignored: true
                        }
                    }
                }

                HoverHandler { id: hover }
                TapHandler {
                    onTapped: {
                        row.forceActiveFocus(Qt.MouseFocusReason);
                        root.toggle(row.modelData.i);
                    }
                }
            }
        }
    }

    Flow {
        id: footer
        objectName: "aiTimelineFooter"
        width: root.width
        leftPadding: root.hpad
        rightPadding: root.hpad
        visible: root.usable && (root.totalText !== "" || root.doneCount > 0)
        spacing: Satin.space.gutter

        Text {
            objectName: "aiTimelineTotal"
            height: root.footerRow
            verticalAlignment: Text.AlignVCenter
            visible: root.totalText !== ""
            text: root.totalText
            textFormat: Text.PlainText
            color: root.alpha(root.foreground, 0.80)
            font.pixelSize: Satin.type.meta
            font.weight: Font.DemiBold
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
        AiButton {
            objectName: "aiTimelineReset"
            visible: root.doneCount > 0
            text: qsTr("Reset")
            foreground: root.foreground
            accent: root.accent
            implicitHeight: root.footerRow
            Accessible.description: qsTr("Clear every done mark")
            onClicked: root.reset()
        }
    }
}
