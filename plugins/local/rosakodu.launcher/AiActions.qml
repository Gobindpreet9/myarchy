pragma ComponentBehavior: Bound

import QtQuick
import "SatinGlass.js" as Satin
import "AiState.js" as AiState

// The follow-up options of an answer (2..6 named options, each with an
// optional one-line hint). A pick is a request to the host, never local state:
// this component emits choiceRequested(index) with the block's ORIGINAL option
// index and reads only `picked`; the service stores `act:<blockIndex>`. Block
// text is model text: PlainText everywhere, cleaned and clamped by
// AiState.vocabText to what choiceWire will actually send (label 40, hint 60).
// AiBlocks already prints the block title as the section heading, so it is not
// repeated here; it only names the group for assistive technology.
//
// States. Open (nothing picked, host gate open): options are buttons. Picked:
// the chosen option shows a check glyph, an accent border and the status line
// "Picked"; the others dim (text stays >= 0.76 alpha) and are inert. Gate
// closed: every option is dimmed and inert and `chooseHint` is the one quiet
// reason line (hidden once something is picked: the status says it). A host
// that silently refuses a pick leaves the options open with a retry message.
//
// Keyboard: the group is ONE Tab stop (roving focus: only the option under the
// cursor is a tab target and it holds real focus, so a screen reader announces
// it). Left/Up and Right/Down move the cursor, Home/End jump, Enter / Space pick
// the cursor option, keys 1..6 pick the nth shown option directly (no Ctrl/Alt/
// Meta), `?` asks about the focused option when the host opens `canFocus`.
// Tab/Shift+Tab/Escape are never consumed, so focus is never trapped. An
// inert group is not a Tab stop at all. The pick is delivered AFTER the key or
// click handler returned (the host appends a turn, which tears this row down),
// and a second activation before it is delivered is dropped.
//
// Motion: state changes are instant (no animation), so reduced motion needs no
// switch. Option text never goes below 0.76 alpha in any state.
Column {
    id: root
    objectName: "aiActions"

    property var block: ({})
    property int blockIndex: 0
    // The index already picked on this block (-1 none); from `act:<blockIndex>`.
    property int picked: -1
    // The host's gate (latest finished answer, idle service) and why not.
    property bool canChoose: false
    property string chooseHint: ""
    required property color foreground
    required property color background
    required property color accent

    // Ask to pick option `index` (AiBlocks adds blockIndex/kind and forwards).
    signal choiceRequested(int index)
    // Ask about one option (the shared `?`-on-the-focused-part convention; no
    // mouse button, an option is already a click target). Inert unless the host
    // opens `canFocus` (its ask gate); with the default false nothing is emitted.
    property bool canFocus: false
    signal focusRequested(int index, string label, string detail)

    spacing: Satin.space.tip

    readonly property int maxOptions: 6
    readonly property real textFloor: 0.76
    readonly property string title: AiState.vocabTitle(root.block)
    // [{index: ORIGINAL option index, label, hint}] of the labelled options, at
    // most maxOptions; the block is untrusted data of any shape.
    readonly property var options: {
        var out = [];
        var plain = AiState.calcPlain(root.block);
        var list = plain && typeof plain === "object" && Array.isArray(plain.options)
            ? plain.options.slice(0, AiState.CHOICE_INDEX_MAX + 1) : [];
        for (var i = 0; i < list.length && out.length < root.maxOptions; ++i) {
            var entry = list[i];
            if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
            var label = AiState.vocabText(entry.label, AiState.CHOICE_LABEL_MAX);
            if (label === "") continue;
            out.push({index: i, label: label, hint: AiState.vocabText(entry.hint, 60)});
        }
        return out;
    }
    readonly property bool usable: root.options.length > 0
    readonly property bool interactive: root.usable && root.picked < 0 && root.canChoose
    readonly property int delegateCount: optionRepeater.count
    // Position (among the shown options) of the keyboard cursor.
    property int cursor: 0
    property bool delivering: false
    property bool sendFailed: false

    readonly property string invalidText: qsTr("These options can't be shown.")
    readonly property string failedText: qsTr("Couldn't send this choice. Try again in a moment.")
    readonly property string closedText: qsTr("Choosing is not available right now.")
    readonly property string hintText: {
        if (!root.usable || root.picked >= 0) return "";
        if (root.sendFailed && root.canChoose) return root.failedText;
        if (root.canChoose) return "";
        return root.chooseHint !== "" ? root.chooseHint : root.closedText;
    }

    Accessible.role: Accessible.Grouping
    Accessible.name: root.title !== "" ? root.title : qsTr("Follow-up options")
    Accessible.description: root.interactive
        ? qsTr("Use the arrow keys to move, Enter to choose, or the number keys 1 to %1.").arg(root.options.length)
        : root.hintText

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }

    function positionOfIndex(index) {
        for (var i = 0; i < root.options.length; ++i)
            if (root.options[i].index === index) return i;
        return -1;
    }
    function optionItem(position) {
        return position >= 0 && position < optionRepeater.count ? optionRepeater.itemAt(position) : null;
    }
    // Move the cursor AND real focus (the focused option is the one announced).
    function moveTo(position, reason) {
        if (root.options.length === 0) return;
        var target = Math.max(0, Math.min(root.options.length - 1, position));
        var item = root.optionItem(target);
        if (item) item.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason);
        root.cursor = target;
    }
    function holdsFocus() {
        for (var i = 0; i < optionRepeater.count; ++i) {
            var item = optionRepeater.itemAt(i);
            if (item && item.activeFocus) return true;
        }
        return false;
    }
    // Returns whether a pick was queued. Delivery happens after the handler
    // that asked for it has returned (never rebuild from the pressed item).
    function requestChoice(position) {
        if (!root.interactive || root.delivering) return false;
        if (position < 0 || position >= root.options.length) return false;
        root.delivering = true;
        root.sendFailed = false;
        // Focus follows a direct pick, so the focus holder is always the cursor.
        if (root.holdsFocus()) root.moveTo(position, Qt.OtherFocusReason);
        root.cursor = position;
        Qt.callLater(root.deliver, root.options[position].index);
        return true;
    }
    function deliver(index) {
        root.delivering = false;
        if (!root.interactive) return;
        root.choiceRequested(index);
        // The service answers synchronously: an accepted pick marks the block
        // picked and closes the gate (busy); anything else was refused.
        if (root.picked < 0 && root.canChoose) root.sendFailed = true;
    }
    // Returns true when the key was handled.
    function handleKey(position, event) {
        var mods = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        if (mods !== 0) return false;
        if (event.key === Qt.Key_Question || event.text === "?") {
            if (!root.canFocus || position < 0 || position >= root.options.length) return false;
            var option = root.options[position];
            if (!event.isAutoRepeat) root.focusRequested(option.index, option.label, option.hint);
            return true;
        }
        if (!root.interactive) return false;
        var last = root.options.length - 1;
        switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_Up: root.moveTo(position - 1); return true;
        case Qt.Key_Right:
        case Qt.Key_Down: root.moveTo(position + 1); return true;
        case Qt.Key_Home: root.moveTo(0); return true;
        case Qt.Key_End: root.moveTo(last); return true;
        case Qt.Key_Space:
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (!event.isAutoRepeat) root.requestChoice(position);
            return true;
        default:
            break;
        }
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_1 + root.maxOptions - 1) {
            var nth = event.key - Qt.Key_1;
            if (nth > last) return false;
            if (!event.isAutoRepeat) root.requestChoice(nth);
            return true;
        }
        return false;
    }

    onOptionsChanged: {
        root.cursor = Math.max(0, Math.min(root.options.length - 1, root.cursor));
        root.sendFailed = false;
    }
    onPickedChanged: {
        root.sendFailed = false;
        var at = root.positionOfIndex(root.picked);
        // The focus holder always stays the cursor (one Tab stop).
        if (at >= 0 && !root.holdsFocus()) root.cursor = at;
    }
    onCanChooseChanged: root.sendFailed = false

    Text {
        objectName: "aiActionsInvalid"
        width: root.width
        visible: !root.usable
        text: root.invalidText
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: root.alpha(root.foreground, 0.80)
        font.pixelSize: Satin.type.meta
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    Flow {
        id: flow
        objectName: "aiActionsOptions"
        width: root.width
        visible: root.usable
        spacing: Satin.space.tip

        Repeater {
            id: optionRepeater
            model: root.options
            delegate: Rectangle {
                id: chip
                required property var modelData
                required property int index
                objectName: "aiActionsOption_" + index
                readonly property string label: chip.modelData.label
                readonly property string hint: chip.modelData.hint
                readonly property bool isPicked: root.picked >= 0 && chip.modelData.index === root.picked
                readonly property bool dimmed: !root.interactive && !chip.isPicked
                readonly property bool isCursor: chip.index === root.cursor
                readonly property real padX: 12
                readonly property real padY: 8
                readonly property real markerWidth: 16
                readonly property real textX: chip.padX + chip.markerWidth + Satin.space.tip
                readonly property real labelAlpha: chip.dimmed ? root.textFloor : 1.0
                readonly property real hintAlpha: chip.dimmed ? root.textFloor : 0.80

                width: Math.min(flow.width, Math.max(96, Math.ceil(Math.max(labelMetrics.advanceWidth, hintMetrics.advanceWidth))
                    + chip.textX + chip.padX))
                implicitHeight: Math.max(36, textColumn.implicitHeight + 2 * chip.padY)
                height: chip.implicitHeight
                radius: Satin.radius.chip
                color: chip.isPicked ? root.alpha(root.accent, 0.12)
                    : chip.activeFocus && !chip.dimmed ? root.alpha(root.accent, 0.08)
                    : tap.pressed && root.interactive ? root.alpha(root.accent, 0.20)
                    : hover.hovered && root.interactive ? root.alpha(root.foreground, 0.045) : "transparent"
                border.width: chip.activeFocus ? 2 : 1
                border.color: chip.activeFocus ? root.accent
                    : chip.isPicked ? root.alpha(root.accent, 0.85)
                    : root.alpha(root.foreground, chip.dimmed ? 0.14 : 0.30)

                // Roving focus: exactly one option (the cursor) is a Tab stop. Qt
                // refuses (and warns) to clear activeFocusOnTab on the item that
                // holds focus, so the holder stays a stop until focus moves on.
                activeFocusOnTab: (root.interactive && chip.isCursor) || chip.activeFocus
                Accessible.role: Accessible.Button
                Accessible.name: chip.hint !== "" ? chip.label + ", " + chip.hint : chip.label
                Accessible.description: chip.isPicked ? qsTr("Picked") : ""
                Accessible.focusable: root.interactive
                Accessible.checkable: true
                Accessible.checked: chip.isPicked
                Accessible.onPressAction: root.requestChoice(chip.index)

                Keys.onPressed: function(event) {
                    if (root.handleKey(chip.index, event)) event.accepted = true;
                }
                onActiveFocusChanged: {
                    if (chip.activeFocus) root.cursor = chip.index;
                }

                TextMetrics {
                    id: labelMetrics
                    text: chip.label
                    font.pixelSize: Satin.type.name
                    font.weight: Font.DemiBold
                }
                TextMetrics {
                    id: hintMetrics
                    text: chip.hint
                    font.pixelSize: Satin.type.meta
                }
                Text {
                    objectName: "aiActionsMarker_" + chip.index
                    x: chip.padX
                    y: chip.padY
                    width: chip.markerWidth
                    horizontalAlignment: Text.AlignHCenter
                    // A number teaches the 1..6 keys; the picked one shows a check.
                    text: chip.isPicked ? "\u2713" : String(chip.index + 1)
                    textFormat: Text.PlainText
                    color: chip.isPicked ? root.accent : root.alpha(root.foreground, chip.dimmed ? root.textFloor : 0.80)
                    font.pixelSize: chip.isPicked ? Satin.type.name : Satin.type.meta
                    font.weight: chip.isPicked ? Font.Bold : Font.Normal
                    Accessible.ignored: true
                }
                Column {
                    id: textColumn
                    x: chip.textX
                    y: chip.padY
                    width: chip.width - chip.textX - chip.padX
                    spacing: 2
                    Text {
                        objectName: "aiActionsLabel_" + chip.index
                        width: parent.width
                        text: chip.label
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: root.alpha(root.foreground, chip.labelAlpha)
                        font.pixelSize: Satin.type.name
                        font.weight: Font.DemiBold
                        Accessible.ignored: true
                    }
                    Text {
                        objectName: "aiActionsHint_" + chip.index
                        width: parent.width
                        visible: chip.hint !== ""
                        text: chip.hint
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: root.alpha(root.foreground, chip.hintAlpha)
                        font.pixelSize: Satin.type.meta
                        Accessible.ignored: true
                    }
                    // The word, not just the colour or glyph, says what happened.
                    Text {
                        objectName: "aiActionsStatus_" + chip.index
                        width: parent.width
                        visible: chip.isPicked
                        text: qsTr("Picked")
                        textFormat: Text.PlainText
                        color: root.alpha(root.foreground, 0.90)
                        font.pixelSize: Satin.type.meta
                        font.weight: Font.DemiBold
                        Accessible.ignored: true
                    }
                }
                HoverHandler {
                    id: hover
                    cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
                TapHandler {
                    id: tap
                    onTapped: {
                        if (!root.interactive) return;
                        chip.forceActiveFocus(Qt.MouseFocusReason);
                        root.requestChoice(chip.index);
                    }
                }
            }
        }
    }

    Text {
        objectName: "aiActionsHint"
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
}
