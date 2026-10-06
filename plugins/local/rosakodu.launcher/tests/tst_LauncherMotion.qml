import QtQuick
import QtTest
import "../LauncherMotion.js" as LauncherMotion

TestCase {
    name: "LauncherMotion"

    function test_dockPayloadKeepsOutputFractionsAndEdge() {
        var context = LauncherMotion.openContext(
            '{"source":"dock","intent":"toggle","originFX":0.5,"originFY":0.92,"edge":"bottom"}')
        compare(context.source, "dock")
        compare(context.intent, "toggle")
        verify(context.hasOrigin)
        compare(context.originFX, 0.5)
        compare(context.originFY, 0.92)
        compare(context.edge, "bottom")
    }

    function test_emptyPayloadUsesKeyboardMotion() {
        var context = LauncherMotion.openContext("")
        compare(context.source, "keyboard")
        compare(context.intent, "")
        verify(!context.hasOrigin)
    }

    function test_invalidDockOriginFallsBackToKeyboardMotion() {
        var malformed = LauncherMotion.openContext("not json")
        compare(malformed.source, "keyboard")
        verify(!malformed.hasOrigin)

        var missing = LauncherMotion.openContext('{"source":"dock","originFX":0.5}')
        compare(missing.source, "keyboard")
        verify(!missing.hasOrigin)

        // Out-of-range fractions are rejected instead of drawing off-screen.
        var outOfRange = LauncherMotion.openContext('{"source":"dock","originFX":1.4,"originFY":0.5}')
        compare(outOfRange.source, "keyboard")
        verify(!outOfRange.hasOrigin)
    }

    function test_keyboardIntentToggleIsNotUsedForSuper() {
        // Bare Super closes through the launcher's own toggle endpoint, so
        // its summon payload must not carry pointer-toggle semantics.
        var context = LauncherMotion.openContext('{"source":"keyboard"}')
        compare(context.intent, "")
        compare(context.source, "keyboard")
    }
}
