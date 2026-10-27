pragma ComponentBehavior: Bound

import QtQuick
import "AiLayout.js" as Layout
import "AiState.js" as AiState
import "SatinGlass.js" as Satin

// One primary native object, its actual controls, then supporting material.
// Stable hosts survive reflow: resizing must not recreate an edited calculator.
Column {
    id: root
    objectName: "aiTaskSurface"
    required property var composition
    readonly property var blocks: root.composition.blocks
    required property color foreground
    required property color background
    required property color accent
    property var checkedState: ({})
    property var uiState: null
    property int turnId: -1
    property var openUiService: null
    property bool calcCanDuplicate: true
    property string calcDuplicateHint: ""
    property string mediaRoot: ""
    property string suppressedTitle: ""
    property int turnIndex: 0
    property bool formCanSubmit: false
    property string formHint: ""
    property bool choiceCanSubmit: false
    property string choiceHint: ""
    property bool canFocus: false
    readonly property var originalIndices: root.blocks.map(function(_, i) { return i; })
    readonly property bool hasControls: root.composition.controls.length > 0
    readonly property bool splitControls: root.hasControls && root.width >= 820
    // Only compact supporting material belongs beside a form. Never squeeze
    // another tool, photo, table or chart into an inspector-sized column.
    readonly property bool sideContext: root.composition.kind === "form" && root.width >= 860
        && root.composition.support.length > 0 && root.composition.support.every(function(i) {
            return ["text", "richtext", "checklist", "progress"].indexOf(root.blocks[i].type) >= 0;
        })
    readonly property int inset: Satin.space.section
    readonly property int gutter: Satin.space.section + Satin.space.tip
    readonly property real sideWidth: Math.min(280, Math.round(root.width * 0.30))
    readonly property real workWidth: root.sideContext ? root.width - root.sideWidth - root.gutter : root.width
    signal checkChanged(int blockIndex, int itemIndex, bool checked)
    signal uiStateEdited(int blockIndex, string key, var value)
    signal copyTextRequested(string text)
    signal duplicateCalcRequested(var baked)
    signal formSubmitRequested(int blockIndex)
    signal choiceRequested(int blockIndex, string kind, int index)
    signal focusRequested(int blockIndex, string kind, int index, string label, string detail)
    signal openUrl(string url)
    spacing: Satin.space.section + Satin.space.tip

    component Group: AiBlocks {
        required property var owner
        contextBlocks: owner.blocks
        contextBlockIndices: owner.originalIndices
        suppressedTitle: owner.suppressedTitle
        checkedState: owner.checkedState
        uiState: owner.uiState
        turnId: owner.turnId
        openUiService: owner.openUiService
        calcCanDuplicate: owner.calcCanDuplicate
        calcDuplicateHint: owner.calcDuplicateHint
        mediaRoot: owner.mediaRoot
        foreground: owner.foreground
        background: owner.background
        accent: owner.accent
        formCanSubmit: owner.formCanSubmit
        formHint: owner.formHint
        choiceCanSubmit: owner.choiceCanSubmit
        choiceHint: owner.choiceHint
        canFocus: owner.canFocus
        onCheckChanged: (blockIndex, itemIndex, checked) => owner.checkChanged(blockIndex, itemIndex, checked)
        onUiStateEdited: (blockIndex, key, value) => owner.uiStateEdited(blockIndex, key, value)
        onCopyTextRequested: text => owner.copyTextRequested(text)
        onDuplicateCalcRequested: baked => owner.duplicateCalcRequested(baked)
        onFormSubmitRequested: blockIndex => owner.formSubmitRequested(blockIndex)
        onChoiceRequested: (blockIndex, kind, index) => owner.choiceRequested(blockIndex, kind, index)
        onFocusRequested: (blockIndex, kind, index, label, detail) => owner.focusRequested(blockIndex, kind, index, label, detail)
        onOpenUrl: url => owner.openUrl(url)
    }

    Item {
        id: stage
        objectName: "aiTaskStage"
        width: root.width
        implicitHeight: Math.max(workArea.height, root.sideContext ? context.height : 0)

        Rectangle {
            id: workArea
            objectName: "aiTaskWorkArea"
            width: root.workWidth
            height: root.inset * 2 + (root.splitControls
                ? Math.max(primary.implicitHeight, controls.implicitHeight)
                : primary.implicitHeight + (root.hasControls ? root.gutter + controls.implicitHeight : 0))
            radius: Satin.radius.row
            color: AiState.alpha(root.foreground, 0.025)
            border.width: 1
            border.color: AiState.alpha(root.foreground, Satin.keyline.hair)
        }

        Item {
            id: primary
            objectName: "aiTaskPrimary"
            x: root.inset
            y: root.inset
            width: root.splitControls ? root.workWidth - root.inset * 2 - root.sideWidth - root.gutter
                : root.workWidth - root.inset * 2
            implicitHeight: primaryBlocks.implicitHeight
            height: implicitHeight
            Group {
                id: primaryBlocks
                objectName: "aiNativeBlocks_" + root.turnIndex
                owner: root
                width: primary.width
                blocks: Layout.blocksAt(root.blocks, root.composition.primary)
                blockIndices: root.composition.primary
            }
        }
        Group {
            id: controls
            objectName: "aiTaskControls"
            owner: root
            x: root.splitControls ? primary.x + primary.width + root.gutter : root.inset
            y: root.splitControls ? root.inset : primary.y + primary.implicitHeight + root.gutter
            width: root.splitControls ? root.sideWidth : primary.width
            visible: root.hasControls
            blocks: Layout.blocksAt(root.blocks, root.composition.controls)
            blockIndices: root.composition.controls
        }
        // This host stays put in the item tree when switching between a side
        // inspector and a full-width context section below the tool.
        Group {
            id: context
            objectName: "aiTaskContext"
            owner: root
            x: root.sideContext ? root.workWidth + root.gutter : 0
            y: root.sideContext ? 0 : workArea.height + root.gutter
            width: root.sideContext ? root.sideWidth : root.width
            visible: root.composition.support.length > 0
            blocks: Layout.blocksAt(root.blocks, root.composition.support)
            blockIndices: root.composition.support
        }
        // Include context below the primary stage without an extra scroll area.
        height: root.sideContext || !context.visible ? implicitHeight : context.y + context.implicitHeight
    }
    Group {
        objectName: "aiTaskSources"
        owner: root
        width: root.width
        visible: root.composition.sources.length > 0
        blocks: Layout.blocksAt(root.blocks, root.composition.sources)
        blockIndices: root.composition.sources
    }
}
