import QtQuick
import Quickshell

// Offline geometry check for the detached window's measured minimum size.
// Requires a dedicated scratch HOME; never starts a store, broker, fixture or
// provider. It only measures how the real WorkspaceWindow reacts when
// CSV-preview chrome plus a capped long draft grows past the old fixed
// 720x560 floor, because a disclosure clipped past the window edge has no
// scroll path back into view.
ShellRoot {
    id: check
    property string home: Quickshell.env("HOME")
    property var failures: []
    property var condition: null
    property var continuation: null
    property double deadline: 0
    property var actions: []
    property int actionIndex: 0
    property var window: null

    function eq(actual, expected, message) {
        if (JSON.stringify(actual) !== JSON.stringify(expected))
            failures.push(message + ": " + JSON.stringify(actual) + " != " + JSON.stringify(expected))
    }
    function until(test, done) {
        condition = test
        continuation = done
        deadline = Date.now() + 4000
        poll.restart()
    }
    function delay(done) {
        var at = Date.now() + 150
        until(function() { return Date.now() >= at }, function() { done() })
    }
    function findByName(root, name) {
        if (!root) return null
        if (root.objectName === name) return root
        var kids = root.children || []
        for (var i = 0; i < kids.length; ++i) {
            var hit = findByName(kids[i], name)
            if (hit) return hit
        }
        return null
    }
    function next() {
        if (actionIndex >= actions.length) { finish(); return }
        actions[actionIndex++]()
    }
    function finish() {
        if (window) window.destroy()
        if (failures.length) {
            console.error(failures.join("\n"))
            Qt.exit(1)
        } else {
            console.log("AiDetachedWindow: measured minimum size follows preview chrome, grows a visible window and keeps disclosures inside the window passed")
            Qt.quit()
        }
    }

    ListModel { id: turnRows }
    QtObject {
        id: stubService
        property bool busy: false
        property bool stopping: false
        property bool loadingLatest: false
        property bool attachmentBlocked: false
        property bool canContinue: false
        property bool windowActive: false
        property string stateRoot: check.home + "/state"
        property string attachment: ""
        property string activity: ""
        property string draft: ""
        property string previewStatus: "idle"
        property var previewData: null
        property string previewError: ""
        property var checklistStates: ({})
        property var turns: []
        property var uiStates: ({})
        property alias turnModel: turnRows
        readonly property var latest: turns.length ? turns[turns.length - 1] : null
        function retryAttachmentPreview() { }
        function submit() { }
        function stop() { }
        function newConversation() { turns = [] }
    }

    Component {
        id: detached
        WorkspaceWindow {
            service: stubService
            foreground: "#f1f2f4"
            background: "#1b1c20"
            accent: "#b4c4dc"
        }
    }

    function fullPreview() {
        var cols = [], rows = []
        for (var ci = 0; ci < 20; ++ci) cols.push("Column " + ci)
        for (var ri = 0; ri < 10; ++ri) {
            var row = []
            for (var cj = 0; cj < 20; ++cj) row.push(ri + "/" + cj)
            rows.push(row)
        }
        return {
            columns: cols, rows: rows,
            previewRows: 10, sampleRows: 10, columnCount: 1000, totalRows: 99999,
            truncated: true, columnsTruncated: true, cellsTruncated: true,
            note: "Sampled from a much larger source file; this is not a complete copy."
        }
    }

    function begin() {
        window = detached.createObject(check)
        if (!window) { console.error("WorkspaceWindow did not instantiate"); Qt.exit(1); return }
        window.visible = true
        window.width = 720
        window.height = 560
        actions = [
            function() {
                check.delay(function() {
                    check.eq(Math.round(check.window.minimumSize.height), 560,
                        "a plain detached window keeps the declared floor")
                    stubService.attachment = check.home + "/rents.csv"
                    stubService.previewData = check.fullPreview()
                    stubService.previewStatus = "ready"
                    stubService.draft = "line one\nline two\nline three\nline four\nline five\n"
                        + "line six\nline seven\nline eight\nline nine\nline ten"
                    check.until(function() { return check.window.minimumSize.height > 560 },
                        function(ok) {
                            check.eq(ok, true, "full preview chrome raises the measured floor above 560")
                            check.eq(check.window.minimumSize.height >= 660
                                && check.window.minimumSize.height <= 680, true,
                                "real-window floor stays in the pinned band around 669, got "
                                + check.window.minimumSize.height)
                            if (!ok) { check.finish(); return }
                            check.until(function() {
                                return check.window.height >= check.window.minimumSize.height
                            }, function(grew) {
                                check.eq(grew, true,
                                    "a visible window grows with its floor instead of clipping content")
                                if (!grew) { check.finish(); return }
                                check.next()
                            })
                        })
                })
            },
            function() {
                check.window.height = Math.ceil(check.window.minimumSize.height)
                check.delay(function() {
                    var disclosure = check.findByName(check.window.contentItem, "aiCsvPreviewDisclosure")
                    check.eq(disclosure !== null && disclosure.visible, true, "the sampling disclosure renders")
                    if (disclosure) {
                        var bottom = disclosure.mapToItem(check.window.contentItem, 0, disclosure.height).y
                        check.eq(bottom <= check.window.contentItem.height, true,
                            "disclosure bottom " + bottom + " fits inside window height "
                            + check.window.contentItem.height)
                    }
                    var loader = check.findByName(check.window.contentItem, "aiCsvPreviewLoader")
                    if (loader) {
                        var loaderBottom = loader.mapToItem(check.window.contentItem, 0, loader.height).y
                        check.eq(loaderBottom <= check.window.contentItem.height, true,
                            "preview chrome bottom " + loaderBottom + " stays inside the window")
                    } else check.failures.push("preview loader missing from the detached window")
                    check.next()
                })
            },
            function() {
                // A restored conversation raises the floor again by its reserve.
                var before = check.window.minimumSize.height
                stubService.turns = [{id: 1, prompt: "Topic", attachment: "", status: "done",
                    error: "", warning: "", answer: "Answer", blocks: [], suggestions: []}]
                check.until(function() { return check.window.minimumSize.height >= before + 150 },
                    function(grew) {
                        check.eq(grew, true, "conversation room adds its reserve to the floor")
                        check.until(function() {
                            return check.window.height >= check.window.minimumSize.height
                        }, function(taller) {
                            check.eq(taller, true, "the window grows again for conversation room")
                            check.next()
                        })
                    })
            }
        ]
        next()
    }

    Timer {
        id: poll
        interval: 20
        repeat: true
        onTriggered: {
            if (check.condition && check.condition()) {
                stop()
                var done = check.continuation
                check.continuation = null
                done(true)
            } else if (Date.now() >= check.deadline) {
                stop()
                var failed = check.continuation
                check.continuation = null
                failed(false)
            }
        }
    }

    Component.onCompleted: {
        if (home.indexOf("/tmp/opencode/") !== 0) {
            console.error("Use a dedicated /tmp/opencode scratch HOME for the detached-window check")
            Qt.exit(2)
            return
        }
        begin()
    }
    Timer {
        interval: 30000
        running: true
        onTriggered: { check.failures.push("Detached-window check exceeded global deadline"); check.finish() }
    }
}
