pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiCalc.js" as Calc
import "AiCalcView.js" as CalcView
import "AiCalcEdit.js" as Edit
import "AiCalcExport.js" as Export

// A model-authored calculation: editable inputs (slider + typed number), derived
// cells, editable data tables (AiCalcGrid), saved input scenarios
// (AiCalcScenarios) and a small toolbar, all evaluated locally by the typed
// engine (AiCalc.js). Stored blocks are not re-validated on restore, so a block
// that cannot be compiled shows one honest line and nothing else.
//
// State. `calc:<blockIndex>` is ONE object: the changed inputs {id:{v,u}} plus
// `_d` (table edits) and `_s` (saved scenarios); see AiCalcEdit.js. The component
// keeps its own copy, `entry`, and DISPLAYS that. Every user action composes a new
// entry (AiCalcEdit.compose/commit, refused above 10 KiB), assigns it locally and
// emits the FULL entry through stateEdited (`{}` = nothing changed). The emit is
// never assumed to have been applied (the host can refuse while a workspace
// transition runs): `entry` stays the display until `saved` changes. A `saved`
// equal to something we emitted is an echo and is ignored (up to 8 in flight); any
// other change is another surface or a restore: it is adopted and the undo/redo
// stacks are cleared, so undo can never overwrite a newer edit. While the host lags
// the display may run ahead of what is persisted; the next accepted emit carries
// the whole entry, so it heals itself.
//
// The plan (compiled model) depends on the block and on `_d` only, so moving a
// slider never recompiles. Undo/redo is in memory only (30 snapshots, 100 KiB).
Column {
    id: root
    objectName: "aiCalc"

    property var block: ({})
    property int blockIndex: 0
    // The persisted `calc:<blockIndex>` entry (undefined when untouched).
    property var saved: undefined
    property bool canDuplicate: true
    property string duplicateHint: ""
    required property color foreground
    required property color background
    required property color accent
    // The complete new `calc:<blockIndex>` object ({} when nothing is changed).
    signal stateEdited(var state)
    // Clipboard text (<= 64 KiB), emitted only from a click on Copy as CSV.
    signal copyRequested(string text)
    // AiCalcEdit.bake(block, entry) = {block, entry}, emitted only from Duplicate.
    signal duplicateRequested(var baked)
    signal focusCellRequested(string cellId)
    // Internal: an action was refused (too large); controls resync to the display.
    signal refused()

    readonly property string invalidText: qsTr("This calculation can't be shown.")
    readonly property string restoreNoteText: qsTr("Some saved values no longer match this calculation and were reset.")
    readonly property string tooLargeText: qsTr("Too many edits to keep. Discard some edits or delete a scenario, then try again.")
    readonly property int maxHistory: 30
    readonly property int maxHistoryBytes: 102400
    readonly property int coalesceMs: 600
    readonly property string historyNote: qsTr("Undo is kept while this view is open.")

    // The local copy of the persisted entry (seeded from `saved`; see the header).
    property var entry: root.normalize(root.saved)
    readonly property string dataKey: CalcView.dataKey(root.entry)
    // A plain JSON copy of the block (turn blocks are QML wrappers).
    readonly property var authored: CalcView.plain(root.block)
    // Compiled once per block or table-data change; null when the block is unusable.
    readonly property var plan: root.build(root.block, root.dataKey)
    readonly property bool valid: plan !== null
    readonly property var restored: CalcView.restore(root.plan, root.entry)
    // id -> number for EVERY input (defaults plus the user's edits).
    readonly property var current: root.restored.values
    readonly property bool restoreReset: root.restored.reset
    property var calcResult: null
    property var resultPlan: null
    property bool tooLarge: false
    property var openCells: ({})
    // Counts compiles (a plain object: mutating it notifies nothing).
    readonly property var meter: ({builds: 0})
    readonly property var gridInfo: root.makeGridInfo(root.plan, root.authored)
    // Stands in for a table while the plan and its grid model change together.
    readonly property var noGrid: ({table: {id: "", label: "", columns: [], rows: [], rowIds: []}, edited: {}, canAdd: false, reason: ""})
    readonly property var scenarioList: root.plan ? CalcView.scenarioResults(root.plan, root.entry, root.calcResult) : []
    readonly property var formatter: root.makeFormatter(root.plan, root.calcResult)
    readonly property int changedCount: {
        var n = 0;
        if (root.plan) {
            for (var i = 0; i < root.plan.inputs.length; ++i)
                if (root.current[root.plan.inputs[i].id] !== root.plan.inputs[i].value) ++n;
        }
        return n;
    }
    readonly property int editedCount: root.plan ? root.plan.edited.cells + root.plan.edited.rowsAdded + root.plan.edited.rowsRemoved : 0

    // History (canonical JSON snapshots of whole entries; NOT persisted).
    property Item toolbarItem: null
    property var undoStack: []
    property var redoStack: []
    readonly property bool canUndo: undoStack.length > 0
    readonly property bool canRedo: redoStack.length > 0
    property var echoes: []
    property string seenKey: ""
    property string lastInputId: ""
    property double lastInputAt: 0

    spacing: Satin.space.section

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function finite(value) { return typeof value === "number" && isFinite(value); }
    function fmt(value) { return finite(value) ? String(Number(value.toPrecision(12))) : ""; }

    // ---- entry helpers ---------------------------------------------------
    function normalize(value) {
        var p = CalcView.plain(value);
        return p !== null && typeof p === "object" && !Array.isArray(p) ? p : {};
    }
    // Key order is not stable across a host round trip: compare sorted JSON.
    function canonical(v) {
        if (Array.isArray(v)) return "[" + v.map(root.canonical).join(",") + "]";
        if (v !== null && typeof v === "object")
            return "{" + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ":" + root.canonical(v[k]); }).join(",") + "}";
        return JSON.stringify(v);
    }
    function keyOf(value) { return root.canonical(root.normalize(value)); }
    function build(source, key) {
        root.meter.builds += 1;
        return CalcView.build(source, key);
    }
    function recompute() {
        if (!root.plan) {
            root.calcResult = null;
            root.resultPlan = null;
            return;
        }
        var prev = root.resultPlan === root.plan ? root.calcResult : null, next = null;
        try { next = Calc.evaluate(root.plan.model, root.restored.values, null, prev); } catch (e) { next = null; }
        root.resultPlan = root.plan;
        root.calcResult = next;
    }
    onRestoredChanged: root.recompute()
    onBlockChanged: root.clearHistory()
    onSavedChanged: root.adoptSaved()
    Component.onCompleted: {
        root.seenKey = root.keyOf(root.saved);
        root.recompute();
    }

    function changedState(id, value) {
        var out = {};
        if (!root.plan) return out;
        for (var i = 0; i < root.plan.inputs.length; ++i) {
            var inp = root.plan.inputs[i], v = inp.id === id ? value : root.current[inp.id];
            if (v !== inp.value) out[inp.id] = {v: v, u: inp.unit};
        }
        return out;
    }

    // ---- saved <-> local -------------------------------------------------
    function adoptSaved() {
        var key = root.keyOf(root.saved);
        if (key === root.seenKey) return;
        root.seenKey = key;
        var at = root.echoes.indexOf(key);
        if (at >= 0) {                       // our own emit came back
            root.echoes = root.echoes.slice(at + 1);
            return;
        }
        root.echoes = [];
        if (key === root.keyOf(root.entry)) return;
        root.clearHistory();
        root.entry = root.normalize(root.saved);
    }
    function clearHistory() {
        root.undoStack = [];
        root.redoStack = [];
        root.echoes = [];
        root.lastInputId = "";
        root.tooLarge = false;
    }
    function emitEntry(next) {
        root.echoes = root.echoes.concat([root.keyOf(next)]).slice(-8);
        root.stateEdited(CalcView.plain(next));
    }

    // ---- the commit pipeline ---------------------------------------------
    // Every user action ends here: compose (+ the 10 KiB cap), skip a no-op, record
    // ONE history entry (repeated edits of one input within 600 ms share one), assign
    // the new entry locally, then emit it.
    function act(inputs, data, scenarios, inputId) {
        var c = Edit.commit(inputs, data, scenarios);
        if (!c.ok) {
            root.tooLarge = true;
            root.refused();
            return false;
        }
        root.tooLarge = false;
        var before = root.keyOf(root.entry);
        if (before === root.keyOf(c.entry)) return false;
        var now = Date.now(), merge = inputId !== "" && root.lastInputId === inputId && now - root.lastInputAt < root.coalesceMs;
        root.lastInputId = inputId;
        root.lastInputAt = now;
        if (!merge) root.pushUndo(before);
        root.redoStack = [];
        root.entry = c.entry;
        root.emitEntry(c.entry);
        return true;
    }
    function pushUndo(snapshot) {
        var list = root.undoStack, top = list.length ? list[list.length - 1] : null;
        if (snapshot !== top) list = list.concat([snapshot]);
        var bytes = 0, i;
        for (i = 0; i < list.length; ++i) bytes += Edit.utf8Bytes(list[i]);
        while (list.length > 1 && (list.length > root.maxHistory || bytes > root.maxHistoryBytes)) {
            bytes -= Edit.utf8Bytes(list[0]);
            list = list.slice(1);
        }
        root.undoStack = list;
    }
    // Undo/redo move one snapshot between the stacks and emit it like any action.
    function jump(snapshot) {
        root.lastInputId = "";
        root.tooLarge = false;
        root.entry = JSON.parse(snapshot);
        root.emitEntry(root.entry);
    }
    function undo() {
        var list = root.undoStack;
        if (!root.valid || list.length === 0) return;
        root.redoStack = root.redoStack.concat([root.keyOf(root.entry)]);
        root.undoStack = list.slice(0, -1);
        root.jump(list[list.length - 1]);
    }
    function redo() {
        var list = root.redoStack;
        if (!root.valid || list.length === 0) return;
        root.undoStack = root.undoStack.concat([root.keyOf(root.entry)]);
        root.redoStack = list.slice(0, -1);
        root.jump(list[list.length - 1]);
    }

    // ---- actions ---------------------------------------------------------
    function setInput(inp, raw) {
        if (!root.plan || !finite(raw)) return false;
        var value = Math.min(inp.max, Math.max(inp.min, Number(raw.toPrecision(12))));
        if (root.current[inp.id] === value) return false;
        return root.act(root.changedState(inp.id, value), root.plan.data, root.restored.scenarios, inp.id);
    }
    function resetAll() {
        if (root.plan && root.changedCount > 0) root.act({}, root.plan.data, root.restored.scenarios, "");
    }
    function discardEdits() {
        if (root.plan && root.editedCount > 0) root.act(root.changedState("", 0), Edit.discardEdits(root.plan.data), root.restored.scenarios, "");
    }
    function applyData(result) {
        if (result.ok) root.act(root.changedState("", 0), result.data, root.restored.scenarios, "");
    }
    function editCell(tableId, rowId, colId, text) {
        if (root.plan) root.applyData(Edit.setCell(root.plan.data, root.authored, tableId, rowId, colId, text));
    }
    function addRow(tableId) {
        if (root.plan) root.applyData(Edit.addRow(root.plan.data, root.authored, tableId));
    }
    function removeRow(tableId, rowId) {
        if (root.plan) root.applyData(Edit.removeRow(root.plan.data, root.authored, tableId, rowId));
    }
    function saveScenario(name) {
        var r = Edit.saveScenario(root.restored.scenarios, name, root.changedState("", 0));
        if (root.plan && r.ok) root.act(root.changedState("", 0), root.plan.data, r.scenarios, "");
    }
    function loadScenario(index) {
        var r = Edit.loadScenario(root.restored.scenarios, index);
        if (root.plan && r.ok) root.act(r.inputs, root.plan.data, root.restored.scenarios, "");
    }
    function deleteScenario(index) {
        var r = Edit.deleteScenario(root.restored.scenarios, index);
        if (root.plan && r.ok) root.act(root.changedState("", 0), root.plan.data, r.scenarios, "");
    }
    function parseTyped(text) {
        var s = String(text).trim();
        if (!/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(s)) return NaN;
        return Number(s);
    }

    // ---- export ----------------------------------------------------------
    // The compare view for the export: differing inputs, then every cell.
    function scenarioView() {
        var list = root.scenarioList;
        if (!root.plan || list.length < 2) return null;
        var names = [], rows = [], i, j;
        for (j = 0; j < list.length; ++j) names.push(list[j].name);
        for (i = 0; i < root.plan.inputs.length; ++i) {
            var inp = root.plan.inputs[i], vals = [], differs = false;
            for (j = 0; j < list.length; ++j) {
                vals.push(root.fmt(list[j].values[inp.id]));
                if (vals[j] !== vals[0]) differs = true;
            }
            if (differs) rows.push({label: inp.label || inp.id, unit: inp.unit, values: vals, errors: vals.map(function () { return null; })});
        }
        for (i = 0; i < root.plan.cells.length; ++i) {
            var cell = root.plan.cells[i], texts = [], errs = [], cur = list[0].result ? list[0].result.nodes[cell.id] : null;
            for (j = 0; j < list.length; ++j) {
                var node = list[j].result ? list[j].result.nodes[cell.id] : null;
                texts.push(node && !node.err ? Calc.formatCell(root.plan.model, list[j].result, cell.id) : "");
                errs.push(!node ? "N/A" : node.err ? node.err.code : null);
            }
            rows.push({label: cell.label, unit: cur && cur.unit ? cur.unit : "", values: texts, errors: errs});
        }
        return {names: names, rows: rows};
    }
    function copyCsv() {
        var view = root.plan && root.calcResult
            ? Export.viewFromRun(root.authored, root.plan, root.calcResult, {values: root.current, scenarios: root.scenarioView()}) : null;
        if (view) root.copyRequested(Export.csv(root.authored, view));
    }
    function duplicate() {
        var baked = root.valid ? Edit.bake(root.authored, root.entry) : null;
        if (baked) root.duplicateRequested(baked);
    }

    // ---- grid model ------------------------------------------------------
    function addReason(code) {
        return code === "max-rows" ? qsTr("This table already has %1 rows.").arg(Calc.maxRows)
            : code === "max-graph" ? qsTr("Another row would make this calculation too large.")
            : qsTr("No more rows can be added to this table.");
    }
    // One entry per table, stable while the plan is: the grid's effective table,
    // its edited cells and whether another row may be added.
    function makeGridInfo(plan, authored) {
        var out = [];
        if (!plan) return out;
        for (var t = 0; t < plan.tables.length; ++t) {
            var tb = plan.tables[t], rec = plan.data[tb.id], edited = {}, keys = rec && rec.e ? Object.keys(rec.e) : [];
            for (var k = 0; k < keys.length; ++k) edited[keys[k]] = true;
            var add = Edit.addRow(plan.data, authored, tb.id);
            out.push({table: {id: tb.id, label: tb.label, columns: tb.cols, rows: tb.rows, rowIds: tb.rowIds},
                      edited: edited, canAdd: add.ok, reason: add.ok ? "" : root.addReason(add.reason)});
        }
        return out;
    }
    function makeFormatter(plan, result) {
        return function (id) {
            try { return plan && result ? Calc.formatCell(plan.model, result, id) : ""; } catch (e) { return ""; }
        };
    }

    // ---- display helpers -------------------------------------------------
    function cellInfo(index, res) {
        var c = root.plan.cells[index];
        if (!res || !res.nodes[c.id]) return {text: "", error: false, message: ""};
        var r = res.nodes[c.id], message = "";
        if (r.err) {
            message = r.err.node === c.id ? qsTr("Cannot compute: ") + r.err.msg
                : qsTr("Waiting on ") + (root.plan.labels[r.err.node] || r.err.node) + ": " + r.err.msg;
        }
        return {text: Calc.formatCell(root.plan.model, res, c.id), error: !!r.err, message: message};
    }
    // Display text of one table cell (the snapshot tests compare against it).
    function tableCell(t, r, c, res) {
        var tb = root.plan.tables[t], col = tb.cols[c];
        if (col.kind === "formula")
            return res ? Calc.formatCell(root.plan.model, res, tb.id + "." + col.id + "#" + (r + 1)) : "";
        return tb.rows[r][c];
    }
    function provenanceOf(id, res) {
        var p = res ? Calc.provenance(root.plan.model, res, id) : null;
        if (!p) return null;
        var refs = [];
        for (var i = 0; i < p.refs.length; ++i) {
            var ref = p.refs[i], isCell = ref.basis === "cell";
            var basisText = ref.basis === "input" ? root.plan.basis[ref.name] : (isCell ? qsTr("calculated cell") : ref.basis);
            var value = ref.error ? "\u2014 (" + qsTr("error ") + ref.error + ")" : (ref.text || qsTr("all values in range"));
            refs.push({name: ref.name, isCell: isCell, line: ref.name + " = " + value + "  \u00b7  " + basisText});
        }
        var message = "";
        if (p.error) {
            message = p.error.node === id ? qsTr("Cannot compute: ") + p.error.msg
                : qsTr("Waiting on ") + (root.plan.labels[p.error.node] || p.error.node) + ": " + p.error.msg;
        }
        return {formula: p.formula, refs: refs, unit: p.unitDerivation, rounding: p.rounding,
                warnings: p.warnings, error: message, chain: p.chain.join(" \u2192 ")};
    }
    function toggleCell(id) {
        var next = {};
        for (var k in root.openCells) next[k] = root.openCells[k];
        next[id] = !next[id];
        root.openCells = next;
    }
    // A toolbar button that disables or hides itself (the last Undo) must not strand
    // keyboard focus: hand it to the nearest button that still works.
    function fromToolbar(action) {
        var kids = root.toolbarItem.children, at = -1, i;
        for (i = 0; i < kids.length; ++i) if (kids[i].activeFocus) at = i;
        action();
        if (at < 0 || (kids[at].visible && kids[at].enabled)) return;
        for (var k = 1; k < kids.length; ++k) {
            var pick = [at + k, at - k];
            for (i = 0; i < 2; ++i) {
                var b = pick[i] >= 0 && pick[i] < kids.length ? kids[pick[i]] : null;
                if (b && b.visible && b.enabled) { b.forceActiveFocus(Qt.TabFocusReason); return; }
            }
        }
    }
    function openCell(id) {
        if (root.openCells[id] !== true) root.toggleCell(id);
        root.focusCellRequested(id);
    }

    // Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y undo and redo, except while a text editor has
    // focus (the grid's cell editor, a number field, the scenario name): those keep
    // their own native text undo.
    Keys.onPressed: function(event) {
        if (!(event.modifiers & Qt.ControlModifier) || (event.modifiers & (Qt.AltModifier | Qt.MetaModifier))) return;
        var focused = root.Window.activeFocusItem;
        if (focused && "selectByMouse" in focused) return;
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        if (event.key === Qt.Key_Z && !shift) root.undo();
        else if ((event.key === Qt.Key_Z && shift) || event.key === Qt.Key_Y) root.redo();
        else return;
        event.accepted = true;
    }

    component CalcButton: Button {
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
        Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
        Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
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

    Text {
        objectName: "aiCalcInvalid"
        width: root.width
        visible: !root.valid
        text: root.invalidText
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.alpha(root.foreground, 0.85)
        font.pixelSize: Satin.type.meta
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    Loader {
        width: root.width
        active: root.valid
        sourceComponent: bodyComponent
    }

    Component {
        id: bodyComponent
        Column {
            id: body
            spacing: Satin.space.section

            Repeater {
                model: root.plan.inputs
                delegate: Column {
                    id: inputRow
                    required property var modelData
                    required property int index
                    width: body.width
                    spacing: 4
                    readonly property real cur: root.current[modelData.id] !== undefined ? root.current[modelData.id] : modelData.value
                    readonly property string unitSuffix: modelData.unit.length ? " " + modelData.unit : ""
                    Connections {
                        target: root
                        function onRefused() { track.value = inputRow.cur; field.sync(); }
                    }

                    Row {
                        width: inputRow.width
                        spacing: Satin.space.gutter
                        Text {
                            objectName: "aiCalcInputLabel_" + inputRow.index
                            width: Math.max(0, inputRow.width - badge.width - Satin.space.gutter)
                            text: inputRow.modelData.label
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.foreground
                            font.pixelSize: Satin.type.result
                        }
                        Rectangle {
                            id: badge
                            width: badgeText.implicitWidth + 12
                            height: badgeText.implicitHeight + 4
                            radius: Satin.radius.chip
                            color: "transparent"
                            border.width: 1
                            border.color: root.alpha(root.foreground, 0.4)
                            Text {
                                id: badgeText
                                objectName: "aiCalcBasis_" + inputRow.index
                                anchors.centerIn: parent
                                text: inputRow.modelData.basis
                                textFormat: Text.PlainText
                                color: root.alpha(root.foreground, 0.80)
                                font.pixelSize: Satin.type.label
                                Accessible.name: qsTr("Basis: ") + text
                            }
                        }
                    }

                    Row {
                        width: inputRow.width
                        spacing: Satin.space.gutter

                        Slider {
                            id: track
                            objectName: "aiCalcSlider_" + inputRow.index
                            width: Math.max(60, inputRow.width - entry.width - Satin.space.gutter)
                            implicitHeight: 28
                            from: inputRow.modelData.min
                            to: inputRow.modelData.max
                            stepSize: inputRow.modelData.step
                            snapMode: Slider.SnapAlways
                            value: inputRow.cur
                            activeFocusOnTab: true
                            hoverEnabled: true
                            onMoved: root.setInput(inputRow.modelData, track.value)
                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Home) {
                                    root.setInput(inputRow.modelData, track.from);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_End) {
                                    root.setInput(inputRow.modelData, track.to);
                                    event.accepted = true;
                                }
                            }
                            Accessible.name: inputRow.modelData.label + ": " + root.fmt(inputRow.cur) + inputRow.unitSuffix
                            Accessible.description: qsTr("Use Left and Right to adjust; Home and End jump to the ends.")
                            background: Rectangle {
                                x: track.leftPadding
                                y: track.topPadding + track.availableHeight / 2 - height / 2
                                width: track.availableWidth
                                height: 4
                                implicitHeight: 4
                                radius: 2
                                color: root.alpha(root.foreground, 0.15)
                                Rectangle {
                                    width: track.visualPosition * parent.width
                                    height: parent.height
                                    radius: 2
                                    color: root.accent
                                }
                            }
                            handle: Rectangle {
                                x: track.leftPadding + track.visualPosition * (track.availableWidth - width)
                                y: track.topPadding + track.availableHeight / 2 - height / 2
                                width: 18
                                height: 18
                                implicitWidth: 18
                                implicitHeight: 18
                                radius: 9
                                color: root.accent
                                border.width: track.activeFocus ? 2 : 0
                                border.color: root.foreground
                            }
                        }

                        Row {
                            id: entry
                            spacing: 4
                            TextField {
                                id: field
                                objectName: "aiCalcField_" + inputRow.index
                                width: 84
                                height: 32
                                text: root.fmt(inputRow.cur)
                                selectByMouse: true
                                activeFocusOnTab: true
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                color: root.foreground
                                selectionColor: root.alpha(root.accent, 0.35)
                                selectedTextColor: root.foreground
                                font.pixelSize: Satin.type.meta
                                horizontalAlignment: Text.AlignRight
                                function sync() { field.text = root.fmt(inputRow.cur); }
                                Connections {
                                    target: inputRow
                                    function onCurChanged() { field.sync(); }
                                }
                                onEditingFinished: {
                                    var typed = root.parseTyped(field.text);
                                    if (isFinite(typed)) root.setInput(inputRow.modelData, typed);
                                    field.sync();
                                }
                                Keys.onEscapePressed: function(event) {
                                    if (field.text !== root.fmt(inputRow.cur)) {
                                        field.sync();
                                        event.accepted = true;
                                    } else event.accepted = false;
                                }
                                Accessible.name: inputRow.modelData.label + (inputRow.modelData.unit.length ? " (" + inputRow.modelData.unit + ")" : "")
                                Accessible.description: qsTr("Type a number from ") + root.fmt(inputRow.modelData.min) + qsTr(" to ")
                                    + root.fmt(inputRow.modelData.max) + qsTr(" and press Enter.")
                                background: Rectangle {
                                    radius: Satin.radius.field
                                    color: root.alpha(root.foreground, 0.04)
                                    border.width: field.activeFocus ? 2 : 1
                                    border.color: field.activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)
                                }
                            }
                            Text {
                                objectName: "aiCalcUnit_" + inputRow.index
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, 72)
                                text: inputRow.modelData.unit
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: root.alpha(root.foreground, 0.80)
                                font.pixelSize: Satin.type.meta
                            }
                        }
                    }
                }
            }

            Flow {
                id: toolbar
                objectName: "aiCalcToolbar"
                Component.onCompleted: root.toolbarItem = toolbar
                width: body.width
                spacing: Satin.space.base
                Accessible.role: Accessible.ToolBar
                Accessible.name: qsTr("Calculation tools")

                CalcButton {
                    objectName: "aiCalcReset"
                    ink: root.foreground
                    ring: root.accent
                    visible: root.plan.inputs.length > 0
                    text: qsTr("Reset to defaults")
                    enabled: root.changedCount > 0
                    onClicked: root.fromToolbar(root.resetAll)
                }
                CalcButton {
                    objectName: "aiCalcUndo"
                    ink: root.foreground
                    ring: root.accent
                    text: qsTr("Undo")
                    enabled: root.canUndo
                    onClicked: root.fromToolbar(root.undo)
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: root.historyNote
                    Accessible.description: root.historyNote
                }
                CalcButton {
                    objectName: "aiCalcRedo"
                    ink: root.foreground
                    ring: root.accent
                    text: qsTr("Redo")
                    enabled: root.canRedo
                    onClicked: root.fromToolbar(root.redo)
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: root.historyNote
                    Accessible.description: root.historyNote
                }
                CalcButton {
                    objectName: "aiCalcDiscard"
                    ink: root.foreground
                    ring: root.accent
                    visible: root.editedCount > 0
                    text: qsTr("Discard my edits (%1)").arg(root.editedCount)
                    onClicked: root.fromToolbar(root.discardEdits)
                    Accessible.description: qsTr("Restores the table to what the answer gave. Your input values stay.")
                }
                CalcButton {
                    objectName: "aiCalcCopy"
                    ink: root.foreground
                    ring: root.accent
                    text: qsTr("Copy as CSV")
                    enabled: root.calcResult !== null
                    onClicked: root.copyCsv()
                }
                CalcButton {
                    objectName: "aiCalcDuplicate"
                    ink: root.foreground
                    ring: root.accent
                    text: qsTr("Duplicate")
                    enabled: root.valid && root.canDuplicate
                    onClicked: root.duplicate()
                    Accessible.description: root.canDuplicate
                        ? qsTr("Starts a copy of this calculation with the current values as its defaults.") : root.duplicateHint
                    ToolTip.visible: hovered && !enabled && root.duplicateHint !== ""
                    ToolTip.text: root.duplicateHint
                }
            }
            Text {
                objectName: "aiCalcRestoreNote"
                width: body.width
                visible: root.restoreReset
                text: root.restoreNoteText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.85)
                font.pixelSize: Satin.type.label
                Accessible.name: text
            }
            Text {
                objectName: "aiCalcTooLarge"
                width: body.width
                visible: root.tooLarge
                text: root.tooLargeText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.90)
                font.pixelSize: Satin.type.label
                font.weight: Font.DemiBold
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }

            Repeater {
                model: root.plan.cells
                delegate: Column {
                    id: cellRow
                    required property var modelData
                    required property int index
                    width: body.width
                    spacing: 3
                    readonly property var info: root.cellInfo(index, root.calcResult)
                    readonly property bool open: root.openCells[modelData.id] === true
                    readonly property var prov: open ? root.provenanceOf(modelData.id, root.calcResult) : null

                    Connections {
                        target: root
                        function onFocusCellRequested(cellId) {
                            if (cellId === cellRow.modelData.id) toggle.forceActiveFocus(Qt.TabFocusReason);
                        }
                    }

                    Row {
                        width: cellRow.width
                        spacing: Satin.space.base
                        Text {
                            objectName: "aiCalcCellLabel_" + cellRow.index
                            width: Math.max(0, cellRow.width * 0.5)
                            text: cellRow.modelData.label
                            textFormat: Text.PlainText
                            wrapMode: Text.WordWrap
                            color: root.alpha(root.foreground, 0.85)
                            font.pixelSize: Satin.type.meta
                        }
                        Text {
                            objectName: "aiCalcCell_" + cellRow.index
                            width: Math.max(0, cellRow.width - cellRow.width * 0.5 - Satin.space.base)
                            text: cellRow.info.text
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.foreground
                            font.pixelSize: Satin.type.result
                            font.weight: Font.DemiBold
                            Accessible.role: Accessible.StaticText
                            Accessible.name: cellRow.modelData.label + ": "
                                + (cellRow.info.error ? qsTr("no value. ") + cellRow.info.message : text)
                        }
                    }
                    Text {
                        objectName: "aiCalcCellError_" + cellRow.index
                        width: cellRow.width
                        visible: cellRow.info.error
                        text: cellRow.info.message
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.alpha(root.foreground, 0.90)
                        font.pixelSize: Satin.type.label
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                    Text {
                        objectName: "aiCalcCellNote_" + cellRow.index
                        width: cellRow.width
                        visible: text.length > 0
                        text: cellRow.modelData.note
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.alpha(root.foreground, 0.76)
                        font.pixelSize: Satin.type.label
                    }
                    Button {
                        id: toggle
                        objectName: "aiCalcProvToggle_" + cellRow.index
                        padding: 4
                        implicitHeight: 28
                        activeFocusOnTab: true
                        hoverEnabled: true
                        text: qsTr("How is this calculated?")
                        onClicked: root.toggleCell(cellRow.modelData.id)
                        Accessible.name: text + " " + cellRow.modelData.label + (cellRow.open ? qsTr(", expanded") : qsTr(", collapsed"))
                        contentItem: Text {
                            text: (cellRow.open ? "\u25be " : "\u25b8 ") + toggle.text
                            textFormat: Text.PlainText
                            color: root.alpha(root.foreground, 0.80)
                            font.pixelSize: Satin.type.label
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: Satin.radius.chip
                            color: toggle.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                            border.width: toggle.visualFocus ? 2 : 0
                            border.color: root.accent
                        }
                    }
                    Column {
                        objectName: "aiCalcProv_" + cellRow.index
                        width: cellRow.width
                        visible: cellRow.open && cellRow.prov !== null
                        spacing: 3
                        Text {
                            objectName: "aiCalcProvFormula_" + cellRow.index
                            width: parent.width
                            text: cellRow.prov ? qsTr("Formula: ") + cellRow.prov.formula : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAnywhere
                            color: root.alpha(root.foreground, 0.85)
                            font.family: "monospace"
                            font.pixelSize: Satin.type.label
                        }
                        Repeater {
                            model: cellRow.prov ? cellRow.prov.refs : []
                            delegate: Button {
                                id: refButton
                                required property var modelData
                                required property int index
                                objectName: "aiCalcProvRef_" + cellRow.index + "_" + index
                                Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
                                Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
                                width: cellRow.width
                                padding: 2
                                focusPolicy: modelData.isCell ? Qt.StrongFocus : Qt.NoFocus
                                activeFocusOnTab: modelData.isCell
                                hoverEnabled: modelData.isCell
                                onClicked: if (modelData.isCell) root.openCell(modelData.name)
                                Accessible.name: modelData.isCell ? qsTr("Show how ") + modelData.name + qsTr(" is calculated: ") + modelData.line : modelData.line
                                contentItem: Text {
                                    text: refButton.modelData.line
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap
                                    color: refButton.modelData.isCell ? root.accent : root.alpha(root.foreground, 0.85)
                                    font.pixelSize: Satin.type.label
                                }
                                background: Rectangle {
                                    radius: Satin.radius.chip
                                    color: refButton.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                                    border.width: refButton.visualFocus ? 2 : 0
                                    border.color: root.accent
                                }
                            }
                        }
                        Text {
                            objectName: "aiCalcProvUnit_" + cellRow.index
                            width: parent.width
                            text: cellRow.prov ? cellRow.prov.unit : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.alpha(root.foreground, 0.85)
                            font.pixelSize: Satin.type.label
                        }
                        Text {
                            objectName: "aiCalcProvRounding_" + cellRow.index
                            width: parent.width
                            text: cellRow.prov ? cellRow.prov.rounding : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.alpha(root.foreground, 0.85)
                            font.pixelSize: Satin.type.label
                        }
                        Text {
                            objectName: "aiCalcProvWarnings_" + cellRow.index
                            width: parent.width
                            visible: text.length > 0
                            text: cellRow.prov ? cellRow.prov.warnings.join("\n") : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.alpha(root.foreground, 0.85)
                            font.pixelSize: Satin.type.label
                        }
                        Text {
                            objectName: "aiCalcProvError_" + cellRow.index
                            width: parent.width
                            visible: text.length > 0
                            text: cellRow.prov && cellRow.prov.error.length
                                ? cellRow.prov.error + (cellRow.prov.chain.length ? "\n" + qsTr("Failing chain: ") + cellRow.prov.chain : "") : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.alpha(root.foreground, 0.90)
                            font.pixelSize: Satin.type.label
                        }
                    }
                }
            }

            Repeater {
                // A count, not the tables: an edit swaps the plan, and the grid whose
                // button was just clicked must not be rebuilt under its own handler.
                model: root.plan.tables.length
                delegate: Column {
                    id: tableView
                    required property int index
                    readonly property var info: root.gridInfo[index] || root.noGrid
                    width: body.width
                    spacing: 4

                    Text {
                        objectName: "aiCalcTableLabel_" + tableView.index
                        width: tableView.width
                        visible: text.length > 0
                        text: tableView.info.table.label
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.foreground
                        font.pixelSize: Satin.type.meta
                        font.weight: Font.DemiBold
                    }
                    AiCalcGrid {
                        objectName: "aiCalcGrid_" + tableView.index
                        width: tableView.width
                        table: tableView.info.table
                        nodes: root.calcResult ? root.calcResult.nodes : ({})
                        formatText: root.formatter
                        editedKeys: tableView.info.edited
                        canAdd: tableView.info.canAdd
                        addBlockedReason: tableView.info.reason
                        foreground: root.foreground
                        background: root.background
                        accent: root.accent
                        onCellCommitted: (rowId, colId, text) => root.editCell(tableView.info.table.id, rowId, colId, text)
                        onClearRequested: (rowId, colId) => root.editCell(tableView.info.table.id, rowId, colId, "")
                        onAddRowRequested: root.addRow(tableView.info.table.id)
                        onRemoveRowRequested: rowId => root.removeRow(tableView.info.table.id, rowId)
                    }
                }
            }

            AiCalcScenarios {
                id: scenarioPanel
                width: body.width
                visible: root.plan.inputs.length > 0
                plan: root.plan
                model: root.plan.model
                scenarios: root.scenarioList
                inputs: root.plan.inputs
                foreground: root.foreground
                background: root.background
                accent: root.accent
                onSaveRequested: name => root.saveScenario(name)
                onLoadRequested: index => root.loadScenario(index)
                onDeleteRequested: index => root.deleteScenario(index)
            }

            Text {
                objectName: "aiCalcNote"
                width: body.width
                visible: text.length > 0
                text: root.plan.note
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.76)
                font.pixelSize: Satin.type.label
            }
        }
    }
}
