import QtQuick
import Quickshell

ShellRoot {
    property int checks: 0
    function checked(ok, message) {
        if (!ok) {
            console.error(message)
            Qt.exit(1)
            return
        }
        checks++
        if (checks === 3) {
            console.log("FileSearchProcess: failed startup and successful output passed")
            Qt.quit()
        }
    }
    Component.onCompleted: {
        var component = Qt.createComponent(Qt.resolvedUrl("FileSearchProcess.qml"))
        if (component.status !== Component.Ready) {
            console.error(component.errorString())
            Qt.exit(1)
            return
        }
        var missing = component.createObject(this, {command: ["/nonexistent-launcher-test-python3"]})
        missing.finished.connect(function(code, output) { checked(code === -1, "Failed startup did not complete") })
        missing.running = true
        var success = component.createObject(this, {command: ["python3", "-c", "print('[]')"]})
        success.finished.connect(function(code, output) {
            checked(code === 0 && output.trim() === "[]", "Output collection failed")
            success.destroy()
            destructionWait.start()
        })
        success.running = true
    }
    Timer {
        id: destructionWait
        interval: 50
        onTriggered: checked(true, "Post-destruction callbacks completed")
    }
    Timer {
        interval: 3000
        running: true
        onTriggered: {
            console.error("Process completion timed out")
            Qt.exit(1)
        }
    }
}
