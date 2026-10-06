pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "SatinGlass.js" as Satin
import "AppState.js" as AppState
import "LauncherSearch.js" as LauncherSearch
import "LauncherMotion.js" as LauncherMotion
import "FileSearch.js" as FileSearch
import "AiState.js" as AiState
import "AiLayout.js" as AiLayout

Item {
    id: root

    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property var service: null

    readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
    readonly property string pluginId: String((root.manifest && root.manifest.id) || "rosakodu.launcher")
    readonly property string recentsPath: Quickshell.env("HOME") + "/.config/omarchy/launcher-recents.json"
    readonly property string dockSettingsPath: Quickshell.env("HOME") + "/.config/omarchy/dock-settings.json"

    property bool opened: false
    // Explore surface: the expanded AI card, toggled explicitly by the user.
    property bool aiExpanded: false
    // Keep the layer mapped through the exit transition. `opened` remains the
    // logical interaction state; `surfaceVisible` is the visual lifecycle.
    property bool surfaceVisible: false
    property real revealProgress: 0
    property bool motionEnabled: true
    property string motionSource: "keyboard"
    property string motionIntent: ""
    property real motionOriginFX: 0.5
    property real motionOriginFY: 0.5
    property string motionOriginEdge: ""
    // Output point a dock click came from. The panel fills its output, so
    // output fractions map straight onto panel coordinates without trusting
    // compositor-global window positions.
    readonly property point motionOrigin: Qt.point(root.motionOriginFX * panel.width, root.motionOriginFY * panel.height)
    property string query: ""
    readonly property bool fileMode: FileSearch.mode(root.query)
    readonly property bool aiMode: AiState.mode(root.query)
    readonly property string fileTerms: FileSearch.terms(root.query)
    readonly property string homePath: Quickshell.env("HOME")
    property int fileGeneration: 0
    property var activeFileProcess: null
    property bool fileSearching: false
    property string fileError: ""
    property int selectedIndex: 0
    property var resultRows: []
    property var recentRows: []
    property var recentIds: []
    property bool appLibraryReady: root.hasEntrySource
    property bool launching: false
    property string feedbackText: ""
    property var configuredHiddenIds: ({})
    property var desktopHiddenIds: ({})
    // Alpha-only translucency independently controlled from Dock Settings.
    property int launcherTranslucency: 0
    readonly property real surfaceOpacity: 1 - root.launcherTranslucency / 100
    // Cached full app list used to resolve persisted recent desktop IDs.
    property var allAppRows: []

    readonly property bool hasEntrySource: root.appLibrary !== null
        || (DesktopEntries.applications && DesktopEntries.applications.values !== undefined)
    readonly property var desktopValues: DesktopEntries.applications && DesktopEntries.applications.values
        ? DesktopEntries.applications.values : []

    // App search, file search and AI answers share the same theme and material.
    readonly property color foreground: Color.bar.text
    readonly property color background: Color.bar.background
    readonly property color accent: Color.accent
    readonly property int cardWidth: root.aiMode && root.service && root.service.turns.length > 0
        ? (root.aiExpanded ? Math.min(1100, Math.max(820, panel.width - 96)) : 820)
        : Satin.launcher.width
    // A short search should feel like a compact launcher, not an empty sheet.
    // At six rows the panel reaches the normal scrolling height.
    readonly property int visibleResultCount: Math.min(resultRows.length, 6)
    readonly property int cardHeight: root.aiMode ? (root.service && root.service.turns.length > 0
        ? (root.service.busy && !root.service.latest.answer
            ? Math.max(210, 40 + aiComposer.implicitHeight + aiPane.chromeHeight)
            : AiLayout.answerHeight(aiPane.responseHeight, aiPane.chromeHeight, aiComposer.implicitHeight,
                root.aiExpanded ? Math.min(940, Math.max(720, panel.height - 140)) : 720))
        : AiLayout.idleCardHeight(!!root.service.attachment, aiComposer.implicitHeight, aiPane.chromeHeight))
        : query.length === 0 ? 560
        : Math.min(560, 188 + Math.max(70, visibleResultCount * rowHeight + Math.max(0, visibleResultCount - 1) * 4))
    readonly property int rowHeight: 58
    readonly property int maxRecentCount: 6
    readonly property string desktopNames: [
        Quickshell.env("XDG_CURRENT_DESKTOP"),
        Quickshell.env("XDG_SESSION_DESKTOP"),
        Quickshell.env("DESKTOP_SESSION")
    ].filter(function(value) { return String(value || "").length > 0 }).join(":")

    NumberAnimation {
        id: launcherOpenAnimation
        target: root
        property: "revealProgress"
        to: 1
        duration: root.motionSource === "dock" ? Satin.launcher.dockOpenMs : Satin.launcher.openMs
        easing.type: root.motionSource === "dock" ? Easing.OutCubic : Easing.OutQuint
    }

    Shortcut {
        sequence: "Ctrl+L"
        enabled: root.opened && root.aiMode
        onActivated: root.focusInput()
    }

    NumberAnimation {
        id: launcherCloseAnimation
        target: root
        property: "revealProgress"
        to: 0
        duration: root.motionSource === "dock" ? Satin.launcher.dockCloseMs : Satin.launcher.closeMs
        easing.type: Easing.InCubic
        onFinished: root.finishDismiss()
    }

    function hiddenIdMap(raw) {
        var result = ({})
        var lines = String(raw || "").split(/\n/)
        for (var i = 0; i < lines.length; i++) {
            var id = AppState.normalizeDesktopId(lines[i])
            if (id) result[id] = true
        }
        return result
    }

    function rowEntry(row) {
        return row && row.entry ? row.entry : null
    }

    function entryId(entry) {
        return AppState.normalizeDesktopId(entry ? entry.id : "")
    }

    function entryName(entry) {
        if (root.appLibrary && entry) return root.appLibrary.entryName(entry)
        return LauncherSearch.entryName(entry)
    }

    function entrySubtext(entry) {
        if (root.appLibrary && entry) return root.appLibrary.entrySubtext(entry)
        return LauncherSearch.entrySubtext(entry)
    }

    function isHiddenEntry(entry) {
        var id = AppState.normalizeDesktopId(entry ? entry.id : "")
        return !!id && (root.configuredHiddenIds[id] === true || root.desktopHiddenIds[id] === true)
    }

    function sortedEntries(queryText) {
        if (root.appLibrary) return root.appLibrary.sortedEntries(queryText)
        return LauncherSearch.sortedEntries(root.desktopValues, queryText, function(entry) {
            return root.isHiddenEntry(entry)
        })
    }

    function iconSource(entry) {
        if (!entry) return ""
        if (root.appLibrary) return root.appLibrary.iconSource(entry.icon)
        var icon = String(entry.icon || "")
        if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
        if (icon.charAt(0) === "/") return "file://" + icon
        var themed = Quickshell.iconPath(icon || "application-x-executable", true)
        return themed || Quickshell.iconPath("application-x-executable", true)
    }

    function launchEntry(entry, name) {
        // Raw entry id on purpose: filenames are id + ".desktop" and
        // basenames may end in ".desktop" (see AppState.desktopFileName).
        var rawId = entry ? String(entry.id || "").trim() : ""
        var command = AppState.desktopLaunchCommand(rawId)
        if (command.length !== 4) return false
        var running = ToplevelManager.toplevels.values
        for (var i = 0; i < running.length; i++) {
            var top = running[i]
            if (!top || !AppState.matchesRunningApp(entry, top.appId)) continue
            var hyprTops = Hyprland.toplevels.values
            for (var j = 0; j < hyprTops.length; j++) {
                var match = hyprTops[j]
                if (!match || match.wayland !== top) continue
                var address = String(match.address || "").replace(/^0x/, "")
                if (/^[0-9a-fA-F]+$/.test(address)) {
                    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({window="address:0x' + address + '"})'])
                    return true
                }
            }
            if (typeof top.activate === "function") {
                top.activate()
                return true
            }
        }
        if (root.appLibrary) root.appLibrary.launch(rawId, name)
        else Quickshell.execDetached(command)
        return true
    }

    function isActionRow(row) {
        return !!row && (row.kind === "url" || row.kind === "search" || row.kind === "calc" || row.kind === "askAi")
    }

    function rowTitle(row) {
        if (row && row.kind === "file") return row.title
        if (row && row.kind === "workspace") return String(row.title || "")
        if (root.isActionRow(row)) return String(row.title || "")
        return root.entryName(root.rowEntry(row))
    }

    function actionRowsFor(queryText) {
        return AppState.buildActionRows(queryText)
    }

    function rebuildEntryCache() {
        var allRows = root.sortedEntries("")
        root.allAppRows = allRows
        root.rebuildRecents()
    }

    function rebuildResults() {
        if (AiState.mode(root.query)) {
            root.resultRows = []
            root.selectedIndex = -1
            return
        }
        if (FileSearch.mode(root.query)) return
        if (!root.hasEntrySource) {
            root.resultRows = []
            root.selectedIndex = 0
            return
        }
        var appRows = root.sortedEntries(root.query)
        var workspaceRows = root.service && root.query.length > 0
            ? AiState.matchWorkspaces(root.service.workspaceIndex, root.query, 4, root.service.workspaceId)
            : []
        var actions = root.actionRowsFor(root.query)
        root.resultRows = appRows.concat(workspaceRows, actions)
        if (root.resultRows.length === 0) root.selectedIndex = -1
        else root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.resultRows.length - 1))
    }

    function rebuildRecents() {
        if (!root.hasEntrySource) {
            root.recentRows = []
            return
        }
        var allRows = root.allAppRows && root.allAppRows.length > 0 ? root.allAppRows : root.sortedEntries("")
        var ordered = root.recentIds
        var seen = ({})
        var recents = []
        for (var i = 0; i < ordered.length && recents.length < root.maxRecentCount; i++) {
            var row = LauncherSearch.bestMatch(allRows, ordered[i])
            var entry = root.rowEntry(row)
            var key = root.entryId(entry).toLowerCase()
            if (!row || !key || seen[key]) continue
            seen[key] = true
            recents.push(row)
        }
        root.recentRows = recents
    }

    function moveSelection(delta) {
        if (root.resultRows.length === 0) return
        var next = root.selectedIndex < 0 ? 0 : root.selectedIndex + delta
        root.selectedIndex = Math.max(0, Math.min(root.resultRows.length - 1, next))
        resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    }

    function selectedRow() {
        return root.selectedIndex >= 0 && root.selectedIndex < root.resultRows.length
            ? root.resultRows[root.selectedIndex] : null
    }

    function recordRecent(entry) {
        root.recentIds = AppState.touchRecent(root.recentIds, root.entryId(entry), 10)
        recentsFile.setText(AppState.serializeRecentIds(root.recentIds) + "\n")
        root.rebuildRecents()
    }

    function launchRow(row) {
        if (!row || root.launching) return
        if (row.kind === "file") {
            root.openFile(row, false)
            return
        }
        if (row.kind === "workspace") {
            root.openWorkspace(row)
            return
        }
        if (root.isActionRow(row)) {
            root.launchActionRow(row)
            return
        }
        var entry = root.rowEntry(row)
        if (!AppState.canLaunchEntry(entry, root.launching)) return
        var id = root.entryId(entry)
        var name = root.entryName(entry)
        root.launching = true
        root.feedbackText = "Launching " + (name || id) + "…"
        if (!root.launchEntry(entry, name)) {
            root.launching = false
            root.feedbackText = "Unable to launch " + (name || id)
            return
        }
        root.recordRecent(entry)
        launchCloseTimer.restart()
    }

    function launchActionRow(row) {
        if (!row) return
        if (row.kind === "calc") {
            var resultText = String(row.resultText || "")
            if (!resultText) return
            try { Quickshell.clipboardText = resultText } catch (e) {}
            Quickshell.execDetached(["wl-copy", resultText])
            root.feedbackText = "Copied " + resultText
            feedbackTimer.restart()
            return
        }
        if (row.kind === "askAi") {
            // Transfer, never auto-send: the user reviews and submits explicitly.
            root.query = AiState.prefix + row.query
            root.focusInput()
            return
        }
        var command = []
        if (row.kind === "url") command = AppState.urlOpenCommand(row.url)
        else if (row.kind === "search") command = AppState.webSearchCommand(row.query)
        if (command.length === 0) {
            root.feedbackText = "Unable to open"
            feedbackTimer.restart()
            return
        }
        root.launching = true
        root.feedbackText = row.kind === "url" ? "Opening link…" : "Searching the web…"
        Quickshell.execDetached(command)
        launchCloseTimer.restart()
    }

    function cancelFileSearch() {
        root.fileGeneration++
        fileSearchTimer.stop()
        if (root.activeFileProcess) {
            root.activeFileProcess.running = false
            root.activeFileProcess = null
        }
        root.fileSearching = false
    }

    function queueFileSearch() {
        root.cancelFileSearch()
        root.fileError = ""
        if (!FileSearch.mode(root.query)) return
        root.resultRows = []
        root.selectedIndex = -1
        if (root.opened && FileSearch.terms(root.query).length >= 2) {
            root.fileSearching = true
            fileSearchTimer.restart()
        }
    }

    function openFile(row, reveal) {
        var command = FileSearch.command(row, reveal)
        if (!command.length || root.launching) return
        root.launching = true
        root.feedbackText = reveal ? "Opening folder…" : "Opening file…"
        Quickshell.execDetached(command)
        launchCloseTimer.restart()
    }

    function copyFilePath(row) {
        if (!row || row.kind !== "file" || !FileSearch.validPath(row.path)) return
        Quickshell.clipboardText = row.path
        root.feedbackText = "Path copied"
        feedbackTimer.restart()
    }

    function askFile(row) {
        if (!root.service || !row || row.kind !== "file" || row.isDirectory) return
        root.service.attachment = row.path
        root.query = AiState.prefix + "Explain this file"
        Qt.callLater(root.focusInput)
    }

    function focusInput() {
        if (root.aiMode) aiComposer.focusPrompt()
        else searchInput.forceActiveFocus()
    }

    // The AI surfaces keep the broker warm while visible; when they are all
    // hidden the broker may idle out (the session hint resumes it).
    function syncPanelActive() {
        if (root.service) root.service.panelActive = root.opened && root.aiMode
    }

    function openWorkspace(row) {
        if (!root.service || !row) return
        if (root.service.busy) {
            root.feedbackText = "Wait for the current answer, or press Stop."
            feedbackTimer.restart()
            return
        }
        if (!root.service.resumeWorkspace(row.id)) return
        // The load lands asynchronously; the restored draft arrives with the
        // workspaceRestored signal below.
        root.query = AiState.prefix
        Qt.callLater(root.focusInput)
    }

    // One detached view per workspace: re-opening focuses the same window.
    function showWorkspaceWindow() {
        if (!root.service || root.service.turns.length === 0) return
        root.dismiss()
        workspaceWindow.show()
    }

    function submitAi() {
        if (!root.service) return "no-service"
        var prompt = AiState.prompt(root.query)
        if (root.service.busy || root.service.stopping) {
            root.feedbackText = "Wait for the answer, or press Stop."
            feedbackTimer.restart()
            return "busy"
        } else if (root.service.loadingLatest) {
            root.feedbackText = "Loading your last conversation…"
            feedbackTimer.restart()
            return "loading"
        } else if (root.service.attachmentBlocked) {
            // IPC-only copy: the composer's Enter/Send are pre-gated by
            // canSubmit, so in the live UI the preview chrome itself is the
            // explanation; these strings reach the user only through the
            // test-only submit/submitfile hooks below.
            root.feedbackText = root.service.previewStatus === "error"
                ? "CSV preview failed. Retry or remove the attachment."
                : "Review the CSV preview before sending."
            feedbackTimer.restart()
            return root.service.previewStatus === "error" ? "attachment-error" : "previewing"
        } else if (prompt.length > 8000) {
            root.feedbackText = "Keep your question under 8,000 characters."
            feedbackTimer.restart()
            return "rejected"
        } else if (root.service.submit(prompt)) {
            root.query = AiState.prefix
            return "submitted"
        }
        return "rejected"
    }

    function open(payloadJson) {
        var context = LauncherMotion.openContext(payloadJson)
        // A dock click is a pointer toggle: clicking the Apps glyph while the
        // launcher is open animates it closed instead of re-opening in place.
        if (root.opened && context.intent === "toggle") {
            root.dismiss()
            return
        }
        launcherCloseAnimation.stop()
        root.motionSource = context.source
        root.motionIntent = context.intent
        root.motionOriginFX = context.originFX
        root.motionOriginFY = context.originFY
        root.motionOriginEdge = context.edge
        root.surfaceVisible = true
        // A saved conversation resumes with its draft; a fresh entry (no
        // turns yet, lazy restore in flight) stays in app search until the
        // user or the restore brings the text in.
        root.query = root.service && (root.service.resumeOnOpen || (root.service.turns && root.service.turns.length > 0))
            ? AiState.prefix + (root.service.draft || "") : ""
        root.selectedIndex = 0
        root.launching = false
        root.feedbackText = ""
        root.opened = true
        if (root.motionEnabled && root.revealProgress < 1) {
            launcherOpenAnimation.from = root.revealProgress
            launcherOpenAnimation.restart()
        } else {
            root.revealProgress = 1
        }
        root.syncPanelActive()
        root.rebuildResults()
        if (root.service) root.service.refreshWorkspaceIndex()
        if (root.appLibrary) root.appLibrary.refreshIcons()
        else if (!hiddenEntryScan.running) hiddenEntryScan.running = true
        Qt.callLater(root.focusInput)
    }

    function close() {
        root.cancelFileSearch()
        if (!root.surfaceVisible) {
            root.opened = false
            root.revealProgress = 0
            return
        }
        root.opened = false
        // A debounced draft/edit may still be pending; close commits it so a
        // quick close and reopen never loses the user's last keystrokes.
        if (root.service && root.service.workspaceId) {
            if (root.service.saveDebounce) root.service.saveDebounce.stop()
            root.service.storeRun("save", root.service.savePayload())
        }
        root.syncPanelActive()
        launcherOpenAnimation.stop()
        if (root.motionEnabled && root.revealProgress > 0) {
            launcherCloseAnimation.from = root.revealProgress
            launcherCloseAnimation.restart()
        } else {
            root.revealProgress = 0
            root.finishDismiss()
        }
    }

    function finishDismiss() {
        if (root.opened) return
        launcherOpenAnimation.stop()
        launcherCloseAnimation.stop()
        root.revealProgress = 0
        root.surfaceVisible = false
        root.query = ""
        root.launching = false
        root.feedbackText = ""
        Qt.callLater(function() {
            if (root.shell && typeof root.shell.hide === "function")
                root.shell.hide(root.pluginId)
        })
    }

    function dismiss() { root.close() }

    function toggle(payloadJson) {
        if (root.opened) root.dismiss()
        else root.open(payloadJson || "")
    }

    onQueryChanged: {
        root.selectedIndex = 0
        if (root.opened && root.service) {
            root.service.resumeOnOpen = AiState.mode(root.query)
            if (AiState.mode(root.query)) {
                root.service.draft = AiState.draft(root.query)
                // User text is authoritative over any workspace restore:
                // the composer keeps what was typed while a load lands.
                root.service.draftTouched = true
            }
        }
        root.queueFileSearch()
        root.rebuildResults()
    }
    onAiModeChanged: {
        if (root.opened && root.aiMode) {
            if (root.service) root.service.requestLatest()
        }
        root.syncPanelActive()
        if (root.opened) Qt.callLater(root.focusInput)
    }
    onAppLibraryChanged: {
        root.rebuildEntryCache()
        root.rebuildResults()
    }
    onDesktopValuesChanged: {
        root.rebuildEntryCache()
        root.rebuildResults()
    }

    Component.onCompleted: {
        root.rebuildEntryCache()
        root.rebuildResults()
        recentsFile.reload()
        configuredHidesFile.reload()
        dockSettingsFile.reload()
        hiddenEntryScan.running = true
    }

    Connections {
        target: root.appLibrary
        enabled: root.appLibrary !== null
        function onAppsChanged() {
            root.rebuildEntryCache()
            root.rebuildResults()
        }
    }

    Connections {
        target: root.service
        enabled: root.service !== null
        function onWorkspaceIndexChanged() {
            if (root.opened && !root.aiMode && !root.fileMode) root.rebuildResults()
        }
        function onWorkspaceRestored() {
            // Restoring while the launcher is open surfaces the saved draft —
            // but never over user text typed while the load was in flight.
            if (!root.opened || !root.aiMode) return
            if (!root.service) return
            if (root.service.loadingLatest) { root.focusInput(); return }
            if (root.service.draftTouched && root.service.draft.length > 0) { root.focusInput(); return }
            root.query = AiState.prefix + (root.service.draft || "")
            root.focusInput()
        }
    }

    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            root.rebuildEntryCache()
            root.rebuildResults()
            if (!hiddenEntryScan.running) hiddenEntryScan.running = true
        }
    }

    IpcHandler {
        target: "rosakodu.launcher"
        function open(): string { root.open(""); return "ok" }
        function close(): string { root.dismiss(); return "ok" }
        function toggle(): string { root.toggle(""); return "ok" }
        function searchFiles(query: string): string {
            root.open("")
            root.query = "f: " + query
            return "ok"
        }
        function ai(): string {
            root.open("")
            // open() already resumes a saved conversation (including its
            // draft); only enter bare when there was nothing to resume.
            root.query = root.query.length > 0 ? root.query : AiState.prefix
            return "ok"
        }
        function query(text: string): string {
            // Test-only: set an ordinary search query on a fresh open.
            root.open("")
            root.query = String(text || "")
            return "ok"
        }
        function window(): string {
            // Test-only: open (or focus) the detached workspace window.
            root.showWorkspaceWindow()
            return root.service && root.service.turns.length > 0 ? "opened" : "empty"
        }
        function newchat(): string {
            // Test-only: equivalent to pressing New chat in the toolbar.
            if (!root.service || root.service.busy) return "busy"
            root.service.newConversation()
            root.query = AiState.prefix
            return "ok"
        }
        function submit(text: string): string {
            // Test-only: drive the exact submit path without keyboard input.
            if (!root.service) return "no-service"
            if (root.service.busy || root.service.stopping) return "busy"
            if (root.service.loadingLatest) return "loading"
            if (root.service.attachmentBlocked)
                return root.service.previewStatus === "error" ? "attachment-error" : "previewing"
            root.query = AiState.prefix + String(text || "")
            return root.submitAi()
        }
        function submitfile(text: string, path: string): string {
            // Test-only: attach a real file (same intent as the Ask-AI row)
            // CSV attachment starts a local preview; sending is a later,
            // explicit action. A ready CURRENT attachment may be sent directly.
            return AiState.submitFile(root.service, text, path,
                function(query) { root.query = query }, function() { return root.submitAi() })
        }
        function depth(mode: string): string {
            // Test-only: trigger the adaptive-depth action directly.
            if (!root.service) return "no-service"
            return root.service.explainLatest(String(mode || "simpler")) ? "ok" : "rejected"
        }
        function swap(block: string, item: string): string {
            // Test-only: cycle a gallery item's alternative (the same state
            // path the in-cell "Show another" button uses).
            if (!root.service || !root.service.latest) return "no-answer"
            var blockIndex = parseInt(String(block || "0"), 10)
            var itemIndex = parseInt(String(item || "0"), 10)
            var blocks = root.service.latest.blocks || []
            var blockData = blocks[blockIndex]
            if (!blockData || blockData.type !== "gallery") return "no-gallery"
            var items = blockData.items || []
            var itemData = items[itemIndex] || {}
            var count = itemData.alternatives ? itemData.alternatives.length : 0
            var key = "gallery:" + blockIndex + ":" + itemIndex
            var turnState = root.service.uiStates[String(root.service.latest.id)] || {}
            var current = typeof turnState[key] === "number" ? turnState[key] : 0
            var next = count > 0 ? (current + 1) % (count + 1) : 0
            root.service.setUiState(root.service.latest.id, key, next)
            return "ok:" + next + "/" + count
        }
        function expand(): string {
            // Test-only: toggle the Explore surface.
            root.aiExpanded = !root.aiExpanded
            return root.aiExpanded ? "expanded" : "collapsed"
        }
        function status(): string {
            return JSON.stringify({
                shell: root.shell !== null,
                appLibrary: root.appLibrary !== null,
                rows: root.resultRows.length,
                recents: root.recentRows.length,
                stripHeight: recentsStrip.height,
                stripPreferred: (root.recentRows.length > 0 && root.query.length === 0) ? 94 : 0,
                queryLength: root.query.length,
                fileMode: root.fileMode,
                fileSearching: root.fileSearching,
                fileError: root.fileError,
                aiMode: root.aiMode,
                aiBusy: root.service ? root.service.busy : false,
                aiLoading: root.service ? root.service.loadingLatest : false,
                previewStatus: root.service ? root.service.previewStatus : "idle",
                previewRows: root.service && root.service.previewData ? root.service.previewData.previewRows : 0,
                columnCount: root.service && root.service.previewData ? root.service.previewData.columnCount : 0,
                totalRows: root.service && root.service.previewData ? root.service.previewData.totalRows : null,
                truncated: root.service && root.service.previewData ? root.service.previewData.truncated : false,
                columnsTruncated: root.service && root.service.previewData ? root.service.previewData.columnsTruncated : false,
                cellsTruncated: root.service && root.service.previewData ? root.service.previewData.cellsTruncated : false,
                previewError: root.service ? root.service.previewError : "",
                brokerIdle: root.service ? root.service.brokerIdleCheck() : false,
                brokerRunning: root.service ? root.service.brokerLive : false,
                aiTurns: root.service ? root.service.turns.length : 0,
                aiAgent: root.service ? root.service.agent || root.service.defaultAgent : "",
                aiState: root.service && root.service.latest ? root.service.latest.status : "idle",
                aiBlocks: root.service && root.service.latest ? root.service.latest.blocks.length : 0,
                aiExpanded: root.aiExpanded,
                focus: dimmer.focusName,
                windowOpen: workspaceWindow.visible,
                workspaceId: root.service ? root.service.workspaceId : "",
                workspaceIndex: root.service ? root.service.workspaceIndex.length : 0,
                cardWidth: root.cardWidth,
                cardHeight: root.cardHeight,
                surfaceOpacity: root.surfaceOpacity,
                launcherTranslucency: root.launcherTranslucency,
                opened: root.opened,
                surfaceVisible: root.surfaceVisible,
                revealProgress: root.revealProgress,
                motionEnabled: root.motionEnabled,
                motionSource: root.motionSource,
                motionOriginFX: root.motionOriginFX,
                motionOriginFY: root.motionOriginFY,
                motionOriginEdge: root.motionOriginEdge
            })
        }
        function ping(): string { return "ok" }
    }

    FileView {
        id: recentsFile
        path: root.recentsPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.recentIds = AppState.parseRecentIds(text() || "")
            root.rebuildRecents()
        }
        onFileChanged: reload()
    }

    FileView {
        id: configuredHidesFile
        path: root.omarchyPath + "/default/omarchy/launcher.hides"
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.configuredHiddenIds = root.hiddenIdMap(text())
            root.rebuildEntryCache()
            root.rebuildResults()
        }
        onFileChanged: reload()
        onLoadFailed: {
            root.configuredHiddenIds = ({})
            root.rebuildEntryCache()
            root.rebuildResults()
        }
    }

    FileView {
        id: dockSettingsFile
        path: root.dockSettingsPath
        watchChanges: true
        printErrors: false
        onLoaded: root.launcherTranslucency = AppState.readLauncherTranslucency(text() || "")
        onFileChanged: reload()
        onLoadFailed: root.launcherTranslucency = 0
    }

    Timer {
        id: fileSearchTimer
        interval: 180
        onTriggered: {
            if (!root.opened || !root.fileMode) return
            root.activeFileProcess = fileSearchComponent.createObject(root, {
                generation: root.fileGeneration,
                command: ["python3", decodeURIComponent(Qt.resolvedUrl("file-search.py").toString().replace(/^file:\/\//, "")),
                          root.homePath, root.fileTerms]
            })
            root.activeFileProcess.running = true
        }
    }

    Component {
        id: fileSearchComponent
        FileSearchProcess {
            id: fileProcess
            property int generation: -1
            onFinished: function(exitCode, output) {
                if (generation === root.fileGeneration && root.opened && root.fileMode) {
                    root.fileSearching = false
                    root.activeFileProcess = null
                    try {
                        if (exitCode !== 0) throw new Error("File search unavailable. Requires python3 and fd.")
                        root.resultRows = FileSearch.parseRows(output)
                        root.selectedIndex = root.resultRows.length ? 0 : -1
                    } catch (error) {
                        root.fileError = String(error.message || error)
                    }
                }
                fileProcess.destroy()
            }
        }
    }

    Process {
        id: hiddenEntryScan
        running: false
        command: [root.omarchyPath + "/shell/services/hidden-entries.sh", root.desktopNames]
        stdout: StdioCollector { id: hiddenEntryOutput; waitForEnd: true }
        onExited: function(exitCode) {
            root.desktopHiddenIds = exitCode === 0 ? root.hiddenIdMap(hiddenEntryOutput.text) : ({})
            root.rebuildEntryCache()
            root.rebuildResults()
        }
    }

    Process {
        id: motionPreferenceProcess
        running: true
        command: ["hyprctl", "-j", "getoption", "animations:enabled"]
        stdout: StdioCollector { id: motionPreferenceOutput; waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode !== 0) return
            try {
                var parsed = JSON.parse(motionPreferenceOutput.text)
                root.motionEnabled = parsed && parsed.bool !== false
            } catch (e) {
                root.motionEnabled = true
            }
            if (!root.motionEnabled) {
                launcherOpenAnimation.stop()
                launcherCloseAnimation.stop()
                root.revealProgress = root.opened ? 1 : 0
                if (!root.opened && root.surfaceVisible) root.finishDismiss()
            }
        }
    }

    Timer {
        id: launchCloseTimer
        interval: 520
        repeat: false
        onTriggered: root.dismiss()
    }

    Timer {
        id: feedbackTimer
        interval: 1300
        repeat: false
        onTriggered: root.feedbackText = ""
    }

    PanelWindow {
        id: panel
        visible: root.surfaceVisible
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "rosakodu-launcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Rectangle {
            id: dimmer
            anchors.fill: parent
            // Focus diagnostics for verification hooks (status IPC).
            readonly property string focusName: Window.activeFocusItem && Window.activeFocusItem.objectName
                ? String(Window.activeFocusItem.objectName) : ""
            color: Util.alpha(Color.background || Color.bar.background, 0.30)
            opacity: root.revealProgress
            // The dimmer echoes the entry gesture: it blooms outward from the
            // dock glyph, or lifts like a lid on the keyboard path. Transform
            // only, so it stays on the compositor's fast path.
            transform: Scale {
                origin.x: root.motionSource === "dock" ? root.motionOrigin.x : dimmer.width / 2
                origin.y: root.motionSource === "dock" ? root.motionOrigin.y : dimmer.height / 2
                xScale: root.motionSource === "dock"
                    ? Satin.launcher.dockDimBloom + (1 - Satin.launcher.dockDimBloom) * root.revealProgress
                    : 1
                yScale: root.motionSource === "dock"
                    ? xScale
                    : Satin.launcher.keyboardDimLid + (1 - Satin.launcher.keyboardDimLid) * root.revealProgress
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.opened
            onClicked: root.dismiss()
        }

        Item {
            id: cardFrame
            readonly property real startScale: root.motionSource === "dock"
                ? Satin.launcher.dockEnterScale : Satin.launcher.enterScale
            readonly property real travelX: root.motionSource === "dock"
                ? root.motionOrigin.x - panel.width / 2 : 0
            readonly property real travelY: root.motionSource === "dock"
                ? root.motionOrigin.y - panel.height / 2 : Satin.launcher.keyboardEnterOffset
            width: Math.min(root.cardWidth + 28, panel.width - 48)
            height: Math.min(root.cardHeight + 32, panel.height - 48)
            Behavior on width { enabled: root.motionEnabled; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on height { enabled: root.aiMode && root.motionEnabled; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            anchors.centerIn: parent
            opacity: root.motionSource === "dock"
                ? Math.min(1, root.revealProgress * 1.7) : root.revealProgress
            scale: startScale + (1 - startScale) * root.revealProgress
            transformOrigin: Item.Center
            transform: Translate {
                x: cardFrame.travelX * (1 - root.revealProgress)
                y: cardFrame.travelY * (1 - root.revealProgress)
            }

            Rectangle {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 14
                width: card.width + 22
                height: card.height + 22
                radius: card.radius + 12
                color: Qt.rgba(0, 0, 0, Satin.elev.card.alpha * 0.48 * root.surfaceOpacity)
                antialiasing: true
            }

            Rectangle {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: 6
                width: card.width + 8
                height: card.height + 8
                radius: card.radius + 5
                color: Qt.rgba(0, 0, 0, Satin.elev.card.alpha * 0.60 * root.surfaceOpacity)
                antialiasing: true
            }

            Rectangle {
                id: card
                width: Math.min(root.cardWidth, cardFrame.width - 28)
                height: Math.min(root.cardHeight, cardFrame.height - 32)
                anchors.centerIn: parent
                radius: Satin.radius.card
                border.width: 1
                border.color: Util.alpha(root.foreground, Satin.keyline.hair * root.surfaceOpacity)
                antialiasing: true
                color: root.background
                gradient: cardGradient
                Gradient {
                    id: cardGradient
                    GradientStop { position: 0.0; color: Util.alpha(Qt.lighter(root.background, 1.22), root.surfaceOpacity) }
                    GradientStop { position: 0.52; color: Util.alpha(root.background, root.surfaceOpacity) }
                    GradientStop { position: 1.0; color: Util.alpha(Qt.darker(root.background, 1.28), root.surfaceOpacity) }
                }

                MouseArea { anchors.fill: parent; onClicked: {} }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, card.radius - 1)
                    color: "transparent"
                    border.width: 1
                    border.color: Util.alpha(root.foreground, Satin.keyline.inner * root.surfaceOpacity)
                }

                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 2
                    height: 1
                    color: Util.alpha(root.foreground, Satin.keyline.specTop * root.surfaceOpacity)
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 14

                    Rectangle {
                        id: searchField
                        visible: !root.aiMode
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? 60 : 0
                        radius: Satin.radius.field
                        color: Util.alpha(root.foreground, 0.075)
                        border.width: searchInput.activeFocus ? 1 : 0
                        border.color: Util.alpha(root.accent, 0.72)

                        Item {
                            anchors.left: parent.left
                            anchors.leftMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            width: 22
                            height: 22
                            readonly property color glyphColor: root.query ? root.accent : Util.alpha(root.foreground, 0.58)
                            Rectangle {
                                x: 1; y: 1; width: 15; height: 15; radius: 7.5
                                color: "transparent"
                                border.width: 2
                                border.color: parent.glyphColor
                            }
                            Rectangle {
                                x: 12.7; y: 14.5; width: 7.5; height: 2.2; radius: 1.1
                                rotation: 45
                                color: parent.glyphColor
                            }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 55
                            anchors.right: shortcutHint.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.query.length === 0
                            text: root.appLibraryReady ? "Search apps · f: files · ai: ask" : "Loading applications…"
                            color: Util.alpha(root.foreground, 0.48)
                            font.pixelSize: Satin.type.search
                            elide: Text.ElideRight
                        }

                        TextInput {
                            id: searchInput
                            anchors.left: parent.left
                            anchors.leftMargin: 55
                            anchors.right: shortcutHint.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.query
                            color: root.foreground
                            selectionColor: Util.alpha(root.accent, 0.42)
                            selectedTextColor: root.foreground
                            font.pixelSize: Satin.type.search
                            clip: true
                            activeFocusOnTab: true
                            Accessible.role: Accessible.EditableText
                            Accessible.name: root.aiMode ? "Ask AI or send a follow-up"
                                : root.fileMode ? "Search files and folders" : "Search installed applications"
                            onTextEdited: root.query = text

                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_Escape) {
                                    root.dismiss()
                                    event.accepted = true
                                } else if (root.aiMode && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                                    root.submitAi()
                                    event.accepted = true
                                } else if (root.aiMode) {
                                    // Preserve native Tab traversal into the answer and its controls.
                                } else if (root.fileMode && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                           && event.modifiers === Qt.ControlModifier) {
                                    root.askFile(root.selectedRow())
                                    event.accepted = true
                                } else if (root.fileMode && event.key === Qt.Key_C && event.modifiers === Qt.ControlModifier) {
                                    if (searchInput.selectedText.length === 0) {
                                        root.copyFilePath(root.selectedRow())
                                        event.accepted = true
                                    }
                                } else if (root.fileMode && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                           && event.modifiers === Qt.AltModifier) {
                                    root.openFile(root.selectedRow(), true)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                                    root.moveSelection(1)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
                                    root.moveSelection(-1)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_PageDown) {
                                    root.moveSelection(5)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_PageUp) {
                                    root.moveSelection(-5)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    root.launchRow(root.selectedRow())
                                    event.accepted = true
                                }
                            }
                        }

                        Rectangle {
                            id: shortcutHint
                            width: 43
                            height: 25
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            radius: Satin.radius.chip
                            color: Util.alpha(root.foreground, 0.08)
                            border.width: 1
                            border.color: Util.alpha(root.foreground, 0.12)
                            Accessible.role: root.aiMode ? Accessible.Button : Accessible.StaticText
                            Accessible.name: root.aiMode ? "Send question" : "Escape closes the launcher"

                            Text {
                                anchors.centerIn: parent
                                text: root.aiMode ? (root.service && root.service.busy ? "…" : "send") : "esc"
                                color: Util.alpha(root.foreground, 0.58)
                                font.pixelSize: Satin.type.label
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: root.aiMode && root.service && !root.service.busy
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.submitAi()
                            }
                        }

                        Rectangle {
                            id: focusKeyline
                            // Keyboard-focus affordance. On the Super path it
                            // draws in from the left as the descent settles;
                            // on the dock path it fades in with the card.
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 16
                            anchors.rightMargin: 16
                            anchors.bottomMargin: 4
                            height: 2
                            radius: 1
                            color: Util.alpha(root.accent, 0.55 * root.surfaceOpacity)
                            opacity: root.revealProgress
                            transform: Scale {
                                xScale: root.motionSource === "keyboard"
                                    ? 0.12 + 0.88 * root.revealProgress : 1
                                yScale: 1
                            }
                        }
                    }

                    AiComposer {
                        id: aiComposer
                        visible: root.aiMode
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? aiComposer.implicitHeight : 0
                        prompt: AiState.draft(root.query)
                        busy: root.service && root.service.busy
                        stopping: root.service && root.service.stopping
                        loading: root.service && root.service.loadingLatest
                        attachmentBlocked: !!root.service && typeof root.service.attachmentBlocked !== "undefined"
                            && root.service.attachmentBlocked
                        hasConversation: root.service && root.service.turns.length > 0
                        foreground: root.foreground
                        background: root.background
                        accent: root.accent
                        onEdited: function(text) { root.query = AiState.prefix + text }
                        onSubmitted: root.submitAi()
                        onHideRequested: root.dismiss()
                        onBackToApps: root.query = ""
                        onStopRequested: { if (root.service) root.service.stop() }
                    }

                    Item {
                        id: recentsStrip
                        // NOTE: visibility must NOT depend on `height` — an invisible
                        // item is excluded from the ColumnLayout, which keeps its
                        // height at 0, which keeps it invisible (circular binding).
                        readonly property bool showStrip: root.recentRows.length > 0 && root.query.length === 0
                        Layout.fillWidth: true
                        Layout.preferredHeight: showStrip ? 94 : 0
                        visible: showStrip
                        clip: true

                        Text {
                            id: recentsLabel
                            anchors.left: parent.left
                            anchors.top: parent.top
                            text: "RECENTS"
                            color: Util.alpha(root.foreground, 0.54)
                            font.pixelSize: Satin.type.header
                            font.weight: Font.DemiBold
                            font.letterSpacing: 1.4
                        }

                        ListView {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: recentsLabel.bottom
                            anchors.topMargin: 8
                            height: 66
                            orientation: ListView.Horizontal
                            spacing: 8
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.recentRows

                            delegate: Rectangle {
                                id: recentTile
                                required property var modelData
                                readonly property var entry: root.rowEntry(modelData)
                                width: 92
                                height: 64
                                radius: Satin.radius.row
                                color: recentMouse.containsMouse ? Util.alpha(root.foreground, 0.10) : Util.alpha(root.foreground, 0.045)
                                border.width: recentMouse.containsMouse ? 1 : 0
                                border.color: Util.alpha(root.accent, 0.42)
                                Accessible.role: Accessible.Button
                                Accessible.name: "Launch " + root.entryName(entry)

                                Image {
                                    width: 34
                                    height: 34
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.top: parent.top
                                    anchors.topMargin: 6
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    source: root.iconSource(recentTile.entry)
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 5
                                    anchors.leftMargin: 5
                                    anchors.rightMargin: 5
                                    horizontalAlignment: Text.AlignHCenter
                                    text: root.entryName(entry)
                                    color: root.foreground
                                    font.pixelSize: Satin.type.label
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: recentMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.launchRow(modelData)
                                }
                            }
                        }
                    }

                    AiPane {
                        id: aiPane
                        visible: AiLayout.paneVisible(root.aiMode, root.service)
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        service: root.service
                        expanded: root.aiExpanded
                        onExpandToggled: root.aiExpanded = !root.aiExpanded
                        onOpenWindowRequested: root.showWorkspaceWindow()
                        foreground: root.foreground
                        background: root.background
                        accent: root.accent
                        onFillPrompt: function(text) {
                            root.query = AiState.prefix + text
                            root.focusInput()
                        }
                        onBackToApps: {
                            root.query = ""
                            searchInput.forceActiveFocus()
                        }
                        onHandedOff: root.dismiss()
                        onHideRequested: root.dismiss()
                    }

                    Text {
                        visible: root.aiMode && !!root.feedbackText
                        Layout.fillWidth: true
                        text: root.feedbackText
                        color: root.accent
                        font.pixelSize: Satin.type.meta
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        visible: !root.aiMode
                        Layout.fillWidth: true
                        Layout.preferredHeight: 18

                        Text {
                            text: root.query.length > 0 ? "RESULTS" : "ALL APPLICATIONS"
                            color: Util.alpha(root.foreground, 0.54)
                            font.pixelSize: Satin.type.header
                            font.weight: Font.DemiBold
                            font.letterSpacing: 1.4
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            text: root.resultRows.length + (root.resultRows.length === 1 ? " result" : " results")
                            color: Util.alpha(root.foreground, 0.42)
                            font.pixelSize: Satin.type.label
                        }
                    }

                    Item {
                        visible: !root.aiMode
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ListView {
                            id: resultList
                            anchors.fill: parent
                            visible: (root.fileMode || root.appLibraryReady) && root.resultRows.length > 0
                            model: root.resultRows
                            spacing: 4
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            currentIndex: root.selectedIndex

                            delegate: Rectangle {
                                id: resultRow
                                required property int index
                                required property var modelData
                                readonly property bool isAction: root.isActionRow(modelData)
                                readonly property bool isFile: modelData && modelData.kind === "file"
                                readonly property bool isWorkspace: modelData && modelData.kind === "workspace"
                                readonly property var entry: root.rowEntry(modelData)
                                readonly property bool selected: index === root.selectedIndex
                                width: ListView.view.width
                                height: root.rowHeight
                                radius: Satin.radius.row
                                color: selected ? Util.alpha(root.accent, 0.17)
                                    : (rowMouse.containsMouse ? Util.alpha(root.foreground, 0.075) : "transparent")
                                border.width: selected ? 1 : 0
                                border.color: Util.alpha(root.accent, 0.42)
                                Accessible.role: Accessible.ListItem
                                Accessible.name: root.rowTitle(modelData)

                                Rectangle {
                                    width: 3
                                    height: selected ? 26 : 0
                                    anchors.left: parent.left
                                    anchors.leftMargin: 1
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: 2
                                    color: root.accent
                                    Behavior on height { NumberAnimation { duration: Satin.motion.state; easing.type: Easing.OutCubic } }
                                }

                                Image {
                                    id: resultIcon
                                    visible: !resultRow.isAction && !resultRow.isWorkspace
                                    width: 40
                                    height: 40
                                    anchors.left: parent.left
                                    anchors.leftMargin: 13
                                    anchors.verticalCenter: parent.verticalCenter
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    source: resultRow.isFile ? Quickshell.iconPath(resultRow.modelData.isDirectory
                                        ? "folder" : "text-x-generic", true) : root.iconSource(resultRow.entry)
                                }

                                Rectangle {
                                    id: actionTile
                                    visible: resultRow.isAction || resultRow.isWorkspace
                                    width: 40
                                    height: 40
                                    anchors.left: parent.left
                                    anchors.leftMargin: 13
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: 10
                                    color: Util.alpha(root.accent, 0.14)
                                    border.width: 1
                                    border.color: Util.alpha(root.accent, 0.38)

                                    Item {
                                        anchors.centerIn: parent
                                        width: 20
                                        height: 20

                                        // Draw icons rather than relying on the font's
                                        // off-centre bearings for search and math glyphs.
                                        Item {
                                            anchors.fill: parent
                                            visible: resultRow.modelData && resultRow.modelData.kind === "search"
                                            Rectangle {
                                                x: 1; y: 1; width: 14; height: 14; radius: 7
                                                color: "transparent"
                                                border.width: 2
                                                border.color: root.accent
                                            }
                                            Rectangle {
                                                x: 11.8; y: 13.5; width: 7; height: 2.2; radius: 1.1
                                                rotation: 45
                                                color: root.accent
                                            }
                                        }
                                        Item {
                                            anchors.fill: parent
                                            visible: resultRow.modelData && resultRow.modelData.kind === "calc"
                                            Rectangle { x: 3; y: 6.5; width: 14; height: 2.5; radius: 1.25; color: root.accent }
                                            Rectangle { x: 3; y: 11; width: 14; height: 2.5; radius: 1.25; color: root.accent }
                                        }
                                        Item {
                                            anchors.fill: parent
                                            visible: resultRow.modelData && resultRow.modelData.kind === "url"
                                            Rectangle {
                                                x: 2.5; y: 9.5; width: 13.5; height: 2.5; radius: 1.25
                                                rotation: -45
                                                color: root.accent
                                            }
                                            Rectangle { x: 10; y: 3; width: 7; height: 2.5; radius: 1.25; color: root.accent }
                                            Rectangle { x: 14.5; y: 3; width: 2.5; height: 7; radius: 1.25; color: root.accent }
                                        }
                                        // Speech mark for Ask AI and saved workspaces.
                                        Item {
                                            anchors.fill: parent
                                            visible: resultRow.modelData && (resultRow.modelData.kind === "askAi"
                                                || resultRow.modelData.kind === "workspace")
                                            Rectangle {
                                                x: 1.5; y: 2; width: 17; height: 13
                                                radius: 4
                                                color: "transparent"
                                                border.width: 2
                                                border.color: root.accent
                                            }
                                            Rectangle { x: 5.5; y: 7.2; width: 2.6; height: 2.6; radius: 1.3; color: root.accent }
                                            Rectangle { x: 9.2; y: 7.2; width: 2.6; height: 2.6; radius: 1.3; color: root.accent }
                                            Rectangle { x: 12.9; y: 7.2; width: 2.6; height: 2.6; radius: 1.3; color: root.accent }
                                        }
                                    }
                                }

                                Text {
                                    id: resultTitle
                                    anchors.left: resultIcon.right
                                    anchors.leftMargin: 13
                                    anchors.right: parent.right
                                    anchors.rightMargin: resultRow.isFile ? 84 : 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: (resultRow.isFile || resultRow.isWorkspace) ? -9 : 0
                                    text: root.rowTitle(resultRow.modelData)
                                    textFormat: Text.PlainText
                                    color: root.foreground
                                    font.pixelSize: Satin.type.result
                                    font.weight: resultRow.selected ? Font.DemiBold : Font.Medium
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: resultRow.isFile || resultRow.isWorkspace
                                    anchors.left: resultTitle.left
                                    anchors.right: resultTitle.right
                                    anchors.top: resultTitle.bottom
                                    anchors.topMargin: 3
                                    text: resultRow.isFile
                                        ? FileSearch.displayParent(resultRow.modelData.parent, root.homePath)
                                        : AiState.workspaceSubtitle(resultRow.modelData.updatedAt)
                                    textFormat: Text.PlainText
                                    color: Util.alpha(root.foreground, 0.50)
                                    font.pixelSize: Satin.type.meta
                                    elide: Text.ElideMiddle
                                }

                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    z: -1
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: root.selectedIndex = resultRow.index
                                    onClicked: root.launchRow(resultRow.modelData)
                                }

                                AiButton {
                                    visible: resultRow.isFile && !resultRow.modelData.isDirectory && resultRow.selected
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Ask AI"
                                    foreground: root.foreground; accent: root.accent
                                    onClicked: root.askFile(resultRow.modelData)
                                }
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 8
                            visible: !resultList.visible

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.fileMode ? (root.fileError ? "File search unavailable"
                                    : root.fileSearching ? "Searching files…"
                                    : root.fileTerms.length < 2 ? "Search files and folders" : "No files found")
                                    : root.appLibraryReady ? "No applications found" : "Loading applications…"
                                color: root.foreground
                                font.pixelSize: Satin.type.result
                                font.weight: Font.DemiBold
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.fileMode ? (root.fileError || (root.fileTerms.length < 2
                                    ? "Type at least two characters after f:." : "Searches names and paths in your home folder."))
                                    : root.appLibraryReady ? "Try a name or keyword." : "Reading installed desktop entries."
                                color: Util.alpha(root.foreground, 0.50)
                                font.pixelSize: Satin.type.meta
                            }
                        }
                    }

                    RowLayout {
                        id: statusRow
                        visible: !root.aiMode
                        Layout.fillWidth: true
                        Layout.preferredHeight: 24

                        Text {
                            text: root.feedbackText || (root.fileMode ? "enter open   alt+enter reveal   ctrl+c path"
                                : "↑↓ navigate   enter launch   tab advance   esc close")
                            color: root.feedbackText ? root.accent : Util.alpha(root.foreground, 0.45)
                            font.pixelSize: Satin.type.label
                            font.weight: root.feedbackText ? Font.DemiBold : Font.Normal
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            text: root.fileMode ? "Files" : "Launcher"
                            color: Util.alpha(root.foreground, 0.34)
                            font.pixelSize: Satin.type.label
                        }
                    }
                }
            }
        }
    }

    // Detached workspace window: shares the retained service; closing it
    // keeps the workspace and the launcher keeps working independently.
    WorkspaceWindow {
        id: workspaceWindow
        service: root.service
        foreground: root.foreground
        background: root.background
        accent: root.accent
    }
}
