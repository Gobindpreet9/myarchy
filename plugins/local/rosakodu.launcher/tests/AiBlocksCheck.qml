import QtQuick
import QtQuick.Controls
import QtTest
import ".." as Launcher
import "../AiFormula.js" as Formula
import "TestJson.js" as TestJson

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

    // ---- calc block (typed computation runtime) ------------------------
    property var calcBlock: ({
        type: "calc", title: "Vendor score", note: "Illustrative <i>fixture</i> numbers.",
        inputs: [
            {id: "wq", label: "Quality <b>weight</b>", unit: "", min: 0, max: 10, step: 1, value: 3, basis: "assumption"},
            {id: "budget", label: "Budget", unit: "EUR/h", min: 0, max: 200, step: 5, value: 60, basis: "provided"}],
        tables: [{id: "opts", label: "Vendors", columns: [
                {id: "name", label: "Vendor", unit: "", kind: "text", expression: ""},
                {id: "rate", label: "Rate", unit: "EUR/h", kind: "number", expression: ""},
                {id: "quality", label: "Quality", unit: "", kind: "number", expression: ""},
                {id: "value", label: "Weighted", unit: "", kind: "formula", expression: "quality*wq"}],
            rows: [["<b>x</b> Alpha", "50", "8", ""], ["Beta", "40", "6", ""], ["Gamma", "65", "9", ""]]}],
        cells: [
            {id: "avg_rate", label: "Average rate", expression: "mean(opts.rate)", unit: "EUR/h", decimals: 2, note: "Mean of the three quotes."},
            {id: "headroom", label: "Headroom", expression: "budget-avg_rate", unit: "EUR/h", decimals: 2, note: ""},
            {id: "score", label: "Score <b>x</b>", expression: "sum(opts.value)", unit: "", decimals: 1, note: ""},
            {id: "per_point", label: "Cost per point", expression: "avg_rate/wq", unit: "EUR/h", decimals: 2, note: ""},
            {id: "weekly", label: "Per day", expression: "per_point*8[h]", unit: "EUR", decimals: 2, note: ""}]
    })

    function calcWith(change) {
        var b = JSON.parse(JSON.stringify(calcBlock));
        change(b);
        return b;
    }
    function showCalc(block, state) {
        testCase.width = 660;
        renderer.blocks = [];
        wait(10);
        renderer.uiState = state || ({});
        renderer.blocks = [block];
        wait(40);
    }
    function textsUnder(item) {
        return descendants(item).filter(function(it) { return it.text !== undefined && it.textFormat !== undefined; });
    }

    function test_calcRendersCellsTableAndBadges() {
        showCalc(calcBlock);
        var calc = findChild(renderer, "aiCalc");
        verify(calc !== null);
        compare(calc.block.type, "calc", "the binding override must not shadow block");
        compare(findChild(renderer, "aiCalcCell_0").text, "51.67 EUR/h");
        compare(findChild(renderer, "aiCalcCell_1").text, "8.33 EUR/h");
        compare(findChild(renderer, "aiCalcCell_2").text, "69.0");
        compare(findChild(renderer, "aiCalcCell_4").text, "137.78 EUR");
        compare(findChild(renderer, "aiCalcCellNote_0").text, "Mean of the three quotes.");
        compare(findChild(renderer, "aiCalcBasis_0").text, "assumption");
        compare(findChild(renderer, "aiCalcBasis_1").text, "provided");
        compare(findChild(renderer, "aiCalcUnit_1").text, "EUR/h");
        compare(findChild(renderer, "aiCalcField_1").text, "60");
        compare(findChild(renderer, "aiCalcGridHeader_1").text, "Rate (EUR/h)");
        compare(findChild(renderer, "aiCalcGridCell_0_3").text, "24.00");
        compare(findChild(renderer, "aiCalcGridCell_2_3").text, "27.00");
        compare(findChild(renderer, "aiCalcNote").text, calcBlock.note);
        verify(!findChild(renderer, "aiCalcReset").enabled, "reset needs a change");
        verify(!findChild(renderer, "aiCalcRestoreNote").visible);
        verify(!findChild(renderer, "aiCalcCellError_0").visible);
        verify(!findChild(renderer, "aiCalcProv_0").visible);
    }

    function test_calcTextIsLiteral() {
        showCalc(calcBlock);
        var calc = findChild(renderer, "aiCalc");
        var texts = textsUnder(calc), literal = 0;
        for (var i = 0; i < texts.length; ++i) {
            var t = texts[i];
            if (t.text.indexOf("<b>") >= 0 || t.text.indexOf("<i>") >= 0) {
                compare(t.textFormat, Text.PlainText, "markup stays literal: " + t.text);
                ++literal;
            }
        }
        verify(literal >= 4, "input label, cell label, table cell and note: " + literal);
        compare(findChild(renderer, "aiCalcCellLabel_2").text, "Score <b>x</b>");
        compare(findChild(renderer, "aiCalcInputLabel_0").text, "Quality <b>weight</b>");
        compare(findChild(renderer, "aiCalcGridCell_0_0").text, "<b>x</b> Alpha");
    }

    function test_calcKeyboardAndTypedEditsEmitOnce() {
        showCalc(calcBlock);
        uiSpy.clear();
        var slider = findChild(renderer, "aiCalcSlider_0");
        verify(slider.activeFocusOnTab);
        slider.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][0], 0);
        compare(uiSpy.signalArguments[0][1], "calc:0");
        verify(TestJson.equal(uiSpy.signalArguments[0][2], {wq: {v: 4, u: ""}}));
        // cells follow without waiting for the host round trip
        compare(findChild(renderer, "aiCalcCell_2").text, "92.0");
        compare(findChild(renderer, "aiCalcCell_3").text, "12.92 EUR/h");
        compare(findChild(renderer, "aiCalcField_0").text, "4");
        verify(findChild(renderer, "aiCalcReset").enabled);
        // typing: Enter commits once, out-of-range clamps, junk is reverted silently
        uiSpy.clear();
        var field = findChild(renderer, "aiCalcField_1");
        field.forceActiveFocus(Qt.TabFocusReason);
        field.selectAll();
        keyClick("8");
        keyClick("0");
        keyClick(Qt.Key_Return);
        compare(uiSpy.count, 1);
        verify(TestJson.equal(uiSpy.signalArguments[0][2], {wq: {v: 4, u: ""}, budget: {v: 80, u: "EUR/h"}}));
        compare(findChild(renderer, "aiCalcCell_1").text, "28.33 EUR/h");
        uiSpy.clear();
        field.selectAll();
        keyClick("9"); keyClick("9"); keyClick("9");
        keyClick(Qt.Key_Return);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][2].budget.v, 200, "typed values clamp to the range");
        compare(field.text, "200");
        uiSpy.clear();
        field.selectAll();
        keyClick("x");
        keyClick(Qt.Key_Return);
        compare(uiSpy.count, 0, "non-numeric text emits nothing");
        compare(field.text, "200", "and is reverted");
        // Home/End on a slider
        slider.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_End);
        compare(uiSpy.signalArguments[uiSpy.count - 1][2].wq.v, 10);
        // Reset restores the defaults and clears the key with an empty object
        uiSpy.clear();
        var reset = findChild(renderer, "aiCalcReset");
        verify(reset.enabled);
        reset.clicked();
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "calc:0");
        compare(JSON.stringify(uiSpy.signalArguments[0][2]), "{}");
        compare(findChild(renderer, "aiCalcCell_0").text, "51.67 EUR/h");
        compare(findChild(renderer, "aiCalcCell_2").text, "69.0");
        compare(findChild(renderer, "aiCalcField_1").text, "60");
        verify(!reset.enabled);
    }

    function test_calcErrorsAreNeverSilentZeros() {
        showCalc(calcBlock);
        var slider = findChild(renderer, "aiCalcSlider_0");
        slider.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Home);
        compare(findChild(renderer, "aiCalcField_0").text, "0");
        compare(findChild(renderer, "aiCalcCell_3").text, "—");
        compare(findChild(renderer, "aiCalcCell_4").text, "—");
        var own = findChild(renderer, "aiCalcCellError_3");
        verify(own.visible);
        verify(own.text.indexOf("Cannot compute: ") === 0 && own.text.length > 20, own.text);
        var detail = own.text.substring("Cannot compute: ".length);
        var waiting = findChild(renderer, "aiCalcCellError_4");
        verify(waiting.visible);
        compare(waiting.text, "Waiting on Cost per point: " + detail);
        verify(findChild(renderer, "aiCalcCell_3").Accessible.name.indexOf("no value") >= 0);
        verify(waiting.Accessible.name === waiting.text);
        // unaffected cells still compute
        compare(findChild(renderer, "aiCalcCell_0").text, "51.67 EUR/h");
        verify(!findChild(renderer, "aiCalcCellError_0").visible);
        // the failing chain is shown in the provenance of the dependant
        var toggle = findChild(renderer, "aiCalcProvToggle_4");
        toggle.clicked();
        verify(findChild(renderer, "aiCalcProv_4").visible);
        var error = findChild(renderer, "aiCalcProvError_4");
        verify(error.visible);
        verify(error.text.indexOf("Waiting on Cost per point: ") === 0);
        verify(error.text.indexOf("Failing chain: weekly → per_point") >= 0, error.text);
        // fixing the input recovers every dependant
        keyClick(Qt.Key_Right);
        compare(findChild(renderer, "aiCalcCell_4").text, "137.78 EUR".length > 0 ? findChild(renderer, "aiCalcCell_4").text : "");
        verify(!findChild(renderer, "aiCalcCellError_3").visible);
        compare(findChild(renderer, "aiCalcCell_3").text, "51.67 EUR/h");
    }

    function test_calcProvenanceDisclosureAndClickThrough() {
        showCalc(calcBlock);
        var toggle = findChild(renderer, "aiCalcProvToggle_4");
        verify(toggle !== null && toggle.activeFocusOnTab);
        compare(toggle.text, "How is this calculated?");
        toggle.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        verify(findChild(renderer, "aiCalcProv_4").visible, "Space opens the disclosure");
        compare(findChild(renderer, "aiCalcProvFormula_4").text, "Formula: per_point*8[h]");
        verify(findChild(renderer, "aiCalcProvUnit_4").text.indexOf("Result unit: EUR") === 0);
        verify(findChild(renderer, "aiCalcProvRounding_4").text.indexOf("half away from zero to 2 places: 137.78") > 0);
        var ref = findChild(renderer, "aiCalcProvRef_4_0");
        compare(ref.modelData.line, "per_point = 17.22 EUR/h  ·  calculated cell");
        verify(ref.activeFocusOnTab);
        verify(!findChild(renderer, "aiCalcProv_3").visible);
        ref.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Return);
        wait(20);
        verify(findChild(renderer, "aiCalcProv_3").visible, "a cell reference opens that cell's provenance");
        verify(findChild(renderer, "aiCalcProvToggle_3").activeFocus, "and moves focus there");
        compare(findChild(renderer, "aiCalcProvFormula_3").text, "Formula: avg_rate/wq");
        // an input reference shows its basis, and is not a tab stop
        var inputRef = findChild(renderer, "aiCalcProvRef_3_1");
        compare(inputRef.modelData.line, "wq = 3.00  ·  assumption");
        verify(!inputRef.activeFocusOnTab);
        // Esc-free close: the toggle collapses again
        toggle.clicked();
        verify(!findChild(renderer, "aiCalcProv_4").visible);
        // a table-backed cell lists the column it reads
        findChild(renderer, "aiCalcProvToggle_0").clicked();
        compare(findChild(renderer, "aiCalcProvRef_0_0").modelData.line.indexOf("opts.rate = "), 0);
    }

    function test_nestedUnitPowerDoesNotBlockTheRenderer() {
        var hostile = JSON.parse(JSON.stringify(calcBlock));
        var expression = "1[m]";
        for (var i = 0; i < 12; ++i) expression = "(" + expression + ")^9";
        hostile.cells[0].expression = expression;
        showCalc(hostile);
        var calc = findChild(renderer, "aiCalc");
        verify(calc !== null);
        compare(calc.calcResult.nodes[hostile.cells[0].id].err.code, "RANGE");
    }

    function test_calcRestoreRules() {
        // valid saved values apply; unknown ids are ignored without a note
        showCalc(calcBlock, {"calc:0": {wq: {v: 5, u: ""}, budget: {v: 80, u: "EUR/h"}, ghost: {v: 1, u: ""}}});
        compare(findChild(renderer, "aiCalcField_0").text, "5");
        compare(findChild(renderer, "aiCalcField_1").text, "80");
        compare(findChild(renderer, "aiCalcCell_2").text, "115.0");
        verify(!findChild(renderer, "aiCalcRestoreNote").visible);
        verify(findChild(renderer, "aiCalcReset").enabled);
        var rules = [
            {wq: {v: 5, u: ""}, budget: {v: 80, u: "USD/h"}},
            {wq: {v: 5, u: ""}, budget: {v: NaN, u: "EUR/h"}},
            {wq: {v: 5, u: ""}, budget: {v: 999, u: "EUR/h"}},
            {wq: {v: 5, u: ""}, budget: {v: -1, u: "EUR/h"}},
            {wq: {v: 5, u: ""}, budget: "80"},
            {wq: {v: 5, u: ""}, budget: {v: "80", u: "EUR/h"}}
        ];
        for (var i = 0; i < rules.length; ++i) {
            showCalc(calcBlock, {"calc:0": rules[i]});
            compare(findChild(renderer, "aiCalcField_1").text, "60", "rule " + i + " resets that input");
            compare(findChild(renderer, "aiCalcField_0").text, "5", "rule " + i + " keeps the valid one");
            verify(findChild(renderer, "aiCalcRestoreNote").visible, "rule " + i);
            compare(findChild(renderer, "aiCalcRestoreNote").text, "Some saved values no longer match this calculation and were reset.");
        }
        // a unit that changed in the block resets that input too
        showCalc(calcWith(function(b) { b.inputs[1].unit = "USD/h"; b.tables[0].columns[1].unit = "USD/h"; }),
                 {"calc:0": {budget: {v: 80, u: "EUR/h"}}});
        compare(findChild(renderer, "aiCalcField_1").text, "60");
        verify(findChild(renderer, "aiCalcRestoreNote").visible);
        // a stored entry that is not an object is ignored
        showCalc(calcBlock, {"calc:0": 7});
        verify(!findChild(renderer, "aiCalcRestoreNote").visible);
        compare(findChild(renderer, "aiCalcField_1").text, "60");
        // the host round trip replaces the state; the note clears once saved is clean
        showCalc(calcBlock, {"calc:0": {budget: {v: 999, u: "EUR/h"}}});
        verify(findChild(renderer, "aiCalcRestoreNote").visible);
        renderer.uiState = ({"calc:0": {}});
        wait(20);
        verify(!findChild(renderer, "aiCalcRestoreNote").visible);
        // derived values are never persisted
        uiSpy.clear();
        findChild(renderer, "aiCalcSlider_1").forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        verify(TestJson.equal(uiSpy.signalArguments[0][2], {budget: {v: 65, u: "EUR/h"}}));
    }

    function test_calcTamperedBlocksShowOneHonestLine() {
        var tampered = [
            calcWith(function(b) { b.cells[0].expression = "headroom"; b.cells[1].expression = "avg_rate"; }),
            calcWith(function(b) {
                b.inputs = [];
                for (var i = 0; i < 13; ++i) b.inputs.push({id: "i" + i, label: "I", unit: "", min: 0, max: 5, step: 1, value: 1, basis: "assumption"});
            }),
            calcWith(function(b) { b.cells[0].expression = "frobnicate(1)"; }),
            calcWith(function(b) { b.inputs[0].min = 5; b.inputs[0].max = 1; }),
            calcWith(function(b) { b.inputs[0].basis = "guess"; }),
            calcWith(function(b) { b.inputs[0].value = 50; }),
            calcWith(function(b) { b.cells = "nope"; }),
            calcWith(function(b) { b.tables[0].rows[0] = ["short"]; })
        ];
        for (var i = 0; i < tampered.length; ++i) {
            showCalc(tampered[i]);
            var line = findChild(renderer, "aiCalcInvalid");
            verify(line !== null && line.visible, "tampered " + i);
            compare(line.text, "This calculation can't be shown.");
            compare(line.textFormat, Text.PlainText);
            compare(findChild(renderer, "aiCalcReset"), null, "no partial render " + i);
            compare(findChild(renderer, "aiCalcCell_0"), null);
            compare(findChild(renderer, "aiCalcField_0"), null);
            compare(findChild(renderer, "aiCalcNote"), null);
            compare(findChild(renderer, "aiCalcGridCell_0_0"), null);
        }
        // the component recovers when a valid block replaces a tampered one
        showCalc(calcBlock);
        verify(findChild(renderer, "aiCalcInvalid").visible === false);
        compare(findChild(renderer, "aiCalcCell_0").text, "51.67 EUR/h");
    }

    function bigCalcBlock() {
        var cols = [{id: "c0", label: "Name", unit: "", kind: "text", expression: ""}], rows = [], i, j;
        for (j = 1; j <= 9; ++j) cols.push({id: "c" + j, label: "N" + j, unit: "", kind: "number", expression: ""});
        cols.push({id: "c10", label: "Sum", unit: "", kind: "formula", expression: "c1+c2"});
        cols.push({id: "c11", label: "Dbl", unit: "", kind: "formula", expression: "c3*2"});
        for (i = 0; i < 40; ++i) {
            var row = ["row" + i];
            for (j = 1; j <= 9; ++j) row.push(String(i + j));
            row.push("", "");
            rows.push(row);
        }
        return {type: "calc", title: "Big", note: "", inputs: [], cells: [
            {id: "total", label: "Total", expression: "sum(t.c10)", unit: "", decimals: 0, note: ""}],
            tables: [{id: "t", label: "Wide", columns: cols, rows: rows}]};
    }

    function test_calcTableDelegatesAreBounded() {
        showCalc(bigCalcBlock());
        var calc = findChild(renderer, "aiCalc");
        function cellCount() {
            return descendants(calc).filter(function(it) { return it.objectName.indexOf("aiCalcGridCell_") === 0; }).length;
        }
        compare(cellCount(), 12 * 12, "collapsed: the first 12 rows only");
        compare(findChild(renderer, "aiCalcGridToggle").text, "Show all 40 rows");
        compare(findChild(renderer, "aiCalcGridCell_0_10").text, "3.00");
        compare(findChild(renderer, "aiCalcGridCell_11_11").text, "28.00");
        // sum(c1+c2) over 40 rows: sum(i*2+3) = 2*780+120 = 1680
        compare(findChild(renderer, "aiCalcCell_0").text, "1680");
        var toggle = findChild(renderer, "aiCalcGridToggle");
        toggle.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        wait(30);
        compare(cellCount(), 40 * 12, "expanded: the 40 x 12 ceiling");
        verify(cellCount() <= 480);
        compare(findChild(renderer, "aiCalcGridToggle").text, "Show fewer rows");
        // the grid scrolls inside its own Flickable; the block never overflows
        var scroller = findChild(renderer, "aiCalcGridScroll");
        verify(scroller.contentWidth > scroller.width, "12 columns cannot fit 660px at 72px each");
        verify(scroller.activeFocusOnTab);
        var before = scroller.contentX;
        scroller.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_End);
        verify(scroller.contentX > before, "navigation keys scroll the grid");
        verify(calc.childrenRect.width <= calc.width + 0.5);
        // two tables stay within the same ceiling
        var two = bigCalcBlock();
        two.tables.push(JSON.parse(JSON.stringify(two.tables[0])));
        two.tables[1].id = "u";
        two.cells = [];
        for (var k = 0; k < two.tables[1].columns.length; ++k) two.tables[1].columns[k].id = "d" + k;
        for (var f = 10; f <= 11; ++f) two.tables[1].columns[f].expression = f === 10 ? "d1+d2" : "d3*2";
        showCalc(two);
        compare(descendants(findChild(renderer, "aiCalc")).filter(function(it) { return it.objectName.indexOf("aiCalcGridCell_") === 0; }).length, 2 * 12 * 12);
    }

    function test_calcFocusOrderAndContrast() {
        showCalc(calcBlock);
        var calc = findChild(renderer, "aiCalc");
        // enable Reset so it joins the chain, then open one disclosure with a cell reference
        findChild(renderer, "aiCalcSlider_0").forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        findChild(renderer, "aiCalcProvToggle_4").clicked();
        var current = findChild(renderer, "aiCalcSlider_0"), order = [];
        current.forceActiveFocus(Qt.TabFocusReason);
        for (var i = 0; i < 40 && current; ++i) {
            if (current.objectName.indexOf("aiCalc") === 0 && order.indexOf(current.objectName) < 0) order.push(current.objectName);
            current = current.nextItemInFocusChain(true);
        }
        var expected = ["aiCalcSlider_0", "aiCalcField_0", "aiCalcSlider_1", "aiCalcField_1", "aiCalcReset",
                        "aiCalcUndo", "aiCalcCopy", "aiCalcDuplicate", "aiCalcProvToggle_0", "aiCalcProvToggle_1", "aiCalcProvToggle_2", "aiCalcProvToggle_3",
                        "aiCalcProvToggle_4", "aiCalcProvRef_4_0"];
        compare(order.slice(0, expected.length).join(","), expected.join(","));
        // readable text: every visible informational Text is at or above the 0.76 floor
        findChild(renderer, "aiCalcProvToggle_0").clicked();
        var texts = textsUnder(calc), checked = 0;
        for (var j = 0; j < texts.length; ++j) {
            var t = texts[j];
            if (!t.visible || t.text.length === 0 || t.color === undefined) continue;
            verify(t.color.a >= 0.76, (t.objectName || t.text) + " alpha " + t.color.a);
            ++checked;
        }
        verify(checked > 25, "texts checked: " + checked);
        // focus rings: field and slider handle are visibly focused
        var field = findChild(renderer, "aiCalcField_1");
        field.forceActiveFocus(Qt.TabFocusReason);
        compare(field.background.border.width, 2);
    }

    property var wrappedRow: null
    // The pane hands blocks to AiBlocks through a Repeater delegate's modelData.
    Repeater {
        id: wrappedTurns
        model: []
        delegate: Item {
            required property var modelData
            Component.onCompleted: testCase.wrappedRow = modelData
        }
    }

    function test_calcRendersBlocksWrappedByTheListModelPath() {
        // Real turn rows reach AiBlocks as QML sequence/reference wrappers
        // (Array.isArray is false all the way down), not plain JS objects.
        wrappedTurns.model = [{blocks: [calcBlock]}];
        wait(20);
        var wrapped = wrappedRow.blocks;
        verify(!Array.isArray(wrapped), "the model really hands out wrapped blocks");
        verify(!Array.isArray(wrapped[0].inputs), "and the nesting is wrapped too");
        testCase.width = 660;
        renderer.blocks = [];
        wait(10);
        renderer.uiState = ({"calc:0": {budget: {v: 80, u: "EUR/h"}}});
        renderer.blocks = wrapped;
        wait(40);
        verify(findChild(renderer, "aiCalcInvalid") === null || !findChild(renderer, "aiCalcInvalid").visible);
        compare(findChild(renderer, "aiCalcCell_1").text, "28.33 EUR/h");
        compare(findChild(renderer, "aiCalcGridCell_0_3").text, "24.00");
        compare(findChild(renderer, "aiCalcField_1").text, "80");
        wrappedTurns.model = [];
    }

    function calcMetrics() {
        var calc = findChild(renderer, "aiCalc");
        return {width: calc.width, height: calc.implicitHeight, content: calc.childrenRect.width};
    }

    function test_calcNarrowAndWideHaveNoHorizontalOverflow() {
        showCalc(calcBlock);
        findChild(renderer, "aiCalcSlider_0").forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Home);   // exercises the error lines too
        findChild(renderer, "aiCalcProvToggle_4").clicked();
        var sizes = [420, 760, 320];
        for (var s = 0; s < sizes.length; ++s) {
            testCase.width = sizes[s];
            wait(40);
            var m = calcMetrics();
            compare(m.width, sizes[s]);
            verify(m.content <= m.width + 0.5, "content " + m.content + " within " + m.width);
            var texts = textsUnder(findChild(renderer, "aiCalc"));
            for (var i = 0; i < texts.length; ++i) {
                var t = texts[i];
                if (!t.visible || t.width === undefined) continue;
                var pos = t.mapToItem(findChild(renderer, "aiCalc"), 0, 0);
                var scrolled = false;
                for (var p = t.parent; p; p = p.parent) if (p.objectName.indexOf("aiCalcGridScroll") === 0) scrolled = true;
                if (!scrolled) verify(pos.x + t.width <= sizes[s] + 1, (t.objectName || t.text) + " overflows at " + sizes[s]);
            }
            verify(m.height > 100);
            console.log("calc height at width " + sizes[s] + ": " + m.height + " (errors + one disclosure open)");
        }
        showCalc(calcWith(function() {}));
        for (var w = 0; w < 2; ++w) {
            testCase.width = w === 0 ? 420 : 760;
            wait(40);
            console.log("calc height at width " + testCase.width + ": " + calcMetrics().height + " (defaults, all collapsed) open="
                + findChild(renderer, "aiCalcProv_4").visible + " err=" + findChild(renderer, "aiCalcCellError_3").visible);
        }
    }

    // ---- editable calc data through the real pane route (appended) ----------
    // AiService keeps turns in a `ListModel { dynamicRoles: true }` as
    // `append({payload: turn})`; AiAnswer copies `payload.blocks[i]` into the array it
    // gives AiBlocks. Each block is then a V4 wrapper (Array.isArray is false at every
    // level, table rows included), so AiCalc must JSON-copy before compiling.
    ListModel { id: calcTurnModel; dynamicRoles: true }
    property var modelRow: null
    Repeater {
        id: modelTurns
        model: calcTurnModel
        delegate: Item {
            required property var payload
            Component.onCompleted: testCase.modelRow = payload
        }
    }
    function calcGrid() { return findChild(renderer, "aiCalcGrid_0"); }
    function gridCell(r, c) { return findChild(calcGrid(), "aiCalcGridCell_" + r + "_" + c); }

    function test_calcEditsKeepWorkingOnTheV4WrapperRoute() {
        calcTurnModel.clear();
        calcTurnModel.append({payload: {id: "t1", blocks: [calcBlock]}});
        wait(20);
        var block = modelRow.blocks[0];
        verify(!Array.isArray(block.inputs) && !Array.isArray(block.tables) && !Array.isArray(block.tables[0].rows),
               "wrapped all the way down");
        testCase.width = 660;
        renderer.blocks = [];
        wait(10);
        renderer.uiState = ({});
        renderer.blocks = [block];
        wait(40);
        var calc = findChild(renderer, "aiCalc");
        verify(calc.valid, "a wrapped block compiles");
        var builds = calc.meter.builds;
        uiSpy.clear();
        // a table edit through the grid: exactly one emission carrying `_d`
        var scroll = findChild(calcGrid(), "aiCalcGridScroll");
        scroll.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Home, Qt.ControlModifier);
        keyClick(Qt.Key_Right);
        keyClick("9");
        keyClick(Qt.Key_Return);
        compare(uiSpy.count, 1);
        compare(uiSpy.signalArguments[0][1], "calc:0");
        verify(TestJson.equal(uiSpy.signalArguments[0][2], {_d: {opts: {e: {"0|rate": "9"}}}}));
        compare(gridCell(0, 1).text, "9");
        compare(gridCell(0, 3).text, "24.00", "quality 8 x weight 3 is untouched by the rate edit");
        compare(findChild(renderer, "aiCalcCell_0").text, "38.00 EUR/h", "mean(9, 40, 65) / 3");
        compare(calc.meter.builds, builds + 1);
        // the host answers: the same state comes back and nothing is lost
        renderer.uiState = ({"calc:0": JSON.parse(JSON.stringify(uiSpy.signalArguments[0][2]))});
        wait(20);
        compare(gridCell(0, 1).text, "9");
        compare(calc.undoStack.length, 1, "an echo keeps the undo history");
        // an input move on the same wrapper does not recompile
        findChild(renderer, "aiCalcSlider_0").forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        compare(calc.meter.builds, builds + 1);
        verify(TestJson.equal(uiSpy.signalArguments[uiSpy.count - 1][2],
                {wq: {v: 4, u: ""}, _d: {opts: {e: {"0|rate": "9"}}}}));
        // undo twice returns to the authored block and emits {}
        keyClick(Qt.Key_Z, Qt.ControlModifier);
        keyClick(Qt.Key_Z, Qt.ControlModifier);
        compare(JSON.stringify(uiSpy.signalArguments[uiSpy.count - 1][2]), "{}");
        compare(gridCell(0, 1).text, "50");
        calcTurnModel.clear();
    }

    function test_calcNarrowAndWideKeepTheGridAndScenariosInside() {
        showCalc(calcBlock, {"calc:0": {wq: {v: 5, u: ""}, _d: {opts: {e: {"2|rate": "70"}}},
            _s: [{n: "Heavy", v: {wq: {v: 9, u: ""}}}, {n: "Light", v: {wq: {v: 1, u: ""}}}, {n: "Mid <b>x</b>", v: {wq: {v: 6, u: ""}}}]}});
        findChild(renderer, "aiCalcScenariosToggle").clicked();
        wait(30);
        findChild(renderer, "aiCalcScenariosCompare").clicked();
        wait(40);
        var calc = findChild(renderer, "aiCalc");
        var sizes = [420, 760];
        for (var s = 0; s < sizes.length; ++s) {
            testCase.width = sizes[s];
            wait(60);
            var m = calcMetrics();
            compare(m.width, sizes[s]);
            verify(m.content <= m.width + 0.5, "content " + m.content + " within " + m.width);
            console.log("calc block height at width " + sizes[s] + ": " + m.height + " (edited cell, 3 scenarios, compare open)");
        }
        compare(findChild(renderer, "aiCalcScenariosColumn_3").text, "Mid <b>x</b>", "scenario names stay literal");
        compare(findChild(renderer, "aiCalcScenariosColumn_3").textFormat, Text.PlainText);
        compare(gridCell(2, 1).text, "70");
        compare(findChild(renderer, "aiCalcDiscard").text, "Discard my edits (1)");
    }
}
