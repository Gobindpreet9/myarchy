import QtQuick
import Quickshell
import Quickshell.Io
import "AiState.js" as AiState
import "CsvPage.js" as CsvPage
import "AiCalcEdit.js" as CalcEdit

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
    // Honest waiting: the provider returns the whole answer at the end, so the
    // UI shows the real phase (`activity`) plus whole seconds since this turn
    // went busy. ONE retained 1 Hz timer feeds every surface, runs only while
    // busy and visible, and a surface that appears recomputes at once.
    property int workElapsed: 0
    property real workStartedAt: 0
    property real clockOverride: -1     // test hook: a fake clock in ms
    readonly property alias elapsedTicking: elapsedTimer.running
    function nowMs() { return clockOverride >= 0 ? clockOverride : Date.now() }
    function refreshElapsed() {
        workElapsed = busy ? AiState.workSeconds((nowMs() - workStartedAt) / 1000) : 0
    }
    onBusyChanged: {
        if (busy) workStartedAt = nowMs()
        refreshElapsed()
    }
    Timer {
        id: elapsedTimer
        interval: 1000
        repeat: true
        running: service.busy && (service.panelActive || service.windowActive)
        onRunningChanged: if (running) service.refreshElapsed()
        onTriggered: service.refreshElapsed()
    }
    // Local timing ring: the last 50 sanitised broker `timing` objects. Memory
    // only: never persisted, never sent to a model.
    property var timingRing: []
    readonly property var lastTiming: timingRing.length ? timingRing[timingRing.length - 1] : null
    function recordTiming(raw) {
        var entry = AiState.sanitizeTiming(raw)
        if (entry) timingRing = timingRing.concat([entry]).slice(-AiState.TIMING_RING_MAX)
    }
    function timingSummary() { return AiState.timingSummary(timingRing) }
    property bool resumeOnOpen: false
    property string draft: ""
    property string attachment: ""
    // Local preview belongs to the retained service, not either disposable view.
    // Use an explicit object property: the reader's JSON `data` shadows Item.data.
    readonly property AiAttachmentPreview attachmentPreview: AiAttachmentPreview {
        path: service.attachment
        activeSurface: service.panelActive || service.windowActive
        restoring: service.loadingLatest
    }
    readonly property string previewStatus: attachmentPreview.status
    readonly property var previewData: attachmentPreview.pathMatch ? attachmentPreview.data : null
    readonly property string previewError: attachmentPreview.error
    readonly property bool attachmentBlocked: attachmentPreview.blocked
    // Column-type corrections ride with the CURRENT preview only: they clear
    // whenever readiness does, are never persisted, and never auto-send.
    readonly property var previewTypeOverrides: attachmentPreview.pathMatch ? attachmentPreview.typeOverrides : []
    function setPreviewColumnType(column, type) {
        return !workspaceTransitionPending && attachmentPreview.setColumnType(column, type)
    }

    function retryAttachmentPreview() { attachmentPreview.retry() }

    // ---- Durable CSV source -------------------------------------------------
    // ONE retained client of the source worker. The store REGISTRY (sources
    // table) is the authority for which source belongs to a workspace: on
    // restore the id is derived from `source_list {workspaceId}`, never from
    // saved text, so the two cannot desync. `interaction.csvSource` carries
    // only the ORIGIN PATH hint (the client never sees the worker's relative
    // origin) and keeps authoritative full saves from deleting it; it is used
    // only when its sourceId equals the registry's choice.
    readonly property AiCsvSource csvSource: AiCsvSource {
        stateRoot: service.stateRoot
        surfacesVisible: service.panelActive || service.windowActive
    }
    // 1 GiB total budget; a single copy is at most the worker's 64 MiB, which
    // is what a new copy is assumed to need before it exists.
    readonly property real sourceBudgetBytes: 1073741824
    readonly property real sourceMaxCopyBytes: 67108864
    property string linkedSourceId: ""   // registry row of the CURRENT workspace
    property string sourceOrigin: ""     // origin path of linkedSourceId, "" unknown
    // "", originChanged, originMissing, copyMissing (static; texts live in the pane)
    property string sourceNotice: ""
    property string sourceError: ""      // static refusal owned by this service
    property string keepPhase: ""        // "", budget, register, link
    property int keepSeq: 0
    property var keepJob: null           // {seq, path, workspaceId, previous, sourceId}
    property var pendingOpen: null       // {id, verify}
    // Restore tries the registry rows newest first: {workspaceId, ids, index}.
    property var restoreTry: null
    // Copies already queued for removal in this session (one unlink per id).
    property var discardedCopies: ({})
    property var heldCsvView: null       // {key, state} until a first turn exists
    property bool quietIdAssign: false
    readonly property bool keepPending: keepPhase !== ""
    // The kept statistics describe the file the model is about to see: true only
    // with no attachment (a follow-up about the kept data) or when the attachment
    // IS the kept file. A different attached file never gets the kept file's
    // "Full-source statistics" next to its own sample.
    function sourceAppliesTo(path) {
        return sourceReady && (!path || (sourceOrigin !== "" && path === sourceOrigin))
    }
    readonly property bool sourceApplies: sourceReady
        && (attachment === "" || (sourceOrigin !== "" && attachment === sourceOrigin))
    readonly property bool sourceReady: csvSource.status === "ready" && linkedSourceId !== ""
        && csvSource.sourceId === linkedSourceId
    readonly property string sourceStatus: keepPending ? "registering"
        : csvSource.status === "idle" && sourceError ? "error" : csvSource.status
    readonly property string sourceErrorText: sourceError || (csvSource.status === "error" ? csvSource.error : "")
    readonly property bool keepOffered: storeEnabled && attachmentPreview.isCsv
        && attachmentPreview.status === "ready" && attachmentPreview.pathMatch
        && !keepPending && csvSource.status !== "registering"
        && !(sourceReady && sourceOrigin === attachment)
    readonly property bool canKeepFullData: keepOffered && restoreSettled && !busy && !stopping
        && !loadingLatest && !attachmentBlocked && !workspaceActionPending
    readonly property bool canRefreshSource: sourceNotice === "originChanged" && sourceOrigin !== ""
        && linkedSourceId !== "" && storeEnabled && restoreSettled && !busy && !stopping
        && !loadingLatest && !keepPending && csvSource.status !== "registering" && !workspaceActionPending

    // Registers the CURRENT ready CSV attachment as this workspace's source.
    // Explicit only: nothing calls it but the person's button (or the test IPC).
    function keepFullData() { return canKeepFullData && startKeep(attachment) }
    // Registers a fresh copy of the original (the swap happens after success).
    function refreshSource() { return canRefreshSource && startKeep(sourceOrigin) }

    function startKeep(path) {
        if (keepPending || !CsvPage.validPath(path)) return false
        sourceError = ""
        restoreTry = null
        // Giving a fresh conversation its id is not a workspace switch: the
        // reviewed preview and its type corrections must survive it.
        quietIdAssign = true
        ensureWorkspaceId()
        quietIdAssign = false
        keepJob = {seq: ++keepSeq, path: path, workspaceId: workspaceId, previous: linkedSourceId, sourceId: ""}
        keepPhase = "budget"
        sourceGuard.restart()
        storeRun("source_list", {}, {purpose: "budget", seq: keepJob.seq, workspaceId: workspaceId})
        return true
    }

    function keepEnd() {
        keepPhase = ""
        keepJob = null
        sourceGuard.stop()
    }

    // The previous copy (if any) comes back after a failed replacement.
    function reopenSource(id, verify) {
        if (!CsvPage.validSourceId(id)) { csvSource.close(); return }
        pendingOpen = {id: id, verify: !!verify}
        if (!csvSource.open(id)) pendingOpen = null
    }

    // Best-effort removal of a copy that never became any workspace's source.
    // The id comes from the worker's own register reply, so it has no registry
    // row; the linked source and the one being replaced are never touched.
    function discardCopy(id) {
        if (!CsvPage.validSourceId(id) || discardedCopies[id] || id === linkedSourceId
                || (keepJob && id === keepJob.previous)) return false
        var seen = Object.assign({}, discardedCopies)
        seen[id] = true
        discardedCopies = seen
        storeRun("source_unlink", {sourceId: id, removeDir: true})
        return true
    }

    function keepAbort(text) {
        var job = keepJob
        var phase = keepPhase
        keepEnd()
        sourceError = text
        if (!job || (phase !== "link" && phase !== "register")) return
        // The new copy never became this workspace's source: remove it
        // (best effort, behind any link already queued) and restore the old.
        discardCopy(job.sourceId)
        csvSource.close()
        if (job.previous) reopenSource(job.previous, false)
    }

    function resetSource() {
        keepEnd()
        pendingOpen = null
        restoreTry = null
        sourceNotice = ""
        sourceError = ""
        linkedSourceId = ""
        sourceOrigin = ""
        heldCsvView = null
        csvSource.close()
    }

    function beginLink() {
        var job = keepJob
        var meta = csvSource.meta
        if (!job || !meta || job.workspaceId !== workspaceId || !CsvPage.validSourceId(meta.sourceId)) {
            // The register finished, so a complete copy exists even though it
            // cannot be linked: keepAbort removes it by the id the worker gave.
            if (job && meta && CsvPage.validSourceId(meta.sourceId)) job.sourceId = meta.sourceId
            keepAbort("Could not save the kept copy with this conversation.")
            return
        }
        job.sourceId = meta.sourceId
        keepPhase = "link"
        sourceGuard.restart()
        // Save first (the registry row needs its workspace), then link.
        saveDebounce.stop()
        storeRun("save", savePayload())
        storeRun("source_link", {workspaceId: job.workspaceId, sourceId: meta.sourceId,
            bytes: meta.bytes, rows: meta.rows},
            {purpose: "link", seq: job.seq, workspaceId: job.workspaceId, sourceId: meta.sourceId,
             previous: job.previous, origin: job.path})
    }

    function csvStatusChanged() {
        var status = csvSource.status
        if (keepPhase === "register") {
            if (status === "ready") beginLink()
            else if (status === "error") {
                var previous = keepJob ? keepJob.previous : ""
                var text = csvSource.error || "CSV source is unavailable."
                keepEnd()
                sourceError = text
                if (previous) reopenSource(previous, false)
            }
            return
        }
        if (!pendingOpen) return
        if (status === "ready" && csvSource.sourceId === pendingOpen.id) {
            var wantsVerify = pendingOpen.verify
            pendingOpen = null
            if (wantsVerify) csvSource.verify()
        } else if (status === "error") {
            var wasVerify = pendingOpen.verify
            pendingOpen = null
            if (wasVerify) restoreCandidateFailed()
        }
    }

    function csvVerifyChanged() {
        if (!linkedSourceId || csvSource.sourceId !== linkedSourceId) return
        var state = csvSource.verifyState
        if (restoreTry && restoreTry.workspaceId === workspaceId && restoreTry.ids[restoreTry.index] === linkedSourceId) {
            if (state === "copyMissing") { restoreCandidateFailed(); return }
            if (state === "ready" || state === "originChanged" || state === "originMissing") restoreCandidateOpened()
        }
        sourceNotice = state === "originChanged" || state === "originMissing" || state === "copyMissing" ? state : ""
    }

    // The newest registry row opened and verified: only now are the OLDER rows
    // (an interrupted swap's leftovers) removed. A newer row that failed stays.
    function restoreCandidateOpened() {
        var attempt = restoreTry
        restoreTry = null
        if (!attempt) return
        for (var i = attempt.index + 1; i < attempt.ids.length; ++i)
            storeRun("source_unlink", {sourceId: attempt.ids[i], removeDir: true})
    }

    // This row will not open: leave every row untouched and try the next newest.
    // Only when none opens is the saved-copy notice shown.
    function restoreCandidateFailed() {
        var attempt = restoreTry
        if (!attempt || attempt.workspaceId !== workspaceId || keepPhase !== "") {
            sourceNotice = "copyMissing"
            return
        }
        if (attempt.index + 1 < attempt.ids.length) {
            attempt.index += 1
            linkedSourceId = attempt.ids[attempt.index]
            sourceOrigin = ""
            reopenSource(linkedSourceId, true)
            return
        }
        restoreTry = null
        linkedSourceId = attempt.ids[0]
        sourceNotice = "copyMissing"
    }

    function sourceStoreResult(job, result) {
        var info = job.carryState || {}
        if (info.purpose === "budget") {
            if (!keepJob || keepJob.seq !== info.seq || keepPhase !== "budget") return
            if (!result || typeof result.totalBytes !== "number") {
                keepAbort("Could not check the storage used by kept CSV copies.")
                return
            }
            var previousBytes = 0
            ;(Array.isArray(result.sources) ? result.sources : []).forEach(function(entry) {
                if (entry && entry.id === keepJob.previous && typeof entry.bytes === "number") previousBytes = entry.bytes
            })
            if (result.totalBytes - previousBytes + sourceMaxCopyBytes > sourceBudgetBytes) {
                keepAbort("Kept CSV copies already fill the 1 GiB limit, so this file was not copied.")
                return
            }
            // register() invalidates the current source first; its own status
            // flips must not read as this registration finishing.
            var started = csvSource.register(keepJob.path)
            if (!started) {
                var restore = keepJob.previous
                keepAbort(csvSource.error || "Choose a CSV file inside your home directory.")
                if (restore) reopenSource(restore, false)
                return
            }
            keepPhase = "register"
            sourceGuard.stop()
        } else if (info.purpose === "link") {
            var current = keepJob && keepJob.seq === info.seq && keepPhase === "link"
                && info.workspaceId === workspaceId && csvSource.sourceId === info.sourceId
            if (!result) {
                if (current) keepAbort("Could not save the kept copy with this conversation.")
                else discardCopy(info.sourceId)
                return
            }
            // A link that landed after the keep was abandoned (timeout) is
            // removed by the unlink queued behind it; the replaced copy stays.
            if (discardedCopies[info.sourceId]) return
            // The new row stands: the replaced copy must not pile up.
            if (info.previous && info.previous !== info.sourceId)
                storeRun("source_unlink", {sourceId: info.previous, removeDir: true})
            if (!current) return
            keepEnd()
            linkedSourceId = info.sourceId
            sourceOrigin = info.origin
            sourceNotice = ""
            sourceError = ""
            // Persist the origin hint with the next full save.
            dirtyContent = true
            queueSave()
        } else if (info.purpose === "restore") {
            if (!result || info.workspaceId !== workspaceId || keepPhase !== "") return
            var mine = (Array.isArray(result.sources) ? result.sources : []).filter(function(entry) {
                return entry && CsvPage.validSourceId(entry.id) && entry.workspaceId === workspaceId
            })
            if (!mine.length) { linkedSourceId = ""; sourceOrigin = ""; return }
            // Newest first. Older rows (an interrupted swap's leftovers) are
            // removed only AFTER the newest has opened and verified, so a
            // damaged newest copy never costs the survivor.
            var ids = mine.map(function(entry) { return entry.id }).reverse()
            restoreTry = {workspaceId: workspaceId, ids: ids, index: 0}
            if (linkedSourceId !== ids[0]) sourceOrigin = ""
            linkedSourceId = ids[0]
            reopenSource(ids[0], true)
        }
    }

    Connections {
        target: service.csvSource
        // Deferred: the client assigns status BEFORE its error/meta fields and
        // a handler must never re-enter it half-way through a transition.
        function onStatusChanged() { Qt.callLater(service.csvStatusChanged) }
        function onVerifyStateChanged() { Qt.callLater(service.csvVerifyChanged) }
        // A copy the worker made but this service will not use (stale or
        // rejected register reply): remove it so it cannot linger unseen.
        function onRegisterDiscarded(id) { service.discardCopy(id) }
    }

    // A store reply lost to a worker restart must not leave the keep action
    // pending forever (register has its own inactivity watchdog).
    Timer {
        id: sourceGuard
        interval: 15000
        onTriggered: {
            if (service.keepPhase === "budget" || service.keepPhase === "link")
                service.keepAbort("Saving the kept copy timed out. Try again.")
        }
    }

    // ---- Explorer view state (sort/filter/page) ---------------------------
    // Persisted like every other learning interaction: under the LATEST turn's
    // `uiStates` entry as `csv:<sourceId>`. Before the first turn exists it is
    // held here and written to the first turn at submit; every submit also
    // carries the current state to the new latest turn, so it survives the
    // 20-turn window.
    function csvViewKey(id) { return "csv:" + id }
    function csvViewState(id) {
        if (!CsvPage.validSourceId(id)) return ({})
        var key = csvViewKey(id)
        for (var i = turns.length - 1; i >= 0; --i) {
            var map = uiStates[String(turns[i].id)]
            if (map && map[key] !== undefined) return map[key]
        }
        return heldCsvView && heldCsvView.key === key ? heldCsvView.state : ({})
    }
    function setCsvViewState(id, state) {
        if (workspaceTransitionPending || !CsvPage.validSourceId(id) || !state || typeof state !== "object") return false
        var clean = {
            sort: CsvPage.isInt(state.sort, -1, 99) ? state.sort : -1,
            dir: state.dir === -1 ? -1 : 1,
            filter: CsvPage.cleanFilter(state.filter),
            page: CsvPage.isInt(state.page, 0, 9007199254740991) ? state.page : 0
        }
        if (latest) { heldCsvView = null; setUiState(latest.id, csvViewKey(id), clean) }
        else heldCsvView = {key: csvViewKey(id), state: clean}
        return true
    }
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
    property string workspaceName: ""
    readonly property string workspaceDisplayTitle: workspaceName
        || (latest ? AiState.answerTitle(latest) : "Untitled workspace")
    property var workspaceAction: null
    property int workspaceActionSeq: 0
    property string workspaceActionError: ""
    readonly property bool workspaceActionPending: workspaceAction !== null
    readonly property bool workspaceTransitionPending: workspaceAction !== null && workspaceAction.phase === "loading"
    readonly property bool canManageWorkspace: storeEnabled && workspaceId !== ""
        && restoreSettled && (turns.length > 0 || linkedSourceId !== "" || workspaceName !== "")
        && !busy && !stopping && !loadingLatest && !keepPending && !workspaceActionPending
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
            // A form-answer turn keeps its rendered answers and the way back to
            // its form (Retry); ordinary turns gain no keys.
            if (turn.formRef) {
                interaction["turn:" + turn.id].formAnswers = turn.formAnswers || []
                interaction["turn:" + turn.id].formRef = turn.formRef
            }
            // Likewise a picked-option turn keeps its visible text and its way back.
            if (turn.choiceRef) {
                interaction["turn:" + turn.id].choiceText = turn.choiceText || ""
                interaction["turn:" + turn.id].choiceRef = turn.choiceRef
            }
            // A partially streamed turn never writes an artifact or revision.
            if (turn.blocks && turn.blocks.length > 0 && turn.partial !== true) {
                artifacts.push({id: artifactId, kind: "answer", presentationVersion: 1,
                    blocks: turn.blocks, reason: "answer", prompt: turn.prompt})
            }
        }
        if (Object.keys(checklistStates).length) interaction.checklists = checklistStates
        if (Object.keys(uiStates).length) interaction.uiStates = uiStates
        if (handoffHome) interaction.handoffHome = handoffHome
        if (linkedSourceId) interaction.csvSource = {sourceId: linkedSourceId, origin: sourceOrigin}
        if (workspaceName) interaction.workspaceName = workspaceName
        return {
            workspace: {id: workspaceId, title: workspaceDisplayTitle,
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
            title: workspaceDisplayTitle,
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
        if (loadingLatest || !restoreSettled || workspaceActionPending) return
        saveDebounce.restart()
    }

    // Save acknowledgement is a barrier: never clone stale on-disk inputs or
    // rename a row whose latest local content failed to commit. Local editing
    // remains possible; deferred edits are saved to the original after the action.
    function beginWorkspaceAction(op, title) {
        var name = AiState.workspaceName(title)
        if (!canManageWorkspace || !name) return false
        workspaceActionError = ""
        var destination = "ws-" + Math.random().toString(16).slice(2, 10).padEnd(8, "0")
            + Math.random().toString(16).slice(2, 10).padEnd(8, "0")
        workspaceAction = {seq: ++workspaceActionSeq, op: op, id: workspaceId,
            title: name, destination: destination, phase: "saving"}
        workspaceActionGuard.restart()
        saveDebounce.stop()
        storeRun("save", workspaceSnapshot(), {workspaceAction: workspaceAction.seq, phase: "save"})
        return true
    }
    function renameWorkspace(title) { return beginWorkspaceAction("rename", title) }
    function duplicateWorkspace(title) { return beginWorkspaceAction("duplicate", title) }

    function failWorkspaceAction(uncertain) {
        if (!workspaceAction) return
        var action = workspaceAction
        workspaceActionGuard.stop()
        if (action.phase === "loading") {
            ++loadToken
            loadWatchdog.stop()
            loadingLatest = false
            restoreSettled = true
        }
        // A committed rename whose reply was lost must not be undone by the
        // recovery save. Replay the requested name idempotently in that save.
        if (uncertain && action.op === "rename" && action.phase === "mutation")
            workspaceName = action.title
        var seq = workspaceAction.seq
        workspaceAction = null
        workspaceActionError = action.phase === "loading"
            ? "The copy was saved but couldn't be opened. Your original is still open."
            : "Couldn't confirm the workspace action. Your answers and inputs are safe. Check saved workspaces before trying again."
        // Do not send a mutation whose prerequisite save timed out.
        var remaining = storeQueue.filter(function(job) {
            return !job.carryState || job.carryState.workspaceAction !== seq
        })
        storePending = Math.max(0, storePending - (storeQueue.length - remaining.length))
        storeQueue = remaining
        dirtyContent = true
        queueSave()
        Qt.callLater(service.refreshWorkspaceIndex)
    }

    function workspaceActionResult(job, result) {
        var info = job.carryState
        if (!info || typeof info.workspaceAction !== "number") return false
        var action = workspaceAction
        // Retired/failed action replies must never navigate or rename a new chat.
        if (!action || info.workspaceAction !== action.seq || action.id !== workspaceId) return true
        workspaceActionGuard.restart()
        if (info.phase === "switch-load") {
            if (job.loadToken !== loadToken) return true
            loadWatchdog.stop()
            loadingLatest = false
            restoreSettled = true
            if (!result || result.ok !== true || !result.workspace || result.workspace.id !== action.destination) {
                failWorkspaceAction()
                return true
            }
            // This is a different workspace, not a latest-restore draft merge.
            // The original's post-click draft was already acknowledged above.
            workspaceAction = null
            workspaceActionGuard.stop()
            draftTouched = false
            applyWorkspaceSnapshot(result, {})
            saveDebounce.restart()
            return true
        }
        if (!result || result.ok !== true) { failWorkspaceAction(); return true }
        if (info.phase === "save") {
            workspaceAction = Object.assign({}, action, {phase: "mutation"})
            var payload = {workspaceId: action.id, title: action.title}
            if (action.op === "duplicate") payload.newWorkspaceId = action.destination
            storeRun(action.op, payload, {workspaceAction: action.seq, phase: "mutation"})
            return true
        }
        if (info.phase === "switch-save") {
            // Edits made while the copy was being created belong to the
            // original. Do not replace that live state until its save is
            // acknowledged. One request at a time bounds continuous editing.
            var current = workspaceSnapshot()
            if (JSON.stringify(current) !== info.snapshot) {
                storeRun("save", current, {workspaceAction: action.seq, phase: "switch-save",
                    snapshot: JSON.stringify(current)})
                return true
            }
            workspaceAction = Object.assign({}, action, {phase: "loading"})
            latestRequested = true
            storeRun("load", {workspaceId: action.destination}, {workspaceAction: action.seq,
                phase: "switch-load", preserveOutgoing: true})
            return true
        }
        var expected = action.op === "duplicate" ? action.destination : action.id
        if (result.workspaceId !== expected || result.title !== action.title) {
            failWorkspaceAction(true)
            return true
        }
        if (action.op === "rename") {
            workspaceAction = null
            workspaceActionGuard.stop()
            workspaceName = action.title
            dirtyContent = true
            queueSave()
            refreshWorkspaceIndex()
        } else {
            var outgoing = workspaceSnapshot()
            storeRun("save", outgoing, {workspaceAction: action.seq, phase: "switch-save",
                snapshot: JSON.stringify(outgoing)})
        }
        return true
    }

    function storeRun(op, payload, carryState) {
        if (op === "save" && workspaceActionPending
            && (!carryState || carryState.workspaceAction !== workspaceAction.seq)) {
            // Close-commit is another save entry point. Hold it too: a stale
            // pre-rename snapshot must never run after the rename transaction.
            dirtyContent = true
            return
        }
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
            // While a duplicate hydrates, the original remains the rollback
            // state. Retire its broker, but keep durable ownership until apply.
            if (!job.carryState.preserveOutgoing) {
                sessionId = ""
                handoffHome = ""
                resetSource()
            }
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
    function storeWorkerLost() {
        failWorkspaceAction(true)
        storeStarting = false
        storeInFlight = []
        // Retire lost in-flight jobs, not unsent work. The queue still counts
        // as busy until a replacement worker has acknowledged those requests.
        storePending = storeQueue.length
        storeStopped = true
        if (storeQueue.length) storeRestartTimer.start()
    }
    function workspaceActionTimedOut() {
        if (!workspaceAction) return
        if (storeStarting && !storeInFlight.length) {
            // No process signal arrived: cancel the startup attempt explicitly
            // and release its latch so recovery saves can demand-start again.
            storeWorkerLost()
            storeProc.running = false
            storeRestartTimer.start()
        } else failWorkspaceAction(true)
    }
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
        if (workspaceActionResult(job, result)) {
            if (storeQueue.length) startDrain()
            return
        }
        if (job.op === "load" && !pruneQueued) {
            pruneQueued = true
            storeRun("prune", {preserveWorkspaces: true})
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
        if (job.op === "source_list" || job.op === "source_link") {
            var good = result && typeof result === "object" && result.ok === true
            if (!good) console.warn("Workspace store " + job.op + " failed")
            sourceStoreResult(job, good ? result : null)
            if (storeQueue.length) startDrain()
            return
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
        // Even an unchanged attachment path is a new workspace-local read.
        // The reader defers dispatch so a load's false flag cannot read the
        // outgoing attachment before this synchronous apply has finished.
        attachmentPreview.invalidate()
        resetSource()
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
        workspaceName = AiState.workspaceName(interaction.workspaceName)
        // Blocks are canonical in artifacts; transcripts saved before the
        // artifact split still carry their blocks inline as a fallback.
        var artifactBlocks = {}
        ;(result.artifacts || []).forEach(function(artifact) {
            if (artifact && artifact.id) artifactBlocks[String(artifact.id)] =
                Array.isArray(artifact.blocks) ? artifact.blocks : []
        })
        handoffHome = String(interaction.handoffHome || "")
        // The registry decides the source (source_list below); this only keeps
        // the saved origin hint alive until it answers, so a full save in
        // between cannot erase it.
        var hint = interaction.csvSource
        if (hint && typeof hint === "object" && CsvPage.validSourceId(hint.sourceId)) {
            linkedSourceId = hint.sourceId
            sourceOrigin = CsvPage.validPath(hint.origin) ? hint.origin : ""
        }
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
        stateNotice = ""
        focusTarget = null
        turnId = ids.length ? Math.max.apply(null, ids) : 0
        turns = fixed
        conversationModel.clear()
        fixed.forEach(function(turn) { conversationModel.append({payload: turn}) })
        resumeOnOpen = fixed.length > 0 || draft.length > 0
        restoreSettled = true
        service.workspaceRestored()
        refreshWorkspaceIndex()
        if (storeEnabled) storeRun("source_list", {workspaceId: workspaceId},
            {purpose: "restore", workspaceId: workspaceId})
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
        if (!storeEnabled || !id || busy || stopping || loadingLatest || workspaceActionPending) return false
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

    function retainedTurnStates(map, activeTurns) {
        var kept = {}
        for (var i = 0; i < activeTurns.length; ++i) {
            var key = String(activeTurns[i].id)
            if (Object.prototype.hasOwnProperty.call(map, key)) kept[key] = map[key]
        }
        return kept
    }
    onTurnsChanged: {
        var keptUi = retainedTurnStates(uiStates, turns)
        var keptChecks = retainedTurnStates(checklistStates, turns)
        if (Object.keys(keptUi).length !== Object.keys(uiStates).length) uiStates = keptUi
        if (Object.keys(keptChecks).length !== Object.keys(checklistStates).length) checklistStates = keptChecks
        dirtyContent = true
        queueSave()
    }
    onChecklistStatesChanged: { dirtyContent = true; queueSave() }
    onUiStatesChanged: { dirtyContent = true; queueSave() }
    onDraftChanged: { ++draftRevision; queueSave() }
    onAttachmentChanged: { sourceError = ""; queueSave() }
    onWorkspaceIdChanged: { if (!quietIdAssign) attachmentPreview.invalidate() }
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

    function copyAnswer() { Quickshell.clipboardText = AiState.textAnswer(latest, latest ? uiStates[String(latest.id)] : null) }

    // Clipboard text a block asked for (a calc's own export). Only a user
    // gesture reaches this; refuses non-strings, empty text and anything over
    // 64 KiB of UTF-8 (NUL is stripped, never copied).
    readonly property int maxCopyBytes: 64 * 1024
    function copyText(text) {
        if (typeof text !== "string") return false
        var clean = text.indexOf("\u0000") >= 0 ? text.replace(/\u0000/g, "") : text
        if (!clean.length || clean.length > maxCopyBytes || CsvPage.utf8Bytes(clean) > maxCopyBytes) return false
        Quickshell.clipboardText = clean
        return true
    }

    function openSource(url) {
        var command = AiState.sourceCommand(url)
        if (!command.length) return false
        Quickshell.execDetached(command)
        return true
    }

    function setChecklist(id, block, item, checked) {
        if (workspaceTransitionPending) return false
        var all = Object.assign({}, checklistStates)
        var state = Object.assign({}, all[String(id)] || {})
        state[block + ":" + item] = checked
        all[String(id)] = state
        checklistStates = all
        return true
    }

    // The store keeps the WHOLE uiStates map as one interaction value and
    // rejects a save over 256 KiB, which would silently stop every autosave.
    // An edit that would grow the map past 200 KiB is refused instead (nothing
    // is changed or deleted); stateNotice says so until the next accepted edit.
    readonly property int maxUiStatesBytes: 200 * 1024
    property string stateNotice: ""
    function uiStatesBytes(map) {
        var text = JSON.stringify(map)
        // UTF-8 is never shorter than UTF-16 length and never over 3x it, so
        // only a map in the middle band needs the exact (linear) count.
        if (text.length > maxUiStatesBytes) return text.length
        return text.length * 3 <= maxUiStatesBytes ? text.length : CsvPage.utf8Bytes(text)
    }
    // A map over the limit may still shrink or stay (Reset must always work).
    function uiStatesFit(next) {
        try {
            var bytes = uiStatesBytes(next)
            return bytes <= maxUiStatesBytes || bytes <= uiStatesBytes(uiStates)
        } catch (error) { return false }
    }

    function setUiState(id, key, value) {
        if (workspaceTransitionPending) return false
        var all = Object.assign({}, uiStates)
        var turnMap = Object.assign({}, all[String(id)] || {})
        turnMap[String(key)] = value
        all[String(id)] = turnMap
        if (!uiStatesFit(all)) {
            stateNotice = "Too many saved edits to keep this change."
            return false
        }
        stateNotice = ""
        uiStates = all
        return true
    }

    // Copy of a calculation as a NEW LOCAL TURN: no provider call, no broker
    // message, provider session/agent untouched (the turn is self-contained, so
    // a later follow-up or depth request reads it from the turn itself; an empty
    // answer is a valid done turn). baked = {block, entry} from AiCalcEdit.bake.
    readonly property int maxDuplicateBytes: 64 * 1024
    function duplicateCalc(baked) {
        if (busy || stopping || loadingLatest || workspaceActionPending || workspaceTransitionPending) return false
        if (storeEnabled && !restoreSettled) return false
        var plain
        try { plain = JSON.parse(JSON.stringify(baked)) } catch (error) { return false }
        var block = plain && typeof plain === "object" ? plain.block : null
        if (!block || typeof block !== "object" || Array.isArray(block) || block.type !== "calc") return false
        if (CsvPage.utf8Bytes(JSON.stringify(block)) > maxDuplicateBytes) return false
        var title = String(block.title === undefined ? "" : block.title)
            .replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029]+/g, " ").replace(/\s+/g, " ").trim()
        var prompt = title.indexOf("Copy of ") === 0 ? title : "Copy of " + (title || "calculation")
        if (prompt.length > 160) {
            prompt = prompt.slice(0, 160)
            if (/[\ud800-\udbff]$/.test(prompt)) prompt = prompt.slice(0, -1)
        }
        // Only a closed, validated entry is kept (scenarios, <= 10 KiB); anything
        // else is dropped so the copy simply starts from its baked defaults.
        var entry = {}, raw = plain.entry
        if (raw && typeof raw === "object" && !Array.isArray(raw) && Array.isArray(block.inputs)
                && Array.isArray(raw._s) && CalcEdit.sizeOf(raw) <= CalcEdit.maxEntryBytes) {
            var inputs = block.inputs.filter(function(input) {
                return input && typeof input === "object" && typeof input.id === "string"
            }).map(function(input) {
                return {id: input.id, unit: typeof input.unit === "string" ? input.unit : "", min: input.min, max: input.max}
            })
            var cleaned = CalcEdit.cleanScenarios(inputs, raw._s).scenarios
            if (cleaned.length) entry = {_s: cleaned}
        }
        var id = turnId + 1
        var nextStates = retainedTurnStates(uiStates, turns.slice(-19))
        if (Object.keys(entry).length) nextStates[String(id)] = {"calc:0": entry}
        if (!uiStatesFit(nextStates)) {
            stateNotice = "Too many saved edits to keep this change."
            return false
        }
        stateNotice = ""
        var turn = {prompt: prompt, attachment: "", answer: "", blocks: [block], suggestions: [],
            status: "done", error: "", warning: "", id: id}
        turns = turns.concat([turn]).slice(-20)
        conversationModel.append({payload: turn})
        if (conversationModel.count > 20) conversationModel.remove(0)
        uiStates = nextStates
        clearFocus()
        resumeOnOpen = true
        turnId++
        ensureWorkspaceId()
        dirtyContent = true
        queueSave()
        return true
    }

    // The part of the latest answer the person is asking about ("About: <label>").
    // NOT persisted and never part of a snapshot. It is named focusTarget because
    // Item.focus is a FINAL property: a property called `focus` will not load.
    // The next TYPED submit attaches it as workspaceContext.focus; any turn that
    // starts (typed, form, choice) clears it, and so do New chat, a workspace
    // switch and a restore. {turnId, blockIndex, kind, index, label, detail}.
    property var focusTarget: null
    readonly property string focusLabel: focusTarget ? String(focusTarget.label) : ""
    function clearFocus() {
        if (focusTarget !== null) focusTarget = null
    }
    // Only the latest FINISHED answer's real block can be the subject: the
    // object is rebuilt through AiState.focusWire (clean, bounded, closed shape)
    // and its kind must be that block's own type.
    function setFocus(target) {
        if (workspaceTransitionPending || busy || stopping || loadingLatest) return false
        var wire = AiState.focusWire(target)
        if (!wire || !latest || latest.id !== wire.turnId || latest.status !== "done") return false
        var block = latest.blocks && wire.blockIndex < latest.blocks.length ? latest.blocks[wire.blockIndex] : null
        if (!block || typeof block !== "object" || block.type !== wire.kind) return false
        focusTarget = wire
        return true
    }

    function submit(prompt) {
        var text = String(prompt || "").trim()
        if (!text || busy || stopping || loadingLatest || attachmentBlocked || workspaceActionPending) return false
        if (text.length > 8000) return false
        return sendTurn(text, null)
    }

    // The one turn-starting path. `linked` is null for a typed question, else the
    // follow-up this turn answers: {key: "form", payload, rows, ref} from
    // submitForm or {key: "choice", payload, text, ref} from submitChoice. A
    // linked turn carries NO attachment, leaves the person's composer draft and
    // pending file alone and attaches no focus (form/choice/focus are mutually
    // exclusive on the wire). Every turn that starts consumes the pending focus.
    function sendTurn(text, linked) {
        var chosen = AiState.resolveAgent(agent, defaultAgent)
        if (linked && !AiState.supported(chosen)) return false
        if (AiState.supported(chosen)) agent = chosen
        // Capture the active tool BEFORE appending/clearing the outgoing turn.
        // This is a bounded immutable snapshot, independent of provider session
        // continuity (including a duplicated workspace's first fresh request).
        var workspaceContext = AiState.supported(chosen) && typeof AiState.workspaceContext === "function"
            ? AiState.workspaceContext(turns, uiStates) : null
        if (linked) {
            if (!workspaceContext) return false
            workspaceContext[linked.key] = linked.payload
        } else if (workspaceContext && focusTarget) {
            // The focus must describe the answer this follow-up is about.
            var focusWire = AiState.focusWire(focusTarget)
            if (focusWire && workspaceContext.previous && workspaceContext.previous.turnId === focusWire.turnId)
                workspaceContext.focus = focusWire
        }
        var turn = AiState.newTurn(text, linked ? "" : attachment)
        if (linked && linked.key === "form") {
            turn.formAnswers = linked.rows
            turn.formRef = linked.ref
        } else if (linked) {
            turn.choiceText = linked.text
            turn.choiceRef = linked.ref
        }
        clearFocus()
        // Capture BEFORE the attachment is consumed below (which resets them).
        var columnTypes = turn.attachment ? attachmentPreview.requestColumnTypes() : null
        turn.id = turnId + 1
        turns = turns.concat([turn]).slice(-20)
        conversationModel.append({payload: turn})
        if (conversationModel.count > 20) conversationModel.remove(0)
        if (!linked) {
            attachment = ""
            draft = ""
        }
        resumeOnOpen = true
        turnId++
        if (heldCsvView) {
            // Edited before any turn existed: the first turn takes it over.
            setUiState(turn.id, heldCsvView.key, heldCsvView.state)
            heldCsvView = null
        } else if (linkedSourceId) {
            // Carry the explorer's view to the new latest turn so it outlives
            // the 20-turn window.
            var carried = csvViewState(linkedSourceId)
            if (Object.keys(carried).length) setUiState(turn.id, csvViewKey(linkedSourceId), carried)
        }
        if (!AiState.supported(chosen)) {
            replaceLatest({type: "error", message: chosen ? "The launcher supports Codex and Hermes for now. Your default is " + chosen + "."
                : "Choose an AI agent in Omarchy first: omarchy default agent codex"})
            return false
        }
        busy = true
        stopping = false
        activity = "Thinking…"
        var request = {op: "submit", turnId: turnId, agent: agent, prompt: text, attachment: turn.attachment}
        if (workspaceContext) request.workspaceContext = workspaceContext
        if (!turn.attachment) delete request.attachment
        if (columnTypes) request.columnTypes = columnTypes
        // Follow-ups about the kept data (no attachment) and turns that attach
        // the kept file itself keep the full-file statistics (the broker owns
        // the size budget); a DIFFERENT attached file never carries them.
        if (sourceAppliesTo(turn.attachment)) request.sourceId = csvSource.sourceId
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

    // Send the answers of a `form` block as ONE fixed-template follow-up. The
    // prompt is a constant sentence (never model text); the values ride
    // workspaceContext.form = {turnId, blockIndex, title, answers[<=6]} built from
    // the PERSISTED draft, and the visible turn lists the same answers
    // (turn.formAnswers) with a way back to the form (turn.formRef) for Retry.
    // `sent` is stored only after the request was accepted. Gated like submit();
    // a repeat while the answer is working is refused by `busy`.
    function submitForm(formTurnId, blockIndex) {
        if (busy || stopping || loadingLatest || workspaceActionPending || workspaceTransitionPending) return false
        if (typeof formTurnId !== "number" || formTurnId !== Math.floor(formTurnId)
                || typeof blockIndex !== "number" || blockIndex !== Math.floor(blockIndex)
                || blockIndex < 0 || blockIndex > 5) return false
        if (!AiState.formResendable(turns, formTurnId)) return false
        var source = null
        for (var i = turns.length - 1; i >= 0 && !source; --i)
            if (turns[i] && turns[i].id === formTurnId) source = turns[i]
        var block = source && source.blocks ? source.blocks[blockIndex] : null
        var states = uiStates[String(formTurnId)]
        var restored = AiState.formRestore(block, states ? states["form:" + blockIndex] : undefined)
        if (!restored.form) return false
        var payload = AiState.formWire(restored, formTurnId, blockIndex)
        if (!payload.answers.length || !AiState.formWireFits(payload)) return false
        if (!AiState.supported(AiState.resolveAgent(agent, defaultAgent))) return false
        // The sent mark must fit the 200 KiB map BEFORE anything is sent, so a
        // request can never go out while its marker is silently refused.
        var marked = Object.assign({}, uiStates)
        var turnMap = Object.assign({}, marked[String(formTurnId)] || {})
        turnMap["form:" + blockIndex] = {v: restored.draft, sent: true}
        marked[String(formTurnId)] = turnMap
        if (!uiStatesFit(marked)) {
            stateNotice = "Too many saved edits to keep this change."
            return false
        }
        var rows = AiState.formRows(AiState.formAnswersOf(restored))
        if (!sendTurn(AiState.FORM_PROMPT, {key: "form", payload: payload, rows: rows,
                ref: {turnId: formTurnId, blockIndex: blockIndex}})) return false
        setUiState(formTurnId, "form:" + blockIndex, {v: restored.draft, sent: true})
        return true
    }

    // Send ONE picked option of an `actions`/`compare` block as a fixed-template
    // follow-up: prompt 'Choice made on the previous answer.', context
    // workspaceContext.choice = {turnId, blockIndex, kind, index, title, label}
    // taken from the PERSISTED block (cleaned and clamped), a visible turn text
    // 'Picked: <label>' and state `act:<blockIndex>` = {picked: index}. Gated like
    // submitForm; refused when that block already has a pick on the still-latest
    // turn (a FAILED answer to the pick re-opens it). Nothing is appended, sent or
    // stored on a refusal; the pick mark is stored only after the request left.
    function submitChoice(choiceTurnId, blockIndex, kind, index) {
        if (busy || stopping || loadingLatest || workspaceActionPending || workspaceTransitionPending) return false
        function whole(value, low, high) {
            return typeof value === "number" && value === Math.floor(value) && value >= low && value <= high
        }
        if (!whole(choiceTurnId, 0, Number.MAX_SAFE_INTEGER) || !whole(blockIndex, 0, 5)
                || !whole(index, 0, AiState.CHOICE_INDEX_MAX) || typeof kind !== "string") return false
        if (!AiState.choiceResendable(turns, choiceTurnId)) return false
        var source = null
        for (var i = turns.length - 1; i >= 0 && !source; --i)
            if (turns[i] && turns[i].id === choiceTurnId) source = turns[i]
        var states = uiStates[String(choiceTurnId)]
        var prior = states ? states["act:" + blockIndex] : undefined
        if (turns[turns.length - 1].id === choiceTurnId && prior && typeof prior === "object"
                && typeof prior.picked === "number") return false
        var wire = AiState.choiceWire(source && source.blocks ? source.blocks[blockIndex] : null,
            choiceTurnId, blockIndex, kind, index)
        if (!wire) return false
        if (!AiState.supported(AiState.resolveAgent(agent, defaultAgent))) return false
        var marked = Object.assign({}, uiStates)
        var turnMap = Object.assign({}, marked[String(choiceTurnId)] || {})
        turnMap["act:" + blockIndex] = {picked: index}
        marked[String(choiceTurnId)] = turnMap
        if (!uiStatesFit(marked)) {
            stateNotice = "Too many saved edits to keep this change."
            return false
        }
        if (!sendTurn(AiState.CHOICE_PROMPT, {key: "choice", payload: wire, text: "Picked: " + wire.label,
                ref: {turnId: choiceTurnId, blockIndex: blockIndex, kind: kind, index: index}})) return false
        setUiState(choiceTurnId, "act:" + blockIndex, {picked: index})
        return true
    }

    function replaceLatest(event) {
        if (!turns.length) return
        var copy = turns.slice()
        copy[copy.length - 1] = AiState.updateTurn(copy[copy.length - 1], event)
        turns = copy
        if (conversationModel.count) conversationModel.setProperty(conversationModel.count - 1, "payload", copy[copy.length - 1])
    }

    // At a final event, a streamed prefix may have been shortened or replaced
    // by the whole-answer fallback: drop state for blocks that no longer exist.
    function pruneTurnUiState(turn) {
        var key = turn ? String(turn.id) : ""
        var state = key ? uiStates[key] : null
        if (!state) return
        var kept = AiState.pruneUiState(state, turn.blocks ? turn.blocks.length : 0, turn.blocks)
        if (kept === state) return
        var all = Object.assign({}, uiStates)
        if (Object.keys(kept).length) all[key] = kept
        else delete all[key]
        uiStates = all
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
        if (event.type === "done" && event.timing !== undefined) recordTiming(event.timing)
        if ((event.type === "done" || event.type === "presentation") && event.partial !== true)
            pruneTurnUiState(latest)
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
        if (busy || stopping || workspaceActionPending) return
        attachmentPreview.invalidate()
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
        // The finished conversation keeps its source (linked and saved above);
        // only this client's view of it is dropped.
        resetSource()
        turns = []
        conversationModel.clear()
        checklistStates = ({})
        uiStates = ({})
        stateNotice = ""
        focusTarget = null
        agent = ""
        sessionId = ""
        handoffHome = ""
        attachment = ""
        draft = ""
        turnId++
        workspaceId = ""
        workspaceName = ""
        workspaceActionError = ""
        resumeOnOpen = false
        latestRequested = true
        draftTouched = false
        refreshWorkspaceIndex()
    }

    function signIn(provider) {
        var command = AiState.signInCommand(provider)
        if (!command.length || busy) return false
        Quickshell.execDetached(command)
        return true
    }

    function continueInTerminal() {
        if (busy || workspaceActionPending) return false
        var command = AiState.handoffCommand(agent, sessionId, handoffHome, stateRoot)
        if (!command.length) return false
        Quickshell.execDetached(command)
        return true
    }

    // Adaptive explanation depth: a prose-only sidecar for the current
    // learning object, preserving blocks, controls, selection and values.
    // Never appends a turn and never rewrites the presented answer.
    function explainLatest(mode) {
        if (!latest || busy || loadingLatest || stopping || workspaceActionPending) return false
        var treatment = mode === "simpler" ? "simpler"
            : mode === "example" ? "another example" : "more depth"
        var blocks = latest.blocks || []
        var state = uiStates[String(latest.id)] || {}
        var parts = ["Requested: " + treatment]
        for (var i = 0; i < blocks.length; ++i) {
            var block = blocks[i]
            if (block && ["diagram", "slider", "steps", "check", "predict", "calc"].indexOf(block.type) >= 0) {
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
                } else if (block.type === "calc") {
                    AiState.calcDepthLines(block, state["calc:" + i]).forEach(function(line) { parts.push(line) })
                }
                break
            }
        }
        var context = parts.join("\n").slice(0, 800)
        busy = true
        stopping = false
        activity = "Adjusting depth…"
        var request = {op: "explain", turnId: turnId, agent: agent, prompt: context}
        if (sourceAppliesTo(latest.attachment)) request.sourceId = csvSource.sourceId
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
        onLoaded: service.defaultAgent = AiState.parseDefaultAgent(text())
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
            service.storeWorkerLost()
            // Only a queue with real work justifies a fresh interpreter; an
            // idle-exited worker must not be resurrected for no reason.
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
                if (service.workspaceTransitionPending) service.failWorkspaceAction(true)
                ++service.loadToken
                service.loadingLatest = false
                service.restoreSettled = true
            }
        }
    }

    // Also covers a worker that never starts (no in-flight request means the
    // existing worker-stall timer cannot observe it). No idle polling added.
    Timer {
        id: workspaceActionGuard
        interval: 10000
        onTriggered: service.workspaceActionTimedOut()
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
            service.storeWorkerLost()
            service.storeStallTick = 0
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
