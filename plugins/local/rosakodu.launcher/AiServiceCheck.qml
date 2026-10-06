import QtQuick
import Quickshell

ShellRoot {
    Timer {
        interval: 1
        running: true
        onTriggered: function() {
            var component = Qt.createComponent(Qt.resolvedUrl("AiService.qml"))
            if (component.status !== Component.Ready) {
                console.error(component.errorString())
                Qt.exit(1)
                return
            }
            var stubScript = decodeURIComponent(Qt.resolvedUrl("tests/ai_service_stub.py").toString().replace(/^file:\/\//, ""))
            var scratchRoot = Quickshell.env("XDG_STATE_HOME") + "/ai-service-check"
            var service = component.createObject(parent, {storeEnabled: false,
                storeScript: stubScript, brokerScript: stubScript, stateRoot: scratchRoot})
            function check(condition, message) { if (!condition) throw new Error(message) }
            try {
                check(Quickshell.env("HOME").indexOf("/tmp/opencode/") === 0
                    && Quickshell.env("XDG_STATE_HOME").indexOf("/tmp/opencode/") === 0,
                    "Run this check with scratch HOME and XDG_STATE_HOME under /tmp/opencode")
                check(service.storeScript === stubScript && service.brokerScript === stubScript
                    && service.stateRoot === scratchRoot, "Every service must use isolated fixtures")
                service.agent = "codex"
                service.defaultAgent = "hermes"
                check(service.agent === "codex", "Default change must not reroute an existing chat")
                service.turnId = 7
                service.turns = [{id: 7, prompt: "Fixture", answer: "", blocks: [], suggestions: [], status: "working"}]
                service.turnModel.append({payload: service.latest})
                service.busy = true
                service.receive(JSON.stringify({type: "delta", turnId: 6, text: "Stale"}))
                check(service.latest.answer === "", "Stale turns must not replace current output")
                service.receive(JSON.stringify({type: "done", turnId: 7, answer: "Complete", blocks: [], suggestions: []}))
                check(!service.busy && service.latest.answer === "Complete", "Completion must finish current turn")
                check(service.turnModel.count === 1 && service.turnModel.get(0).payload.answer === "Complete", "Stable model must update in place")
                service.receive(JSON.stringify({type: "delta", turnId: 7, text: "Late"}))
                check(service.latest.answer === "Complete", "Late deltas must not replace completed answers")
                service.resumeOnOpen = true
                service.setChecklist(7, 0, 0, true)
                check(service.checklistStates["7"]["0:0"] === true, "Checklist state must belong to the persistent service")
                service.draft = "A follow-up"
                check(service.turns.length === 1, "UI drafts must not clear conversation state")
                // Adaptive depth: busy answers reject re-explanation; explain
                // events land on the latest turn as a prose sidecar and clear
                // busy; the sidecar persists with the transcript.
                service.busy = true
                check(!service.explainLatest("simpler"), "A busy answer must reject depth requests")
                service.receive(JSON.stringify({type: "explain", turnId: 7, text: "Simpler: keep the overview."}))
                check(service.latest.explanation === "Simpler: keep the overview.",
                    "Explain events must land on the latest turn")
                check(!service.busy && service.latest.status === "done", "Explain completion must clear busy")
                check(service.workspaceSnapshot().interaction["turn:7"].explanation === "Simpler: keep the overview.",
                    "The explanation sidecar must persist with the transcript")

                function isolated() {
                    return component.createObject(parent, {storeEnabled: false,
                        storeScript: stubScript, brokerScript: stubScript, stateRoot: scratchRoot})
                }
                function depthContext(block, key, value, expected) {
                    var depth = isolated()
                    depth.agent = "codex"
                    depth.turnId = 8
                    depth.turns = [{id: 8, prompt: "Learning fixture", answer: "Answer", status: "done",
                        blocks: [{type: "text", text: "Intro"}, block]}]
                    depth.setUiState(8, key, value)
                    check(depth.explainLatest("example"), "Depth requests must accept persisted numeric state")
                    check(depth.pending && depth.pending.op === "explain"
                        && depth.pending.prompt.indexOf("Requested: another example") >= 0
                        && depth.pending.prompt.indexOf(expected) >= 0,
                        "Depth context must contain " + expected)
                    depth.busy = false
                    depth.destroy()
                }
                depthContext({type: "diagram", parts: [{label: "First"}, {label: "Second"}]},
                    "diagram:1", 0, "Selected: First")
                depthContext({type: "diagram", parts: [{label: "First"}, {label: "Second"}]},
                    "diagram:1", 1, "Selected: Second")
                depthContext({type: "slider", unit: "wrong", control: {unit: "m"}},
                    "slider:1", 0, "Value: 0 m")
                depthContext({type: "slider", control: {unit: "m"}}, "slider:1", 12.5, "Value: 12.5 m")

                // Deterministic transport checks: hold the queue in memory so
                // failure/null/superseded results never reach a real store.
                var snapshot = {ok: true, workspace: {id: "ws-fixture", agent: "codex", draft: "Stored"},
                    artifacts: [], interaction: {}}
                function finishLoad(result) {
                    var held = isolated()
                    held.storeStarting = true
                    held.storeRun("load", {workspaceId: "ws-fixture"})
                    held.storeInFlight.push(held.storeQueue.shift())
                    held.dispatch(JSON.stringify(result))
                    check(!held.loadingLatest && held.restoreSettled, "Every load result must release the gate")
                    check(held.pruneQueued && held.storeQueue[0].op === "prune"
                        && held.storePending === 1, "Every settled load schedules pruning exactly once")
                    check(JSON.parse(held.storeQueue[0].payload).preserveWorkspaces === true,
                        "Automatic housekeeping must never delete saved conversations")
                    held.destroy()
                }
                finishLoad(snapshot)
                finishLoad({ok: true, workspace: null})
                finishLoad({ok: false, error: "Fixture failure"})
                var legacy = isolated(), legacyInteraction = {}, legacyArtifacts = []
                for (var legacyId = 1; legacyId <= 23; ++legacyId) {
                    var legacyArtifactId = "legacy-" + legacyId
                    legacyInteraction["turn:" + legacyId] = {id: legacyId, artifactId: legacyArtifactId,
                        prompt: "Legacy", answer: "Stored", status: "done", blocks: []}
                    legacyArtifacts.push({id: legacyArtifactId, blocks: [{type: "text", text: "Fixture"}]})
                }
                legacyInteraction.uiStates = {"1": {"table:0": {filter: "old"}}, "23": {"step:0": 1}}
                legacy.applyWorkspaceSnapshot({workspace: {id: "ws-legacy"}, artifacts: legacyArtifacts,
                    interaction: legacyInteraction}, {})
                check(legacy.turns.length === 20 && legacy.turns[0].id === 4 && legacy.turnId === 23,
                    "Legacy accumulated transcripts must hydrate only the latest twenty turns")
                check(legacy.workspaceSnapshot().artifacts.length === 20 && !legacy.uiStates["1"]
                    && legacy.uiStates["23"]["step:0"] === 1,
                    "Hydrated legacy content must fit the store cap and discard obsolete interaction state")
                legacy.destroy()
                var late = isolated()
                late.storeStarting = true
                late.pruneQueued = true
                late.storeRun("load", {workspaceId: "ws-late"})
                var lateJob = late.storeQueue.shift(), lateToken = late.loadToken
                late.storeInFlight.push(lateJob)

                // The lazy store phase: boot must not hydrate, a real entry
                // issues exactly one latest load (submit stays gated until it
                // settles), and a typed draft survives the completed snapshot.
                var lazy = component.createObject(parent, {
                    storeEnabled: false,
                    storeScript: stubScript,
                    brokerScript: stubScript,
                    stateRoot: scratchRoot
                })
                // Fail before any operation if injection did not take. The
                // fixture is in-tree and never reads/writes files or starts a
                // provider; no missing scratch script can fall back to live state.
                check(lazy.storeScript === stubScript && lazy.brokerScript === stubScript,
                    "The check must use bundled store and broker fixtures")
                check(lazy.stateRoot === scratchRoot, "The check must never use the real state root")
                lazy.storeEnabled = true
                // The real FileView reads the default agent; set it the same
                // way the service would on a real shell.
                lazy.defaultAgent = "codex"
                check(lazy.loadingLatest === false, "Boot must not load the latest workspace")
                // The user was typing before entry, so the restore must be
                // told to preserve their editing intent; the text itself is
                // typed while the load is in flight.
                lazy.draftTouched = true
                lazy.requestLatest()
                lazy.requestLatest()
                check(lazy.loadingLatest === true, "A real AI entry must trigger exactly one latest load")
                check(!lazy.submit("Blocked while loading"), "Submit must be gated on the restore")
                check(!lazy.submit("Still blocked"), "A still-loading restore must keep submit closed")
                lazy.draft = "Typed while restoring"

                // Finish the deterministic service's pinning checks.
                service.newConversation()
                check(service.agent === "" && service.turns.length === 0, "New chat must release provider pinning")
                check(service.restoreSettled, "a fresh conversation must be immediately persistable")
                service.defaultAgent = "unsupported"
                service.submit("Fixture without an AI call")
                check(service.agent === "" && !service.busy && service.latest.status === "error", "Unsupported agents must not latch or start a helper")
                service.defaultAgent = "codex"
                check(service.agent === "", "Correcting a default must allow recovery without resetting a failed session")
                service.destroy()

                // Asynchronously verify the one latest load settles and the
                // user's typed draft survives the completed snapshot.
                var settled = false, failed = null, phase = 0, phaseTime = 0
                function settle() {
                    if (failed) return
                    if (lazy.loadingLatest || !lazy.restoreSettled) return
                    try {
                        if (phase === 0) {
                        console.log("AiService lazy settle: draft=" + JSON.stringify(lazy.draft) + " touched=" + lazy.draftTouched + " turns=" + lazy.turns.length + " workspace=" + lazy.workspaceId + " loading=" + lazy.loadingLatest)
                        check(lazy.latestRequested === true, "The restore must complete as the lazy request")
                        check(lazy.pruneQueued, "Successful hydration must schedule housekeeping")
                        check(lazy.turns.length === 1, "The latest workspace must hydrate once on entry")
                        check(lazy.draft === "Typed while restoring", "A completed restore must keep the user's typed draft")
                        check(lazy.workspaceId === "ws-lazy-1", "The restored workspace must own the conversation")
                        // Coalesced saves: a draft-only edit sends no content;
                        // a content change sends the full artifacts/interaction.
                        lazy.dirtyContent = false
                        lazy.draft = "Only a draft edit"
                        var thin = lazy.savePayload()
                        check(thin.artifacts.length === 0 && Object.keys(thin.interaction).length === 0,
                            "draft-only saves skip the conversation content")
                        check(thin.authoritativeContent !== true, "thin saves never delete omitted content")
                        check(thin.workspace.draft === "Only a draft edit")
                        lazy.turns = [{id: 99, prompt: "p", answer: "a", blocks: [{type: "text", text: "b"}],
                            suggestions: [], warning: "", error: "", status: "done"}]
                        var full = lazy.savePayload()
                        check(full.artifacts.length === 1 && full.interaction["turn:99"] !== undefined,
                            "content changes send the full snapshot")
                        check(full.authoritativeContent === true, "full snapshots retire obsolete content")
                        var again = lazy.savePayload()
                        check(again.artifacts.length === 0,
                            "the dirty flag is consumed by the full save")
                        lazy.turns = []
                        // Hidden-surface broker lifecycle: eligible only when
                        // every surface is hidden and the grace period passed.
                        lazy.brokerStarted = false
                        check(!lazy.brokerIdleCheck(), "a fresh service never idles a non-started broker")
                        lazy.brokerStarted = true
                        lazy.lastBrokerActivity = Date.now()
                        check(!lazy.brokerIdleCheck(), "fresh broker activity must not be eligible for shutdown")
                        check(Math.abs(Date.now() - lazy.lastBrokerActivity) < 1000,
                            "broker activity timestamps must retain epoch milliseconds")
                        check(Math.abs(Date.now() - lazy.lastStoreWork) < 1000,
                            "store work timestamps must retain epoch milliseconds")
                        lazy.lastBrokerActivity = Date.now() - 40000
                        check(lazy.brokerIdleCheck(), "a hidden, idle broker is eligible for shutdown")
                        lazy.panelActive = true
                        check(!lazy.brokerIdleCheck(), "the visible panel keeps the broker warm")
                        lazy.panelActive = false
                        lazy.windowActive = true
                        check(!lazy.brokerIdleCheck(), "the detached window keeps the broker warm")
                        lazy.windowActive = false
                        lazy.busy = true
                        check(!lazy.brokerIdleCheck(), "a running job keeps the broker warm")
                        lazy.busy = false
                        lazy.brokerStarted = false
                        check(lazy.submit("Warm broker fixture"), "A settled restore accepts a stub job")
                        phase = 1
                        } else if (phase === 1) {
                            if (!lazy.brokerLive || !lazy.brokerStarted) return
                            var previousId = lazy.workspaceId
                            check(!lazy.resumeWorkspace("ws-other"), "Busy jobs reject workspace switches")
                            lazy.newConversation()
                            check(lazy.workspaceId === previousId && lazy.busy,
                                "New chat must reject a busy workspace without mutating it")
                            lazy.busy = false
                            lazy.sessionId = "old-session"
                            lazy.handoffHome = "old-handoff"
                            lazy.pending = {op: "submit", resumeSession: "old-session"}
                            lazy.draft = "Carry to clear"
                            check(lazy.resumeWorkspace("ws-named", {draft: lazy.draft, draftTouched: true}),
                                "Named workspace loads are accepted while idle")
                            check(lazy.loadingLatest && !lazy.submit("Blocked named load")
                                && !lazy.explainLatest("simpler") && !lazy.resumeWorkspace("ws-other"),
                                "Named loads gate submit, depth and overlapping workspace switches")
                            check(lazy.brokerRetiring && !lazy.brokerStarted && lazy.pending === null
                                && lazy.sessionId === "" && lazy.handoffHome === "",
                                "Switching workspaces retires the warm broker and clears old session state")
                            lazy.receive(JSON.stringify({type: "done", sessionId: "old-session"}))
                            check(lazy.sessionId === "", "Retiring brokers cannot repopulate old session state")
                            lazy.draft = ""
                            phase = 2
                        } else if (phase === 2) {
                            if (lazy.brokerLive || lazy.brokerRetiring) return
                            check(lazy.draft === "", "Clearing a draft during restore must not resurrect carry text")
                            lazy.applyWorkspaceSnapshot({workspace: {id: "ws-target", agent: "codex",
                                sessionRef: "target-session"}, artifacts: [], interaction: {}}, {})
                            check(lazy.submit("Target follow-up") && lazy.pending
                                && lazy.pending.resumeSession === "target-session",
                                "The switched conversation cold-starts with its restored provider session")
                            phase = 3
                        } else if (phase === 3) {
                            if (!lazy.brokerStarted || lazy.storeBusy) return
                            lazy.receive(JSON.stringify({type: "done", turnId: lazy.turnId, answer: "Stub answer"}))
                            lazy.lastStoreWork = Date.now()
                            phaseTime = Date.now()
                            phase = 4
                        } else if (phase === 4) {
                            if (Date.now() - phaseTime < 1200 || lazy.storeBusy) return
                            check(!lazy.storeStopped, "Fresh store work must keep its idle worker alive")
                            lazy.lastStoreWork = Date.now() - 40000
                            phase = 5
                        } else if (phase === 5) {
                            if (!lazy.storeStopped) return
                            phase = 6
                        } else if (phase === 6) {
                            if (late.loadingLatest) return
                            check(late.loadToken > lateToken && late.restoreSettled,
                                "Watchdog release invalidates its outstanding load")
                            late.defaultAgent = "codex"
                            check(late.submit("Accepted after timeout"), "A timed-out load releases submission")
                            var accepted = late.latest
                            late.dispatch(JSON.stringify(snapshot))
                            check(late.latest === accepted && late.storePending === 0,
                                "Late snapshots cannot overwrite accepted turns or leak pending accounting")
                            settled = true
                            console.log("AiService: state, depth context, restore gates, watchdog, pruning and idle lifecycle checks passed")
                            Qt.quit()
                        }
                    } catch (error) {
                        failed = error.message
                        console.error(error.message)
                        Qt.exit(1)
                    }
                }
                var settleTimer = Qt.createQmlObject("import QtQuick; Timer { interval: 50; repeat: true }", lazy)
                settleTimer.triggered.connect(settle)
                settleTimer.start()
                var watchdog = Qt.createQmlObject("import QtQuick; Timer { interval: 12000 }", lazy)
                watchdog.triggered.connect(function() {
                    if (failed || settled) return
                    console.error("The service checks never settled; phase=" + phase)
                    Qt.exit(1)
                })
                watchdog.start()
            } catch (error) {
                console.error(error.message)
                Qt.exit(1)
            }
        }
    }
}
