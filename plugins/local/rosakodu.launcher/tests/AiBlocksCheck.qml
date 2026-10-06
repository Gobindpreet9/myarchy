import QtQuick
import QtQuick.Controls
import QtTest
import ".." as Launcher
import "../AiFormula.js" as Formula

TestCase {
    id: testCase
    name: "AiBlocks"
    width: 660
    height: 480
    visible: true
    when: windowShown

    property var fixture: [
        {type: "text", title: "Summary", text: "<b>Literal text</b> " + "Long readable text. ".repeat(20)},
        {type: "richtext", title: "", text: "<b>Formatted</b> text with <a href='https://example.com'>an inert link</a>."},
        {type: "code", title: "Code", text: "<b>Not HTML</b>\n" + "long_identifier_".repeat(40)},
        {type: "checklist", title: "Tasks", items: ["Review " + "a long label ".repeat(8), "<b>Plain label</b>"]},
        {type: "table", title: "Comparison", columns: ["First column", "Second column"], rows: [["A wrapped " + "cell ".repeat(12), "B"], ["C", "D"]]},
        {type: "metric", title: "Count", value: "42", detail: "Illustrative fixture"},
        {type: "progress", title: "Completion", value: 0.65, detail: "Illustrative fixture"}
    ]

    Flickable {
        id: viewport
        anchors.fill: parent
        contentWidth: width
        contentHeight: renderer.implicitHeight
        clip: true
        Launcher.AiBlocks {
            id: renderer
            width: viewport.width
            foreground: "#eeeeee"
            background: "#222222"
            accent: "#88bbff"
            blocks: testCase.fixture
        }
    }

    function init() {
        testCase.width = 660;
        viewport.contentY = 0;
        renderer.blocks = fixture;
        wait(30);
    }

    function test_heightAndWrapping() {
        var wideHeight = renderer.implicitHeight;
        verify(wideHeight > 0);
        compare(renderer.height, wideHeight);
        testCase.width = 240;
        wait(30);
        verify(renderer.implicitHeight > wideHeight);
        compare(renderer.height, renderer.implicitHeight);
        var code = findChild(renderer, "aiCode");
        verify(code !== null);
        compare(code.textFormat, TextEdit.PlainText);
        verify(code.readOnly && code.selectByMouse);
        verify(code.height > 0);
        var bar = findChild(renderer, "aiProgress");
        verify(bar !== null);
        compare(bar.value, 0.65);
    }

    function test_checklistKeyboardAndScrollPersistence() {
        var box = findChild(renderer, "aiCheck_3_0");
        verify(box !== null);
        box.checked = false;
        box.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(box.checked, true);
        viewport.contentY = renderer.implicitHeight - viewport.height;
        wait(30);
        viewport.contentY = 0;
        wait(30);
        compare(findChild(renderer, "aiCheck_3_0"), box);
        compare(box.checked, true);
        box.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Return);
        compare(box.checked, false);
    }

    function test_emptyHasZeroHeight() {
        renderer.blocks = [];
        wait(30);
        compare(renderer.implicitHeight, 0);
    }

    function descendants(item) {
        var result = [];
        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i];
            result.push(child);
            result = result.concat(descendants(child));
        }
        return result;
    }

    function test_literalTextAndCodeSelection() {
        var items = descendants(renderer);
        var foundPlain = false;
        var foundRich = false;
        for (var i = 0; i < items.length; ++i) {
            if (items[i].text === fixture[0].text) {
                compare(items[i].textFormat, Text.PlainText);
                foundPlain = true;
            }
            if (items[i].text === fixture[1].text) {
                compare(items[i].textFormat, Text.RichText);
                foundRich = true;
            }
            if (items[i].text === "<b>Plain label</b>")
                compare(items[i].textFormat, Text.PlainText);
        }
        verify(foundPlain && foundRich);
        var code = findChild(renderer, "aiCode");
        code.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_A, Qt.ControlModifier);
        compare(code.selectedText, fixture[2].text);
    }

    function test_narrowSectionsDoNotOverlap() {
        testCase.width = 240;
        wait(30);
        var previousBottom = 0;
        var sectionCount = 0;
        for (var i = 0; i < renderer.children.length; ++i) {
            var section = renderer.children[i];
            if (section.modelData === undefined)
                continue;
            verify(section.y >= previousBottom);
            verify(section.height > 0);
            compare(section.width, 240);
            previousBottom = section.y + section.height;
            ++sectionCount;
        }
        compare(sectionCount, fixture.length);
        compare(renderer.implicitHeight, previousBottom);
    }

    property var learningFixture: [
        {type: "steps", title: "Season cycle", steps: [
            {label: "Orbit the Sun", detail: "One orbit takes a year."},
            {label: "Keep the tilt", detail: "The axis stays tilted."},
            {label: "Angle shifts", detail: "Seasons follow the light angle."}]},
        {type: "check", title: "Quick check", question: "Why is June warm in the north?",
         options: [
             {label: "The north leans sunward", correct: true, feedback: "The tilt, not distance."},
             {label: "Earth is closest to the Sun", correct: false, feedback: "Distance is not the cause."}],
         explanation: "Axial tilt decides the sunlight angle."},
        {type: "predict", title: "Predict", prompt: "Which hemisphere is warmer in January?",
         choices: ["Northern", "Southern"], reveal: "The Southern Hemisphere.",
         explanation: "January is southern summer."}
    ]

    SignalSpy { id: uiSpy; target: renderer; signalName: "uiStateEdited" }

    function test_stepsNavigateAndReportState() {
        renderer.blocks = [learningFixture[0]];
        renderer.uiState = ({});
        wait(30);
        uiSpy.clear();
        compare(findChild(renderer, "aiStepCount").text, "Step 1 of 3");
        var next = findChild(renderer, "aiStepNext");
        mouseClick(next, next.width / 2, next.height / 2);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][0], 0);
        compare(uiSpy.signalArguments[0][1], "step:0");
        compare(uiSpy.signalArguments[0][2], 1);
        // The host applies the state map; the view follows it.
        renderer.uiState = ({"step:0": 2});
        wait(30);
        compare(findChild(renderer, "aiStepCount").text, "Step 3 of 3");
        compare(findChild(renderer, "aiStepDetail").text, "Seasons follow the light angle.");
        uiSpy.clear();
        var prev = findChild(renderer, "aiStepPrev");
        mouseClick(prev, prev.width / 2, prev.height / 2);
        compare(uiSpy.signalArguments[0][2], 1);
        // Direct step selection is a labelled, keyboard-reachable control.
        var row = findChild(renderer, "aiStep_0_0");
        row.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(uiSpy.count, 2);
        compare(uiSpy.signalArguments[1][2], 0);
    }

    function test_checkCommitAndRetry() {
        renderer.blocks = [learningFixture[1]];
        renderer.uiState = ({});
        wait(30);
        uiSpy.clear();
        var wrong = findChild(renderer, "aiCheckOption_0_1");
        mouseClick(wrong, wrong.width / 2, wrong.height / 2);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "check:0");
        compare(uiSpy.signalArguments[0][2].selected, [1]);
        renderer.uiState = ({"check:0": {selected: [1], checked: false}});
        wait(30);
        var commit = findChild(renderer, "aiCheckCommit");
        verify(commit.visible && commit.enabled);
        mouseClick(commit, commit.width / 2, commit.height / 2);
        compare(uiSpy.count, 2);
        compare(uiSpy.signalArguments[1][2].checked, true);
        renderer.uiState = ({"check:0": {selected: [1], checked: true}});
        wait(30);
        verify(findChild(renderer, "aiCheckResult").text.indexOf("Not quite") === 0);
        verify(findChild(renderer, "aiCheckExplanation").visible);
        verify(findChild(renderer, "aiCheckRetry").visible);
        uiSpy.clear();
        var retry = findChild(renderer, "aiCheckRetry");
        mouseClick(retry, retry.width / 2, retry.height / 2);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][2].selected, []);
        compare(uiSpy.signalArguments[0][2].checked, false);
    }

    function test_predictLocksAfterCommitAndReveals() {
        renderer.blocks = [learningFixture[2]];
        renderer.uiState = ({});
        wait(30);
        uiSpy.clear();
        var choice = findChild(renderer, "aiPredictChoice_0_1");
        verify(choice.enabled);
        mouseClick(choice, choice.width / 2, choice.height / 2);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "predict:0");
        compare(uiSpy.signalArguments[0][2], 1);
        renderer.uiState = ({"predict:0": 1});
        wait(30);
        verify(!findChild(renderer, "aiPredictChoice_0_0").enabled, "predictions lock after committing");
        verify(findChild(renderer, "aiPredictReveal").visible);
        compare(findChild(renderer, "aiPredictReveal").text, "The Southern Hemisphere.");
        compare(findChild(renderer, "aiPredictExplanation").text, "January is southern summer.");
    }

    property var diagramFixture: [{
        type: "diagram", title: "Seasons schematic", caption: "Schematic, not to scale.", aspect: 1.6,
        parts: [
            {shape: "circle", x: 12, y: 34, w: 24, h: 30, label: "Sun",
             detail: "The Sun is the light source.", tone: "accent", fill: true, rotation: 0},
            {shape: "circle", x: 62, y: 36, w: 14, h: 18, label: "Earth",
             detail: "Its axis stays tilted through the orbit.", tone: "foreground", fill: false, rotation: 0},
            {shape: "line", x: 66, y: 40, w: -2, h: 22, label: "Axis", detail: "",
             tone: "muted", fill: false, rotation: 0},
            {shape: "arrow", x: 38, y: 48, w: 22, h: -8, label: "", detail: "",
             tone: "accent", fill: false, rotation: 0},
            {shape: "text", x: 4, y: 4, w: 60, h: 8, label: "June: the north leans sunward",
             detail: "", tone: "foreground", fill: false, rotation: 0}
        ]
    }]

    function test_diagramRendersSelectsAndFocuses() {
        renderer.blocks = diagramFixture;
        renderer.uiState = ({});
        wait(30);
        var canvas = findChild(renderer, "aiDiagramCanvas");
        verify(canvas !== null);
        compare(canvas.height, Math.round(canvas.width / 1.6));
        var detail = findChild(renderer, "aiDiagramDetail");
        var diagram = findChild(renderer, "aiDiagram");
        compare(detail.text, "Schematic, not to scale.");
        compare(diagram.sceneParts.length, 5);
        uiSpy.clear();
        var sun = findChild(renderer, "aiDiagramPart_0_0");
        verify(sun !== null && sun.activeFocusOnTab);
        mouseClick(sun, canvas.width * 0.2, canvas.height * 0.45);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "diagram:0");
        compare(uiSpy.signalArguments[0][2], 0);
        renderer.uiState = ({"diagram:0": 0});
        wait(30);
        verify(findChild(renderer, "aiDiagramDetail").text.indexOf("The Sun is the light source.") >= 0);
        // Decorative parts are not focusable; selectable parts are.
        var axis = findChild(renderer, "aiDiagramPart_0_2");
        verify(!axis.activeFocusOnTab);
        uiSpy.clear();
        var earth = findChild(renderer, "aiDiagramPart_0_1");
        earth.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(uiSpy.count, 1, "keyboard selection matches pointer selection");
        compare(uiSpy.signalArguments[0][2], 1);
        // The canvas keeps its aspect at narrow widths.
        testCase.width = 240;
        wait(30);
        compare(canvas.height, Math.round(canvas.width / 1.6));
    }

    function test_formulaMirrorsPythonVectors() {
        var vectors = [
            ["2*x + 1", 3, 7],
            ["2 * (x + 1) - 4 / 2", 2, 4],
            ["x ^ 2", -3, 9],
            ["x ^ 3", -2, -8],
            ["x ^ 0.5", 4, 2],
            ["x ^ 0.5", -1, null],
            ["x ^ 1000", 100, null],
            ["x ^ -1", 0, null],
            ["x ^ 0", 0, 1],
            ["min(1/x,10)", 0, null],
            ["1/(x^1000)", 100, null],
            ["sqrt(-x)^0", 1, null],
            ["min(x*x,10)", 1e200, null],
            ["2 ^ 3 ^ 2", 0, 512],
            ["-x + 5", 2, 3],
            ["x % 7", 10, 3],
            ["min(x, 5) + max(x, 2)", 4, 8],
            ["clamp(x, 0, 10)", 42, 10],
            ["clamp(x, 0, 10)", -3, 0],
            ["abs(x) + floor(x) + ceil(x)", 2.4, 7.4],
            ["round(x)", 2.5, 3],
            ["sind(x)", 90, 1],
            ["cosd(x)", 180, -1],
            ["sqrt(x)", 16, 4],
            ["pi", 0, 3.141592653589793],
            ["e", 0, 2.718281828459045]
        ];
        for (var i = 0; i < vectors.length; ++i) {
            var vector = vectors[i];
            var tree = Formula.compile(vector[0]);
            verify(tree !== null, "compiles: " + vector[0]);
            var result = Formula.evaluate(tree, vector[1]);
            if (vector[2] === null) {
                compare(result, null, "guarded: " + vector[0]);
                continue;
            }
            verify(result !== null, "compiles: " + vector[0]);
            verify(Math.abs(result - vector[2]) < 1e-9, vector[0] + " -> " + result + " expected " + vector[2]);
        }
        // Anything but arithmetic is rejected in both engines.
        ["x.__class__", "system(x)", "x;y", "[1]", "'x'", "{x}", "x=1",
         "import os", "open(x)", "x[0]", "lambda: 1", "x and y", "@x",
         "cos(x", "min(x)", "clamp(x,1)", "min(1,2,3)", "x,,1", "()",
         "１２ + x", "١٢ + x", "1.２ + x"].forEach(function(bad) {
            compare(Formula.compile(bad), null, "rejected: " + bad);
        });
        compare(Formula.evaluate(Formula.compile("sqrt(x)"), -1), null);
        compare(Formula.evaluate(Formula.compile("1 / x"), 0), null);
        compare(Formula.compile(""), null);
        compare(Formula.compile("x+".repeat(200) + "x"), null);
        compare(Formula.compile("(".repeat(40) + "x" + ")".repeat(40)), null);
        compare(Formula.formatValue(6, "°"), "6 °");
        compare(Formula.formatValue(2.50, "°"), "2.5 °");
        compare(Formula.formatValue(null, "°"), "—");
        compare(Formula.formatValue(-0.0001, ""), "0");
        compare(Formula.formatValue(100, "m", 0), "100 m");
        compare(Formula.formatValue(1e30, "m"), "1e+30 m");
        compare(Formula.formatValue(1e100, "m"), "1e+100 m");
        compare(Formula.formatValue(1e308, "m"), "1e+308 m");
    }

    property var sliderFixture: [{
        type: "slider", title: "Noon sun angle", note: "Approximate; ignores refraction.",
        control: {label: "Month", min: 0, max: 11, step: 1, value: 5, unit: "",
                  labels: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]},
        readouts: [
            {label: "Noon angle at 49N", expression: "90 - abs(x - 5.5) * 8", unit: "°"},
            {label: "Doubled", expression: "2*x", unit: ""},
            {label: "Guarded", expression: "1 / x", unit: ""}
        ]
    }]

    function test_sliderComputesLocallyAndPersists() {
        renderer.blocks = sliderFixture;
        renderer.uiState = ({});
        wait(30);
        compare(findChild(renderer, "aiSliderValue").text, "Jun");
        compare(findChild(renderer, "aiSliderReadout_0_0").text, "86 °");
        compare(findChild(renderer, "aiSliderReadout_0_1").text, "10");
        verify(findChild(renderer, "aiSliderNote").visible);
        // Keyboard scrubbing is a local computation with no model request.
        uiSpy.clear();
        var track = findChild(renderer, "aiSliderTrack");
        verify(track !== null && track.activeFocusOnTab);
        verify(track.height >= 24, "the track and handle must paint, not collapse");
        verify(track.width > 100);
        track.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "slider:0");
        compare(uiSpy.signalArguments[0][2], 6);
        // The host applies the value; the display and readouts follow.
        renderer.uiState = ({"slider:0": 6});
        wait(30);
        compare(findChild(renderer, "aiSliderValue").text, "Jul");
        compare(findChild(renderer, "aiSliderReadout_0_0").text, "86 °");
        compare(findChild(renderer, "aiSliderReadout_0_1").text, "12");
        // Home/End jump to the ends and report the change (QQC2 alone omits them).
        uiSpy.clear();
        keyClick(Qt.Key_Home);
        compare(uiSpy.count, 1, "Home reports the range minimum");
        compare(uiSpy.signalArguments[0][2], 0);
        uiSpy.clear();
        keyClick(Qt.Key_End);
        compare(uiSpy.count, 1, "End reports the range maximum");
        compare(uiSpy.signalArguments[0][2], 11);
        renderer.uiState = ({"slider:0": 0});
        wait(30);
        compare(findChild(renderer, "aiSliderValue").text, "Jan");
        compare(findChild(renderer, "aiSliderReadout_0_0").text, "46 °");
        compare(findChild(renderer, "aiSliderReadout_0_2").text, "—");
        renderer.uiState = ({"slider:0": 11});
        wait(30);
        compare(findChild(renderer, "aiSliderValue").text, "Dec");
    }

    function test_tableSortsAndFiltersLocally() {
        // The comparison table is a local tool: header clicks sort (asc,
        // desc, off) and the filter narrows rows; both are persisted state.
        renderer.uiState = ({});
        renderer.blocks = [{type: "table", title: "Options", columns: ["Option", "Cost"], rows: [
            ["Train", "40"], ["Bus", "20"], ["Car", "75"], ["Bike", "0"]]}];
        wait(30);
        var costHeader = findChild(renderer, "aiTableHeader_1");
        verify(costHeader !== null && costHeader.activeFocusOnTab);
        uiSpy.clear();
        mouseClick(costHeader, 5, 5);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "table:0");
        var emitted = uiSpy.signalArguments[0][2];
        compare(emitted.sort, 1);
        compare(emitted.dir, 1);
        renderer.uiState = ({"table:0": emitted});
        wait(30);
        // Numeric-aware ascending order: Bike (0) first.
        compare(findChild(renderer, "aiTableRow_0").children[0].text, "Bike");
        compare(findChild(renderer, "aiTableRow_3").children[0].text, "Car");
        compare(findChild(renderer, "aiTableCount").visible, false);
        // Second click: descending.
        uiSpy.clear();
        mouseClick(costHeader, 5, 5);
        compare(uiSpy.signalArguments[0][2].dir, -1);
        renderer.uiState = ({"table:0": uiSpy.signalArguments[0][2]});
        wait(30);
        compare(findChild(renderer, "aiTableRow_0").children[0].text, "Car");
        // Third click: back to the authored order.
        uiSpy.clear();
        mouseClick(costHeader, 5, 5);
        compare(uiSpy.signalArguments[0][2].sort, -1);
        renderer.uiState = ({"table:0": uiSpy.signalArguments[0][2]});
        wait(30);
        compare(findChild(renderer, "aiTableRow_0").children[0].text, "Train");
        var filter = findChild(renderer, "aiTableFilter");
        filter.forceActiveFocus(Qt.TabFocusReason);
        verify(filter.activeFocus);
        compare(filter.background.border.width, 2, "the focused filter needs a visible ring");
        uiSpy.clear();
        keyClick(Qt.Key_T);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "table:0");
        compare(uiSpy.signalArguments[0][2].filter, "t");
        // Filtering is local and reports the count; state persists with it.
        renderer.uiState = ({"table:0": {sort: -1, dir: 1, filter: "tr"}});
        wait(30);
        compare(findChild(renderer, "aiTableRow_0").children[0].text, "Train");
        verify(findChild(renderer, "aiTableCount").visible);
        compare(findChild(renderer, "aiTableCount").text, "1 of 4 rows");
        renderer.uiState = ({"table:0": {sort: -1, dir: 1, filter: "train|bus"}});
        wait(30);
        compare(findChild(renderer, "aiTableCount").text, "0 of 4 rows",
            "the filter is a literal substring, never a pattern");
    }

    property var couplingFixture: [
        {type: "diagram", title: "Tilt says", caption: "Scrub the month.", aspect: 1.6,
         parts: [
             {shape: "rect", x: 30, y: 30, w: 40, h: 8, label: "Ray", detail: "The sun ray's tilt.",
              tone: "accent", fill: true, rotation: 0},
             {shape: "circle", x: 70, y: 40, w: 14, h: 18, label: "Spot", detail: "",
              tone: "foreground", fill: false, rotation: 0}
         ]},
        {type: "slider", title: "Scrub", note: "",
         control: {label: "Month", min: 0, max: 11, step: 1, value: 0, unit: "", labels: []},
         readouts: [{label: "Tilt", expression: "x*7", unit: "°"}],
         links: [
             {part: 0, property: "rotation", expression: "x*7"},
             {part: 1, property: "x", expression: "70 - x*3"}
         ]}
    ]

    function test_sliderLinksDriveDiagramParts() {
        testCase.width = 660;
        renderer.blocks = couplingFixture;
        renderer.uiState = ({});
        wait(40);
        var rect = findChild(renderer, "aiDiagramRect_0_0");
        var circle = findChild(renderer, "aiDiagramCircle_0_1");
        verify(rect !== null && circle !== null);
        compare(rect.rotation, 0, "linked rotation starts at the slider default");
        var startX = circle.x;
        // The slider block is block index 1 in this answer.
        renderer.uiState = ({"slider:1": 5});
        wait(40);
        rect = findChild(renderer, "aiDiagramRect_0_0");
        circle = findChild(renderer, "aiDiagramCircle_0_1");
        compare(rect.rotation, 35, "scrubbing the slider updates the linked rotation");
        verify(Math.abs(circle.x - startX) > 10, "the linked x-position follows too");
        var height = rect.height;
        // Unlinked geometry stays put.
        renderer.uiState = ({"slider:1": 999});
        wait(40);
        rect = findChild(renderer, "aiDiagramRect_0_0");
        compare(rect.height, height, "unlinked geometry is untouched");
        verify(rect.rotation <= 180 && rect.rotation >= -180, "out-of-range results clamp");
    }
}
