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
                var retained = isolated()
                var manyTurns = []
                for (var old = 1; old <= 20; ++old) manyTurns.push({id: old, status: "done", blocks: []})
                retained.turns = manyTurns
                retained.setUiState(1, "calc:0", {x: {v: 3, u: ""}})
                retained.setUiState(20, "calc:0", {x: {v: 4, u: ""}})
                retained.setChecklist(1, 0, 0, true)
                retained.turns = manyTurns.concat([{id: 21, status: "done", blocks: []}]).slice(-20)
                check(!retained.uiStates["1"] && !retained.checklistStates["1"]
                    && retained.uiStates["20"]["calc:0"].x.v === 4,
                    "Discarded turn state cannot keep consuming the edit budget")
                retained.destroy()
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
                var calcFixture = {type: "calc", title: "Trip cost", inputs: [
                    {id: "dist", label: "Distance", unit: "km", min: 0, max: 1000, step: 1, value: 100, basis: "assumption"},
                    {id: "rate", label: "Rate", unit: "", min: 0, max: 10, step: 0.1, value: 2, basis: "assumption"}],
                    tables: [], cells: [{id: "cost", label: "Cost", expression: "dist * rate", unit: "", decimals: 2}]}
                depthContext(calcFixture, "calc:1", {dist: {v: 250, u: "km"}}, "Subject: Trip cost\nInputs: dist=250 km, rate=2")
                depthContext(calcFixture, "calc:1", {dist: {v: 9999, u: "km"}}, "Inputs: dist=100 km, rate=2")   // out of range RESETS to the default (never clamps)
                depthContext(Object.assign({}, calcFixture, {cells: [{id: "bad", label: "Bad", expression: "dist / 0",
                    unit: "", decimals: 2}]}), "calc:1", {}, "Calculation error in bad: ")
                // Hostile calc block: a forged-line title cannot add a request line, an unbuildable block
                // (here 14 inputs, over the limit) reports no Inputs line, and the whole context stays
                // within the 800-character bound.
                var hostile = isolated()
                hostile.agent = "codex"
                hostile.turnId = 9
                var many = []
                for (var calcInput = 0; calcInput < 12; ++calcInput)
                    many.push({id: "input_number_" + calcInput, label: "L", unit: "m", min: 0, max: 1e9, step: 1, value: 123456789.5, basis: "assumption"})
                hostile.turns = [{id: 9, prompt: "p".repeat(900), answer: "A", status: "done", blocks: [
                    {type: "calc", title: "T".repeat(1200), inputs: many, tables: [], cells: [{id: "a", expression: "input_number_0+1", label: "A", unit: "m", decimals: 2}]}]}]
                check(hostile.explainLatest("deeper") && hostile.pending.prompt.length <= 800
                    && hostile.pending.prompt.indexOf("Inputs: input_number_0=123456789.5 m") >= 0,
                    "Hostile calc context must stay bounded with a valid 12-input block")
                hostile.busy = false
                var overLimit = isolated()
                overLimit.agent = "codex"
                overLimit.turnId = 9
                var tooMany = many.concat([{id: "input_number_12", label: "L", unit: "m", min: 0, max: 1e9, step: 1, value: 1, basis: "assumption"},
                    {id: "input_number_13", label: "L", unit: "m", min: 0, max: 1e9, step: 1, value: 1, basis: "assumption"}])
                overLimit.turns = [{id: 9, prompt: "p", answer: "A", status: "done", blocks: [
                    {type: "calc", title: "Too many", inputs: tooMany, tables: [], cells: [{id: "a", expression: "input_number_0+1", label: "A", unit: "m", decimals: 2}]}]}]
                check(overLimit.explainLatest("deeper") && overLimit.pending.prompt.indexOf("Subject: Too many") >= 0
                    && overLimit.pending.prompt.indexOf("Inputs:") < 0,
                    "A calc block over the input limit must report no Inputs line")
                overLimit.busy = false
                overLimit.destroy()
                hostile.destroy()

                // Honest waiting: ONE retained 1 Hz timer, whole seconds from a fake
                // clock, running only while busy AND an AI surface is visible.
                var clocked = isolated()
                clocked.clockOverride = 1000000
                clocked.turnId = 3
                clocked.turns = [{id: 3, prompt: "P", answer: "", blocks: [], suggestions: [], status: "working"}]
                clocked.turnModel.append({payload: clocked.latest})
                check(!clocked.elapsedTicking && clocked.workElapsed === 0, "Idle must run no timer and show no counter")
                clocked.busy = true
                check(!clocked.elapsedTicking, "A hidden surface must not wake a timer for a busy turn")
                clocked.panelActive = true
                check(clocked.elapsedTicking && clocked.workElapsed === 0, "A visible busy turn runs the shared timer")
                clocked.clockOverride = 1002900
                clocked.refreshElapsed()
                check(clocked.workElapsed === 2, "Elapsed is whole seconds, floored: " + clocked.workElapsed)
                clocked.clockOverride = 1003000
                clocked.refreshElapsed()
                check(clocked.workElapsed === 3, "The counter reaches 3 s from the clock")
                clocked.panelActive = false
                check(!clocked.elapsedTicking, "Hiding every surface stops the timer")
                clocked.clockOverride = 1012500
                clocked.panelActive = true
                check(clocked.elapsedTicking && clocked.workElapsed === 12,
                    "A surface that appears recomputes at once: " + clocked.workElapsed)
                clocked.clockOverride = 1000000 - 5000
                clocked.refreshElapsed()
                check(clocked.workElapsed === 0, "A backwards clock never yields a negative counter")
                clocked.clockOverride = 1020000
                clocked.receive(JSON.stringify({type: "activity", turnId: 3, text: "Searching the web\u2026"}))
                check(clocked.activity === "Searching the web\u2026" && clocked.elapsedTicking,
                    "An activity event keeps the turn working")
                clocked.receive(JSON.stringify({type: "done", turnId: 3, answer: "Ok", blocks: [], suggestions: []}))
                check(!clocked.busy && !clocked.elapsedTicking && clocked.workElapsed === 0,
                    "Done must stop the timer and clear the counter")
                clocked.busy = true
                check(clocked.elapsedTicking && clocked.workElapsed === 0, "A new turn starts again at zero")
                clocked.receive(JSON.stringify({type: "error", turnId: 3, message: "Boom"}))
                check(!clocked.elapsedTicking && clocked.workElapsed === 0, "Error must stop the timer")
                clocked.busy = true
                clocked.stop()
                check(!clocked.busy && !clocked.elapsedTicking && clocked.workElapsed === 0, "Stop must stop the timer")

                // Timing ring: 50 sanitised entries, memory only, never persisted.
                var ring = isolated()
                ring.turnId = 3
                ring.turns = [{id: 3, prompt: "P", answer: "", blocks: [], suggestions: [], status: "working"}]
                ring.turnModel.append({payload: ring.latest})
                check(ring.lastTiming === null && ring.timingSummary().n === 0
                    && ring.timingSummary().doneP95 === null, "An empty ring invents no number")
                for (var sample = 0; sample < 55; ++sample) {
                    ring.busy = true
                    ring.receive(JSON.stringify({type: "done", turnId: 3, answer: "A", blocks: [], suggestions: [],
                        timing: {marks: {received: 0, first_text: sample + 1, done: (sample + 1) * 10},
                            streamed: sample % 2 === 0, agent: "codex", unknown: "x"}}))
                }
                check(ring.timingRing.length === 50, "The ring keeps the last 50: " + ring.timingRing.length)
                check(ring.lastTiming.marks.first_text === 55 && ring.timingRing[0].marks.first_text === 6,
                    "The ring drops the oldest first")
                check(ring.lastTiming.unknown === undefined, "Unknown timing keys are ignored")
                var tally = ring.timingSummary()
                check(tally.n === 50 && tally.ttfTextP50 === 30 && tally.ttfBlockP50 === null
                    && tally.doneP50 === 300 && tally.doneP95 === 530 && tally.streamedShare === 0.5
                    && tally.note === "", "Percentiles over hand data: " + JSON.stringify(tally))
                ring.busy = true
                ring.receive(JSON.stringify({type: "done", turnId: 3, answer: "A", blocks: [], suggestions: [],
                    timing: "garbage"}))
                ring.busy = true
                ring.receive(JSON.stringify({type: "done", turnId: 3, answer: "A", blocks: [], suggestions: [],
                    timing: {marks: {done: "12", first_text: -4, final: NaN}, streamed: "yes"}}))
                check(ring.timingRing.length === 50 && ring.lastTiming.marks.first_text === 55,
                    "Hostile timing must add nothing")
                ring.busy = true
                ring.receive(JSON.stringify({type: "done", turnId: 3, answer: "A", blocks: [], suggestions: [],
                    timing: {marks: {first_text: 1e12, done: 1e12}}}))
                check(ring.lastTiming.marks.done === 600000 && ring.lastTiming.marks.first_text === 600000,
                    "Huge values clamp to 600000 ms")
                var persisted = JSON.stringify(ring.workspaceSnapshot()) + JSON.stringify(ring.savePayload())
                check(persisted.indexOf("marks") < 0 && persisted.indexOf("first_text") < 0
                    && ring.latest.timing === undefined, "Timing must stay out of the turn and the saved snapshot")
                var small = isolated()
                small.turnId = 3
                small.turns = [{id: 3, prompt: "P", answer: "", blocks: [], suggestions: [], status: "working"}]
                small.busy = true
                small.receive(JSON.stringify({type: "done", turnId: 3, answer: "A", blocks: [], suggestions: [],
                    timing: {marks: {done: 4500, first_text: 4500}, streamed: false}}))
                check(small.timingSummary().n === 1 && small.timingSummary().doneP95 === 4500
                    && small.timingSummary().note.indexOf("indicative") >= 0, "n < 20 says p95 is indicative")
                small.destroy()
                ring.destroy()

                // Partial-turn seam: partial blocks stay in memory only; the
                // final event resyncs, clears the flag and prunes dead UI state.
                var seam = isolated()
                seam.turnId = 4
                seam.turns = [{id: 3, prompt: "Earlier", answer: "Done", blocks: [{type: "text", text: "Kept"}],
                    suggestions: [], status: "done"},
                    {id: 4, prompt: "Streaming", answer: "", blocks: [], suggestions: [], status: "working"}]
                seam.turnModel.append({payload: seam.turns[0]})
                seam.turnModel.append({payload: seam.turns[1]})
                seam.busy = true
                function snapshotIds() { return seam.workspaceSnapshot().artifacts.map(function(a) { return a.id }) }
                seam.receive(JSON.stringify({type: "presentation", turnId: 4, partial: true, from: 0,
                    blocks: [{type: "text", text: "One"}, {type: "text", text: "Two"}, {type: "text", text: "Three"}]}))
                check(seam.latest.partial === true && seam.latest.blocks.length === 3 && seam.busy,
                    "A partial presentation lands on the working turn")
                check(snapshotIds().length === 1 && snapshotIds()[0] === seam.artifactIdFor(3),
                    "A partial turn must not persist an artifact: " + JSON.stringify(snapshotIds()))
                check(seam.workspaceSnapshot().interaction["turn:4"] !== undefined,
                    "The transcript row still persists")
                seam.receive(JSON.stringify({type: "presentation", turnId: 4, partial: true, from: 7,
                    blocks: [{type: "text", text: "Gap"}]}))
                check(seam.latest.blocks.length === 3, "A gapped partial is ignored")
                check(seam.setUiState(4, "check:2", {selected: [0], checked: false})
                    && seam.setUiState(4, "gallery:2:1", 1) && seam.setUiState(4, "slider:0", 5)
                    && seam.setUiState(4, "csv:src-1", {sort: 1}), "Fixture state must save")
                seam.receive(JSON.stringify({type: "done", turnId: 4, answer: "Final", suggestions: [],
                    blocks: [{type: "text", text: "Only"}]}))
                check(seam.latest.partial !== true && seam.latest.blocks.length === 1 && !seam.busy,
                    "A final event resyncs and clears partial")
                check(snapshotIds().length === 2, "The finished turn persists its artifact")
                var kept = seam.uiStates["4"]
                check(kept["slider:0"] === 5 && kept["csv:src-1"].sort === 1
                    && kept["check:2"] === undefined && kept["gallery:2:1"] === undefined,
                    "A shrunken final answer prunes only dead block keys: " + JSON.stringify(kept))
                check(seam.dirtyContent, "Pruning marks the workspace dirty so the cleaned map is saved")
                // Whole-answer fallback with no blocks: a map left empty is removed.
                seam.busy = true
                seam.turnId = 5
                seam.turns = seam.turns.concat([{id: 5, prompt: "Again", answer: "", blocks: [], suggestions: [], status: "working"}])
                seam.receive(JSON.stringify({type: "presentation", turnId: 5, partial: true, from: 0,
                    blocks: [{type: "text", text: "A"}, {type: "text", text: "B"}]}))
                check(seam.setUiState(5, "step:1", 1), "Fixture state must save")
                seam.receive(JSON.stringify({type: "done", turnId: 5, answer: "Prose only", blocks: [], suggestions: []}))
                check(seam.uiStates["5"] === undefined && seam.uiStates["4"] !== undefined,
                    "An emptied per-turn map is removed")
                // Stopping mid-stream keeps the flag: half-streamed blocks never persist.
                seam.busy = true
                seam.turnId = 6
                seam.turns = seam.turns.concat([{id: 6, prompt: "Stop me", answer: "", blocks: [], suggestions: [], status: "working"}])
                seam.receive(JSON.stringify({type: "presentation", turnId: 6, partial: true, from: 0,
                    blocks: [{type: "text", text: "A"}]}))
                seam.stop()
                check(seam.latest.status === "stopped" && seam.latest.partial === true
                    && snapshotIds().indexOf(seam.artifactIdFor(6)) < 0, "A stopped partial turn persists no artifact")
                seam.destroy()
                clocked.destroy()

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
                // Workspace actions wait for an acknowledged full snapshot;
                // names survive subsequent thin/full saves and restoration.
                function namedFixture() {
                    var named = isolated()
                    named.storeStarting = true
                    named.storeEnabled = true
                    named.restoreSettled = true
                    named.workspaceId = "ws-named"
                    named.turnId = 3
                    named.turns = [{id: 3, prompt: "Original heading", answer: "A", status: "done",
                        blocks: [], suggestions: []}]
                    named.sessionId = "original-session"
                    named.handoffHome = scratchRoot + "/codex-fixture"
                    return named
                }
                function answerHeld(named, value) {
                    var queued = named.storeQueue.shift()
                    named.storeInFlight.push(queued)
                    named.dispatch(JSON.stringify(value))
                    return queued
                }
                var named = namedFixture()
                check(named.renameWorkspace("  My laptop tool  ") && named.workspaceActionPending,
                    "Rename accepts a valid name and enters the save barrier")
                check(named.storeQueue.length === 1 && named.storeQueue[0].op === "save",
                    "Rename must not mutate the title until the full snapshot is acknowledged")
                check(!named.submit("Blocked") && !named.duplicateWorkspace("Copy"),
                    "Pending actions gate provider work and overlapping mutations")
                named.newConversation()
                check(named.workspaceId === "ws-named", "New chat cannot invalidate an in-flight mutation")
                named.draft = "Edited during rename"
                answerHeld(named, {ok: true})
                check(named.storeQueue[0].op === "rename", "The save acknowledgement unlocks rename")
                named.storeRun("save", named.savePayload())
                check(named.storeQueue.length === 1 && named.storeQueue[0].op === "rename",
                    "Close-commit during rename must defer its stale title snapshot")
                answerHeld(named, {ok: true, workspaceId: "ws-named", title: "My laptop tool"})
                check(!named.workspaceActionPending && named.workspaceName === "My laptop tool",
                    "The acknowledged name becomes the explicit override")
                named.dirtyContent = false
                check(named.savePayload().workspace.title === "My laptop tool"
                    && named.workspaceSnapshot().interaction.workspaceName === "My laptop tool"
                    && named.latest.prompt === "Original heading" && named.draft === "Edited during rename",
                    "Thin saves retain the name without rewriting answer headings or drafts")
                named.destroy()
                var rejected = namedFixture()
                check(!rejected.renameWorkspace("bad\nname") && rejected.storeQueue.length === 0,
                    "Invalid names must not enter the store")
                check(rejected.duplicateWorkspace("Tool copy"), "Duplicate enters the save barrier")
                answerHeld(rejected, {ok: false})
                check(!rejected.workspaceActionPending && rejected.workspaceActionError.length > 0
                    && rejected.workspaceId === "ws-named" && rejected.storeQueue.every(function(job) {
                        return job.op !== "duplicate"
                    }), "A failed prerequisite save must never duplicate or navigate")
                rejected.destroy()
                var reusableCalc = {type: "calc", title: "Illustrative weighted comparison", note: "Fixture scores.",
                    inputs: [{id: "weight", label: "Weight", unit: "", min: 1, max: 10, step: 1, value: 5, basis: "assumption"}],
                    cells: [{id: "total", label: "Total weight", expression: "weight", unit: "", decimals: 0}],
                    tables: [{id: "ratings", label: "Candidates", columns: [
                        {id: "name", label: "Name", kind: "text", unit: "", expression: ""},
                        {id: "score", label: "Score", kind: "number", unit: "", expression: ""},
                        {id: "weighted", label: "Weighted score", kind: "formula", unit: "", expression: "score * weight"}],
                        rows: [["A", "5", ""], ["B", "2", ""]]}]}
                var cloned = namedFixture()
                cloned.turns = [Object.assign({}, cloned.latest, {blocks: [reusableCalc]})]
                cloned.setUiState(3, "calc:0", {weight: {v: 8, u: ""}})
                check(cloned.duplicateWorkspace("My second tool"), "Duplicate accepts a title")
                var destination = cloned.workspaceAction.destination
                var savedJob = answerHeld(cloned, {ok: true})
                check(JSON.parse(savedJob.payload).interaction.uiStates["3"]["calc:0"].weight.v === 8,
                    "The clone barrier saves current local calculator inputs")
                check(cloned.storeQueue[0].op === "duplicate"
                    && JSON.parse(cloned.storeQueue[0].payload).newWorkspaceId === destination,
                    "Duplicate gets an independent destination id")
                cloned.draft = "Post-click draft"
                answerHeld(cloned, {ok: true, workspaceId: destination, title: "My second tool"})
                check(cloned.workspaceActionPending && !cloned.loadingLatest
                    && cloned.storeQueue.length === 1 && cloned.storeQueue[0].op === "save",
                    "Opening the clone waits for acknowledgement of later original edits")
                check(JSON.parse(cloned.storeQueue[0].payload).workspace.draft === "Post-click draft",
                    "Edits during cloning are saved to the original, not lost")
                cloned.draft = "One more edit"
                answerHeld(cloned, {ok: true})
                check(cloned.workspaceActionPending && cloned.storeQueue[0].op === "save"
                    && JSON.parse(cloned.storeQueue[0].payload).workspace.draft === "One more edit",
                    "Edits during the final save require another acknowledgement before switching")
                answerHeld(cloned, {ok: true})
                check(cloned.workspaceActionPending && cloned.workspaceTransitionPending && cloned.loadingLatest
                    && cloned.sessionId === "original-session" && cloned.handoffHome !== ""
                    && cloned.storeQueue[0].op === "load",
                    "The final hydration freezes editing and retains original ownership for rollback")
                check(!cloned.setUiState(3, "calc:0", {weight: {v: 10, u: ""}})
                    && !cloned.setChecklist(3, 0, 0, true)
                    && !cloned.setCsvViewState("src-0123456789abcdef", {filter: "late"}),
                    "An edit to the outgoing workspace cannot be accepted during final hydration")
                cloned.draftTouched = true
                answerHeld(cloned, {ok: true, workspace: {id: destination, agent: "codex", sessionRef: "", draft: "Copy draft"},
                    interaction: {workspaceName: "My second tool", "turn:3": {
                        id: 3, prompt: "Original heading", answer: "A", status: "done", artifactId: "copied-calc", blocks: [], suggestions: []},
                        uiStates: {"3": {"calc:0": {weight: {v: 8, u: ""}}}}},
                    artifacts: [{id: "copied-calc", blocks: [reusableCalc]}]})
                check(cloned.workspaceDisplayTitle === "My second tool" && cloned.linkedSourceId === ""
                    && cloned.uiStates["3"]["calc:0"].weight.v === 8 && cloned.draft === "Copy draft"
                    && !cloned.draftTouched && !cloned.workspaceActionPending && cloned.sessionId === "" && cloned.handoffHome === "",
                    "The clone restores its name/inputs/draft without carrying original ownership or typing intent")
                check(cloned.submit("Follow up") && cloned.pending && !cloned.pending.resumeSession,
                    "A clone's first request must not resume the original session")
                var captured = cloned.pending.workspaceContext
                check(captured && captured.previous.turnId === 3 && captured.calc.turnId === 3
                    && captured.calc.inputs[0].value === 8 && captured.calc.inputs[0].adjusted
                    && captured.calc.outputs[0].value === 8 && captured.calc.tables[0].rows[0][2].value === 40
                    && captured.calc.tables[0].rows[1][2].value === 16,
                    "The first fresh-session clone request carries current inputs and locally computed table scores")
                var capturedJson = JSON.stringify(captured), originalBlocks = JSON.stringify(cloned.turns[0].blocks)
                cloned.setUiState(3, "calc:0", {weight: {v: 9, u: ""}})
                check(JSON.stringify(captured) === capturedJson && JSON.stringify(cloned.turns[0].blocks) === originalBlocks,
                    "Later local edits cannot mutate the in-flight snapshot or original answer blocks")
                cloned.receive(JSON.stringify({type: "done", turnId: cloned.turnId, answer: "Explanation", blocks: [], suggestions: []}))
                check(cloned.submit("Explain further") && cloned.pending.workspaceContext.previous.turnId === 4
                    && cloned.pending.workspaceContext.calc.turnId === 3 && cloned.pending.workspaceContext.calc.inputs[0].value === 9,
                    "A later prose follow-up keeps the most recent loaded calculator context with its own identity")
                cloned.busy = false
                cloned.destroy()
                var firstQuestion = isolated()
                firstQuestion.agent = "codex"
                check(firstQuestion.submit("Hello") && firstQuestion.pending && !firstQuestion.pending.workspaceContext,
                    "A first question sends no invented workspace history or calculator snapshot")
                firstQuestion.busy = false
                firstQuestion.destroy()

                // copyText: bool results and limits.
                var copier = isolated()
                check(copier.copyText("Total: 12") && Quickshell.clipboardText === "Total: 12",
                    "copyText copies a plain string")
                check(copier.copyText("a\u0000b\u0000") && Quickshell.clipboardText === "ab",
                    "copyText strips NUL")
                Quickshell.clipboardText = "kept"
                check(!copier.copyText(42) && !copier.copyText(null) && !copier.copyText(undefined)
                    && !copier.copyText({}) && !copier.copyText(["a"]) && !copier.copyText("") && !copier.copyText("\u0000"),
                    "copyText refuses non-strings and empty text")
                check(copier.copyText("x".repeat(65536)) && !copier.copyText("x".repeat(65537)),
                    "copyText accepts 64 KiB and refuses one byte more")
                check(!copier.copyText("é".repeat(32769)) && copier.copyText("é".repeat(32768)),
                    "copyText limits UTF-8 bytes, not characters")
                Quickshell.clipboardText = "kept"
                copier.copyText("y".repeat(70000))
                check(Quickshell.clipboardText === "kept", "A refused copy leaves the clipboard alone")
                copier.destroy()

                // duplicateCalc: a new local turn, never a provider request.
                var dupBlock = Object.assign({}, reusableCalc, {title: "Copy of Illustrative weighted comparison"})
                var dupEntry = {_s: [{n: "Heavy", v: {weight: {v: 9, u: ""}}}]}
                function dupFixture() {
                    var d = namedFixture()
                    d.turns = [Object.assign({}, d.latest, {blocks: [reusableCalc]})]
                    return d
                }
                function saveTimerRunning(svc) {
                    for (var t = 0; t < svc.data.length; ++t)
                        if (svc.data[t] && svc.data[t].interval === 800 && svc.data[t].triggered) return svc.data[t].running
                    return false
                }
                var dup = dupFixture()
                var dupStamp = dup.lastBrokerActivity
                check(dup.duplicateCalc({block: dupBlock, entry: dupEntry}), "duplicateCalc accepts a baked calc")
                check(dup.turns.length === 2 && dup.turnModel.count === 1,
                    "One turn is appended to both the turns list and the stable model (the fixture seeded turns only)")
                check(dup.turnId === 4 && dup.latest.id === 4 && dup.latest.answer === "" && dup.latest.status === "done"
                    && dup.latest.error === "" && dup.latest.warning === "" && dup.latest.suggestions.length === 0
                    && dup.latest.prompt === "Copy of Illustrative weighted comparison"
                    && dup.latest.blocks.length === 1 && dup.latest.blocks[0].type === "calc"
                    && dup.turnModel.get(dup.turnModel.count - 1).payload.id === 4,
                    "The copy is a done turn with one calc block and no answer")
                check(JSON.stringify(dup.uiStates["4"]["calc:0"]) === JSON.stringify(dupEntry)
                    && !dup.uiStates["3"], "The fresh entry lands on the new turn only")
                check(dup.dirtyContent && saveTimerRunning(dup), "A full save is queued")
                check(dup.pending === null && !dup.busy && !dup.stopping && dup.lastBrokerActivity === dupStamp
                    && !dup.brokerStarted && dup.sessionId === "original-session" && dup.agent === ""
                    && dup.handoffHome !== "", "No provider request is made and the provider session is untouched")
                dupBlock.title = "mutated later"
                dupEntry._s[0].n = "mutated"
                check(dup.latest.blocks[0].title === "Copy of Illustrative weighted comparison"
                    && dup.uiStates["4"]["calc:0"]._s[0].n === "Heavy", "The copy is a JSON copy, not a shared reference")
                dupBlock.title = "Copy of Illustrative weighted comparison"
                dupEntry._s[0].n = "Heavy"
                var dupSnap = JSON.parse(JSON.stringify(dup.workspaceSnapshot()))
                check(dupSnap.artifacts.length === 2 && dupSnap.artifacts[1].blocks[0].type === "calc"
                    && dupSnap.interaction["turn:4"].answer === "", "The snapshot carries the copy as an artifact")
                var dupBack = isolated()
                dupBack.applyWorkspaceSnapshot({workspace: dupSnap.workspace, artifacts: dupSnap.artifacts,
                    interaction: dupSnap.interaction}, {})
                check(dupBack.turns.length === 2 && dupBack.turnId === 4 && dupBack.latest.blocks[0].type === "calc"
                    && dupBack.latest.prompt === "Copy of Illustrative weighted comparison"
                    && dupBack.uiStates["4"]["calc:0"]._s[0].n === "Heavy" && dupBack.latest.status === "done",
                    "A restart round trip keeps the duplicated block and its scenarios")
                check(dupBack.explainLatest("simpler") && dupBack.pending.prompt.indexOf("Subject: Copy of") >= 0,
                    "A depth request on the empty-answer copy reads the block itself")
                dupBack.busy = false
                dupBack.destroy()
                dup.agent = "codex"
                check(dup.submit("Why?") && dup.pending.workspaceContext.previous.turnId === 4
                    && dup.pending.workspaceContext.previous.answer === ""
                    && dup.pending.workspaceContext.calc.turnId === 4, "A follow-up after a copy carries the copy's context")
                dup.busy = false
                dup.destroy()

                var plainDup = dupFixture()
                check(plainDup.duplicateCalc({block: dupBlock, entry: {}}) && !plainDup.uiStates["4"],
                    "An empty entry adds no state")
                check(plainDup.duplicateCalc({block: dupBlock}) && !plainDup.uiStates["5"], "A missing entry adds no state")
                check(plainDup.duplicateCalc({block: dupBlock, entry: {_s: [{n: "Bad", v: {weight: {v: 999, u: ""}}}],
                        weight: {v: 7, u: ""}, _d: {x: 1}}})
                    && JSON.stringify(plainDup.uiStates["6"]["calc:0"]) === JSON.stringify({_s: [{n: "Bad", v: {}}]}),
                    "Only validated scenarios are kept; edits, data and out-of-range values are dropped")
                check(plainDup.duplicateCalc({block: dupBlock, entry: "x"}) && !plainDup.uiStates["7"]
                    && plainDup.duplicateCalc({block: dupBlock, entry: [1]}) && !plainDup.uiStates["8"],
                    "A non-object entry is dropped")
                check(plainDup.duplicateCalc({block: Object.assign({}, dupBlock, {title: "T".repeat(400) + "\n"}), entry: {}})
                    && plainDup.latest.prompt.length === 160 && plainDup.latest.prompt.indexOf("Copy of T") === 0,
                    "The prompt is clamped to 160 characters")
                check(plainDup.duplicateCalc({block: Object.assign({}, dupBlock, {title: "A\u0007\nB"}), entry: {}})
                    && plainDup.latest.prompt === "Copy of A B", "Control characters never reach the prompt")
                var untitled = Object.assign({}, dupBlock)
                delete untitled.title
                check(plainDup.duplicateCalc({block: untitled, entry: {}}) && plainDup.latest.prompt === "Copy of calculation",
                    "A missing title still gives a labelled copy")
                var idBefore = plainDup.turnId, countBefore = plainDup.turns.length, modelBefore = plainDup.turnModel.count
                var cyclic = {}
                cyclic.block = {type: "calc", self: cyclic}
                check(!plainDup.duplicateCalc(null) && !plainDup.duplicateCalc("x") && !plainDup.duplicateCalc(7)
                    && !plainDup.duplicateCalc({}) && !plainDup.duplicateCalc({block: null})
                    && !plainDup.duplicateCalc({block: [dupBlock]}) && !plainDup.duplicateCalc({block: {type: "slider"}})
                    && !plainDup.duplicateCalc({block: {type: "calc", pad: "p".repeat(65536)}})
                    && !plainDup.duplicateCalc(cyclic) && plainDup.turnId === idBefore
                    && plainDup.turns.length === countBefore && plainDup.turnModel.count === modelBefore,
                    "Non-objects, wrong types, oversized and cyclic blocks are refused without changes")
                plainDup.destroy()

                var windowed = namedFixture()
                var seeded = []
                for (var seedId = 1; seedId <= 20; ++seedId) {
                    seeded.push({id: seedId, prompt: "Q" + seedId, answer: "A", status: "done", blocks: [], suggestions: []})
                    windowed.turnModel.append({payload: seeded[seedId - 1]})
                }
                windowed.turns = seeded
                windowed.turnId = 20
                check(windowed.duplicateCalc({block: dupBlock, entry: dupEntry}) && windowed.turns.length === 20
                    && windowed.turns[0].id === 2 && windowed.latest.id === 21 && windowed.turnModel.count === 20
                    && windowed.turnModel.get(0).payload.id === 2 && windowed.turnModel.get(19).payload.id === 21,
                    "A duplicate honours the 20-turn window")
                windowed.destroy()

                function gated(label, setup, undo) {
                    var g = dupFixture()
                    setup(g)
                    var before = JSON.stringify([g.turns, g.uiStates, g.turnId, g.turnModel.count])
                    check(!g.duplicateCalc({block: dupBlock, entry: dupEntry}) && g.pending === null
                        && JSON.stringify([g.turns, g.uiStates, g.turnId, g.turnModel.count]) === before,
                        "duplicateCalc must refuse while " + label)
                    undo(g)
                    check(g.duplicateCalc({block: dupBlock, entry: {}}), "duplicateCalc works again after " + label)
                    g.destroy()
                }
                gated("busy", function(g) { g.busy = true }, function(g) { g.busy = false })
                gated("stopping", function(g) { g.stopping = true }, function(g) { g.stopping = false })
                gated("loading the latest workspace", function(g) { g.loadingLatest = true }, function(g) { g.loadingLatest = false })
                gated("restore is unsettled", function(g) { g.restoreSettled = false }, function(g) { g.restoreSettled = true })
                gated("a workspace action is pending", function(g) { g.renameWorkspace("Named") },
                    function(g) { g.failWorkspaceAction(); g.storeQueue = [] })
                gated("a workspace transition is pending", function(g) {
                    g.workspaceAction = {op: "duplicate", phase: "loading", destination: "ws-x"}
                }, function(g) { g.workspaceAction = null })

                // setUiState size guard: 200 KiB for the whole map, never mutating on refusal.
                var guarded = isolated()
                var limit = 200 * 1024, notice = "Too many saved edits to keep this change."
                check(guarded.setUiState(1, "calc:0", {w: {v: 1, u: ""}}) && guarded.stateNotice === ""
                    && guarded.uiStatesBytes(guarded.uiStates) === JSON.stringify(guarded.uiStates).length,
                    "A small edit is accepted without a notice")
                function padState(chars) { return {_s: [{n: "pad", v: {}}], filler: "z".repeat(chars)} }
                var justUnder = limit - guarded.uiStatesBytes({"1": {"calc:0": padState(0)}})
                check(guarded.setUiState(1, "calc:0", padState(justUnder)) && guarded.stateNotice === ""
                    && guarded.uiStatesBytes(guarded.uiStates) === limit, "An edit landing exactly on 200 KiB is accepted")
                var kept = JSON.stringify(guarded.uiStates)
                check(!guarded.setUiState(1, "calc:0", padState(justUnder + 1)) && guarded.stateNotice === notice
                    && JSON.stringify(guarded.uiStates) === kept, "One byte more is refused, notice set, nothing mutated")
                check(!guarded.setUiState(2, "step:0", 1) && JSON.stringify(guarded.uiStates) === kept,
                    "Another turn's edit is refused too while the map is full")
                check(guarded.setUiState(1, "calc:0", {}) && guarded.stateNotice === ""
                    && Object.keys(guarded.uiStates["1"]["calc:0"]).length === 0,
                    "A shrinking edit (Reset) is accepted and clears the notice")
                check(!guarded.setUiState(1, "calc:0", {t: "€".repeat(70000)}) && guarded.stateNotice === notice
                    && Object.keys(guarded.uiStates["1"]["calc:0"]).length === 0,
                    "70000 three-byte characters are over the cap although they are under 200000 characters")
                check(guarded.setUiState(1, "calc:0", {t: "é".repeat(50000)}) && guarded.stateNotice === "",
                    "Two-byte text well under the cap is accepted")
                guarded.uiStates = {"1": {"calc:0": {pad: "q".repeat(210 * 1024)}}}
                check(!guarded.setUiState(1, "calc:0", {pad: "q".repeat(210 * 1024 + 1)}) && guarded.stateNotice === notice,
                    "A map already over the cap cannot grow")
                check(guarded.setUiState(1, "calc:0", {pad: "q".repeat(1024)}) && guarded.stateNotice === "", "It can shrink")
                guarded.turns = [{id: 1, prompt: "Q", answer: "A", status: "done", blocks: []}]
                guarded.turnId = 1
                var nearFull = {pad: "q".repeat(limit - 20 - guarded.uiStatesBytes({"1": {"calc:0": {pad: ""}}}))}
                guarded.uiStates = {"1": {"calc:0": nearFull}}
                var fullBefore = JSON.stringify([guarded.turns, guarded.uiStates, guarded.turnId, guarded.turnModel.count])
                check(!guarded.duplicateCalc({block: dupBlock, entry: dupEntry}) && guarded.stateNotice === notice
                    && JSON.stringify([guarded.turns, guarded.uiStates, guarded.turnId, guarded.turnModel.count]) === fullBefore,
                    "A duplicate whose scenarios would overflow the map is refused whole, with the notice")
                check(guarded.duplicateCalc({block: dupBlock, entry: {}}) && guarded.stateNotice === "",
                    "A duplicate that adds no state still works beside a full map")
                guarded.destroy()
                var transitioning = isolated()
                transitioning.workspaceAction = {op: "duplicate", phase: "loading", destination: "ws-x"}
                check(!transitioning.setUiState(1, "calc:0", {}) && transitioning.stateNotice === "",
                    "A transition refusal does not set the size notice")
                transitioning.workspaceAction = null
                transitioning.destroy()
                var lost = namedFixture()
                lost.duplicateWorkspace("Unconfirmed copy")
                var lostJob = lost.storeQueue.shift()
                lost.failWorkspaceAction()
                lost.storeInFlight.push(lostJob)
                lost.dispatch(JSON.stringify({ok: true}))
                check(!lost.workspaceActionPending && lost.workspaceId === "ws-named"
                    && !lost.storeQueue.some(function(job) { return job.op === "duplicate" }),
                    "A failed/retired action's late reply must never mutate or navigate")
                lost.destroy()
                var unconfirmed = namedFixture()
                unconfirmed.renameWorkspace("Confirmed on disk")
                answerHeld(unconfirmed, {ok: true})
                unconfirmed.failWorkspaceAction(true)
                check(unconfirmed.workspaceName === "Confirmed on disk"
                    && unconfirmed.workspaceSnapshot().interaction.workspaceName === "Confirmed on disk",
                    "An uncertain rename's recovery save must replay its intended name, never undo it")
                unconfirmed.destroy()
                function failedCopyLoad(result) {
                    var rollback = namedFixture()
                    rollback.linkedSourceId = "src-0123456789abcdef"
                    rollback.sourceOrigin = "/fixtures/original.csv"
                    rollback.duplicateWorkspace("Saved but unopened")
                    var target = rollback.workspaceAction.destination
                    answerHeld(rollback, {ok: true})
                    answerHeld(rollback, {ok: true, workspaceId: target, title: "Saved but unopened"})
                    answerHeld(rollback, {ok: true})
                    if (result) answerHeld(rollback, result)
                    else rollback.failWorkspaceAction(true)
                    check(!rollback.workspaceActionPending && !rollback.loadingLatest && rollback.restoreSettled
                        && rollback.workspaceId === "ws-named" && rollback.sessionId === "original-session"
                        && rollback.handoffHome === scratchRoot + "/codex-fixture"
                        && rollback.linkedSourceId === "src-0123456789abcdef" && rollback.sourceOrigin === "/fixtures/original.csv"
                        && rollback.workspaceActionError.indexOf("couldn't be opened") >= 0,
                        "Failed/null/interrupted copy loads must keep original provider/source ownership and show recovery")
                    rollback.destroy()
                }
                failedCopyLoad({ok: false})
                failedCopyLoad({ok: true, workspace: null})
                failedCopyLoad(null)
                var emptyNamed = namedFixture()
                emptyNamed.turns = []
                emptyNamed.workspaceName = "Named empty copy"
                check(emptyNamed.canManageWorkspace, "A named source-less copy keeps management reachable")
                emptyNamed.destroy()
                var recoveredStartup = namedFixture()
                recoveredStartup.renameWorkspace("Never-start fixture")
                recoveredStartup.storeRun("list", {limit: 10})
                recoveredStartup.workspaceActionTimedOut()
                check(!recoveredStartup.workspaceActionPending && !recoveredStartup.storeStarting
                    && recoveredStartup.storePending === recoveredStartup.storeQueue.length
                    && recoveredStartup.storePending > 0 && recoveredStartup.storeBusy,
                    "Never-start timeout releases startup without reporting queued non-action work as idle")
                recoveredStartup.storeRun("save", recoveredStartup.workspaceSnapshot())
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
                // submitForm: ONE fixed-template follow-up carrying the answers in
                // workspaceContext.form; never model text as the prompt.
                var formField = function(id, label, kind, extra) {
                    return Object.assign({id: id, label: label, kind: kind, unit: "", min: 0, max: 0, step: 0, value: 0,
                        options: [], placeholder: ""}, extra || {})
                }
                var tripForm = {type: "form", title: "Trip details", submitLabel: "Send answers", note: "Used to plan.", fields: [
                    formField("budget", "Budget", "number", {unit: "EUR", min: 100, max: 5000, step: 50, value: 1000}),
                    formField("style", "Travel style", "choice", {options: ["Relaxed", "Balanced", "Packed"], value: 1}),
                    formField("notes", "Anything to avoid", "text", {placeholder: "Optional"}),
                    formField("flex", "Flexible dates", "toggle", {value: 0})]}
                var formPrompt = "Answers to the form on the previous answer."
                function formFixture(block) {
                    var f = isolated()
                    f.agent = "codex"
                    f.defaultAgent = "codex"
                    f.turnId = 5
                    f.turns = [{id: 4, prompt: "Hi", answer: "Hello", status: "done", blocks: [], suggestions: []},
                        {id: 5, prompt: "Plan a trip", answer: "Tell me a little more.", status: "done",
                         blocks: [{type: "text", text: "Intro"}, block || tripForm], suggestions: []}]
                    f.turnModel.append({payload: f.turns[0]})
                    f.turnModel.append({payload: f.turns[1]})
                    return f
                }
                var asked = formFixture()
                asked.draft = "keep this draft"
                asked.attachment = ""
                asked.setUiState(5, "form:1", {v: {budget: 1800, style: 2, notes: "No hostels", flex: 1}, sent: false})
                var askedUi = JSON.stringify(asked.uiStates)
                check(asked.submitForm(5, 1), "A valid form is accepted")
                var formRequest = asked.pending
                check(formRequest && formRequest.op === "submit" && formRequest.prompt === formPrompt
                    && formRequest.attachment === undefined && formRequest.turnId === 6,
                    "The request prompt is the fixed sentence, with no attachment")
                check(JSON.stringify(formRequest.workspaceContext.form) === JSON.stringify({turnId: 5, blockIndex: 1,
                    title: "Trip details", answers: [
                        {id: "budget", label: "Budget", kind: "number", value: 1800, unit: "EUR"},
                        {id: "style", label: "Travel style", kind: "choice", value: 2, valueText: "Packed"},
                        {id: "notes", label: "Anything to avoid", kind: "text", value: "No hostels"},
                        {id: "flex", label: "Flexible dates", kind: "toggle", value: 1}]}),
                    "workspaceContext.form has the exact shape: " + JSON.stringify(formRequest.workspaceContext.form))
                check(formRequest.workspaceContext.version === 1 && formRequest.workspaceContext.previous.turnId === 5
                    && formRequest.workspaceContext.truncated === false
                    && Object.keys(formRequest.workspaceContext).sort().join() === "form,previous,truncated,version",
                    "The form rides beside the ordinary snapshot")
                check(asked.latest.id === 6 && asked.latest.prompt === formPrompt && asked.latest.status === "working"
                    && asked.latest.attachment === "" && asked.turnModel.count === 3
                    && asked.turnModel.get(2).payload.formAnswers.length === 4,
                    "A visible turn is appended with the fixed sentence")
                check(JSON.stringify(asked.latest.formAnswers) === JSON.stringify([
                        {label: "Budget", text: "1800 EUR"}, {label: "Travel style", text: "Packed"},
                        {label: "Anything to avoid", text: "No hostels"}, {label: "Flexible dates", text: "Yes"}])
                    && JSON.stringify(asked.latest.formRef) === JSON.stringify({turnId: 5, blockIndex: 1}),
                    "The turn lists the rendered answers and the way back to its form")
                check(asked.draft === "keep this draft" && asked.attachment === "",
                    "A form answer leaves the composer draft alone")
                check(JSON.stringify(asked.uiStates["5"]["form:1"]) === JSON.stringify({v: {budget: 1800, style: 2,
                        notes: "No hostels", flex: 1}, sent: true}),
                    "sent is stored after the request was accepted: " + JSON.stringify(asked.uiStates["5"]["form:1"]))
                check(askedUi !== JSON.stringify(asked.uiStates) && asked.busy, "The service is working")
                check(!asked.submitForm(5, 1) && asked.turns.length === 3, "A repeat while the answer is working is impossible")
                asked.busy = false
                // Persisted form-answer rows, nothing extra on ordinary turns.
                var askedSnapshot = JSON.parse(JSON.stringify(asked.workspaceSnapshot()))
                check(askedSnapshot.interaction["turn:6"].formRef.turnId === 5
                    && askedSnapshot.interaction["turn:6"].formAnswers.length === 4
                    && !("formRef" in askedSnapshot.interaction["turn:5"]) && !("formAnswers" in askedSnapshot.interaction["turn:4"])
                    && askedSnapshot.interaction.uiStates["5"]["form:1"].sent === true,
                    "The snapshot carries the answer rows and the sent mark")
                var restarted = isolated()
                restarted.applyWorkspaceSnapshot({workspace: askedSnapshot.workspace, artifacts: askedSnapshot.artifacts,
                    interaction: askedSnapshot.interaction}, {})
                check(restarted.turns.length === 3 && restarted.latest.formRef.blockIndex === 1
                    && restarted.latest.formAnswers[0].text === "1800 EUR"
                    && restarted.uiStates["5"]["form:1"].sent === true && restarted.latest.status !== "done",
                    "A restart round trip restores the rows, the form link and the sent mark")
                restarted.destroy()
                asked.destroy()
                // An unsent draft survives a restart too (it is ordinary saved state).
                var drafted = formFixture()
                check(drafted.setUiState(5, "form:1", {v: {budget: 750, notes: "Quiet"}, sent: false}),
                    "a form draft is a normal state edit")
                var draftSnapshot = JSON.parse(JSON.stringify(drafted.workspaceSnapshot()))
                var draftBack = isolated()
                draftBack.applyWorkspaceSnapshot({workspace: draftSnapshot.workspace, artifacts: draftSnapshot.artifacts,
                    interaction: draftSnapshot.interaction}, {})
                check(JSON.stringify(draftBack.uiStates["5"]["form:1"]) === JSON.stringify({v: {budget: 750, notes: "Quiet"}, sent: false}),
                    "The draft values come back after a restart")
                draftBack.destroy()
                drafted.destroy()

                // Hostile labels and values are cleaned and bounded on the wire.
                var BEL = String.fromCharCode(7), RLO = String.fromCharCode(0x202e), ZWSP = String.fromCharCode(0x200b)
                var evil = formFixture({type: "form", title: "T" + BEL + "\n" + "x".repeat(400), submitLabel: "Go", note: "",
                    fields: [formField("a", "L" + RLO + "abel" + BEL + String.fromCharCode(0xd800) + "y".repeat(200), "text"),
                             formField("b", "Two  \n lines", "text"),
                             formField("c", "Pick", "choice", {options: ["o".repeat(60), "q"], value: 0})]})
                evil.setUiState(5, "form:1", {v: {a: "fine", b: "  a   b  ", c: 0}})
                check(evil.submitForm(5, 1), "A hostile form still sends its cleaned answers")
                var evilWire = evil.pending.workspaceContext.form
                var evilJson = JSON.stringify(evilWire)
                var escapedNewline = String.fromCharCode(92) + "n"
                check(evilWire.title.length === 160 && evilWire.answers[0].label.length <= 80
                    && evilWire.answers[1].label === "Two lines" && evilWire.answers[1].value === "a b"
                    && evilWire.answers[2].valueText.length === 48
                    && evilJson.indexOf(BEL) < 0 && evilJson.indexOf(RLO) < 0 && evilJson.indexOf(ZWSP) < 0
                    && evilJson.indexOf(escapedNewline) < 0 && evilJson.indexOf("\\u0007") < 0,
                    "Labels and values are single clean lines within bounds: " + evilJson.slice(0, 300))
                check(evilWire.answers.length === 3 && evilWire.answers.every(function(a) {
                    return a.id.length <= 24 && a.label.length <= 80 && (a.kind !== "text" || a.value.length <= 200) }),
                    "At most six answers within the id/label/value bounds")
                evil.busy = false
                evil.destroy()

                // Gates: nothing is appended, sent or stored while any is closed.
                function formGate(label, setup, undo) {
                    var g = formFixture()
                    setup(g)
                    var before = JSON.stringify([g.turns, g.uiStates, g.turnId, g.turnModel.count])
                    check(!g.submitForm(5, 1) && g.pending === null && JSON.stringify([g.turns, g.uiStates, g.turnId, g.turnModel.count]) === before,
                        "submitForm must refuse while " + label)
                    if (undo) {
                        undo(g)
                        check(g.submitForm(5, 1), "submitForm works again after " + label)
                        g.busy = false
                    }
                    g.destroy()
                }
                formGate("busy", function(g) { g.busy = true }, function(g) { g.busy = false })
                formGate("stopping", function(g) { g.stopping = true }, function(g) { g.stopping = false })
                formGate("loading the latest workspace", function(g) { g.loadingLatest = true }, function(g) { g.loadingLatest = false })
                formGate("a workspace action is pending", function(g) {
                    g.storeStarting = true
                    g.storeEnabled = true
                    g.restoreSettled = true
                    g.workspaceId = "ws-named"
                    check(g.renameWorkspace("Named"), "the fixture enters a workspace action")
                }, function(g) { g.failWorkspaceAction(); g.storeQueue = [] })
                formGate("a workspace transition is pending", function(g) {
                    g.workspaceAction = {op: "duplicate", phase: "loading", destination: "ws-x"}
                }, function(g) { g.workspaceAction = null })
                formGate("the form's turn is no longer the latest", function(g) {
                    g.turns = g.turns.concat([{id: 6, prompt: "Later", answer: "B", status: "done", blocks: [], suggestions: []}])
                }, null)
                formGate("the form's turn is still working", function(g) {
                    g.turns = [g.turns[0], Object.assign({}, g.turns[1], {status: "working"})]
                }, null)
                formGate("there is no agent", function(g) { g.agent = ""; g.defaultAgent = "" }, null)
                formGate("the turn is unknown", function(g) { g.turns = [g.turns[0]] }, null)
                var wrongIndex = formFixture()
                check(!wrongIndex.submitForm(5, 0) && !wrongIndex.submitForm(5, 2) && !wrongIndex.submitForm(5, -1)
                    && !wrongIndex.submitForm(5, 6) && !wrongIndex.submitForm("5", 1) && !wrongIndex.submitForm(5.5, 1)
                    && !wrongIndex.submitForm(5, 1.5) && !wrongIndex.submitForm(null, 1) && !wrongIndex.submitForm(5)
                    && wrongIndex.pending === null && wrongIndex.turns.length === 2,
                    "A block that is not a form, or a malformed identity, is refused")
                wrongIndex.destroy()
                var hostileForm = formFixture({type: "form", title: "Dead", fields: 7})
                check(!hostileForm.submitForm(5, 1) && hostileForm.pending === null, "An unusable form is refused")
                hostileForm.destroy()

                // A failed response keeps the form open for one more send; each send is a new turn.
                var retry = formFixture()
                check(retry.submitForm(5, 1), "first send")
                retry.receive(JSON.stringify({type: "error", turnId: retry.turnId, message: "Codex could not complete the answer."}))
                check(!retry.busy && retry.latest.status === "error" && retry.latest.formRef.turnId === 5,
                    "The failed answer stays a form-answer turn")
                check(retry.submitForm(5, 1) && retry.turns.length === 4 && retry.latest.id === 7
                    && retry.pending.prompt === formPrompt && retry.pending.workspaceContext.form.turnId === 5,
                    "A retry is a NEW turn carrying the same form")
                retry.receive(JSON.stringify({type: "done", turnId: retry.turnId, answer: "Here you go", blocks: [], suggestions: []}))
                check(!retry.submitForm(5, 1) && retry.turns.length === 4,
                    "Once answered, the form's turn is closed")
                retry.destroy()

                // Bounds: a form too large for the broker's 4 KiB form limit is refused, not truncated.
                var bigForm = formFixture({type: "form", title: "T".repeat(160), submitLabel: "Go", note: "",
                    fields: ["a", "b", "c", "d", "e", "f"].map(function(id) { return formField(id, id.toUpperCase(), "text") })})
                var wide = String.fromCharCode(0x4e2d).repeat(200)
                bigForm.setUiState(5, "form:1", {v: {a: wide, b: wide, c: wide, d: wide, e: wide, f: wide}})
                check(!bigForm.submitForm(5, 1) && bigForm.pending === null && bigForm.turns.length === 2,
                    "Answers over the wire bound are refused before anything is appended")
                bigForm.setUiState(5, "form:1", {v: {a: wide, b: wide}})
                check(bigForm.submitForm(5, 1), "the same form fits with fewer long answers")
                bigForm.busy = false
                bigForm.destroy()

                // Size guard: the sent mark must fit the 200 KiB map BEFORE anything is sent.
                var fullMap = formFixture()
                fullMap.setUiState(4, "calc:0", {pad: ""})
                var baseBytes = fullMap.uiStatesBytes(fullMap.uiStates)
                check(fullMap.setUiState(4, "calc:0", {pad: "z".repeat(200 * 1024 - 10 - baseBytes)}),
                    "the fixture fills the map to within 10 bytes of the cap")
                var fullBefore = JSON.stringify([fullMap.turns, fullMap.uiStates, fullMap.turnId, fullMap.turnModel.count])
                check(200 * 1024 - fullMap.uiStatesBytes(fullMap.uiStates) === 10, "fixture is 10 bytes under the cap")
                check(!fullMap.submitForm(5, 1) && fullMap.stateNotice === "Too many saved edits to keep this change."
                    && fullMap.pending === null && JSON.stringify([fullMap.turns, fullMap.uiStates, fullMap.turnId, fullMap.turnModel.count]) === fullBefore,
                    "A form whose sent mark cannot be stored is refused whole, with the notice")
                fullMap.setUiState(4, "calc:0", {})
                check(fullMap.submitForm(5, 1) && fullMap.stateNotice === "", "Making room lets the same form go")
                fullMap.busy = false
                fullMap.destroy()

                // An ordinary question still clears the composer and records no form link.
                var ordinary = formFixture()
                ordinary.draft = "typed"
                check(ordinary.submit("A typed question") && ordinary.draft === "" && ordinary.latest.formRef === undefined
                    && ordinary.latest.formAnswers === undefined && ordinary.pending.workspaceContext.form === undefined,
                    "Typed questions are unchanged")
                ordinary.busy = false
                ordinary.destroy()

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
                // No default chosen at all: nothing to fall back to. (An explicit but
                // unsupported default now falls back to Codex; see AiState.resolveAgent.)
                service.defaultAgent = ""
                service.submit("Fixture without an AI call")
                check(service.agent === "" && !service.busy && service.latest.status === "error", "A missing default agent must not latch or start a helper")
                service.defaultAgent = "codex"
                check(service.agent === "", "Correcting a default must allow recovery without resetting a failed session")
                service.destroy()

                // Asynchronously verify the one latest load settles and the
                // user's typed draft survives the completed snapshot.
                var settled = false, failed = null, phase = 0, phaseTime = 0

                // Durable CSV source: the keep/replace/link/restore flows against the
                // in-memory source worker (tests/ai_csv_source_stub.py) and a HELD
                // store queue, so ordering is observable and no file is touched.
                function until(condition, next, label) {
                    var started = Date.now()
                    var timer = Qt.createQmlObject("import QtQuick; Timer { interval: 20; repeat: true }", lazy)
                    timer.triggered.connect(function() {
                        try {
                            if (condition()) { timer.stop(); timer.destroy(); next() }
                            else if (Date.now() - started > 4000) throw new Error("Timed out waiting for " + label)
                        } catch (error) { timer.stop(); console.error(error.message); Qt.exit(1) }
                    })
                    timer.start()
                }
                function keepChecks(finished) {
                    var csvStub = decodeURIComponent(Qt.resolvedUrl("tests/ai_csv_source_stub.py").toString().replace(/^file:\/\//, ""))
                    var svc = component.createObject(parent, {storeEnabled: true, storeScript: stubScript,
                        brokerScript: stubScript, stateRoot: scratchRoot})
                    check(svc.stateRoot === scratchRoot && svc.csvSource.stateRoot === scratchRoot,
                        "The source client must follow the service's isolated state root")
                    svc.csvSource.workerScript = csvStub
                    check(svc.csvSource.workerScript === csvStub, "The source worker must be the offline stub")
                    check(!svc.csvSource.surfacesVisible, "Hidden surfaces let the source worker idle out")
                    svc.panelActive = true
                    check(svc.csvSource.surfacesVisible, "The visible panel keeps the source client warm")
                    svc.panelActive = false
                    svc.windowActive = true
                    check(svc.csvSource.surfacesVisible, "The detached window keeps the source client warm")
                    svc.windowActive = false
                    svc.defaultAgent = "codex"
                    // Hold the store in memory: jobs stay inspectable and are answered by hand.
                    svc.storeStarting = true
                    svc.newConversation()
                    svc.storeQueue = []
                    svc.storePending = 0
                    function hex(n, width) { var t = n.toString(16); while (t.length < width) t = "0" + t; return t }
                    function sid(rows, flags) { return "src-" + hex(rows, 8) + hex(flags, 8) }
                    function ops() { return svc.storeQueue.map(function(job) { return job.op }) }
                    function serve(op, result) {
                        check(svc.storeQueue.length > 0 && svc.storeQueue[0].op === op,
                            "Next store job must be " + op + ", queue is " + JSON.stringify(ops()))
                        var job = svc.storeQueue[0]
                        svc.storeInFlight.push(svc.storeQueue.shift())
                        svc.dispatch(JSON.stringify(result))
                        return job
                    }
                    // Debounced autosaves from submits may interleave; they are not under test.
                    // The real FileView clears defaultAgent asynchronously in a scratch HOME.
                    function ask(text) { svc.defaultAgent = "codex"; svc.brokerStarted = false; return svc.submit(text) }
                    function dropSaves() { while (svc.storeQueue.length && svc.storeQueue[0].op === "save") serve("save", {ok: true}) }
                    // A CSV attachment whose preview already read ready (no reader runs offscreen).
                    function readyAttach(path) {
                        svc.attachment = path
                        var ap = svc.attachmentPreview
                        ap._resultPath = path
                        ap._resultToken = ap.token
                        ap.data = {columns: ["a"], rows: [], sampleRows: 0, totalRows: 0, truncated: false}
                        ap.status = "ready"
                    }
                    function fireKeepGuard() {
                        for (var i = 0; i < svc.data.length; ++i)
                            if (svc.data[i] && svc.data[i].interval === 15000 && svc.data[i].triggered) { svc.data[i].triggered(); return true }
                        return false
                    }
                    function unlinks() {
                        return svc.storeQueue.filter(function(job) { return job.op === "source_unlink" })
                            .map(function(job) { return JSON.parse(job.payload).sourceId })
                    }
                    function finishTurn(type) {
                        svc.receive(JSON.stringify(type === "explain"
                            ? {type: "explain", turnId: svc.turnId, text: "Prose"}
                            : {type: "done", turnId: svc.turnId, answer: "A", blocks: [], suggestions: []}))
                        check(!svc.busy, "The stub turn must finish")
                    }
                    var id70 = sid(70, 0), id80 = sid(80, 0), id91 = sid(91, 0)

                    // 1. Keep: the 1 GiB check answers first, then the copy registers.
                    // The service's own boot index refresh lands one tick after creation.
                    until(function() { return ops().indexOf("list") >= 0 }, function() {
                        svc.storeQueue = []
                        svc.storePending = 0
                        firstKeep()
                    }, "the boot index refresh")
                    function firstKeep() {
                    check(svc.startKeep("/scratch/u/rows70.csv"), "Keeping the current CSV must start")
                    check(svc.keepPhase === "budget" && svc.sourceStatus === "registering" && svc.workspaceId !== "",
                        "Keep waits for the budget answer under a workspace id")
                    check(svc.csvSource.status === "idle", "Nothing registers before the budget answer")
                    check(!svc.startKeep("/scratch/u/rows71.csv") && svc.storeQueue.length === 1,
                        "A second keep must not corrupt the pending one")
                    check(JSON.parse(svc.storeQueue[0].payload).workspaceId === undefined,
                        "The budget check covers the whole registry")
                    serve("source_list", {ok: true, totalBytes: 1000, count: 0, sources: []})
                    check(svc.keepPhase === "register" && svc.csvSource.status === "registering",
                        "A passing budget registers the copy")
                    until(function() { return svc.keepPhase === "link" }, function() {
                        check(svc.csvSource.sourceId === id70, "The registered copy is the current source")
                        check(JSON.stringify(ops()) === JSON.stringify(["save", "source_link"]),
                            "The workspace is saved BEFORE the source is linked, got " + JSON.stringify(ops()))
                        check(JSON.stringify(JSON.parse(svc.storeQueue[1].payload)) === JSON.stringify(
                            {workspaceId: svc.workspaceId, sourceId: id70, bytes: 70 * 24 + 16, rows: 70}),
                            "The link carries the workspace, source, bytes and rows")
                        check(!svc.sourceReady && svc.linkedSourceId === "",
                            "An unlinked copy is not yet this workspace's ready source")
                        // View state before any turn exists is held, then follows the first turn.
                        check(svc.setCsvViewState(id70, {sort: 2, dir: -1, filter: "x", page: 3, junk: 1}),
                            "The explorer view state is accepted")
                        check(JSON.stringify(svc.csvViewState(id70)) === JSON.stringify(
                            {sort: 2, dir: -1, filter: "x", page: 3}) && svc.turns.length === 0,
                            "Held state is sanitised and readable before the first turn")
                        check(!svc.setCsvViewState("src-nope", {sort: 1}), "A foreign key is refused")
                        check(ask("Before link"), "A send while linking is allowed")
                        check(!("sourceId" in svc.pending), "A copy that is not linked yet is never claimed to the broker")
                        check(JSON.stringify(svc.uiStates[String(svc.latest.id)]["csv:" + id70]) === JSON.stringify(
                            {sort: 2, dir: -1, filter: "x", page: 3}) && svc.heldCsvView === null,
                            "The first turn takes over the held view state")
                        finishTurn("done")
                        serve("save", {ok: true})
                        dropSaves()
                        serve("source_link", {ok: true, sourceId: id70})
                        check(svc.linkedSourceId === id70 && svc.sourceOrigin === "/scratch/u/rows70.csv"
                            && svc.sourceReady && svc.keepPhase === "" && svc.sourceStatus === "ready"
                            && svc.sourceError === "", "A successful link makes the source ready")
                        check(JSON.stringify(svc.workspaceSnapshot().interaction.csvSource) === JSON.stringify(
                            {sourceId: id70, origin: "/scratch/u/rows70.csv"}), "The origin hint is saved with the workspace")
                        check(ask("With source"), "A follow-up is accepted")
                        check(svc.pending.sourceId === id70, "Every turn of a workspace with a ready source carries sourceId")
                        check(JSON.stringify(svc.uiStates[String(svc.latest.id)]["csv:" + id70]) === JSON.stringify(
                            {sort: 2, dir: -1, filter: "x", page: 3}), "Each submit carries the explorer view to the new latest turn")
                        finishTurn("done")
                        svc.brokerStarted = false
                        check(svc.explainLatest("simpler"), "Depth requests are accepted")
                        check(svc.pending.sourceId === id70, "Depth requests carry the source statistics too")
                        finishTurn("explain")
                        // Wrong-file statistics: the kept file's numbers ride only with the kept
                        // data (no attachment) or with the kept file itself.
                        check(svc.sourceApplies, "Without an attachment the kept statistics apply")
                        readyAttach("/scratch/u/other.csv")
                        check(svc.sourceReady && !svc.sourceApplies,
                            "A different attached file does not get the kept file's statistics")
                        check(ask("About the other file") && svc.pending.attachment === "/scratch/u/other.csv",
                            "The different file is attached to the request")
                        check(!("sourceId" in svc.pending), "A different attached file never carries sourceId")
                        finishTurn("done")
                        svc.brokerStarted = false
                        check(svc.explainLatest("simpler") && !("sourceId" in svc.pending),
                            "Depth on an answer about a different file never carries the kept statistics")
                        finishTurn("explain")
                        readyAttach("/scratch/u/rows70.csv")
                        check(svc.sourceApplies, "Attaching the kept file itself keeps the statistics")
                        check(ask("About the kept file") && svc.pending.attachment === "/scratch/u/rows70.csv"
                            && svc.pending.sourceId === id70, "The kept file attached again carries sourceId")
                        finishTurn("done")
                        svc.brokerStarted = false
                        check(svc.explainLatest("simpler") && svc.pending.sourceId === id70,
                            "Depth on an answer about the kept file carries the statistics")
                        finishTurn("explain")
                        check(ask("Follow-up on the kept data") && !svc.pending.attachment && svc.pending.sourceId === id70,
                            "A follow-up with no attachment still carries the statistics")
                        finishTurn("done")
                        replaceCheck()
                    }, "the keep to reach linking")
                    }

                    // 2. Replacing: one source per workspace; the old copy goes AFTER the new link.
                    function replaceCheck() {
                        dropSaves()
                        check(svc.startKeep("/scratch/u/rows80.csv"), "Another keep replaces the source")
                        check(svc.keepJob.previous === id70, "The replaced source is remembered")
                        serve("source_list", {ok: true, totalBytes: 1696, count: 1,
                            sources: [{id: id70, workspaceId: svc.workspaceId, bytes: 1696, rows: 70}]})
                        until(function() { return svc.keepPhase === "link" }, function() {
                            check(svc.linkedSourceId === id70 && !svc.sourceReady,
                                "While swapping, the new copy is not claimed to the broker")
                            var queued = ops()
                            check(queued.slice(-2).join() === "save,source_link", "Swap saves, then links, got " + JSON.stringify(queued))
                            check(queued.indexOf("source_unlink") < 0, "The old copy is not unlinked before the new link succeeds")
                            dropSaves()
                            serve("source_link", {ok: true, sourceId: id80})
                            check(svc.linkedSourceId === id80 && svc.sourceReady && svc.sourceOrigin === "/scratch/u/rows80.csv",
                                "The new copy becomes the source")
                            var unlink = JSON.parse(serve("source_unlink", {ok: true, unlinked: true}).payload)
                            check(JSON.stringify(unlink) === JSON.stringify({sourceId: id70, removeDir: true}),
                                "The replaced copy is unlinked with its directory, got " + JSON.stringify(unlink))
                            check(ops().indexOf("source_unlink") < 0, "Exactly one copy is removed")
                            budgetCheck()
                        }, "the replacement to reach linking")
                    }

                    // 3. Budget: refusal is static and leaves the current source alone.
                    function budgetCheck() {
                        dropSaves()
                        check(svc.startKeep("/scratch/u/rows90.csv"), "A keep over budget still asks the registry")
                        serve("source_list", {ok: true, totalBytes: 1073741824, count: 1,
                            sources: [{id: id80, workspaceId: svc.workspaceId, bytes: 1936, rows: 80}]})
                        check(svc.keepPhase === "" && svc.sourceError.indexOf("1 GiB") >= 0,
                            "A copy that could exceed 1 GiB is refused with a static text")
                        check(svc.csvSource.status === "ready" && svc.csvSource.sourceId === id80 && svc.sourceReady
                            && svc.sourceStatus === "ready", "A refusal never touches the current source")
                        check(svc.storeQueue.length === 0, "A refusal queues no store work")
                        check(!svc.startKeep("/scratch/u/" + "x".repeat(5000) + ".csv"), "An unrepresentable path is refused")
                        // 4. Exactly at the limit is allowed; a failed link leaves a static error.
                        dropSaves()
                        check(svc.startKeep("/scratch/u/rows91.csv"), "A keep exactly at the limit starts")
                        serve("source_list", {ok: true, totalBytes: 1073741824 - 67108864 + 1936, count: 1,
                            sources: [{id: id80, workspaceId: svc.workspaceId, bytes: 1936, rows: 80}]})
                        until(function() { return svc.keepPhase === "link" }, function() {
                            dropSaves()
                            serve("source_link", {ok: false, error: "Fixture"})
                            check(svc.keepPhase === "" && svc.sourceError.indexOf("Could not save the kept copy") >= 0,
                                "A failed link ends with a static error")
                            var cleanup = JSON.parse(serve("source_unlink", {ok: true}).payload)
                            check(JSON.stringify(cleanup) === JSON.stringify({sourceId: id91, removeDir: true}),
                                "A copy that never got a row is removed")
                            check(unlinks().length === 0, "Exactly one removal, and never the previous copy's")
                            check(svc.linkedSourceId === id80, "The old row is still the workspace's source")
                            until(function() { return svc.sourceReady && svc.csvSource.sourceId === id80 }, function() {
                                guardTimeoutCheck()
                            }, "the previous copy to come back")
                        }, "the over-limit keep to reach linking")
                    }

                    // 4b. Every keep failure after the worker returned an id removes exactly
                    // that new copy (store op source_unlink {removeDir:true}) and never the
                    // linked one.
                    function expectCleanup(id, label) {
                        check(JSON.stringify(unlinks()) === JSON.stringify([id]),
                            label + ": exactly one removal, for the new copy, got " + JSON.stringify(unlinks()))
                        var cleanup = JSON.parse(serve("source_unlink", {ok: true}).payload)
                        check(JSON.stringify(cleanup) === JSON.stringify({sourceId: id, removeDir: true}),
                            label + ": removes the new directory")
                        check(svc.linkedSourceId === id80, label + ": the linked source is untouched")
                    }
                    function guardTimeoutCheck() {
                        dropSaves()
                        var id92 = sid(92, 0)
                        check(svc.startKeep("/scratch/u/rows92.csv"), "A keep for the timeout case starts")
                        serve("source_list", {ok: true, totalBytes: 1936, count: 1,
                            sources: [{id: id80, workspaceId: svc.workspaceId, bytes: 1936, rows: 80}]})
                        until(function() { return svc.keepPhase === "link" }, function() {
                            check(fireKeepGuard(), "The 15 s keep guard exists")
                            check(svc.keepPhase === "" && svc.sourceError.indexOf("timed out") >= 0, "The guard ends the keep")
                            dropSaves()
                            // The link was already sent; its late success must not unlink the old copy.
                            serve("source_link", {ok: true, sourceId: id92})
                            check(unlinks().length === 1 && unlinks()[0] === id92,
                                "A late link of an abandoned copy removes only that copy, got " + JSON.stringify(unlinks()))
                            check(svc.linkedSourceId === id80 && svc.sourceOrigin === "/scratch/u/rows80.csv",
                                "An abandoned keep never relinks")
                            expectCleanup(id92, "Guard timeout")
                            until(function() { return svc.sourceReady && svc.csvSource.sourceId === id80 }, rejectedCheck,
                                "the previous copy after the timeout")
                        }, "the timeout keep to reach linking")
                    }
                    function rejectedCheck() {
                        dropSaves()
                        var id93 = sid(93, 0)
                        check(svc.startKeep("/scratch/u/rows93badmeta.csv"), "A keep whose reply the client will reject starts")
                        serve("source_list", {ok: true, totalBytes: 1936, count: 1,
                            sources: [{id: id80, workspaceId: svc.workspaceId, bytes: 1936, rows: 80}]})
                        until(function() { return svc.keepPhase === "" && svc.csvSource.status !== "registering" && unlinks().length > 0 },
                            function() {
                            check(svc.sourceError !== "" && !svc.keepPending, "A rejected register reply ends the keep with an error")
                            expectCleanup(id93, "Rejected reply")
                            until(function() { return svc.sourceReady && svc.csvSource.sourceId === id80 }, earlyAbortCheck,
                                "the previous copy after the rejected reply")
                        }, "the rejected reply to be cleaned up")
                    }
                    function earlyAbortCheck() {
                        dropSaves()
                        var id94 = sid(94, 0)
                        var realWorkspace = svc.workspaceId
                        check(svc.startKeep("/scratch/u/rows94.csv"), "A keep that will lose its workspace starts")
                        serve("source_list", {ok: true, totalBytes: 1936, count: 1,
                            sources: [{id: id80, workspaceId: realWorkspace, bytes: 1936, rows: 80}]})
                        check(svc.keepPhase === "register", "The copy is registering")
                        svc.workspaceId = "ws-moved-away"
                        until(function() { return svc.keepPhase === "" && unlinks().length > 0 }, function() {
                            svc.workspaceId = realWorkspace
                            check(svc.sourceError.indexOf("Could not save the kept copy") >= 0, "The early abort shows the static error")
                            expectCleanup(id94, "Early abort before linking")
                            until(function() { return svc.sourceReady && svc.csvSource.sourceId === id80 }, newChatCheck,
                                "the previous copy after the early abort")
                        }, "the early abort to clean up")
                    }

                    // 5. New chat: the source stays with the finished workspace.
                    function newChatCheck() {
                        svc.storeQueue = []
                        svc.storePending = 0
                        svc.newConversation()
                        var saved = JSON.parse(svc.storeQueue.filter(function(job) { return job.op === "save" })[0].payload)
                        check(saved.interaction.csvSource.sourceId === id80,
                            "The finished conversation is saved with its source hint")
                        check(ops().indexOf("source_unlink") < 0, "New chat never deletes the source")
                        check(svc.linkedSourceId === "" && !svc.sourceReady && svc.csvSource.status === "idle"
                            && svc.csvSource.sourceId === "" && svc.sourceStatus === "idle" && svc.heldCsvView === null,
                            "New chat invalidates the client token")
                        check(!("csvSource" in svc.workspaceSnapshot().interaction), "A fresh conversation has no source")
                        check(ask("Fresh chat"), "A fresh chat sends normally")
                        check(!("sourceId" in svc.pending), "A fresh chat carries no sourceId")
                        finishTurn("done")
                        restoreChecks()
                    }

                    // 6. Restore: the registry decides; verify states become notices.
                    function restoreChecks() {
                        svc.storeQueue = []
                        svc.storePending = 0
                        var changed = sid(60, 32)
                        var stale = sid(40, 0)
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-r", agent: "codex"}, artifacts: [],
                            interaction: {csvSource: {sourceId: changed, origin: "/scratch/u/data.csv"}}}, {})
                        check(svc.linkedSourceId === changed && svc.sourceOrigin === "/scratch/u/data.csv",
                            "The saved hint survives until the registry answers")
                        serve("list", {ok: true, workspaces: []})
                        var request = JSON.parse(serve("source_list", {ok: true, totalBytes: 0, count: 3, sources: [
                            {id: stale, workspaceId: "ws-r"}, {id: changed, workspaceId: "ws-r"},
                            {id: sid(30, 0), workspaceId: "ws-other"}]}).payload)
                        check(JSON.stringify(request) === JSON.stringify({workspaceId: "ws-r"}), "Restore asks for this workspace only")
                        check(svc.storeQueue.length === 0,
                            "No older copy is removed before the newest one has opened and verified")
                        until(function() { return svc.sourceNotice === "originChanged" }, function() {
                            var cleanup = JSON.parse(serve("source_unlink", {ok: true}).payload)
                            check(JSON.stringify(cleanup) === JSON.stringify({sourceId: stale, removeDir: true}),
                                "An interrupted swap's older copy is removed once the newest opened")
                            check(svc.storeQueue.length === 0, "The other workspace's copy is never touched")
                            check(svc.sourceReady && svc.csvSource.sourceId === changed, "A changed original keeps the saved copy usable")
                            check(svc.canRefreshSource, "A known origin offers Refresh")
                            check(svc.refreshSource(), "Refresh starts")
                            check(svc.keepJob.path === "/scratch/u/data.csv" && svc.keepJob.previous === changed,
                                "Refresh copies the original and remembers the saved copy")
                            serve("source_list", {ok: true, totalBytes: 100, count: 1,
                                sources: [{id: changed, workspaceId: "ws-r", bytes: 100, rows: 60}]})
                            until(function() { return svc.keepPhase === "link" }, function() {
                                dropSaves()
                                serve("source_link", {ok: true, sourceId: sid(60, 0)})
                                check(svc.linkedSourceId === sid(60, 0) && svc.sourceNotice === "" && svc.sourceReady,
                                    "Refresh swaps to the new copy and clears the notice")
                                var swapped = JSON.parse(serve("source_unlink", {ok: true}).payload)
                                check(swapped.sourceId === changed && swapped.removeDir === true, "The stale copy is removed after the swap")
                                notices()
                            }, "the refresh to reach linking")
                        }, "the original-changed notice")
                    }

                    function restoreWith(id, extra, then, label) {
                        svc.storeQueue = []
                        svc.storePending = 0
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-n", agent: "codex"}, artifacts: [],
                            interaction: {csvSource: {sourceId: id, origin: "/scratch/u/data.csv"}}}, {})
                        serve("list", {ok: true, workspaces: []})
                        serve("source_list", {ok: true, totalBytes: 0, count: extra.length, sources: extra})
                        until(then.until, function() { then.check(); then.next() }, label)
                    }
                    function notices() {
                        restoreWith(sid(50, 64), [{id: sid(50, 64), workspaceId: "ws-n"}], {
                            until: function() { return svc.sourceNotice === "originMissing" },
                            check: function() { check(svc.sourceReady && !svc.canRefreshSource,
                                "A missing original keeps the saved copy and offers no refresh") },
                            next: function() {
                                restoreWith(sid(50, 128), [{id: sid(50, 128), workspaceId: "ws-n"}], {
                                    until: function() { return svc.sourceNotice === "copyMissing" },
                                    check: function() { },
                                    next: function() {
                                        var broken = "src-0000000500000fff"
                                        restoreWith(broken, [{id: broken, workspaceId: "ws-n"}], {
                                            until: function() { return svc.sourceNotice === "copyMissing" && svc.csvSource.status === "error" },
                                            check: function() {
                                                check(!svc.sourceReady && svc.sourceStatus === "error", "A copy that cannot open is not ready")
                                                svc.brokerStarted = false
                                                check(svc.submit("Still usable"), "The workspace stays fully usable")
                                                check(!("sourceId" in svc.pending), "An unusable copy is never claimed to the broker")
                                                finishTurn("done")
                                            },
                                            next: restoreOrder
                                        }, "the unopenable copy notice")
                                    }
                                }, "the copy-missing notice")
                            }
                        }, "the origin-missing notice")
                    }
                    // Several registry rows (oldest first): the newest is tried first, older rows
                    // go only after a row opened, and a damaged newest never costs the survivor.
                    function restoreOrder() {
                        var broken1 = "src-0000000500000fff", broken2 = "src-0000000600000fff"
                        var good = sid(42, 0), older = sid(41, 0)
                        function rows() {
                            return Array.prototype.slice.call(arguments).map(function(id) { return {id: id, workspaceId: "ws-n"} })
                        }
                        // newest damaged, older good: the older one is used and nothing is removed
                        restoreWith(good, rows(good, broken1), {
                            until: function() { return svc.sourceReady && svc.csvSource.sourceId === good },
                            check: function() {
                                check(svc.linkedSourceId === good && svc.sourceNotice === "",
                                    "A damaged newest copy falls back to the older one without a notice")
                                check(svc.storeQueue.length === 0, "The damaged newest and the used older row both stay untouched")
                            },
                            next: function() {
                                // newest damaged, middle good, oldest leftover: only the older-than-used row goes
                                restoreWith(good, rows(older, good, broken1), {
                                    until: function() { return svc.sourceReady && svc.csvSource.sourceId === good && svc.storeQueue.length > 0 },
                                    check: function() {
                                        check(JSON.stringify(unlinks()) === JSON.stringify([older]),
                                            "Only the row older than the opened one is removed, got " + JSON.stringify(unlinks()))
                                        check(svc.sourceNotice === "", "No notice when a copy opened")
                                    },
                                    next: function() {
                                        // none opens: every row stays and the notice shows
                                        restoreWith(broken1, rows(broken1, broken2), {
                                            until: function() { return svc.sourceNotice === "copyMissing" && svc.csvSource.status === "error" },
                                            check: function() {
                                                check(svc.storeQueue.length === 0, "When no copy opens, no row is removed")
                                                check(svc.linkedSourceId === broken2 && !svc.sourceReady,
                                                    "The newest row stays the workspace's source")
                                            },
                                            next: staleAndEmpty
                                        }, "no copy to open")
                                    }
                                }, "the older row to be cleaned after the good copy opened")
                            }
                        }, "the fallback to the older copy")
                    }
                    function staleAndEmpty() {
                        svc.storeQueue = []
                        svc.storePending = 0
                        // A late registry answer for a workspace we already left changes nothing.
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-a"}, artifacts: [], interaction: {}}, {})
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-b"}, artifacts: [], interaction: {}}, {})
                        serve("list", {ok: true, workspaces: []})
                        serve("source_list", {ok: true, totalBytes: 0, count: 1, sources: [{id: sid(20, 0), workspaceId: "ws-a"}]})
                        serve("list", {ok: true, workspaces: []})
                        serve("source_list", {ok: true, totalBytes: 0, count: 0, sources: []})
                        check(svc.linkedSourceId === "" && svc.csvSource.status === "idle" && !svc.keepPending,
                            "A superseded registry answer and an empty registry leave no source")
                        // A hint the registry no longer backs is dropped.
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-c"}, artifacts: [], interaction: {
                            csvSource: {sourceId: sid(21, 0), origin: "/scratch/u/gone.csv"}}}, {})
                        check(svc.linkedSourceId === sid(21, 0), "The hint is kept while the registry is unanswered")
                        serve("list", {ok: true, workspaces: []})
                        serve("source_list", {ok: false, error: "Fixture"})
                        check(svc.linkedSourceId === sid(21, 0), "A failed registry read keeps the hint instead of erasing it")
                        // The explorer's view state restores with the workspace: it rides the
                        // latest turn's uiStates entry under csv:<sourceId>.
                        var viewId = sid(33, 0)
                        svc.applyWorkspaceSnapshot({workspace: {id: "ws-v"}, artifacts: [], interaction: {
                            "turn:5": {id: 5, prompt: "Q", answer: "A", status: "done", blocks: []}}}, {})
                        check(svc.setCsvViewState(viewId, {sort: 3, dir: -1, filter: "porto", page: 4}),
                            "A view state is accepted once a turn exists")
                        check(svc.heldCsvView === null && svc.dirtyContent, "It rides the latest turn and marks the content dirty")
                        var snap = JSON.parse(JSON.stringify(svc.workspaceSnapshot()))
                        var back = isolated()
                        back.applyWorkspaceSnapshot({workspace: snap.workspace, artifacts: snap.artifacts,
                            interaction: snap.interaction}, {})
                        check(JSON.stringify(back.csvViewState(viewId)) === JSON.stringify(
                            {sort: 3, dir: -1, filter: "porto", page: 4}), "The explorer view state restores with the workspace")
                        check(JSON.stringify(back.csvViewState(sid(34, 0))) === "{}", "Another source starts clean")
                        check(!back.setCsvViewState(viewId, null) && !back.setCsvViewState("nope", {}),
                            "Invalid state is refused")
                        // Out-of-range values are clamped to a safe state, never stored raw.
                        back.setCsvViewState(viewId, {sort: 1000, dir: 7, filter: "x".repeat(500), page: -2})
                        var clamped = back.csvViewState(viewId)
                        check(clamped.sort === -1 && clamped.dir === 1 && clamped.filter.length === 200 && clamped.page === 0,
                            "Hostile view state is sanitised")
                        back.destroy()
                        svc.destroy()
                        finished()
                    }
                }

                function settle() {
                    if (failed) return
                    if (lazy.loadingLatest || !lazy.restoreSettled) return
                    try {
                        if (phase === 0) {
                        if (recoveredStartup.storeBusy) return
                        check(recoveredStartup.storeQueue.length === 0 && recoveredStartup.storeInFlight.length === 0
                            && !recoveredStartup.storeStopped,
                            "A save after never-start timeout must complete through a fresh stub worker")
                        recoveredStartup.destroy()
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
                            // The answer carries a form; its submission goes through the
                            // real pipe to the stub broker, which checks the closed shape.
                            lazy.receive(JSON.stringify({type: "done", turnId: lazy.turnId, answer: "Stub answer",
                                blocks: [{type: "form", title: "Pick", submitLabel: "Send", note: "", fields: [
                                    {id: "size", label: "Size", kind: "number", unit: "cm", min: 1, max: 9, step: 1, value: 3,
                                     options: [], placeholder: ""},
                                    {id: "tone", label: "Tone", kind: "choice", unit: "", min: 0, max: 0, step: 0, value: 0,
                                     options: ["Calm", "Bold"], placeholder: ""}]}], suggestions: []}))
                            check(lazy.submitForm(lazy.turnId, 0) && lazy.busy && lazy.latest.prompt === "Answers to the form on the previous answer.",
                                "A form answer is accepted by the live service")
                            phase = 31
                        } else if (phase === 31) {
                            if (lazy.busy) return
                            check(lazy.latest.status === "done" && lazy.latest.answer === "Form accepted",
                                "The stub broker accepted the exact form shape over the real pipe: "
                                + lazy.latest.status + " " + lazy.latest.error)
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
                            phase = 7
                            keepChecks(function() {
                                console.log("AiService: state, depth context, restore gates, watchdog, pruning, idle lifecycle and durable-source checks passed")
                                Qt.quit()
                            })
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
