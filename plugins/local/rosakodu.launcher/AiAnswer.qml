pragma ComponentBehavior: Bound

import QtQuick
import "AiState.js" as AiState
import "AiLayout.js" as Layout
import "SatinGlass.js" as Satin

// Width determines the composition; measured children determine its height.
// The host owns title derivation, errors, retry and persisted checklist state.
Column {
    id: root

    required property var turn
    required property color foreground
    required property color background
    required property color accent
    property bool showText: false
    property var checkedState: ({})
    property var uiState: null
    property bool calcCanDuplicate: true
    property string calcDuplicateHint: ""
    property string mediaRoot: ""
    property string title: ""
    // A failed turn keeps its prompt as a quiet label so the error, not the
    // question, is the loudest thing on the card.
    property bool failed: false
    property int turnIndex: 0
    readonly property string summary: showText ? AiState.textAnswer(turn, uiState) : String(turn && turn.answer || "")
    readonly property var answerBlocks: {
        // ListModel payloads expose Qt sequences, not native JavaScript arrays.
        var result = [], blocks = turn && turn.blocks;
        for (var i = 0; blocks && i < blocks.length; ++i) result.push(blocks[i]);
        return result;
    }
    readonly property var composition: Layout.answerComposition(root.answerBlocks)
    readonly property bool isTaskAnswer: !root.failed && root.composition.kind !== ""
    readonly property bool taskMode: root.isTaskAnswer && !root.showText
    readonly property string displayTitle: root.taskMode && root.composition.title
        ? root.composition.title : root.title
    readonly property string taskLabel: ({calc: qsTr("CALCULATOR"), compare: qsTr("COMPARE & DECIDE"),
        form: qsTr("MAKE IT YOURS"), timeline: qsTr("YOUR PLAN"), diagram: qsTr("EXPLORE THE IDEA"),
        gallery: qsTr("VISUAL EXPLORER"), chart: qsTr("EXPLORE THE DATA"), market: qsTr("MARKET OVERVIEW"),
        steps: qsTr("STEP BY STEP"), check: qsTr("CHECK YOUR UNDERSTANDING"), predict: qsTr("MAKE A PREDICTION"),
        table: qsTr("EXPLORE THE DETAILS"), actions: qsTr("CHOOSE YOUR NEXT STEP")})[root.composition.kind] || ""
    property bool explanationExpanded: false
    readonly property string disclosureKey: String(root.turn && root.turn.id) + "\n" + String(root.turn && root.turn.prompt)
    onDisclosureKeyChanged: root.explanationExpanded = false
    readonly property bool canFoldExplanation: root.taskMode && root.summary.length > 200
    readonly property string visibleSummary: root.canFoldExplanation && !root.explanationExpanded
        ? Layout.orientationExcerpt(root.summary, 160) : root.summary
    readonly property int heroBlockIndex: {
        for (var i = 0; i < answerBlocks.length; ++i) {
            if (answerBlocks[i] && answerBlocks[i].type === "image") return i;
        }
        return -1;
    }
    readonly property var heroBlock: {
        var block = root.answerBlocks[root.heroBlockIndex];
        return block && block.type === "image" ? block : ({});
    }
    readonly property bool hasHero: !showText && !root.isTaskAnswer && root.heroBlock.type === "image"
    readonly property bool wideHero: hasHero && width >= 620
    // Keep sources at the end without changing checklist identity. These are
    // indexes into the original answer, before the hero image is removed.
    readonly property var remainingBlockIndices: {
        var body = [], sources = [];
        for (var i = 0; i < answerBlocks.length; ++i) {
            if (i === heroBlockIndex) continue;
            (answerBlocks[i].type === "sources" ? sources : body).push(i);
        }
        return body.concat(sources);
    }
    readonly property var remainingBlocks: remainingBlockIndices.map(function(index) { return root.answerBlocks[index]; })
    readonly property bool waiting: !!turn && turn.status === "working" && !summary.length && !answerBlocks.length
    readonly property real responseHeight: implicitHeight
    signal checkChanged(int originalBlockIndex, int itemIndex, bool checked)
    signal uiStateEdited(int blockIndex, string key, var value)
    signal copyTextRequested(string text)
    signal duplicateCalcRequested(var baked)
    signal formSubmitRequested(int blockIndex)
    // Host gate for sending a form block, and the reason when it is closed.
    property bool formCanSubmit: false
    property string formHint: ""
    // Same seams for a picked option / a focus request (see AiBlocks).
    signal choiceRequested(int blockIndex, string kind, int index)
    property bool choiceCanSubmit: false
    property string choiceHint: ""
    signal focusRequested(int blockIndex, string kind, int index, string label, string detail)
    // Host gate for "Ask about this" on a part (latest finished answer on an
    // idle service). Never open in the text view, which has no parts.
    property bool canFocus: false
    signal openUrl(string url)

    spacing: Satin.space.section

    Item {
        id: hero
        objectName: "aiAnswerHero"
        width: root.width
        implicitHeight: root.wideHero
            ? Math.max(copy.implicitHeight, figure.implicitHeight)
            : copy.implicitHeight + (root.hasHero ? (copy.implicitHeight > 0 ? Satin.space.section : 0) + figure.implicitHeight : 0)
        height: implicitHeight
        visible: implicitHeight > 0
        readonly property real figureColumnWidth: Math.max(0, Math.min(width >= 900 ? 460 : 300, width * 0.4))

        Column {
            id: copy
            objectName: "aiAnswerCopy"
            width: root.wideHero ? Math.max(0, hero.width - hero.figureColumnWidth - 24) : hero.width
            spacing: 12

            Text {
                objectName: "aiAnswerTaskLabel"
                width: copy.width
                visible: root.taskMode
                text: root.taskLabel
                textFormat: Text.PlainText
                color: AiState.alpha(root.foreground, 0.80)
                font.pixelSize: Satin.type.header
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                id: heading
                objectName: "aiAnswerTitle"
                width: copy.width
                visible: text.length > 0
                text: root.displayTitle
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.failed ? AiState.alpha(root.foreground, 0.80) : root.foreground
                font.pixelSize: root.failed ? Satin.type.subtitle : Satin.type.display
                font.weight: Font.DemiBold
                font.letterSpacing: root.failed ? 0 : -0.4
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            // What a form-answer turn sent: the same rows the request carried.
            Text {
                objectName: "aiAnswerFormSent"
                width: copy.width
                visible: text.length > 0
                text: AiState.formSentText(root.turn)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: AiState.alpha(root.foreground, 0.86)
                font.pixelSize: Satin.type.body
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // What a picked-option turn chose ("Picked: <label>").
            Text {
                objectName: "aiAnswerChoice"
                width: copy.width
                visible: text.length > 0
                text: AiState.choiceSentText(root.turn)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: AiState.alpha(root.foreground, 0.86)
                font.pixelSize: Satin.type.body
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            TextEdit {
                id: answerText
                objectName: "aiAnswerSummary"
                width: copy.width
                visible: text.length > 0
                text: root.visibleSummary
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                activeFocusOnTab: true
                color: root.foreground
                selectionColor: AiState.alpha(root.accent, 0.35)
                selectedTextColor: root.foreground
                // Native font leading gives roughly 1.35 line height without
                // converting plain selectable prose to HTML or fixing a height.
                font.pixelSize: Satin.type.subtitle
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("AI answer")
                Accessible.description: text
            }

            AiButton {
                objectName: "aiAnswerReadMore"
                visible: root.canFoldExplanation
                text: root.explanationExpanded ? qsTr("Less explanation") : qsTr("Read full explanation")
                foreground: root.foreground
                accent: root.accent
                implicitHeight: 28
                horizontalPadding: 0
                Accessible.description: qsTr("Expand or collapse the full answer. The interactive tool stays below.")
                onClicked: root.explanationExpanded = !root.explanationExpanded
            }

            Column {
                objectName: "aiAnswerPlaceholder"
                width: copy.width
                visible: root.waiting
                spacing: 9
                // Decorative only: the pane's activity row owns the real
                // phase, elapsed time and accessible name.
                Accessible.ignored: true
                Rectangle {
                    width: Math.max(0, Math.min(parent.width * 0.76, 280))
                    height: 7
                    radius: 3.5
                    color: AiState.alpha(root.foreground, 0.08)
                }
                Rectangle {
                    width: Math.max(0, Math.min(parent.width * 0.48, 180))
                    height: 7
                    radius: 3.5
                    color: AiState.alpha(root.foreground, 0.05)
                }
            }
        }

        AiImage {
            id: figure
            // AiImage retains its native objectName and local-cache validation.
            x: root.wideHero ? copy.width + 24 : 0
            y: root.wideHero ? 0 : copy.implicitHeight + (copy.implicitHeight > 0 ? Satin.space.section : 0)
            width: root.wideHero ? hero.figureColumnWidth : hero.width
            visible: root.hasHero
            block: root.hasHero ? root.heroBlock : ({})
            mediaRoot: root.mediaRoot || defaultMediaRoot
            alternativeIndex: {
                var value = root.uiState ? root.uiState["image:" + root.heroBlockIndex] : undefined;
                return typeof value === "number" && value >= 0 ? value : 0;
            }
            maxFigureWidth: root.width >= 900 ? 460 : 300
            maxFigureHeight: root.width >= 900 ? 440 : 320
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onOpenUrl: url => root.openUrl(url)
            onAlternativeChanged: index => root.uiStateEdited(root.heroBlockIndex, "image:" + root.heroBlockIndex, index)
        }
    }

    Loader {
        id: taskLoader
        objectName: "aiTaskSurfaceLoader"
        width: root.width
        // Switching to text hides, rather than destroys, the edited tool.
        active: root.isTaskAnswer
        visible: root.taskMode
        height: visible && item ? (item as Item).implicitHeight : 0
        sourceComponent: Component {
            AiTaskSurface {
                width: taskLoader.width
                composition: root.composition
                turnIndex: root.turnIndex
                suppressedTitle: root.displayTitle
                checkedState: root.checkedState
                uiState: root.uiState
                calcCanDuplicate: root.calcCanDuplicate
                calcDuplicateHint: root.calcDuplicateHint
                mediaRoot: root.mediaRoot
                foreground: root.foreground
                background: root.background
                accent: root.accent
                formCanSubmit: root.formCanSubmit
                formHint: root.formHint
                choiceCanSubmit: root.choiceCanSubmit
                choiceHint: root.choiceHint
                canFocus: root.canFocus && !root.showText
                onCheckChanged: (blockIndex, itemIndex, checked) => root.checkChanged(blockIndex, itemIndex, checked)
                onUiStateEdited: (blockIndex, key, value) => root.uiStateEdited(blockIndex, key, value)
                onCopyTextRequested: text => root.copyTextRequested(text)
                onDuplicateCalcRequested: baked => root.duplicateCalcRequested(baked)
                onFormSubmitRequested: blockIndex => root.formSubmitRequested(blockIndex)
                onChoiceRequested: (blockIndex, kind, index) => root.choiceRequested(blockIndex, kind, index)
                onFocusRequested: (blockIndex, kind, index, label, detail) => root.focusRequested(blockIndex, kind, index, label, detail)
                onOpenUrl: url => root.openUrl(url)
            }
        }
    }

    AiBlocks {
        objectName: root.isTaskAnswer ? "" : "aiNativeBlocks_" + root.turnIndex
        width: root.width
        visible: !root.isTaskAnswer && !root.showText && root.remainingBlocks.length > 0
        blocks: root.isTaskAnswer ? [] : root.remainingBlocks
        suppressedTitle: root.title
        blockIndices: root.remainingBlockIndices
        checkedState: root.checkedState
        uiState: root.uiState
        calcCanDuplicate: root.calcCanDuplicate
        calcDuplicateHint: root.calcDuplicateHint
        mediaRoot: root.mediaRoot
        foreground: root.foreground
        background: root.background
        accent: root.accent
        onCheckChanged: (blockIndex, itemIndex, checked) => root.checkChanged(blockIndex, itemIndex, checked)
        onUiStateEdited: (blockIndex, key, value) => root.uiStateEdited(blockIndex, key, value)
        onCopyTextRequested: text => root.copyTextRequested(text)
        onDuplicateCalcRequested: baked => root.duplicateCalcRequested(baked)
        formCanSubmit: root.formCanSubmit
        formHint: root.formHint
        onFormSubmitRequested: blockIndex => root.formSubmitRequested(blockIndex)
        choiceCanSubmit: root.choiceCanSubmit
        choiceHint: root.choiceHint
        onChoiceRequested: (blockIndex, kind, index) => root.choiceRequested(blockIndex, kind, index)
        canFocus: root.canFocus && !root.showText
        onFocusRequested: (blockIndex, kind, index, label, detail) => root.focusRequested(blockIndex, kind, index, label, detail)
        onOpenUrl: url => root.openUrl(url)
    }
}
