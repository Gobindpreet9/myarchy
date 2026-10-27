import QtQuick
import QtQuick.Controls
import QtTest
import "../.."

Item {
    width: 1000
    height: 1600
    AiOpenUiView {
        id: surface
        width: 420
        height: implicitHeight
    }
    SignalSpy { id: events; target: surface; signalName: "eventRequested" }
    TestCase {
        name: "AiOpenUiNative"
        when: windowShown

        function n(id, kind, props, children) {
            return { id: id, kind: kind, props: props || {}, children: children || [] };
        }
        function mount(children) {
            surface.tree = n("root", "Col", {}, children);
            tryVerify(function() { return surface.implicitHeight > 0; });
            wait(10);
        }
        function control(id) { return findChild(surface, "openuiControl:" + id); }
        function init() {
            failOnWarning(/.*/);
            surface.tree = null;
            surface.reset();
            surface.enabled = true;
            surface.busy = false;
            surface.width = 420;
            events.clear();
        }
        function cleanup() { surface.tree = null; wait(0); }

        function test_labelledInputKeyboardAndStaleFrames() {
            mount([n("input", "Input", { label: "Name", value: "A" }), n("status", "Text", { text: "Ready" })]);
            var field = control("input");
            verify(field !== null);
            compare(field.Accessible.name, "Name");
            field.forceActiveFocus();
            keyClick(Qt.Key_End);
            keyClick(Qt.Key_B);
            compare(field.text, "Ab");
            compare(events.count, 1);
            compare(events.signalArguments[0][0], "input");
            compare(events.signalArguments[0][1], "change");
            compare(events.signalArguments[0][2], "Ab");
            var caret = field.cursorPosition;
            surface.tree = n("root", "Col", {}, [n("input", "Input", { label: "Name", value: "Ab" }), n("status", "Text", { text: "Saved" })]);
            wait(10);
            verify(control("input") === field, "same control survives an acknowledgement");
            verify(field.activeFocus);
            compare(field.cursorPosition, caret);
            keyClick(Qt.Key_C);
            compare(field.text, "Abc");
            surface.tree = n("root", "Col", {}, [n("input", "Input", { label: "Name", value: "A" }), n("status", "Text", { text: "Older acknowledgement" })]);
            wait(10);
            compare(field.text, "Abc");
            compare(field.cursorPosition, caret + 1);
            compare(events.count, 2, "frame updates never emit changes");
        }

        function test_changedSemanticBindingCannotKeepAnotherInputsFocusedDraft() {
            mount([n("root/0", "Input", {label: "A", value: "A", _openuiHandle: "binding-a"})]);
            var first = control("root/0");
            first.forceActiveFocus();
            keyClick(Qt.Key_End);
            keyClick(Qt.Key_B);
            compare(first.text, "Ab");
            surface.tree = n("root", "Col", {}, [n("root/0", "Input", {label: "B", value: "Bee", _openuiHandle: "binding-b"})]);
            wait(10);
            var second = control("root/0");
            verify(second !== first, "the positional slot no longer represents the same bound variable");
            compare(second.text, "Bee");
            verify(!second.activeFocus, "focus cannot silently retarget another input");
        }

        function test_returnAndKeypadEnterActivateNativeChoicesAndButtons() {
            mount([n("button", "Button", {label: "Go", hasAction: true}),
                n("check", "Checkbox", {label: "Ready", checked: false}),
                n("choices", "SegmentedControl", {value: "a", options: ["a", "b"]})]);
            var button = control("button");
            button.forceActiveFocus();
            keyClick(Qt.Key_Enter);
            compare(events.count, 1);
            compare(events.signalArguments[0][1], "click");
            control("check").forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(events.count, 2);
            compare(events.signalArguments[1][2], true);
            keyClick(Qt.Key_Enter);
            compare(events.count, 3);
            compare(events.signalArguments[2][2], false, "rapid toggles use the immediate native checked state");
            var option = findChild(surface, "openuiChoice:choices:1");
            option.forceActiveFocus();
            keyClick(Qt.Key_Enter);
            compare(events.count, 4);
            compare(events.signalArguments[3][2], "b");
        }
        function test_numericDraftKeepsPartialAndSendsTypedValues() {
            mount([n("number", "Input", { label: "Amount", type: "number", value: 4 })]);
            var field = control("number");
            field.forceActiveFocus();
            keyClick(Qt.Key_A, Qt.ControlModifier);
            keyClick(Qt.Key_Minus);
            compare(events.count, 0, "partial numeric drafts are not sent as invalid strings");
            surface.tree = n("root", "Col", {}, [n("number", "Input", { label: "Amount", type: "number", value: 4 })]);
            wait(10);
            compare(field.text, "-");
            keyClick(Qt.Key_A, Qt.ControlModifier);
            keyClick(Qt.Key_7);
            compare(events.count, 1);
            compare(events.signalArguments[0][2], 7);
            keyClick(Qt.Key_Backspace);
            compare(events.count, 2);
            compare(events.signalArguments[1][2], null);
        }
        function test_textAreaPlainDraftAndCaret() {
            mount([n("area", "TextArea", { label: "Notes", value: "Text", rows: 2 })]);
            var area = control("area");
            area.forceActiveFocus();
            keyClick(Qt.Key_End);
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_X);
            compare(area.text, "Text\nx");
            compare(events.count, 2);
            surface.tree = n("root", "Col", {}, [n("area", "TextArea", { label: "Notes", value: "Text\n", rows: 2 })]);
            wait(10);
            verify(control("area") === area);
            verify(area.activeFocus);
            compare(area.text, "Text\nx");
        }
        function test_sliderKeyboardAndClickToggleChoices() {
            mount([
                n("range", "Slider", { label: "Length", min: 0, max: 10, step: 1, value: 4 }),
                n("button", "Button", { label: "Apply", action: true }),
                n("check", "Checkbox", { label: "Include", checked: false }),
                n("segments", "SegmentedControl", { value: "a", options: ["a", { value: "b", label: "Choice B" }] }),
                n("radio", "RadioGroup", { label: "Mode", value: "first", options: ["first", "second"], variant: "cards" })
            ]);
            var range = control("range");
            range.forceActiveFocus();
            keyClick(Qt.Key_Right);
            compare(events.count, 1);
            compare(events.signalArguments[0][2], 5);
            mouseClick(control("button"));
            compare(events.signalArguments[1][1], "click");
            compare(events.signalArguments[1][0], "button");
            mouseClick(control("check"));
            compare(events.signalArguments[2][2], true);
            mouseClick(findChild(surface, "openuiChoice:segments:1"));
            compare(events.signalArguments[3][2], "b");
            mouseClick(findChild(surface, "openuiChoice:radio:1"));
            compare(events.signalArguments[4][2], "second");
        }
        function test_selectKeyboard() {
            mount([n("select", "Select", { label: "Choice", value: "a", options: ["a", { value: "b", label: "Bee" }] })]);
            var select = control("select");
            compare(select.currentText, "a");
            select.forceActiveFocus();
            keyClick(Qt.Key_Down);
            compare(events.count, 1);
            compare(events.signalArguments[0][2], "b");
            var frame = n("root", "Col", {}, [n("select", "Select", { label: "Choice", value: "b", options: ["a", { value: "b", label: "Bee" }] })]);
            surface.tree = frame;
            wait(10);
            verify(control("select") === select);
            compare(select.currentText, "Bee");
        }
        function test_disabledBusyAndUnsupportedAreExplicit() {
            mount([n("button", "Button", { label: "Apply" }), n("unsupported", "Markdown", { text: "Not rendered as rich text" })]);
            surface.busy = true;
            compare(control("button").enabled, false);
            mouseClick(control("button"));
            compare(events.count, 0);
            var unsupported = findChild(surface, "openuiNode:unsupported");
            compare(unsupported.presentation.text, "Unsupported component: Markdown");
        }
        function test_responsiveGridAndPersistentReorder() {
            var children = [];
            for (var i = 0; i < 4; ++i) children.push(n("card" + i, "Card", {}, [n("name" + i, "Text", { text: "Card " + i })]));
            surface.tree = n("grid", "Grid", { columns: 3, minChildWidth: 240 }, children);
            tryVerify(function() { return surface.implicitHeight > 0; });
            var grid = surface.rootNode.presentation;
            compare(grid.columns, 1);
            var first = findChild(surface, "openuiNode:card0");
            var last = findChild(surface, "openuiNode:card3");
            verify(first !== null && last !== null);
            var narrowHeight = surface.implicitHeight;
            surface.width = 760;
            tryCompare(grid, "columns", 3);
            tryVerify(function() { return surface.implicitHeight < narrowHeight; });
            surface.width = 980;
            tryCompare(grid, "columns", 3);
            children = [children[3], children[0], children[1], children[2]];
            surface.tree = n("grid", "Grid", { columns: 3, minChildWidth: 240 }, children);
            wait(10);
            verify(findChild(surface, "openuiNode:card0") === first);
            verify(findChild(surface, "openuiNode:card3") === last);
            verify(last.parent.x < first.parent.x);
        }
        function test_pressableKeyboardAndNestedControl() {
            mount([n("tile", "Pressable", { selected: true }, [n("tileText", "Text", { text: "Tile" }), n("nested", "Button", { label: "Nested" })])]);
            var tile = findChild(surface, "openuiNode:tile").presentation;
            var focus = tile.children[1];
            focus.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(events.count, 1);
            compare(events.signalArguments[0][0], "tile");
            mouseClick(control("nested"));
            compare(events.count, 2, "nested button must not invoke its pressable parent");
            compare(events.signalArguments[1][0], "nested");
        }
        function test_resetStartsANewMount() {
            mount([n("input", "Input", { value: "A", label: "Name" })]);
            var original = control("input");
            original.forceActiveFocus();
            keyClick(Qt.Key_End);
            keyClick(Qt.Key_B);
            surface.reset();
            wait(10);
            compare(control("input").text, "A");
            verify(control("input") !== original);
        }
        function test_svgAllShapesViewBoxAndTransforms() {
            surface.tree = n("drawing", "Svg", { viewBox: "-20 -10 240 120" }, [
                n("group", "G", { transform: "translate(10 0) rotate(20 80 40) scale(1 0.9)", opacity: 0.8 }, [
                    n("circle", "Circle", { cx: 20, cy: 30, r: 10, fill: "accent" }),
                    n("ellipse", "Ellipse", { cx: 60, cy: 30, rx: 15, ry: 8, stroke: "warning" }),
                    n("rect", "Rect", { x: 85, y: 20, width: 30, height: 20, rx: 4, fill: "success" }),
                    n("line", "Line", { x1: 0, y1: 60, x2: 180, y2: 70, stroke: "foreground" }),
                    n("gear", "Path", { d: "M 120 60 l 5 -5 10 0 5 5 0 10 -5 5 -10 0 -5 -5 Z M 125 65 a 5 5 0 1 0 10 0 a 5 5 0 1 0 -10 0", fill: "accent" }),
                    n("polyline", "Polyline", { points: "10,80 30,60 50,80", stroke: "#c0a0ff" }),
                    n("polygon", "Polygon", { points: "65,80 75,60 85,80", fill: "pink" }),
                    n("caption", "SvgText", { x: 90, y: 105, text: "Illustrative lever", anchor: "middle", fill: "ink" })
                ])
            ]);
            tryVerify(function() { return surface.implicitHeight > 0; });
            compare(surface.implicitHeight, 180);
            var svg = surface.rootNode.presentation;
            compare(svg.drawingWidth, 360);
            compare(svg.zoom, 1.5);
            wait(30);
            verify(grabImage(surface).width > 0);
            surface.width = 280;
            tryCompare(svg, "drawingWidth", 280);
            compare(surface.implicitHeight, 140);
        }
        function test_plainTextNeverInterpretsMarkup() {
            mount([n("text", "Text", { text: "<img src='https://example.com'>**plain**" })]);
            var textNode = findChild(surface, "openuiNode:text");
            compare(textNode.presentation.children[1].textFormat, Text.PlainText);
        }
    }
}
