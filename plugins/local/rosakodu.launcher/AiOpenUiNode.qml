import QtQuick
import QtQuick.Controls
import "AiOpenUiNative.js" as Native

Item {
    id: host
    property var node: null
    property var theme: fallbackTheme
    readonly property var p: node && node.props ? node.props : ({})
    readonly property string kind: node ? Native.text(node.kind) : ""
    readonly property string nodeId: node ? Native.text(node.id) : ""
    readonly property string semanticIdentity: kind + ":" + Native.text(p._openuiHandle)
    onSemanticIdentityChanged: if (content) reset()
    readonly property bool interactive: theme.controlsEnabled && p.disabled !== true
    readonly property bool container: ["Col", "Row", "Grid", "Card", "Box", "Pressable"].indexOf(kind) >= 0
    readonly property real flex: kind === "Spacer" ? 1 : Math.max(0, Native.number(p.flex, 0))
    readonly property bool fluid: container || ["Input", "TextArea", "Slider", "Select", "RadioGroup"].indexOf(kind) >= 0 || p.block === true
    readonly property alias presentation: content.item
    objectName: "openuiNode:" + nodeId
    implicitWidth: content.item ? content.item.preferredWidth !== undefined ? content.item.preferredWidth : content.item.implicitWidth : 0
    implicitHeight: Native.length(p.height, width, content.item ? content.item.implicitHeight : 0)
    height: implicitHeight

    QtObject {
        id: fallbackTheme
        property color foreground: "#ece9e1"
        property color background: "#202124"
        property color accent: "#a8bbeb"
        property var palette: ({})
        property bool controlsEnabled: false
    }
    function emitEvent(event, value) {
        if (interactive && theme.dispatch) theme.dispatch(nodeId, event, value);
    }
    function reset() {
        // Outer mount reset is explicit; ordinary frames never reach this path.
        content.active = false;
        content.active = true;
    }
    function componentForKind() {
        if (!node) return null;
        if (container) return containerComponent;
        if (["Title", "Text", "Caption", "Label", "Badge", "Icon"].indexOf(kind) >= 0) return textComponent;
        if (kind === "Button" || kind === "IconButton") return buttonComponent;
        if (kind === "Input") return inputComponent;
        if (kind === "TextArea") return areaComponent;
        if (kind === "Slider") return sliderComponent;
        if (kind === "Checkbox") return checkboxComponent;
        if (kind === "Select") return selectComponent;
        if (kind === "SegmentedControl" || kind === "RadioGroup") return choicesComponent;
        if (kind === "Svg") return svgComponent;
        if (kind === "Divider") return dividerComponent;
        if (kind === "Spacer") return spacerComponent;
        return unsupportedComponent;
    }
    Loader {
        id: content
        width: host.width
        sourceComponent: host.componentForKind()
    }

    Component {
        id: containerComponent
        Item {
            id: group
            readonly property bool horizontal: host.kind === "Row" || host.kind === "Box" && host.p.direction === "row"
            readonly property bool grid: host.kind === "Grid"
            readonly property real padding: Native.space(host.p.padding, host.kind === "Card" ? 16 : host.kind === "Pressable" ? 12 : 0)
            readonly property real gap: Native.space(host.p.gap, grid ? 12 : horizontal ? 8 : 12)
            readonly property int columns: grid ? Math.max(1, Math.min(Math.round(Native.number(host.p.columns, 2)), 12,
                host.p.minChildWidth > 0 ? Math.floor((Math.max(0, width - padding * 2) + gap) / (host.p.minChildWidth + gap)) : 12)) : 1
            property real measuredHeight: 0
            property real naturalWidth: 0
            implicitHeight: measuredHeight + padding * 2
            implicitWidth: naturalWidth + padding * 2
            height: implicitHeight
            onWidthChanged: schedule()
            onGapChanged: schedule()
            onPaddingChanged: schedule()
            onColumnsChanged: schedule()
            onHorizontalChanged: schedule()
            Connections { target: host; function onNodeChanged() { group.sync(); } }
            Component.onCompleted: sync()
            function sync() { Native.reconcile(childrenModel, host.node ? host.node.children : []); schedule(); }
            function schedule() { Qt.callLater(arrange); }
            function arrange() {
                var items = [], inner = Math.max(0, width - padding * 2), maxNatural = 0, totalNatural = 0;
                for (var i = 0; i < childrenRepeater.count; ++i) {
                    var loader = childrenRepeater.itemAt(i);
                    if (!loader || !loader.item) continue;
                    items.push(loader);
                    var nw = Native.length(loader.spec.props.width, inner, loader.item.implicitWidth);
                    maxNatural = Math.max(maxNatural, nw);
                    totalNatural += nw;
                }
                naturalWidth = horizontal ? totalNatural + Math.max(0, items.length - 1) * gap : grid ? maxNatural * columns + (columns - 1) * gap : maxNatural;
                var x = 0, y = 0, rowHeight = 0;
                if (grid) {
                    var cellWidth = Math.max(0, (inner - (columns - 1) * gap) / columns);
                    for (i = 0; i < items.length; ++i) {
                        loader = items[i];
                        if (i > 0 && i % columns === 0) { y += rowHeight + gap; rowHeight = 0; }
                        loader.x = padding + (i % columns) * (cellWidth + gap);
                        loader.y = padding + y;
                        loader.width = cellWidth;
                        rowHeight = Math.max(rowHeight, loader.item.implicitHeight);
                    }
                    measuredHeight = y + rowHeight;
                } else if (horizontal) {
                    var weights = 0, fixed = 0, sizes = [], wrap = host.p.wrap === true;
                    for (i = 0; i < items.length; ++i) {
                        loader = items[i];
                        var explicit = Native.length(loader.spec.props.width, inner, -1);
                        var weight = loader.item.flex || (explicit < 0 && loader.item.fluid ? 1 : 0);
                        var preferred = explicit >= 0 ? explicit : Math.min(inner, loader.item.implicitWidth);
                        sizes.push({ weight: weight, preferred: preferred });
                        weights += weight;
                        if (!weight) fixed += preferred;
                    }
                    var free = Math.max(0, inner - fixed - Math.max(0, items.length - 1) * gap);
                    var shrink = !wrap && !weights && fixed > inner ? Math.max(0, (inner - Math.max(0, items.length - 1) * gap) / fixed) : 1;
                    for (i = 0; i < items.length; ++i) {
                        loader = items[i];
                        var size = sizes[i];
                        var w = size.weight ? wrap ? Math.min(inner, Math.max(160, size.preferred)) : free * size.weight / weights : size.preferred * shrink;
                        if (wrap && x > 0 && x + w > inner) { y += rowHeight + gap; x = 0; rowHeight = 0; }
                        loader.width = Math.max(0, w);
                        loader.x = padding + x;
                        loader.y = padding + y;
                        rowHeight = Math.max(rowHeight, loader.item.implicitHeight);
                        x += w + gap;
                    }
                    if (!wrap) {
                        var remaining = Math.max(0, inner - x + gap), offset = host.p.justify === "end" ? remaining : host.p.justify === "center" ? remaining / 2 : 0;
                        for (i = 0; i < items.length; ++i) {
                            loader = items[i];
                            loader.x += offset + (host.p.justify === "between" && items.length > 1 ? remaining * i / (items.length - 1) : 0);
                            loader.y += host.p.align === "start" ? 0 : host.p.align === "end" ? rowHeight - loader.item.implicitHeight : (rowHeight - loader.item.implicitHeight) / 2;
                        }
                    }
                    measuredHeight = y + rowHeight;
                } else {
                    for (i = 0; i < items.length; ++i) {
                        loader = items[i];
                        var specified = Native.length(loader.spec.props.width, inner, -1);
                        var fill = specified < 0 && (loader.item.fluid || ["Text", "Title", "Caption", "Label", "Divider", "Svg"].indexOf(loader.spec.kind) >= 0);
                        loader.width = Math.min(inner, specified >= 0 ? specified : fill ? inner : loader.item.implicitWidth);
                        loader.x = padding + (host.p.align === "center" ? (inner - loader.width) / 2 : host.p.align === "end" ? inner - loader.width : 0);
                        loader.y = padding + y;
                        // Tight pairs belong together; larger sections keep breathing room.
                        var next = items[i + 1];
                        var pairGap = host.p.gap !== undefined ? gap : next && (loader.spec.kind === "Title" || loader.spec.kind === "Label") ? 4 : gap;
                        y += loader.item.implicitHeight + (i < items.length - 1 ? pairGap : 0);
                    }
                    measuredHeight = y;
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: Native.radius(host.p.radius, host.kind === "Card" ? 12 : 7)
                color: Native.color(host.p.background, host.theme, host.kind === "Card" && host.p.variant === "soft" ? Native.alpha(host.theme.foreground, 0.06)
                    : host.kind === "Pressable" && host.p.selected ? Native.alpha(host.theme.accent, 0.12) : "transparent")
                border.width: host.kind === "Card" || host.p.border === true || host.kind === "Pressable" && (pressFocus.activeFocus || host.p.selected) ? 1 : 0
                border.color: Native.alpha(host.kind === "Pressable" ? host.theme.accent : host.theme.foreground, pressFocus.activeFocus ? 0.9 : 0.14)
            }
            FocusScope {
                id: pressFocus
                anchors.fill: parent
                activeFocusOnTab: host.kind === "Pressable" && host.interactive
                enabled: host.interactive
                Accessible.role: host.kind === "Pressable" ? Accessible.Button : Accessible.NoRole
                Accessible.name: Native.text(host.p.label || group.accessibleText())
                Accessible.checkable: host.p.selected !== undefined
                Accessible.checked: host.p.selected === true
                Keys.onSpacePressed: if (host.kind === "Pressable") host.emitEvent("click", null)
                Keys.onReturnPressed: if (host.kind === "Pressable") host.emitEvent("click", null)
                Keys.onEnterPressed: if (host.kind === "Pressable") host.emitEvent("click", null)
                TapHandler {
                    enabled: host.kind === "Pressable" && host.interactive
                    // Passive gesture: nested native controls retain their own click.
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: function(eventPoint) {
                        var point = pressFocus.mapToItem(group, eventPoint.position.x, eventPoint.position.y);
                        if (!group.controlAt(group, point.x, point.y)) host.emitEvent("click", null);
                    }
                }
            }
            function accessibleText() {
                var result = [];
                function visit(n) {
                    if (n.props && (n.props.text || n.props.label)) result.push(Native.text(n.props.text || n.props.label));
                    (n.children || []).forEach(visit);
                }
                if (host.node) visit(host.node);
                return result.join(" ").slice(0, 240) || "Select";
            }
            function controlAt(parent, x, y) {
                for (var i = parent.children.length - 1; i >= 0; --i) {
                    var child = parent.children[i];
                    if (!child.visible || !child.enabled || child === pressFocus) continue;
                    var pt = child.mapFromItem(parent, x, y);
                    if (pt.x < 0 || pt.y < 0 || pt.x > child.width || pt.y > child.height) continue;
                    if (child instanceof Control || controlAt(child, pt.x, pt.y)) return true;
                }
                return false;
            }
            ListModel { id: childrenModel }
            Repeater {
                id: childrenRepeater
                model: childrenModel
                onItemAdded: group.schedule()
                onItemRemoved: group.schedule()
                delegate: Loader {
                    id: childLoader
                    required property string nodeSpec
                    readonly property var spec: JSON.parse(nodeSpec)
                    height: item ? item.implicitHeight : 0
                    source: "AiOpenUiNode.qml"
                    onLoaded: {
                        item.node = Qt.binding(function() { return childLoader.spec; });
                        item.theme = Qt.binding(function() { return host.theme; });
                        group.schedule();
                    }
                    onNodeSpecChanged: group.schedule()
                    Connections {
                        target: childLoader.item
                        function onImplicitHeightChanged() { group.schedule(); }
                        function onImplicitWidthChanged() { group.schedule(); }
                    }
                }
            }
        }
    }
    Component {
        id: textComponent
        Item {
            // `neutral` is a surface token in the palette (foreground at 6%),
            // which made a neutral badge's own text nearly transparent. Badge
            // tones are semantic foreground colours; only their background is
            // tinted down.
            readonly property color tone: host.kind === "Badge" && (!host.p.color || host.p.color === "neutral")
                ? Native.alpha(host.theme.foreground, 0.86)
                : Native.color(host.p.color, host.theme, host.theme.foreground)
            implicitWidth: copy.implicitWidth + (host.kind === "Badge" ? 16 : 0)
            implicitHeight: copy.implicitHeight + (host.kind === "Badge" ? 8 : 0)
            height: implicitHeight
            Rectangle {
                anchors.fill: parent
                visible: host.kind === "Badge"
                radius: 6
                color: Native.alpha(tone, 0.12)
            }
            Text {
                id: copy
                x: host.kind === "Badge" ? 8 : 0
                y: host.kind === "Badge" ? 4 : 0
                width: Math.max(0, parent.width - x * 2)
                text: host.kind === "Icon" ? Native.glyph(host.p.name || host.p.icon)
                    : (host.kind === "Badge" && Native.glyph(host.p.icon)
                        ? Native.glyph(host.p.icon) + "  " + Native.text(host.p.text) : Native.text(host.p.text))
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: Math.max(1, Native.number(host.p.maxLines, 100000))
                elide: host.p.maxLines > 0 ? Text.ElideRight : Text.ElideNone
                color: host.kind === "Badge" ? parent.tone
                    : Native.color(host.p.color, host.theme, host.kind === "Caption" ? Native.alpha(host.theme.foreground, 0.80) : host.theme.foreground)
                font.pixelSize: host.kind === "Title" ? ({ sm: 15, md: 17, lg: 20, xl: 24, "2xl": 29, "3xl": 36 }[host.p.size || "md"] || 17)
                    : host.kind === "Icon" ? ({ sm: 14, md: 18, lg: 24, xl: 32 }[host.p.size || "md"] || 18)
                    : host.kind === "Caption" ? 12 : host.kind === "Badge" || host.kind === "Label" ? 13 : ({ xs: 12, sm: 13, md: 14, lg: 17 }[host.p.size || "md"] || 14)
                font.weight: host.kind === "Title" || host.p.weight === "semibold" ? Font.DemiBold : host.kind === "Label" || host.kind === "Badge" || host.p.weight === "medium" ? Font.Medium : Font.Normal
                font.italic: host.p.italic === true
                font.strikeout: host.p.lineThrough === true
                lineHeight: 1.25
                Accessible.role: host.kind === "Title" ? Accessible.Heading : Accessible.StaticText
                Accessible.name: host.kind === "Icon" ? Native.text(host.p.name || host.p.icon)
                    : host.kind === "Badge" ? Native.text(host.p.text) : text
            }
        }
    }
    Component {
        id: buttonComponent
        Button {
            id: actionButton
            objectName: "openuiControl:" + host.nodeId
            width: host.width
            implicitWidth: Math.max(host.kind === "IconButton" ? 34 : 0, buttonText.implicitWidth + 24)
            implicitHeight: host.p.size === "lg" ? 42 : host.p.size === "sm" ? 30 : 34
            enabled: host.interactive
            hoverEnabled: true
            text: host.kind === "IconButton" ? Native.glyph(host.p.icon)
                : (Native.glyph(host.p.icon) ? Native.glyph(host.p.icon) + "  " : "") + Native.text(host.p.label)
            Accessible.name: Native.text(host.p.label || host.p.icon)
            onClicked: host.emitEvent("click", null)
            Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
            Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
            contentItem: Text {
                id: buttonText
                text: actionButton.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Native.color(host.p.color, host.theme, host.p.variant === "ghost" ? host.theme.foreground : host.theme.accent)
                opacity: actionButton.enabled ? 1 : 0.38
                font.pixelSize: 13
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                radius: host.kind === "IconButton" ? height / 2 : 7
                color: actionButton.down ? Native.alpha(host.theme.accent, 0.24) : actionButton.hovered || !host.p.variant || host.p.variant === "solid" || host.p.variant === "soft" ? Native.alpha(host.theme.accent, 0.12) : "transparent"
                border.width: actionButton.visualFocus || host.p.variant === "outline" || !host.p.variant ? 1 : 0
                border.color: Native.alpha(host.theme.accent, actionButton.visualFocus ? 0.9 : 0.35)
            }
        }
    }
    Component {
        id: inputComponent
        Column {
            spacing: host.p.label ? 6 : 0
            property real preferredWidth: 200
            width: host.width
            Text {
                visible: !!host.p.label
                width: parent.width
                text: Native.text(host.p.label)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: host.theme.foreground
                font.pixelSize: 13
                Accessible.name: text
            }
            TextField {
                id: field
                property bool draftDirty: false
                objectName: "openuiControl:" + host.nodeId
                width: parent.width
                implicitHeight: 36
                enabled: host.interactive
                color: host.theme.foreground
                placeholderText: Native.text(host.p.placeholder)
                placeholderTextColor: Native.alpha(host.theme.foreground, 0.80)
                selectionColor: Native.alpha(host.theme.accent, 0.35)
                selectedTextColor: host.theme.foreground
                font.pixelSize: 14
                inputMethodHints: host.p.type === "number" ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
                Accessible.name: Native.text(host.p.label || host.p.placeholder || "Value")
                function sync() {
                    // No revision travels with a frame: while editing, only an
                    // exact echo can acknowledge the newest draft. Never replace
                    // a focused draft with a delayed older value (or move caret).
                    var incoming = Native.text(host.p.value);
                    if (text === incoming) return;
                    if (!activeFocus || !draftDirty) text = incoming;
                }
                Component.onCompleted: sync()
                Connections { target: host; function onNodeChanged() { field.sync(); } }
                onTextEdited: {
                    draftDirty = true;
                    if (host.p.type !== "number") host.emitEvent("change", text);
                    else if (text.trim() === "") host.emitEvent("change", null);
                    else {
                        var value = Number(text.replace(/,/g, ""));
                        if (isFinite(value)) host.emitEvent("change", value);
                    }
                }
                onActiveFocusChanged: if (!activeFocus) { draftDirty = false; sync(); }
                background: Rectangle {
                    radius: 7
                    color: Native.alpha(host.theme.foreground, 0.04)
                    border.width: field.activeFocus ? 2 : 1
                    border.color: Native.alpha(field.activeFocus ? host.theme.accent : host.theme.foreground, field.activeFocus ? 0.9 : 0.14)
                }
            }
        }
    }
    Component {
        id: areaComponent
        Column {
            spacing: host.p.label ? 6 : 0
            property real preferredWidth: 240
            width: host.width
            Text {
                visible: !!host.p.label
                text: Native.text(host.p.label)
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                color: host.theme.foreground
                font.pixelSize: 13
                Accessible.name: text
            }
            ScrollView {
                width: parent.width
                height: Math.max(2, Math.min(20, Math.round(Native.number(host.p.rows, 3)))) * 21 + 16
                clip: true
                TextArea {
                    id: area
                    property bool draftDirty: false
                    objectName: "openuiControl:" + host.nodeId
                    enabled: host.interactive
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    color: host.theme.foreground
                    placeholderText: Native.text(host.p.placeholder)
                    placeholderTextColor: Native.alpha(host.theme.foreground, 0.80)
                    selectionColor: Native.alpha(host.theme.accent, 0.35)
                    font.pixelSize: 14
                    Accessible.name: Native.text(host.p.label || host.p.placeholder || "Text")
                    function sync() {
                        var incoming = Native.text(host.p.value);
                        if (text === incoming) return;
                        if (!activeFocus || !draftDirty) text = incoming;
                    }
                    Component.onCompleted: sync()
                    Connections { target: host; function onNodeChanged() { area.sync(); } }
                    onTextChanged: if (activeFocus) { draftDirty = true; host.emitEvent("change", text); }
                    onActiveFocusChanged: if (!activeFocus) { draftDirty = false; sync(); }
                    background: Rectangle {
                        radius: 7
                        color: Native.alpha(host.theme.foreground, 0.04)
                        border.width: area.activeFocus ? 2 : 1
                        border.color: Native.alpha(area.activeFocus ? host.theme.accent : host.theme.foreground, area.activeFocus ? 0.9 : 0.14)
                    }
                }
            }
        }
    }
    Component {
        id: sliderComponent
        Column {
            width: host.width
            property real preferredWidth: 200
            spacing: 4
            Text {
                readonly property string valueText: Native.quantity(range.value, host.p.unit)
                visible: !!host.p.label || !!host.p.unit
                width: parent.width
                text: Native.text(host.p.label) + (host.p.label ? "  ·  " : "") + valueText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: host.theme.foreground
                font.pixelSize: 13
                Accessible.name: Native.text(host.p.label) ? Native.text(host.p.label) + ", " + valueText : valueText
            }
            Slider {
                id: range
                objectName: "openuiControl:" + host.nodeId
                width: parent.width
                implicitHeight: 30
                enabled: host.interactive
                from: Native.number(host.p.min, 0)
                to: Math.max(from + 0.000001, Native.number(host.p.max, from + 100))
                stepSize: Math.max(0.000001, Native.number(host.p.step, 1))
                value: Native.number(host.p.value, from)
                Accessible.name: Native.text(host.p.label || "Value")
                onMoved: host.emitEvent("change", value)
                background: Rectangle {
                    x: range.leftPadding
                    y: range.topPadding + range.availableHeight / 2 - height / 2
                    width: range.availableWidth
                    height: 4
                    radius: 2
                    color: Native.alpha(host.theme.foreground, 0.14)
                    Rectangle { width: range.visualPosition * parent.width; height: parent.height; radius: 2; color: host.theme.accent }
                }
                handle: Rectangle {
                    x: range.leftPadding + range.visualPosition * (range.availableWidth - width)
                    y: range.topPadding + range.availableHeight / 2 - height / 2
                    width: 18; height: 18; radius: 9
                    color: host.theme.accent
                    border.width: range.visualFocus ? 2 : 0
                    border.color: host.theme.foreground
                }
            }
            Item {
                id: markLabels
                readonly property var marks: host.p.marks || []
                width: parent.width
                implicitHeight: marks.length > 0 ? 16 : 0
                visible: marks.length > 0
                Repeater {
                    model: markLabels.marks
                    delegate: Text {
                        required property var modelData
                        required property int index
                        readonly property real fraction: Math.max(0, Math.min(1,
                            (Native.number(modelData.value, range.from) - range.from) / (range.to - range.from)))
                        objectName: "openuiMark:" + host.nodeId + ":" + index
                        x: (markLabels.width - width) * fraction
                        width: implicitWidth
                        height: markLabels.implicitHeight
                        text: Native.text(modelData.label)
                        textFormat: Text.PlainText
                        color: Native.alpha(host.theme.foreground, 0.80)
                        font.pixelSize: 12
                        horizontalAlignment: fraction <= 0 ? Text.AlignLeft
                            : fraction >= 1 ? Text.AlignRight : Text.AlignHCenter
                    }
                }
            }
        }
    }
    Component {
        id: checkboxComponent
        CheckBox {
            id: check
            objectName: "openuiControl:" + host.nodeId
            width: host.width
            implicitWidth: checkText.implicitWidth + 32
            implicitHeight: Math.max(34, checkText.implicitHeight + 8)
            enabled: host.interactive
            checked: host.p.checked === true
            text: Native.text(host.p.label)
            Accessible.name: text
            property bool keyboardToggling: false
            function keyToggle() {
                keyboardToggling = true;
                toggle();
                keyboardToggling = false;
                host.emitEvent("change", checked);
            }
            onToggled: if (!keyboardToggling) host.emitEvent("change", checked)
            Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) keyToggle(); event.accepted = true; }
            Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) keyToggle(); event.accepted = true; }
            indicator: Rectangle {
                x: 0; y: (check.height - height) / 2
                width: 19; height: 19; radius: 5
                color: check.checked ? Native.alpha(host.theme.accent, 0.2) : "transparent"
                border.width: check.visualFocus ? 2 : 1
                border.color: check.checked || check.visualFocus ? host.theme.accent : Native.alpha(host.theme.foreground, 0.5)
                Text { anchors.centerIn: parent; text: check.checked ? "✓" : ""; textFormat: Text.PlainText; color: host.theme.accent; font.pixelSize: 15 }
            }
            contentItem: Text {
                id: checkText
                leftPadding: 29
                text: check.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                verticalAlignment: Text.AlignVCenter
                color: host.theme.foreground
                font.pixelSize: 14
                font.strikeout: check.checked && host.p.lineThrough === true
            }
        }
    }
    Component {
        id: selectComponent
        Column {
            id: selectField
            width: host.width
            property real preferredWidth: 200
            spacing: host.p.label ? 6 : 0
            property string optionKey: ""
            function sync() {
                var choices = Native.options(host.p.options), key = JSON.stringify(choices);
                if (key !== optionKey) { optionKey = key; select.model = choices; }
                var selected = -1;
                for (var i = 0; i < choices.length; ++i) if (choices[i].value === Native.text(host.p.value)) selected = i;
                select.currentIndex = selected;
            }
            Component.onCompleted: sync()
            Connections { target: host; function onNodeChanged() { selectField.sync(); } }
            Text {
                visible: !!host.p.label
                width: parent.width
                text: Native.text(host.p.label)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: host.theme.foreground
                font.pixelSize: 13
                Accessible.name: text
            }
            ComboBox {
                id: select
                objectName: "openuiControl:" + host.nodeId
                width: parent.width
                implicitHeight: 36
                enabled: host.interactive
                textRole: "label"
                valueRole: "value"
                Accessible.name: Native.text(host.p.label || host.p.placeholder || "Choose")
                onActivated: host.emitEvent("change", currentValue)
                contentItem: Text {
                    text: select.currentIndex >= 0 ? select.currentText : Native.text(host.p.placeholder || "Choose…")
                    textFormat: Text.PlainText
                    color: host.theme.foreground
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    leftPadding: 10
                    rightPadding: 24
                    font.pixelSize: 14
                }
                delegate: ItemDelegate {
                    required property var modelData
                    required property int index
                    width: select.width
                    contentItem: Text { text: Native.text(modelData.label); textFormat: Text.PlainText; color: host.theme.foreground; font.pixelSize: 14; wrapMode: Text.Wrap }
                    background: Rectangle { color: parent.highlighted ? Native.alpha(host.theme.accent, 0.16) : host.theme.background }
                    highlighted: select.highlightedIndex === index
                }
                background: Rectangle {
                    radius: 7
                    color: Native.alpha(host.theme.foreground, 0.04)
                    border.width: select.visualFocus ? 2 : 1
                    border.color: Native.alpha(select.visualFocus ? host.theme.accent : host.theme.foreground, select.visualFocus ? 0.9 : 0.14)
                }
            }
        }
    }
    Component {
        id: choicesComponent
        Column {
            id: choicesField
            width: host.width
            property real preferredWidth: 240
            spacing: host.p.label ? 7 : 0
            function sync() {
                var choices = Native.options(host.p.options).map(function(option, i) { return { id: option.value + ":" + i, props: option }; });
                Native.reconcile(choiceModel, choices);
            }
            Component.onCompleted: sync()
            Connections { target: host; function onNodeChanged() { choicesField.sync(); } }
            ListModel { id: choiceModel }
            Text {
                visible: !!host.p.label
                width: parent.width
                text: Native.text(host.p.label)
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Native.alpha(host.theme.foreground, 0.88)
                font.pixelSize: 13
                font.weight: Font.Medium
                Accessible.name: text
            }
            Flow {
                width: parent.width
                spacing: 6
                Accessible.role: Accessible.Grouping
                Accessible.name: Native.text(host.p.label || "Choices")
                Repeater {
                    model: choiceModel
                    delegate: RadioButton {
                        id: choice
                        required property string nodeSpec
                        required property int index
                        readonly property var option: JSON.parse(nodeSpec).props
                        // A RadioGroup defaults to a vertical list. "pills" and a
                        // SegmentedControl are visibly bounded choices; otherwise
                        // unselected controls looked like plain sentences.
                        readonly property bool list: host.kind === "RadioGroup" && host.p.variant !== "pills" && host.p.variant !== "cards"
                        readonly property bool grouped: host.kind === "SegmentedControl"
                        readonly property bool cards: host.kind === "RadioGroup" && host.p.variant === "cards"
                        readonly property bool fill: list || cards || host.p.block === true
                        objectName: "openuiChoice:" + host.nodeId + ":" + index
                        width: fill ? (cards || list ? parent.width : parent.width / Math.max(1, choiceModel.count) - 6) : Math.min(parent.width, implicitWidth)
                        implicitWidth: Math.min(parent ? parent.width : 240, optionText.implicitWidth + (list ? 24 : 26))
                        implicitHeight: Math.max(list ? 30 : 34, optionText.implicitHeight + (list ? 6 : 14))
                        hoverEnabled: true
                        enabled: host.interactive
                        checked: Native.text(host.p.value) === option.value
                        autoExclusive: false
                        leftPadding: list ? 2 : 12
                        rightPadding: list ? 2 : 12
                        topPadding: list ? 3 : 7
                        bottomPadding: list ? 3 : 7
                        Accessible.name: option.label
                        Accessible.description: option.description
                        onClicked: host.emitEvent("change", option.value)
                        Keys.onReturnPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
                        Keys.onEnterPressed: event => { if (enabled && !event.isAutoRepeat) clicked(); event.accepted = true; }
                        indicator: null
                        contentItem: Text {
                            id: optionText
                            text: (choice.list ? choice.checked ? "●  " : "○  " : "") + choice.option.label
                                + (choice.option.description ? "\n" + choice.option.description : "")
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: choice.checked ? host.theme.accent : host.theme.foreground
                            font.pixelSize: 13
                            font.weight: choice.checked ? Font.Medium : Font.Normal
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: choice.list ? 6 : choice.cards ? 9 : 999
                            color: choice.checked ? Native.alpha(host.theme.accent, 0.14)
                                : choice.list ? (choice.hovered ? Native.alpha(host.theme.foreground, 0.045) : "transparent")
                                : Native.alpha(host.theme.foreground, choice.hovered ? 0.075 : 0.035)
                            border.width: choice.visualFocus ? 2 : choice.list ? (choice.checked ? 1 : 0) : 1
                            border.color: Native.alpha(choice.checked || choice.visualFocus ? host.theme.accent : host.theme.foreground,
                                choice.visualFocus ? 0.9 : choice.checked ? 0.55 : 0.16)
                        }
                    }
                }
            }
        }
    }
    Component { id: svgComponent; AiOpenUiSvg { node: host.node; theme: host.theme; width: host.width } }
    Component { id: dividerComponent; Rectangle { implicitWidth: 1; implicitHeight: 1; color: Native.alpha(host.theme.foreground, 0.14) } }
    Component { id: spacerComponent; Item { implicitWidth: 0; implicitHeight: 0 } }
    Component {
        id: unsupportedComponent
        Text {
            text: "Unsupported component: " + host.kind
            textFormat: Text.PlainText
            width: host.width
            wrapMode: Text.Wrap
            color: host.theme.foreground
            font.pixelSize: 13
            Accessible.name: text
        }
    }
}
