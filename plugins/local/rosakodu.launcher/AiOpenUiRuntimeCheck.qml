import QtQuick
import Quickshell

ShellRoot {
    id: check
    property int phase: 0
    property real deadline: Date.now() + 7000
    AiOpenUiRuntime { id: runtime; active: true }
    Timer {
        interval: 10
        repeat: true
        running: true
        onTriggered: {
            try {
                if (runtime.error || Date.now() > check.deadline) throw new Error(runtime.error || "Runtime check deadline")
                if (check.phase === 0) {
                    if (!runtime.mount("synthetic", '$page = false\n$deleted = false\nroot = $page ? Button("Delete", @Set($deleted, true)) : Button("Next", @Set($page, true))', {}))
                        throw new Error("Mount refused")
                    check.phase = 1
                } else if (check.phase === 1 && runtime.ready && !runtime.busy) {
                    if (!runtime.dispatch("root", "click", null) || !runtime.dispatch("root", "click", null))
                        throw new Error("Two clicks on the same rendered Next must enter the queue")
                    check.phase = 2
                } else if (check.phase === 2 && !runtime.busy) {
                    if (!runtime.canonicalState.$page || runtime.canonicalState.$deleted || !runtime.warning)
                        throw new Error("A queued Next click must not invoke unseen Delete")
                    if (!runtime.dispatch("root", "click", null)) throw new Error("Fresh Delete click refused")
                    check.phase = 3
                } else if (check.phase === 3 && !runtime.busy) {
                    if (!runtime.canonicalState.$deleted) throw new Error("Fresh displayed action did not run")
                    console.log("AiOpenUiRuntime: queued positional-action replacement is rejected; fresh semantic action runs")
                    Qt.exit(0)
                }
            } catch (error) { console.error(String(error)); Qt.exit(1) }
        }
    }
}
