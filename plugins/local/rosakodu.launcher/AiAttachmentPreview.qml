import QtQuick
import Quickshell
import Quickshell.Io

// Retained, local-only reader. Surface visibility grants permission to START
// work; hiding a surface never discards an already-started read or its result.
Item {
    id: root

    property string path: ""
    property bool activeSurface: false
    property bool restoring: false
    // Writable internal injection points, not provider/user configuration.
    property string scriptPath: decodeURIComponent(Qt.resolvedUrl("ai_attachment_preview.py").toString().replace(/^file:\/\//, ""))
    property int watchdogInterval: 5000
    property string status: "idle"
    property var data: null
    property string error: ""
    property double token: 0
    readonly property bool isCsv: /\.csv$/i.test(path)
    readonly property bool pathMatch: _resultPath === path && _resultToken === token
    readonly property bool blocked: isCsv && !(status === "ready" && pathMatch)

    property bool _complete: false
    property bool _occupied: false
    property bool _started: false
    property bool _terminal: true
    property string _runPath: ""
    property double _runToken: -1
    property string _resultPath: ""
    property double _resultToken: -1
    property int _stdoutOffset: 0

    function bytes(text) {
        try { return encodeURIComponent(text).replace(/%[0-9A-F]{2}|[^%]/g, "x").length }
        catch (_) { return 32769 }
    }

    function reset() { invalidate() }
    function retry() { invalidate() }
    function invalidate() {
        token += 1
        _terminal = true
        watchdog.stop()
        _resultPath = ""
        _resultToken = -1
        data = null
        error = ""
        status = "idle"
        // Keep the process slot occupied until exited, not merely until the
        // requested running flag changes. Otherwise an old exit can kill a retry.
        if (_occupied && worker.running) stopWorker()
        Qt.callLater(root.startIfEligible)
    }

    function currentRun() {
        return _occupied && !_terminal && _runToken === token && _runPath === path && !restoring
    }

    function stopWorker() {
        // Quickshell exposes a Process before QProcess has a PID. Never send
        // signal(9) to PID 0: that would signal the shell's entire process group.
        if (Number(worker.processId) > 0) worker.signal(9)
        else worker.running = false
    }

    function fail(message) {
        if (!currentRun()) return
        _terminal = true
        watchdog.stop()
        data = null
        error = message
        status = "error"
        if (worker.running) stopWorker()
    }

    function startIfEligible() {
        if (!_complete || _occupied || !activeSurface || restoring || !isCsv || status !== "idle") return
        _runPath = path
        _runToken = token
        _occupied = true
        _started = false
        _terminal = false
        _stdoutOffset = 0
        status = "loading"
        var request = JSON.stringify({token: _runToken, path: _runPath}) + "\n"
        if (path.length > 4096 || bytes(request) > 8192) {
            fail("Choose a CSV file inside your home directory.")
            _occupied = false
            return
        }
        watchdog.restart()
        worker.running = true
    }

    function integer(value, maximum) {
        return typeof value === "number" && isFinite(value) && Math.floor(value) === value
            && value >= 0 && value <= maximum
    }

    function validPreview(p) {
        if (!p || typeof p !== "object" || Array.isArray(p) || p.kind !== "csv"
                || !Array.isArray(p.columns) || !Array.isArray(p.rows)
                || p.columns.length < 1 || p.columns.length > 20 || p.rows.length > 10
                || p.columns.length * p.rows.length > 200
                || !integer(p.previewRows, 10) || p.previewRows !== p.rows.length
                || !integer(p.sampleRows, 200) || p.sampleRows < p.previewRows
                || !integer(p.columnCount, 9007199254740991) || p.columnCount < p.columns.length
                || !(p.totalRows === null || (integer(p.totalRows, 9007199254740991) && p.totalRows >= p.sampleRows))
                || typeof p.truncated !== "boolean" || typeof p.columnsTruncated !== "boolean"
                // The sampler composes its note from at most four fixed
                // sentences (~265 chars worst case); 300 leaves digit slack.
                // A longer note is producer/validator drift and must not
                // silently inflate the disclosure past the peek-card budget.
                || typeof p.cellsTruncated !== "boolean" || typeof p.note !== "string" || p.note.length > 300)
            return false
        if (p.previewRows !== Math.min(10, p.sampleRows)
                || p.columns.length !== Math.min(20, p.columnCount)
                || p.columnsTruncated !== (p.columnCount > 20)
                || p.truncated !== (p.totalRows === null || p.sampleRows < p.totalRows
                    || p.columnsTruncated || p.cellsTruncated)) return false
        // The sampler bounds Unicode codepoints to 80 (up to 160 UTF-16 units).
        function cell(value) {
            if (typeof value !== "string" || value.length > 160) return false
            var count = 0
            for (var k = 0; k < value.length; ++k) {
                var c = value.charCodeAt(k)
                if (c >= 0xd800 && c <= 0xdbff) {
                    if (k + 1 >= value.length || value.charCodeAt(k + 1) < 0xdc00
                            || value.charCodeAt(k + 1) > 0xdfff) return false
                    ++k
                } else if (c >= 0xdc00 && c <= 0xdfff) return false
                if (++count > 80) return false
            }
            return true
        }
        for (var c = 0; c < p.columns.length; ++c) if (!cell(p.columns[c])) return false
        for (var r = 0; r < p.rows.length; ++r) {
            if (!Array.isArray(p.rows[r]) || p.rows[r].length !== p.columns.length) return false
            for (var j = 0; j < p.rows[r].length; ++j) if (!cell(p.rows[r][j])) return false
        }
        return true
    }

    function safeError(message) {
        var known = ["Choose a text file inside your home directory.", "Attachment must be inside your home directory.",
            "Invalid attachment path.", "Credential and secret files cannot be attached.",
            "Attachment must be a text file smaller than 64 KiB.", "Attachment is unavailable or is a symbolic link.",
            "Attachment is too large or is binary.", "Attachment must be UTF-8 text.", "Attachment is binary.",
            "CSV attachment is empty.", "CSV header could not be parsed.", "CSV header exceeds the read window.",
            "CSV attachment has no header row.", "CSV preview is unavailable.", "CSV preview response is too large."]
        if (typeof message !== "string" || message.length > 256) return "CSV preview is unavailable."
        if (known.indexOf(message) >= 0
                || /^(?:CSV could not be parsed near line [0-9]{1,10} \(invalid quotes or oversized field\)\.|CSV line [0-9]{1,10} has [0-9]{1,10} columns; the header has [0-9]{1,10}\.)$/.test(message)) return message
        return "CSV preview is unavailable."
    }

    function receive(line) {
        if (!currentRun()) return
        if (bytes(line) + 1 > 32768) { fail("CSV preview returned an invalid response."); return }
        var response
        try { response = JSON.parse(line) }
        catch (_) { fail("CSV preview returned an invalid response."); return }
        if (!response || typeof response !== "object" || Array.isArray(response)) {
            fail("CSV preview returned an invalid response.")
            return
        }
        if (response.token !== _runToken || (response.path !== undefined && response.path !== _runPath)) return
        if (response.ok === false) { fail(safeError(response.error)); return }
        if (response.ok !== true || !validPreview(response.preview)) {
            fail("CSV preview returned an invalid response.")
            return
        }
        var p = response.preview
        _terminal = true
        watchdog.stop()
        // Retain only the validated bounded fields, never arbitrary helper data.
        data = {kind: "csv", columns: p.columns, rows: p.rows, previewRows: p.previewRows,
            sampleRows: p.sampleRows, columnCount: p.columnCount, totalRows: p.totalRows,
            columnsTruncated: p.columnsTruncated, cellsTruncated: p.cellsTruncated,
            truncated: p.truncated, note: p.note}
        _resultPath = _runPath
        _resultToken = _runToken
        error = ""
        status = "ready"
        if (worker.running) stopWorker()
    }

    function consumeStdout(text, byteLength) {
        if (!currentRun()) return
        // Collect incrementally so an unterminated line cannot grow for the
        // whole watchdog interval. Decode the cumulative byte buffer, not raw
        // chunks: UTF-8 codepoints may be split across OS reads.
        if (typeof byteLength !== "number" || byteLength > 32768) { fail("CSV preview returned an invalid response."); return }
        var end = text.indexOf("\n", _stdoutOffset)
        while (end >= 0 && currentRun()) {
            var line = text.slice(_stdoutOffset, end)
            _stdoutOffset = end + 1
            receive(line)
            end = text.indexOf("\n", _stdoutOffset)
        }
    }

    function release() {
        watchdog.stop()
        _occupied = false
        _started = false
        Qt.callLater(root.startIfEligible)
    }

    onPathChanged: invalidate()
    onRestoringChanged: {
        if (restoring) invalidate()
        else Qt.callLater(root.startIfEligible)
    }
    onActiveSurfaceChanged: { if (activeSurface) Qt.callLater(root.startIfEligible) }
    Component.onCompleted: { _complete = true; Qt.callLater(root.startIfEligible) }

    // Explicit object properties avoid feeding helper objects into Item's
    // default data property, which this API intentionally overrides with JSON.
    property Timer _watchdog: Timer {
        id: watchdog
        interval: Math.max(1, Math.min(5000, root.watchdogInterval))
        onTriggered: {
            root.fail("CSV preview timed out. Retry to read the file again.")
            // QProcess failed-start has no exited signal. The watchdog also
            // covers that case if runningChanged was not delivered.
            if (root._occupied && !worker.running) root.release()
        }
    }

    property Process _worker: Process {
        id: worker
        command: ["/usr/bin/python3", "-B", "-u", root.scriptPath]
        stdinEnabled: true
        clearEnvironment: true
        environment: {
            var env = {HOME: Quickshell.env("HOME"), PATH: "/usr/bin:/bin", PYTHONDONTWRITEBYTECODE: "1"}
            var state = Quickshell.env("XDG_STATE_HOME")
            if (state) env.XDG_STATE_HOME = state
            return env
        }
        stdout: StdioCollector {
            id: output
            waitForEnd: false
            onDataChanged: root.consumeStdout(text, data.byteLength)
        }
        // Do not collect or expose stderr (it may contain filesystem details).
        onStarted: {
            root._started = true
            if (!root.currentRun()) { root.stopWorker(); return }
            worker.write(JSON.stringify({token: root._runToken, path: root._runPath}) + "\n")
        }
        onExited: {
            root.fail("CSV preview could not be read. Retry to read the file again.")
            root.release()
        }
        onRunningChanged: {
            if (!running) Qt.callLater(function() {
                if (root._occupied && !root._started && !worker.running) {
                    root.fail("CSV preview could not start. Retry to read the file again.")
                    root.release()
                }
            })
        }
    }
}
