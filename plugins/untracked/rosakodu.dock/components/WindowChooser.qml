import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

PanelWindow {
    id: chooser
    required property var root
    required property var dockWindow
    readonly property bool actions: root.chooserMode === "actions"
    readonly property var windowList: {
        var live = ToplevelManager.toplevels.values
        var candidates = root.activeWindowChooserItem ? root.activeWindowChooserItem.toplevels || [] : []
        return candidates.filter(function(top) { return top && live.indexOf(top) >= 0 })
    }
    onWindowListChanged: if (visible && !actions && windowList.length === 0) root.closeWindowChooser()
    readonly property var menuActions: root.activeWindowChooserItem ? [
        {label: root.activeWindowChooserItem.isPinned ? "Remove from Dock" : "Keep in Dock", action: "pin"},
        {label: "Open New Window", action: "launch"},
        {label: "Choose Window…", action: "windows"},
        {label: "Minimize", action: "minimize"}
    ] : []
    screen: dockWindow ? dockWindow.screen : null
    visible: root.isWindowChooserOpen && root.dockRevealed && !root.isVertical
    WlrLayershell.namespace: "omarchy-dock-window-chooser"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.chooserLatched ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region { item: card }
    anchors { bottom: true; left: true }
    margins.bottom: root.slotSize + root.shelfPadding * 2 + 20
    margins.left: Math.max(8, Math.min((screen ? screen.width : 2048) - implicitWidth - 8,
        root.calculatedWindowChooserLeft + root.windowChooserWidth / 2 - implicitWidth / 2))
    implicitWidth: actions ? 240 : Math.min(4, Math.max(1, windowList.length)) * 192 + 16
    implicitHeight: actions ? 196 : 194
    onVisibleChanged: if (visible && root.chooserLatched) card.forceActiveFocus()

    HyprlandFocusGrab {
        active: chooser.visible && chooser.root.chooserLatched
        windows: [chooser, chooser.dockWindow]
        onCleared: chooser.root.closeWindowChooser()
    }
    Rectangle {
        id: card
        anchors.fill: parent
        radius: 14
        color: Color.popups.background
        border.width: 1
        border.color: Util.alpha(Color.popups.text, 0.18)
        focus: true
        property int selectedIndex: 0
        Keys.onEscapePressed: chooser.root.closeWindowChooser()
        Keys.onLeftPressed: { selectedIndex = Math.max(0, selectedIndex - 1); previews.positionViewAtIndex(selectedIndex, ListView.Contain) }
        Keys.onRightPressed: { selectedIndex = Math.min(chooser.windowList.length - 1, selectedIndex + 1); previews.positionViewAtIndex(selectedIndex, ListView.Contain) }
        Keys.onDownPressed: selectedIndex = Math.min(chooser.menuActions.length - 1, selectedIndex + 1)
        Keys.onUpPressed: selectedIndex = Math.max(0, selectedIndex - 1)
        Keys.onReturnPressed: {
            if (chooser.actions) chooser.root.runAppAction(chooser.menuActions[selectedIndex].action)
            else chooser.root.selectWindowChooser(selectedIndex)
        }
        HoverHandler {
            onHoveredChanged: {
                chooser.root.isWindowChooserHovered = hovered
                if (hovered) chooser.root.holdWindowChooser()
                else chooser.root.scheduleWindowChooserDismiss()
            }
        }
        Text {
            x: 12; y: 10; width: parent.width - 24
            text: chooser.root.activeWindowChooserItem ? String(chooser.root.activeWindowChooserItem.name || chooser.root.activeWindowChooserItem.appId) : ""
            textFormat: Text.PlainText
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
        }
        Column {
            visible: chooser.actions
            x: 8; y: 34; width: parent.width - 16
            Repeater {
                model: chooser.menuActions
                Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width; height: 38; radius: 7
                    color: actionMouse.containsMouse || (card.activeFocus && card.selectedIndex === index) ? Util.alpha(Color.accent, 0.15) : "transparent"
                    Text {
                        anchors.fill: parent; anchors.leftMargin: 10
                        verticalAlignment: Text.AlignVCenter
                        text: modelData.label
                        textFormat: Text.PlainText
                        font.family: Style.font.family; font.pixelSize: 12
                        color: Color.popups.text
                    }
                    MouseArea {
                        id: actionMouse
                        anchors.fill: parent; hoverEnabled: true
                        onClicked: chooser.root.runAppAction(parent.modelData.action)
                    }
                }
            }
        }
        ListView {
            id: previews
            visible: !chooser.actions
            x: 8; y: 34; width: parent.width - 16; height: 152
            orientation: ListView.Horizontal
            spacing: 12
            clip: true
            model: chooser.windowList
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.horizontal: ScrollBar { policy: chooser.windowList.length > 4 ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded }
            delegate: Rectangle {
                id: preview
                required property var modelData
                required property int index
                width: 180; height: 144; radius: 8
                color: mouse.containsMouse ? Util.alpha(Color.accent, 0.14) : Util.alpha(Color.popups.text, 0.04)
                border.width: 1
                border.color: modelData === ToplevelManager.activeToplevel ? Color.accent : Util.alpha(Color.popups.text, 0.14)
                Item {
                    x: 4; y: 4; width: 172; height: 100; clip: true
                    Image {
                        anchors.centerIn: parent; width: 32; height: 32
                        source: chooser.root.activeWindowChooserItem ? chooser.root.resolveIcon(chooser.root.activeWindowChooserItem) : ""
                    }
                    ScreencopyView {
                        anchors.fill: parent
                        captureSource: preview.modelData
                        live: chooser.visible && !chooser.actions
                        paintCursor: false
                    }
                }
                Text {
                    x: 8; y: 110; width: parent.width - 16
                    text: String(preview.modelData ? preview.modelData.title || "Untitled window" : "Window closed")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Color.popups.text
                    font.family: Style.font.family; font.pixelSize: 11
                }
                ToolTip.visible: mouse.containsMouse
                ToolTip.delay: 700
                ToolTip.text: preview.modelData ? String(preview.modelData.title || "Untitled window") : ""
                MouseArea {
                    id: mouse
                    anchors.fill: parent; hoverEnabled: true
                    onClicked: {
                        var target = preview.modelData
                        chooser.root.activateChooserWindow(target)
                    }
                }
            }
        }
    }
}
