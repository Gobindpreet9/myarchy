import QtQuick
import Quickshell

// Real AiService against the in-tree stub broker/store (tests/ai_service_stub.py):
// the dynamic-vocabulary seams (submitChoice, focusTarget, state pruning).
// Run with a scratch HOME and XDG_STATE_HOME under /tmp/opencode; it never reads
// or writes the user's state and never starts a provider. The stub's context
// validators mirror the closed shapes; ai_broker.validate_workspace_context is
// the authority.
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
            var scratchRoot = Quickshell.env("XDG_STATE_HOME") + "/ai-seams-check"
            function check(condition, message) { if (!condition) throw new Error(message) }
            function json(value) { return JSON.stringify(value) }
            try {
                check(Quickshell.env("HOME").indexOf("/tmp/opencode/") === 0
                    && Quickshell.env("XDG_STATE_HOME").indexOf("/tmp/opencode/") === 0,
                    "Run this check with scratch HOME and XDG_STATE_HOME under /tmp/opencode")
                function isolated() {
                    var created = component.createObject(parent, {storeEnabled: false,
                        storeScript: stubScript, brokerScript: stubScript, stateRoot: scratchRoot})
                    check(created.storeScript === stubScript && created.brokerScript === stubScript
                        && created.stateRoot === scratchRoot, "Every service must use isolated fixtures")
                    return created
                }
                var CHOICE = "Choice made on the previous answer."
                var actionsBlock = {type: "actions", title: "Next steps", options: [
                    {label: "Book", hint: "Now"}, {label: "Wait", hint: ""}, {label: "Skip", hint: ""}]}
                var compareBlock = {type: "compare", title: "Two laptops", options: [
                    {name: "Aero 14", summary: "Light", facts: [], pros: [], cons: [], recommended: true},
                    {name: "Forge 16", summary: "Fast", facts: [], pros: [], cons: [], recommended: false}], verdict: "Aero."}
                var timelineBlock = {type: "timeline", title: "Saturday", items: [{label: "Pack", when: "08:00", minutes: 30, detail: ""}]}
                function fixture(blocks) {
                    var f = isolated()
                    f.agent = "codex"
                    f.defaultAgent = "codex"
                    f.turnId = 5
                    f.turns = [{id: 4, prompt: "Hi", answer: "Hello", status: "done", blocks: [], suggestions: []},
                        {id: 5, prompt: "Plan a trip", answer: "Pick one.", status: "done",
                         blocks: blocks || [{type: "text", text: "Intro"}, actionsBlock, compareBlock, timelineBlock], suggestions: []}]
                    f.turnModel.append({payload: f.turns[0]})
                    f.turnModel.append({payload: f.turns[1]})
                    return f
                }
                function done(f) { f.busy = false; f.destroy() }
                function frozen(f) { return json([f.turns, f.uiStates, f.turnId, f.turnModel.count, f.focusTarget]) }

                // ---- submitChoice: exact prompt, context, visible text, state ----
                var a = fixture()
                a.draft = "typed draft"
                a.attachment = ""
                check(a.submitChoice(5, 1, "actions", 2), "A valid pick is accepted")
                var request = a.pending
                check(request && request.op === "submit" && request.prompt === CHOICE && request.turnId === 6
                    && request.attachment === undefined, "The prompt is the fixed sentence, with no attachment")
                check(json(request.workspaceContext.choice) === json({turnId: 5, blockIndex: 1, kind: "actions", index: 2,
                        title: "Next steps", label: "Skip"}), "workspaceContext.choice has the exact shape: " + json(request.workspaceContext.choice))
                check(Object.keys(request.workspaceContext).sort().join() === "choice,previous,truncated,version"
                    && request.workspaceContext.previous.turnId === 5, "The choice rides beside the ordinary snapshot")
                check(a.latest.id === 6 && a.latest.prompt === CHOICE && a.latest.status === "working" && a.latest.attachment === ""
                    && a.latest.choiceText === "Picked: Skip" && json(a.latest.choiceRef) === json({turnId: 5, blockIndex: 1, kind: "actions", index: 2})
                    && a.latest.formRef === undefined && a.latest.formAnswers === undefined && a.turnModel.count === 3
                    && a.turnModel.get(2).payload.choiceText === "Picked: Skip", "A visible turn says what was picked")
                check(json(a.uiStates["5"]["act:1"]) === json({picked: 2}), "The pick is stored: " + json(a.uiStates))
                check(a.draft === "typed draft" && a.attachment === "", "A pick leaves the composer alone")
                check(a.busy && a.focusTarget === null, "Working")
                check(!a.submitChoice(5, 1, "actions", 0) && !a.submitChoice(5, 1, "actions", 2) && a.turns.length === 3
                    && a.uiStates["5"]["act:1"].picked === 2, "A double submit is impossible while the answer is working")
                var snapshot = JSON.parse(json(a.workspaceSnapshot()))
                check(snapshot.interaction["turn:6"].choiceText === "Picked: Skip" && snapshot.interaction["turn:6"].choiceRef.index === 2
                    && !("choiceRef" in snapshot.interaction["turn:5"]) && !("choiceText" in snapshot.interaction["turn:4"])
                    && snapshot.interaction.uiStates["5"]["act:1"].picked === 2, "The snapshot carries the pick and its link")
                var restored = isolated()
                restored.applyWorkspaceSnapshot({workspace: snapshot.workspace, artifacts: snapshot.artifacts,
                    interaction: snapshot.interaction}, {})
                check(restored.turns.length === 3 && restored.latest.choiceText === "Picked: Skip"
                    && restored.latest.choiceRef.blockIndex === 1 && restored.uiStates["5"]["act:1"].picked === 2
                    && restored.latest.status === "error", "A restart restores the pick, its link and an interrupted turn")
                check(restored.submitChoice(5, 1, "actions", 0) && restored.latest.id === 7,
                    "An interrupted pick can be made again (a failed answer re-opens the options)")
                done(restored)
                done(a)

                // A compare option is labelled by its NAME.
                var cmp = fixture()
                check(cmp.submitChoice(5, 2, "compare", 1) && json(cmp.pending.workspaceContext.choice)
                    === json({turnId: 5, blockIndex: 2, kind: "compare", index: 1, title: "Two laptops", label: "Forge 16"})
                    && cmp.latest.choiceText === "Picked: Forge 16", "A compare pick")
                done(cmp)

                // ---- hostile labels are cleaned and clamped from the persisted block ----
                var BEL = String.fromCharCode(7), RLO = String.fromCharCode(0x202e), ZWSP = String.fromCharCode(0x200b)
                var evil = fixture([{type: "actions", title: "T" + BEL + "\n" + "t".repeat(400), options: [
                    {label: RLO + "Go" + BEL + ZWSP + "\n" + "x".repeat(100), hint: ""}, {label: BEL + ZWSP, hint: "unlabelled"}]}])
                check(evil.submitChoice(5, 0, "actions", 0), "A hostile label is cleaned, not refused")
                var evilWire = evil.pending.workspaceContext.choice
                var evilJson = json(evilWire)
                check(evilWire.title.length === 160 && evilWire.label.length === 40 && evilWire.label.indexOf("Go ") === 0
                    && evilJson.indexOf(BEL) < 0 && evilJson.indexOf(RLO) < 0 && evilJson.indexOf(ZWSP) < 0
                    && evilJson.indexOf("\\n") < 0 && evilJson.indexOf("\\u0007") < 0
                    && evil.latest.choiceText.length === "Picked: ".length + 40, "Clean single lines within bounds: " + evilJson)
                done(evil)
                var blank = fixture([{type: "actions", title: "T", options: [{label: BEL + ZWSP, hint: ""}]}])
                var blankBefore = frozen(blank)
                check(!blank.submitChoice(5, 0, "actions", 0) && blank.pending === null && frozen(blank) === blankBefore,
                    "An option with no readable label cannot be picked")
                done(blank)

                // ---- refusals change nothing ----
                var refusals = [[5, 1, "actions", 3], [5, 1, "actions", -1], [5, 1, "actions", 1.5], [5, 1, "actions", "1"],
                    [5, 1, "actions", 16], [5, 0, "actions", 0], [5, 6, "actions", 0], [5, -1, "actions", 0],
                    [5, 1, "compare", 0], [5, 1, "timeline", 0], [5, 3, "timeline", 0], [5, 3, "actions", 0],
                    [5, 1, "form", 0], [5, 1, "", 0], [5, 1, null, 0], [5, 1, undefined, 0], [4, 1, "actions", 0],
                    [999, 1, "actions", 0], ["5", 1, "actions", 0], [5.5, 1, "actions", 0], [null, 1, "actions", 0],
                    [5, 1, "actions"], [5, 1], [5]]
                var refusing = fixture()
                var refusingBefore = frozen(refusing)
                for (var r = 0; r < refusals.length; ++r)
                    check(!refusing.submitChoice.apply(refusing, refusals[r]) && refusing.pending === null
                        && frozen(refusing) === refusingBefore, "submitChoice must refuse " + json(refusals[r]))
                check(!refusing.submitChoice() && refusing.pending === null && frozen(refusing) === refusingBefore, "no arguments")
                done(refusing)
                var hostileBlock = fixture([{type: "actions", options: 7}, {type: "actions", options: [null]},
                    {type: "actions", options: [{label: {x: 1}}]}])
                for (var h = 0; h < 3; ++h)
                    check(!hostileBlock.submitChoice(5, h, "actions", 0) && hostileBlock.pending === null, "hostile block " + h)
                done(hostileBlock)

                // ---- gates: nothing is appended, sent or stored while one is closed ----
                function gate(label, setup, undo) {
                    var g = fixture()
                    setup(g)
                    var before = frozen(g)
                    check(!g.submitChoice(5, 1, "actions", 0) && g.pending === null && frozen(g) === before,
                        "submitChoice must refuse while " + label)
                    if (undo) {
                        undo(g)
                        check(g.submitChoice(5, 1, "actions", 0), "submitChoice works again after " + label)
                    }
                    done(g)
                }
                gate("busy", function(g) { g.busy = true }, function(g) { g.busy = false })
                gate("stopping", function(g) { g.stopping = true }, function(g) { g.stopping = false })
                gate("loading the latest workspace", function(g) { g.loadingLatest = true }, function(g) { g.loadingLatest = false })
                gate("a workspace action is pending", function(g) {
                    g.storeStarting = true
                    g.storeEnabled = true
                    g.restoreSettled = true
                    g.workspaceId = "ws-named"
                    check(g.renameWorkspace("Named"), "the fixture enters a workspace action")
                }, function(g) { g.failWorkspaceAction(); g.storeQueue = [] })
                gate("a workspace transition is pending", function(g) {
                    g.workspaceAction = {op: "duplicate", phase: "loading", destination: "ws-x"}
                }, function(g) { g.workspaceAction = null })
                gate("the turn is no longer the latest", function(g) {
                    g.turns = g.turns.concat([{id: 6, prompt: "Later", answer: "B", status: "done", blocks: [], suggestions: []}])
                }, null)
                gate("the turn is still working", function(g) {
                    g.turns = [g.turns[0], Object.assign({}, g.turns[1], {status: "working"})]
                }, null)
                gate("there is no agent", function(g) { g.agent = ""; g.defaultAgent = "" }, null)
                gate("the turn is unknown", function(g) { g.turns = [g.turns[0]] }, null)
                gate("the options already have a pick", function(g) { g.setUiState(5, "act:1", {picked: 0}) }, null)

                // ---- a failed answer re-opens the options; an answered pick closes them ----
                var retry = fixture()
                check(retry.submitChoice(5, 1, "actions", 1), "first pick")
                retry.receive(json({type: "error", turnId: retry.turnId, message: "Codex could not complete the answer."}))
                check(!retry.busy && retry.latest.status === "error" && retry.latest.choiceRef.turnId === 5,
                    "The failed answer stays a picked-option turn")
                check(retry.submitChoice(5, 1, "actions", 2) && retry.turns.length === 4 && retry.latest.id === 7
                    && retry.pending.workspaceContext.choice.index === 2 && retry.pending.workspaceContext.choice.label === "Skip"
                    && json(retry.uiStates["5"]["act:1"]) === json({picked: 2}), "A re-pick is a NEW turn and replaces the stored pick")
                retry.receive(json({type: "done", turnId: retry.turnId, answer: "Booked", blocks: [], suggestions: []}))
                check(!retry.submitChoice(5, 1, "actions", 0) && retry.turns.length === 4 && !retry.submitChoice(5, 2, "compare", 0),
                    "Once answered, that turn's options are closed")
                done(retry)
                // A failed FORM answer does not re-open a pick (and the form gate is unchanged).
                var crossed = fixture()
                crossed.turns = crossed.turns.concat([{id: 6, prompt: "Answers to the form on the previous answer.", answer: "",
                    status: "error", error: "Boom", blocks: [], suggestions: [], formRef: {turnId: 5, blockIndex: 0}, formAnswers: []}])
                check(!crossed.submitChoice(5, 1, "actions", 0), "A failed form answer does not re-open a pick")
                done(crossed)

                // ---- size guard: the pick mark must fit the 200 KiB map before anything is sent ----
                var full = fixture()
                full.setUiState(4, "calc:0", {pad: ""})
                var baseBytes = full.uiStatesBytes(full.uiStates)
                check(full.setUiState(4, "calc:0", {pad: "z".repeat(200 * 1024 - 5 - baseBytes)}), "the fixture fills the map to within 5 bytes")
                var fullBefore = frozen(full)
                check(!full.submitChoice(5, 1, "actions", 0) && full.stateNotice === "Too many saved edits to keep this change."
                    && full.pending === null && frozen(full) === fullBefore, "A pick whose mark cannot be stored is refused whole, with the notice")
                full.setUiState(4, "calc:0", {})
                check(full.submitChoice(5, 1, "actions", 0) && full.stateNotice === "", "Making room lets the same pick go")
                done(full)

                // ---- focus: attach on the next typed submit, then clear ----
                var focus = {turnId: 5, blockIndex: 1, kind: "actions", index: 1, label: "FocusOnly", detail: "Why this one"}
                var b = fixture()
                check(b.focusTarget === null && b.focusLabel === "", "No focus at start")
                check(b.setFocus(focus) && b.focusLabel === "FocusOnly" && b.focusTarget.index === 1, "A real part of the latest answer")
                check(json(b.workspaceSnapshot()).indexOf("FocusOnly") < 0 && json(b.savePayload()).indexOf("FocusOnly") < 0,
                    "Focus is never persisted")
                b.draft = "Why wait?"
                check(b.submit("Why wait?") && json(b.pending.workspaceContext.focus) === json({turnId: 5, blockIndex: 1,
                        kind: "actions", index: 1, label: "FocusOnly", detail: "Why this one"})
                    && Object.keys(b.pending.workspaceContext).sort().join() === "focus,previous,truncated,version"
                    && b.pending.prompt === "Why wait?", "The typed submit attaches the focus: " + json(b.pending.workspaceContext))
                check(b.focusTarget === null && b.focusLabel === "", "...and clears it")
                b.busy = false
                check(b.submit("And then?") && b.pending.workspaceContext.focus === undefined, "The next question carries no focus")
                done(b)

                // What can be focused: only a real block of the latest FINISHED answer.
                var c = fixture()
                var focusBefore = frozen(c)
                var badFocus = [Object.assign({}, focus, {kind: "compare"}), Object.assign({}, focus, {turnId: 4}),
                    Object.assign({}, focus, {turnId: 99}), Object.assign({}, focus, {blockIndex: 9}),
                    Object.assign({}, focus, {blockIndex: 0}), Object.assign({}, focus, {kind: "form"}),
                    Object.assign({}, focus, {label: "  "}), Object.assign({}, focus, {index: 64}),
                    Object.assign({}, focus, {index: -2}), null, 5, "x", [], {}]
                for (var k = 0; k < badFocus.length; ++k)
                    check(!c.setFocus(badFocus[k]) && frozen(c) === focusBefore, "setFocus must refuse " + k)
                check(c.setFocus(Object.assign({}, focus, {index: -1, kind: "timeline", blockIndex: 3, label: "Saturday", detail: ""})),
                    "The whole block (index -1)")
                check(c.setFocus(Object.assign({}, focus, {label: BEL + "L".repeat(200), detail: "D".repeat(500)}))
                    && c.focusTarget.label.length === 80 && c.focusTarget.detail.length === 240
                    && c.focusTarget.label.indexOf(BEL) < 0, "Label and detail are cleaned and clamped")
                c.clearFocus()
                c.clearFocus()
                check(c.focusTarget === null, "clearFocus is idempotent")
                c.busy = true
                check(!c.setFocus(focus), "Not while an answer is working")
                c.busy = false
                c.turns = [c.turns[0], Object.assign({}, c.turns[1], {status: "working"})]
                check(!c.setFocus(focus), "Not on an unfinished answer")
                done(c)

                // Every turn that starts consumes it; form/choice never carry it.
                var tripForm = {type: "form", title: "Trip", submitLabel: "Send", note: "", fields: [
                    {id: "budget", label: "Budget", kind: "number", unit: "EUR", min: 0, max: 5000, step: 50, value: 1000,
                     options: [], placeholder: ""}]}
                var d = fixture([tripForm, actionsBlock])
                check(d.setFocus(Object.assign({}, focus, {blockIndex: 1})), "focus before a form send")
                check(d.submitForm(5, 0) && d.pending.workspaceContext.focus === undefined && d.pending.workspaceContext.form !== undefined
                    && d.focusTarget === null, "A form send carries no focus and consumes it")
                done(d)
                var e = fixture()
                check(e.setFocus(focus) && e.submitChoice(5, 1, "actions", 0) && e.pending.workspaceContext.focus === undefined
                    && e.pending.workspaceContext.choice !== undefined && e.focusTarget === null,
                    "A pick carries no focus and consumes it")
                done(e)
                // A focus about an older answer is dropped, not sent.
                var stale = fixture()
                check(stale.setFocus(focus), "focus on the latest answer")
                stale.turns = stale.turns.concat([{id: 6, prompt: "Later", answer: "B", status: "done", blocks: [], suggestions: []}])
                stale.turnId = 6
                check(stale.submit("Next?") && stale.pending.workspaceContext.focus === undefined && stale.focusTarget === null,
                    "A focus about another answer is never attached")
                done(stale)
                // New chat, a restore and a workspace switch clear it.
                var f1 = fixture()
                check(f1.setFocus(focus), "focus")
                f1.newConversation()
                check(f1.focusTarget === null && f1.focusLabel === "", "New chat clears the focus")
                done(f1)
                var f2 = fixture()
                check(f2.setFocus(focus), "focus")
                f2.applyWorkspaceSnapshot({workspace: {id: "ws-other", agent: "codex"}, artifacts: [], interaction: {}}, {})
                check(f2.focusTarget === null, "A restore / workspace switch clears the focus")
                done(f2)
                // An unsupported agent still consumes it (the turn was started).
                var f3 = fixture()
                check(f3.setFocus(focus), "focus")
                f3.defaultAgent = ""
                f3.agent = ""
                f3.submit("Why?")
                check(f3.focusTarget === null && f3.latest.status === "error", "A refused-agent turn consumed the focus")
                done(f3)

                // ---- pruning: a final answer drops dead vocabulary keys ----
                var p = fixture()
                p.turnId = 6
                p.turns = p.turns.concat([{id: 6, prompt: "Again", answer: "", status: "working", blocks: [], suggestions: []}])
                p.turnModel.append({payload: p.turns[2]})
                p.setUiState(6, "act:0", {picked: 1})
                p.setUiState(6, "act:1", {picked: 0})
                p.setUiState(6, "compare:1", {open: [0]})
                p.setUiState(6, "plan:2", {done: [0]})
                p.setUiState(6, "plan:3", {done: [0]})
                p.setUiState(6, "csv:x", {a: 1})
                p.busy = true
                p.receive(json({type: "done", turnId: 6, answer: "Final", suggestions: [],
                    blocks: [{type: "actions", title: "A", options: [{label: "x", hint: ""}]}, {type: "text", text: "now text"},
                             {type: "timeline", title: "T", items: [{label: "x", when: "", minutes: 0, detail: ""}]}]}))
                check(json(Object.keys(p.uiStates["6"]).sort()) === json(["act:0", "csv:x", "plan:2"]),
                    "Only keys on a block of their own type stay: " + json(Object.keys(p.uiStates["6"])))
                done(p)

                // ---- the stub broker accepts the new contexts end to end (async) ----
                var failed = null, finished = false
                function until(condition, next, label, owner) {
                    var started = Date.now()
                    var timer = Qt.createQmlObject("import QtQuick; Timer { interval: 20; repeat: true }", owner)
                    timer.triggered.connect(function() {
                        try {
                            if (condition()) { timer.stop(); timer.destroy(); next() }
                            else if (Date.now() - started > 4000) throw new Error("Timed out waiting for " + label)
                        } catch (error) { failed = error.message; console.error(error.message); Qt.exit(1) }
                    })
                    timer.start()
                }
                var rtChoice = fixture()
                check(rtChoice.submitChoice(5, 1, "actions", 2), "round trip: pick")
                until(function() { return !rtChoice.busy }, function() {
                    check(rtChoice.latest.status === "done" && rtChoice.latest.answer === "Choice accepted",
                        "The stub accepted the choice context: " + json(rtChoice.latest))
                    var rtFocus = fixture()
                    check(rtFocus.setFocus(focus), "round trip: focus")
                    check(rtFocus.submit("Why wait?"), "round trip: typed question")
                    until(function() { return !rtFocus.busy }, function() {
                        check(rtFocus.latest.status === "done" && rtFocus.latest.answer === "Focus accepted",
                            "The stub accepted the focus context: " + json(rtFocus.latest))
                        finished = true
                        console.log("AiSeams: submitChoice, focus attach/clear, gates, pruning and the stub round trip passed")
                        Qt.quit()
                    }, "the focus answer", rtFocus)
                }, "the choice answer", rtChoice)
                var watchdog = Qt.createQmlObject("import QtQuick; Timer { interval: 12000 }", rtChoice)
                watchdog.triggered.connect(function() {
                    if (failed || finished) return
                    console.error("The seams checks never settled")
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
