import QtQuick
import QtTest
import "../FileSearch.js" as FileSearch

TestCase {
    name: "FileSearch"

    function test_mode() {
        verify(FileSearch.mode("f: notes"))
        verify(FileSearch.mode("F:"))
        verify(!FileSearch.mode("firefox"))
        verify(!FileSearch.mode("https://example.com/f:"))
        compare(FileSearch.terms("f:  config hypr  "), "config hypr")
        compare(FileSearch.terms("firefox"), "")
    }

    function test_pathsRemainSingleArguments() {
        var path = "/fixtures/test-home/notes ' $(touch nope)\n雪.txt"
        var row = {kind: "file", path: path}
        compare(FileSearch.command(row, false), ["uwsm-app", "--", "xdg-open", path])
        compare(FileSearch.command(row, true), ["uwsm-app", "--", "xdg-open", "/fixtures/test-home"])
        compare(FileSearch.command({kind: "file", path: "/notes"}, true)[3], "/")
        compare(FileSearch.command({kind: "file", path: "--help"}, false).length, 0)
        compare(FileSearch.command({kind: "file", path: "/bad\0path"}, false).length, 0)
        compare(FileSearch.command(null, false).length, 0)
    }

    function test_parseRows() {
        var row = {kind: "file", path: "/fixtures/test-home/a\nb.txt", title: "a\nb.txt", parent: "/fixtures/test-home", isDirectory: false}
        var parsed = FileSearch.parseRows(JSON.stringify([row, {kind: "file", path: "relative"}, null]))
        compare(parsed.length, 1)
        compare(parsed[0].path, row.path)
        var failed = false
        try { FileSearch.parseRows("{}") } catch (e) { failed = true }
        verify(failed)
    }

    function test_homeDisplay() {
        compare(FileSearch.displayParent("/fixtures/test-home", "/fixtures/test-home"), "~")
        compare(FileSearch.displayParent("/fixtures/test-home/Documents", "/fixtures/test-home"), "~/Documents")
        compare(FileSearch.displayParent("/fixtures/test-home-other", "/fixtures/test-home"), "/fixtures/test-home-other")
    }
}
