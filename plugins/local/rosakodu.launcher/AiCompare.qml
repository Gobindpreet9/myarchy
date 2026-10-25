pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "SatinGlass.js" as Satin
import "AiState.js" as AiState
import "AiCompareView.js" as View

// A model-authored comparison of 2-4 options (the `compare` block). Width picks
// the composition: enough room per VISIBLE option gives a side-by-side matrix
// (one column per option: header, fact rows unioned across options, pros, cons), else
// a compact shortlist and ONE inspected option's detail card. Nothing is scored or
// sorted; the person may PIN one option first and HIDE options they have ruled
// out (a hidden option collapses to a one-line stub with Show; the last visible
// option can never be hidden). Choosing is a follow-up the HOST sends:
// `choiceRequested(index)` carries the raw option index, gated by `canChoose`.
//
// State. `compare:<blockIndex>` = {pin: index|-1, hide: [index...]} (see
// AiCompareView.js): tiny, closed, sanitised on every read, so stale indices
// (no such option any more) and "everything hidden" simply never show. Like the
// calc block the component displays its own last edit until `saved` changes, so
// a host that refuses an emit cannot leave the controls looking dead.
//
// Keyboard. ONE Tab stop for the whole block. Left/Right/Home/End move the
// cursor between options (the ring), Enter/Space chooses the option under it
// (on a hidden stub: shows it), P pins/unpins, H hides/shows, ? asks about it
// (when the host opens `canFocus`; a hidden stub asks about its own option).
// The Pin/Hide/Continue buttons and shortlist names are mouse and assistive-technology targets
// only, so the block never adds more than one stop. Up/Down are left alone so
// they keep scrolling the pane.
//
// Interface (AiBlocks owns the wiring):
//   block, blockIndex, picked (-1 none), canChoose, chooseHint, saved,
//   foreground/background/accent; signals choiceRequested(index),
//   focusRequested(index, label, detail), stateEdited(state).
Item {
    id: root
    objectName: "aiCompare"

    property var block: ({})
    property int blockIndex: 0
    // The index already picked on this block (-1 none); from `act:<blockIndex>`.
    property int picked: -1
    // The host's gate (latest finished answer, idle service) and why not.
    property bool canChoose: false
    property string chooseHint: ""
    // The persisted `compare:<blockIndex>` entry (undefined when untouched).
    property var saved: undefined
    required property color foreground
    required property color background
    required property color accent

    // Ask to pick option `index` (AiBlocks adds blockIndex/kind and forwards).
    signal choiceRequested(int index)
    // Ask about one option (`?` on the cursor option, the shared convention;
    // no visible control). Emitted only while the host opens `canFocus`.
    property bool canFocus: false
    signal focusRequested(int index, string label, string detail)
    // The complete next `compare:<blockIndex>` object (local view state).
    signal stateEdited(var state)

    readonly property var parsed: View.model(root.block)
    readonly property var options: root.parsed.options
    readonly property var indices: root.options.map(function (option) { return option.index; })
    readonly property bool usable: root.options.length > 0
    // The person's last edit, displayed until the host's `saved` changes.
    property var local: null
    readonly property var view: View.sanitizeState(root.local !== null ? root.local : root.saved, root.indices)
    readonly property var arranged: View.arrange(root.options, root.view)
    readonly property var shown: root.arranged.visible
    readonly property var stubs: root.arranged.hidden
    readonly property var order: root.shown.concat(root.stubs)
    readonly property bool matrix: View.composition(root.width, root.shown.length) === "matrix"
    readonly property var rows: View.factRows(root.shown)
    readonly property var pointRows: [
        {field: "pros", title: qsTr("Pros"), glyph: "+", spoken: qsTr("Pro")},
        {field: "cons", title: qsTr("Cons"), glyph: "-", spoken: qsTr("Con")}
    ].filter(function (row) {
        return root.shown.some(function (option) { return option[row.field].length > 0; });
    })
    readonly property bool lastVisible: root.shown.length <= 1

    // The option under the keyboard cursor (a raw option index; -1 = the first).
    property int cursor: -1
    readonly property int cursorPos: {
        for (var i = 0; i < root.order.length; ++i) {
            if (root.order[i].index === root.cursor) return i;
        }
        return 0;
    }
    readonly property var cursorOption: root.order[root.cursorPos] || null
    readonly property bool cursorHidden: root.cursorOption !== null && root.cursorPos >= root.shown.length
    // Inspection is ephemeral (the same raw-index keyboard cursor), never saved.
    // A hidden cursor stays on its stub; the first visible option supplies detail.
    readonly property int inspectedPos: root.cursorHidden ? 0 : root.cursorPos
    readonly property var inspectedOption: root.shown[root.inspectedPos] || null

    // Matrix geometry: the width decides the columns, the text decides the height.
    readonly property int gap: Satin.space.gutter
    // Room for the cursor ring (it is drawn 4 px outside its column).
    readonly property int inset: Satin.space.base
    readonly property int available: Math.max(0, root.width - 2 * root.inset)
    readonly property bool hasLabels: root.rows.length > 0 || root.pointRows.length > 0
    readonly property int labelWidth: root.hasLabels ? 96 : 0
    readonly property int columnWidth: root.shown.length === 0 ? 0 : Math.max(0, Math.floor(
        (root.available - root.labelWidth - (root.labelWidth > 0 ? root.gap : 0) - (root.shown.length - 1) * root.gap)
        / root.shown.length))

    implicitHeight: content.implicitHeight
    height: implicitHeight
    activeFocusOnTab: root.usable
    Accessible.role: Accessible.Grouping
    Accessible.focusable: true
    Accessible.name: root.cursorOption
        ? qsTr("Comparison of %1 options. %2").arg(root.options.length).arg(View.optionName(root.cursorOption, root.picked,
            root.view.pin === root.cursorOption.index) + (root.cursorHidden ? ", hidden" : ""))
        : qsTr("Comparison")
    Accessible.description: qsTr("Left and Right move between options. Enter sends an AI follow-up, or shows a hidden option. P pins. H hides or shows; one option always stays visible. Question mark asks AI about the option when available.")

    onSavedChanged: root.local = null
    onBlockChanged: root.local = null
    onMatrixChanged: { if (root.activeFocus) Qt.callLater(root.revealCursor); }

    // Delegates can outlive a model change for a moment: never index blindly.
    function nameAt(position) { return position >= 0 && position < root.shown.length ? root.shown[position].name : ""; }
    function commit(next) {
        if (!next || View.stateBytes(next) > View.MAX_STATE_BYTES) return;
        root.local = next;
        root.stateEdited(next);
        if (root.activeFocus) Qt.callLater(root.revealCursor);
    }
    function togglePin(index) { root.commit(View.togglePin(root.view, index, root.indices)); }
    function toggleHide(index) { root.commit(View.toggleHide(root.view, index, root.indices)); }
    function choose(index) { if (root.canChoose) root.choiceRequested(index); }
    // A mouse press anywhere on an option parks the cursor (and the one Tab stop) on it.
    function touch(option) {
        if (!option) return;
        root.cursor = option.index;
        root.forceActiveFocus(Qt.MouseFocusReason);
    }
    function moveCursor(position) {
        if (root.order.length === 0) return;
        root.cursor = root.order[Math.max(0, Math.min(root.order.length - 1, position))].index;
        Qt.callLater(root.revealCursor);
    }
    // The pane scrolls a newly focused item into view, but the cursor moves
    // inside one focus item: keep the card under it visible ourselves.
    function revealCursor() {
        var at = root.cursorPos;
        var item = at < root.shown.length ? (root.matrix ? matrixBox : cards.itemAt(0))
            : stubRepeater.itemAt(at - root.shown.length);
        View.reveal(item, root.parent);
    }

    Keys.onPressed: function (event) {
        if (!root.usable || !root.cursorOption || (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return;
        var option = root.cursorOption;
        if (event.key === Qt.Key_Question || event.text === "?") {
            if (!root.canFocus) return;
            var ask = View.askAbout(option);
            if (ask && !event.isAutoRepeat) root.focusRequested(ask.index, ask.label, ask.detail);
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Left: root.moveCursor(root.cursorPos - 1); break;
        case Qt.Key_Right: root.moveCursor(root.cursorPos + 1); break;
        case Qt.Key_Home: root.moveCursor(0); break;
        case Qt.Key_End: root.moveCursor(root.order.length - 1); break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (!event.isAutoRepeat) {
                if (root.cursorHidden) root.toggleHide(option.index);
                else root.choose(option.index);
            }
            break;
        case Qt.Key_P:
            if (!event.isAutoRepeat && !root.cursorHidden) root.togglePin(option.index);
            break;
        case Qt.Key_H:
            if (!event.isAutoRepeat) root.toggleHide(option.index);
            break;
        default: return;
        }
        event.accepted = true;
    }

    // ---- building blocks (inline components do not see the file's ids) ------
    component Chip: Rectangle {
        id: chip
        required property color ink
        required property color ring
        property string label: ""
        // Spoken name when it differs from the visible label.
        property string spoken: ""
        property string hint: ""
        property bool primary: false
        property bool quiet: false
        property bool canAct: true
        property int size: Satin.type.small
        property int weight: Font.Medium
        signal activated()
        // Full-width primaries do not size their parent from their adaptive
        // label (that would feed width -> label -> implicitWidth back on itself).
        implicitWidth: chip.primary ? 0 : Math.ceil(metrics.advanceWidth) + 20
        implicitHeight: caption.implicitHeight + 14
        radius: Satin.radius.chip
        enabled: chip.canAct
        color: chip.canAct && hover.hovered ? AiState.alpha(chip.ring, 0.22)
            : chip.canAct && chip.primary ? AiState.alpha(chip.ring, 0.12) : "transparent"
        border.width: 1
        border.color: !chip.canAct ? AiState.alpha(chip.ink, 0.30)
            : chip.primary ? chip.ring : chip.quiet && !hover.hovered ? "transparent" : AiState.alpha(chip.ink, 0.55)
        Accessible.role: Accessible.Button
        Accessible.name: chip.spoken !== "" ? chip.spoken : chip.label
        Accessible.description: chip.hint
        Accessible.onPressAction: { if (chip.canAct) chip.activated(); }
        TextMetrics {
            id: metrics
            text: chip.label
            font.pixelSize: chip.size
            font.weight: chip.weight
        }
        Text {
            id: caption
            x: 10
            y: 7
            width: chip.width - 20
            text: chip.label
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            horizontalAlignment: Text.AlignHCenter
            color: AiState.alpha(chip.ink, chip.canAct ? 1 : 0.76)
            font.pixelSize: chip.size
            font.weight: chip.weight
            Accessible.ignored: true
        }
        HoverHandler { id: hover }
        TapHandler { onTapped: chip.activated() }
    }

    // The decision content leads. Actions are separate, AFTER all evidence.
    component OptionHead: Item {
        id: head
        required property var option
        required property bool chosen
        required property bool pinned
        required property bool grouped
        required property color ink
        required property color ring
        // A matrix row gives every header the height of the tallest one.
        property real minHeight: 0
        implicitHeight: headCopy.implicitHeight
        height: Math.max(head.implicitHeight, head.minHeight)
        Accessible.role: Accessible.Grouping
        Accessible.ignored: !head.grouped
        Accessible.name: View.optionName(head.option, head.chosen ? head.option.index : -1, head.pinned)
        Accessible.description: head.option.summary
            + (head.option.recommended ? " " + qsTr("Recommendation from the AI answer, not an independent assessment.") : "")

        Column {
            id: headCopy
            width: head.width
            spacing: Satin.space.base
            Text {
                objectName: "aiCompareName"
                width: head.width
                text: head.option.name
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: head.ink
                font.pixelSize: head.grouped ? Satin.type.subtitle : Satin.type.prompt
                font.weight: Font.DemiBold
                Accessible.ignored: true
            }
            Text {
                objectName: "aiCompareSummary"
                width: head.width
                visible: text.length > 0
                text: head.option.summary
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: AiState.alpha(head.ink, 0.86)
                font.pixelSize: Satin.type.body
                Accessible.ignored: true
            }
            Flow {
                width: head.width
                visible: head.option.recommended || head.chosen || head.pinned
                spacing: Satin.space.tip
                Row {
                    visible: head.option.recommended
                    spacing: Satin.space.base
                    Text {
                        text: "\u2605"
                        textFormat: Text.PlainText
                        color: head.ring
                        font.pixelSize: Satin.type.small
                        Accessible.ignored: true
                    }
                    Text {
                        objectName: "aiCompareRecommended"
                        text: qsTr("Recommended")
                        textFormat: Text.PlainText
                        color: head.ink
                        font.pixelSize: Satin.type.small
                        font.weight: Font.DemiBold
                        Accessible.ignored: true
                    }
                }
                Row {
                    visible: head.chosen
                    spacing: Satin.space.base
                    Text {
                        text: "\u2713"
                        textFormat: Text.PlainText
                        color: head.ring
                        font.pixelSize: Satin.type.small
                        font.weight: Font.Bold
                        Accessible.ignored: true
                    }
                    Text {
                        objectName: "aiCompareChosen"
                        text: qsTr("Chosen")
                        textFormat: Text.PlainText
                        color: head.ink
                        font.pixelSize: Satin.type.small
                        font.weight: Font.DemiBold
                        Accessible.ignored: true
                    }
                }
                Row {
                    visible: head.pinned
                    spacing: Satin.space.base
                    Text {
                        text: "\u25cf"
                        textFormat: Text.PlainText
                        color: head.ring
                        font.pixelSize: Satin.type.small
                        Accessible.ignored: true
                    }
                    Text {
                        objectName: "aiComparePinned"
                        text: qsTr("Pinned")
                        textFormat: Text.PlainText
                        color: head.ink
                        font.pixelSize: Satin.type.small
                        font.weight: Font.DemiBold
                        Accessible.ignored: true
                    }
                }
            }
        }
    }

    component OptionActions: Column {
            id: actions
            required property var option
            required property bool pinned
            required property bool canChoose
            required property bool canHide
            required property string chooseHint
            required property color ink
            required property color ring
            signal chooseClicked()
            signal pinClicked()
            signal hideClicked()
            spacing: Satin.space.base
            TextMetrics {
                id: continueMetrics
                text: qsTr("Continue with %1").arg(actions.option.name)
                font.pixelSize: Satin.type.body
                font.weight: Font.DemiBold
            }
            Chip {
                objectName: "aiCompareChoose"
                width: actions.width
                ink: actions.ink
                ring: actions.ring
                label: continueMetrics.advanceWidth <= actions.width - 20 ? continueMetrics.text : qsTr("Continue")
                spoken: qsTr("Continue with %1").arg(actions.option.name)
                hint: qsTr("Sends an AI follow-up about %1.").arg(actions.option.name)
                    + (actions.canChoose || actions.chooseHint === "" ? "" : " " + actions.chooseHint)
                primary: true
                canAct: actions.canChoose
                size: Satin.type.body
                weight: Font.DemiBold
                onActivated: actions.chooseClicked()
            }
            Text {
                objectName: "aiCompareFollowupHint"
                width: actions.width
                text: qsTr("Sends an AI follow-up.")
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: AiState.alpha(actions.ink, 0.80)
                font.pixelSize: Satin.type.small
            }
            Flow {
                width: actions.width
                spacing: Satin.space.base
                Chip {
                    objectName: "aiComparePin"
                    width: Math.min(implicitWidth, actions.width)
                    ink: actions.ink
                    ring: actions.ring
                    quiet: true
                    label: actions.pinned ? qsTr("Unpin") : qsTr("Pin")
                    spoken: (actions.pinned ? qsTr("Unpin %1") : qsTr("Pin %1")).arg(actions.option.name)
                    hint: qsTr("Moves this option first in this comparison only.")
                    onActivated: actions.pinClicked()
                }
                Chip {
                    objectName: "aiCompareHide"
                    width: Math.min(implicitWidth, actions.width)
                    ink: actions.ink
                    ring: actions.ring
                    quiet: true
                    label: qsTr("Hide")
                    spoken: qsTr("Hide %1").arg(actions.option.name)
                    hint: actions.canHide ? qsTr("Hides this option locally. Show restores it.") : qsTr("At least one option stays visible.")
                    canAct: actions.canHide
                    onActivated: actions.hideClicked()
                }
            }
    }

    // One "label  value" pair (stacked cards).
    component FactLine: Row {
        id: line
        objectName: "aiCompareFactLine"
        required property string label
        required property string value
        required property color ink
        spacing: Satin.space.tip
        Accessible.role: Accessible.StaticText
        Accessible.name: line.label + ": " + line.value
        readonly property real labelWidth: Math.min(Math.round(line.width * 0.42), 160)
        Text {
            width: line.labelWidth
            text: line.label
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: AiState.alpha(line.ink, 0.80)
            font.pixelSize: Satin.type.body
            Accessible.ignored: true
        }
        Text {
            width: line.width - line.labelWidth - line.spacing
            text: line.value
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: AiState.alpha(line.ink, 0.95)
            font.pixelSize: Satin.type.body
            Accessible.ignored: true
        }
    }

    // A '+' or '-' point of an option.
    component Point: Row {
        id: point
        required property string glyph
        required property string text
        required property string spokenKind
        required property color ink
        objectName: "aiComparePoint"
        spacing: Satin.space.base
        Accessible.role: Accessible.StaticText
        Accessible.name: point.spokenKind + ": " + point.text
        Text {
            width: 12
            text: point.glyph
            textFormat: Text.PlainText
            color: point.ink
            font.pixelSize: Satin.type.body
            font.weight: Font.Bold
            Accessible.ignored: true
        }
        Text {
            width: point.width - 12 - point.spacing
            text: point.text
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: AiState.alpha(point.ink, 0.95)
            font.pixelSize: Satin.type.body
            Accessible.ignored: true
        }
    }

    // A matrix cell: a hairline above, padding, then `contentItem`-like children.
    component Cell: Item {
        id: cell
        default property alias body: inner.data
        property real pad: Satin.space.tip
        height: inner.implicitHeight + 2 * cell.pad
        Rectangle {
            width: parent.width
            height: 1
            color: AiState.alpha(root.foreground, 0.22)
        }
        Column {
            id: inner
            x: Satin.space.base
            y: cell.pad
            width: cell.width - 2 * Satin.space.base
        }
    }

    Column {
        id: content
        width: root.width
        spacing: Satin.space.tip

        Text {
            objectName: "aiCompareInvalid"
            width: content.width
            visible: !root.usable
            text: qsTr("This comparison can't be shown.")
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: AiState.alpha(root.foreground, 0.80)
            font.pixelSize: Satin.type.meta
            Accessible.name: text
        }

        // An authored recommendation, not a computed score or verified fact.
        Item {
            id: recommendation
            objectName: "aiCompareRecommendation"
            width: content.width
            height: verdictBody.implicitHeight + 2 * Satin.space.gutter
            visible: root.usable && root.parsed.verdict.length > 0
            Rectangle {
                width: 2
                height: parent.height
                color: root.accent
            }
            Column {
                id: verdictBody
                x: Satin.space.gutter
                y: Satin.space.gutter
                width: parent.width - 2 * Satin.space.gutter
                spacing: Satin.space.base
                Text {
                    objectName: "aiCompareRecommendationLabel"
                    text: root.stubs.length > 0 ? qsTr("Original AI recommendation") : qsTr("AI recommendation")
                    textFormat: Text.PlainText
                    color: AiState.alpha(root.foreground, 0.80)
                    font.pixelSize: Satin.type.small
                    font.weight: Font.DemiBold
                }
                Text {
                    objectName: "aiCompareVerdict"
                    width: parent.width
                    text: root.parsed.verdict
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: root.foreground
                    font.pixelSize: Satin.type.body
                    Accessible.role: Accessible.StaticText
                    Accessible.name: (root.stubs.length > 0 ? qsTr("Original AI recommendation: %1") : qsTr("AI recommendation: %1")).arg(text)
                }
            }
        }

        // Reserve two lines even while unfocused: entering the single Tab stop
        // reveals its controls without moving any evidence or action below it.
        Item {
            objectName: "aiCompareKeyboardHelpSpace"
            width: content.width
            height: helpMetrics.height * 2
            visible: root.usable
            FontMetrics { id: helpMetrics; font.pixelSize: Satin.type.small }
            Text {
                objectName: "aiCompareKeyboardHelp"
                x: root.inset
                width: root.available
                visible: root.activeFocus
                text: (root.cursorHidden ? qsTr("\u2190/\u2192 options \u00b7 H show") : qsTr("\u2190/\u2192 options \u00b7 P pin \u00b7 H hide"))
                    + "\n" + (root.cursorHidden ? qsTr("Enter show option")
                        : root.canChoose ? qsTr("Enter AI follow-up") : qsTr("AI follow-up unavailable"))
                    + (root.canFocus ? qsTr(" \u00b7 ? ask AI") : "")
                textFormat: Text.PlainText
                color: AiState.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // ---- side by side ---------------------------------------------------
        Item {
            id: matrixBox
            objectName: "aiCompareMatrix"
            width: content.width
            height: grid.height
            visible: root.usable && root.matrix

            Column {
                id: grid
                x: root.inset
                width: root.available
                spacing: 0

                // One layout row: every header is as tall as the tallest.
                RowLayout {
                    width: grid.width
                    spacing: root.gap
                    Item {
                        visible: root.labelWidth > 0
                        Layout.preferredWidth: root.labelWidth
                        Layout.preferredHeight: 1
                    }
                    Repeater {
                        model: matrixBox.visible ? root.shown : []
                        delegate: Item {
                            id: column
                            required property var modelData
                            required property int index
                            objectName: "aiCompareColumn_" + column.index
                            Layout.preferredWidth: root.columnWidth
                            Layout.minimumWidth: root.columnWidth
                            Layout.maximumWidth: root.columnWidth
                            Layout.fillHeight: true
                            implicitHeight: head.implicitHeight + Satin.space.base
                            OptionHead {
                                id: head
                                x: Satin.space.base
                                width: parent.width - 2 * Satin.space.base
                                minHeight: column.height - Satin.space.base
                                option: column.modelData
                                chosen: column.modelData.index === root.picked
                                pinned: column.modelData.index === root.view.pin
                                grouped: true
                                ink: root.foreground
                                ring: root.accent
                            }
                            TapHandler { onTapped: root.touch(column.modelData) }
                        }
                    }
                }

                Repeater {
                    model: matrixBox.visible ? root.rows : []
                    delegate: Row {
                        id: factRow
                        required property var modelData
                        spacing: root.gap
                        Cell {
                            width: root.labelWidth
                            Text {
                                width: parent.width
                                text: factRow.modelData.label
                                textFormat: Text.PlainText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: AiState.alpha(root.foreground, 0.80)
                                font.pixelSize: Satin.type.meta
                                Accessible.ignored: true
                            }
                        }
                        Repeater {
                            model: factRow.modelData.values
                            delegate: Cell {
                                id: valueCell
                                required property var modelData
                                required property int index
                                readonly property bool stated: valueCell.modelData !== null
                                objectName: "aiCompareFact_" + valueCell.index
                                width: root.columnWidth
                                Accessible.role: Accessible.StaticText
                                Accessible.name: factRow.modelData.label + ": " + (valueCell.stated ? valueCell.modelData : qsTr("not stated"))
                                    + " (" + root.nameAt(valueCell.index) + ")"
                                Text {
                                    width: parent.width
                                    text: valueCell.stated && valueCell.modelData !== "" ? valueCell.modelData : View.DASH
                                    textFormat: Text.PlainText
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    color: AiState.alpha(root.foreground, valueCell.stated ? 0.95 : 0.76)
                                    font.pixelSize: Satin.type.body
                                    Accessible.ignored: true
                                }
                                TapHandler { onTapped: root.touch(root.shown[valueCell.index]) }
                            }
                        }
                    }
                }

                // Pros then Cons: one row each, a '+' or '-' glyph per point.
                Repeater {
                    model: matrixBox.visible ? root.pointRows : []
                    delegate: Row {
                        id: pointRow
                        required property var modelData
                        spacing: root.gap
                        Cell {
                            width: root.labelWidth
                            Text {
                                width: parent.width
                                text: pointRow.modelData.title
                                textFormat: Text.PlainText
                                color: AiState.alpha(root.foreground, 0.80)
                                font.pixelSize: Satin.type.meta
                                Accessible.ignored: true
                            }
                        }
                        Repeater {
                            model: root.shown
                            delegate: Cell {
                                id: pointCell
                                required property var modelData
                                readonly property var points: pointCell.modelData[pointRow.modelData.field]
                                objectName: "aiComparePointsCell_" + pointRow.modelData.field
                                width: root.columnWidth
                                Text {
                                    width: parent.width
                                    visible: pointCell.points.length === 0
                                    text: View.DASH
                                    textFormat: Text.PlainText
                                    color: AiState.alpha(root.foreground, 0.76)
                                    font.pixelSize: Satin.type.body
                                    Accessible.name: qsTr("None stated (%1)").arg(pointCell.modelData.name)
                                }
                                Repeater {
                                    model: pointCell.points
                                    delegate: Point {
                                        required property string modelData
                                        width: pointCell.width - 2 * Satin.space.base
                                        glyph: pointRow.modelData.glyph
                                        text: modelData
                                        spokenKind: pointRow.modelData.spoken
                                        ink: root.foreground
                                    }
                                }
                                TapHandler { onTapped: root.touch(pointCell.modelData) }
                            }
                        }
                    }
                }

                // Only after aligned facts, pros and cons do actions enter the
                // reading order. Footer columns retain the header's geometry.
                RowLayout {
                    objectName: "aiCompareMatrixActions"
                    width: grid.width
                    spacing: root.gap
                    Item {
                        visible: root.labelWidth > 0
                        Layout.preferredWidth: root.labelWidth
                        Layout.preferredHeight: 1
                    }
                    Repeater {
                        model: matrixBox.visible ? root.shown : []
                        delegate: Item {
                            id: footer
                            required property var modelData
                            required property int index
                            objectName: "aiCompareActions_" + footer.index
                            Layout.preferredWidth: root.columnWidth
                            Layout.minimumWidth: root.columnWidth
                            Layout.maximumWidth: root.columnWidth
                            Layout.fillHeight: true
                            implicitHeight: footerActions.implicitHeight + Satin.space.gutter
                            OptionActions {
                                id: footerActions
                                x: Satin.space.base
                                y: Satin.space.gutter
                                width: footer.width - 2 * Satin.space.base
                                option: footer.modelData
                                pinned: footer.modelData.index === root.view.pin
                                canChoose: root.canChoose
                                canHide: !root.lastVisible
                                chooseHint: root.chooseHint
                                ink: root.foreground
                                ring: root.accent
                                onChooseClicked: { root.touch(footer.modelData); root.choose(footer.modelData.index); }
                                onPinClicked: { root.touch(footer.modelData); Qt.callLater(root.togglePin, footer.modelData.index); }
                                onHideClicked: { root.touch(footer.modelData); Qt.callLater(root.toggleHide, footer.modelData.index); }
                            }
                        }
                    }
                }
            }

            // The keyboard cursor on a column.
            Rectangle {
                objectName: "aiCompareRing"
                visible: root.activeFocus && root.matrix && !root.cursorHidden && root.cursorOption !== null
                x: root.inset + (root.labelWidth > 0 ? root.labelWidth + root.gap : 0)
                    + root.cursorPos * (root.columnWidth + root.gap) - 4
                y: -4
                width: root.columnWidth + 8
                height: matrixBox.height + 8
                radius: Satin.radius.chip
                color: "transparent"
                border.width: 2
                border.color: root.accent
            }
        }

        // ---- stacked --------------------------------------------------------
        Column {
            id: cardColumn
            objectName: "aiCompareCards"
            width: content.width
            spacing: Satin.space.tip
            visible: root.usable && !root.matrix

            Text {
                objectName: "aiCompareShortlistLabel"
                width: parent.width
                text: qsTr("Options \u00b7 select a name to inspect locally")
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: AiState.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.small
            }
            Column {
                objectName: "aiCompareShortlist"
                width: parent.width
                spacing: Satin.space.base
                Repeater {
                    model: cardColumn.visible ? root.shown : []
                    delegate: Rectangle {
                        id: candidate
                        required property var modelData
                        required property int index
                        readonly property bool inspecting: root.inspectedOption !== null
                            && root.inspectedOption.index === candidate.modelData.index
                        objectName: "aiCompareCandidate_" + candidate.index
                        width: cardColumn.width
                        height: candidateName.implicitHeight + 2 * Satin.space.tip
                        radius: Satin.radius.chip
                        color: candidate.inspecting ? AiState.alpha(root.accent, 0.10) : "transparent"
                        border.width: root.activeFocus && !root.cursorHidden && candidate.inspecting ? 2 : 1
                        border.color: root.activeFocus && !root.cursorHidden && candidate.inspecting
                            ? root.accent : AiState.alpha(root.foreground, 0.22)
                        Accessible.role: Accessible.Button
                        Accessible.name: View.optionName(candidate.modelData, root.picked, candidate.modelData.index === root.view.pin)
                            + (candidate.inspecting ? qsTr(", inspecting") : "")
                        Accessible.description: qsTr("Inspect this option locally. Does not send an AI follow-up.")
                        Accessible.onPressAction: root.touch(candidate.modelData)
                        Text {
                            id: candidateName
                            objectName: "aiCompareCandidateName"
                            x: Satin.space.gutter
                            y: Satin.space.tip
                            width: candidate.width - 2 * Satin.space.gutter
                            text: candidate.modelData.name
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            color: root.foreground
                            font.pixelSize: Satin.type.subtitle
                            font.weight: candidate.inspecting ? Font.DemiBold : Font.Normal
                            Accessible.ignored: true
                        }
                        TapHandler { onTapped: root.touch(candidate.modelData) }
                    }
                }
            }

            Repeater {
                id: cards
                model: cardColumn.visible && root.inspectedOption ? [root.inspectedOption] : []
                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property bool cursorHere: root.activeFocus && root.cursorOption !== null
                        && root.cursorOption.index === card.modelData.index
                    objectName: "aiCompareCard_" + root.inspectedPos
                    width: cardColumn.width
                    height: body.implicitHeight + 2 * Satin.space.gutter
                    radius: Satin.radius.row
                    color: card.modelData.index === root.picked ? AiState.alpha(root.accent, 0.08) : "transparent"
                    border.width: card.cursorHere ? 2 : 1
                    border.color: card.cursorHere ? root.accent : AiState.alpha(root.foreground, 0.30)
                    Accessible.role: Accessible.Grouping
                    Accessible.name: View.optionName(card.modelData, root.picked, card.modelData.index === root.view.pin)
                    Accessible.description: card.modelData.summary
                        + (card.modelData.recommended ? " " + qsTr("Recommendation from the AI answer, not an independent assessment.") : "")

                    Column {
                        id: body
                        x: Satin.space.gutter
                        y: Satin.space.gutter
                        width: card.width - 2 * Satin.space.gutter
                        spacing: Satin.space.tip
                        OptionHead {
                            width: body.width
                            option: card.modelData
                            chosen: card.modelData.index === root.picked
                            pinned: card.modelData.index === root.view.pin
                            grouped: false
                            ink: root.foreground
                            ring: root.accent
                        }
                        Column {
                            width: body.width
                            spacing: Satin.space.base
                            visible: card.modelData.facts.length > 0
                            Repeater {
                                model: card.modelData.facts
                                delegate: FactLine {
                                    required property var modelData
                                    width: body.width
                                    label: modelData.label
                                    value: modelData.value !== "" ? modelData.value : View.DASH
                                    ink: root.foreground
                                }
                            }
                        }
                        Column {
                            width: body.width
                            spacing: Satin.space.base
                            visible: card.modelData.pros.length + card.modelData.cons.length > 0
                            Repeater {
                                model: card.modelData.pros
                                delegate: Point {
                                    required property string modelData
                                    width: body.width
                                    glyph: "+"
                                    text: modelData
                                    spokenKind: qsTr("Pro")
                                    ink: root.foreground
                                }
                            }
                            Repeater {
                                model: card.modelData.cons
                                delegate: Point {
                                    required property string modelData
                                    width: body.width
                                    glyph: "-"
                                    text: modelData
                                    spokenKind: qsTr("Con")
                                    ink: root.foreground
                                }
                            }
                        }
                        OptionActions {
                            width: body.width
                            option: card.modelData
                            pinned: card.modelData.index === root.view.pin
                            canChoose: root.canChoose
                            canHide: !root.lastVisible
                            chooseHint: root.chooseHint
                            ink: root.foreground
                            ring: root.accent
                            onChooseClicked: { root.touch(card.modelData); root.choose(card.modelData.index); }
                            onPinClicked: { root.touch(card.modelData); Qt.callLater(root.togglePin, card.modelData.index); }
                            onHideClicked: { root.touch(card.modelData); Qt.callLater(root.toggleHide, card.modelData.index); }
                        }
                    }
                    TapHandler { onTapped: root.touch(card.modelData) }
                }
            }
        }

        // ---- hidden options: one line each, in both compositions -------------
        Column {
            id: stubColumn
            objectName: "aiCompareStubs"
            width: content.width
            spacing: Satin.space.base
            visible: root.usable && root.stubs.length > 0
            // A newly hidden option's delegate may not exist at the first
            // queued cursor reveal. Retry after its real geometry is laid out.
            onPositioningComplete: { if (root.activeFocus && root.cursorHidden) Qt.callLater(root.revealCursor); }

            Repeater {
                id: stubRepeater
                model: stubColumn.visible ? root.stubs : []
                delegate: Rectangle {
                    id: stub
                    required property var modelData
                    required property int index
                    readonly property bool cursorHere: root.activeFocus && root.cursorOption !== null
                        && root.cursorOption.index === stub.modelData.index
                    objectName: "aiCompareStub_" + stub.index
                    width: stubColumn.width
                    height: Math.max(showChip.height, stubName.implicitHeight) + Satin.space.tip * 2
                    radius: Satin.radius.chip
                    color: "transparent"
                    border.width: stub.cursorHere ? 2 : 1
                    border.color: stub.cursorHere ? root.accent : AiState.alpha(root.foreground, 0.30)
                    Accessible.role: Accessible.Grouping
                    Accessible.name: stub.modelData.name + ", " + qsTr("hidden")

                    Text {
                        id: stubName
                        objectName: "aiCompareStubName"
                        x: Satin.space.gutter
                        anchors.verticalCenter: parent.verticalCenter
                        width: stub.width - showChip.width - 3 * Satin.space.gutter
                        text: stub.modelData.name + " \u2014 " + qsTr("hidden")
                        textFormat: Text.PlainText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: AiState.alpha(root.foreground, 0.86)
                        font.pixelSize: Satin.type.meta
                        Accessible.ignored: true
                    }
                    Chip {
                        id: showChip
                        objectName: "aiCompareShow"
                        anchors.right: parent.right
                        anchors.rightMargin: Satin.space.gutter
                        anchors.verticalCenter: parent.verticalCenter
                        ink: root.foreground
                        ring: root.accent
                        label: qsTr("Show")
                        spoken: qsTr("Show %1").arg(stub.modelData.name)
                        onActivated: {
                            root.touch(stub.modelData);
                            Qt.callLater(root.toggleHide, stub.modelData.index);
                        }
                    }
                    TapHandler { onTapped: root.touch(stub.modelData) }
                }
            }
        }

        Text {
            objectName: "aiCompareHint"
            width: content.width
            visible: text.length > 0
            text: root.usable && !root.canChoose && root.picked < 0 ? root.chooseHint : ""
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: AiState.alpha(root.foreground, 0.80)
            font.pixelSize: Satin.type.label
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }
}
