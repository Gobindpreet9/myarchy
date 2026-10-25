pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "SatinGlass.js" as Satin
import "AiState.js" as AiState
import "AiFormula.js" as Formula
import "AiScroll.js" as Scroll

// Eager native delegates deliberately survive Flickable scrolling. Replacing
// blocks starts a new result (and therefore resets local checklist state).
Column {
    id: root

    property var blocks: []
    // Filtered editorial layouts retain indexes used by persistent checklists.
    property var blockIndices: []
    // A task layout may place the diagram and its control in different columns.
    // Resolve bindings against the WHOLE answer, not just this group's blocks.
    property var contextBlocks: []
    property var contextBlockIndices: []
    property string suppressedTitle: ""
    property string mediaRoot: ""
    property var checkedState: null
    // Per-turn interaction state (step index, check selections, predictions).
    property var uiState: null
    property bool calcCanDuplicate: true
    property string calcDuplicateHint: ""
    signal checkChanged(int blockIndex, int itemIndex, bool checked)
    signal uiStateEdited(int blockIndex, string key, var value)
    // A calc block asked for clipboard text / a standalone duplicate (user-initiated).
    signal copyTextRequested(string text)
    signal duplicateCalcRequested(var baked)
    // A form block asked to be sent (original block index; user-initiated).
    signal formSubmitRequested(int blockIndex)
    // The host's gate for sending a form (latest answer, idle service) and why not.
    property bool formCanSubmit: false
    property string formHint: ""
    // A picked option of an actions/compare block (ORIGINAL block index, the
    // block's own type, option index; user-initiated), and the host's gate for
    // it (latest finished answer, idle service) with the reason when closed.
    signal choiceRequested(int blockIndex, string kind, int index)
    property bool choiceCanSubmit: false
    property string choiceHint: ""
    // A part of a block the person wants to ask about (index -1 = the block).
    signal focusRequested(int blockIndex, string kind, int index, string label, string detail)
    // The host's gate for pointing a question at a part ("Ask" on a table row,
    // gallery tile, diagram node, step or chart point): the latest finished
    // answer on an idle service, in the interface (not text) view. Closed, the
    // per-part controls and their `?` key do not exist.
    property bool canFocus: false
    signal openUrl(string url)
    required property color foreground
    required property color background
    required property color accent

    // Slider -> diagram coupling: at most one slider and one diagram coexist,
    // so the pairing is unambiguous. Link expressions are evaluated at the
    // slider's current value and override the diagram part's base fields.
    readonly property var diagramLinks: {
        var result = {}, slider = null, sliderIndex = -1;
        var blocks = root.contextBlocks.length ? root.contextBlocks : root.blocks;
        var indices = root.contextBlocks.length ? root.contextBlockIndices : root.blockIndices;
        for (var i = 0; i < blocks.length; ++i) {
            var candidate = blocks[i];
            if (candidate && candidate.type === "slider") {
                slider = candidate;
                sliderIndex = indices.length > i ? indices[i] : i;
                break;
            }
        }
        if (!slider || !slider.links || slider.links.length === 0) return result;
        var stored = root.uiState ? root.uiState["slider:" + sliderIndex] : undefined;
        var value = typeof stored === "number" ? stored : Number((slider.control || {}).value) || 0;
        for (var j = 0; j < slider.links.length; ++j) {
            var link = slider.links[j];
            if (!link) continue;
            var part = result[String(link.part)] || (result[String(link.part)] = {});
            part[String(link.property)] = Formula.evaluate(Formula.compile(String(link.expression || "")), value);
        }
        return result;
    }

    spacing: Satin.space.section

    function alpha(color, opacity) {
        return Qt.rgba(color.r, color.g, color.b, opacity);
    }

    // The option already picked on a block (`act:<blockIndex>` = {picked}), -1 none.
    function pickedOf(blockIndex) {
        var entry = root.uiState ? root.uiState["act:" + blockIndex] : undefined;
        var value = entry && typeof entry === "object" ? entry.picked : undefined;
        return typeof value === "number" && value === Math.floor(value) && value >= 0 ? value : -1;
    }

    Repeater {
        model: root.blocks

        delegate: Column {
            id: section
            required property var modelData
            required property int index
            width: root.width
            spacing: Satin.space.tip

            Text {
                width: parent.width
                visible: text.length > 0 && section.modelData.type !== "image" && section.modelData.type !== "sources"
                    && text.toLowerCase() !== root.suppressedTitle.toLowerCase()
                text: section.modelData.title || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.result
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Loader {
                width: parent.width
                // The component gets this context through its visual parent.
                property var block: section.modelData
                property int blockIndex: root.blockIndices.length > section.index ? root.blockIndices[section.index] : section.index
                sourceComponent: {
                    switch (block.type) {
                    case "text":
                    case "richtext": return proseComponent;
                    case "code": return codeComponent;
                    case "checklist": return checklistComponent;
                    case "table": return tableComponent;
                    case "metric": return metricComponent;
                    case "progress": return progressComponent;
                    case "image": return imageComponent;
                    case "gallery": return galleryComponent;
                    case "market":
                    case "chart": return chartComponent;
                    case "steps": return stepsComponent;
                    case "check": return checkComponent;
                    case "predict": return predictComponent;
                    case "diagram": return diagramComponent;
                    case "slider": return sliderComponent;
                    case "calc": return calcComponent;
                    case "form": return formComponent;
                    case "actions": return actionsComponent;
                    case "compare": return compareComponent;
                    case "timeline": return timelineComponent;
                    case "sources": return sourcesComponent;
                    default: return null;
                    }
                }
            }
        }
    }

    Component {
        id: imageComponent
        AiImage {
            readonly property var host: parent
            block: host.block
            mediaRoot: root.mediaRoot || defaultMediaRoot
            alternativeIndex: {
                var value = root.uiState ? root.uiState["image:" + host.blockIndex] : undefined;
                return typeof value === "number" && value >= 0 ? value : 0;
            }
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onOpenUrl: url => root.openUrl(url)
            onAlternativeChanged: index => root.uiStateEdited(host.blockIndex, "image:" + host.blockIndex, index)
        }
    }

    Component {
        id: galleryComponent
        AiGallery {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            uiState: root.uiState
            mediaRoot: root.mediaRoot
            canFocus: root.canFocus
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onUiStateEdited: (key, value) => root.uiStateEdited(blockIndex, key, value)
            onFocusRequested: (index, label, detail) => root.focusRequested(blockIndex, "gallery", index, label, detail)
            onOpenUrl: url => root.openUrl(url)
        }
    }

    Component {
        id: chartComponent
        AiChart {
            readonly property var host: parent
            block: host.block
            // Only the plain `chart` block is a focus kind (a `market` block is
            // not: the service requires kind === the block's own type).
            canFocus: root.canFocus && host.block.type === "chart"
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onOpenUrl: url => root.openUrl(url)
            onFocusRequested: (index, label, detail) => root.focusRequested(host.blockIndex, "chart", index, label, detail)
        }
    }

    Component {
        id: sourcesComponent
        Flow {
            id: sources
            readonly property var host: parent
            property var block: host.block
            spacing: Satin.space.base
            Repeater {
                model: sources.block.items || []
                delegate: Button {
                    id: link
                    required property var modelData
                    required property int index
                    objectName: "aiSource_" + index
                    width: Math.min(sources.width, contentItem.implicitWidth + 2 * padding)
                    padding: Satin.space.tip
                    implicitHeight: Math.max(36, contentItem.implicitHeight + padding * 2)
                    activeFocusOnTab: true
                    text: String(modelData.label || modelData.url || "")
                    enabled: AiState.sourceCommand(String(modelData.url || "")).length > 0
                    onClicked: root.openUrl(String(modelData.url))
                    Accessible.name: qsTr("Open source: ") + text
                    contentItem: Text {
                        text: link.text + "  ·  " + String(link.modelData.url || "").replace(/^https?:\/\//i, "").split("/")[0] + " ↗"
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: Satin.type.meta
                        color: root.alpha(root.foreground, link.enabled ? 0.82 : 0.5)
                    }
                    background: Rectangle {
                        radius: Satin.radius.chip
                        color: link.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                        border.width: link.visualFocus ? 2 : 0
                        border.color: root.accent
                    }
                }
            }
        }
    }

    Component {
        id: proseComponent
        Text {
            readonly property var host: parent
            property var block: host.block
            text: block.text || ""
            textFormat: block.type === "richtext" ? Text.RichText : Text.PlainText
            wrapMode: Text.Wrap
            color: root.foreground
            linkColor: root.accent
            font.pixelSize: Satin.type.result
            // Sanitized rich text may contain links; no link handler opens URLs.
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }
    }

    Component {
        id: codeComponent
        Rectangle {
            id: code
            readonly property var host: parent
            property var block: host.block
            implicitHeight: codeText.implicitHeight + 2 * Satin.space.gutter
            radius: Satin.radius.chip
            color: root.alpha(root.foreground, 0.045)
            border.width: codeText.activeFocus ? 2 : 1
            border.color: codeText.activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)

            TextEdit {
                id: codeText
                objectName: "aiCode"
                x: Satin.space.gutter
                y: Satin.space.gutter
                width: Math.max(0, parent.width - 2 * Satin.space.gutter)
                height: implicitHeight
                text: code.block.text || ""
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                activeFocusOnTab: true
                color: root.foreground
                selectionColor: root.alpha(root.accent, 0.42)
                selectedTextColor: root.foreground
                font.family: "monospace"
                font.pixelSize: Satin.type.meta
                Accessible.name: code.block.title || qsTr("Code")
            }
        }
    }

    Component {
        id: checklistComponent
        Column {
            id: checklist
            readonly property var host: parent
            property var block: host.block
            property int blockIndex: host.blockIndex
            spacing: Satin.space.base

            Repeater {
                model: checklist.block.items
                delegate: CheckBox {
                    id: box
                    required property string modelData
                    required property int index
                    objectName: "aiCheck_" + checklist.blockIndex + "_" + index
                    width: checklist.width
                    implicitHeight: Math.max(Satin.space.row * 3, contentItem.implicitHeight + 2 * padding)
                    padding: Satin.space.base
                    spacing: Satin.space.tip
                    activeFocusOnTab: true
                    checked: root.checkedState ? root.checkedState[checklist.blockIndex + ":" + index] === true : false
                    onToggled: root.checkChanged(checklist.blockIndex, index, checked)
                    Accessible.name: modelData
                    Keys.onReturnPressed: {
                        toggle()
                        root.checkChanged(checklist.blockIndex, index, checked)
                    }
                    Keys.onEnterPressed: {
                        toggle()
                        root.checkChanged(checklist.blockIndex, index, checked)
                    }

                    indicator: Rectangle {
                        x: box.leftPadding
                        y: (box.height - height) / 2
                        width: Satin.type.search
                        height: width
                        radius: Satin.space.base
                        color: box.checked ? root.accent : root.background
                        border.width: 1
                        border.color: box.checked ? root.accent : root.alpha(root.foreground, 0.55)

                        Text {
                            anchors.centerIn: parent
                            text: "✓"
                            textFormat: Text.PlainText
                            visible: box.checked
                            color: root.background
                            font.pixelSize: Satin.type.result
                            font.weight: Font.Bold
                        }
                    }
                    contentItem: Text {
                        leftPadding: box.indicator.width + box.spacing
                        text: box.modelData
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.foreground
                        font.pixelSize: Satin.type.result
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: Satin.radius.chip
                        color: box.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                        border.width: box.visualFocus ? 2 : 0
                        border.color: root.accent
                    }
                }
            }
        }
    }

    Component {
        id: stepsComponent
        Column {
            id: stepsView
            readonly property var host: parent
            property var block: host.block
            property int blockIndex: host.blockIndex
            spacing: Satin.space.tip

            readonly property var steps: block.steps || []
            readonly property int current: {
                var value = root.uiState ? root.uiState["step:" + blockIndex] : undefined;
                return typeof value === "number" && value >= 0 && value < steps.length ? value : 0;
            }
            function choose(index) {
                if (index < 0 || index >= steps.length || index === current) return;
                root.uiStateEdited(blockIndex, "step:" + blockIndex, index);
            }
            // "Ask about this step": descriptors exist only while the host's
            // gate is open; the step buttons are already Tab stops, so the
            // keyboard path is `?` on the focused step (no extra stop).
            readonly property var askParts: root.canFocus ? AiState.askParts(block) : []
            function askAbout(index) {
                var part = root.canFocus && index >= 0 && index < askParts.length ? askParts[index] : null;
                if (part) root.focusRequested(blockIndex, "steps", part.index, part.label, part.detail);
            }

            Repeater {
                model: stepsView.steps
                delegate: Button {
                    id: stepRow
                    required property var modelData
                    required property int index
                    objectName: "aiStep_" + stepsView.blockIndex + "_" + index
                    readonly property bool askable: root.canFocus && index < stepsView.askParts.length
                        && stepsView.askParts[index] !== null
                    width: stepsView.width
                    padding: Satin.space.tip
                    activeFocusOnTab: true
                    Accessible.name: (index + 1) + ". " + modelData.label
                    Accessible.description: modelData.detail || ""
                    onClicked: stepsView.choose(index)
                    Keys.onPressed: function(event) {
                        if (stepRow.askable && (event.key === Qt.Key_Question || event.text === "?")) {
                            stepsView.askAbout(stepRow.index);
                            event.accepted = true;
                        }
                    }
                    HoverHandler { id: stepHover }
                    AiAskButton {
                        objectName: "aiStepAsk_" + stepsView.blockIndex + "_" + stepRow.index
                        z: 2
                        anchors.right: parent.right
                        anchors.rightMargin: Satin.space.base
                        anchors.verticalCenter: parent.verticalCenter
                        visible: stepRow.askable && (stepHover.hovered || stepRow.activeFocus || hovered)
                        subject: stepRow.askable ? stepsView.askParts[stepRow.index].label : ""
                        foreground: root.foreground
                        surface: root.background
                        accent: root.accent
                        onClicked: stepsView.askAbout(stepRow.index)
                    }
                    contentItem: Row {
                        spacing: Satin.space.gutter
                        Rectangle {
                            width: Satin.type.search
                            height: width
                            radius: width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: stepRow.index === stepsView.current ? root.accent : "transparent"
                            border.width: 1
                            border.color: stepRow.index === stepsView.current ? root.accent : root.alpha(root.foreground, 0.45)
                            Text {
                                anchors.centerIn: parent
                                text: String(stepRow.index + 1)
                                color: stepRow.index === stepsView.current ? root.background : root.foreground
                                font.pixelSize: Satin.type.meta
                            }
                        }
                        Text {
                            width: Math.max(0, stepRow.width - Satin.type.search - Satin.space.gutter - stepRow.padding * 2
                                - (stepRow.askable ? 52 : 0))
                            text: stepRow.modelData.label
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.pixelSize: Satin.type.result
                            font.weight: stepRow.index === stepsView.current ? Font.DemiBold : Font.Normal
                            wrapMode: Text.Wrap
                        }
                    }
                    background: Rectangle {
                        radius: Satin.radius.chip
                        color: stepRow.index === stepsView.current ? root.alpha(root.accent, 0.10)
                            : stepRow.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                        border.width: stepRow.visualFocus ? 2 : 0
                        border.color: root.accent
                    }
                }
            }

            Text {
                objectName: "aiStepDetail"
                width: parent.width
                visible: text.length > 0
                text: stepsView.steps.length > 0 ? (stepsView.steps[stepsView.current].detail || "") : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.85)
                font.pixelSize: Satin.type.meta
            }

            Row {
                spacing: Satin.space.gutter
                AiButton {
                    objectName: "aiStepPrev"
                    text: "Previous"
                    enabled: stepsView.current > 0
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: stepsView.choose(stepsView.current - 1)
                }
                Text {
                    objectName: "aiStepCount"
                    anchors.verticalCenter: parent.verticalCenter
                    text: stepsView.steps.length > 0 ? "Step " + (stepsView.current + 1) + " of " + stepsView.steps.length : ""
                    textFormat: Text.PlainText
                    color: root.alpha(root.foreground, 0.76)
                    font.pixelSize: Satin.type.meta
                }
                AiButton {
                    objectName: "aiStepNext"
                    text: "Next"
                    enabled: stepsView.current < stepsView.steps.length - 1
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: stepsView.choose(stepsView.current + 1)
                }
            }
        }
    }

    Component {
        id: checkComponent
        Column {
            id: checkView
            readonly property var host: parent
            property var block: host.block
            property int blockIndex: host.blockIndex
            spacing: Satin.space.tip

            readonly property var options: block.options || []
            readonly property var state: root.uiState ? root.uiState["check:" + blockIndex] : undefined
            readonly property var selected: state && Array.isArray(state.selected) ? state.selected : []
            readonly property bool checked: !!(state && state.checked)

            function toggleOption(index) {
                if (checked) return;
                var next = selected.slice();
                var at = next.indexOf(index);
                if (at >= 0) next.splice(at, 1); else next.push(index);
                root.uiStateEdited(blockIndex, "check:" + blockIndex, {selected: next, checked: false});
            }
            function commit() {
                if (!selected.length || checked) return;
                root.uiStateEdited(blockIndex, "check:" + blockIndex, {selected: selected, checked: true});
            }
            function retry() {
                root.uiStateEdited(blockIndex, "check:" + blockIndex, {selected: [], checked: false});
            }
            readonly property bool allRight: {
                if (!checked) return false;
                for (var i = 0; i < options.length; ++i) {
                    var wants = options[i].correct === true;
                    var picked = selected.indexOf(i) >= 0;
                    if (wants !== picked) return false;
                }
                return selected.length > 0;
            }

            Text {
                objectName: "aiCheckQuestion"
                width: parent.width
                text: checkView.block.question || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.result
            }

            Repeater {
                model: checkView.options
                delegate: Column {
                    id: optionRow
                    required property var modelData
                    required property int index
                    width: checkView.width
                    spacing: 4
                    readonly property bool picked: checkView.selected.indexOf(index) >= 0
                    readonly property bool correct: modelData.correct === true
                    readonly property bool revealFeedback: checkView.checked && (picked || correct)

                    Button {
                        id: optionButton
                        objectName: "aiCheckOption_" + checkView.blockIndex + "_" + index
                        width: optionRow.width
                        padding: Satin.space.tip
                        activeFocusOnTab: true
                        enabled: !checkView.checked
                        hoverEnabled: true
                        Accessible.name: modelData.label
                        onClicked: checkView.toggleOption(index)
                        contentItem: Row {
                            spacing: Satin.space.gutter
                            Text {
                                width: Satin.type.search
                                anchors.verticalCenter: parent.verticalCenter
                                text: optionRow.revealFeedback ? (optionRow.correct ? "✓" : "✗") : (optionRow.picked ? "●" : "○")
                                textFormat: Text.PlainText
                                color: optionRow.revealFeedback && !optionRow.correct ? root.alpha(root.foreground, 0.7)
                                    : optionRow.picked || optionRow.revealFeedback && optionRow.correct ? root.accent : root.alpha(root.foreground, 0.6)
                                font.pixelSize: Satin.type.result
                            }
                            Text {
                                width: Math.max(0, optionButton.width - Satin.type.search - Satin.space.gutter - optionButton.padding * 2)
                                text: modelData.label
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.pixelSize: Satin.type.result
                                wrapMode: Text.Wrap
                            }
                        }
                        background: Rectangle {
                            radius: Satin.radius.chip
                            color: optionRow.picked && !checkView.checked ? root.alpha(root.accent, 0.10)
                                : optionButton.hovered && !checkView.checked ? root.alpha(root.foreground, 0.045) : "transparent"
                            border.width: optionButton.visualFocus ? 2 : optionRow.picked && !checkView.checked ? 1 : 0
                            border.color: root.accent
                        }
                    }
                    Text {
                        width: parent.width
                        visible: optionRow.revealFeedback && modelData.feedback.length > 0
                        text: modelData.feedback
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: root.alpha(root.foreground, 0.75)
                        font.pixelSize: Satin.type.meta
                    }
                }
            }

            Row {
                spacing: Satin.space.gutter
                AiButton {
                    objectName: "aiCheckCommit"
                    visible: !checkView.checked
                    text: "Check"
                    enabled: checkView.selected.length > 0
                    primary: true
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: checkView.commit()
                }
                AiButton {
                    objectName: "aiCheckRetry"
                    visible: checkView.checked
                    text: "Try again"
                    foreground: root.foreground
                    accent: root.accent
                    onClicked: checkView.retry()
                }
                Text {
                    objectName: "aiCheckResult"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: checkView.checked
                    text: checkView.allRight ? "Correct." : "Not quite — check the marked answers and try again."
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    width: Math.max(0, checkView.width - 120)
                    color: checkView.allRight ? root.accent : root.alpha(root.foreground, 0.85)
                    font.pixelSize: Satin.type.result
                    Accessible.name: text
                }
            }

            Text {
                objectName: "aiCheckExplanation"
                width: parent.width
                visible: checkView.checked && text.length > 0
                text: checkView.checked ? (checkView.block.explanation || "") : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.8)
                font.pixelSize: Satin.type.meta
            }
        }
    }

    Component {
        id: predictComponent
        Column {
            id: predictView
            readonly property var host: parent
            property var block: host.block
            property int blockIndex: host.blockIndex
            spacing: Satin.space.tip

            readonly property var state: root.uiState ? root.uiState["predict:" + blockIndex] : undefined
            readonly property int choice: typeof state === "number" ? state : -1
            readonly property var choices: block.choices || []

            Text {
                objectName: "aiPredictPrompt"
                width: parent.width
                text: predictView.block.prompt || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.result
            }

            Repeater {
                model: predictView.choices
                delegate: Button {
                    id: choiceButton
                    required property string modelData
                    required property int index
                    objectName: "aiPredictChoice_" + predictView.blockIndex + "_" + index
                    width: predictView.width
                    padding: Satin.space.tip
                    activeFocusOnTab: true
                    enabled: predictView.choice < 0
                    hoverEnabled: true
                    Accessible.name: modelData
                    onClicked: root.uiStateEdited(predictView.blockIndex, "predict:" + predictView.blockIndex, index)
                    contentItem: Text {
                        width: Math.max(0, choiceButton.width - 2 * choiceButton.padding)
                        text: (choiceButton.index === predictView.choice ? "● " : "○ ") + choiceButton.modelData
                            + (choiceButton.index === predictView.choice ? "  ·  your prediction" : "")
                        textFormat: Text.PlainText
                        color: choiceButton.index === predictView.choice ? root.accent : root.foreground
                        font.pixelSize: Satin.type.result
                        wrapMode: Text.Wrap
                    }
                    background: Rectangle {
                        radius: Satin.radius.chip
                        color: choiceButton.index === predictView.choice ? root.alpha(root.accent, 0.10)
                            : choiceButton.hovered && predictView.choice < 0 ? root.alpha(root.foreground, 0.045) : "transparent"
                        border.width: choiceButton.visualFocus ? 2 : 0
                        border.color: root.accent
                    }
                }
            }

            Column {
                width: parent.width
                visible: predictView.choice >= 0
                spacing: 4
                Text {
                    objectName: "aiPredictReveal"
                    width: parent.width
                    text: predictView.choice >= 0 ? (predictView.block.reveal || "") : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.foreground
                    font.pixelSize: Satin.type.result
                }
                Text {
                    objectName: "aiPredictExplanation"
                    width: parent.width
                    visible: text.length > 0
                    text: predictView.choice >= 0 ? (predictView.block.explanation || "") : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.alpha(root.foreground, 0.8)
                    font.pixelSize: Satin.type.meta
                }
            }
        }
    }

    Component {
        id: diagramComponent
        AiDiagram {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            links: root.diagramLinks
            selectedPart: {
                var value = root.uiState ? root.uiState["diagram:" + blockIndex] : undefined;
                return typeof value === "number" && value >= 0 ? value : -1;
            }
            canFocus: root.canFocus
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onPartSelected: partIndex => root.uiStateEdited(blockIndex, "diagram:" + blockIndex, partIndex)
            onFocusRequested: (index, label, detail) => root.focusRequested(blockIndex, "diagram", index, label, detail)
        }
    }

    Component {
        id: sliderComponent
        AiSlider {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            value: {
                var stored = root.uiState ? root.uiState["slider:" + blockIndex] : undefined;
                if (typeof stored === "number") return stored;
                return Number((host.block && host.block.control ? host.block.control.value : 0)) || 0;
            }
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onValueEdited: value => root.uiStateEdited(blockIndex, "slider:" + blockIndex, value)
        }
    }

    Component {
        id: calcComponent
        AiCalc {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            saved: root.uiState ? root.uiState["calc:" + blockIndex] : undefined
            canDuplicate: root.calcCanDuplicate
            duplicateHint: root.calcDuplicateHint
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onStateEdited: edited => root.uiStateEdited(blockIndex, "calc:" + blockIndex, edited)
            onCopyRequested: text => root.copyTextRequested(text)
            onDuplicateRequested: baked => root.duplicateCalcRequested(baked)
        }
    }

    Component {
        id: formComponent
        AiForm {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            saved: root.uiState ? root.uiState["form:" + blockIndex] : undefined
            canSubmit: root.formCanSubmit
            submitHint: root.formHint
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onStateEdited: edited => root.uiStateEdited(blockIndex, "form:" + blockIndex, edited)
            onSubmitRequested: root.formSubmitRequested(blockIndex)
        }
    }

    Component {
        id: actionsComponent
        AiActions {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            // An open host gate also permits retrying a failed/stopped pick.
            // Keep the recorded pick on disk without locking out that retry.
            picked: root.choiceCanSubmit ? -1 : root.pickedOf(blockIndex)
            canChoose: root.choiceCanSubmit
            chooseHint: root.choiceHint
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onChoiceRequested: index => root.choiceRequested(blockIndex, "actions", index)
            canFocus: root.canFocus
            onFocusRequested: (index, label, detail) => root.focusRequested(blockIndex, "actions", index, label, detail)
        }
    }

    Component {
        id: compareComponent
        AiCompare {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            picked: root.pickedOf(blockIndex)
            canChoose: root.choiceCanSubmit
            chooseHint: root.choiceHint
            saved: root.uiState ? root.uiState["compare:" + blockIndex] : undefined
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onChoiceRequested: index => root.choiceRequested(blockIndex, "compare", index)
            onStateEdited: edited => root.uiStateEdited(blockIndex, "compare:" + blockIndex, edited)
            canFocus: root.canFocus
            onFocusRequested: (index, label, detail) => root.focusRequested(blockIndex, "compare", index, label, detail)
        }
    }

    Component {
        id: timelineComponent
        AiTimeline {
            readonly property var host: parent
            block: host.block
            blockIndex: host.blockIndex
            saved: root.uiState ? root.uiState["plan:" + blockIndex] : undefined
            foreground: root.foreground
            background: root.background
            accent: root.accent
            onStateEdited: edited => root.uiStateEdited(blockIndex, "plan:" + blockIndex, edited)
            canFocus: root.canFocus
            onFocusRequested: (index, label, detail) => root.focusRequested(blockIndex, "timeline", index, label, detail)
        }
    }

    Component {
        id: tableComponent
        Column {
            id: table
            readonly property var host: parent
            property var block: host.block
            property int blockIndex: host.blockIndex
            readonly property int columnCount: block.columns.length
            readonly property real cellWidth: columnCount > 0
                ? Math.max(0, (width - (root.canFocus ? 52 : 0) - (columnCount - 1) * Satin.space.gutter) / columnCount) : 0
            // Local comparison tools: a header click cycles asc/desc/off and
            // the filter narrows rows. Both live in the turn's persisted state,
            // so a reopened workspace keeps the user's arrangement.
            readonly property var tableState: root.uiState ? root.uiState["table:" + blockIndex] : undefined
            readonly property int sortColumn: tableState && typeof tableState.sort === "number" ? tableState.sort : -1
            readonly property int sortDir: tableState && tableState.dir === -1 ? -1 : 1
            readonly property string filterText: tableState && typeof tableState.filter === "string" ? tableState.filter : ""
            // Rows in view order, each with its position in the AUTHORED list
            // (`origin`): the sort/filter never changes which row a person means.
            readonly property var viewEntries: {
                var rows = [];
                var list = block.rows || [];
                var needle = filterText.toLowerCase();
                for (var i = 0; i < list.length; ++i) {
                    var row = list[i] || [];
                    if (needle.length) {
                        var joined = "";
                        for (var j = 0; j < row.length; ++j) joined += String(row[j] === undefined ? "" : row[j]) + "\u0001";
                        if (joined.toLowerCase().indexOf(needle) < 0) continue;
                    }
                    rows.push({row: row, origin: i});
                }
                if (sortColumn >= 0 && sortColumn < columnCount) {
                    var column = sortColumn;
                    rows.sort(function(a, b) {
                        var x = String(a.row[column] === undefined ? "" : a.row[column]);
                        var y = String(b.row[column] === undefined ? "" : b.row[column]);
                        var nx = Number(x), ny = Number(y);
                        var result = (x.length && y.length && isFinite(nx) && isFinite(ny))
                            ? nx - ny : x.localeCompare(y);
                        return result * sortDir || (a.origin - b.origin);
                    });
                }
                return rows;
            }
            readonly property var viewRows: viewEntries.map(function(entry) { return entry.row; })
            // "Ask about this row": descriptors only while the host's gate is
            // open (see AiBlocks.canFocus), indexed by the authored row.
            readonly property var askParts: root.canFocus ? AiState.askParts(block) : []
            function askPartAt(viewIndex) {
                if (!root.canFocus || viewIndex < 0 || viewIndex >= viewEntries.length) return null;
                var origin = viewEntries[viewIndex].origin;
                return origin < askParts.length ? askParts[origin] : null;
            }
            function askAbout(viewIndex) {
                var part = askPartAt(viewIndex);
                if (part) root.focusRequested(blockIndex, "table", part.index, part.label, part.detail);
            }
            function setState(sort, dir, filter) {
                root.uiStateEdited(blockIndex, "table:" + blockIndex,
                                   {sort: sort, dir: dir, filter: filter});
            }
            function cycleSort(column) {
                if (sortColumn !== column) table.setState(column, 1, filterText);
                else if (sortDir === 1) table.setState(column, -1, filterText);
                else table.setState(-1, 1, filterText);
            }
            spacing: Satin.space.tip

            Row {
                width: table.width
                spacing: Satin.space.gutter
                Repeater {
                    model: table.block.columns
                    delegate: Button {
                        id: tableHeader
                        required property string modelData
                        required property int index
                        objectName: "aiTableHeader_" + index
                        width: table.cellWidth
                        padding: 0
                        activeFocusOnTab: true
                        onClicked: table.cycleSort(index)
                        Accessible.name: modelData + (table.sortColumn === index
                            ? (table.sortDir === 1 ? qsTr(" sorted ascending") : qsTr(" sorted descending")) : "")
                        contentItem: Text {
                            text: tableHeader.modelData + (table.sortColumn === tableHeader.index
                                ? (table.sortDir === 1 ? "  ↑" : "  ↓") : "")
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: table.sortColumn === tableHeader.index ? root.accent : root.foreground
                            font.pixelSize: Satin.type.meta
                            font.weight: Font.DemiBold
                        }
                        background: Rectangle {
                            color: "transparent"
                            radius: Satin.radius.chip
                            border.width: tableHeader.visualFocus ? 2 : 0
                            border.color: root.accent
                        }
                    }
                }
            }
            Rectangle {
                width: table.width
                height: 1
                color: root.alpha(root.foreground, Satin.keyline.hair)
            }
            TextField {
                id: tableFilter
                objectName: "aiTableFilter"
                visible: (table.block.rows || []).length >= 4
                width: Math.min(table.width, 240)
                text: table.filterText
                placeholderText: qsTr("Filter rows…")
                selectByMouse: true
                activeFocusOnTab: true
                color: root.foreground
                placeholderTextColor: root.alpha(root.foreground, 0.76)
                selectionColor: root.alpha(root.accent, 0.35)
                selectedTextColor: root.foreground
                font.pixelSize: Satin.type.meta
                onTextEdited: table.setState(table.sortColumn, table.sortDir, text)
                Accessible.name: qsTr("Filter table rows")
                background: Rectangle {
                    radius: Satin.radius.field
                    color: root.alpha(root.foreground, 0.04)
                    border.width: tableFilter.activeFocus ? 2 : 1
                    border.color: tableFilter.activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)
                }
            }
            Text {
                objectName: "aiTableCount"
                visible: table.filterText.length > 0
                text: table.viewRows.length + qsTr(" of ") + (table.block.rows || []).length + qsTr(" rows")
                textFormat: Text.PlainText
                color: root.alpha(root.foreground, 0.76)
                font.pixelSize: Satin.type.label
            }
            // The body is ONE Tab stop while the Ask gate is open (never one
            // per row): Up/Down/Home/End move the row cursor, `?` asks about
            // it. Closed, it is not focusable and looks exactly as before.
            Column {
                id: tableBody
                objectName: "aiTableRows"
                width: table.width
                spacing: Satin.space.tip
                property int cursor: 0
                readonly property int current: Math.max(0, Math.min(cursor, table.viewEntries.length - 1))
                // Always a Tab stop, but DISABLED (skipped, and focus released)
                // while the gate is closed or there is no row: Qt refuses to
                // switch activeFocusOnTab off while the item holds focus.
                activeFocusOnTab: true
                enabled: root.canFocus && table.viewEntries.length > 0
                Accessible.role: root.canFocus ? Accessible.List : Accessible.NoRole
                Accessible.name: root.canFocus ? qsTr("Table rows") : ""
                Accessible.description: root.canFocus
                    ? qsTr("Up and Down choose a row; press ? to ask about the chosen row.") : ""
                Keys.onPressed: function(event) {
                    if (!root.canFocus || table.viewEntries.length === 0) return;
                    var last = table.viewEntries.length - 1, at = tableBody.current, to = at;
                    if (event.key === Qt.Key_Question || event.text === "?") {
                        table.askAbout(at);
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Down) to = Math.min(last, at + 1);
                    else if (event.key === Qt.Key_Up) to = Math.max(0, at - 1);
                    else if (event.key === Qt.Key_Home) to = 0;
                    else if (event.key === Qt.Key_End) to = last;
                    else return;
                    // At either end the key is NOT taken, so the pane still scrolls.
                    if (to === at) return;
                    tableBody.cursor = to;
                    var row = tableRows.itemAt(to);
                    if (row) Scroll.reveal(row, 0, 0, row.width, row.height);
                    event.accepted = true;
                }
                Repeater {
                    id: tableRows
                    model: table.viewRows
                    delegate: Item {
                        id: rowHost
                        required property var modelData
                        required property int index
                        width: table.width
                        implicitHeight: tableRow.implicitHeight
                        height: implicitHeight
                        readonly property var askPart: root.canFocus ? table.askPartAt(index) : null
                        readonly property bool cursorHere: tableBody.activeFocus && tableBody.current === index
                        Rectangle {
                            visible: rowHost.cursorHere
                            anchors.fill: parent
                            anchors.margins: -2
                            radius: Satin.radius.chip
                            color: root.alpha(root.accent, 0.10)
                            border.width: 2
                            border.color: root.accent
                        }
                        Row {
                            id: tableRow
                            objectName: "aiTableRow_" + rowHost.index
                            width: table.width
                            spacing: Satin.space.gutter
                            Repeater {
                                model: table.columnCount
                                delegate: Text {
                                    required property int index
                                    width: table.cellWidth
                                    text: rowHost.modelData[index] || ""
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap
                                    color: root.foreground
                                    font.pixelSize: Satin.type.meta
                                }
                            }
                        }
                        HoverHandler { id: rowHover }
                        AiAskButton {
                            objectName: "aiTableAsk_" + rowHost.index
                            z: 2
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: rowHost.askPart !== null && (rowHover.hovered || rowHost.cursorHere || hovered)
                            subject: rowHost.askPart ? rowHost.askPart.label : ""
                            foreground: root.foreground
                            surface: root.background
                            accent: root.accent
                            onClicked: {
                                tableBody.cursor = rowHost.index;
                                table.askAbout(rowHost.index);
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: metricComponent
        Column {
            readonly property var host: parent
            property var block: host.block
            spacing: Satin.space.base
            Text {
                width: parent.width
                text: parent.block.value
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.search
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                visible: text.length > 0
                text: parent.block.detail || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.76)
                font.pixelSize: Satin.type.meta
            }
        }
    }

    Component {
        id: progressComponent
        Column {
            id: progress
            readonly property var host: parent
            property var block: host.block
            spacing: Satin.space.tip
            Text {
                width: parent.width
                text: Math.round(progress.block.value * 100) + "%"
                textFormat: Text.PlainText
                color: root.foreground
                font.pixelSize: Satin.type.search
                font.weight: Font.DemiBold
            }
            ProgressBar {
                id: bar
                objectName: "aiProgress"
                width: parent.width
                from: 0
                to: 1
                value: progress.block.value
                padding: 0
                implicitHeight: Satin.space.base * 2
                Accessible.name: progress.block.title || qsTr("Progress")
                background: Rectangle {
                    implicitHeight: Satin.space.base * 2
                    radius: Satin.space.base
                    color: root.alpha(root.foreground, Satin.keyline.hair)
                }
                contentItem: Item {
                    Rectangle {
                        width: bar.visualPosition * parent.width
                        height: parent.height
                        radius: Satin.space.base
                        color: root.accent
                    }
                }
            }
            Text {
                width: parent.width
                visible: text.length > 0
                text: progress.block.detail || ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.alpha(root.foreground, 0.76)
                font.pixelSize: Satin.type.meta
            }
        }
    }
}
