import QtQuick
import QtTest
import "../AppState.js" as AppState

TestCase {
    name: "LauncherAppState"

    function test_parseRecentIdsRejectsMalformedInput() {
        compare(AppState.parseRecentIds("not json").length, 0)
        compare(AppState.parseRecentIds("{}").length, 0)
    }

    function test_parseRecentIdsNormalizesAndDeduplicates() {
        var ids = AppState.parseRecentIds('["org.mozilla.firefox.desktop", "org.mozilla.firefox", "com.mitchellh.ghostty"]')
        compare(ids.length, 2)
        compare(ids[0], "org.mozilla.firefox")
        compare(ids[1], "com.mitchellh.ghostty")
    }

    function test_touchRecentMovesAppToFrontAndCapsList() {
        var before = ["one", "two", "three", "four"]
        var next = AppState.touchRecent(before, "three.desktop", 3)
        compare(next.length, 3)
        compare(next[0], "three")
        compare(next[1], "one")
        compare(next[2], "two")
    }

    function test_flattenPinnedPreservesFolderOrder() {
        var raw = JSON.stringify({ pinned: [
            "com.mitchellh.ghostty",
            { id: "stack_creative", isStack: true, apps: ["org.kde.krita.desktop", "org.inkscape.Inkscape"] }
        ]})
        var ids = AppState.flattenPinned(raw)
        compare(ids.length, 3)
        compare(ids[0], "com.mitchellh.ghostty")
        compare(ids[1], "org.kde.krita")
        compare(ids[2], "org.inkscape.Inkscape")
    }

    function test_launchCommandUsesUnstrippedEntryIdAsFilenameBase() {
        var normal = AppState.desktopLaunchCommand("org.mozilla.firefox")
        compare(normal.length, 4)
        compare(normal[0], "uwsm-app")
        compare(normal[1], "--")
        compare(normal[2], "gtk-launch")
        compare(normal[3], "org.mozilla.firefox.desktop")
        // Basenames may end in ".desktop" (ai.opencode.desktop.desktop):
        // the id is never stripped, the suffix always appended.
        var doubled = AppState.desktopLaunchCommand("ai.opencode.desktop")
        compare(doubled.length, 4)
        compare(doubled[3], "ai.opencode.desktop.desktop")
        compare(AppState.desktopLaunchCommand("; touch /tmp/not-a-query").length, 0)
        compare(AppState.desktopLaunchCommand("").length, 0)
    }

    function test_launchEligibilityDoesNotRequireScopedAppLibrary() {
        verify(AppState.canLaunchEntry({ id: "org.mozilla.firefox" }, false))
        verify(!AppState.canLaunchEntry({ id: "org.mozilla.firefox" }, true))
        verify(!AppState.canLaunchEntry(null, false))
    }

    function test_runningAppFocusRequiresExactDesktopOrWindowClass() {
        verify(AppState.matchesRunningApp({ id: "ai.opencode.desktop" }, "ai.opencode.desktop"))
        verify(AppState.matchesRunningApp({ id: "org.mozilla.firefox" }, "org.mozilla.firefox.desktop"))
        verify(AppState.matchesRunningApp({ id: "org.example.editor", startupWMClass: "EditorWindow" }, "EditorWindow"))
        verify(!AppState.matchesRunningApp({ id: "org.example.editor" }, "org.example.viewer"))
        verify(!AppState.matchesRunningApp({ id: "org.example.editor" }, ""))
    }

    function test_isPinnedHandlesDesktopSuffix() {
        var raw = JSON.stringify({ pinned: ["org.mozilla.firefox"] })
        verify(AppState.isPinned(raw, "org.mozilla.firefox.desktop"))
        verify(!AppState.isPinned(raw, "org.kde.dolphin.desktop"))
    }

    function test_normalizeTranslucencyClampsPercentages() {
        compare(AppState.normalizeTranslucency(undefined, 0), 0)
        compare(AppState.normalizeTranslucency("35", 0), 35)
        compare(AppState.normalizeTranslucency(-5, 0), 0)
        compare(AppState.normalizeTranslucency(100, 0), 100)
        compare(AppState.normalizeTranslucency(110, 0), 100)
        compare(AppState.normalizeTranslucency("opaque", 0), 0)
    }

    function test_readLauncherTranslucencyMigratesAndKeepsIndependentSetting() {
        compare(AppState.readLauncherTranslucency('{"surfaceOpacity": 0.72}'), 28)
        compare(AppState.readLauncherTranslucency('{"dockTranslucency": 10, "launcherTranslucency": 85}'), 85)
        compare(AppState.readLauncherTranslucency('{"surfaceOpacity": 0.72, "launcherTranslucency": 0}'), 0)
        compare(AppState.readLauncherTranslucency('not json'), 0)
        compare(AppState.readLauncherTranslucency('{}'), 0)
    }

    function test_urlNormalizationRejectsNonLinks() {
        compare(AppState.normalizeUrl("example.com"), "https://example.com")
        compare(AppState.normalizeUrl("https://example.com/a?b=c"), "https://example.com/a?b=c")
        compare(AppState.normalizeUrl("not a query"), "")
        compare(AppState.normalizeUrl("firefox"), "")
        compare(AppState.normalizeUrl("; touch /tmp/x"), "")
        compare(AppState.normalizeUrl(""), "")
    }

    function test_urlOpenCommandUsesFixedArgvPath() {
        var command = AppState.urlOpenCommand("example.com")
        compare(command.length, 4)
        compare(command[0], "uwsm-app")
        compare(command[1], "--")
        compare(command[2], "xdg-open")
        compare(command[3], "https://example.com")
        compare(AppState.urlOpenCommand("not a query").length, 0)
        compare(AppState.urlOpenCommand("; touch /tmp/x").length, 0)
    }

    function test_webSearchUsesFixedBaseWithEncodedQuery() {
        var url = AppState.webSearchUrl("firefox browser")
        verify(url.indexOf("https://www.google.com/search?q=") === 0)
        verify(url.indexOf("firefox%20browser") !== -1)
        var command = AppState.webSearchCommand("firefox browser")
        compare(command.length, 4)
        compare(command[0], "uwsm-app")
        compare(command[2], "xdg-open")
        compare(command[3], url)
        compare(AppState.webSearchCommand("   ").length, 0)
        compare(AppState.webSearchCommand("; rm -rf ~").length, 4)
        verify(AppState.webSearchCommand("; rm -rf ~")[3].indexOf("%3B") !== -1)
    }

    function test_mathEvaluationIsPureArithmetic() {
        verify(AppState.isMathQuery("2 + 2"))
        verify(AppState.isMathQuery("(3 + 4) * 2"))
        verify(!AppState.isMathQuery("firefox"))
        verify(!AppState.isMathQuery("2 + touch"))
        compare(AppState.evaluateMath("2 + 2"), 4)
        compare(AppState.evaluateMath("(3 + 4) * 2"), 14)
        compare(AppState.evaluateMath("10 / 4"), 2.5)
        verify(AppState.evaluateMath("1 / 0") === null)
        verify(AppState.evaluateMath("2 + ") === null)
        compare(AppState.formatMathResult(2.5), "2.5")
        compare(AppState.formatMathResult(4), "4")
    }

    function test_buildActionRowsNeverExecutesQueryText() {
        var calcRows = AppState.buildActionRows("2 + 3")
        verify(calcRows.length >= 3)
        compare(calcRows[0].kind, "askAi", "Ask AI is explicit discovery and leads the actions")
        compare(calcRows[0].query, "2 + 3", "The transfer carries the exact query as a draft")
        compare(calcRows[1].kind, "calc")
        compare(calcRows[1].resultText, "5")
        var urlRows = AppState.buildActionRows("example.com")
        compare(urlRows[1].kind, "url", "App matches keep their ranking above the fixed actions")
        compare(urlRows[1].url, "https://example.com")
        var searchRows = AppState.buildActionRows("firefox")
        compare(searchRows[searchRows.length - 1].kind, "search")
        compare(AppState.buildActionRows("   ").length, 0)
        compare(AppState.buildActionRows("").length, 0)
    }
}
