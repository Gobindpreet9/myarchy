import QtQuick
import QtQuick.Window
import Quickshell

// Real retained service -> synthetic broker -> real guardian/core -> native
// answer -> real scratch SQLite. Never use the live launcher/store/provider.
ShellRoot {
    id: check
    property int phase: 0
    property real deadline: Date.now() + 18000
    property string original: ""
    property string firstKey: ""
    property int acknowledgements: 0
    property bool showAnswer: true
    property bool showHistory: false
    property int stableTicks: 0
    property string copiedWorkspace: ""
    property var failures: []
    function require(value, message) {
        if (!value) throw new Error(message)
    }
    function finish(code, message) {
        clock.stop()
        service.panelActive = false
        service.openUiRuntime.unmount()
        if (code) console.error(message)
        else console.log("AiOpenUiService: synthetic broker, native answer/control, retained acknowledgements, follow-up context, SQLite restore, idle restart and invalid-state recovery passed")
        Qt.exit(code)
    }
    AiService {
        id: service
        storeEnabled: true
        restoreSettled: true
        latestRequested: true
        defaultAgent: "codex"
        panelActive: true
        stateRoot: Quickshell.env("XDG_STATE_HOME") + "/openui-check"
        brokerScript: decodeURIComponent(Qt.resolvedUrl("tests/ai_openui_broker_stub.py").toString().replace(/^file:\/\//, ""))
    }
    Connections {
        target: service.openUiRuntime
        function onAcknowledged() { ++check.acknowledgements }
    }
    Window {
        width: 720
        height: 900
        visible: true
        Loader {
            anchors.fill: parent
            active: check.showAnswer && !!service.latest
            sourceComponent: Component {
                AiAnswer {
                    turn: service.latest
                    openUiService: service
                    uiState: service.latest ? service.uiStates[String(service.latest.id)] || ({}) : ({})
                    foreground: "#ece9e1"
                    background: "#202124"
                    accent: "#a8bbeb"
                }
            }
        }
        Loader {
            width: parent.width
            active: check.showHistory && service.turns.length > 1
            sourceComponent: Component {
                AiAnswer {
                    turn: service.turns[0]
                    openUiService: service
                    foreground: "#ece9e1"; background: "#202124"; accent: "#a8bbeb"
                }
            }
        }
    }
    Timer {
        id: clock
        interval: 15
        repeat: true
        running: true
        onTriggered: {
            try {
                if (Date.now() > check.deadline) throw new Error("Native integration deadline at phase " + check.phase + ": " + service.openUiRuntime.error)
                var runtime = service.openUiRuntime
                if (check.phase === 0) {
                    check.require(Quickshell.env("HOME").indexOf("/tmp/opencode/") === 0, "Scratch HOME required")
                    check.require(runtime.identity === "" && !runtime.busy, "No eager worker at service boot")
                    service.draft = "Make tool"
                    check.require(service.submit(service.draft), "Explicit submit accepted")
                    check.phase = 1
                } else if (check.phase === 1 && !service.busy && runtime.ready && !runtime.busy) {
                    check.require(service.responseMode === "openui", "New Codex conversation selects OpenUI")
                    check.require(runtime.canonicalState.$n === 2, "Real core loaded defaults")
                    check.require(runtime.tree.children[1].props.text === "6", "Derived native text")
                    check.original = service.workspaceId
                    check.firstKey = runtime.identity
                    check.require(service.dispatchOpenUi(service.latest.id, 1, "root/0", "change", 7), "Native event accepted")
                    check.require(runtime.busy && !service.submit("Too soon") && !service.newConversation()
                        && !service.resumeWorkspace("ws-other"), "Transitions wait for acknowledgements")
                    check.showAnswer = false
                    service.panelActive = false
                    check.phase = 2
                } else if (check.phase === 2 && !runtime.busy && runtime.canonicalState.$n === 7) {
                    check.require(service.uiStates[String(service.latest.id)]["openui:1"].$n === 7,
                        "Destroyed view cannot discard pending state")
                    check.require(runtime.tree.children[1].props.text === "21", "Control and result share state")
                    service.panelActive = true
                    check.showAnswer = true
                    check.require(service.submit("Revise"), "Follow-up uses acknowledged state")
                    check.phase = 3
                } else if (check.phase === 3 && !service.busy && runtime.ready && !runtime.busy && runtime.identity !== check.firstKey) {
                    check.require(service.latest.status === "done" && runtime.canonicalState.$n === 7,
                        "Synthetic broker received current program/state, not stale defaults")
                    service.storeRun("save", service.workspaceSnapshot())
                    check.phase = 4
                } else if (check.phase === 4 && !service.storeBusy) {
                    check.require(service.newConversation(), "Drained new chat succeeds")
                    check.phase = 5
                } else if (check.phase === 5 && !service.storeBusy) {
                    check.require(service.resumeWorkspace(check.original), "Saved workspace reload starts")
                    check.phase = 6
                } else if (check.phase === 6 && !service.loadingLatest && service.latest && runtime.ready && !runtime.busy) {
                    check.require(runtime.canonicalState.$n === 7 && service.responseMode === "openui", "SQLite restores tool state and response profile")
                    check.showAnswer = false
                    service.panelActive = false
                    runtime.idleInterval = 40
                    check.phase = 7
                } else if (check.phase === 7 && runtime._phase === "stopped") {
                    check.require(runtime.canonicalState.$n === 7, "Idle release retains acknowledged state")
                    service.panelActive = true
                    check.showAnswer = true
                    check.phase = 8
                } else if (check.phase === 8 && runtime.ready && !runtime.busy && runtime._loaded) {
                    check.require(runtime.canonicalState.$n === 7, "Cold worker reload retains state")
                    service.setUiState(service.latest.id, "openui:1", {"$unknown": 1})
                    check.require(service.activateOpenUi(service.latest.id, 1, true), "Explicit retry revalidates restored state")
                    check.phase = 9
                } else if (check.phase === 9 && !runtime.busy && runtime.error) {
                    check.require(!runtime.ready, "Incompatible state is not silently rendered")
                    check.require(service.resetOpenUi(service.latest.id, 1), "Explicit saved-input reset recovers")
                    check.phase = 10
                } else if (check.phase === 10 && runtime.ready && !runtime.busy) {
                    check.require(runtime.canonicalState.$n === 7, "Reset uses the revised authored defaults")
                    check.require(service.textAnswerFor(service.latest).indexOf("21") >= 0,
                        "Copy/text view includes the current derived result")
                    check.showHistory = true
                    check.require(service.activateOpenUi(service.turns[0].id, 1, true), "Open an older tool explicitly")
                    check.phase = 11
                } else if (check.phase === 11 && runtime.ready && !runtime.busy) {
                    check.require(runtime.identity === service.openUiIdentity(service.turns[0].id, 1),
                        "Newest visible surface cannot steal an explicit historical selection")
                    if (++check.stableTicks < 10) return
                    check.require(service.dispatchOpenUi(service.turns[0].id, 1, "root/0", "change", 9), "Edit the selected historical tool")
                    check.phase = 115
                } else if (check.phase === 115 && !runtime.busy) {
                    check.require(service.submit("Revise selected"), "Follow-up captures explicitly selected tool")
                    check.phase = 116
                } else if (check.phase === 116 && !service.busy && runtime.ready && !runtime.busy
                        && runtime.identity === service.openUiIdentity(service.latest.id, 1)) {
                    check.require(service.latest.status === "done" && runtime.canonicalState.$n === 9,
                        "Selected historical code and acknowledged value reach the broker")
                    check.showHistory = false
                    check.require(service.duplicateWorkspace("Independent tool"), "Duplicate a drained tool workspace")
                    check.phase = 12
                } else if (check.phase === 12 && !service.workspaceActionPending && !service.loadingLatest
                        && service.workspaceId !== check.original && runtime.ready && !runtime.busy) {
                    check.copiedWorkspace = service.workspaceId
                    check.showAnswer = false
                    service.panelActive = false
                    check.phase = 13
                } else if (check.phase === 13 && runtime._phase === "stopped") {
                    check.require(service.resumeWorkspace(check.original), "Start hidden saved-workspace navigation")
                    service.panelActive = true
                    check.showAnswer = true
                    check.phase = 14
                } else if (check.phase === 14 && !service.loadingLatest && runtime.ready && !runtime.busy) {
                    check.require(service.workspaceId === check.original && runtime.identity.indexOf(check.original + ":") === 0,
                        "Panel reopening must not cold-load the outgoing tool and discard the destination")
                    var snapshot = service.workspaceSnapshot()
                    snapshot.workspace = Object.assign({}, snapshot.workspace, {id: check.copiedWorkspace, sessionRef: ""})
                    check.require(service.dispatchOpenUi(service.latest.id, 1, "root/0", "change", 11), "Accepted outgoing edit before a deferred restore")
                    check.require(!service.applyWorkspaceSnapshot(snapshot, {}) && service.workspaceTransitionPending,
                        "A busy restore is deferred behind a visible freeze barrier")
                    check.require(!service.setUiState(service.latest.id, "openui:1", {"$n": 99})
                        && !service.dispatchOpenUi(service.latest.id, 1, "root/0", "change", 99)
                        && !service.submit("Frozen"), "Deferred restore refuses new outgoing edits and submits")
                    check.phase = 15
                } else if (check.phase === 15 && !service.deferredOpenUiRestore && runtime.ready && !runtime.busy
                        && service.workspaceId === check.copiedWorkspace) {
                    check.require(runtime.canonicalState.$n === 9, "Deferred destination applies its own state")
                    check.require(service.resumeWorkspace(check.original), "Reload acknowledged outgoing workspace")
                    check.phase = 16
                } else if (check.phase === 16 && !service.loadingLatest && runtime.ready && !runtime.busy
                        && service.workspaceId === check.original) {
                    check.require(runtime.canonicalState.$n === 11, "Pre-freeze acknowledgement was saved to the original before switching")
                    check.finish(0, "")
                }
            } catch (error) { check.finish(1, String(error)) }
        }
    }
}
