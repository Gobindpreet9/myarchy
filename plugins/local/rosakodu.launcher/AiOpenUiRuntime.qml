import QtQuick
import Quickshell.Io

// One retained instance belongs to AiService, never to an answer/view Loader.
// All navigation must wait for !busy/drained before mount/unmount. A mount's
// identity includes workspace + turn + block. Save echoes are NOT new mounts.
Item {
    id: root

    property bool active: false
    property string identity: ""
    property var tree: null
    property var canonicalState: ({})
    property bool ready: false
    property string error: ""
    property string warning: ""
    readonly property int pending: _queue.length + (_inflight !== null ? 1 : 0) + (_loadQueued ? 1 : 0)
    readonly property bool busy: pending > 0

    signal acknowledged(string identity, var state)
    signal copyRequested(string text)
    signal drained()

    // Internal injection points, not settings or model-selected paths.
    property string helperScript: decodeURIComponent(Qt.resolvedUrl("ai_openui_runtime.py").toString().replace(/^file:\/\//, ""))
    property int requestTimeout: 5000
    property int idleInterval: 30000
    property int queueLimit: 32
    property int queueBytes: 131072
    property string _program: ""
    property string _token: ""
    property double _generation: 0
    property double _nextId: 0
    property var _queue: []
    property var _inflight: null
    property bool _loadQueued: false
    property bool _loaded: false
    property bool _complete: false
    property string _phase: "stopped"
    property bool _gotStart: false
    property bool _wasBusy: false
    readonly property var _kinds: ["Col", "Row", "Grid", "Card", "Box", "Divider", "Spacer", "Title", "Text", "Caption", "Label", "Badge", "Button", "IconButton", "Pressable", "Input", "TextArea", "Slider", "Checkbox", "Select", "SegmentedControl", "RadioGroup", "Icon", "Svg", "Circle", "Ellipse", "Rect", "Line", "Path", "Polyline", "Polygon", "G", "SvgText"]

    function _bytes(s) {
        if (typeof s !== "string") return 524289
        try { return encodeURIComponent(s).replace(/%[0-9A-F]{2}|[^%]/g, "x").length }
        catch (_) { return 524289 }
    }
    function _object(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }
    function _int(v) { return typeof v === "number" && isFinite(v) && Math.floor(v) === v && v > 0 && v <= 9007199254740991 }
    function _keys(v, required, optional) {
        if (!_object(v)) return false
        var keys = Object.keys(v)
        for (var i = 0; i < required.length; ++i)
            if (!Object.prototype.hasOwnProperty.call(v, required[i])) return false
        for (var j = 0; j < keys.length; ++j)
            if (required.indexOf(keys[j]) < 0 && optional.indexOf(keys[j]) < 0) return false
        return true
    }
    function _json(v, limit) {
        var count = 0
        function visit(value, depth) {
            if (++count > 32768 || depth > 64) return false
            if (value === null || typeof value === "boolean") return true
            if (typeof value === "number") return isFinite(value)
            if (typeof value === "string") return root._bytes(value) <= limit
            if (typeof value !== "object") return false
            var keys = Object.keys(value)
            for (var i = 0; i < keys.length; ++i) {
                var key = keys[i]
                if (key === "__proto__" || key === "constructor" || key === "prototype" || root._bytes(key) > 4096
                        || !visit(value[key], depth + 1)) return false
            }
            return true
        }
        try { return visit(v, 0) } catch (_) { return false }
    }
    function _state(v) {
        if (!_object(v) || Object.keys(v).length > 40 || !_json(v, 65536)) return false
        try { return _bytes(JSON.stringify(v)) <= 65536 } catch (_) { return false }
    }
    function _tree(v) {
        var count = 0
        function visit(node, path, depth) {
            if (++count > 512 || depth > 64 || !root._keys(node, ["id", "kind", "props", "children"], [])
                    || node.id !== path || root._bytes(node.id) > 512 || root._kinds.indexOf(node.kind) < 0
                    || !root._object(node.props) || !Array.isArray(node.children) || node.children.length > 512) return false
            var keys = Object.keys(node.props)
            for (var i = 0; i < keys.length; ++i) {
                var key = keys[i]
                if (key === "__proto__" || key === "constructor" || key === "prototype" || root._bytes(key) > 4096
                        || !root._json(node.props[key], node.kind === "TextArea" && key === "value" ? 32768 : 4096)) return false
            }
            for (var j = 0; j < node.children.length; ++j)
                if (!visit(node.children[j], path + "/" + j, depth + 1)) return false
            return true
        }
        try { return visit(v, "root", 0) } catch (_) { return false }
    }

    function mount(key, program, state) {
        if (typeof key !== "string" || !key || _bytes(key) > 1024 || typeof program !== "string"
                || !program.trim() || _bytes(program) > 32768) return false
        // Intentionally ignore ALL state echoes for this identity+code, even
        // while awaiting an acknowledgement. They can be older autosaves.
        if (identity === key && _program === program) return true
        if (busy) return false
        var saved
        try {
            if (!_state(state)) return false
            saved = JSON.parse(JSON.stringify(state))
            if (!_state(saved)) return false
        } catch (_) { return false }
        _halt()
        _generation += 1
        _token = "mount-" + Date.now() + "-" + _generation
        identity = key
        _program = program
        canonicalState = saved
        tree = null
        ready = false
        error = ""
        warning = ""
        _loaded = false
        if (active) _scheduleLoad()
        return true
    }

    function unmount() {
        if (busy) return false
        _halt()
        _generation += 1
        _token = ""
        identity = ""
        _program = ""
        tree = null
        canonicalState = ({})
        ready = false
        error = ""
        warning = ""
        _loaded = false
        return true
    }

    function refuse(message, saved) {
        // The host's aggregate save budget can be smaller than one worker's
        // state budget. Never keep displaying an edit that cannot be persisted.
        _fail(message)
        tree = null
        if (_state(saved)) canonicalState = JSON.parse(JSON.stringify(saved))
    }

    function _node(target) {
        if (typeof target !== "string" || _bytes(target) > 512 || !/^root(?:\/[0-9]{1,3})*$/.test(target)) return null
        var parts = target.split("/")
        var node = tree
        for (var i = 1; node && i < parts.length; ++i) node = node.children[Number(parts[i])]
        return node && node.id === target ? node : null
    }

    function dispatch(target, event, value) {
        if (!identity || !ready || !active || (event !== "change" && event !== "click")) return false
        var node = _node(target)
        if (!node || node.props.disabled === true) return false
        var job = {op: "event", target: target, event: event}
        if (typeof node.props._openuiHandle !== "string") return false
        job.handle = node.props._openuiHandle
        if (event === "change") {
            if (["Input", "TextArea", "Slider", "Checkbox", "Select", "SegmentedControl", "RadioGroup"].indexOf(node.kind) < 0
                    || !(value === null || typeof value === "string" || typeof value === "boolean" || typeof value === "number")
                    || !_json(value, node.kind === "TextArea" ? 32768 : 4096)) return false
            job.value = value
        } else {
            if (["Button", "IconButton", "Pressable"].indexOf(node.kind) < 0 || node.props.hasAction !== true
                    || !(value === undefined || value === null)) return false
        }
        var queue = _queue.slice()
        // Only adjacent, not-yet-written changes to the SAME target commute.
        // Never move a change across a click or another reactive control.
        var tail = queue.length ? queue[queue.length - 1] : null
        if (tail && event === "change" && tail.event === "change" && tail.target === target) queue[queue.length - 1] = job
        else queue.push(job)
        if (queue.length > Math.max(1, Math.min(32, queueLimit)) || _bytes(JSON.stringify(queue)) > Math.max(32768, Math.min(131072, queueBytes))) {
            error = "Too many UI changes. Wait for the current changes to finish."
            return false
        }
        error = ""
        _queue = queue
        if (!_loaded && !_loadQueued && _inflight === null) _loadQueued = true
        _pump()
        return true
    }

    function _scheduleLoad() {
        if (!identity || !active || _loaded || _loadQueued || (_inflight && _inflight.op === "load")) return
        _loadQueued = true
        _pump()
    }

    function _pump() {
        if (!_complete || _inflight !== null || (!_loadQueued && !_queue.length)) return
        idleTimer.stop()
        if (_phase === "stopped") {
            _phase = "starting"
            _gotStart = false
            watchdog.restart() // failed start must not leave queued work idle
            worker.running = true
            return
        }
        if (_phase !== "running") return
        var job
        if (_loadQueued) {
            job = {op: "load", program: _program, state: canonicalState}
            _loadQueued = false
        } else {
            var queue = _queue.slice()
            while (queue.length) {
                job = queue.shift()
                var current = _node(job.target)
                if (current && current.props.disabled !== true && current.props._openuiHandle === job.handle) break
                warning = "The tool changed. Review it before trying that action again."
                job = null
            }
            _queue = queue
            if (!job) { _armIdle(); return }
        }
        if (_nextId >= 9007199254740991) { _fail("UI runtime is unavailable."); return }
        job.id = ++_nextId
        job.token = _token
        _inflight = job
        var line = JSON.stringify(job) + "\n"
        if (_bytes(line) > 524288) { _fail("UI runtime returned an invalid response."); return }
        watchdog.restart()
        worker.write(line)
    }

    function _safeError(code) {
        if (code === "runtime_timeout") return "UI runtime timed out. Reopen this answer to retry."
        if (code === "invalid_program" || code === "unsupported_action") return "This interactive answer could not be shown."
        if (code === "limit_exceeded") return "This interactive answer exceeds the runtime limits."
        if (code === "invalid_event") return "This UI change could not be applied."
        if (code === "invalid_response") return "UI runtime returned an invalid response."
        return "UI runtime is unavailable. Reopen this answer to retry."
    }

    function receive(line) {
        if (_phase !== "running") return
        var reply
        try {
            if (_bytes(line) + 1 > 524288) throw new Error()
            reply = JSON.parse(line)
            if (!_object(reply) || !_int(reply.id) || typeof reply.token !== "string" || !reply.token || _bytes(reply.token) > 128) throw new Error()
            if (reply.token !== _token) return // late response cannot touch a newer mount
            if (!_inflight || reply.id !== _inflight.id) throw new Error()
            if (reply.ok === false) {
                var errors = ["invalid_request", "invalid_program", "limit_exceeded", "stale_token", "not_loaded", "invalid_event", "unsupported_action", "runtime_error", "runtime_unavailable", "runtime_timeout", "invalid_response", "runtime_stopped"]
                if (!_keys(reply, ["id", "token", "ok", "error"], []) || errors.indexOf(reply.error) < 0) throw new Error()
                _fail(_safeError(reply.error))
                return
            }
            if (reply.ok !== true || !_keys(reply, ["id", "token", "ok", "tree", "state"], ["warning", "copyText"])
                    || !_state(reply.state) || !_tree(reply.tree)
                    || (reply.warning !== undefined && reply.warning !== "Some values could not be calculated.")
                    || (reply.copyText !== undefined && (typeof reply.copyText !== "string" || _bytes(reply.copyText) > 32768
                        || _inflight.op !== "event" || _inflight.event !== "click"))) throw new Error()
        } catch (_) { _fail("UI runtime returned an invalid response."); return }
        watchdog.stop()
        _loaded = true
        tree = reply.tree
        canonicalState = reply.state
        ready = true // stays true during subsequent event acknowledgements
        error = ""
        warning = reply.warning || ""
        // Emit while busy is still true: a navigation callback must wait for
        // drained, and an autosave echo cannot remount the current program.
        acknowledged(identity, JSON.parse(JSON.stringify(canonicalState)))
        if (_inflight === null) return // host refused the acknowledged state
        if (reply.copyText !== undefined) copyRequested(reply.copyText)
        _inflight = null
        _pump()
        _armIdle()
    }

    function _fail(message) {
        watchdog.stop()
        _queue = []
        _loadQueued = false
        _inflight = null
        _loaded = false
        ready = false
        error = message
        _halt()
    }

    function _started() {
        if (_phase !== "starting") { _signalStop(); return }
        _gotStart = true
        _phase = "running"
        watchdog.stop()
        _pump()
        _armIdle()
    }
    function _signalStop() {
        // TERM lets the guardian reap Node's whole group. Never signal PID 0.
        if (Number(worker.processId) > 0) worker.signal(15)
        else worker.running = false
    }
    function _halt() {
        idleTimer.stop()
        _loaded = false
        if (_phase === "stopped" || _phase === "stopping") return
        _phase = "stopping"
        haltGuard.restart()
        _signalStop()
    }
    function _exited() {
        var expected = _phase === "stopping"
        haltGuard.stop()
        watchdog.stop()
        _phase = "stopped"
        _gotStart = false
        _loaded = false
        if (!expected && busy) { _fail("UI runtime stopped before confirming the changes."); return }
        if (!expected && identity && ready) {
            // The canonical tree remains usable; the next local event cold-
            // loads its last acknowledged state before sending that event.
            error = ""
        }
        if (busy) Qt.callLater(root._pump)
    }
    function _armIdle() {
        if (!active && !busy && (_phase === "starting" || _phase === "running")) idleTimer.restart()
        else idleTimer.stop()
    }
    onActiveChanged: {
        if (active && identity && !error) _scheduleLoad()
        _armIdle()
    }
    onBusyChanged: {
        if (busy) _wasBusy = true
        else if (_wasBusy) {
            _wasBusy = false
            // A queue head transition must not emit a false drain. Deferred
            // emission observes the complete synchronous acknowledgement pump.
            Qt.callLater(function() { if (!root.busy) root.drained() })
        }
    }
    Component.onCompleted: { _complete = true; _pump() }
    Component.onDestruction: _signalStop()

    property Timer _watchdog: Timer {
        id: watchdog
        interval: Math.max(1, Math.min(5000, root.requestTimeout))
        onTriggered: root._fail("UI runtime timed out. Reopen this answer to retry.")
    }
    property Timer _idle: Timer {
        id: idleTimer
        interval: Math.max(1, Math.min(30000, root.idleInterval))
        onTriggered: { if (!root.active && !root.busy) root._halt() }
    }
    property Timer _haltGuard: Timer {
        id: haltGuard
        interval: 1500
        onTriggered: {
            // Linux PDEATHSIG + denied child-process permission is the final
            // fallback if the Python guardian itself stopped responding.
            if (root._phase === "stopping" && Number(worker.processId) > 0) worker.signal(9)
        }
    }
    property Process _worker: Process {
        id: worker
        command: ["/usr/bin/python3", "-I", "-B", "-u", root.helperScript, "--serve"]
        stdinEnabled: true
        clearEnvironment: true
        environment: ({PATH: "/usr/bin:/bin", LANG: "C.UTF-8"})
        stdout: SplitParser { onRead: function(line) { root.receive(line) } }
        // Never collect or expose helper/Node stderr.
        onStarted: root._started()
        onExited: root._exited()
        onRunningChanged: {
            if (!running) Qt.callLater(function() {
                if (root._phase === "starting" && !root._gotStart && !worker.running) root._exited()
            })
        }
    }
}
