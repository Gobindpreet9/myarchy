import QtQuick
import QtQuick.Controls
import QtTest
import ".." as Launcher

TestCase {
    id: testCase
    name: "AiVisual"
    width: 760
    height: 900
    visible: true
    when: windowShown
    property int parentEscapeCount: 0

    // Deliberately illustrative observations, not claimed market prices.
    property var marketFixture: ({type: "market", title: "Illustrative prices", symbol: "DEMO", range: "1mo", unit: "USD",
        points: [{label: "2026-01-01", value: 100}, {label: "2026-01-02", value: 104}, {label: "2026-01-03", value: 102}],
        sourceUrl: "https://example.com/prices", asOf: "2026-01-03"})
    property var fixtures: [marketFixture,
        {type: "image", title: "Illustrative unavailable image", query: "Illustrative landscape", error: "Image provider unavailable"},
        {type: "sources", title: "Sources", items: [{label: "Illustrative reference", url: "https://example.com/reference"}]}]

    Rectangle {
        id: surface
        width: testCase.width
        height: renderer.implicitHeight
        color: "#222222"
        Keys.onEscapePressed: ++testCase.parentEscapeCount
        Launcher.AiBlocks {
            id: renderer
            width: surface.width
            foreground: "#eeeeee"
            background: surface.color
            accent: "#88bbff"
            blocks: testCase.fixtures
        }
    }
    SignalSpy { id: localSourceSpy; target: localImage; signalName: "openUrl" }
    SignalSpy { id: sourceSpy; target: renderer; signalName: "openUrl" }
    SignalSpy { id: alternativeSpy; target: localImage; signalName: "alternativeChanged" }

    // Generate a real local PNG using Qt, without remote I/O or a committed asset.
    Rectangle {
        id: pngFixture
        width: 240
        height: 320
        color: "#88bbff"
        x: 800
        Rectangle { width: parent.width; height: 8; color: "#eeeeee" }
        Rectangle { y: parent.height - height; width: parent.width; height: 8; color: "#eeeeee" }
        Rectangle { width: 8; height: parent.height; color: "#eeeeee" }
        Rectangle { x: parent.width - width; width: 8; height: parent.height; color: "#eeeeee" }
    }
    Launcher.AiImage {
        id: localImage
        x: 800
        width: 420
        foreground: "#eeeeee"
        background: "#222222"
        accent: "#88bbff"
        // Only the trusted test host can configure this directory.
        mediaRoot: "/tmp/opencode"
        block: ({})
    }
    Launcher.AiImage {
        id: defaultCacheImage
        x: 800
        width: 420
        foreground: "#eeeeee"
        background: "#222222"
        accent: "#88bbff"
        block: ({})
    }

    function initTestCase() {
        var saved = false;
        verify(pngFixture.grabToImage(function(result) {
            saved = result.saveToFile("/tmp/opencode/ai-visual-fixture.png");
        }));
        tryVerify(function() { return saved; });
        pngFixture.width = 480;
        pngFixture.height = 300;
        wait(30);
        saved = false;
        verify(pngFixture.grabToImage(function(result) {
            saved = result.saveToFile("/tmp/opencode/ai-visual-landscape.png");
        }));
        tryVerify(function() { return saved; });
    }
    function init() {
        testCase.forceActiveFocus();
        testCase.width = 760;
        renderer.mediaRoot = "";
        renderer.blocks = [];
        renderer.blocks = fixtures;
        localImage.block = ({});
        localImage.width = 420;
        localImage.maxFigureWidth = 620;
        localImage.maxFigureHeight = 340;
        localImage.comparisonFrameHeight = 0;
        localImage.alternativeIndex = 0;
        localImage.mediaRoot = "/tmp/opencode";
        findChild(localImage, "aiImageCreditPopup").close();
        findChild(localImage, "aiImageViewer").close();
        sourceSpy.clear();
        localSourceSpy.clear();
        parentEscapeCount = 0;
        wait(30);
    }
    function chart() { return findChild(renderer, "aiChart"); }

    function alternativeFixture() {
        return {type: "image", query: "Fixture", error: "",
            imageUrl: "file:///tmp/opencode/ai-visual-fixture.png",
            attribution: "First · CC0", sourceUrl: "https://example.com/1",
            alternatives: [{imageUrl: "file:///tmp/opencode/ai-visual-landscape.png",
                            attribution: "Second · CC BY", sourceUrl: "https://example.com/2"}]}
    }

    function test_alternativesCycleAndCreditsFollow() {
        localImage.mediaRoot = "/tmp/opencode";
        localImage.alternativeIndex = 0;
        localImage.block = alternativeFixture();
        tryCompare(localImage, "imageStatus", Image.Ready);
        compare(localImage.attributionText, "First · CC0");
        var next = findChild(localImage, "aiImageNext");
        verify(next !== null && next.visible);
        verify(next.text.indexOf("1/2") >= 0);
        alternativeSpy.clear();
        mouseClick(next, next.width / 2, next.height / 2);
        compare(alternativeSpy.count, 1);
        compare(alternativeSpy.signalArguments[0][0], 1);
        // The host applies the index; the figure, credit and source follow.
        localImage.alternativeIndex = 1;
        tryCompare(localImage, "attributionText", "Second · CC BY");
        compare(localImage.sourceUrl, "https://example.com/2");
        tryCompare(localImage, "imageStatus", Image.Ready);
        verify(findChild(localImage, "aiImageNext").text.indexOf("2/2") >= 0);
        alternativeSpy.clear();
        mouseClick(next, next.width / 2, next.height / 2);
        compare(alternativeSpy.signalArguments[0][0], 0, "cycling wraps back to the primary");
        localImage.alternativeIndex = 0;
        wait(30);
    }

    function test_viewerEnlargesZoomsAndEscapes() {
        localImage.mediaRoot = "/tmp/opencode";
        localImage.block = alternativeFixture();
        tryCompare(localImage, "imageStatus", Image.Ready);
        compare(String(findChild(localImage, "aiImageViewerImage").source), "",
            "a closed viewer does not decode an extra image");
        var area = findChild(localImage, "aiImageZoomArea");
        verify(area !== null);
        mouseClick(area, 10, 10);
        var viewer = findChild(localImage, "aiImageViewer");
        tryCompare(viewer, "opened", true);
        compare(findChild(localImage, "aiImageViewerImage").source, localImage.safeSource);
        var raster = findChild(localImage, "aiImageViewerImage");
        tryCompare(raster, "status", Image.Ready);
        verify(raster.width > 0 && raster.height > 0, "the enlarged raster has real geometry");
        var fitWidth = raster.width, fitHeight = raster.height;
        var viewport = findChild(localImage, "aiImageViewerPan");
        verify(raster.x >= 0 && raster.y >= 0);
        verify(viewport.height + viewport.y <= viewer.availableHeight);
        var zoom = findChild(localImage, "aiImageViewerZoom");
        zoom.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(viewer.zoomed, true);
        compare(zoom.text, "Fit");
        verify(Math.abs(raster.width - fitWidth * 2) <= 1);
        verify(Math.abs(raster.height - fitHeight * 2) <= 1);
        wait(20);
        viewport.forceActiveFocus(Qt.TabFocusReason);
        var oldY = viewport.contentY;
        keyClick(Qt.Key_Down);
        verify(viewport.contentY > oldY, "zoomed image pans with the keyboard");
        keyClick(Qt.Key_Escape);
        tryCompare(viewer, "opened", false);
        compare(viewer.zoomed, false, "closing resets the zoom");
        compare(String(raster.source), "", "closing releases the viewer's image request");
        verify(findChild(localImage, "aiImageFrame").activeFocus, "focus returns to the opening figure");
    }

    function test_comparisonFramesKeepPortraitAndLandscapeAligned() {
        localImage.comparisonFrameHeight = 260;
        localImage.block = alternativeFixture();
        tryCompare(localImage, "imageStatus", Image.Ready);
        compare(localImage.frameWidth, 420);
        compare(localImage.frameHeight, 260);
        localImage.alternativeIndex = 1;
        tryCompare(localImage, "imageStatus", Image.Ready);
        compare(localImage.frameWidth, 420);
        compare(localImage.frameHeight, 260);
        compare(findChild(localImage, "aiImageRaster").fillMode, Image.PreserveAspectFit,
            "comparison never crops the distinguishing features");
        localImage.width = 220;
        compare(localImage.frameWidth, 220);
        localImage.block = {error: "Unavailable"};
        compare(localImage.frameHeight, 260, "failure does not collapse the gallery grid");
    }

    function test_galleryGridCaptionsAndPerItemErrors() {
        renderer.blocks = [{type: "gallery", title: "Styles", items: [
            {query: "Gothic", caption: "Pointed arches",
             imageUrl: "file:///tmp/opencode/ai-visual-fixture.png",
             attribution: "A · CC0", sourceUrl: "https://example.com/a", error: "", fetchedAt: ""},
            {query: "Romanesque", caption: "Round arches",
             imageUrl: "", attribution: "", sourceUrl: "", error: "Provider unavailable", fetchedAt: ""}]}];
        wait(40);
        verify(findChild(renderer, "aiGallery") !== null);
        compare(findChild(renderer, "aiGalleryCaption_0_0").text, "Pointed arches");
        compare(findChild(renderer, "aiGalleryCaption_0_1").text, "Round arches");
        compare(findChild(renderer, "aiGallery").items.length, 2);
        renderer.blocks = fixtures;
        wait(30);
    }

    function test_galleryItemReplacementStateIsScoped() {
        // A replaced gallery example must not reset its neighbours: the cell
        // offers Show another, and its state key names that single item.
        renderer.blocks = [{type: "gallery", title: "Styles", items: [
            {query: "Gothic", caption: "Pointed",
             imageUrl: "file:///tmp/opencode/ai-visual-fixture.png",
             attribution: "A · CC0", sourceUrl: "https://example.com/a", error: "", fetchedAt: "",
             alternatives: [{imageUrl: "file:///tmp/opencode/ai-visual-landscape.png",
                             attribution: "B · CC BY", sourceUrl: "https://example.com/b"}]},
            {query: "Romanesque", caption: "Round",
             imageUrl: "file:///tmp/opencode/ai-visual-fixture.png",
             attribution: "C · CC0", sourceUrl: "https://example.com/c", error: "", fetchedAt: ""}]}];
        wait(40);
        var gallery = findChild(renderer, "aiGallery");
        verify(gallery !== null);
        var next = findChild(gallery, "aiImageNext");
        verify(next !== null && next.visible, "gallery examples with candidates offer Show another");
        var emitted = [];
        gallery.uiStateEdited.connect(function(key, value) { emitted.push([key, value]) });
        mouseClick(next, next.width / 2, next.height / 2);
        wait(20);
        compare(emitted.length, 1, "replacement emits exactly one state edit")
        compare(emitted[0][0], "gallery:0:0", "only the replaced item's slot changes")
        compare(emitted[0][1], 1)
        renderer.blocks = fixtures;
        wait(30);
    }

    function test_keyboardAndScale() {
        var item = chart();
        verify(item !== null);
        compare(item.points.length, 3);
        compare(item.selectedIndex, 2);
        verify(isFinite(item.scaleMin) && isFinite(item.scaleMax));
        verify(item.scaleMin > 0); // Financial scale does not force zero.
        item.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Left);
        compare(item.selectedIndex, 1);
        compare(item.selectedPoint.value, 104);
        keyClick(Qt.Key_Home);
        compare(item.selectedIndex, 0);
        keyClick(Qt.Key_End);
        compare(item.selectedIndex, 2);
        keyClick(Qt.Key_Right);
        compare(item.selectedIndex, 2);
        verify(item.summary.indexOf("Illustrative") >= 0);
        verify(item.changeText.indexOf("+") >= 0);
    }
    function test_flatSingleInvalidAndBoundedSeries() {
        renderer.blocks = [{type: "chart", title: "Illustrative flat series", unit: "items", labels: ["A", "B"], values: [5, 5], source: "Fixture"}];
        wait(30);
        var item = chart();
        verify(item.scaleMax > item.scaleMin);
        verify(isFinite(item.pointY(5)));
        renderer.blocks = [{type: "chart", labels: ["A"], values: [0]}];
        wait(30);
        verify(isFinite(chart().pointX(0)) && isFinite(chart().pointY(0)));
        renderer.blocks = [{type: "chart", values: [null, "12", NaN, Infinity]}];
        wait(30);
        compare(chart().points.length, 0);
        verify(findChild(renderer, "aiChartError").visible);
        verify(chart().errorText.indexOf("No finite") >= 0);
        var many = [];
        for (var i = 0; i < 180; ++i) many.push({label: String(i), value: i});
        renderer.blocks = [{type: "market", points: many}];
        wait(30);
        compare(chart().points.length, 120);
    }
    function test_sourcesForwardAndKeyboard() {
        var link = findChild(renderer, "aiSource_0");
        verify(link !== null);
        link.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(sourceSpy.count, 1);
        compare(sourceSpy.signalArguments[0][0], "https://example.com/reference");
        var marketSource = findChild(renderer, "aiChartSource");
        marketSource.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(sourceSpy.count, 2);
        compare(sourceSpy.signalArguments[1][0], "https://example.com/prices");
        renderer.blocks = [{type: "image", title: "Illustrative image credit", error: "Illustrative unavailable image", attribution: "Example photographer", sourceUrl: "https://example.com/photo"}];
        wait(30);
        var image = findChild(renderer, "aiImage");
        var imageSource = findChild(image, "aiImageSource");
        var popup = findChild(image, "aiImageCreditPopup");
        var viewSource = findChild(image, "aiImageViewSource");
        imageSource.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        tryCompare(popup, "opened", true);
        compare(sourceSpy.count, 2, "Photo details disclose credit without opening a browser");
        viewSource.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        compare(sourceSpy.count, 3);
        compare(sourceSpy.signalArguments[2][0], "https://example.com/photo");
        renderer.blocks = [{type: "sources", items: [{label: "Unsafe", url: "javascript:alert(1)"}]}];
        wait(30);
        verify(!findChild(renderer, "aiSource_0").enabled);
    }
    function test_hoverScrub() {
        var item = chart();
        mouseMove(item, item.pointX(0) + 1, 120);
        tryCompare(item, "selectedIndex", 0);
        mouseMove(item, item.pointX(1), 120);
        tryCompare(item, "selectedIndex", 1);
        compare(item.selectedPoint.label, "2026-01-02");
        mouseMove(testCase, 0, 800);
    }
    function test_photoCreditCollapsesProviderBlankSpaceWithoutDroppingText() {
        localImage.block = {type: "image", attribution: "Illustrative artist\n\n\n\nSupported project\n \n\nCC BY 4.0",
            sourceUrl: "https://example.com/photo"};
        compare(localImage.attributionText, "Illustrative artist\n\nSupported project\n\nCC BY 4.0");
        compare(findChild(localImage, "aiImageCreditText").text,
            "Illustrative artist\n\nSupported project\n\nCC BY 4.0\n\nhttps://example.com/photo");
    }
    function test_negativeSeriesAndDataReplacement() {
        var item = chart();
        item.block = {type: "chart", title: "Illustrative signed observations", unit: "units",
                      labels: ["A", "B", "C"], values: [-5, 0, 3], source: "", asOf: "Provided data"};
        wait(30);
        compare(item.points.length, 3);
        verify(item.scaleMin < 0 && item.scaleMax > 0);
        verify(isFinite(item.pointY(-5)) && isFinite(item.pointY(3)));
        item.block = {type: "chart", title: "Replacement", unit: "units", labels: ["X", "Y"], values: [8, 12],
                      sourceUrl: "https://example.com/data", asOf: "Provided data"};
        wait(30);
        compare(item.points.length, 2);
        verify(item.scaleMin > 0);
        verify(findChild(item, "aiChartSource").text.indexOf("https://example.com/data") >= 0);
    }
    function test_sourceButtonsMatchNavigationPolicy() {
        for (var url of ["http://example.com/data", "https://localhost/data", "https://127.0.0.1/data", "file:///tmp/data"]) {
            renderer.blocks = [
                {type: "sources", items: [{label: "Invalid fixture", url: url}]},
                {type: "chart", labels: ["A", "B"], values: [1, 2], source: url},
                {type: "image", error: "Fixture", sourceUrl: url}];
            wait(20);
            verify(!findChild(renderer, "aiSource_0").enabled);
            verify(!findChild(renderer, "aiChartSource").enabled);
            verify(!findChild(renderer, "aiImageSource").enabled);
            var viewSource = findChild(findChild(renderer, "aiImage"), "aiImageViewSource");
            verify(!viewSource.enabled);
            viewSource.clicked();
            compare(sourceSpy.count, 0, "An invalid source remains rejected at the navigation handler");
        }
    }
    function test_photoDetailsPopupAndFocusReturn() {
        var creditText = "Illustrative full photographer name · CC BY-SA 4.0 · Wikimedia Commons · "
            + "Facebook: https://example.com/photographer · <b>literal, not HTML</b>";
        renderer.blocks = [{type: "image", error: "Image provider unavailable",
            attribution: creditText, sourceUrl: "https://example.com/photo"}];
        wait(30);
        var image = findChild(renderer, "aiImage");
        var details = findChild(image, "aiImageSource");
        var popup = findChild(image, "aiImageCreditPopup");
        var viewSource = findChild(image, "aiImageViewSource");
        var close = findChild(image, "aiImageCreditClose");
        var title = findChild(image, "aiImageCreditTitle");
        var disclosure = findChild(image, "aiImageCreditText");
        compare(details.text, "Photo details");
        verify(details.Accessible.name.indexOf(creditText) >= 0);
        details.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Space);
        tryCompare(popup, "opened", true);
        compare(sourceSpy.count, 0);
        verify(popup.modal && popup.focus);
        verify((popup.closePolicy & Popup.CloseOnEscape) !== 0);
        compare(title.text, "Photo credit");
        compare(disclosure.text, creditText + "\n\nhttps://example.com/photo");
        compare(disclosure.textFormat, Text.PlainText);
        compare(disclosure.wrapMode, Text.Wrap);
        verify(disclosure.maximumLineCount > 2, "The popup retains the complete author and license");
        compare(disclosure.Accessible.name, disclosure.text);
        verify(popup.width <= testCase.width);
        keyClick(Qt.Key_Escape);
        tryCompare(popup, "opened", false);
        tryCompare(details, "activeFocus", true);
        compare(parentEscapeCount, 0, "Escape closes the popup before the launcher parent");
        compare(sourceSpy.count, 0);
        keyClick(Qt.Key_Escape);
        compare(parentEscapeCount, 1, "The next Escape reaches the launcher after focus returns");

        mouseClick(details, details.width / 2, details.height / 2);
        tryCompare(popup, "opened", true);
        mouseClick(close, close.width / 2, close.height / 2);
        tryCompare(popup, "opened", false);
        tryCompare(details, "activeFocus", true);
        compare(sourceSpy.count, 0);

        keyClick(Qt.Key_Space);
        tryCompare(popup, "opened", true);
        mouseClick(viewSource, viewSource.width / 2, viewSource.height / 2);
        compare(sourceSpy.count, 1);
        compare(sourceSpy.signalArguments[0][0], "https://example.com/photo");
        tryCompare(popup, "opened", false);
        tryCompare(details, "activeFocus", true);
    }
    function test_photoCreditLongDisclosureAtLauncherWidths() {
        var creditText = "Illustrative photographer · CC BY-SA 4.0 · Wikimedia Commons. ";
        for (var i = 0; i < 12; ++i) creditText += "Full attribution and provenance remain plain, readable text. ";
        for (var w of [420, 760]) {
            testCase.width = w;
            renderer.blocks = [{type: "image", error: "Image provider unavailable", attribution: creditText,
                sourceUrl: "https://example.com/photographer/this-is-a-deliberately-long-literal-source-address"}];
            wait(30);
            var image = findChild(renderer, "aiImage");
            var details = findChild(image, "aiImageSource");
            var popup = findChild(image, "aiImageCreditPopup");
            var disclosure = findChild(image, "aiImageCreditText");
            var scroll = findChild(image, "aiImageCreditScroll");
            var viewSource = findChild(image, "aiImageViewSource");
            mouseClick(details, details.width / 2, details.height / 2);
            tryCompare(popup, "opened", true);
            compare(sourceSpy.count, 0);
            verify(popup.width <= w);
            verify(popup.height <= popup.parent.height);
            verify(disclosure.text.indexOf(creditText) === 0);
            verify(disclosure.implicitHeight > scroll.height, "Long credits scroll instead of being truncated");
            verify(viewSource.y >= scroll.y + scroll.height, "The explicit source button remains outside the scrollable credit");
            var captured = false;
            var capturePath = "/tmp/opencode/ai-photo-credit-" + w + ".png";
            verify(popup.contentItem.parent.grabToImage(function(result) { captured = result.saveToFile(capturePath); }));
            tryVerify(function() { return captured; });
            keyClick(Qt.Key_Escape);
            tryCompare(popup, "opened", false);
            tryCompare(details, "activeFocus", true);
            compare(parentEscapeCount, 0);
        }
    }
    function test_widthsAndStableFrames() {
        for (var w of [420, 760]) {
            testCase.width = w;
            wait(30);
            compare(chart().width, w);
            verify(chart().height >= 240 && chart().height <= 280);
            var image = findChild(renderer, "aiImage");
            compare(image.width, w);
            compare(image.frameWidth, Math.min(w, 620));
            verify(image.frameHeight > 0 && image.frameHeight <= 240, "Unavailable images reserve a bounded placeholder, not the final figure size");
            var error = findChild(renderer, "aiImageStatus");
            verify(error.visible && error.text.indexOf("unavailable") >= 0);
            var bottom = 0;
            for (var section of renderer.children) {
                if (section.modelData === undefined) continue;
                verify(section.y >= bottom);
                bottom = section.y + section.height;
            }
            compare(renderer.implicitHeight, bottom);
            var captured = false;
            verify(surface.grabToImage(function(result) {
                captured = result.saveToFile("/tmp/opencode/ai-visual-" + w + ".png");
            }));
            tryVerify(function() { return captured; });
        }
    }
    function test_localImageSuccessAndRemoteRefused() {
        localImage.block = {type: "image", query: "Illustrative tiny blue image", imageUrl: "file:///tmp/opencode/ai-visual-fixture.png"};
        tryCompare(localImage, "imageStatus", Image.Ready);
        var raster = findChild(localImage, "aiImageRaster");
        compare(raster.fillMode, Image.PreserveAspectFit);
        compare(raster.sourceSize.width, 960);
        compare(localImage.frameHeight, 340);
        compare(localImage.frameWidth, 255);
        var placeholderHeight = Math.min(240, 420 * 0.56);
        for (var url of ["https://example.com/image.png", "file:///etc/image.png", "file:///tmp/opencode/../image.png",
                         "file:///tmp/opencode/%2e%2e/image.png", "file:///tmp/opencode/image.svg", "file://example.com/image.png"]) {
            localImage.block = {type: "image", imageUrl: url};
            compare(localImage.safeSource, "");
            compare(String(raster.source), "");
            verify(localImage.statusText.indexOf("trusted local") >= 0);
            compare(localImage.frameHeight, placeholderHeight);
        }
        localImage.block = {type: "image", imageUrl: "file:///tmp/opencode/no-such-image.png"};
        ignoreWarning(/.*Cannot open: file:\/\/\/tmp\/opencode\/no-such-image.png/);
        tryCompare(localImage, "imageStatus", Image.Error);
        verify(localImage.statusText.indexOf("could not be loaded") >= 0);
    }
    function test_defaultCachePathIsFilesystemPathNotQtUrl() {
        verify(defaultCacheImage.mediaRoot.startsWith("/"), "Qt StandardPaths returns a URL; normalize it before cache confinement")
        compare(defaultCacheImage.mediaRoot, defaultCacheImage.defaultMediaRoot);
        verify(defaultCacheImage.mediaRoot.endsWith("/omarchy/launcher-ai/media"));
        var url = "file://" + encodeURI(defaultCacheImage.mediaRoot + "/ai-fixture.png");
        compare(defaultCacheImage.validatedSource(url), url);
        compare(defaultCacheImage.validatedSource("file:///etc/passwd.png"), "");
        compare(defaultCacheImage.validatedSource("https://example.com/photo.png"), "");
        renderer.blocks = [{type: "image", error: "Fixture"}];
        wait(30);
        var delegated = findChild(renderer, "aiImage");
        compare(delegated.mediaRoot, defaultCacheImage.defaultMediaRoot);
        compare(delegated.validatedSource(url), url);
        // Use a disjoint sibling root: a scratch XDG_STATE_HOME can itself
        // be inside /tmp/opencode, so that broad ancestor is not "outside".
        var hostRoot = defaultCacheImage.defaultMediaRoot + "-host-fixture";
        var hostUrl = "file://" + encodeURI(hostRoot + "/ai-visual-fixture.png");
        renderer.mediaRoot = hostRoot;
        compare(delegated.mediaRoot, hostRoot);
        compare(delegated.validatedSource(url), "");
        compare(delegated.validatedSource(hostUrl), hostUrl);
        delegated.block = {type: "image", imageUrl: "file:///etc/photo.png", mediaRoot: "/etc",
            maxFigureWidth: 900, maxFigureHeight: 900};
        compare(delegated.mediaRoot, hostRoot, "Answer fields cannot override trusted host configuration");
        compare(delegated.safeSource, "");
        compare(delegated.maxFigureWidth, 620);
        compare(delegated.maxFigureHeight, 340);
    }
    function test_configurableFigureCapsAndNarrowRoots() {
        for (var fixture of [{file: "ai-visual-fixture.png", aspect: 0.75},
                             {file: "ai-visual-landscape.png", aspect: 1.6}]) {
            localImage.block = {type: "image", imageUrl: "file:///tmp/opencode/" + fixture.file};
            tryCompare(localImage, "imageStatus", Image.Ready);
            for (var bounds of [{width: 300, maxWidth: 300, maxHeight: 320},
                               {width: 420, maxWidth: 380, maxHeight: 220},
                               {width: 760, maxWidth: 500, maxHeight: 300}]) {
                localImage.width = bounds.width;
                localImage.maxFigureWidth = bounds.maxWidth;
                localImage.maxFigureHeight = bounds.maxHeight;
                wait(30);
                compare(localImage.frameWidth, Math.min(bounds.width, bounds.maxWidth, bounds.maxHeight * fixture.aspect));
                verify(localImage.frameHeight <= bounds.maxHeight);
                verify(Math.abs(localImage.frameWidth / localImage.frameHeight - fixture.aspect) < 0.01);
                var raster = findChild(localImage, "aiImageRaster");
                verify(Math.abs(raster.paintedWidth - localImage.frameWidth) < 1);
                verify(Math.abs(raster.paintedHeight - localImage.frameHeight) < 1);
            }
        }
        localImage.width = 300;
        localImage.maxFigureWidth = 280;
        localImage.maxFigureHeight = 120;
        localImage.block = {type: "image", error: "Image provider unavailable"};
        compare(localImage.frameWidth, 280);
        compare(localImage.frameHeight, 120);
        compare(localImage.statusText, "Image provider unavailable");
        verify(!localImage.imageReady);
        compare(findChild(localImage, "aiImageRaster").source.toString(), "");
    }
    function test_errorKeepsCacheAndCreditPolicies() {
        localImage.block = {type: "image", imageUrl: "file:///tmp/opencode/ai-visual-fixture.png",
            error: "Image provider rate limit", sourceUrl: "https://example.com/photo"};
        tryCompare(localImage, "imageStatus", Image.Ready);
        compare(localImage.safeSource, "file:///tmp/opencode/ai-visual-fixture.png");
        verify(!localImage.imageReady);
        verify(!findChild(localImage, "aiImageRaster").visible);
        compare(localImage.statusText, "Image provider rate limit");
        verify(findChild(localImage, "aiImageSource").enabled);
        compare(localSourceSpy.count, 0);
        var popup = findChild(localImage, "aiImageCreditPopup");
        popup.open();
        tryCompare(popup, "opened", true);
        verify(findChild(localImage, "aiImageCreditText").text.indexOf("Attribution was not provided") >= 0);
        popup.close();
        tryCompare(popup, "opened", false);

        localImage.block = {type: "image", imageUrl: "https://example.com/unsafe.png",
            error: "Image provider unavailable", attribution: "Illustrative author · CC BY 4.0"};
        compare(localImage.safeSource, "", "Provider failure does not downgrade cache confinement");
        compare(findChild(localImage, "aiImageRaster").source.toString(), "");
        compare(localImage.statusText, "Image provider unavailable");
        verify(findChild(localImage, "aiImageSource").enabled, "Attribution without a source still has a disclosure");
        verify(!findChild(localImage, "aiImageViewSource").enabled);
        findChild(localImage, "aiImageViewSource").clicked();
        compare(localSourceSpy.count, 0);
    }
    function test_aspectAwareFiguresAndCompactCredit() {
        var creditText = "Illustrative photographer with a deliberately long full author name and institution · CC BY-SA 4.0 · Wikimedia Commons";
        renderer.mediaRoot = "/tmp/opencode";
        for (var fixture of [{name: "portrait", file: "ai-visual-fixture.png", aspect: 0.75},
                             {name: "landscape", file: "ai-visual-landscape.png", aspect: 1.6}]) {
            for (var w of [320, 420, 760]) {
                testCase.width = w;
                renderer.blocks = [{type: "image", query: "Illustrative " + fixture.name,
                    imageUrl: "file:///tmp/opencode/" + fixture.file,
                    attribution: creditText, sourceUrl: "https://example.com/photo"}];
                var image = findChild(renderer, "aiImage");
                tryCompare(image, "imageStatus", Image.Ready);
                wait(30);
                var frame = findChild(image, "aiImageFrame");
                var raster = findChild(image, "aiImageRaster");
                var credit = findChild(image, "aiImageSource");
                verify(Math.abs(image.imageAspect - fixture.aspect) < 0.01);
                verify(frame.width <= w && frame.width <= 620);
                verify(frame.height <= 340);
                compare(frame.width, Math.min(w, 620, 340 * fixture.aspect));
                verify(Math.abs(frame.width / frame.height - fixture.aspect) < 0.01);
                compare(raster.fillMode, Image.PreserveAspectFit);
                verify(Math.abs(raster.paintedWidth - frame.width) < 1, "No unused horizontal letterbox");
                verify(Math.abs(raster.paintedHeight - frame.height) < 1, "No unused vertical letterbox or cropping");
                compare(frame.x, credit.x);
                verify(credit.width <= frame.width && credit.width <= 140, "Photo details stays a compact footer action");
                compare(credit.contentItem.maximumLineCount, 1);
                compare(credit.contentItem.text, "Photo details");
                verify(credit.height <= 32, "Long attribution does not enlarge the footer");
                verify(credit.Accessible.name.indexOf(creditText) >= 0, "Full author and license remain accessible");
                verify(findChild(image, "aiImageCreditText").text.indexOf(creditText) >= 0);
                verify(image.height >= frame.height + credit.height);
                verify(renderer.implicitHeight >= image.height, "Ready-image geometry propagates into response height");
                var pixels = grabImage(surface);
                compare(pixels.pixel(Math.floor(frame.width / 2), Math.floor(frame.height / 2)), "#88bbff",
                    "The unlayered raster must keep the whole figure visible");
                compare(pixels.pixel(Math.floor(frame.width / 2), 2), "#eeeeee", "The subject's top edge is retained");
                compare(pixels.pixel(Math.floor(frame.width / 2), Math.floor(frame.height) - 3), "#eeeeee", "The subject's bottom edge is retained");
                verify(!raster.layer.enabled, "Retained images must not create shader layers that survive a DPR change");
                var captured = false;
                var capturePath = "/tmp/opencode/ai-figure-" + fixture.name + "-" + w + ".png";
                verify(surface.grabToImage(function(result) { captured = result.saveToFile(capturePath); }));
                tryVerify(function() { return captured; });
            }
        }
    }
    function test_marketError() {
        renderer.blocks = [{type: "market", title: "Illustrative failure", error: "Price provider unavailable"}];
        wait(30);
        compare(chart().points.length, 0);
        var error = findChild(renderer, "aiChartError");
        verify(error.visible);
        compare(error.text, "Price provider unavailable");
        compare(chart().height, 276);
    }
}
