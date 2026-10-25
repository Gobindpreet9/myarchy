pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiState.js" as AiState

// A model-authored form (1..6 fields: number, choice, text, toggle). The model
// supplies labels and defaults only; every rule, parse and restore decision is
// AiState.form* (pure, tested). Block text is model text: PlainText everywhere.
//
// State. `saved` is the persisted `form:<blockIndex>` entry {v: {<id>: number|string},
// sent: bool}; this component never keeps a second copy. An action composes the
// full next entry from the PERSISTED draft and emits it (stateEdited); the display
// follows `saved`, so a host that refuses an edit leaves the form showing what is
// stored. Only a value that passed its field's rule is emitted: invalid or
// out-of-range typing stays in the field with an inline message (never stored) and
// the form is not submittable until it is fixed. Validity and the "all answered"
// state are derived, never persisted. A stale/hostile entry is restored by dropping
// what no longer matches (note shown), never clamping.
//
// Keyboard: each field is one Tab stop (a choice group is ONE stop: arrows move
// the cursor, Space/Enter select), Enter in the last field submits only when the
// form is valid, Escape is not handled here.
Column {
    id: root
    objectName: "aiForm"
    spacing: Satin.space.gutter

    property var block: ({})
    property int blockIndex: 0
    // The persisted `form:<blockIndex>` entry (undefined when untouched).
    property var saved: undefined
    // The host's decision: the form's turn is the latest answer and the service
    // is idle. `submitHint` says why not (shown only while it blocks sending).
    property bool canSubmit: true
    property string submitHint: ""
    required property color foreground
    required property color background
    required property color accent

    // The complete next `form:<blockIndex>` object.
    signal stateEdited(var state)
    signal submitRequested()

    readonly property string invalidText: qsTr("This form can't be shown.")
    readonly property string restoreNoteText: qsTr("Some saved values no longer match this form and were reset.")
    readonly property string tooLongText: qsTr("These answers are too long to send together. Shorten the text.")
    readonly property string fixText: qsTr("Fix the marked fields to send.")
    readonly property string sendFailedText: qsTr("Couldn't send these answers. Try again in a moment.")

    // The field model depends on the block only: a value edit must never rebuild
    // the field delegates (that would drop focus mid-typing).
    readonly property var spec: AiState.formNormalize(root.block)
    readonly property var restored: AiState.formApply(root.spec, root.saved)
    readonly property bool usable: root.spec !== null
    readonly property var fields: root.usable ? root.spec.fields : []
    readonly property var values: root.restored.values
    readonly property var draft: root.restored.draft
    readonly property bool sent: root.restored.sent
    readonly property int dropped: root.restored.dropped
    readonly property var answers: AiState.formAnswersOf(root.restored)
    // Measured against the widest possible turn id, so it never flips later.
    readonly property bool fits: AiState.formWireFits(AiState.formWire(root.restored, 9007199254740991, 5))
    // Transient, never persisted: field id -> message / note.
    property var issues: ({})
    property var notes: ({})
    // Only the CURRENT fields count: a stale entry of a replaced field is inert.
    readonly property bool hasIssues: {
        for (var i = 0; i < root.fields.length; ++i)
            if (root.issueOf(root.fields[i].id) !== "") return true;
        return false;
    }
    readonly property bool valid: root.usable && !root.hasIssues && root.fits
    readonly property bool submitEnabled: root.valid && root.canSubmit && !root.sent
    readonly property int delegateCount: fieldRepeater.count
    readonly property string hintText: {
        if (!root.usable || root.sent) return "";
        if (root.hasIssues) return root.fixText;
        if (!root.fits) return root.tooLongText;
        if (root.sendFailed) return root.sendFailedText;
        return root.canSubmit ? "" : root.submitHint;
    }
    property bool focusOnSent: false
    // The host is expected to record `sent` synchronously when it accepts the
    // send; if it did not, say so instead of leaving a button that did nothing.
    property bool sendFailed: false

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function own(map, id) { return Object.prototype.hasOwnProperty.call(map, id); }
    function issueOf(id) { return root.own(root.issues, id) ? String(root.issues[id]) : ""; }
    function noteOf(id) { return root.own(root.notes, id) ? String(root.notes[id]) : ""; }
    function setIssue(id, message) {
        if (root.issueOf(id) === message) return;
        var next = Object.assign({}, root.issues);
        next[id] = message;
        root.issues = next;
    }
    function clearIssue(id) {
        if (!root.own(root.issues, id)) return;
        var next = Object.assign({}, root.issues);
        delete next[id];
        root.issues = next;
    }
    function setNote(id, text) {
        var next = Object.assign({}, root.notes);
        next[id] = text;
        root.notes = next;
    }
    function clearNote(id) {
        if (!root.own(root.notes, id)) return;
        var next = Object.assign({}, root.notes);
        delete next[id];
        root.notes = next;
    }
    function sameField(field, index) {
        var now = index >= 0 && index < root.fields.length ? root.fields[index] : null;
        return !!field && !!now && now.id === field.id && now.kind === field.kind && now.min === field.min && now.max === field.max;
    }
    function valueOf(id) { return root.own(root.values, id) ? root.values[id] : undefined; }
    function lineAt(index) {
        var a = index >= 0 && index < root.answers.length ? root.answers[index] : null;
        return a ? a.label + ": " + AiState.formValueText(a) : "";
    }
    function setValue(id, value) {
        var next = Object.assign({}, root.draft);
        next[id] = value;
        root.sendFailed = false;
        root.stateEdited({v: next, sent: false});
    }
    // The send is delivered AFTER the click/key handler that asked for it has
    // returned: the host appends a turn, which tears this answer's row down, and
    // that must never happen from inside the pressed button's own handler.
    function requestSubmit() {
        if (!root.submitEnabled) return false;
        Qt.callLater(root.deliverSubmit);
        return true;
    }
    function deliverSubmit() {
        if (!root.submitEnabled) return;
        root.focusOnSent = true;
        root.sendFailed = false;
        root.submitRequested();
        root.focusOnSent = false;
        if (!root.sent) root.sendFailed = true;
    }
    function changeAnswers() {
        if (!root.sent) return;
        root.stateEdited({v: Object.assign({}, root.draft), sent: false});
        Qt.callLater(root.focusFirst);
    }
    function focusFirst() {
        // The first Tab stop after the row itself is its editor.
        var row = fieldRepeater.count > 0 ? fieldRepeater.itemAt(0) : null;
        var target = row ? row.nextItemInFocusChain(true) : null;
        if (target) target.forceActiveFocus(Qt.TabFocusReason);
    }
    onSentChanged: {
        if (root.sent && root.focusOnSent) Qt.callLater(function() { sentMarker.forceActiveFocus(Qt.OtherFocusReason); });
    }

    Text {
        objectName: "aiFormInvalid"
        width: root.width
        visible: !root.usable
        text: root.invalidText
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.meta
        Accessible.name: text
    }
    Text {
        objectName: "aiFormRestoreNote"
        width: root.width
        visible: root.usable && root.dropped > 0
        text: root.restoreNoteText
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.label
        Accessible.name: text
    }

    Repeater {
        id: fieldRepeater
        objectName: "aiFormFields"
        model: root.fields
        delegate: Column {
            id: fieldRow
            required property var modelData
            required property int index
            objectName: "aiFormField_" + index
            width: root.width
            spacing: Satin.space.base
            readonly property var field: fieldRow.modelData
            readonly property string issue: root.issueOf(fieldRow.field.id)
            readonly property string note: root.noteOf(fieldRow.field.id)

            Text {
                objectName: "aiFormLabel_" + fieldRow.index
                width: parent.width
                visible: !root.sent && fieldRow.field.kind !== "toggle"
                text: fieldRow.field.label
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.foreground
                font.pixelSize: Satin.type.name
                font.weight: Font.DemiBold
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
            // After sending, the values are shown read-only.
            Text {
                objectName: "aiFormSentLine_" + fieldRow.index
                width: parent.width
                visible: root.sent
                text: root.lineAt(fieldRow.index)
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, 0.90)
                font.pixelSize: Satin.type.result
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
            Loader {
                id: editorLoader
                width: parent.width
                active: !root.sent
                visible: active
                property var field: fieldRow.field
                property int fieldIndex: fieldRow.index
                property bool lastField: fieldRow.index === root.fields.length - 1
                sourceComponent: {
                    switch (fieldRow.field.kind) {
                    case "number": return numberEditor;
                    case "choice": return choiceEditor;
                    case "toggle": return toggleEditor;
                    default: return textEditor;
                    }
                }
            }
            Row {
                spacing: 6
                visible: fieldRow.issue !== "" && !root.sent
                Text {
                    text: "\u26a0"
                    textFormat: Text.PlainText
                    color: root.accent
                    font.pixelSize: Satin.type.label
                    font.weight: Font.Bold
                    Accessible.ignored: true
                }
                Text {
                    objectName: "aiFormMessage_" + fieldRow.index
                    width: fieldRow.width - 20
                    text: fieldRow.issue
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: root.alpha(root.foreground, 0.90)
                    font.pixelSize: Satin.type.label
                    font.weight: Font.DemiBold
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }
            }
            Text {
                objectName: "aiFormNote_" + fieldRow.index
                width: parent.width
                visible: fieldRow.note !== "" && fieldRow.issue === "" && !root.sent
                text: fieldRow.note
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.label
                Accessible.name: text
            }
        }
    }

    Text {
        objectName: "aiFormBlockNote"
        width: root.width
        visible: root.usable && text.length > 0
        text: root.usable ? root.spec.note : ""
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.meta
        Accessible.name: text
    }

    Flow {
        objectName: "aiFormActions"
        width: root.width
        visible: root.usable
        spacing: Satin.space.gutter
        FormButton {
            objectName: "aiFormSubmit"
            visible: !root.sent
            text: root.usable ? root.spec.submitLabel : ""
            primary: true
            enabled: root.submitEnabled
            ink: root.foreground
            ring: root.accent
            Accessible.description: root.hintText
            onClicked: root.requestSubmit()
        }
        Text {
            id: sentMarker
            objectName: "aiFormSent"
            visible: root.sent
            height: 34
            text: "\u2713 " + qsTr("Sent")
            textFormat: Text.PlainText
            verticalAlignment: Text.AlignVCenter
            color: root.accent
            font.pixelSize: Satin.type.meta
            font.weight: Font.DemiBold
            activeFocusOnTab: true
            Accessible.role: Accessible.StaticText
            Accessible.name: qsTr("Sent. Answers were sent.")
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                color: "transparent"
                radius: 4
                border.width: sentMarker.activeFocus ? 2 : 0
                border.color: root.accent
            }
        }
        FormButton {
            objectName: "aiFormChange"
            visible: root.sent
            text: qsTr("Change answers")
            enabled: root.canSubmit
            ink: root.foreground
            ring: root.accent
            Accessible.description: root.canSubmit ? "" : root.submitHint
            onClicked: root.changeAnswers()
        }
    }
    Text {
        objectName: "aiFormHint"
        width: root.width
        visible: text.length > 0
        text: root.hintText
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.label
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // ---- editors (their parent is the field's Loader) -----------------------
    component FormButton: Button {
        id: control
        required property color ink
        required property color ring
        property bool primary: false
        padding: 4
        leftPadding: 14
        rightPadding: 14
        implicitHeight: 34
        hoverEnabled: true
        Accessible.name: text
        Keys.onReturnPressed: { if (control.enabled) control.clicked(); }
        Keys.onEnterPressed: { if (control.enabled) control.clicked(); }
        contentItem: Text {
            text: control.text
            textFormat: Text.PlainText
            color: Qt.rgba(control.primary && control.enabled ? control.ring.r : control.ink.r,
                           control.primary && control.enabled ? control.ring.g : control.ink.g,
                           control.primary && control.enabled ? control.ring.b : control.ink.b,
                           control.enabled ? 0.95 : 0.76)
            font.pixelSize: Satin.type.meta
            font.weight: control.enabled ? Font.DemiBold : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: Satin.radius.chip
            color: control.down && control.enabled ? Qt.rgba(control.ring.r, control.ring.g, control.ring.b, 0.24)
                : control.enabled && (control.hovered || control.primary) ? Qt.rgba(control.ring.r, control.ring.g, control.ring.b, 0.12)
                : "transparent"
            border.width: control.activeFocus ? 2 : (control.enabled ? 1 : 0)
            border.color: control.activeFocus ? control.ring
                : Qt.rgba(control.ring.r, control.ring.g, control.ring.b, 0.5)
        }
    }

    Component {
        id: numberEditor
        Column {
            id: numberBox
            readonly property var host: parent
            readonly property var field: host.field
            readonly property int fieldIndex: host.fieldIndex
            readonly property bool lastField: host.lastField
            readonly property real current: Number(root.valueOf(field.id))
            readonly property string shown: AiState.formNumberText(numberBox.current)
            readonly property string rangeText: qsTr("Allowed: %1").arg(AiState.formRangeHint(field))
            // False once the block was replaced under this delegate (it is being
            // torn down): a late blur must never write state.
            // False once this delegate's field is no longer the block's field at
            // its index (its row is being replaced): a late blur must never write.
            // A function, not a binding, so a late event cannot see an old value.
            function live() { return root.sameField(numberBox.field, numberBox.fieldIndex); }
            Component.onCompleted: { root.clearIssue(field.id); root.clearNote(field.id); input.text = numberBox.shown; }
            spacing: 2

            function edited() {
                var r = AiState.formParseNumber(field, input.text);
                if (!r.ok) { root.setIssue(field.id, r.msg); return; }
                root.clearIssue(field.id);
                root.clearNote(field.id);
                if (r.value !== numberBox.current) root.setValue(field.id, r.value);
            }
            // Returns true when the typed value was out of range and was clamped.
            function commit() {
                var r = AiState.formParseNumber(field, input.text);
                if (r.ok) {
                    root.clearIssue(field.id);
                    if (r.value !== numberBox.current) root.setValue(field.id, r.value);
                    input.text = AiState.formNumberText(r.value);
                    return false;
                }
                if (r.clamped === null) { root.setIssue(field.id, r.msg); return false; }
                root.clearIssue(field.id);
                root.setNote(field.id, qsTr("Adjusted to %1.").arg(AiState.formNumberText(r.clamped)));
                if (r.clamped !== numberBox.current) root.setValue(field.id, r.clamped);
                input.text = AiState.formNumberText(r.clamped);
                return true;
            }
            function enter() {
                var adjusted = numberBox.commit();
                if (numberBox.lastField && !adjusted) root.requestSubmit();
            }

            Row {
                spacing: Satin.space.tip
                TextField {
                    id: input
                    objectName: "aiFormInput_" + numberBox.fieldIndex
                    width: Math.max(96, Math.min(numberBox.width - (unitText.visible ? unitText.width + Satin.space.tip : 0), 220))
                    maximumLength: 64
                    selectByMouse: true
                    activeFocusOnTab: true
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    color: root.foreground
                    placeholderTextColor: root.alpha(root.foreground, 0.76)
                    selectionColor: root.alpha(root.accent, 0.35)
                    selectedTextColor: root.foreground
                    font.pixelSize: Satin.type.result
                    Accessible.name: numberBox.field.label + (numberBox.field.unit ? " (" + numberBox.field.unit + ")" : "")
                    Accessible.description: numberBox.rangeText + (root.issueOf(numberBox.field.id) ? ". " + root.issueOf(numberBox.field.id) : "")
                    onTextEdited: numberBox.edited()
                    onActiveFocusChanged: { if (!input.activeFocus && numberBox.live()) numberBox.commit(); }
                    Keys.onReturnPressed: numberBox.enter()
                    Keys.onEnterPressed: numberBox.enter()
                    background: Rectangle {
                        radius: Satin.radius.field
                        color: root.alpha(root.foreground, 0.04)
                        border.width: input.activeFocus || root.issueOf(numberBox.field.id) !== "" ? 2 : 1
                        border.color: input.activeFocus ? root.accent
                            : root.issueOf(numberBox.field.id) !== "" ? root.alpha(root.foreground, 0.9)
                            : root.alpha(root.foreground, Satin.keyline.inner)
                    }
                }
                Text {
                    id: unitText
                    objectName: "aiFormUnit_" + numberBox.fieldIndex
                    anchors.verticalCenter: parent.verticalCenter
                    visible: numberBox.field.unit !== ""
                    text: numberBox.field.unit
                    textFormat: Text.PlainText
                    color: root.alpha(root.foreground, 0.86)
                    font.pixelSize: Satin.type.meta
                }
            }
            Text {
                objectName: "aiFormRange_" + numberBox.fieldIndex
                width: parent.width
                text: numberBox.rangeText
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: root.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.label
            }
            // Follows the stored value while the field is not being edited.
            Connections {
                target: numberBox
                function onShownChanged() {
                    if (!input.activeFocus && root.issueOf(numberBox.field.id) === "") input.text = numberBox.shown;
                }
            }
        }
    }

    Component {
        id: textEditor
        Column {
            id: textBox
            readonly property var host: parent
            readonly property var field: host.field
            readonly property int fieldIndex: host.fieldIndex
            readonly property bool lastField: host.lastField
            readonly property string current: String(root.valueOf(field.id))
            function live() { return root.sameField(textBox.field, textBox.fieldIndex); }
            Component.onCompleted: { root.clearIssue(field.id); input.text = textBox.current; }
            spacing: 2

            function edited() {
                var r = AiState.formParseText(input.text);
                if (!r.ok) { root.setIssue(field.id, r.msg); return; }
                root.clearIssue(field.id);
                if (r.text !== textBox.current) root.setValue(field.id, r.text);
            }
            function commit() {
                var r = AiState.formParseText(input.text);
                if (!r.ok) { root.setIssue(field.id, r.msg); return; }
                root.clearIssue(field.id);
                if (r.text !== textBox.current) root.setValue(field.id, r.text);
                input.text = r.text;
            }
            function enter() {
                textBox.commit();
                if (textBox.lastField) root.requestSubmit();
            }

            TextField {
                id: input
                objectName: "aiFormInput_" + textBox.fieldIndex
                placeholderTextColor: root.alpha(root.foreground, 0.76)
                width: Math.min(textBox.width, 420)
                selectByMouse: true
                activeFocusOnTab: true
                color: root.foreground
                selectionColor: root.alpha(root.accent, 0.35)
                selectedTextColor: root.foreground
                font.pixelSize: Satin.type.result
                Accessible.name: textBox.field.label
                Accessible.description: root.issueOf(textBox.field.id) || textBox.field.placeholder
                onTextEdited: textBox.edited()
                onActiveFocusChanged: { if (!input.activeFocus && textBox.live()) textBox.commit(); }
                Keys.onReturnPressed: textBox.enter()
                Keys.onEnterPressed: textBox.enter()
                // The model's placeholder is drawn as PlainText by this overlay,
                // never through TextField.placeholderText (which parses markup).
                Text {
                    objectName: "aiFormPlaceholder_" + textBox.fieldIndex
                    x: input.leftPadding
                    y: input.topPadding
                    width: Math.max(0, input.width - input.leftPadding - input.rightPadding)
                    height: input.height - input.topPadding - input.bottomPadding
                    visible: input.text.length === 0 && input.preeditText.length === 0
                    text: textBox.field.placeholder
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    color: root.alpha(root.foreground, 0.76)
                    font.pixelSize: input.font.pixelSize
                    Accessible.ignored: true
                }
                background: Rectangle {
                    radius: Satin.radius.field
                    color: root.alpha(root.foreground, 0.04)
                    border.width: input.activeFocus || root.issueOf(textBox.field.id) !== "" ? 2 : 1
                    border.color: input.activeFocus ? root.accent
                        : root.issueOf(textBox.field.id) !== "" ? root.alpha(root.foreground, 0.9)
                        : root.alpha(root.foreground, Satin.keyline.inner)
                }
            }
            Connections {
                target: textBox
                function onCurrentChanged() {
                    if (!input.activeFocus && root.issueOf(textBox.field.id) === "") input.text = textBox.current;
                }
            }
        }
    }

    // One Tab stop for the whole group. Arrows (and Home/End) move the cursor,
    // Space/Enter select it; the chips themselves are never focus targets.
    Component {
        id: choiceEditor
        Item {
            id: group
            readonly property var host: parent
            readonly property var field: host.field
            readonly property int fieldIndex: host.fieldIndex
            readonly property int selected: Number(root.valueOf(field.id))
            property int cursor: 0
            objectName: "aiFormChoice_" + fieldIndex
            implicitHeight: chips.implicitHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.RadioButton
            Accessible.name: field.label + ": " + (selected >= 0 && selected < field.options.length ? field.options[selected] : "")
            Accessible.description: qsTr("Use the arrow keys to move and Space to choose.")

            function pick(index) {
                if (index < 0 || index >= group.field.options.length || index === group.selected) return;
                root.setValue(group.field.id, index);
            }
            onActiveFocusChanged: { if (group.activeFocus) group.cursor = Math.max(0, group.selected); }
            Keys.onPressed: function(event) {
                var last = group.field.options.length - 1;
                switch (event.key) {
                case Qt.Key_Left:
                case Qt.Key_Up: group.cursor = Math.max(0, group.cursor - 1); break;
                case Qt.Key_Right:
                case Qt.Key_Down: group.cursor = Math.min(last, group.cursor + 1); break;
                case Qt.Key_Home: group.cursor = 0; break;
                case Qt.Key_End: group.cursor = last; break;
                case Qt.Key_Space:
                case Qt.Key_Return:
                case Qt.Key_Enter: group.pick(group.cursor); break;
                default: return;
                }
                event.accepted = true;
            }

            Flow {
                id: chips
                width: group.width
                spacing: Satin.space.base
                Repeater {
                    model: group.field.options
                    delegate: Rectangle {
                        id: chip
                        required property string modelData
                        required property int index
                        objectName: "aiFormChip_" + group.fieldIndex + "_" + index
                        readonly property bool picked: index === group.selected
                        width: Math.min(group.width, Math.ceil(metrics.advanceWidth) + 28)
                        implicitHeight: Math.max(34, label.implicitHeight + 12)
                        height: implicitHeight
                        radius: Satin.radius.chip
                        color: chip.picked ? root.alpha(root.accent, 0.12) : "transparent"
                        border.width: group.activeFocus && index === group.cursor ? 2 : 1
                        border.color: group.activeFocus && index === group.cursor ? root.accent
                            : chip.picked ? root.alpha(root.accent, 0.85) : root.alpha(root.foreground, 0.30)
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData
                        Accessible.checkable: true
                        Accessible.checked: chip.picked
                        Accessible.focusable: false
                        TextMetrics {
                            id: metrics
                            text: "\u25cf " + chip.modelData
                            font.pixelSize: Satin.type.result
                            font.weight: Font.DemiBold
                        }
                        Text {
                            id: label
                            x: 14
                            y: 6
                            width: chip.width - 28
                            text: (chip.picked ? "\u25cf " : "\u25cb ") + chip.modelData
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            color: root.foreground
                            font.pixelSize: Satin.type.result
                            font.weight: chip.picked ? Font.DemiBold : Font.Normal
                        }
                        TapHandler {
                            onTapped: {
                                group.forceActiveFocus(Qt.MouseFocusReason);
                                group.cursor = chip.index;
                                group.pick(chip.index);
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: toggleEditor
        Button {
            id: toggle
            readonly property var host: parent
            readonly property var field: host.field
            readonly property int fieldIndex: host.fieldIndex
            readonly property bool on: root.valueOf(field.id) === 1
            objectName: "aiFormToggle_" + fieldIndex
            padding: Satin.space.base
            implicitHeight: Math.max(Satin.space.row * 3, contentItem.implicitHeight + 2 * padding)
            activeFocusOnTab: true
            hoverEnabled: true
            text: field.label
            Accessible.role: Accessible.CheckBox
            Accessible.name: field.label
            Accessible.checkable: true
            Accessible.checked: toggle.on
            onClicked: root.setValue(field.id, toggle.on ? 0 : 1)
            Keys.onReturnPressed: root.setValue(field.id, toggle.on ? 0 : 1)
            Keys.onEnterPressed: root.setValue(field.id, toggle.on ? 0 : 1)
            contentItem: Row {
                spacing: Satin.space.tip
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Satin.type.search
                    height: width
                    radius: Satin.space.base
                    color: toggle.on ? root.accent : root.background
                    border.width: 1
                    border.color: toggle.on ? root.accent : root.alpha(root.foreground, 0.55)
                    Text {
                        anchors.centerIn: parent
                        visible: toggle.on
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: root.background
                        font.pixelSize: Satin.type.result
                        font.weight: Font.Bold
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, toggle.width - Satin.type.search - Satin.space.tip - 2 * toggle.padding)
                    text: toggle.field.label
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: root.foreground
                    font.pixelSize: Satin.type.name
                    font.weight: Font.DemiBold
                }
            }
            background: Rectangle {
                radius: Satin.radius.chip
                color: toggle.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                border.width: toggle.activeFocus ? 2 : 0
                border.color: root.accent
            }
        }
    }
}
