pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiCalc.js" as Calc
import "AiCalcEdit.js" as Edit
import "AiScroll.js" as Scroll

// Editable table grid for a typed calc block. It NEVER mutates data: a typed
// value is checked with AiCalcEdit.parseCell for the column kind and only a
// parse-valid one is emitted (cellCommitted); the host applies it and hands back
// a new `table`. Formula columns are read-only and show the engine's text.
//
// Keyboard: the whole grid is ONE roving Tab stop (the active cell). Arrows,
// Home/End and Ctrl+Home/Ctrl+End move it (the horizontal scroll follows);
// Enter, F2 or a printable key opens the single shared editor over an editable
// cell; Enter commits and moves down, Esc reverts, Tab commits and leaves for the
// next control. An invalid value keeps the editor open with an inline message.
// Cells are PlainText `Text` delegates (<= 40 rows x 12 columns) plus ONE TextField.
Column {
    id: root
    objectName: "aiCalcGrid"
    spacing: 4

    // Effective table {id,label,columns:[{id,label,unit,kind}],rows:[[string]],rowIds:[string]}.
    required property var table
    // Engine result.nodes (display errors) and Calc.formatCell by node id.
    required property var nodes
    required property var formatText
    // {"rowId|colId": true}
    property var editedKeys: ({})
    property bool canAdd: true
    property string addBlockedReason: ""
    required property color foreground
    required property color background
    required property color accent

    signal cellCommitted(string rowId, string colId, string text)
    signal clearRequested(string rowId, string colId)
    signal addRowRequested()
    signal removeRowRequested(string rowId)

    // ---- bounds and metrics ------------------------------------------------
    readonly property int collapsedRows: 12
    readonly property int minColumnWidth: 72
    readonly property int rowHeight: 28
    readonly property int headerHeight: 32
    readonly property int cellGap: Satin.space.base
    readonly property int colCount: root.table && root.table.columns ? Math.min(root.table.columns.length, Calc.maxColumns) : 0
    readonly property int rowTotal: root.table && root.table.rows ? Math.min(root.table.rows.length, Calc.maxRows) : 0
    // Opt-in expansion beyond the first 12 rows (host may bind or ignore it).
    property bool expanded: false
    readonly property int shownRows: expanded ? rowTotal : Math.min(rowTotal, collapsedRows)
    readonly property real colWidth: colCount > 0
        ? Math.max(minColumnWidth, (width - (colCount - 1) * cellGap) / colCount) : 0
    readonly property real gridWidth: colCount * colWidth + Math.max(0, colCount - 1) * cellGap
    readonly property real rowsTop: headerHeight + 3
    readonly property int delegateCount: cells.count

    // ---- active cell and editing ---------------------------------------------
    property int wantRow: 0
    property int wantCol: 0
    readonly property int activeRow: Math.max(0, Math.min(wantRow, shownRows - 1))
    readonly property int activeCol: Math.max(0, Math.min(wantCol, colCount - 1))
    property bool editing: false
    property string editRowId: ""
    property string editColId: ""
    readonly property string errorText: summarize(root.errorList)
    readonly property var errorList: collectErrors(root.table, root.nodes)

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function columnAt(c) { return root.table && root.table.columns && c >= 0 && c < root.colCount ? root.table.columns[c] : null; }
    function rowIdAt(r) {
        var ids = root.table ? root.table.rowIds : null;
        return ids && r >= 0 && r < ids.length ? String(ids[r]) : String(r);
    }
    function isFormula(c) { var col = columnAt(c); return !col || (col.kind !== "number" && col.kind !== "text"); }
    function unitOf(col) {
        var u = col.unitText !== undefined && col.unitText !== null ? col.unitText : col.unit;
        return typeof u === "string" ? u : "";
    }
    function headerText(c) {
        var col = columnAt(c);
        if (!col) return "";
        var unit = col.kind !== "text" ? unitOf(col) : "";
        return String(col.label === undefined || col.label === null ? "" : col.label) + (unit ? " (" + unit + ")" : "");
    }
    function nodeId(r, c) { return root.table.id + "." + root.table.columns[c].id + "#" + (r + 1); }
    function errorOf(r, c) {
        var n = root.nodes && columnAt(c) && isFormula(c) ? root.nodes[nodeId(r, c)] : undefined;
        return n && n.err ? n.err : null;
    }
    function cellText(r, c) {
        var col = columnAt(c);
        if (!col) return "";
        if (isFormula(c)) {
            var id = nodeId(r, c), t = "";
            if (typeof root.formatText === "function") {
                var v = root.formatText(id);
                t = v === null || v === undefined ? "" : String(v);
            }
            if (t === "" && errorOf(r, c)) t = "\u2014";
            return t;
        }
        var row = root.table.rows[r], raw = row ? row[c] : "";
        return raw === null || raw === undefined ? "" : String(raw);
    }
    function alignOf(c) { var col = columnAt(c); return col && col.kind === "text" ? Text.AlignLeft : Text.AlignRight; }
    function isEdited(r, c) {
        var col = columnAt(c);
        return !!col && !!root.editedKeys && root.editedKeys[rowIdAt(r) + "|" + col.id] === true;
    }
    function describe(r, c) {
        if (isEdited(r, c)) return qsTr("edited");
        return isFormula(c) ? qsTr("calculated") : qsTr("editable");
    }
    // 'Row 2, Price (EUR), 1800, editable' (+ ', edited' for a changed cell).
    function cellName(r, c) {
        if (root.shownRows <= 0 || root.colCount <= 0) return root.table && root.table.label ? root.table.label : qsTr("Calculation table");
        var text = cellText(r, c);
        var kind = isFormula(c) ? qsTr("calculated") : qsTr("editable");
        return qsTr("Row %1, %2, %3, %4").arg(r + 1).arg(headerText(c)).arg(text === "" ? qsTr("empty") : text).arg(kind)
            + (isEdited(r, c) ? qsTr(", edited") : "");
    }
    function collectErrors(table, nodes) {
        var out = [];
        if (!table || !table.columns || !table.rows || !nodes) return out;
        var cols = Math.min(table.columns.length, Calc.maxColumns), rows = Math.min(table.rows.length, Calc.maxRows);
        for (var r = 0; r < rows; ++r) {
            for (var c = 0; c < cols; ++c) {
                var kind = table.columns[c].kind;
                if (kind === "number" || kind === "text") continue;
                var id = table.id + "." + table.columns[c].id + "#" + (r + 1), n = nodes[id];
                if (!n || !n.err) continue;
                var msg = n.err.node === id ? qsTr("Cannot compute: ") + n.err.msg
                    : qsTr("Waiting on ") + n.err.node + ": " + n.err.msg;
                out.push({row: r + 1, column: String(table.columns[c].label), message: msg});
            }
        }
        return out;
    }
    function summarize(list) {
        if (!list || list.length === 0) return "";
        var parts = [];
        for (var i = 0; i < Math.min(3, list.length); ++i)
            parts.push(qsTr("Row %1, %2: %3").arg(list[i].row).arg(list[i].column).arg(list[i].message));
        var text = parts.join(" \u00b7 ");
        if (list.length > 3) text += qsTr(" \u00b7 and %1 more").arg(list.length - 3);
        return text;
    }

    function cellX(c) { return c * (root.colWidth + root.cellGap); }
    function cellY(r) { return root.rowsTop + r * root.rowHeight; }
    function reveal(c) {
        var left = cellX(c), right = left + root.colWidth, max = Math.max(0, scroller.contentWidth - scroller.width);
        var next = scroller.contentX;
        if (left < next) next = left;
        else if (right > next + scroller.width) next = right - scroller.width;
        scroller.contentX = Math.max(0, Math.min(max, next));
    }
    function moveTo(r, c) {
        if (root.shownRows <= 0 || root.colCount <= 0) return;
        root.wantRow = Math.max(0, Math.min(r, root.shownRows - 1));
        root.wantCol = Math.max(0, Math.min(c, root.colCount - 1));
        reveal(root.wantCol);
        Scroll.reveal(scroller.contentItem, cellX(root.wantCol), cellY(root.wantRow), root.colWidth, root.rowHeight);
    }
    function openEditor(initial) {
        if (root.editing || root.shownRows <= 0 || isFormula(root.activeCol)) return false;
        root.editRowId = rowIdAt(root.activeRow);
        root.editColId = String(columnAt(root.activeCol).id);
        editor.invalid = false;
        editor.message = "";
        editor.text = initial === undefined ? cellText(root.activeRow, root.activeCol) : initial;
        root.editing = true;
        reveal(root.activeCol);
        editor.forceActiveFocus(Qt.OtherFocusReason);
        editor.cursorPosition = editor.text.length;
        return true;
    }
    function closeEditor() {
        root.editing = false;
        editor.invalid = false;
        editor.message = "";
        scroller.forceActiveFocus(Qt.OtherFocusReason);
    }
    // True when the editor closed (valid value, or nothing to change).
    function commitEdit() {
        if (!root.editing) return true;
        var col = columnAt(root.activeCol), p = Edit.parseCell(editor.text, col ? col.kind : "");
        if (!p.ok) {
            editor.invalid = true;
            editor.message = p.msg;
            return false;
        }
        var rowId = root.editRowId, colId = root.editColId, same = p.text === Edit.trimAscii(cellText(root.activeRow, root.activeCol));
        closeEditor();
        if (!same) root.cellCommitted(rowId, colId, p.text);
        return true;
    }
    function leaveEditor(backwards) {
        if (!commitEdit()) return;
        var next = scroller.nextItemInFocusChain(!backwards);
        if (next && next !== scroller)
            next.forceActiveFocus(backwards ? Qt.BacktabFocusReason : Qt.TabFocusReason);
    }
    function toggleExpanded() {
        if (root.editing && !commitEdit()) return;
        root.expanded = !root.expanded;
    }
    function printable(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false;
        return event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127;
    }

    onTableChanged: {
        if (root.editing && (rowIdAt(root.activeRow) !== root.editRowId
                || !columnAt(root.activeCol) || String(columnAt(root.activeCol).id) !== root.editColId))
            closeEditor();
    }

    // ---- the grid ------------------------------------------------------------
    Flickable {
        id: scroller
        objectName: "aiCalcGridScroll"
        width: root.width
        height: contentHeight
        contentWidth: Math.max(width, root.gridWidth)
        contentHeight: root.rowsTop + root.shownRows * root.rowHeight
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        activeFocusOnTab: root.shownRows > 0 && root.colCount > 0
        Accessible.role: Accessible.Table
        Accessible.name: root.cellName(root.activeRow, root.activeCol)

        Keys.onPressed: function(event) {
            if (root.shownRows <= 0 || root.colCount <= 0) return;
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            switch (event.key) {
            case Qt.Key_Left: root.moveTo(root.activeRow, root.activeCol - 1); break;
            case Qt.Key_Right: root.moveTo(root.activeRow, root.activeCol + 1); break;
            case Qt.Key_Up: root.moveTo(root.activeRow - 1, root.activeCol); break;
            case Qt.Key_Down: root.moveTo(root.activeRow + 1, root.activeCol); break;
            case Qt.Key_Home: root.moveTo(ctrl ? 0 : root.activeRow, 0); break;
            case Qt.Key_End: root.moveTo(ctrl ? root.shownRows - 1 : root.activeRow, root.colCount - 1); break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_F2:
                root.openEditor();
                break;
            case Qt.Key_Delete:
                if (!root.isFormula(root.activeCol))
                    root.clearRequested(root.rowIdAt(root.activeRow), String(root.columnAt(root.activeCol).id));
                break;
            default:
                if (!root.printable(event)) return;
                root.openEditor(event.text);   // a formula cell swallows the key and does nothing
            }
            event.accepted = true;
        }

        Item {
            id: surface
            width: scroller.contentWidth
            height: scroller.contentHeight

            // Read-only (calculated) columns get a faint band.
            Repeater {
                model: root.colCount
                delegate: Rectangle {
                    required property int index
                    objectName: "aiCalcGridBand_" + index
                    visible: root.isFormula(index) && root.shownRows > 0
                    x: root.cellX(index)
                    y: root.rowsTop
                    width: root.colWidth
                    height: root.shownRows * root.rowHeight
                    color: root.alpha(root.foreground, 0.06)
                }
            }

            Repeater {
                id: headers
                objectName: "aiCalcGridHeaders"
                model: root.colCount
                delegate: Text {
                    required property int index
                    objectName: "aiCalcGridHeader_" + index
                    x: root.cellX(index)
                    width: root.colWidth
                    height: root.headerHeight
                    leftPadding: 4
                    rightPadding: 4
                    text: root.headerText(index)
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: root.alignOf(index)
                    color: root.foreground
                    font.pixelSize: Satin.type.label
                    font.weight: Font.DemiBold
                    Accessible.name: text
                }
            }
            Rectangle {
                y: root.headerHeight + 1
                width: surface.width
                height: 1
                color: root.alpha(root.foreground, Satin.keyline.hair)
            }

            Repeater {
                id: cells
                objectName: "aiCalcGridCells"
                model: root.shownRows * root.colCount
                delegate: Text {
                    id: cell
                    required property int index
                    readonly property int r: Math.floor(index / root.colCount)
                    readonly property int c: index % root.colCount
                    readonly property bool edited: root.isEdited(r, c)
                    objectName: "aiCalcGridCell_" + r + "_" + c
                    x: root.cellX(c)
                    y: root.cellY(r)
                    width: root.colWidth
                    height: root.rowHeight
                    leftPadding: 4
                    rightPadding: 4
                    text: root.cellText(r, c)
                    textFormat: Text.PlainText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: root.alignOf(c)
                    color: root.foreground
                    font.pixelSize: Satin.type.meta
                    font.weight: edited ? Font.Bold : Font.Normal
                    Accessible.role: Accessible.Cell
                    Accessible.name: root.headerText(c) + ", row " + (r + 1) + ": " + text
                    Accessible.description: root.errorOf(r, c) ? root.errorOf(r, c).msg : root.describe(r, c)
                }
            }

            // 'Edited' mark: a small accent diamond (bold text is the second cue).
            Repeater {
                model: root.shownRows * root.colCount
                delegate: Rectangle {
                    required property int index
                    readonly property int r: Math.floor(index / root.colCount)
                    readonly property int c: index % root.colCount
                    objectName: "aiCalcGridEdited_" + r + "_" + c
                    visible: root.isEdited(r, c)
                    x: root.cellX(c) + 2
                    y: root.cellY(r) + 2
                    width: 6
                    height: 6
                    rotation: 45
                    color: root.accent
                    Accessible.ignored: true
                }
            }

            // Active cell ring (2 px accent) while the grid has focus.
            Rectangle {
                objectName: "aiCalcGridRing"
                visible: scroller.activeFocus && !root.editing && root.shownRows > 0 && root.colCount > 0
                x: root.cellX(root.activeCol)
                y: root.cellY(root.activeRow)
                width: root.colWidth
                height: root.rowHeight
                color: "transparent"
                border.width: 2
                border.color: root.accent
                radius: 2
            }

            // The ONE shared editor, positioned over the active cell.
            TextField {
                id: editor
                objectName: "aiCalcGridEditor"
                property bool invalid: false
                property string message: ""
                visible: root.editing
                enabled: root.editing
                x: root.cellX(root.activeCol)
                y: root.cellY(root.activeRow)
                width: root.colWidth
                height: root.rowHeight
                padding: 0
                leftPadding: 4
                rightPadding: invalid ? 20 : 4
                focusPolicy: Qt.ClickFocus   // never a Tab stop; the grid is the stop
                maximumLength: 200
                selectByMouse: true
                color: root.foreground
                selectionColor: root.accent
                selectedTextColor: root.background
                font.pixelSize: Satin.type.meta
                font.weight: invalid ? Font.Bold : Font.Normal
                horizontalAlignment: root.alignOf(root.activeCol)
                verticalAlignment: Text.AlignVCenter
                Accessible.name: root.headerText(root.activeCol) + ", row " + (root.activeRow + 1) + qsTr(", editing")
                Accessible.description: invalid ? message : ""
                background: Rectangle {
                    color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
                    border.width: 2
                    border.color: root.accent
                    radius: 2
                    Text {
                        objectName: "aiCalcGridEditorGlyph"
                        visible: editor.invalid
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: "\u26a0"
                        textFormat: Text.PlainText
                        color: root.accent
                        font.pixelSize: Satin.type.label
                        font.weight: Font.Bold
                    }
                }
                onTextChanged: {
                    if (root.editing && invalid) {
                        invalid = false;
                        message = "";
                    }
                }
                onActiveFocusChanged: {
                    // Focus moved elsewhere (a click): keep a valid value, never drop a typed one.
                    if (!activeFocus && root.editing) root.commitEdit();
                }
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        var row = root.activeRow;
                        if (root.commitEdit()) root.moveTo(row + 1, root.activeCol);
                    } else if (event.key === Qt.Key_Escape) {
                        root.closeEditor();
                    } else if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier)) {
                        root.leaveEditor(false);
                    } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Tab) {
                        root.leaveEditor(true);
                    } else {
                        return;
                    }
                    event.accepted = true;
                }
            }

            TapHandler {
                id: tap
                function hit(point) {
                    if (root.shownRows <= 0 || root.colCount <= 0) return false;
                    var c = Math.floor(point.x / (root.colWidth + root.cellGap)), r = Math.floor((point.y - root.rowsTop) / root.rowHeight);
                    if (r < 0 || r >= root.shownRows || c < 0 || c >= root.colCount) return false;
                    if (root.editing && (r !== root.activeRow || c !== root.activeCol) && !root.commitEdit()) return false;
                    root.moveTo(r, c);
                    if (!root.editing) scroller.forceActiveFocus(Qt.MouseFocusReason);
                    return true;
                }
                // A second tap on the same cell within 450 ms opens the editor
                // (own timer: TapHandler.tapCount never reaches 2 under QtTest).
                property double lastTap: 0
                property int lastRow: -1
                property int lastCol: -1
                onTapped: function(eventPoint) {
                    var now = Date.now(), again = now - tap.lastTap < 450;
                    if (!tap.hit(eventPoint.position)) return;
                    if (again && tap.lastRow === root.activeRow && tap.lastCol === root.activeCol) {
                        root.openEditor();
                        tap.lastTap = 0;
                    } else {
                        tap.lastTap = now;
                    }
                    tap.lastRow = root.activeRow;
                    tap.lastCol = root.activeCol;
                }
            }
        }
    }

    // ---- messages ----------------------------------------------------------
    Row {
        objectName: "aiCalcGridMessageRow"
        spacing: 6
        visible: root.editing && editor.invalid && editor.message !== ""
        Text {
            objectName: "aiCalcGridMessageGlyph"
            text: "\u26a0"
            textFormat: Text.PlainText
            color: root.accent
            font.pixelSize: Satin.type.label
            font.weight: Font.Bold
        }
        Text {
            id: messageText
            objectName: "aiCalcGridMessage"
            width: root.width - 20
            text: editor.message
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: root.alpha(root.foreground, 0.90)
            font.pixelSize: Satin.type.label
            font.weight: Font.DemiBold
            Accessible.role: Accessible.AlertMessage
        }
    }
    Text {
        objectName: "aiCalcGridErrors"
        width: root.width
        visible: root.errorText !== ""
        text: root.errorText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.alpha(root.foreground, 0.90)
        font.pixelSize: Satin.type.label
    }

    component GridButton: Button {
        id: control
        required property color ink
        required property color ring
        padding: 4
        leftPadding: 10
        rightPadding: 10
        implicitHeight: 28
        activeFocusOnTab: enabled
        hoverEnabled: true
        Accessible.name: text
        contentItem: Text {
            text: control.text
            textFormat: Text.PlainText
            color: Qt.rgba(control.ink.r, control.ink.g, control.ink.b, control.enabled ? 0.80 : 0.76)
            font.pixelSize: Satin.type.label
            font.weight: control.enabled ? Font.Medium : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: Satin.radius.chip
            color: control.hovered && control.enabled ? Qt.rgba(control.ink.r, control.ink.g, control.ink.b, 0.045) : "transparent"
            border.width: control.visualFocus ? 2 : (control.enabled ? 1 : 0)
            border.color: control.visualFocus ? control.ring : Qt.rgba(control.ink.r, control.ink.g, control.ink.b, 0.30)
        }
    }

    GridButton {
        id: more
        objectName: "aiCalcGridToggle"
        ink: root.foreground
        ring: root.accent
        visible: root.rowTotal > root.collapsedRows
        text: root.expanded ? qsTr("Show fewer rows") : qsTr("Show all %1 rows").arg(root.rowTotal)
        onClicked: root.toggleExpanded()
    }
    Row {
        spacing: 8
        GridButton {
            id: addButton
            objectName: "aiCalcGridAdd"
            ink: root.foreground
            ring: root.accent
            enabled: root.canAdd
            text: qsTr("Add row")
            Accessible.description: root.canAdd ? "" : root.addBlockedReason
            onClicked: root.addRowRequested()
        }
        GridButton {
            id: removeButton
            objectName: "aiCalcGridRemove"
            ink: root.foreground
            ring: root.accent
            enabled: root.shownRows > 0
            text: qsTr("Remove row")
            onClicked: {
                if (root.editing) root.closeEditor();
                root.removeRowRequested(root.rowIdAt(root.activeRow));
            }
        }
    }
    Text {
        objectName: "aiCalcGridBlockedReason"
        width: root.width
        visible: !root.canAdd && root.addBlockedReason !== ""
        text: root.addBlockedReason
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.label
    }
}
