import QtQuick
import Quickshell
import Quickshell.Io

// Round-trip check: the retained service persists a conversation through the
// real ai_workspace_store.py CLI and restores it into a fresh service
// instance, mapping interrupted working turns to honest errors.
// Run with XDG_STATE_HOME pointed at a scratch directory.
ShellRoot {
    id: check

    property var component: null
    property var saved: null
    property var restored: null
    property bool verified: false
    property bool fallbackFired: false
    property var failures: []
    property var pollCondition: null
    property var pollDone: null
    property real pollDeadline: 0

    function eq(a, b, msg) {
        if (JSON.stringify(a) !== JSON.stringify(b))
            failures.push(msg + ": " + JSON.stringify(a) + " != " + JSON.stringify(b))
    }

    // Timer-driven bounded polling: never a hot callLater spin.
    function pollUntil(condition, done) {
        pollCondition = condition
        pollDone = done
        pollDeadline = Date.now() + 8000
        pollTimer.start()
    }

    Timer {
        id: pollTimer
        interval: 50
        repeat: true
        onTriggered: {
            if (check.pollCondition && check.pollCondition()) {
                stop()
                var done = check.pollDone
                check.pollDone = null
                done(true)
            } else if (Date.now() > check.pollDeadline) {
                stop()
                var timedOut = check.pollDone
                check.pollDone = null
                timedOut(false)
            }
        }
    }

    function finish() {
        if (saved) saved.destroy()
        if (restored) restored.destroy()
        if (failures.length) {
            console.error(failures.join("\n"))
            Qt.exit(1)
            return
        }
        console.log("AiWorkspaceStore: save, load, artifact, interrupted-turn, rename, duplicate, new-chat and source-registry checks passed")
        Qt.quit()
    }

    // Phase 3: New chat must clear the local conversation while keeping the
    // finished workspace saved and findable in the library.
    function newChatPhase() {
        var finalId = check.saved.workspaceId
        check.saved.newConversation()
        eq(check.saved.turns.length, 0, "new chat clears the local conversation")
        eq(check.saved.workspaceId, "", "new chat releases the workspace id")
        eq(check.saved.uiStates, {}, "new chat clears interaction state, not only checklists")
        pollUntil(function() { return !check.saved.storeBusy }, function(ok) {
            if (!ok) { failures.push("new chat final save did not settle"); finish(); return }
            check.saved.storeRun("list", {limit: 10})
            pollUntil(function() { return check.saved.workspaceIndex.length > 0 }, function(found) {
                if (!found) { failures.push("workspace library did not refresh"); finish(); return }
                var present = check.saved.workspaceIndex.some(function(entry) {
                    return entry && String(entry.id) === finalId
                })
                if (!present) failures.push("new chat must keep the finished workspace saved")
                else sourcesPhase(finalId)
                if (!present) finish()
            })
        })
    }

    // Phase 4: the source registry through the real worker. Deleting the
    // workspace must drop its rows and remove only its copied directory.
    property string sourceId: "src-0123456789abcdef"
    function storeCli(op, body, done) {
        shell.done = done
        shell.command = ["sh", "-c", "printf '%s' \"$1\" | python3 \"$2\" --root \"$3\" " + op
            + "; test -e \"$3/sources/" + sourceId + "/data.csv\" && echo present || echo gone",
            "sh", JSON.stringify(body), saved.storeScript, saved.stateRoot]
        shell.running = true
    }

    // A replaced copy is unlinked THROUGH THE SERVICE QUEUE with removeDir:
    // the row and only that directory go; the first source is untouched.
    property string replacedId: "src-fedcba9876543210"
    function unlinkPhase(workspaceId, done) {
        var replaced = saved.stateRoot + "/sources/" + replacedId + "/data.csv"
        shell.done = function() {
            saved.storeRun("source_link", {workspaceId: workspaceId, sourceId: replacedId, bytes: 7, rows: 1})
            saved.storeRun("source_unlink", {sourceId: replacedId, removeDir: true})
            pollUntil(function() { return !saved.storeBusy }, function() {
                shell.done = function(text) {
                    eq(text.trim().split("\n"), ["gone", "present"],
                        "unlink removeDir removed only the replaced copy")
                    storeCli("source_list", {}, function(listed) {
                        eq(JSON.parse(listed.trim().split("\n")[0]).count, 1, "the replaced row is gone, the kept row stays")
                        done()
                    })
                }
                shell.command = ["sh", "-c", "for f in \"$1\" \"$2/data.csv\"; do test -e \"$f\" && echo present || echo gone; done",
                    "sh", replaced, saved.stateRoot + "/sources/" + sourceId]
                shell.running = true
            })
        }
        shell.command = ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && echo x > \"$1\"", "sh", replaced]
        shell.running = true
    }

    function sourcesPhase(workspaceId) {
        var dir = saved.stateRoot + "/sources/" + sourceId
        shell.done = function() {
            saved.storeRun("source_link", {workspaceId: workspaceId, sourceId: sourceId, bytes: 5, rows: 1})
            pollUntil(function() { return !saved.storeBusy }, function() {
                storeCli("source_list", {}, function(text) {
                    var lines = text.trim().split("\n")
                    var listing = JSON.parse(lines[0])
                    eq(listing.count, 1, "the worker registered the source")
                    eq(listing.totalBytes, 5, "the registry reports its total bytes")
                    eq(lines[1], "present", "the copied directory exists before the delete")
                    unlinkPhase(workspaceId, function() {
                    saved.storeRun("delete", {workspaceId: workspaceId})
                    pollUntil(function() { return !saved.storeBusy }, function() {
                        storeCli("source_list", {}, function(after) {
                            var rest = after.trim().split("\n")
                            eq(JSON.parse(rest[0]).count, 0, "workspace delete cascades the source row")
                            eq(rest[1], "gone", "workspace delete removes the copied directory")
                            finish()
                        })
                    })
                    })
                })
            })
        }
        shell.command = ["sh", "-c", "mkdir -p \"$1\" && echo x > \"$1/data.csv\"", "sh", dir]
        shell.running = true
    }

    Process {
        id: shell
        property var done: null
        stdout: StdioCollector {
            onStreamFinished: {
                var callback = shell.done
                shell.done = null
                if (callback) callback(text)
            }
        }
    }

    function onceVerified() {
        if (verified) return
        verified = true
        console.log("verify trigger: " + (fallbackFired ? "fallback" : "signal")
            + " turns=" + (restored ? restored.turns.length : -1)
            + " workspaceId=" + (restored ? restored.workspaceId : "?"))
        verify()
    }

    function verify() {
        eq(restored.workspaceId, "ws-check0001", "workspace id restored")
        eq(restored.agent, "codex", "agent pin restored")
        eq(restored.draft, "Follow-up draft", "draft restored")
        eq(restored.attachment, "/tmp/opencode/check-attachment.txt", "attachment restored")
        eq(restored.turns.length, 3, "turn count restored")
        eq(restored.turns[0].prompt, "Earlier", "older turn first")
        eq(restored.turns[1].answer, "New", "answer text restored")
        eq(restored.turns[1].blocks.length, 1, "native blocks restored")
        eq(restored.turns[1].blocks[0].items[1], "Two", "block content restored")
        eq(restored.checklistStates["3"]["0:1"], true, "checklist selection restored")
        eq(restored.uiStates["3"]["step:0"], 2, "learning position restored")
        eq(restored.turns[2].status, "error", "working turn restored as interrupted error")
        eq(restored.turns[2].error.indexOf("interrupted") >= 0, true, "interrupted message present")
        eq(restored.turnId, 4, "turn identity restored")
        eq(restored.resumeOnOpen, true, "workspace resumable")
        // Blocks now come from the artifact table; the transcript keeps a
        // fallback path for workspaces saved before the artifact split.
        check.verifyFallback()
        for (var f = 0; f < check.fallbackFailures.length; ++f) check.failures.push(check.fallbackFailures[f])
        check.reusableToolsPhase()
    }

    function reusableToolsPhase() {
        restored.storeEnabled = true
        restored.sessionId = "original-session"
        restored.handoffHome = restored.stateRoot + "/codex-fixture"
        restored.setUiState(3, "calc:0", {weight: {v: 8, u: ""}})
        eq(restored.renameWorkspace("Laptop decision tool"), true, "rename accepted")
        pollUntil(function() { return !restored.workspaceActionPending && !restored.storeBusy }, function(ok) {
            if (!ok) { failures.push("rename did not settle"); finish(); return }
            eq(restored.workspaceDisplayTitle, "Laptop decision tool", "explicit name applied")
            restored.dirtyContent = false
            restored.draft = "Named tool draft"
            restored.storeRun("save", restored.savePayload())
            pollUntil(function() { return !restored.storeBusy }, function(savedOk) {
                if (!savedOk) { failures.push("named thin save did not settle"); finish(); return }
                eq(restored.duplicateWorkspace("Laptop decision variant"), true, "duplicate accepted")
                pollUntil(function() { return !restored.workspaceActionPending && !restored.loadingLatest
                    && restored.workspaceId !== "ws-check0001" && !restored.storeBusy }, function(cloned) {
                    if (!cloned) { failures.push("duplicate did not open"); finish(); return }
                    var copyId = restored.workspaceId
                    eq(restored.workspaceDisplayTitle, "Laptop decision variant", "copy name restored")
                    eq(restored.draft, "Named tool draft", "copy draft restored")
                    eq(restored.sessionId, "", "copy has a fresh provider session")
                    eq(restored.handoffHome, "", "copy has no provider handoff")
                    eq(restored.uiStates["3"]["calc:0"].weight.v, 8, "copy keeps calculator input")
                    eq(restored.checklistStates["3"]["0:1"], true, "copy keeps checklists")
                    restored.setUiState(3, "calc:0", {weight: {v: 2, u: ""}})
                    restored.resumeWorkspace("ws-check0001")
                    pollUntil(function() { return !restored.loadingLatest && restored.workspaceId === "ws-check0001"
                        && !restored.storeBusy }, function(original) {
                        if (!original) { failures.push("original did not reopen"); finish(); return }
                        eq(restored.workspaceDisplayTitle, "Laptop decision tool", "original name survives copy")
                        eq(restored.uiStates["3"]["calc:0"].weight.v, 8, "copy edits leave original inputs intact")
                        eq(restored.sessionId, "original-session", "original provider session stays intact")
                        restored.storeRun("delete", {workspaceId: copyId})
                        pollUntil(function() { return !restored.storeBusy }, function(deleted) {
                            if (!deleted) failures.push("copy delete did not settle")
                            saved.destroy()
                            saved = restored
                            restored = null
                            newChatPhase()
                        })
                    })
                })
            })
        })
    }

    property var fallbackFailures: []
    function verifyFallback() {
        // Synthetic legacy snapshot: no artifacts, blocks inline in the turn.
        var probe = component.createObject(check, {storeEnabled: false})
        probe.applyWorkspaceSnapshot({workspace: {id: "ws-legacy1"}, interaction: {
            "turn:1": {id: 1, prompt: "Old", answer: "legacy text", status: "done", blocks: [
                {type: "text", title: "Legacy", text: "inline block"}]}}})
        if (probe.turns.length !== 1 || !probe.turns[0].blocks.length
                || probe.turns[0].blocks[0].text !== "inline block")
            fallbackFailures.push("legacy inline blocks must restore when no artifact exists")
        // Artifact blocks are canonical when both forms are present.
        probe.applyWorkspaceSnapshot({workspace: {id: "ws-legacy2"}, interaction: {
            "turn:1": {id: 1, prompt: "New", answer: "text", status: "done", artifactId: "af-x-t1",
                blocks: [{type: "text", text: "stale inline"}]}},
            artifacts: [{id: "af-x-t1", blocks: [{type: "text", text: "artifact canonical"}]}]})
        if (probe.turns[0].blocks[0].text !== "artifact canonical")
            fallbackFailures.push("artifact blocks must win over stale inline blocks")
        // An artifact with legitimately empty blocks stays empty.
        probe.applyWorkspaceSnapshot({workspace: {id: "ws-legacy3"}, interaction: {
            "turn:1": {id: 1, prompt: "Plain", answer: "text", status: "done", artifactId: "af-x-t1",
                blocks: [{type: "text", text: "stale inline"}]}},
            artifacts: [{id: "af-x-t1", blocks: []}]})
        if (probe.turns[0].blocks.length !== 0)
            fallbackFailures.push("an empty artifact must not resurrect stale inline blocks")
        probe.destroy()
    }

    Timer {
        id: boot
        interval: 1
        running: true

        function waitSave() {
            if (check.saved.storeBusy) { Qt.callLater(waitSave); return }
            phaseLoad()
        }

        function phaseLoad() {
            // Both instances keep their own boot-restore disabled so only the
            // explicit save/load below drive the round trip.
            check.restored = check.component.createObject(check, {storeEnabled: false})
            check.restored.storeRun("load", {workspaceId: "ws-check0001"})
            // Event-driven verification when the snapshot applies, with a
            // wall-clock fallback so a failed load still reports.
            check.restored.workspaceRestored.connect(check.onceVerified)
            fallback.start()
        }

        onTriggered: {
            if (Quickshell.env("XDG_STATE_HOME").indexOf("/tmp/opencode/") !== 0
                || Quickshell.env("HOME").indexOf("/tmp/opencode/") !== 0) {
                console.error("HOME and XDG_STATE_HOME must point at scratch directories under /tmp/opencode")
                Qt.exit(2)
                return
            }
            check.component = Qt.createComponent(Qt.resolvedUrl("AiService.qml"))
            if (check.component.status !== Component.Ready) {
                console.error(check.component.errorString())
                Qt.exit(1)
                return
            }
            check.saved = check.component.createObject(check, {storeEnabled: false})
            check.saved.defaultAgent = "codex"
            check.saved.agent = "codex"
            check.saved.draft = "Follow-up draft"
            check.saved.attachment = "/tmp/opencode/check-attachment.txt"
            check.saved.turnId = 3
            check.saved.turns = [
                {id: 2, prompt: "Earlier", attachment: "", answer: "Old", blocks: [],
                    suggestions: [], warning: "", error: "", status: "done"},
                {id: 3, prompt: "Latest", attachment: "", answer: "New", blocks: [
                    {type: "checklist", title: "Steps", items: ["One", "Two"]}],
                    suggestions: [], warning: "", error: "", status: "done"},
                // A working turn must restore as an interrupted error.
                {id: 4, prompt: "Interrupted", attachment: "", answer: "", blocks: [],
                    suggestions: [], warning: "", error: "", status: "working"}
            ]
            check.saved.setChecklist(3, 0, 1, true)
            check.saved.setUiState(3, "step:0", 2)
            check.saved.workspaceId = "ws-check0001"
            check.saved.storeRun("save", check.saved.workspaceSnapshot())
            Qt.callLater(waitSave)
        }
    }

    Timer {
        id: fallback
        interval: 6000
        onTriggered: {
            check.fallbackFired = true
            check.onceVerified()
        }
    }
}
