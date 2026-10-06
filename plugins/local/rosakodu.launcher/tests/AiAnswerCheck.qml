import QtQuick
import QtTest
import ".." as Launcher
import "../AiState.js" as AiState

TestCase {
    id: tests
    name: "AiAnswer"
    width: 760
    height: 900
    visible: true
    when: windowShown

    // Illustrative prose and image only, not claims about a real subject.
    property var illustrativeTurn: ({
        id: 17,
        prompt: "Illustrative prompt, never a duplicate heading",
        answer: "Illustrative answer: a short, readable overview accompanies the figure. "
            + "The full subject remains visible, and supporting details follow below.",
        status: "done",
        blocks: [
            {type: "sources", items: [{label: "Illustrative reference", url: "https://example.com/reference"}]},
            {type: "checklist", title: "Illustrative preparation", items: ["Review the example"]},
            {type: "image", query: "Illustrative portrait, not evidence", imageUrl: "file:///tmp/opencode/ai-answer-portrait.png",
                attribution: "Illustrative local fixture", sourceUrl: "https://example.com/photo"},
            {type: "text", title: "Illustrative detail", text: "Supporting example text stays below the introductory composition."},
            {type: "checklist", title: "Illustrative follow-up", items: ["Save the example"]}
        ]
    })

    Flickable {
        id: viewport
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: renderer.responseHeight
        Rectangle {
            id: surface
            width: viewport.width
            height: renderer.implicitHeight
            color: "#202124"
            Launcher.AiAnswer {
                id: renderer
                width: surface.width
                turn: null
                title: "Illustrative subject"
                foreground: "#f4f4f5"
                background: surface.color
                accent: "#e4e4e7"
                mediaRoot: "/tmp/opencode"
                checkedState: ({"1:0": true, "4:0": false})
            }
        }
    }
    SignalSpy { id: checkSpy; target: renderer; signalName: "checkChanged" }
    SignalSpy { id: sourceSpy; target: renderer; signalName: "openUrl" }
    SignalSpy { id: uiStateSpy; target: renderer; signalName: "uiStateEdited" }

    Component {
        id: restoredAnswerComponent
        Launcher.AiAnswer {
            property int stateEditCount: 0
            foreground: "#f4f4f5"
            background: "#202124"
            accent: "#e4e4e7"
            mediaRoot: "/tmp/opencode"
            onUiStateEdited: ++stateEditCount
        }
    }

    // Qt writes real raster bytes to the trusted local fixture directory.
    Rectangle {
        id: portraitFixture
        x: 900
        width: 240
        height: 400
        color: "#d9d7d2"
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 52
            width: 80
            height: 80
            radius: 40
            color: "#858b8b"
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 148
            width: 128
            height: 210
            radius: 28
            color: "#858b8b"
        }
        Rectangle { width: parent.width; height: 6; color: "#f4f4f5" }
        Rectangle { y: parent.height - height; width: parent.width; height: 6; color: "#f4f4f5" }
    }

    function initTestCase() {
        var saved = false;
        verify(portraitFixture.grabToImage(function(result) {
            saved = result.saveToFile("/tmp/opencode/ai-answer-portrait.png");
        }));
        tryVerify(function() { return saved; });
    }

    function init() {
        tests.width = 760;
        viewport.contentY = 0;
        renderer.turn = null;
        renderer.title = "Illustrative subject";
        renderer.turnIndex = 0;
        renderer.showText = false;
        renderer.mediaRoot = "/tmp/opencode";
        renderer.checkedState = ({"1:0": true, "4:0": false});
        renderer.uiState = null;
        renderer.turn = illustrativeTurn;
        checkSpy.clear();
        sourceSpy.clear();
        uiStateSpy.clear();
        tryCompare(image(), "imageStatus", Image.Ready);
        wait(30);
    }

    function image() { return findChild(renderer, "aiImage"); }
    function heading() { return findChild(renderer, "aiAnswerTitle"); }
    function summary() { return findChild(renderer, "aiAnswerSummary"); }
    function hero() { return findChild(renderer, "aiAnswerHero"); }
    function nativeBlocks() { return findChild(renderer, "aiNativeBlocks_" + renderer.turnIndex); }

    function capture(name) {
        var saved = false;
        verify(surface.grabToImage(function(result) {
            saved = result.saveToFile("/tmp/opencode/ai-answer-" + name + ".png");
        }));
        tryVerify(function() { return saved; });
    }

    function test_portraitRightWideAndStackedNarrow() {
        for (var width of [760, 420]) {
            tests.width = width;
            wait(30);
            var photo = image();
            var copy = findChild(renderer, "aiAnswerCopy");
            compare(photo.mediaRoot, "/tmp/opencode");
            verify(Math.abs(photo.imageAspect - 0.6) < 0.01, "The fixture is a genuine portrait PNG");
            compare(photo.frameHeight, 320);
            verify(Math.abs(photo.frameWidth - 192) < 1);
            compare(findChild(photo, "aiImageRaster").fillMode, Image.PreserveAspectFit);
            if (width >= 620) {
                verify(renderer.wideHero);
                verify(photo.x >= copy.width + 20, "Wide answers put the figure to the right of the text");
                compare(photo.y, 0);
                verify(copy.width >= width * 0.5 && copy.width <= width * 0.6);
                compare(hero().height, Math.max(copy.implicitHeight, photo.implicitHeight));
            } else {
                verify(!renderer.wideHero);
                compare(photo.x, 0);
                compare(copy.width, width);
                verify(photo.y >= copy.implicitHeight + 16, "Narrow answers stack the image after title and answer");
                compare(hero().height, photo.y + photo.implicitHeight);
            }
            verify(nativeBlocks().y >= hero().height + 16);
            compare(renderer.height, renderer.implicitHeight);
            compare(renderer.responseHeight, renderer.implicitHeight);
            compare(viewport.contentHeight, renderer.implicitHeight);
            compare(renderer.implicitHeight, nativeBlocks().y + nativeBlocks().implicitHeight);
            capture(String(width));
        }
    }

    function test_expandedWidthGrowsTheFigureUncropped() {
        tests.width = 1000;
        wait(30);
        var photo = image();
        compare(photo.maxFigureWidth, 460, "The Explore surface allows a larger figure");
        compare(photo.maxFigureHeight, 440);
        verify(photo.frameHeight > 320, "The portrait figure grows past the peek cap");
        verify(Math.abs(photo.frameHeight / photo.frameWidth - 400 / 240) < 0.05,
            "The whole subject stays uncropped at expanded widths");
        tests.width = 760;
        wait(30);
        compare(image().maxFigureHeight, 320, "Narrow peeks keep the compact caps");
    }

    function test_headingAndSelectablePlainSummary() {
        compare(renderer.title, "Illustrative subject");
        compare(heading().text, renderer.title);
        compare(heading().Accessible.role, Accessible.Heading);
        compare(heading().Accessible.name, renderer.title);
        compare(heading().font.pixelSize, 29);
        compare(heading().font.weight, Font.DemiBold);
        verify(Math.abs(heading().font.letterSpacing + 0.4) < 0.02, "Qt stores letter spacing at subpixel precision");
        compare(renderer.summary, illustrativeTurn.answer);
        compare(summary().textFormat, TextEdit.PlainText);
        compare(summary().font.pixelSize, 17);
        verify(summary().readOnly && summary().selectByMouse && summary().activeFocusOnTab);
        verify(summary().y >= heading().height + 12);
        compare(summary().height, summary().implicitHeight);
        summary().forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_A, Qt.ControlModifier);
        compare(summary().selectedText, illustrativeTurn.answer);
    }

    function test_originalChecklistIndexesAndSourcesAtBottom() {
        compare(renderer.heroBlockIndex, 2);
        compare(renderer.remainingBlockIndices, [1, 3, 4, 0]);
        compare(nativeBlocks().blocks.length, 4);
        var before = findChild(renderer, "aiCheck_1_0");
        var after = findChild(renderer, "aiCheck_4_0");
        verify(before !== null && after !== null);
        verify(before.checked && !after.checked);
        before.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Return);
        compare(checkSpy.count, 1);
        compare(checkSpy.signalArguments[0][0], 1);
        compare(checkSpy.signalArguments[0][1], 0);
        compare(checkSpy.signalArguments[0][2], false);
        renderer.checkedState = ({"1:0": false, "4:0": true});
        renderer.turn = Object.assign({}, illustrativeTurn, {blocks: illustrativeTurn.blocks.slice()});
        wait(30);
        verify(!findChild(renderer, "aiCheck_1_0").checked);
        verify(findChild(renderer, "aiCheck_4_0").checked);
        var source = findChild(renderer, "aiSource_0");
        after = findChild(renderer, "aiCheck_4_0");
        verify(source.mapToItem(renderer, 0, 0).y >= after.mapToItem(renderer, 0, after.height).y);
        source.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(sourceSpy.count, 1);
        compare(sourceSpy.signalArguments[0][0], "https://example.com/reference");
        renderer.turnIndex = 3;
        verify(findChild(renderer, "aiNativeBlocks_3") !== null);
    }

    function test_textModeUsesFullFallbackAndKeepsTitle() {
        renderer.showText = true;
        wait(30);
        compare(renderer.summary, AiState.textAnswer(illustrativeTurn));
        compare(summary().text, AiState.textAnswer(illustrativeTurn));
        compare(summary().textFormat, TextEdit.PlainText);
        verify(summary().text.indexOf("Review the example") >= 0);
        verify(summary().text.indexOf("https://example.com/reference") >= 0);
        verify(heading().visible && heading().text === "Illustrative subject");
        verify(!image().visible && !nativeBlocks().visible);
        compare(summary().width, renderer.width);
        compare(renderer.implicitHeight, hero().implicitHeight);
        compare(sourceSpy.count, 0, "Displaying the fallback must not open a source");
        renderer.showText = false;
        tryCompare(image(), "imageStatus", Image.Ready);
        verify(findChild(renderer, "aiCheck_1_0").checked);
    }

    function test_imageSourceAndTrustedCacheForwarding() {
        compare(sourceSpy.count, 0);
        var source = findChild(image(), "aiImageSource");
        source.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        var popup = findChild(image(), "aiImageCreditPopup");
        tryCompare(popup, "opened", true);
        compare(sourceSpy.count, 0, "Photo details disclose attribution without opening the browser");
        var viewSource = findChild(image(), "aiImageViewSource");
        viewSource.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(sourceSpy.count, 1);
        compare(sourceSpy.signalArguments[0][0], "https://example.com/photo");
        tryCompare(popup, "opened", false);
        compare(image().safeSource, "file:///tmp/opencode/ai-answer-portrait.png");
        compare(image().validatedSource("https://example.com/portrait.png"), "");
        compare(image().validatedSource("file:///etc/portrait.png"), "");
        renderer.mediaRoot = "";
        compare(image().mediaRoot, image().defaultMediaRoot);
        compare(image().validatedSource("file:///tmp/opencode/ai-answer-portrait.png"), "");
    }

    function test_heroReplacementUsesOriginalBlockStateAndRestores() {
        var blocks = illustrativeTurn.blocks.slice();
        blocks[2] = Object.assign({}, blocks[2], {alternatives: [{
            imageUrl: "file:///tmp/opencode/ai-answer-portrait.png",
            attribution: "Illustrative alternative fixture", sourceUrl: "https://example.com/alternative"
        }]});
        var turn = Object.assign({}, illustrativeTurn, {blocks: blocks});
        renderer.turn = turn;
        renderer.uiState = ({"image:0": 0, "image:2": 0, "step:3": 2});
        wait(30);
        compare(renderer.heroBlockIndex, 2);
        var next = findChild(image(), "aiImageNext");
        verify(next !== null && next.visible);
        verify(next.text.startsWith("Show another"));
        mouseClick(next, next.width / 2, next.height / 2);
        compare(uiStateSpy.count, 1, "The hero must forward the replacement edit to its host");
        compare(uiStateSpy.signalArguments[0][0], 2, "Hero extraction must preserve the authored block index");
        compare(uiStateSpy.signalArguments[0][1], "image:2");
        compare(uiStateSpy.signalArguments[0][2], 1);

        var savedState = Object.assign({}, renderer.uiState);
        savedState[uiStateSpy.signalArguments[0][1]] = uiStateSpy.signalArguments[0][2];
        renderer.uiState = savedState;
        compare(image().alternativeIndex, 1);
        compare(image().sourceUrl, "https://example.com/alternative");
        compare(image().attributionText, "Illustrative alternative fixture");
        compare(renderer.uiState["image:0"], 0);
        compare(renderer.uiState["step:3"], 2);

        renderer.turn = null;
        var restored = createTemporaryObject(restoredAnswerComponent, surface, {
            width: 760, turn: turn, uiState: savedState
        });
        verify(restored !== null);
        var restoredImage = findChild(restored, "aiImage");
        tryCompare(restoredImage, "imageReady", true);
        compare(restored.heroBlockIndex, 2);
        compare(restoredImage.alternativeIndex, 1, "A recreated answer must restore the hero's saved candidate");
        compare(restoredImage.sourceUrl, "https://example.com/alternative");
        compare(restoredImage.attributionText, "Illustrative alternative fixture");
        compare(restored.stateEditCount, 0, "Restoring state must not emit an edit from the recreated answer");
    }

    function test_longTextAndNoImageUseMeasuredFullWidth() {
        renderer.turn = {id: 18, status: "done", answer: "Illustrative long prose. ".repeat(60), blocks: []};
        wait(30);
        var wideHeight = renderer.responseHeight;
        compare(summary().width, renderer.width);
        verify(!image().visible && !nativeBlocks().visible);
        tests.width = 420;
        wait(30);
        verify(renderer.responseHeight > wideHeight);
        compare(summary().width, 420);
        compare(renderer.responseHeight, summary().mapToItem(renderer, 0, summary().height).y);
        compare(renderer.height, renderer.implicitHeight);
        renderer.turn = {id: 19, status: "done", answer: "<b>Illustrative literal text</b>", blocks: []};
        compare(summary().text, "<b>Illustrative literal text</b>");
        compare(summary().textFormat, TextEdit.PlainText);
    }

    function test_imageQueryNeverInventsTitle() {
        renderer.title = "";
        wait(30);
        verify(!heading().visible);
        compare(renderer.title, "");
        compare(summary().text, illustrativeTurn.answer);
        verify(image().visible);
    }

    function test_workingEmptyIsCompactAndFailureBelongsToHost() {
        renderer.title = "";
        renderer.turn = {status: "working", answer: "", blocks: []};
        wait(30);
        var placeholder = findChild(renderer, "aiAnswerPlaceholder");
        verify(placeholder.visible);
        verify(!summary().visible && !heading().visible && !image().visible && !nativeBlocks().visible);
        verify(renderer.responseHeight > 0 && renderer.responseHeight < 40);
        renderer.turn = {status: "error", answer: "", blocks: [], error: "Illustrative offline error"};
        wait(30);
        verify(!placeholder.visible);
        compare(renderer.responseHeight, 0);
        renderer.turn = null;
        wait(30);
        compare(renderer.responseHeight, 0);
    }
}
