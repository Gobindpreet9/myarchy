import QtQuick
import QtQuick.Layouts
import QtTest

// Regression guard for the Recents strip layout in LauncherPanel.qml.
//
// QQuickLayouts exclude invisible items from layout. An item whose `visible`
// binding reads its own `height` therefore collapses permanently:
// height 0 -> invisible -> excluded -> height stays 0. The strip must tie
// visibility to the SAME content condition used for its preferred height.
TestCase {
    id: testCase
    name: "RecentsStripLayout"
    width: 420
    height: 420
    visible: true

    property bool contentReady: true

    Component {
        id: circularPattern
        ColumnLayout {
            spacing: 14
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 60; color: "#222" }
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: testCase.contentReady ? 94 : 0
                visible: height > 0
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 18; color: "#333" }
            Item { Layout.fillWidth: true; Layout.fillHeight: true }
        }
    }

    Component {
        id: fixedPattern
        ColumnLayout {
            spacing: 14
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 60; color: "#222" }
            Item {
                readonly property bool showStrip: testCase.contentReady
                Layout.fillWidth: true
                Layout.preferredHeight: showStrip ? 94 : 0
                visible: showStrip
                clip: true
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 18; color: "#333" }
            Item { Layout.fillWidth: true; Layout.fillHeight: true }
        }
    }

    function test_circularVisibilityBindingCollapsesStrip() {
        var layout = circularPattern.createObject(testCase, { width: 420, height: 380 })
        verify(layout !== null)
        wait(30)
        var strip = layout.children[1]
        compare(strip.height, 0)
        layout.destroy()
    }

    function test_contentConditionBindingKeepsStripHeight() {
        var layout = fixedPattern.createObject(testCase, { width: 420, height: 380 })
        verify(layout !== null)
        wait(30)
        var strip = layout.children[1]
        compare(strip.height, 94)
        layout.destroy()
    }
}
