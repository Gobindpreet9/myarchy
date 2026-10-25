import QtQuick
import Quickshell
import Quickshell.Io
import "CsvPage.js" as CsvPage

// Retained, non-visual client of the durable CSV source worker
// (`ai_csv_source.py --root <stateRoot> --serve`, one JSON line per request and
// response, strictly ordered, ids echoed). Mirrors AiAttachmentPreview: a token
// bumped by every invalidation discards late responses, a response is applied
// at most once, and error text is always static (CsvPage.safeError).
//
// Lifecycle: no process until the first request; one worker serves the whole
// session through an always-open stdin (stdinEnabled is never toggled) and a
// SplitParser stdout. A timer stops it `idleInterval` after the owner marks all
// surfaces hidden. A crashed or hung worker fails its in-flight requests with a
// static retryable error and restarts for work that was still queued. The
// worker re-opens a source lazily: view/page requests to a fresh process are
// preceded by an internal `open`.
Item {
    id: root

    // Writable injection points (tests point them at the stub).
    property string workerScript: decodeURIComponent(Qt.resolvedUrl("ai_csv_source.py").toString().replace(/^file:\/\//, ""))
    property string stateRoot: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/launcher-ai"
    property string interpreter: "/usr/bin/python3"
    property string workerIdle: ""        // test override for LAUNCHER_CSV_IDLE (seconds)
    property int debounceInterval: 250
    property int idleInterval: 30000
    property int registerTimeout: 60000   // inactivity: progress events re-arm it
    property int requestTimeout: 10000
    property int pageTimeout: 5000

    // Owner state: true while any surface that shows the explorer is visible.
    property bool surfacesVisible: false

    // "idle" | "registering" (register or open in flight) | "ready" | "error".
    // `error` may also be set while "ready": the last view/page/verify failed.
    property string status: "idle"
    property int progressRows: 0
    property var meta: null               // validated register/open response
    property var page: null               // validated current page
    property int viewRows: -1             // -1 until the first view settles
    property string sourceId: ""
    property string verifyState: ""       // "" until a verify answered
    property string error: ""
    property bool retryable: false
    property double token: 0
    property int generation: 0
    property bool viewPending: false      // debounce running or view in flight
    readonly property bool busy: _jobCount > 0 || viewPending

    // The worker finished a register (it holds a complete src-* copy) but the
    // reply fails validation, so this client will not use it. The owner decides
    // whether to remove the copy; the id is a validated one. (An abandoned
    // register never gets here: invalidate() kills the worker instead.)
    signal registerDiscarded(string sourceId)

    property var _jobs: []
    property int _jobCount: 0
    property var _opened: ({})
    property string _phase: "stopped"     // stopped | starting | running | stopping
    property bool _gotStart: false
    property int _nextId: 0
    property int _pageSeq: 0
    property int _targetPage: 0
    property var _viewParams: ({sort: -1, dir: 1, filter: ""})

    // ---- public interface ---------------------------------------------------

    function register(path) {
        invalidate()
        if (!CsvPage.validPath(path)) { _fatal(CsvPage.ERR.path, false); return false }
        status = "registering"
        if (_submit("register", {path: path}, {timeout: registerTimeout}) === null) {
            _fatal(CsvPage.ERR.path, false)
            return false
        }
        return true
    }

    function open(id) {
        invalidate()
        if (!CsvPage.validSourceId(id)) { _fatal(CsvPage.ERR.unavailable, false); return false }
        status = "registering"
        return _submit("open", {sourceId: id}, {timeout: requestTimeout, sourceId: id}) !== null
    }

    // Answers the "verify" state for `id` (default: the current source).
    function verify(id) {
        var target = id === undefined ? sourceId : id
        if (!CsvPage.validSourceId(target)) return false
        verifyState = ""
        return _submit("verify", {sourceId: target}, {timeout: requestTimeout}) !== null
    }

    // Also the retry for a failed view: repeat the same arguments.
    function setView(sort, dir, filter) {
        if (status !== "ready" || !meta) return false
        if (!CsvPage.isInt(sort, -1, meta.columns.length - 1) || (dir !== 1 && dir !== -1)) return false
        _viewParams = {sort: sort, dir: dir, filter: CsvPage.cleanFilter(filter)}
        generation += 1
        _targetPage = 0
        viewPending = true
        debounce.restart()
        return true
    }

    function goPage(n) {
        if (status !== "ready" || !meta || !CsvPage.isInt(n, 0, 9007199254740991)) return false
        _targetPage = n
        if (viewPending) return true      // applied (clamped) once the view settles
        if (viewRows < 0) return false
        _sendPage(CsvPage.clampPage(n, CsvPage.pageCountFor(viewRows)))
        return true
    }

    // Tell the worker to forget the current source (only if it is running),
    // then invalidate. Never starts a process.
    function close() {
        if (sourceId && _phase === "running" && _opened[sourceId])
            _submit("close", {sourceId: sourceId}, {timeout: requestTimeout, sourceId: sourceId})
        invalidate()
    }

    // Path/workspace/new-chat/restore switch: drop state, discard late answers.
    function invalidate() {
        token += 1
        generation += 1
        debounce.stop()
        status = "idle"
        meta = null
        page = null
        viewRows = -1
        sourceId = ""
        verifyState = ""
        error = ""
        retryable = false
        progressRows = 0
        viewPending = false
        _targetPage = 0
        _viewParams = {sort: -1, dir: 1, filter: ""}
        var abandonIndex = false
        var kept = []
        for (var k = 0; k < _jobs.length; ++k) {
            if (_jobs[k].written || _jobs[k].op === "close") kept.push(_jobs[k])
            if (_jobs[k].written && _jobs[k].op === "register") abandonIndex = true
        }
        // A stale index would block the strictly ordered worker for its whole
        // duration: kill it instead of waiting.
        _jobs = abandonIndex ? [] : kept
        _syncJobs()
        _rearmWatchdog()
        if (abandonIndex) _halt()
    }

    // invalidate() and kill the worker now.
    function stop() {
        invalidate()
        _jobs = []
        restartTimer.stop()
        _syncJobs()
        _halt()
    }

    // ---- requests -------------------------------------------------------------

    function _makeJob(op, fields, opts) {
        var id = ++_nextId
        var line = CsvPage.requestLine(id, op, fields)
        if (line === null) return null
        return {id: id, op: op, fields: fields, line: line, token: token,
            gen: opts.gen === undefined ? -1 : opts.gen, seq: opts.seq || 0,
            sourceId: opts.sourceId || "", needsOpen: !!opts.needsOpen, internal: !!opts.internal,
            timeout: opts.timeout, written: false, retried: false}
    }

    function _submit(op, fields, opts) {
        var job = _makeJob(op, fields, opts)
        if (job === null) return null
        _jobs.push(job)
        _syncJobs()
        if (_jobs[0] === job) _rearmWatchdog()
        _pump()
        _armIdle()
        return job
    }

    function _syncJobs() { _jobCount = _jobs.length }

    function _dropUnwritten(ops) {
        _jobs = _jobs.filter(function(j) { return j.written || ops.indexOf(j.op) < 0 })
        _syncJobs()
    }

    function _sendView() {
        var p = _viewParams
        _dropUnwritten(["view", "page"])
        if (_submit("view", {sourceId: sourceId, sort: p.sort, dir: p.dir, filter: p.filter, gen: generation},
                {gen: generation, needsOpen: true, sourceId: sourceId, timeout: requestTimeout}) === null) {
            viewPending = false
            error = CsvPage.ERR.unavailable
            retryable = false
        }
    }

    function _sendPage(n) {
        var seq = ++_pageSeq
        _dropUnwritten(["page"])
        if (_submit("page", {sourceId: sourceId, page: n, gen: generation},
                {gen: generation, seq: seq, needsOpen: true, sourceId: sourceId, timeout: pageTimeout}) === null) {
            error = CsvPage.ERR.unavailable
            retryable = false
        }
    }

    function _debounced() {
        if (viewPending && status === "ready" && meta) _sendView()
    }

    function _hasUnwritten() {
        for (var k = 0; k < _jobs.length; ++k) if (!_jobs[k].written) return true
        return false
    }

    function _viewInFlight() {
        for (var k = 0; k < _jobs.length; ++k) if (_jobs[k].written && _jobs[k].op === "view") return true
        return false
    }

    // Writes unwritten jobs in order; the worker answers them in order. The
    // worker aborts a running view ("Superseded.") when ANY request is queued
    // behind it, so only a newer view may follow one: everything else waits
    // for the view's answer (receive() pumps again). A job that needs its
    // source gets an internal open on a fresh process, plus the current view
    // re-applied before a page, because a new worker has neither.
    function _pump() {
        if (_phase === "stopped") { if (_hasUnwritten()) _startWorker(); return }
        if (_phase !== "running") return
        for (var k = 0; k < _jobs.length; ++k) {
            var job = _jobs[k]
            if (job.written) continue
            if (job.op !== "view" && _viewInFlight()) break
            if (job.needsOpen && !_opened[job.sourceId]) {
                var prefix = [_makeJob("open", {sourceId: job.sourceId},
                    {internal: true, sourceId: job.sourceId, timeout: requestTimeout})]
                if (job.op === "page") {
                    var p = _viewParams
                    prefix.push(_makeJob("view", {sourceId: job.sourceId, sort: p.sort, dir: p.dir, filter: p.filter, gen: job.gen},
                        {internal: true, gen: job.gen, sourceId: job.sourceId, timeout: requestTimeout}))
                }
                _opened[job.sourceId] = true
                for (var i = 0; i < prefix.length; ++i) {
                    if (prefix[i] === null) continue
                    prefix[i].token = job.token
                    prefix[i].written = true
                    _jobs.splice(k, 0, prefix[i])
                    worker.write(prefix[i].line)
                    ++k
                }
                if (job.op !== "view" && _viewInFlight()) break
            }
            job.written = true
            worker.write(job.line)
        }
        _syncJobs()
    }

    // ---- process lifecycle ------------------------------------------------------

    function stopWorker() {
        // Quickshell exposes a Process before QProcess has a PID. Never signal
        // PID 0: that would signal the shell's entire process group.
        if (Number(worker.processId) > 0) worker.signal(9)
        else worker.running = false
    }

    function _startWorker() {
        if (_phase !== "stopped") return
        _phase = "starting"
        _gotStart = false
        worker.running = true
    }

    function _halt() {
        if (_phase === "stopped" || _phase === "stopping") return
        _phase = "stopping"
        idleTimer.stop()
        haltGuard.restart()
        stopWorker()
    }

    function _started() {
        if (_phase !== "starting") { stopWorker(); return }
        _gotStart = true
        _phase = "running"
        _pump()
        _armIdle()
    }

    // `clean` is true for an exit code 0 that was not our own kill: the worker's
    // idle or EOF exit, which may race one request written a moment before it.
    function _exited(clean) {
        haltGuard.stop()
        var requested = _phase === "stopping"
        var started = _gotStart
        var jobs = _jobs
        _jobs = []
        _phase = "stopped"
        _gotStart = false
        _opened = ({})
        var kept = []
        for (var k = 0; k < jobs.length; ++k) {
            var job = jobs[k]
            if (!started) _jobFailed(job, CsvPage.ERR.start)
            else if (!job.written) kept.push(job)
            else if (clean === true && !requested && !job.retried && !job.internal) {
                job.retried = true
                job.written = false
                kept.push(job)
            } else if (!job.internal) _jobFailed(job, CsvPage.ERR.stopped)
        }
        _jobs = kept
        _syncJobs()
        _rearmWatchdog()
        _armIdle()
        if (kept.length) restartTimer.start()
    }

    function _armIdle() {
        if (!surfacesVisible && (_phase === "running" || _phase === "starting")) idleTimer.restart()
        else idleTimer.stop()
    }

    function _idleFired() {
        if (surfacesVisible || _phase !== "running") return
        if (_jobs.length) { _armIdle(); return }
        _halt()
    }

    function _rearmWatchdog() {
        if (!_jobs.length) { watchdog.stop(); return }
        watchdog.interval = Math.max(1, _jobs[0].timeout)
        watchdog.restart()
    }

    function _watchdogFired() {
        if (!_jobs.length) return
        var jobs = _jobs
        _jobs = []
        var kept = []
        for (var k = 0; k < jobs.length; ++k) {
            if (jobs[k].written) { if (!jobs[k].internal) _jobFailed(jobs[k], CsvPage.ERR.timeout) }
            else kept.push(jobs[k])
        }
        _jobs = kept
        _syncJobs()
        if (_phase === "stopped") {
            // Never started and no exit coming: nothing to wait for.
            for (var j = 0; j < kept.length; ++j) _jobFailed(kept[j], CsvPage.ERR.start)
            _jobs = []
            _syncJobs()
            return
        }
        _halt()
    }

    // ---- responses --------------------------------------------------------------

    function _protocolViolation() {
        var jobs = _jobs
        _jobs = []
        var kept = []
        for (var k = 0; k < jobs.length; ++k) {
            if (jobs[k].written) { if (!jobs[k].internal) _jobFailed(jobs[k], CsvPage.ERR.invalid) }
            else kept.push(jobs[k])
        }
        _jobs = kept
        _syncJobs()
        _halt()
    }

    function receive(line) {
        var parsed = CsvPage.parseResponse(line)
        if (parsed.response === null) { _protocolViolation(); return }
        var resp = parsed.response
        var head = _jobs.length && _jobs[0].written ? _jobs[0] : null
        if (head === null || resp.id !== head.id) {
            // A late answer to a job already failed or discarded is ignored; an
            // answer that skips the queue means the stream cannot be trusted.
            var known = false
            for (var k = 0; k < _jobs.length; ++k) if (_jobs[k].written && _jobs[k].id === resp.id) known = true
            if (known) _protocolViolation()
            return
        }
        if (resp.event !== undefined) {
            if (head.op === "register" && CsvPage.validProgress(resp)) {
                if (_isCurrent(head) && status === "registering" && resp.rows > progressRows) progressRows = resp.rows
                _rearmWatchdog()
            } else _protocolViolation()
            return
        }
        _jobs.shift()
        _syncJobs()
        _rearmWatchdog()
        _complete(head, resp)
        _pump()
        _armIdle()
    }

    function _isCurrent(job) {
        if (job.token !== token) return false
        if (job.op === "view") return job.gen === generation
        if (job.op === "page") return job.gen === generation && job.seq === _pageSeq
        return true
    }

    function _complete(job, resp) {
        if (job.op === "close") return
        if (job.internal) {
            if (resp.ok !== true) {
                var failure = CsvPage.safeError(resp.error)
                if (job.op === "open") delete _opened[job.sourceId]
                // A superseded re-applied view means a newer one is already queued.
                if (job.token === token && !(job.op === "view" && failure === CsvPage.ERR.superseded))
                    _applyFailure(job, failure, CsvPage.isRetryable(failure), false)
            }
            return
        }
        if (!_isCurrent(job)) return
        if (resp.ok === false) {
            var text = CsvPage.safeError(resp.error)
            _applyFailure(job, text, CsvPage.isRetryable(text), false)
            return
        }
        if (resp.ok !== true) { _applyFailure(job, CsvPage.ERR.invalid, true, false); return }
        if (job.op === "register" || job.op === "open") {
            var m = CsvPage.validateMeta(resp)
            if (m === null || (job.op === "open" && m.sourceId !== job.sourceId)) {
                if (job.op === "register" && CsvPage.validSourceId(resp.sourceId)) registerDiscarded(resp.sourceId)
                _applyFailure(job, CsvPage.ERR.invalid, true, false)
                return
            }
            _acceptMeta(m)
        } else if (job.op === "view") {
            var v = CsvPage.validateView(resp)
            if (v === null || v.gen !== job.gen || !meta || v.viewRows > meta.rows) {
                _applyFailure(job, CsvPage.ERR.invalid, true, false)
                return
            }
            viewRows = v.viewRows
            viewPending = false
            error = ""
            retryable = false
            _sendPage(CsvPage.clampPage(_targetPage, CsvPage.pageCountFor(viewRows)))
        } else if (job.op === "page") {
            var p = CsvPage.validatePage(resp, {columnCount: meta ? meta.columns.length : undefined, viewRows: viewRows})
            if (p === null || p.gen !== job.gen || p.page !== job.fields.page) {
                _applyFailure(job, CsvPage.ERR.invalid, true, false)
                return
            }
            page = p
            error = ""
            retryable = false
        } else if (job.op === "verify") {
            var s = CsvPage.validateVerify(resp)
            if (s === null) { _applyFailure(job, CsvPage.ERR.invalid, true, false); return }
            verifyState = s.state
        }
    }

    function _acceptMeta(m) {
        meta = m
        sourceId = m.sourceId
        progressRows = m.rows
        _opened[m.sourceId] = true
        error = ""
        retryable = false
        verifyState = ""
        page = null
        viewRows = -1
        _targetPage = 0
        _viewParams = {sort: -1, dir: 1, filter: ""}
        status = "ready"
        generation += 1
        viewPending = true
        _sendView()
    }

    function _jobFailed(job, message) {
        if (job.op === "close" || !_isCurrent(job)) return
        _applyFailure(job, message, CsvPage.isRetryable(message), true)
    }

    function _applyFailure(job, text, retry, transport) {
        if ((job.op === "register" || job.op === "open") && !(job.internal && transport)) {
            _fatal(text, retry)
            return
        }
        error = text
        retryable = retry
        if (job.op === "view" && !job.internal) viewPending = false
    }

    function _fatal(text, retry) {
        debounce.stop()
        status = "error"
        error = text
        retryable = retry
        meta = null
        page = null
        viewRows = -1
        sourceId = ""
        viewPending = false
        progressRows = 0
    }

    onSurfacesVisibleChanged: _armIdle()

    // Explicit object properties keep helper objects out of Item's default
    // data property (same shape as AiAttachmentPreview).
    property Timer _watchdog: Timer {
        id: watchdog
        onTriggered: root._watchdogFired()
    }
    property Timer _debounce: Timer {
        id: debounce
        interval: Math.max(1, root.debounceInterval)
        onTriggered: root._debounced()
    }
    property Timer _idle: Timer {
        id: idleTimer
        interval: Math.max(1, root.idleInterval)
        onTriggered: root._idleFired()
    }
    // Restarts the worker for work that was still queued when it went away.
    property Timer _restart: Timer {
        id: restartTimer
        interval: 60
        onTriggered: root._pump()
    }
    // A kill that never produces an exit signal must not wedge the lifecycle.
    property Timer _guard: Timer {
        id: haltGuard
        interval: 1500
        onTriggered: if (root._phase === "stopping") root._exited(false)
    }

    property Process _worker: Process {
        id: worker
        command: [root.interpreter, "-B", "-u", root.workerScript, "--root", root.stateRoot, "--serve"]
        // Always open and never toggled after the first start: re-setting it
        // would send EOF into a worker that is expected to persist.
        stdinEnabled: true
        clearEnvironment: true
        environment: {
            var env = {HOME: Quickshell.env("HOME"), PATH: "/usr/bin:/bin", PYTHONDONTWRITEBYTECODE: "1"}
            if (root.workerIdle) env.LAUNCHER_CSV_IDLE = root.workerIdle
            return env
        }
        stdout: SplitParser { onRead: function(line) { root.receive(line) } }
        // stderr is neither collected nor exposed (it may carry file paths).
        onStarted: root._started()
        onExited: function(code, exitStatus) { root._exited(code === 0 && exitStatus === 0) }
        onRunningChanged: {
            if (!running) Qt.callLater(function() {
                if (root._phase === "starting" && !root._gotStart && !worker.running) root._exited(false)
            })
        }
    }
}
