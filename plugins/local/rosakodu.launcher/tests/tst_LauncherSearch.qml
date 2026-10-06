import QtQuick
import QtTest
import "../LauncherSearch.js" as LauncherSearch

TestCase {
    name: "LauncherSearch"

    readonly property var entries: [
        { id: "org.mozilla.firefox", name: "Firefox", genericName: "Web Browser", keywords: ["internet", "web"], comment: "Browse the Web", icon: "firefox" },
        { id: "org.kde.dolphin", name: "Dolphin", genericName: "File Manager", keywords: ["files", "folders"], icon: "system-file-manager" },
        { id: "com.example.firetools", name: "Fire Tools", genericName: "Developer Utility", keywords: ["debug"], icon: "applications-development" },
        { id: "hidden.app", name: "Hidden App", genericName: "Secret", noDisplay: false, icon: "application-x-executable" },
        { id: "nodisplay.app", name: "No Display", noDisplay: true, icon: "application-x-executable" }
    ]

    function test_exactNameRanksAbovePrefixAndOtherMatches() {
        var rows = LauncherSearch.sortedEntries(entries, "firefox", function() { return false })
        compare(rows.length, 1)
        compare(rows[0].entry.id, "org.mozilla.firefox")
    }

    function test_prefixRanksAboveGenericKeywordMatch() {
        var extended = entries.concat([
            { id: "com.example.viewer", name: "Image Viewer", genericName: "Firefox companion", keywords: ["firefox"] }
        ])
        var rows = LauncherSearch.sortedEntries(extended, "fire", function() { return false })
        compare(rows[0].entry.id, "org.mozilla.firefox")
        compare(rows[1].entry.id, "com.example.firetools")
    }

    function test_searchesGenericNameKeywordsAndDesktopId() {
        compare(LauncherSearch.sortedEntries(entries, "file manager", function() { return false })[0].entry.id, "org.kde.dolphin")
        compare(LauncherSearch.sortedEntries(entries, "folders", function() { return false })[0].entry.id, "org.kde.dolphin")
        compare(LauncherSearch.sortedEntries(entries, "org.kde.dolphin", function() { return false })[0].entry.id, "org.kde.dolphin")
    }

    function test_bestMatchResolvesLegacyPinByNameOrDesktopId() {
        var rows = LauncherSearch.sortedEntries(entries, "", function() { return false })
        compare(LauncherSearch.bestMatch(rows, "Firefox").entry.id, "org.mozilla.firefox")
        compare(LauncherSearch.bestMatch(rows, "org.kde.dolphin.desktop").entry.id, "org.kde.dolphin")
        compare(LauncherSearch.bestMatch(rows, "missing"), null)
    }

    function test_bestMatchPrefersExactDesktopIdOverEarlierNameMatch() {
        var rows = LauncherSearch.sortedEntries([
            { id: "com.example.utility", name: "org.kde.dolphin", genericName: "Utility" },
            { id: "org.kde.dolphin", name: "Z Dolphin", genericName: "File Manager" }
        ], "", function() { return false })
        compare(LauncherSearch.bestMatch(rows, "org.kde.dolphin").entry.id, "org.kde.dolphin")
    }

    function test_matchingPinTokenReturnsLegacyIdentity() {
        var rows = LauncherSearch.sortedEntries(entries, "", function() { return false })
        compare(LauncherSearch.matchingToken(rows, ["Firefox", "org.kde.dolphin"], rows[0].entry),
                rows[0].entry.id === "org.kde.dolphin" ? "org.kde.dolphin" : "Firefox")
        compare(LauncherSearch.matchingToken(rows, ["Firefox"], { id: "missing", name: "Missing" }), "")
    }

    function test_filtersNoDisplayAndConfiguredHiddenEntries() {
        var rows = LauncherSearch.sortedEntries(entries, "", function(entry) { return entry.id === "hidden.app" })
        for (var i = 0; i < rows.length; i++) {
            verify(rows[i].entry.id !== "hidden.app")
            verify(rows[i].entry.id !== "nodisplay.app")
        }
    }

    function test_buildPinIndexCachesLegacyTokenLookup() {
        var rows = LauncherSearch.sortedEntries(entries, "", function() { return false })
        var index = LauncherSearch.buildPinIndex(rows, ["Firefox", "org.kde.dolphin"])
        compare(LauncherSearch.pinTokenFromIndex(index, { id: "org.mozilla.firefox" }), "Firefox")
        compare(LauncherSearch.pinTokenFromIndex(index, { id: "org.kde.dolphin.desktop" }), "org.kde.dolphin")
        compare(LauncherSearch.pinTokenFromIndex(index, { id: "missing" }), "")
        compare(LauncherSearch.pinTokenFromIndex(index, null), "")
    }

    function test_buildPinIndexIgnoresUnresolvableTokens() {
        var rows = LauncherSearch.sortedEntries(entries, "", function() { return false })
        var index = LauncherSearch.buildPinIndex(rows, ["missing", "Firefox"])
        compare(LauncherSearch.pinTokenFromIndex(index, { id: "org.mozilla.firefox" }), "Firefox")
        verify(LauncherSearch.pinTokenFromIndex(index, { id: "missing" }) === "")
    }
}
