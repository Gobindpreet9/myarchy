import QtQuick
import Quickshell
import Quickshell.Io

// Offline Quickshell lifecycle check for AiCsvSource against the in-memory
// tests/ai_csv_source_stub.py worker. Requires a dedicated scratch HOME named
// /tmp/opencode/ai-preview-check-* and a nested XDG_STATE_HOME; the stub never
// opens a file, a provider or the requested paths.
ShellRoot {
    id: check
    property string home: Quickshell.env("HOME")
    property string stub: decodeURIComponent(Qt.resolvedUrl("tests/ai_csv_source_stub.py").toString().replace(/^file:\/\//, ""))
    property var component: null
    property var source: null
    property var progress: []
    property var failures: []
    property var condition: null
    property var continuation: null
    property double deadline: 0
    property var actions: []
    property int actionIndex: 0
    property double capturedPid: 0
    property double firstPid: 0
    property bool checkingAlive: true
    property int baseId: 0
    property int baseGeneration: 0

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
    function expect(test, message, done) {
        until(test, function(ok) {
            if (!ok) failures.push("Timed out: " + message + " (status " + source.status + ", error " + source.error + ")")
            done()
        })
    }
    function delay(milliseconds, done) {
        var at = Date.now() + milliseconds
        until(function() { return Date.now() >= at }, function() { done() })
    }
    function loaded() {
        return source.status === "ready" && source.page !== null && !source.busy
    }
    function pid() { return Number(source._worker.processId) }
    function make(props) {
        if (source) source.destroy()
        var base = {workerScript: stub, stateRoot: Quickshell.env("XDG_STATE_HOME") + "/csv-source",
            surfacesVisible: true, idleInterval: 400, registerTimeout: 700, requestTimeout: 700, pageTimeout: 400}
        for (var key in props) base[key] = props[key]
        progress = []
        source = component.createObject(check, base)
        if (!source) { console.error(component.errorString()); Qt.exit(1) }
    }
    function next() {
        if (actionIndex >= actions.length) { finish(); return }
        actions[actionIndex++]()
    }
    function finish() {
        if (source) source.destroy()
        if (failures.length) {
            console.error(failures.join("\n"))
            Qt.exit(1)
        } else {
            console.log("AiCsvSource: lazy start, register progress, paging, debounce/supersede, stale drops, crash/kill restart, watchdogs, idle stop, token invalidation, static errors and destruction passed")
            Qt.quit()
        }
    }

    function begin() {
        component = Qt.createComponent(Qt.resolvedUrl("AiCsvSource.qml"))
        if (component.status !== Component.Ready) { console.error(component.errorString()); Qt.exit(1); return }
        actions = [
            // 1. Nothing requested, nothing running.
            function() {
                make({})
                eq(source.stateRoot, Quickshell.env("XDG_STATE_HOME") + "/csv-source", "State root override is effective")
                eq(source.workerScript, stub, "Worker script override is effective")
                eq(source.setView(-1, 1, "x"), false, "setView needs a ready source")
                eq(source.goPage(1), false, "goPage needs a ready source")
                eq(source.verify(), false, "verify needs a source id")
                eq(source.verify("nope"), false, "verify rejects a malformed id")
                source.close()
                source.invalidate()
                source.surfacesVisible = false
                source.surfacesVisible = true
                eq(source.register(""), false, "Empty path is refused locally")
                eq(source.error, "Choose a CSV file inside your home directory.", "Local refusal is static")
                eq(source.register(home + "/" + "x".repeat(5000)), false, "Oversized path is refused locally")
                eq(source.open("bad"), false, "Malformed source id is refused locally")
                eq(source.error, "CSV source is unavailable.", "Malformed id error is static")
                delay(300, function() {
                    eq(source._phase, "stopped", "No request starts no process")
                    eq(source._worker.running, false, "Worker is not running")
                    eq(pid(), 0, "No worker pid exists")
                    next()
                })
            },
            // 2. Register with progress.
            function() {
                source.invalidate()
                eq(source.status, "idle", "invalidate returns to idle")
                eq(source.register(home + "/progress-rows60.csv"), true, "register accepts a path")
                eq(source.status, "registering", "register starts registering")
                expect(loaded, "register reaches ready with the first page", function() {
                    eq(progress, [20, 40, 60], "Progress rows are monotone and end at the exact count")
                    eq(source.meta.rows, 60, "Register meta rows")
                    eq(source.meta.columns, ["id", "city", "amount", "day"], "Register meta columns")
                    eq(source.meta.stats.length, 4, "One stats entry per column")
                    eq(source.viewRows, 60, "Unfiltered view is every row")
                    eq(source.page.rows.length, 25, "First page has 25 rows")
                    eq(source.page.rows[0], ["1", "City1", "10", "2024-02-02"], "First page content")
                    eq(source.page.firstRow, 1, "First page starts at source row 1")
                    eq(source.page.pageCount, 3, "Three pages")
                    eq(source.error, "", "No error")
                    eq(source.sourceId, source.meta.sourceId, "Source id is exposed")
                    firstPid = pid()
                    capturedPid = firstPid
                    check.next()
                })
            },
            // 3. Paging.
            function() {
                eq(source.goPage(2), true, "goPage accepts the last page")
                expect(function() { return source.page.page === 2 && !source.busy }, "last page arrives", function() {
                    eq(source.page.rows.length, 10, "Last page is short")
                    eq(source.page.firstRow, 51, "Last page first source row")
                    eq(source.goPage(99), true, "goPage clamps an over-range page")
                    expect(function() { return source.page.page === 2 && !source.busy }, "clamped page settles", function() {
                        eq(source.page.page, 2, "Over-range page clamps to the last page")
                        eq(source.goPage(-1), false, "Negative page refused")
                        eq(source.goPage(1.5), false, "Fractional page refused")
                        eq(source.goPage(0), true, "Back to page 0")
                        expect(function() { return source.page.page === 0 && !source.busy }, "page 0 returns", next)
                    })
                })
            },
            // 4. Debounce coalesces keystrokes into one view request.
            function() {
                baseId = source._nextId
                baseGeneration = source.generation
                eq(source.setView(-1, 1, "c"), true, "setView accepts a filter")
                source.setView(-1, 1, "ci")
                source.setView(-1, 1, "city3")
                eq(source.viewPending, true, "A view is pending during the debounce")
                eq(source._nextId, baseId, "No request is sent before the debounce fires")
                expect(function() { return loaded() && source.viewRows === 9 }, "filtered view settles", function() {
                    eq(source._nextId - baseId, 2, "Three keystrokes made one view and one page request")
                    eq(source.generation, baseGeneration + 3, "Every keystroke bumped the generation")
                    eq(source.page.viewRows, 9, "Page agrees with the view")
                    eq(source.viewPending, false, "View settled")
                    check.next()
                })
            },
            // 5. Sorting is part of the view.
            function() {
                source.setView(2, -1, "")
                expect(function() { return loaded() && source.viewRows === 60 && source.page.rows[0][2] === "600" }, "descending sort arrives", function() {
                    eq(source.page.rows[0], ["60", "City4", "600", "2024-01-05"], "Descending amount leads with the maximum")
                    eq(source.setView(99, 1, ""), false, "Out-of-range sort column refused")
                    eq(source.setView(0, 0, ""), false, "Direction must be 1 or -1")
                    check.next()
                })
            },
            // 6. A stale in-flight view is dropped (the worker says Superseded).
            function() {
                source.setView(-1, 1, "slow")
                expect(function() { return source._jobs.length === 1 && source._jobs[0].op === "view" && source._jobs[0].written },
                    "slow view is in flight", function() {
                    source.setView(-1, 1, "city1")
                    expect(function() { return loaded() && source.viewRows === 9 }, "newer view wins", function() {
                        eq(source.error, "", "Superseded answer is dropped silently")
                        eq(source.page.viewRows, 9, "Page belongs to the newer view")
                        eq(source.page.rows[0][1], "City1", "Newer filter content")
                        check.next()
                    })
                })
            },
            // 7. A worker answer for the wrong generation is an invalid response, not applied.
            function() {
                source.setView(-1, 1, "wronggen")
                expect(function() { return !source.busy && source.error !== "" }, "wrong generation is rejected", function() {
                    eq(source.error, "CSV source returned an invalid response.", "Wrong generation is a static invalid-response error")
                    eq(source.retryable, true, "Invalid response is retryable")
                    eq(source.status, "ready", "A failed view leaves the source ready")
                    eq(source.page.viewRows, 9, "The previous page is kept")
                    source.setView(-1, 1, "")
                    expect(function() { return loaded() && source.viewRows === 60 && source.error === "" }, "retry recovers", next)
                })
            },
            // 8. verify (before or without open) and open by id.
            function() {
                source.verify("src-0000003c00000020")
                expect(function() { return source.verifyState === "originChanged" }, "verify reports a changed origin", function() {
                    source.verify()
                    expect(function() { return source.verifyState === "ready" }, "verify of the current source is ready", function() {
                        eq(source.open("src-0000001400000000"), true, "open accepts a well-formed id")
                        eq(source.status, "registering", "open reads as registering")
                        expect(loaded, "open reaches ready and the first page", function() {
                            eq(source.meta.rows, 20, "Opened source rows")
                            eq(source.page.rows.length, 20, "Opened source page")
                            eq(pid(), firstPid, "Everything so far used one worker process")
                            check.next()
                        })
                    })
                })
            },
            // 9. close() tells the running worker and returns to idle without killing it.
            function() {
                source.close()
                eq(source.status, "idle", "close invalidates")
                eq(source.meta, null, "close clears meta")
                delay(200, function() {
                    eq(source._phase, "running", "close keeps the retained worker")
                    eq(source.error, "", "close raised no error")
                    check.next()
                })
            },
            // 10. Late answers after invalidation are discarded.
            function() {
                source.register(home + "/lateview-rows60.csv")
                expect(loaded, "source ready for the stale tests", function() {
                    source.verify()
                    source.invalidate()
                    delay(300, function() {
                        eq(source.verifyState, "", "Late verify cannot repopulate an invalidated source")
                        eq(source.status, "idle", "Late verify leaves the source idle")
                        source.register(home + "/lateview-rows60.csv")
                        expect(loaded, "source ready again", function() {
                            source.setView(-1, 1, "slow")
                            expect(function() { return source._jobs.length === 1 && source._jobs[0].op === "view" && source._jobs[0].written },
                                "slow view is in flight", function() {
                                source.invalidate()
                                delay(700, function() {
                                    eq(source.status, "idle", "Late view cannot revive an invalidated source")
                                    eq(source.meta, null, "Late view leaves no meta")
                                    eq(source.page, null, "Late view leaves no page")
                                    eq(source.viewRows, -1, "Late view leaves no view rows")
                                    eq(source.error, "", "Late view leaves no error")
                                    eq(source._jobs.length, 0, "Stale job was consumed")
                                    eq(pid(), firstPid, "Cheap stale work does not kill the worker")
                                    source.receive("{\"id\":999999,\"ok\":false,\"error\":\"x\"}")
                                    eq(source.status, "idle", "Unknown ids are ignored")
                                    check.next()
                                })
                            })
                        })
                    })
                })
            },
            // 11. A stale register abandons the long index (the worker is killed) and the new one wins.
            function() {
                source.register(home + "/slow-rows60.csv")
                expect(function() { return source._jobs.length === 1 && source._jobs[0].written }, "slow register is in flight", function() {
                    source.register(home + "/replacement-rows10.csv")
                    expect(loaded, "replacement register reaches ready", function() {
                        eq(source.meta.rows, 10, "Only the newer register applies")
                        eq(source.page.rows.length, 10, "Newer page applies")
                        eq(pid() !== firstPid, true, "Abandoned index restarted the worker")
                        eq(source.error, "", "No error from the abandoned index")
                        check.next()
                    })
                })
            },
            // 12. Static error allowlist.
            function() {
                source.register(home + "/evil-rows5.csv")
                expect(function() { return source.status === "error" }, "hostile worker text is replaced", function() {
                    eq(source.error, "CSV source is unavailable.", "Non-allowlisted worker text becomes the generic string")
                    eq(source.error.indexOf("SECRET"), -1, "Worker text is never shown")
                    eq(source.meta, null, "Failure clears meta")
                    source.register(home + "/error-rows5.csv")
                    expect(function() { return source.status === "error" && source.error !== "CSV source is unavailable." }, "allowlisted text passes", function() {
                        eq(source.error, "Attachment is unavailable or is a symbolic link.", "Allowlisted worker text is shown verbatim")
                        eq(source.retryable, false, "Allowlisted refusal is not retryable")
                        source.register("relative.csv")
                        expect(function() { return source.status === "error" && source.error === "Choose a CSV file inside your home directory." },
                            "worker path refusal is shown", next)
                    })
                })
            },
            // 13. Kill the worker mid-request: static retryable error, then lazy restart + re-open.
            function() {
                source.register(home + "/pagehang-rows60.csv")
                expect(function() { return source._jobs.length === 1 && source._jobs[0].op === "page" && source._jobs[0].written },
                    "page 0 hangs in flight", function() {
                    capturedPid = pid()
                    eq(capturedPid > 0, true, "Worker has a pid")
                    source.stopWorker()
                    expect(function() { return source.error !== "" && !source.busy }, "killed request fails", function() {
                        eq(source.error, "CSV source stopped. Try again.", "Killed worker gives the static stopped error")
                        eq(source.retryable, true, "Stopped is retryable")
                        eq(source.status, "ready", "Page failure leaves the source ready")
                        eq(source.page, null, "No page was fabricated")
                        source.goPage(1)
                        expect(function() { return source.page !== null && source.page.page === 1 && !source.busy }, "restarted worker serves a re-opened source", function() {
                            eq(pid() !== capturedPid, true, "A fresh worker serves the retry")
                            eq(source.error, "", "Success clears the error")
                            check.next()
                        })
                    })
                })
            },
            // 14. A page-request watchdog turns a hung worker into a static error and kills it.
            function() {
                source.register(home + "/pagehang-rows60.csv")
                expect(function() { return source.error === "CSV source timed out. Try again." }, "page watchdog fires", function() {
                    eq(source.retryable, true, "Timeout is retryable")
                    eq(source.status, "ready", "Page timeout leaves the source ready")
                    expect(function() { return source._phase === "stopped" }, "hung worker is killed", function() {
                        eq(source._worker.running, false, "Killed worker is gone")
                        check.next()
                    })
                })
            },
            // 15. A worker that crashes by itself mid-request.
            function() {
                source.register(home + "/pagecrash-rows300.csv")
                expect(loaded, "crash source ready", function() {
                    source.goPage(7)
                    expect(function() { return source.error === "CSV source stopped. Try again." && !source.busy }, "crash fails the in-flight page", function() {
                        eq(source.page.page, 0, "Previous page is kept")
                        source.goPage(2)
                        expect(function() { return source.page.page === 2 && !source.busy && source.error === "" }, "retry after crash works", next)
                    })
                })
            },
            // 16. Work queued while the worker is going away restarts it.
            function() {
                source.register(home + "/rows60.csv")
                expect(loaded, "source ready before the queued restart", function() {
                    source.setView(2, -1, "city")
                    expect(function() { return loaded() && source.viewRows === 60 }, "sorted view applied", function() {
                        capturedPid = pid()
                        source._halt()
                        eq(source.goPage(1), true, "goPage queues while the worker stops")
                        eq(source._jobs[0].written, false, "Queued job was not written to the dying worker")
                        expect(function() { return source.page.page === 1 && !source.busy }, "queued page runs on a fresh worker", function() {
                            eq(pid() !== capturedPid, true, "Queued work restarted the worker")
                            eq(source.error, "", "Queued work raised no error")
                            eq(source.page.rows[0][2], "350", "The sorted view was re-applied before the page (page 1 of amount descending)")
                            check.next()
                        })
                    })
                })
            },
            // 17. Register watchdog, then recovery on the same object.
            function() {
                source.register(home + "/hang-rows60.csv")
                expect(function() { return source.status === "error" }, "register watchdog fires", function() {
                    eq(source.error, "CSV source timed out. Try again.", "Register timeout is static")
                    eq(source.retryable, true, "Register timeout is retryable")
                    expect(function() { return source._phase === "stopped" }, "hung register worker is killed", function() {
                        source.register(home + "/rows60.csv")
                        expect(loaded, "register recovers after a watchdog", next)
                    })
                })
            },
            // 18. A clean exit mid-request is retried once, then fails statically.
            function() {
                source.register(home + "/quit-rows60.csv")
                expect(function() { return source.status === "error" }, "unanswered clean exits fail", function() {
                    eq(source.error, "CSV source stopped. Try again.", "Second clean exit fails statically")
                    source.register(home + "/rows60.csv")
                    expect(loaded, "source recovers after clean exits", next)
                })
            },
            // 19. Idle stop once surfaces are hidden, with state kept and lazy restart.
            function() {
                capturedPid = pid()
                eq(capturedPid > 0, true, "Worker is running before the idle test")
                delay(700, function() {
                    eq(source._phase, "running", "Visible surfaces keep the worker")
                    source.surfacesVisible = false
                    expect(function() { return source._phase === "stopped" }, "hidden surfaces stop the worker after the idle interval", function() {
                        eq(source.status, "ready", "Idle stop keeps the source state")
                        eq(source.page !== null, true, "Idle stop keeps the page")
                        eq(source.error, "", "Idle stop is not an error")
                        source.goPage(1)
                        expect(function() { return source.page.page === 1 && !source.busy }, "next request restarts the worker", function() {
                            eq(pid() !== capturedPid, true, "A new worker served the request")
                            eq(source.error, "", "Restart after idle is silent")
                            expect(function() { return source._phase === "stopped" }, "idle timer stops it again", next)
                        })
                    })
                })
            },
            // 20. The worker's own idle exit leaves a consistent object.
            function() {
                make({workerIdle: "1", idleInterval: 60000})
                source.register(home + "/rows60.csv")
                expect(loaded, "source ready under a 1 s worker idle", function() {
                    expect(function() { return source._phase === "stopped" }, "worker exits by itself when idle", function() {
                        eq(source.error, "", "Self-exit is silent")
                        eq(source.status, "ready", "Self-exit keeps the source")
                        source.goPage(1)
                        expect(function() { return source.page.page === 1 && !source.busy }, "request after self-exit restarts", next)
                    })
                })
            },
            // 21. Destruction releases the worker.
            function() {
                make({})
                source.register(home + "/rows60.csv")
                expect(loaded, "source ready before destruction", function() {
                    capturedPid = pid()
                    checkingAlive = true
                    helper.command = ["/usr/bin/python3", "-B", "-u", stub, "--check-alive", String(capturedPid)]
                    helper.running = true
                })
            }
        ]
        next()
    }

    Connections {
        target: check.source
        function onProgressRowsChanged() { if (check.source) check.progress.push(check.source.progressRows) }
    }
    Process {
        id: helper
        clearEnvironment: true
        environment: ({HOME: check.home, PATH: "/usr/bin:/bin", PYTHONDONTWRITEBYTECODE: "1"})
        onExited: function(code) {
            check.eq(code, 0, check.checkingAlive ? "captured PID is the stub worker" : "destroyed source's worker is gone")
            if (code !== 0) { check.finish(); return }
            if (check.checkingAlive) {
                check.checkingAlive = false
                check.source.destroy()
                check.source = null
                Qt.callLater(function() {
                    helper.command = ["/usr/bin/python3", "-B", "-u", check.stub, "--check-gone", String(check.capturedPid)]
                    helper.running = true
                })
            } else check.next()
        }
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
        var state = Quickshell.env("XDG_STATE_HOME")
        if (home.indexOf("/tmp/opencode/ai-preview-check-") !== 0 || state.indexOf(home + "/") !== 0) {
            console.error("Use dedicated /tmp/opencode/ai-preview-check-* HOME and a nested scratch XDG_STATE_HOME")
            Qt.exit(2)
            return
        }
        begin()
    }
    Timer {
        interval: 60000
        running: true
        onTriggered: { check.failures.push("CSV source check exceeded global deadline"); check.finish() }
    }
}
