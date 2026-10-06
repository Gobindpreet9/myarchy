import QtQuick
import Quickshell
import Quickshell.Io
import "AiState.js" as AiState

// The host retains this service independently of the on-demand launcher panel.
Item {
    id: service
    property var shell: null
    property var manifest: null
    property string omarchyPath: ""
    property string defaultAgent: ""
    property string agent: ""
    property string sessionId: ""
    property string handoffHome: ""
    property string stateRoot: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/launcher-ai"
    readonly property bool canContinue: !busy && AiState.handoffCommand(agent, sessionId, handoffHome, stateRoot).length > 0
    property var turns: []
    property alias turnModel: conversationModel
    property var checklistStates: ({})
    // Per-turn interaction state: step indexes, check selections, predictions.
    property var uiStates: ({})
    readonly property var latest: turns.length ? turns[turns.length - 1] : null
    property bool busy: false
    property bool stopping: false
    property string activity: ""
    property bool resumeOnOpen: false
    property string draft: ""
    property string attachment: ""
    property int turnId: 0
    property var pending: null
    property bool brokerStarted: false
    property bool brokerRetiring: false
    // Visibility of the AI surfaces driving broker warmth: the launcher panel
    // and the detached window both raise it; hide/close lets the broker idle
    // out and exit, since the persisted session hint resumes it on demand.
    property bool panelActive: false
    property bool windowActive: false
    property real lastBrokerActivity: 0
    // Phase 1 persistence: one workspace id per conversation. The store keeps
    // transcript turns, checklist state, draft, attachment and the session
    // reference across restarts. Offscreen checks opt out via storeEnabled.
    property bool storeEnabled: true
    property string workspaceId: ""
    property var storeQueue: []
    // Each store op is a job {op, payload, token}; the token scopes responses
    // so a stale queued load can never apply over a newer request. Results are
    // matched to jobs by the order the worker answers them.
    property int storeToken: 0
    property int loadToken: 0
    property bool pruneQueued: false
    // True between a worker exit and its next on-demand start; the supervisor
    // never reuses a dead interpreter.
    property bool storeStopped: false
    // Lazy restore: boot and discovery use metadata only; the latest workspace
    // is loaded once, on real AI entry. Editing while that load is in flight
    // is user-owned state that the completed snapshot must preserve.
    property bool loadingLatest: false
    property bool restoreSettled: false
    property bool draftTouched: false
    property int draftRevision: 0
    // Each accepted store op counts until its process exits; Quickshell's
    // `running` does not read back true synchronously after assignment.
    property int storePending: 0
    signal workspaceRestored()
    // External view of store activity (the check and panels must not reach ids).
    readonly property bool storeBusy: storePending > 0
    // Internal dependency injection for deterministic checks. Model output and
    // plugin settings never choose these paths.
    property string storeScript: decodeURIComponent(Qt.resolvedUrl("ai_workspace_store.py").toString().replace(/^file:\/\//, ""))
    property string brokerScript: decodeURIComponent(Qt.resolvedUrl("ai_broker.py").toString().replace(/^file:\/\//, ""))

    function ensureWorkspaceId() {
        if (workspaceId) return workspaceId
        workspaceId = "ws-" + Math.random().toString(16).slice(2, 10)
            + Math.random().toString(16).slice(2, 10)
        return workspaceId
    }

    function artifactIdFor(turnId) {
        // Workspace-scoped so two workspaces never collide on the same turn id.
        return "af-" + workspaceId.slice(3) + "-t" + turnId
    }

    function workspaceSnapshot() {
        var interaction = {}
        var artifacts = []
        for (var i = 0; i < turns.length; ++i) {
            var turn = turns[i]
            var artifactId = artifactIdFor(turn.id)
            // Presentation (blocks) lives in artifacts; the transcript keeps
            // text, status and local UI state only. The store records a
            // revision whenever the blocks actually change.
            interaction["turn:" + turn.id] = {id: turn.id, prompt: turn.prompt,
                attachment: turn.attachment, answer: turn.answer, artifactId: artifactId,
                suggestions: turn.suggestions, warning: turn.warning,
                error: turn.error, status: turn.status,
                explanation: turn.explanation || ""}
            if (turn.blocks && turn.blocks.length > 0) {
                artifacts.push({id: artifactId, kind: "answer", presentationVersion: 1,
                    blocks: turn.blocks, reason: "answer", prompt: turn.prompt})
            }
        }
        if (Object.keys(checklistStates).length) interaction.checklists = checklistStates
        if (Object.keys(uiStates).length) interaction.uiStates = uiStates
        if (handoffHome) interaction.handoffHome = handoffHome
        return {
            workspace: {id: workspaceId, title: latest ? AiState.answerTitle(latest) : "",
                summary: latest ? String(latest.answer || "").slice(0, 200) : "",
                agent: agent, sessionRef: sessionId, draft: draft, attachment: attachment},
            artifacts: artifacts,
            interaction: interaction,
            authoritativeContent: true
        }
    }

    // Coalesced dirty-field saves: the workspace row fields are small and
    // travel on every save; the full artifacts/interaction serialization is
    // sent only when conversation content actually changed (turns, checklists,
    // learning state). The store upserts only what it receives, so a partial
    // save cannot clear stored content.
    property bool dirtyContent: false
    function savePayload() {
        var workspace = {
            id: workspaceId,
            title: latest ? AiState.answerTitle(latest) : "",
            summary: latest ? String(latest.answer || "").slice(0, 200) : "",
            agent: agent, sessionRef: sessionId, draft: draft, attachment: attachment
        }
        if (!dirtyContent) return {workspace: workspace, artifacts: [], interaction: {}}
        dirtyContent = false
        return {workspace: workspace, artifacts: workspaceSnapshot().artifacts,
                interaction: workspaceSnapshot().interaction, authoritativeContent: true}
    }

    function queueSave() {
        if (!storeEnabled || !workspaceId) return
        // Never write over the on-disk workspace while a load that will fully
        // replace this state is pending. The load completion re-queues after
        // apply only if the snapshot actually diverged.
        if (loadingLatest || !restoreSettled) return
        saveDebounce.restart()
    }

    function storeRun(op, payload, carryState) {
        var job = {op: op, payload: JSON.stringify(payload || {}), token: ++storeToken, carryState: carryState || null}
        if (op === "load") {
            job.loadToken = ++loadToken
            job.carryState = Object.assign({draftRevision: draftRevision}, carryState || {})
            saveDebounce.stop()
            loadingLatest = true
            loadWatchdog.restart()
            restoreSettled = false
            // A warm broker owns its previous provider session and ignores
            // resume hints. Retire it before switching to restored state.
            pending = null
            startupTimer.stop()
            brokerStarted = false
            if (broker.running) {
                brokerRetiring = true
                broker.running = false
            }
            sessionId = ""
            handoffHome = ""
        }
        storePending++
        storeQueue.push(job)
        lastStoreWork = Date.now()
        startDrain()
    }

    // The demand-started worker serves the queue over one connection; a
    // burst of edits coalesces inside the worker instead of spawning one
    // Python interpreter per operation.
    property var storeInFlight: []
    property bool storeStarting: false
    function startDrain() {
        if (!storeQueue.length || storeStarting) return
        if (!storeProc.running) {
            storeStopped = false
            // The channel must never be flipped after it is first configured:
            // re-setting stdinEnabled re-opens/re-closes the pipe and sends
            // EOF into a worker that is expected to persist across a burst.
            if (!storeProc.command.length)
                storeProc.command = ["python3", "-u", storeScript, "--root", stateRoot, "--serve"]
            storeStarting = true
            storeProc.running = true
            return
        }
        // The worker is already running (idle between results): write the
        // queued requests now — waiting for the next response would strand
        // them if no request is currently in flight.
        sendJobs()
    }

    // Writes the pending request lines; the worker answers them strictly in
    // the same order, so live results are matched to jobs by sequence.
    function sendJobs() {
        while (storeQueue.length) {
            var job = storeQueue.shift()
            storeProc.write("{\"op\":\"" + job.op + "\",\"payload\":" + job.payload + "}\n")
            storeInFlight.push(job)
        }
    }

    function dispatch(line) {
        service.storeStallTick = 0
        var result
        try { result = JSON.parse(line) } catch (error) {
            console.warn("Workspace store got unparseable output: " + String(line).slice(0, 120))
            return
        }
        var job = storeInFlight.length ? storeInFlight.shift() : null
        if (!job) {
            console.warn("Workspace store result with no matching request")
            return
        }
        storePending = Math.max(0, storePending - 1)
        lastStoreWork = Date.now()
        if (job.op === "load" && !pruneQueued) {
            pruneQueued = true
            storeRun("prune", {})
        }
        if (job.op === "load" && job.loadToken !== loadToken) {
            console.warn("Workspace store ignored a superseded load response")
            if (storeQueue.length) startDrain()
            return
        }
        if (job.op === "load") {
            loadWatchdog.stop()
            loadingLatest = false
            restoreSettled = true
        }
        if (!result || typeof result !== "object" || result.ok !== true) {
            console.warn("Workspace store " + job.op + " failed: " + JSON.stringify(result).slice(0, 160))
            if (storeQueue.length) startDrain()
            return
        }
        var op = job.op
        if (op === "load" && result.workspace) {
            applyWorkspaceSnapshot(result, job.carryState || {})
            // The load may merge the user's typed draft or attachment back over
            // the stored snapshot; persist the settled state through the same
            // debounce so the merged user text survives the next reopen.
            saveDebounce.restart()
            if (storeQueue.length) startDrain()
            return
        }
        if (op === "list") workspaceIndex = Array.isArray(result.workspaces) ? result.workspaces : []
        // The worker is ready for the next request; drain anything queued
        // while it was busy (the write pipe stays open across the burst).
        if (storeQueue.length) startDrain()
    }

    function applyWorkspaceSnapshot(result, carryState) {
        var carry = carryState || {}
        var carryDraft = String(carry.draft || "")
        var carryAttachment = String(carry.attachment || "")
        // The carry snapshot owns entry-time user text. If the live draft has
        // moved since the capture, the user kept typing while the load was in
        // flight: that newer text wins, never a stale capture.
        var liveDraft = String(service.draft || "")
        var liveAttachment = String(service.attachment || "")
        // The carry flag records *editing intent*. An intentional entry into AI
        // mode alone is not text: an empty live draft still deserves the stored
        // draft, because the flag was set programmatically before any keystroke.
        var draftEditedDuringLoad = typeof carry.draftRevision === "number"
            ? draftRevision !== carry.draftRevision : carry.draftTouched && liveDraft !== carryDraft
        var attachmentEditedDuringLoad = carry.attachmentEdited && liveAttachment !== carryAttachment
        workspaceId = String(result.workspace.id)
        agent = String(result.workspace.agent || "")
        sessionId = String(result.workspace.sessionRef || "")
        draft = draftEditedDuringLoad ? liveDraft : carry.draftTouched ? carryDraft
            : String(result.workspace.draft || "")
        attachment = carry.attachmentEdited ? (attachmentEditedDuringLoad ? liveAttachment : carryAttachment)
            : String(result.workspace.attachment || "")
        var interaction = result.interaction || {}
        // Blocks are canonical in artifacts; transcripts saved before the
        // artifact split still carry their blocks inline as a fallback.
        var artifactBlocks = {}
        ;(result.artifacts || []).forEach(function(artifact) {
            if (artifact && artifact.id) artifactBlocks[String(artifact.id)] =
                Array.isArray(artifact.blocks) ? artifact.blocks : []
        })
        handoffHome = String(interaction.handoffHome || "")
        var restored = [], ids = []
        Object.keys(interaction).forEach(function(key) {
            if (key.indexOf("turn:") === 0) {
                var id = Number(key.slice(5))
                if (isFinite(id)) { ids.push(id); restored.push(interaction[key]) }
            }
        })
        restored.sort(function(a, b) { return Number(a.id) - Number(b.id) })
        // Older upsert-only saves could accumulate discarded turns. Enforce
        // the same window on hydration before the next authoritative save.
        restored = restored.slice(-20)
        ids = restored.map(function(turn) { return Number(turn.id) })
        var fixed = restored.map(function(turn) {
            var artifactId = String(turn.artifactId || "")
            var blocks = Object.prototype.hasOwnProperty.call(artifactBlocks, artifactId)
                ? artifactBlocks[artifactId]
                : (Array.isArray(turn.blocks) ? turn.blocks : [])
            var withBlocks = Object.assign({}, turn, {blocks: blocks})
            if (withBlocks.status !== "working") return withBlocks
            // Unfinished work at restart is interrupted, never an eternal spinner.
            return Object.assign({}, withBlocks, {status: "error",
                error: "Response was interrupted by a shell restart. Try again."})
        })
        checklistStates = interaction.checklists && typeof interaction.checklists === "object"
            ? interaction.checklists : {}
        uiStates = interaction.uiStates && typeof interaction.uiStates === "object"
            ? interaction.uiStates : {}
        // Drop state belonging to turns that are not in this workspace (older
        // builds could write a global map across conversations).
        var cleanChecklists = {}, cleanUi = {}
        ids.forEach(function(id) {
            if (checklistStates[String(id)]) cleanChecklists[String(id)] = checklistStates[String(id)]
            if (uiStates[String(id)]) cleanUi[String(id)] = uiStates[String(id)]
        })
        checklistStates = cleanChecklists
        uiStates = cleanUi
        turnId = ids.length ? Math.max.apply(null, ids) : 0
        turns = fixed
        conversationModel.clear()
        fixed.forEach(function(turn) { conversationModel.append({payload: turn}) })
        resumeOnOpen = fixed.length > 0 || draft.length > 0
        restoreSettled = true
        service.workspaceRestored()
        refreshWorkspaceIndex()
    }

    function restoreWorkspace(carryState) {
        if (!storeEnabled || busy || stopping || loadingLatest) return
        storeRun("load", {latest: true}, carryState || null)
    }

    // Lazy latest: boot and discovery stay metadata-only; a real AI entry
    // triggers exactly one automatic load, with all redundant opens no-ops.
    function requestLatest() {
        if (!storeEnabled || busy || stopping || loadingLatest || restoreSettled || latestRequested) return
        latestRequested = true
        var carry = {draft: String(draft || ""), attachment: String(attachment || ""),
            draftTouched: draftTouched, attachmentEdited: attachment.length > 0}
        restoreWorkspace(carry)
    }
    property bool latestRequested: false

    // Saved-workspace index for launcher search. Cached after each list op.
    property var workspaceIndex: []
    function refreshWorkspaceIndex() {
        if (!storeEnabled) return
        storeRun("list", {limit: 40})
    }

    function resumeWorkspace(id, carryState) {
        if (!storeEnabled || !id || busy || stopping || loadingLatest) return false
        if (workspaceId && restoreSettled) {
            // Loading stops the outgoing debounce. Commit that conversation
            // before clearing its provider session and applying the target.
            saveDebounce.stop()
            storeRun("save", workspaceSnapshot())
        }
        latestRequested = true
        storeRun("load", {workspaceId: String(id)}, carryState || null)
        return true
    }

    ListModel { id: conversationModel; dynamicRoles: true }

    onTurnsChanged: { dirtyContent = true; queueSave() }
    onChecklistStatesChanged: { dirtyContent = true; queueSave() }
    onUiStatesChanged: { dirtyContent = true; queueSave() }
    onDraftChanged: { ++draftRevision; queueSave() }
    onAttachmentChanged: queueSave()
    onAgentChanged: queueSave()
    onLoadingLatestChanged: {
        if (loadingLatest) loadWatchdog.start()
        else loadWatchdog.stop()
    }

    Timer {
        id: saveDebounce
        interval: 800
        onTriggered: if (service.workspaceId) service.storeRun("save", service.savePayload())
    }

    function send(message) {
        lastBrokerActivity = Date.now()
        broker.write(JSON.stringify(message) + "\n")
    }

    function copyAnswer() { Quickshell.clipboardText = AiState.textAnswer(latest) }

    function openSource(url) {
        var command = AiState.sourceCommand(url)
        if (!command.length) return false
        Quickshell.execDetached(command)
        return true
    }

    function setChecklist(id, block, item, checked) {
        var all = Object.assign({}, checklistStates)
        var state = Object.assign({}, all[String(id)] || {})
        state[block + ":" + item] = checked
        all[String(id)] = state
        checklistStates = all
    }

    function setUiState(id, key, value) {
        var all = Object.assign({}, uiStates)
        var turnMap = Object.assign({}, all[String(id)] || {})
        turnMap[String(key)] = value
        all[String(id)] = turnMap
        uiStates = all
    }

    function submit(prompt) {
        var text = String(prompt || "").trim()
        if (!text || busy || stopping || loadingLatest) return false
        if (text.length > 8000) return false
        var chosen = AiState.supported(agent) ? agent : defaultAgent
        if (AiState.supported(chosen)) agent = chosen
        var turn = AiState.newTurn(text, attachment)
        turn.id = turnId + 1
        turns = turns.concat([turn]).slice(-20)
        conversationModel.append({payload: turn})
        if (conversationModel.count > 20) conversationModel.remove(0)
        attachment = ""
        draft = ""
        resumeOnOpen = true
        turnId++
        if (!AiState.supported(chosen)) {
            replaceLatest({type: "error", message: chosen ? "The launcher supports Codex and Hermes for now. Your default is " + chosen + "."
                : "Choose an AI agent in Omarchy first: omarchy default agent codex"})
            return false
        }
        busy = true
        stopping = false
        activity = "Thinking…"
        var request = {op: "submit", turnId: turnId, agent: agent, prompt: text, attachment: turn.attachment}
        if (!turn.attachment) delete request.attachment
        // The persisted provider session travels with the request so a fresh
        // broker (idle shutdown, shell reload) resumes the conversation.
        if (sessionId) request.resumeSession = sessionId
        if (broker.running && brokerStarted) send(request)
        else {
            pending = request
            brokerStarted = false
            if (!brokerRetiring) {
                broker.running = true
                startupTimer.restart()
            }
        }
        ensureWorkspaceId()
        queueSave()
        return true
    }

    function replaceLatest(event) {
        if (!turns.length) return
        var copy = turns.slice()
        copy[copy.length - 1] = AiState.updateTurn(copy[copy.length - 1], event)
        turns = copy
        if (conversationModel.count) conversationModel.setProperty(conversationModel.count - 1, "payload", copy[copy.length - 1])
    }

    function receive(line) {
        if (brokerRetiring) return
        var event
        try { event = JSON.parse(line) } catch (error) { return }
        if (!event || typeof event !== "object") return
        lastBrokerActivity = Date.now()
        if (event.type === "ready") return
        if (event.turnId !== undefined && event.turnId !== turnId) return
        if (!busy) return
        if (event.sessionId) sessionId = String(event.sessionId)
        if (event.handoffHome) handoffHome = String(event.handoffHome)
        if (event.type === "started") activity = "Thinking…"
        if (event.type === "activity") activity = String(event.text || "Thinking…")
        if (["delta", "presentation", "done", "error", "stopped", "explain"].indexOf(event.type) >= 0) replaceLatest(event)
        if (["done", "error", "stopped", "explain"].indexOf(event.type) >= 0) {
            busy = false
            stopping = false
            activity = ""
        }
    }

    function stop() {
        if (!busy || stopping) return
        stopping = true
        activity = "Stopping…"
        if (broker.running && brokerStarted) send({op: "stop"})
        else {
            pending = null
            replaceLatest({type: "stopped"})
            busy = false
            stopping = false
        }
    }

    function newConversation() {
        if (busy || stopping) return
        var wasLoading = loadingLatest
        pending = null
        startupTimer.stop()
        if (broker.running && !brokerRetiring) send({op: "new"})
        // Any load still in flight describes the previous conversation; it
        // must not apply after a New chat, and its late output is discarded.
        ++loadToken
        loadWatchdog.stop()
        loadingLatest = false
        // A fresh conversation is immediately persistable: nothing is
        // pending that could overwrite it, so autosave must not stay
        // suppressed (that suppression is only for an in-flight restore).
        restoreSettled = true
        if (workspaceId && storeEnabled && !wasLoading) {
            // Starting fresh keeps the finished conversation: it stays saved
            // and searchable instead of being destroyed.
            saveDebounce.stop()
            storeRun("save", workspaceSnapshot())
        }
        turns = []
        conversationModel.clear()
        checklistStates = ({})
        uiStates = ({})
        agent = ""
        sessionId = ""
        handoffHome = ""
        attachment = ""
        draft = ""
        turnId++
        workspaceId = ""
        resumeOnOpen = false
        latestRequested = true
        draftTouched = false
        refreshWorkspaceIndex()
    }

    function continueInTerminal() {
        if (busy) return false
        var command = AiState.handoffCommand(agent, sessionId, handoffHome, stateRoot)
        if (!command.length) return false
        Quickshell.execDetached(command)
        return true
    }

    // Adaptive explanation depth: a prose-only sidecar for the current
    // learning object, preserving blocks, controls, selection and values.
    // Never appends a turn and never rewrites the presented answer.
    function explainLatest(mode) {
        if (!latest || busy || loadingLatest || stopping) return false
        var treatment = mode === "simpler" ? "simpler"
            : mode === "example" ? "another example" : "more depth"
        var blocks = latest.blocks || []
        var state = uiStates[String(latest.id)] || {}
        var parts = ["Requested: " + treatment]
        for (var i = 0; i < blocks.length; ++i) {
            var block = blocks[i]
            if (block && ["diagram", "slider", "steps", "check", "predict"].indexOf(block.type) >= 0) {
                parts.push("Subject: " + String(block.title || latest.prompt || "the answer").slice(0, 160))
                if (block.type === "diagram") {
                    var selection = state["diagram:" + i]
                    var part = typeof selection === "number" && selection >= 0
                        && block.parts && block.parts[selection]
                    if (part && part.label) parts.push("Selected: " + String(part.label).slice(0, 120))
                } else if (block.type === "slider") {
                    var slider = state["slider:" + i]
                    var unit = block.control && block.control.unit
                    if (typeof slider === "number" && isFinite(slider))
                        parts.push("Value: " + slider + (unit ? " " + unit : ""))
                } else if (block.type === "steps") {
                    var step = state["step:" + i]
                    if (typeof step === "number") parts.push("Stage: index " + step)
                }
                break
            }
        }
        var context = parts.join("\n").slice(0, 800)
        busy = true
        stopping = false
        activity = "Adjusting depth…"
        var request = {op: "explain", turnId: turnId, agent: agent, prompt: context}
        if (sessionId) request.resumeSession = sessionId
        if (broker.running && brokerStarted) send(request)
        else {
            pending = request
            brokerStarted = false
            if (!brokerRetiring) {
                broker.running = true
                startupTimer.restart()
            }
        }
        return true
    }

    // The broker stays warm while an AI surface is visible and a job may be
    // imminent; when everything is hidden and it has been idle past the grace
    // period it must exit (closed-state lifecycle). The persisted session
    // hint makes the next submit resume after the cold start.
    function brokerIdleCheck() {
        return brokerStarted && !busy && !stopping
            && !panelActive && !windowActive
            && Date.now() - lastBrokerActivity >= 30000
    }
    // Read-only view for diagnostics: the broker Process id is service-scope.
    readonly property bool brokerLive: broker.running

    FileView {
        path: Quickshell.env("HOME") + "/.config/omarchy/defaults/agent"
        watchChanges: true
        printErrors: false
        onLoaded: service.defaultAgent = String(text() || "").trim().toLowerCase()
        onLoadFailed: service.defaultAgent = ""
        onFileChanged: reload()
    }

    Timer {
        id: startupTimer
        interval: 3000
        onTriggered: {
            if (!service.brokerStarted && service.busy) {
                service.pending = null
                service.receive(JSON.stringify({type: "error", message: "AI helper could not start. Requires python3."}))
            }
        }
    }

    Process {
        id: broker
        stdinEnabled: true
        command: ["python3", "-u", service.brokerScript]
        stdout: SplitParser { onRead: function(line) { service.receive(line) } }
        stderr: StdioCollector { waitForEnd: true }
        onStarted: {
            if (service.brokerRetiring) { broker.running = false; return }
            service.brokerStarted = true
            startupTimer.stop()
            if (service.pending) {
                service.send(service.pending)
                service.pending = null
            }
        }
        onExited: function(code) {
            service.brokerStarted = false
            startupTimer.stop()
            if (service.brokerRetiring) {
                service.brokerRetiring = false
                if (service.pending) {
                    broker.running = true
                    startupTimer.restart()
                }
                return
            }
            if (service.busy) service.receive(JSON.stringify({type: "error", message: "AI helper stopped unexpectedly. Try your question again."}))
        }
    }

    // Hidden-surface idle shutdown: once the launcher and the detached window
    // are both gone (or the AI mode was never engaged) and no work ran for
    // 30 s, retire the broker process; submission later restarts it, resumed
    // from the persisted session hint.
    Timer {
        id: brokerIdleTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            if (broker.running && service.brokerIdleCheck())
                broker.running = false
        }
    }

    // Demand-started store worker: one Python interpreter and connection
    // across the burst of operations, answered strictly in request order.
    // The idle timer releases the worker 30 seconds after its last operation;
    // new work starts a fresh interpreter on demand.
    Process {
        id: storeProc
        stdinEnabled: true
        stdout: SplitParser { onRead: function(line) { service.dispatch(line) } }
        stderr: StdioCollector { waitForEnd: true }
        onStarted: {
            service.storeStarting = false
            // First synchronisation: after the start signal the child's stdin
            // is attached; drain whatever entered the queue while it started.
            // The channel stays open for the whole burst: closing it here
            // would send EOF and end the worker after its first request.
            if (service.storeQueue.length) service.sendJobs()
        }
        onExited: function(code) {
            service.storeStarting = false
            service.storePending = 0
            service.storeInFlight = []
            service.storeStopped = true
            // Only a queue with real work justifies a fresh interpreter; an
            // idle-exited worker must not be resurrected for no reason.
            if (service.storeQueue.length) storeRestartTimer.start()
        }
    }

    // Demand-started idle shutdown: the worker stays for the burst, then is
    // released 30 seconds after the last operation (the plan's cleanup
    // deadline). New work restarts it; nothing resurrects an idle worker.
    property real lastStoreWork: 0
    Timer {
        id: storeIdleTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            if (!storeProc.running || service.storeInFlight.length || service.storeQueue.length) return
            if (Date.now() - service.lastStoreWork < 30000) return
            if (service.busy) return
            service.storeStopped = true
            storeProc.running = false
        }
    }

    Timer {
        id: storeRestartTimer
        interval: 60
        onTriggered: {
            if (service.storeStarting && !storeProc.running) {
                // A Process that never delivered a start signal must not block
                // the drain forever; release the latch and let a fresh start
                // attempt happen (nothing clears it via onStarted in that case).
                service.storeStarting = false
            }
            if (service.storeQueue.length && !storeProc.running) service.startDrain()
        }
    }

    Timer {
        id: loadWatchdog
        interval: 5000
        onTriggered: {
            // A provider-side restore failure must never leave the composer
            // permanently unable to submit a fresh conversation.
            if (service.loadingLatest) {
                ++service.loadToken
                service.loadingLatest = false
                service.restoreSettled = true
            }
        }
    }

    // Last-resort store stall protection: a request written but never answered
    // (worker killed exactly between write and result, or a wedged worker)
    // must not strand the next save/load forever. The worker is torn down and
    // queued work restarts it; results resume on the next request.
    property int storeStallTick: 0
    Timer {
        id: storeStallTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            if (!service.storeInFlight.length) { service.storeStallTick = 0; return }
            if (++service.storeStallTick < 8) return
            console.warn("Workspace store worker stalled; restarting it for queued work")
            service.storeStallTick = 0
            service.storePending = 0
            service.storeInFlight = []
            service.storeStopped = true
            storeProc.running = false
            storeRestartTimer.start()
        }
    }

    Timer {
        id: bootRestore
        interval: 1
        onTriggered: if (service.storeEnabled) service.refreshWorkspaceIndex()
    }
    Component.onCompleted: bootRestore.start()
}
