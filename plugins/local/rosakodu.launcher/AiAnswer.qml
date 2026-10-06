pragma ComponentBehavior: Bound

import QtQuick
import "AiState.js" as AiState
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
    property string mediaRoot: ""
    property string title: ""
    property int turnIndex: 0
    readonly property string summary: showText ? AiState.textAnswer(turn) : String(turn && turn.answer || "")
    readonly property var answerBlocks: {
        // ListModel payloads expose Qt sequences, not native JavaScript arrays.
        var result = [], blocks = turn && turn.blocks;
        for (var i = 0; blocks && i < blocks.length; ++i) result.push(blocks[i]);
        return result;
    }
    readonly property int heroBlockIndex: {
        for (var i = 0; i < answerBlocks.length; ++i) {
            if (answerBlocks[i].type === "image") return i;
        }
        return -1;
    }
    readonly property bool hasHero: !showText && heroBlockIndex >= 0
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
                id: heading
                objectName: "aiAnswerTitle"
                width: copy.width
                visible: text.length > 0
                text: root.title
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.display
                font.weight: Font.DemiBold
                font.letterSpacing: -0.4
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            TextEdit {
                id: answerText
                objectName: "aiAnswerSummary"
                width: copy.width
                visible: text.length > 0
                text: root.summary
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

            Column {
                objectName: "aiAnswerPlaceholder"
                width: copy.width
                visible: root.waiting
                spacing: 9
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Preparing answer")
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
            block: root.hasHero ? root.answerBlocks[root.heroBlockIndex] : ({})
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

    AiBlocks {
        objectName: "aiNativeBlocks_" + root.turnIndex
        width: root.width
        visible: !root.showText && root.remainingBlocks.length > 0
        blocks: root.remainingBlocks
        suppressedTitle: root.title
        blockIndices: root.remainingBlockIndices
        checkedState: root.checkedState
        uiState: root.uiState
        mediaRoot: root.mediaRoot
        foreground: root.foreground
        background: root.background
        accent: root.accent
        onCheckChanged: (blockIndex, itemIndex, checked) => root.checkChanged(blockIndex, itemIndex, checked)
        onUiStateEdited: (blockIndex, key, value) => root.uiStateEdited(blockIndex, key, value)
        onOpenUrl: url => root.openUrl(url)
    }
}
