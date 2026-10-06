import QtQuick
import Quickshell.Io

// One-shot process: failed startup does not emit Process.exited.
Process {
    id: process
    property bool hasStarted: false
    property bool completed: false
    signal finished(int code, string output)
    stdout: StdioCollector { id: output; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    function complete(code) {
        if (completed) return
        completed = true
        finished(code, output.text)
    }

    onStarted: hasStarted = true
    onExited: function(code) { complete(code) }
    onRunningChanged: {
        if (!running) Qt.callLater(function() {
            if (process && !process.hasStarted) process.complete(-1)
        })
    }
}
