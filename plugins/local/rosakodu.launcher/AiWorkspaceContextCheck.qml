import QtQuick
import Quickshell

// Offline protocol regression. Create a FRESH scratch HOME under /tmp/opencode,
// with .config/omarchy/defaults/agent containing codex, nested XDG_STATE_HOME,
// private XDG_RUNTIME_DIR, QT_QPA_PLATFORM=offscreen, QT_QUICK_BACKEND=software.
// Run: quickshell -p AiWorkspaceContextCheck.qml
ShellRoot {
    id: root
    property var service: null
    property var condition: null
    property var continuation: null
    property double deadline: 0
    property string originalBlocks: ""
    property string initialUi: ""
    property string editedUi: ""
    property string firstAnswer: ""
    property double lastActivity: 0
    property string stubScript: decodeURIComponent(Qt.resolvedUrl("tests/ai_context_stub.py").toString().replace(/^file:\/\//, ""))

    function check(condition, message) {
        if (!condition) throw new Error(message)
    }
    function finish(error) {
        poll.stop()
        watchdog.stop()
        if (service) { service.destroy(); service = null }
        if (error) {
            console.error("AiWorkspaceContext: " + error)
            Qt.exit(1)
        } else {
            console.log("AiWorkspaceContext: real service -> real Broker.command validation/prompt -> stub provider -> retained answer; adjusted/restored calc, older calc after prose, append-only state, explicit sends, fresh chat and once-only byte accounting passed (scratch/offscreen only)")
            Qt.quit()
        }
    }
    function until(test, done) {
        condition = test
        continuation = done
        deadline = Date.now() + 8000
        poll.restart()
    }
    function completed(done) {
        until(function() { return !service.busy }, function() {
            check(service.latest.status === "done", "Broker must finish successfully: " + service.latest.error)
            check(service.latest.answer.length < 8192, "Fixture must return short JSON, not the full system prompt")
            var result = JSON.parse(service.latest.answer)
            check(result.chargedOnce && result.chargedBytes === result.promptBytes
                && result.promptBytes === result.baseBytes + result.contextSectionBytes,
                "Actual assembled prompt and context are charged exactly once")
            check(result.session === null && result.providerHome === null && result.sourceId === null,
                "No provider session, home or source belongs to the copied workspace")
            check(result.explain === false && result.allowResume === true,
                "Normal submit's provider-run flags are unchanged")
            check(JSON.stringify(result.requestFields) === JSON.stringify(result.context
                ? ["agent", "op", "prompt", "turnId", "workspaceContext"] : ["agent", "op", "prompt", "turnId"]),
                "Context does not grant tools, attachment/source access or resume flags")
            check(service.turnModel.get(service.turnModel.count - 1).payload.answer === service.latest.answer,
                "The real retained model receives the broker's JSON answer")
            done(result)
        })
    }
    function assertCalc(reply, value, previousId) {
        var context = reply.context
        check(reply.markerCount === 1 && reply.contextSectionBytes > 0,
            "Actual assembled prompt has exactly one workspace snapshot section")
        check(context && context.version === 1 && context.previous.turnId === previousId,
            "Snapshot identifies the most recent completed answer")
        var calc = context.calc
        check(calc && calc.turnId === 3 && calc.blockIndex === 0 && !calc.unavailable && !calc.truncated,
            "The loaded native calculator keeps its own older turn identity")
        check(calc.inputs.length === 1 && calc.inputs[0].id === "weight"
            && calc.inputs[0].value === value && calc.inputs[0].adjusted
            && calc.inputs[0].basis === "assumption", "Current adjusted input and honest basis reach the broker")
        check(calc.outputs[0].id === "totalweight" && calc.outputs[0].value === value,
            "Scalar total uses the current weight, not its default of five")
        check(calc.tables[0].rows[0][0].value === "A" && calc.tables[0].rows[1][0].value === "B"
            && calc.tables[0].rows[0][2].value === 5 * value && calc.tables[0].rows[1][2].value === 2 * value,
            "Native numeric/formula table uses current locally computed scores")
        check(service.sessionId === "" && service.handoffHome === "" && service.linkedSourceId === ""
            && service.attachment === "" && service.csvSource.status === "idle",
            "Protocol regression never starts file/source/provider ownership")
        check(JSON.stringify(service.turns[0].blocks) === originalBlocks,
            "Append-only submission preserves original authored blocks")
        check(service.turns[0].id === 3 && service.turns[0].answer === "Fixture comparison"
            && service.checklistStates["3"]["0:0"] === true,
            "Append-only submission preserves earlier prose and other interaction state")
    }
    function begin() {
        try {
            var home = Quickshell.env("HOME"), state = Quickshell.env("XDG_STATE_HOME")
            check(home.indexOf("/tmp/opencode/") === 0 && home.indexOf("/../") < 0
                && state.indexOf(home + "/") === 0 && state.indexOf("/../") < 0
                && Quickshell.env("XDG_RUNTIME_DIR").indexOf("/tmp/opencode/") === 0,
                "Run only with a fresh scratch HOME/state/runtime under /tmp/opencode")
            var component = Qt.createComponent(Qt.resolvedUrl("AiService.qml"))
            check(component.status === Component.Ready, component.errorString())
            var scratchRoot = state + "/workspace-context-check"
            service = component.createObject(root, {storeEnabled: false, brokerScript: stubScript,
                storeScript: stubScript, stateRoot: scratchRoot})
            check(service && service.storeEnabled === false && service.brokerScript === stubScript
                && service.storeScript === stubScript && service.stateRoot === scratchRoot,
                "Effective service injection and disabled store must be verified before dispatch")
            until(function() { return service.defaultAgent === "codex" }, seed)
        } catch (error) { finish(error) }
    }
    function seed() {
        var calc = {type: "calc", title: "Weighted comparison", note: "Synthetic scores only.",
            inputs: [{id: "weight", label: "Weight", unit: "", min: 1, max: 10, step: 1, value: 5, basis: "assumption"}],
            cells: [{id: "totalweight", label: "Total weight", expression: "weight", unit: "", decimals: 0}],
            tables: [{id: "ratings", label: "Candidates", columns: [
                {id: "name", label: "Name", kind: "text", unit: "", expression: ""},
                {id: "score", label: "Score", kind: "number", unit: "", expression: ""},
                {id: "weighted", label: "Weighted score", kind: "formula", unit: "", expression: "score * weight"}],
                rows: [["A", "5", ""], ["B", "2", ""]]}]}
        // Hydrate through the real restoration path, with copied artifact and
        // calculator UI state but deliberately NO session, handoff or source.
        service.applyWorkspaceSnapshot({ok: true,
            workspace: {id: "ws-context-copy", agent: "codex", sessionRef: "", draft: "", attachment: ""},
            artifacts: [{id: "copied-calc", blocks: [calc]}],
            interaction: {workspaceName: "Copied tool", "turn:3": {id: 3, prompt: "Compare A and B",
                answer: "Fixture comparison", artifactId: "copied-calc", blocks: [], suggestions: [], status: "done"},
                checklists: {"3": {"0:0": true}}, uiStates: {"3": {"calc:0": {weight: {v: 8, u: ""}},
                    "table:0": {sort: 1, dir: -1, filter: "A"}}}}}, {})
        originalBlocks = JSON.stringify(service.turns[0].blocks)
        initialUi = JSON.stringify(service.uiStates)
        check(service.defaultAgent === "codex" && service.turnId === 3 && !service.brokerLive,
            "Scratch default-agent file is actually loaded and restoration does not dispatch")
        check(service.submit("Explain my current weighted scores"), "First explicit follow-up is accepted")
        completed(function(reply) {
            assertCalc(reply, 8, 3)
            check(service.turnId === 4 && service.turns.length === 2 && service.latest.blocks.length === 0,
                "The provider reply appends one prose answer")
            check(JSON.stringify(service.uiStates) === initialUi, "First submit preserves all loaded UI state")
            firstAnswer = service.latest.answer
            lastActivity = service.lastBrokerActivity
            check(service.setUiState(3, "calc:0", {weight: {v: 9, u: ""}}), "Older calculator accepts a local edit")
            editedUi = JSON.stringify(service.uiStates)
            var quietUntil = Date.now() + 200
            until(function() { return Date.now() >= quietUntil }, edited)
        })
    }
    function edited() {
        check(!service.busy && !service.stopping && service.pending === null
            && service.turnId === 4 && service.turns.length === 2 && service.lastBrokerActivity === lastActivity,
            "Local input edit alone starts no job and sends no broker command")
        check(service.latest.answer === firstAnswer && JSON.stringify(service.turns[0].blocks) === originalBlocks,
            "Local edit never rewrites either retained answer")
        check(service.submit("Explain again using my updated weight"), "Second explicit follow-up is accepted")
        completed(function(reply) {
            assertCalc(reply, 9, 4)
            check(reply.context.previous.answer === firstAnswer.slice(0, 1024),
                "The latest prose answer, not stale calculator prose, supplies previous context")
            check(JSON.stringify(service.uiStates) === editedUi, "Edits and all unrelated UI state remain intact")
            service.newConversation()
            check(service.turns.length === 0 && Object.keys(service.uiStates).length === 0
                && service.sessionId === "" && service.handoffHome === "", "New chat clears conversation ownership")
            var freshId = service.turnId + 1
            check(service.submit("Fresh question"), "Fresh question is accepted")
            completed(function(fresh) {
                check(fresh.context === null && fresh.markerCount === 0 && fresh.contextSectionBytes === 0,
                    "A fresh question has no invented workspace context")
                check(service.turns.length === 1 && service.turnId === freshId && service.latest.id === freshId,
                    "Fresh answer belongs only to the new chat, with the service's monotonic identity")
                finish(null)
            })
        })
    }
    Timer {
        id: poll
        interval: 15
        repeat: true
        onTriggered: {
            try {
                if (condition()) {
                    stop()
                    var next = continuation
                    condition = continuation = null
                    next()
                } else if (Date.now() >= deadline) {
                    finish("Timed out waiting for asynchronous default-agent/broker completion")
                }
            } catch (error) { finish(error) }
        }
    }
    Timer { id: watchdog; interval: 26000; running: true; onTriggered: root.finish("Overall check timed out") }
    Timer { interval: 1; running: true; onTriggered: root.begin() }
}
