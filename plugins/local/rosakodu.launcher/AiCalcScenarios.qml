pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiCalc.js" as Calc
import "AiCalcEdit.js" as Edit

// Saved input scenarios for a typed calc block: a collapsed "Scenarios (n)"
// toggle, then a name field + Save, the saved list (Load / Delete) and a
// Compare view. This component NEVER changes state: it only emits
// saveRequested(name) / loadRequested(index) / deleteRequested(index) and the
// owner (AiCalc) persists them through AiCalcEdit and feeds `scenarios` back
// (AiCalcView.scenarioResults: Current first at index -1, then saved ones).
// The compare grid lives in an inactive Loader until opened and is bounded:
// <= 4 value columns, <= 40 data rows (differing inputs, then every derived
// cell, then ONE picked formula column per table, 12 rows until "Show all").
// Scenario names come from the person: every string here is PlainText.
Item {
    id: root
    objectName: "aiCalcScenarios"

    required property var plan
    // The compiled model of `plan` (Calc.formatCell needs it).
    required property var model
    // AiCalcView.scenarioResults(): [{name, index, values, result}], Current first.
    required property var scenarios
    // block.inputs: {id, label, unit} for the labels and units of differing inputs.
    required property var inputs
    required property color foreground
    required property color background
    required property color accent
    property bool busy: false
    property bool expanded: false
    property bool comparing: false

    signal saveRequested(string name)
    signal loadRequested(int index)
    signal deleteRequested(int index)
    // Internal: the open panel listens and moves focus to the neighbour of a deleted row.
    signal focusAfterDelete(int index)

    readonly property int maxColumns: 4
    readonly property int maxDataRows: 40
    readonly property int collapsedRows: 12
    readonly property int maxDerivedCells: 24
    readonly property real minValueWidth: 80
    readonly property real minLabelWidth: 120
    readonly property real dim: 0.80
    readonly property color dimColor: Qt.alpha(foreground, dim)
    readonly property string noteText: qsTr("Table edits apply to all scenarios.")
    readonly property string legendText: qsTr("Bold marks a value that differs from Current.")

    // The saved scenarios (everything but Current), in saved order.
    readonly property var saved: {
        var out = [];
        var list = root.scenarios;
        if (list) {
            for (var i = 0; i < list.length; ++i)
                if (list[i] && list[i].index >= 0 && out.length < Edit.maxScenarios) out.push(list[i]);
        }
        return out;
    }
    readonly property int savedCount: saved.length

    implicitWidth: 660
    implicitHeight: body.implicitHeight
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Scenarios")

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function fmt(value) {
        return typeof value === "number" && isFinite(value) ? String(Number(value.toPrecision(12))) : "\u2014";
    }

    // ---- compare data ----------------------------------------------------
    function cellOf(result, id) {
        if (!result || !result.nodes || !result.nodes[id])
            return {text: "\u2014", code: "N/A", err: true, sig: "!N/A"};
        var r = result.nodes[id];
        if (r.err) return {text: "\u2014", code: String(r.err.code), err: true, sig: "!" + r.err.code};
        var text = Calc.formatCell(root.model, result, id);
        return {text: text, code: "", err: false, sig: "=" + text};
    }
    function textOf(value, unit) {
        return root.fmt(value) + (typeof unit === "string" && unit.length ? " " + unit : "");
    }
    // One row: `cells` are cellOf() results, one per column; column 0 is Current.
    function rowOf(label, cells) {
        var out = [];
        for (var c = 0; c < cells.length; ++c) {
            var cell = cells[c];
            out.push({text: cell.err ? cell.text + " " + cell.code : cell.text, err: cell.err, code: cell.code,
                      differs: c > 0 && cell.sig !== cells[0].sig});
        }
        return {kind: "row", label: label, cells: out};
    }
    function formulaColumns(table) {
        var out = [];
        for (var c = 0; c < table.cols.length; ++c)
            if (table.cols[c].kind === "formula") out.push(c);
        return out;
    }
    function headerText(col) {
        return col.label + (col.kind !== "text" && col.unitText ? " (" + col.unitText + ")" : "");
    }
    function rowLabelOf(table, r) {
        for (var c = 0; c < table.cols.length; ++c) {
            if (table.cols[c].kind !== "text") continue;
            var text = String(table.rows[r][c] === undefined ? "" : table.rows[r][c]);
            if (text.length) return text.slice(0, 60);
            break;
        }
        return qsTr("Row %1").arg(r + 1);
    }
    // picked: {tableIndex: columnIndex}; showAll: lift the 12-row limit (still <= 40 rows overall).
    function compareData(picked, showAll) {
        var list = root.scenarios, plan = root.plan, cols = [], rows = [], pickers = [];
        var i, c, t, r;
        if (!plan || !list) return {cols: cols, rows: rows, pickers: pickers, expandable: false, cut: false};
        for (i = 0; i < list.length && cols.length < root.maxColumns; ++i)
            cols.push({name: String(list[i].name), index: list[i].index, scenario: list[i]});
        var data = 0, ins = root.inputs;
        var inputRows = [];
        for (i = 0; ins && i < ins.length && data < root.maxDataRows; ++i) {
            var inp = ins[i];
            if (!inp || typeof inp.id !== "string") continue;
            var vals = [], differs = false;
            for (c = 0; c < cols.length; ++c) {
                var v = cols[c].scenario.values ? cols[c].scenario.values[inp.id] : undefined;
                var text = root.textOf(v, inp.unit);
                vals.push({text: text, code: "", err: false, sig: "=" + text});
                if (c > 0 && vals[c].sig !== vals[0].sig) differs = true;
            }
            if (!differs) continue;
            inputRows.push(root.rowOf(typeof inp.label === "string" && inp.label.length ? inp.label.slice(0, 120) : inp.id, vals));
            ++data;
        }
        rows.push({kind: "section", text: inputRows.length ? qsTr("Inputs that differ") : qsTr("All inputs are the same")});
        for (i = 0; i < inputRows.length; ++i) rows.push(inputRows[i]);
        var cells = plan.cells ? plan.cells : [];
        if (cells.length && data < root.maxDataRows) rows.push({kind: "section", text: qsTr("Results")});
        for (i = 0; i < cells.length && i < root.maxDerivedCells && data < root.maxDataRows; ++i) {
            var cv = [];
            for (c = 0; c < cols.length; ++c) cv.push(root.cellOf(cols[c].scenario.result, cells[i].id));
            rows.push(root.rowOf(cells[i].label, cv));
            ++data;
        }
        var expandable = false, cut = false;
        for (t = 0; plan.tables && t < plan.tables.length; ++t) {
            var table = plan.tables[t], fcols = root.formulaColumns(table);
            if (!fcols.length) continue;
            var pick = fcols[fcols.length - 1];
            if (picked && picked[t] !== undefined && fcols.indexOf(picked[t]) >= 0) pick = picked[t];
            var col = table.cols[pick], n = table.rows.length;
            if (fcols.length > 1) {
                var opts = [];
                for (c = 0; c < fcols.length; ++c)
                    opts.push({col: fcols[c], label: root.headerText(table.cols[fcols[c]]), selected: fcols[c] === pick});
                pickers.push({table: t, label: table.label, options: opts});
            }
            var room = Math.max(0, root.maxDataRows - data);
            var fewer = Math.min(n, root.collapsedRows, room), most = Math.min(n, room);
            if (most > fewer) expandable = true;
            if (n > most) cut = true;
            var want = showAll ? most : fewer;
            if (want <= 0) continue;
            rows.push({kind: "section", text: (table.label.length ? table.label + ": " : "") + root.headerText(col)});
            for (r = 0; r < want; ++r) {
                var fv = [], id = table.id + "." + col.id + "#" + (r + 1);
                for (c = 0; c < cols.length; ++c) fv.push(root.cellOf(cols[c].scenario.result, id));
                rows.push(root.rowOf(root.rowLabelOf(table, r), fv));
                ++data;
            }
        }
        return {cols: cols, rows: rows, pickers: pickers, expandable: expandable, cut: cut};
    }

    // ---- shared button look (2 px accent focus ring) --------------------------
    component ScnButton: Button {
        Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
        Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
        id: btn
        required property color fg
        required property color acc
        // A highlighted choice in a group (the owner decides; clicking never toggles it).
        property bool selected: false
        padding: 4
        horizontalPadding: 10
        implicitHeight: 30
        implicitWidth: label.implicitWidth + 20
        activeFocusOnTab: true
        hoverEnabled: true
        Accessible.name: text
        contentItem: Text {
            id: label
            text: btn.text
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Qt.rgba(btn.fg.r, btn.fg.g, btn.fg.b, btn.enabled ? 0.80 : 0.55)
            font.pixelSize: Satin.type.meta
            font.weight: btn.selected ? Font.DemiBold : Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: Satin.radius.chip
            color: btn.down ? Qt.rgba(btn.fg.r, btn.fg.g, btn.fg.b, 0.12)
                : btn.hovered || btn.selected ? Qt.rgba(btn.fg.r, btn.fg.g, btn.fg.b, 0.07) : "transparent"
            border.width: btn.visualFocus ? 2 : 1
            border.color: btn.visualFocus ? btn.acc : Qt.rgba(btn.fg.r, btn.fg.g, btn.fg.b, Satin.keyline.hair)
        }
    }

    Column {
        id: body
        width: root.width
        spacing: Satin.space.tip

        ScnButton {
            id: toggle
            objectName: "aiCalcScenariosToggle"
            fg: root.foreground
            acc: root.accent
            text: (root.expanded ? "\u25BE " : "\u25B8 ") + qsTr("Scenarios (%1)").arg(root.savedCount)
            onClicked: root.expanded = !root.expanded
            Accessible.name: qsTr("Scenarios (%1)").arg(root.savedCount) + (root.expanded ? qsTr(", expanded") : qsTr(", collapsed"))
        }

        Loader {
            id: panelLoader
            objectName: "aiCalcScenariosPanelLoader"
            width: body.width
            active: root.expanded
            visible: active
            sourceComponent: panelComponent
        }
    }

    function focusToggle() { toggle.forceActiveFocus(Qt.BacktabFocusReason); }
    // The owner usually drops the row synchronously, which may destroy this very button: emit from the
    // next event-loop turn, then put focus on the neighbour.
    function requestDelete(index) { Qt.callLater(root.finishDelete, index); }
    function finishDelete(index) {
        root.deleteRequested(index);
        Qt.callLater(root.refocusAfterDelete, index);
    }
    function refocusAfterDelete(index) { root.focusAfterDelete(index); }

    Component {
        id: panelComponent

        Column {
            id: panel
            objectName: "aiCalcScenariosPanel"
            spacing: Satin.space.tip

            readonly property string cleanName: Edit.plainName(nameField.text)
            readonly property bool replaces: {
                for (var i = 0; i < root.saved.length; ++i)
                    if (root.saved[i].name === panel.cleanName) return panel.cleanName.length > 0;
                return false;
            }
            readonly property bool full: root.savedCount >= Edit.maxScenarios
            readonly property string saveReason: root.busy ? qsTr("Busy. Try again in a moment.")
                : panel.cleanName.length === 0
                    ? (panel.full ? qsTr("%1 scenarios are saved. Type a saved name to replace it, or delete one.").arg(Edit.maxScenarios)
                                  : qsTr("Enter a name to save."))
                : panel.full && !panel.replaces ? qsTr("%1 scenarios are saved. Delete one, or type a saved name to replace it.").arg(Edit.maxScenarios)
                : ""
            readonly property bool canSave: panel.saveReason.length === 0

            function save() {
                if (!panel.canSave) return;
                var name = panel.cleanName;
                nameField.text = "";
                root.saveRequested(name);
            }
            // After a delete the focused button disappears: land on the next one, or the name field.
            function refocus(index) {
                var next = panel.named("aiCalcScenariosDelete_" + Math.min(index, root.savedCount - 1));
                if (next) next.forceActiveFocus(Qt.TabFocusReason);
                else nameField.forceActiveFocus(Qt.TabFocusReason);
            }
            function named(name) {
                var stack = [panel];
                while (stack.length) {
                    var it = stack.pop();
                    if (it.objectName === name) return it;
                    for (var k = 0; k < it.children.length; ++k) stack.push(it.children[k]);
                }
                return null;
            }

            Connections {
                target: root
                function onFocusAfterDelete(index) { panel.refocus(index); }
            }

            Flow {
                width: panel.width
                spacing: Satin.space.tip

                TextField {
                    id: nameField
                    objectName: "aiCalcScenariosName"
                    width: Math.min(panel.width, 240)
                    height: 32
                    maximumLength: Edit.maxScenarioName
                    placeholderText: qsTr("Scenario name")
                    placeholderTextColor: root.dimColor
                    selectByMouse: true
                    activeFocusOnTab: true
                    color: root.foreground
                    selectionColor: root.alpha(root.accent, 0.35)
                    selectedTextColor: root.foreground
                    font.pixelSize: Satin.type.meta
                    Accessible.name: qsTr("Scenario name")
                    Accessible.description: qsTr("Up to %1 characters. Press Enter to save the current inputs under this name.").arg(Edit.maxScenarioName)
                    onAccepted: panel.save()
                    Keys.onEscapePressed: function(event) {
                        root.focusToggle();
                        event.accepted = true;
                    }
                    background: Rectangle {
                        radius: Satin.radius.field
                        color: root.alpha(root.foreground, 0.04)
                        border.width: nameField.activeFocus ? 2 : 1
                        border.color: nameField.activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)
                    }
                }

                ScnButton {
                    id: saveButton
                    objectName: "aiCalcScenariosSave"
                    fg: root.foreground
                    acc: root.accent
                    enabled: panel.canSave
                    text: panel.replaces ? qsTr("Save (Replaces)") : qsTr("Save")
                    onClicked: panel.save()
                    Accessible.name: panel.replaces ? qsTr("Save, replaces the saved scenario named %1").arg(panel.cleanName) : qsTr("Save scenario")
                    Accessible.description: panel.saveReason
                }
            }

            Text {
                objectName: "aiCalcScenariosReason"
                width: panel.width
                visible: panel.saveReason.length > 0
                text: panel.saveReason
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dimColor
                font.pixelSize: Satin.type.label
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                objectName: "aiCalcScenariosEmpty"
                width: panel.width
                visible: root.savedCount === 0
                text: qsTr("No saved scenarios yet. Save the current inputs to compare them later.")
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dimColor
                font.pixelSize: Satin.type.label
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // The model is the COUNT and rows read their entry live: the owner usually replaces the whole
            // `scenarios` array from inside a Load click, and rebuilding the delegates there would destroy
            // the button whose handler is running.
            Repeater {
                model: root.savedCount
                delegate: Row {
                    id: savedRow
                    required property int index
                    readonly property var entry: root.saved[index]
                    readonly property string entryName: entry ? String(entry.name) : ""
                    width: panel.width
                    spacing: Satin.space.base
                    Text {
                        objectName: "aiCalcScenariosItem_" + savedRow.index
                        width: Math.max(40, savedRow.width - loadButton.width - deleteButton.width - 2 * Satin.space.base)
                        height: 30
                        text: savedRow.entryName
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.foreground
                        font.pixelSize: Satin.type.meta
                        verticalAlignment: Text.AlignVCenter
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("Saved scenario %1").arg(text)
                    }
                    ScnButton {
                        id: loadButton
                        objectName: "aiCalcScenariosLoad_" + savedRow.index
                        fg: root.foreground
                        acc: root.accent
                        enabled: !root.busy
                        text: qsTr("Load")
                        onClicked: if (savedRow.entry) root.loadRequested(savedRow.entry.index)
                        Accessible.name: qsTr("Load scenario %1").arg(savedRow.entryName)
                        Accessible.description: root.busy ? qsTr("Busy. Try again in a moment.") : ""
                    }
                    ScnButton {
                        id: deleteButton
                        objectName: "aiCalcScenariosDelete_" + savedRow.index
                        fg: root.foreground
                        acc: root.accent
                        enabled: !root.busy
                        text: qsTr("Delete")
                        onClicked: if (savedRow.entry) root.requestDelete(savedRow.entry.index)
                        Accessible.name: qsTr("Delete scenario %1").arg(savedRow.entryName)
                        Accessible.description: root.busy ? qsTr("Busy. Try again in a moment.") : ""
                    }
                }
            }

            ScnButton {
                id: compareButton
                objectName: "aiCalcScenariosCompare"
                fg: root.foreground
                acc: root.accent
                enabled: root.savedCount > 0
                checkable: false
                text: (root.comparing && root.savedCount > 0 ? "\u25BE " : "\u25B8 ")
                    + (root.comparing && root.savedCount > 0 ? qsTr("Hide comparison") : qsTr("Compare"))
                onClicked: root.comparing = !root.comparing
                Accessible.name: qsTr("Compare scenarios") + (root.comparing && root.savedCount > 0 ? qsTr(", expanded") : qsTr(", collapsed"))
                Accessible.description: root.savedCount === 0 ? qsTr("Save a scenario first.") : ""
            }

            Loader {
                id: compareLoader
                objectName: "aiCalcScenariosCompareLoader"
                width: panel.width
                active: root.comparing && root.savedCount > 0
                visible: active
                sourceComponent: compareComponent
            }
        }
    }

    Component {
        id: compareComponent

        Column {
            id: cmp
            objectName: "aiCalcScenariosCompareView"
            spacing: Satin.space.tip

            property var picked: ({})
            property bool showAll: false
            readonly property var view: root.compareData(cmp.picked, cmp.showAll)
            readonly property int colCount: cmp.view.cols.length
            readonly property real labelW: Math.max(root.minLabelWidth, Math.round(cmp.width * 0.4))
            readonly property real valueW: colCount > 0
                ? Math.max(root.minValueWidth, Math.floor((cmp.width - labelW) / colCount)) : 0
            readonly property real gridW: labelW + colCount * valueW

            function pick(table, col) {
                var next = {};
                for (var k in cmp.picked) next[k] = cmp.picked[k];
                next[table] = col;
                cmp.picked = next;
            }

            // Counts as models (see the saved list): a pick rebuilds `view`, but must not destroy its own button.
            Repeater {
                model: cmp.view.pickers.length
                delegate: Flow {
                    id: pickerRow
                    required property int index
                    readonly property var picker: cmp.view.pickers[index]
                    width: cmp.width
                    spacing: Satin.space.base
                    Text {
                        height: 30
                        text: qsTr("Column to compare in %1:").arg(pickerRow.picker && pickerRow.picker.label ? pickerRow.picker.label : qsTr("the table"))
                        textFormat: Text.PlainText
                        color: root.dimColor
                        font.pixelSize: Satin.type.label
                        verticalAlignment: Text.AlignVCenter
                    }
                    Repeater {
                        model: pickerRow.picker ? pickerRow.picker.options.length : 0
                        delegate: ScnButton {
                            id: pickButton
                            required property int index
                            readonly property var option: pickerRow.picker ? pickerRow.picker.options[index] : null
                            objectName: "aiCalcScenariosPick_" + pickerRow.index + "_" + index
                            fg: root.foreground
                            acc: root.accent
                            selected: option ? option.selected : false
                            text: option ? option.label : ""
                            onClicked: if (pickButton.option && pickerRow.picker) cmp.pick(pickerRow.picker.table, pickButton.option.col)
                            Accessible.name: qsTr("Compare column %1").arg(text)
                            Accessible.checkable: true
                            Accessible.checked: selected
                        }
                    }
                }
            }

            Item {
                id: frame
                width: cmp.width
                height: scroller.height

                Flickable {
                    id: scroller
                    objectName: "aiCalcScenariosScroll"
                    width: frame.width
                    height: grid.implicitHeight
                    contentWidth: Math.max(width, cmp.gridW)
                    contentHeight: grid.implicitHeight
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    activeFocusOnTab: cmp.gridW > width
                    Keys.onPressed: function(event) {
                        var step = cmp.valueW, max = Math.max(0, scroller.contentWidth - scroller.width);
                        if (event.key === Qt.Key_Left) scroller.contentX = Math.max(0, scroller.contentX - step);
                        else if (event.key === Qt.Key_Right) scroller.contentX = Math.min(max, scroller.contentX + step);
                        else if (event.key === Qt.Key_Home) scroller.contentX = 0;
                        else if (event.key === Qt.Key_End) scroller.contentX = max;
                        else return;
                        event.accepted = true;
                    }
                    Accessible.role: Accessible.Table
                    Accessible.name: qsTr("Scenario comparison")
                    Accessible.description: cmp.gridW > scroller.width ? qsTr("Use Left and Right to scroll the columns.") : ""

                    Column {
                        id: grid
                        width: scroller.contentWidth

                        Row {
                            Text {
                                width: cmp.labelW
                                text: qsTr("Value")
                                textFormat: Text.PlainText
                                leftPadding: 6
                                color: root.foreground
                                font.pixelSize: Satin.type.small
                                font.weight: Font.DemiBold
                            }
                            Repeater {
                                model: cmp.view.cols
                                delegate: Text {
                                    id: headerCell
                                    required property var modelData
                                    required property int index
                                    objectName: "aiCalcScenariosColumn_" + index
                                    width: cmp.valueW
                                    text: String(modelData.name)
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WrapAnywhere
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    horizontalAlignment: Text.AlignRight
                                    leftPadding: 6
                                    rightPadding: 6
                                    color: root.foreground
                                    font.pixelSize: Satin.type.small
                                    font.weight: Font.DemiBold
                                    Accessible.role: Accessible.ColumnHeader
                                    Accessible.name: modelData.index < 0 ? qsTr("Current") : qsTr("Scenario %1").arg(modelData.name)
                                }
                            }
                        }
                        Rectangle {
                            width: grid.width
                            height: 1
                            color: root.alpha(root.foreground, Satin.keyline.hair)
                        }

                        Repeater {
                            model: cmp.view.rows
                            delegate: Loader {
                                id: rowLoader
                                required property var modelData
                                required property int index
                                width: grid.width
                                sourceComponent: modelData.kind === "section" ? sectionComponent : dataComponent

                                Component {
                                    id: sectionComponent
                                    Text {
                                        objectName: "aiCalcScenariosSection_" + rowLoader.index
                                        topPadding: 8
                                        leftPadding: 6
                                        text: rowLoader.modelData.text
                                        textFormat: Text.PlainText
                                        wrapMode: Text.Wrap
                                        color: root.foreground
                                        font.pixelSize: Satin.type.small
                                        font.weight: Font.DemiBold
                                        Accessible.role: Accessible.StaticText
                                        Accessible.name: text
                                    }
                                }

                                Component {
                                    id: dataComponent
                                    Column {
                                        Row {
                                            Text {
                                                objectName: "aiCalcScenariosLabel_" + rowLoader.index
                                                width: cmp.labelW
                                                text: rowLoader.modelData.label
                                                textFormat: Text.PlainText
                                                wrapMode: Text.Wrap
                                                topPadding: 3
                                                bottomPadding: 3
                                                leftPadding: 6
                                                rightPadding: 6
                                                color: root.alpha(root.foreground, 0.85)
                                                font.pixelSize: Satin.type.meta
                                            }
                                            Repeater {
                                                model: rowLoader.modelData.cells
                                                delegate: Text {
                                                    id: valueCell
                                                    required property var modelData
                                                    required property int index
                                                    objectName: "aiCalcScenariosCell_" + rowLoader.index + "_" + index
                                                    width: cmp.valueW
                                                    text: modelData.text
                                                    textFormat: Text.PlainText
                                                    wrapMode: Text.Wrap
                                                    horizontalAlignment: Text.AlignRight
                                                    topPadding: 3
                                                    bottomPadding: 3
                                                    leftPadding: 6
                                                    rightPadding: 6
                                                    color: root.foreground
                                                    font.pixelSize: Satin.type.meta
                                                    font.weight: modelData.differs ? Font.Bold : Font.Normal
                                                    Accessible.role: Accessible.Cell
                                                    Accessible.name: rowLoader.modelData.label + ", "
                                                        + (cmp.view.cols[index] ? (cmp.view.cols[index].index < 0 ? qsTr("Current") : cmp.view.cols[index].name) : "")
                                                        + ": " + (modelData.err ? qsTr("no value, error %1").arg(modelData.code) : modelData.text)
                                                    Accessible.description: modelData.differs ? qsTr("differs from current") : ""
                                                }
                                            }
                                        }
                                        Rectangle {
                                            width: cmp.gridW
                                            height: 1
                                            color: root.alpha(root.foreground, 0.07)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    objectName: "aiCalcScenariosFocusRing"
                    anchors.fill: parent
                    color: "transparent"
                    radius: Satin.radius.chip
                    border.width: scroller.activeFocus ? 2 : 0
                    border.color: root.accent
                }
            }

            ScnButton {
                objectName: "aiCalcScenariosMore"
                visible: cmp.view.expandable
                fg: root.foreground
                acc: root.accent
                text: cmp.showAll ? qsTr("Show fewer rows") : qsTr("Show all rows")
                onClicked: cmp.showAll = !cmp.showAll
                Accessible.name: text
            }

            Text {
                objectName: "aiCalcScenariosCut"
                width: cmp.width
                visible: cmp.view.cut
                text: qsTr("Showing the first %1 rows.").arg(root.maxDataRows)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dimColor
                font.pixelSize: Satin.type.label
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                objectName: "aiCalcScenariosLegend"
                width: cmp.width
                text: root.legendText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dimColor
                font.pixelSize: Satin.type.label
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                objectName: "aiCalcScenariosNote"
                width: cmp.width
                text: root.noteText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dimColor
                font.pixelSize: Satin.type.label
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }
    }
}
