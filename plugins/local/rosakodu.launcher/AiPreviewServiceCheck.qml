import QtQuick
import Quickshell
import Quickshell.Io

// Offline integration check. Use a FRESH /tmp/opencode/ai-preview-check-*
// HOME and nested XDG_STATE_HOME. The existing preview stub creates/replaces
// only synthetic rents.csv/malformed.csv fixtures; the broker is always stubbed.
ShellRoot {
    id: check
    property string home: Quickshell.env("HOME")
    property string fixtureScript: decodeURIComponent(Qt.resolvedUrl("tests/ai_preview_stub.py").toString().replace(/^file:\/\//, ""))
    property string brokerScript: decodeURIComponent(Qt.resolvedUrl("tests/ai_service_stub.py").toString().replace(/^file:\/\//, ""))
    property string csvStub: decodeURIComponent(Qt.resolvedUrl("tests/ai_csv_source_stub.py").toString().replace(/^file:\/\//, ""))
    property var service: null
    property var failures: []
    property var condition: null
    property var continuation: null
    property var fixtureDone: null
    property double deadline: 0
    property var actions: []
    property int actionIndex: 0
    property double savedToken: 0
    property var savedData: null

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
    function settled(status, done) {
        until(function() { return service.previewStatus === status && !service.attachmentPreview._occupied }, function(ok) {
            eq(ok, true, "Preview settles to " + status + " / " + service.previewError)
            done()
        })
    }
    function delay(done) {
        var at = Date.now() + 150
        until(function() { return Date.now() >= at }, function() { done() })
    }
    function next() {
        if (actionIndex >= actions.length) { finish(); return }
        actions[actionIndex++]()
    }
    function protectedState() {
        return {draft: service.draft, attachment: service.attachment, turnId: service.turnId,
            turns: service.turns, modelCount: service.turnModel.count, agent: service.agent,
            workspaceId: service.workspaceId, sessionId: service.sessionId,
            pending: service.pending, busy: service.busy, brokerLive: service.brokerLive}
    }
    function rejectsWithoutMutation(label) {
        var before = protectedState()
        eq(service.submit(service.draft), false, label + " rejects submission")
        eq(protectedState(), before, label + " preserves draft, attachment, turns, pin and transport")
    }
    function writeFixtures(replace, done) {
        fixtureDone = done
        fixtures.command = ["/usr/bin/python3", "-B", "-u", fixtureScript, replace ? "--replace" : "--fixtures"]
        fixtures.running = true
    }
    function finish() {
        if (service) service.destroy()
        if (failures.length) {
            console.error(failures.join("\n"))
            Qt.exit(1)
        } else {
            console.log("AiPreviewService: real scratch CSV, pre-mutation gates, retry/source replacement, retained surfaces, same-path workspace/restore invalidation, column-type correction reset/transport, Keep full data offer gates and explicit STUB-only submit passed")
            Qt.quit()
        }
    }

    function begin() {
        var component = Qt.createComponent(Qt.resolvedUrl("AiService.qml"))
        if (component.status !== Component.Ready) { console.error(component.errorString()); Qt.exit(1); return }
        var scratch = Quickshell.env("XDG_STATE_HOME") + "/preview-service"
        service = component.createObject(check, {storeEnabled: false, openUiEnabled: false, stateRoot: scratch,
            brokerScript: brokerScript, storeScript: brokerScript})
        if (!service) { console.error(component.errorString()); Qt.exit(1); return }
        eq(service.storeEnabled, false, "Store is disabled")
        eq(service.stateRoot, scratch, "State root is scratch")
        eq(service.brokerScript, brokerScript, "Broker injection is effective before any submit")
        eq(service.storeScript, brokerScript, "Any explicit transport check also uses the stub store")
        service.defaultAgent = "codex"
        service.draft = "Review these rows"
        service.attachment = home + "/rents.csv"
        actions = [
            function() {
                delay(function() {
                    eq(service.previewStatus, "idle", "Hidden attachment stays lazy")
                    eq(service.attachmentBlocked, true, "Unread CSV is gated")
                    eq(service.brokerLive, false, "Preview does not start a provider broker")
                    rejectsWithoutMutation("Hidden attachment")
                    service.loadingLatest = true
                    service.panelActive = true
                    delay(function() {
                        eq(service.previewStatus, "idle", "Active restore still defers reading")
                        eq(service.attachmentPreview._occupied, false, "Restore has no preview process")
                        rejectsWithoutMutation("Restoring attachment")
                        service.loadingLatest = false
                        service.attachmentPreview.startIfEligible()
                        eq(service.previewStatus, "loading", "Real read starts after restore")
                        eq(service.busy, false, "Local reading is not AI busy")
                        rejectsWithoutMutation("Loading attachment")
                        // Fresh scratch HOME intentionally has no rents.csv yet.
                        settled("error", next)
                    })
                })
            },
            function() {
                eq(service.previewError, "Attachment is unavailable or is a symbolic link.", "Access error is honest")
                eq(service.previewData, null, "Error has no retained data")
                rejectsWithoutMutation("Errored attachment")
                writeFixtures(false, function() {
                    service.retryAttachmentPreview()
                    settled("ready", next)
                })
            },
            function() {
                eq(service.previewData.rows, [["Oslo", "1200"], ["Porto", "600"], ["Lisbon", "900"],
                    ["Paris", "1400"], ["Riga", "700"], ["Rome", "1100"], ["Tallinn", "800"], ["Vienna", "1000"]], "Preview preserves all eight literal rows")
                eq(service.previewData.previewRows, 8, "Service exposes preview metadata")
                eq(service.attachmentBlocked, false, "Parsed current CSV opens the gate")
                eq(service.turns.length, 0, "Readiness never auto-sends")
                eq(service.agent, "", "Preview never pins a provider")
                savedToken = service.attachmentPreview.token
                savedData = service.previewData
                service.panelActive = false
                delay(function() {
                    eq(service.previewData, savedData, "Closing panel retains the preview")
                    service.windowActive = true
                    delay(function() {
                        eq(service.attachmentPreview.token, savedToken, "Detached surface reuses the same read")
                        eq(service.brokerLive, false, "Opening another surface never starts broker")
                        writeFixtures(true, function() {
                            eq(service.previewData.rows[0], ["Oslo", "1200"], "Changed source is not falsely claimed as refreshed")
                            eq(service.turns.length, 0, "Source replacement never sends")
                            service.retryAttachmentPreview()
                            settled("ready", next)
                        })
                    })
                })
            },
            function() {
                eq(service.previewData.rows[0], ["Changed", "42"], "Retry securely rereads changed source")
                eq(service.previewTypeOverrides, [], "A fresh read starts with no column-type corrections")
                eq(service.setPreviewColumnType(1, "number"), true, "The ready preview accepts a correction")
                eq(service.setPreviewColumnType(2, "number"), false, "A column past the preview is refused")
                eq(service.setPreviewColumnType(0, "bogus"), false, "An unknown type is refused")
                eq(service.previewTypeOverrides, ["", "number"], "Only the valid correction is kept")
                eq(service.turns.length, 0, "Correcting a type never sends")
                eq(service.brokerLive, false, "Correcting a type never starts a provider")
                savedToken = service.attachmentPreview.token
                service.workspaceId = "ws-another"
                eq(service.previewTypeOverrides, [], "Workspace change clears corrections with readiness")
                eq(service.attachmentBlocked, true, "Workspace change closes same-path gate immediately")
                eq(service.previewData, null, "Workspace change drops old data")
                eq(service.attachmentPreview.token > savedToken, true, "Workspace identity invalidates unchanged path")
                rejectsWithoutMutation("New workspace, same attachment")
                settled("ready", next)
            },
            function() {
                service.windowActive = false
                savedToken = service.attachmentPreview.token
                eq(service.setPreviewColumnType(0, "text"), true, "Corrected before a restore")
                service.applyWorkspaceSnapshot({workspace: {id: "ws-another", agent: "codex",
                    draft: "Restored review", attachment: home + "/rents.csv"}, artifacts: [], interaction: {}}, {})
                eq(service.attachmentPreview.token > savedToken, true, "Same-id snapshot still invalidates unchanged path")
                eq(service.previewTypeOverrides, [], "A restored snapshot starts with no corrections")
                delay(function() {
                    eq(service.previewStatus, "idle", "Restored attachment stays lazy while hidden")
                    rejectsWithoutMutation("Hidden restored attachment")
                    service.windowActive = true
                    settled("ready", next)
                })
            },
            function() {
                service.windowActive = false
                service.attachment = home + "/malformed.csv"
                service.storeStarting = true
                service.pruneQueued = false
                service.storeRun("load", {workspaceId: "ws-target"})
                service.storeInFlight.push(service.storeQueue.shift())
                service.panelActive = true
                service.dispatch(JSON.stringify({ok: true, workspace: {id: "ws-target", agent: "codex",
                    draft: "Restored review", attachment: home + "/rents.csv"}, artifacts: [], interaction: {}}))
                eq(service.storeQueue[0].op, "prune", "Restore schedules orphan cleanup")
                eq(JSON.parse(service.storeQueue[0].payload).preserveWorkspaces, true,
                    "Automatic restore cleanup preserves conversation history")
                eq(service.loadingLatest, false, "Dispatch releases restore before apply")
                eq(service.previewStatus, "idle", "Dispatch has not synchronously read outgoing path")
                eq(service.attachment, home + "/rents.csv", "Snapshot installs target attachment first")
                eq(service.attachmentPreview._occupied, false, "Deferred lifecycle sees only completed apply")
                settled("ready", next)
            },
            function() {
                eq(service.previewData.rows[0], ["Changed", "42"], "Restore reads the target CSV, not outgoing malformed source")
                service.attachment = ""
                eq(service.previewStatus, "idle", "Removal drops readiness")
                eq(service.previewData, null, "Removal drops data")
                eq(service.attachmentBlocked, false, "Removal releases gate")
                service.attachment = home + "/ordinary.txt"
                eq(service.attachmentBlocked, false, "Non-CSV attachments retain their existing contract")
                service.attachment = home + "/malformed.csv"
                settled("error", function() {
                    eq(service.previewError, "CSV line 2 has 3 columns; the header has 2.", "Parse error is exposed without provider")
                    rejectsWithoutMutation("Malformed CSV")
                    service.attachment = home + "/rents.csv"
                    settled("ready", next)
                })
            },
            function() {
                savedToken = service.attachmentPreview.token
                service.newConversation()
                eq(service.attachmentPreview.token > savedToken, true, "New chat invalidates preview")
                eq(service.previewData, null, "New chat drops retained CSV")
                eq(service.previewTypeOverrides, [], "New chat clears corrections")
                eq(service.setPreviewColumnType(0, "text"), false, "No correction without a ready preview")
                service.draft = "Send only after review"
                service.attachment = home + "/rents.csv"
                settled("ready", next)
            },
            function() {
                // Readiness is not merely a string status: only a parsed result
                // for the current path/token can grant permission to send.
                service.attachmentPreview._resultPath = home + "/old.csv"
                eq(service.previewStatus, "ready", "Status alone may look ready")
                eq(service.previewData, null, "Mismatched result is never exposed")
                eq(service.attachmentBlocked, true, "Mismatched ready result stays gated")
                rejectsWithoutMutation("Ready status for another path")
                service.retryAttachmentPreview()
                settled("ready", next)
            },
            function() {
                eq(service.turns.length, 0, "No restore, retry or readiness auto-submitted")
                eq(service.brokerLive, false, "All previews remained provider-independent")
                service.agent = "hermes"
                eq(service.previewData.rows[0], ["Changed", "42"], "Provider choice does not change local preview")
                service.agent = "codex"
                var id = service.turnId
                eq(service.setPreviewColumnType(0, "text"), true, "Corrected before the explicit send")
                eq(service.setPreviewColumnType(1, "number"), true, "Corrected before the explicit send")
                eq(service.submit(service.draft), true, "Explicit reviewed send succeeds into stub only")
                eq(service.pending.columnTypes, ["text", "number"], "Corrected enum types ride the request, nothing else")
                eq(Object.keys(service.pending).sort(), ["agent", "attachment", "columnTypes", "op", "prompt", "turnId"],
                    "The request has only fixed keys: no preview rows or names")
                eq(service.previewTypeOverrides, [], "A sent attachment retires its corrections")
                eq(service.turnId, id + 1, "Explicit send creates exactly one turn")
                eq(service.turnModel.count, 1, "Explicit send appends one model row")
                eq(service.latest.attachment, home + "/rents.csv", "Turn retains the source attachment")
                eq(service.pending.attachment, home + "/rents.csv", "Broker gets source path, not preview rows")
                eq(service.draft, "", "Only accepted send clears draft")
                eq(service.attachment, "", "Only accepted send consumes attachment")
                eq(service.previewData, null, "Consumed attachment retires preview")
                until(function() { return service.brokerStarted && !service.pending }, function(ok) {
                    eq(ok, true, "Bundled stub receives the explicit request")
                    service.receive(JSON.stringify({type: "done", turnId: service.turnId,
                        answer: "Stub-only completion", blocks: [], suggestions: []}))
                    eq(service.busy, false, "Stub completion finishes the turn")
                    eq(service.workspaceSnapshot().interaction["turn:" + service.turnId].attachment,
                        home + "/rents.csv", "Source context persists with the sent turn")
                    eq(JSON.stringify(service.workspaceSnapshot()).indexOf("columnTypes"), -1,
                        "Corrections are never persisted into the workspace")
                    next()
                })
            },
            function() {
                // An uncorrected send carries no columnTypes key at all.
                service.draft = "Second review"
                service.attachment = home + "/rents.csv"
                settled("ready", function() {
                    eq(service.attachmentBlocked, false, "Second preview is ready")
                    service.brokerStarted = false
                    eq(service.submit(service.draft), true, "Second explicit send")
                    eq("columnTypes" in service.pending, false, "No corrections means no columnTypes key")
                    eq(service.pending.attachment, home + "/rents.csv", "The request still names the source")
                    next()
                })
            },
            function() {
                // Keep full data: offered only for a ready, unregistered CSV; the
                // copy is never started by readiness; reviewed type corrections
                // survive it. The store is HELD in memory and the source worker
                // is the in-memory stub: nothing here writes or sends.
                var keep = component.createObject(check, {storeEnabled: true, stateRoot: scratch + "/keep",
                    brokerScript: brokerScript, storeScript: brokerScript})
                keep.csvSource.workerScript = csvStub
                keep.storeStarting = true
                keep.newConversation()
                keep.storeQueue = []
                keep.storePending = 0
                // The service's own boot index refresh ("list") may land at any point.
                function pruneList() { keep.storeQueue = keep.storeQueue.filter(function(job) { return job.op !== "list" }) }
                function answer(op, result) {
                    pruneList()
                    eq(keep.storeQueue.length > 0 ? keep.storeQueue[0].op : "none", op, "Next store job")
                    if (!keep.storeQueue.length) return
                    keep.storeInFlight.push(keep.storeQueue.shift())
                    keep.dispatch(JSON.stringify(result))
                }
                eq(keep.keepOffered, false, "No attachment: nothing to keep")
                eq(keep.keepFullData(), false, "Keep is refused without a ready CSV")
                keep.attachment = home + "/rents.csv"
                eq(keep.keepOffered, false, "An unread CSV is not offered for keeping")
                eq(keep.keepFullData(), false, "Keep is refused until the preview is ready")
                keep.panelActive = true
                until(function() { return keep.previewStatus === "ready" && !keep.attachmentPreview._occupied }, function(ok) {
                    eq(ok, true, "Second service preview settles")
                    eq(keep.keepOffered, true, "A ready CSV offers Keep full data")
                    eq(keep.canKeepFullData, true, "...and it can start")
                    eq(keep.csvSource.status, "idle", "Readiness never registers a copy")
                    pruneList()
                    eq(keep.storeQueue.length, 0, "Readiness queues no store work")
                    keep.busy = true
                    eq(keep.keepOffered && !keep.canKeepFullData, true, "Busy disables the offer without hiding it")
                    eq(keep.keepFullData(), false, "Busy refuses the action")
                    keep.busy = false
                    keep.stopping = true
                    eq(keep.canKeepFullData, false, "A stopping answer refuses the action")
                    keep.stopping = false
                    keep.storeEnabled = false
                    eq(keep.keepOffered, false, "Without a store the copy could not be owned, so it is not offered")
                    keep.storeEnabled = true
                    eq(keep.setPreviewColumnType(1, "number"), true, "A reviewed correction")
                    var token = keep.attachmentPreview.token
                    eq(keep.keepFullData(), true, "The explicit action starts")
                    eq(keep.workspaceId !== "", true, "A fresh chat gets its workspace id")
                    eq(keep.attachmentPreview.token, token, "Giving the chat its id is not a workspace switch")
                    eq(keep.previewTypeOverrides, ["", "number"], "The reviewed type corrections survive keeping")
                    eq(keep.keepOffered, false, "The offer is hidden while registering")
                    eq(keep.sourceStatus, "registering", "The source reports registering")
                    answer("source_list", {ok: true, totalBytes: 0, count: 0, sources: []})
                    until(function() { return keep.keepPhase === "link" }, function(linking) {
                        eq(linking, true, "The copy registers through the stub worker")
                        eq(keep.keepOffered, false, "Still hidden while linking")
                        answer("save", {ok: true})
                        answer("source_link", {ok: true})
                        eq(keep.sourceReady, true, "The linked source is ready")
                        eq(keep.sourceOrigin, home + "/rents.csv", "The origin is the attachment")
                        eq(keep.keepOffered, false, "Hidden when a source is already kept for this attachment")
                        eq(keep.turns.length, 0, "Keeping never sends")
                        eq(keep.brokerLive, false, "Keeping never starts a provider")
                        keep.sourceOrigin = "/elsewhere.csv"
                        eq(keep.keepOffered, true, "Offered again for a different file (replace)")
                        keep.destroy()
                        next()
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
    Process {
        id: fixtures
        clearEnvironment: true
        environment: ({HOME: check.home, PATH: "/usr/bin:/bin", PYTHONDONTWRITEBYTECODE: "1"})
        onExited: function(code) {
            check.eq(code, 0, "Scratch fixture update succeeds")
            var done = check.fixtureDone
            check.fixtureDone = null
            if (done) done()
        }
    }
    Component.onCompleted: {
        var state = Quickshell.env("XDG_STATE_HOME")
        if (home.indexOf("/tmp/opencode/ai-preview-check-") !== 0 || state.indexOf(home + "/") !== 0) {
            console.error("Use fresh /tmp/opencode/ai-preview-check-* HOME and nested scratch XDG_STATE_HOME")
            Qt.exit(2)
            return
        }
        begin()
    }
    Timer {
        interval: 30000
        running: true
        onTriggered: { check.failures.push("Service preview check exceeded global deadline"); check.finish() }
    }
}
