pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "CsvPage.js" as CsvPage
import "SatinGlass.js" as Satin

// Collapsible "Explore all rows" view over a durable CSV source (AiCsvSource):
// one 25-row page at a time, sorted/filtered by the worker over the WHOLE file.
// It owns presentation only. The owner persists `viewState`
// ({sort, dir, filter, page}) per turn; this component reads it, applies it to
// the source once per source-ready (setView, then goPage), and emits
// `viewStateEdited` with the new FULL state only when the person edits.
Item {
    id: root

    required property var source
    required property color foreground
    required property color background
    required property color accent
    property var viewState: ({})
    property bool expanded: false
    signal viewStateEdited(var state)

    readonly property bool sourceReady: source.status === "ready" && !!source.meta
    readonly property bool registering: source.status === "registering"
    readonly property var columns: sourceReady && Array.isArray(source.meta.columns)
        ? source.meta.columns.slice(0, CsvPage.MAX_COLUMNS) : []
    readonly property int columnCount: columns.length
    readonly property var rows: sourceReady && source.page && Array.isArray(source.page.rows)
        ? source.page.rows.slice(0, CsvPage.PAGE_SIZE) : []
    readonly property int viewRowCount: source.viewRows >= 0 ? source.viewRows
        : source.page && typeof source.page.viewRows === "number" ? source.page.viewRows : -1
    readonly property int pageCount: viewRowCount >= 0 ? CsvPage.pageCountFor(viewRowCount) : 0
    readonly property int lastPage: Math.max(0, pageCount - 1)
    readonly property int shownPage: source.page && typeof source.page.page === "number" ? source.page.page : _page
    readonly property color dim: Qt.alpha(foreground, 0.80)

    // Local copy of the arrangement. Edits update it first, then the source.
    property int _sort: -1
    property int _dir: 1
    property string _filter: ""
    property int _page: 0
    property var _appliedMeta: null

    readonly property string countText: registering
        ? CsvPage.rowCountLabel(source.progressRows, -1, true, false)
        : !sourceReady ? ""
        : source.viewPending || source.viewRows < 0
            ? CsvPage.rowCountLabel(-1, -1, true, false)
            : CsvPage.rowCountLabel(source.meta.rows, source.viewRows, false, _filter.length > 0)
    readonly property bool sortIsText: _sort >= 0 && !numericColumn(_sort)
    readonly property string sortNote: sortIsText && _filter.length > 0
        ? "Sorted by character code; filtered rows are counted over the whole file"
        : sortIsText ? "Sorted by character code"
        : _filter.length > 0 ? "Filtered rows are counted over the whole file" : ""

    implicitWidth: 660
    implicitHeight: visible ? body.implicitHeight : 0
    visible: sourceReady || registering
    Accessible.role: Accessible.Pane
    Accessible.name: "Explore all rows"

    function numericColumn(column) {
        var stats = sourceReady ? source.meta.stats : null
        var item = stats && column >= 0 && column < stats.length ? stats[column] : null
        return !!item && !!item.typeCounts && item.nonEmpty > 0 && item.typeCounts.number === item.nonEmpty
    }

    function _current() { return {sort: _sort, dir: _dir, filter: _filter, page: _page} }

    function _normalized(raw) {
        var s = raw && typeof raw === "object" ? raw : ({})
        var sort = CsvPage.isInt(s.sort, -1, columnCount - 1) ? s.sort : -1
        return {sort: sort, dir: s.dir === -1 && sort >= 0 ? -1 : 1,
            filter: CsvPage.cleanFilter(s.filter), page: CsvPage.isInt(s.page, 0, 9007199254740991) ? s.page : 0}
    }

    function _same(a, b) {
        return a.sort === b.sort && a.dir === b.dir && a.filter === b.filter && a.page === b.page
    }

    function _isDefault(s) { return s.sort === -1 && s.dir === 1 && s.filter === "" && s.page === 0 }

    // A new source (new meta object) starts on the default view, so the stored
    // arrangement is re-applied only when it is not the default. Later owner
    // changes that differ from the local copy are applied too. Never emits.
    function _applyOwnerState() {
        if (!sourceReady) return
        var wanted = _normalized(viewState)
        var fresh = source.meta !== _appliedMeta
        if (!fresh && _same(wanted, _current())) return
        _appliedMeta = source.meta
        _sort = wanted.sort
        _dir = wanted.dir
        _filter = wanted.filter
        _page = wanted.page
        if (fresh && _isDefault(wanted)) return
        source.setView(_sort, _dir, _filter)
        source.goPage(_page)
    }

    function _edited() { viewStateEdited(_current()) }

    function _cycleSort(column) {
        if (_sort !== column) { _sort = column; _dir = 1 }
        else if (_dir === 1) _dir = -1
        else { _sort = -1; _dir = 1 }
        _page = 0
        source.setView(_sort, _dir, _filter)
        _edited()
    }

    function _setFilter(text) {
        _filter = CsvPage.cleanFilter(text)
        _page = 0
        source.setView(_sort, _dir, _filter)
        _edited()
    }

    function goToPage(n) {
        if (viewRowCount < 0 || !CsvPage.isInt(n, 0, 9007199254740991)) return
        var target = Math.max(0, Math.min(lastPage, n))
        if (target === _page && target === shownPage) return
        _page = target
        source.goPage(target)
        _edited()
    }

    function goToRow(row) {
        if (!CsvPage.isInt(row, 1, 9007199254740991) || viewRowCount < 1) return
        goToPage(Math.floor((Math.min(row, viewRowCount) - 1) / CsvPage.PAGE_SIZE))
    }

    function retry() {
        source.setView(_sort, _dir, _filter)
        source.goPage(_page)
    }

    onViewStateChanged: _applyOwnerState()
    Component.onCompleted: _applyOwnerState()

    Connections {
        target: root.source
        function onStatusChanged() { root._applyOwnerState() }
        function onMetaChanged() { root._applyOwnerState() }
        // The source clamps a page past the end; follow it silently.
        function onPageChanged() {
            if (root.source.page && !root.source.viewPending && typeof root.source.page.page === "number")
                root._page = root.source.page.page
        }
    }

    Column {
        id: body
        width: root.width
        spacing: Satin.space.tip

        Flow {
            width: parent.width
            spacing: Satin.space.tip

            AiButton {
                objectName: "aiCsvExplorerToggle"
                visible: root.sourceReady
                text: (root.expanded ? "▾ " : "▸ ") + "Explore all rows"
                foreground: root.foreground
                accent: root.accent
                focusPolicy: Qt.StrongFocus
                Accessible.name: "Explore all rows, " + (root.expanded ? "expanded" : "collapsed")
                onClicked: root.expanded = !root.expanded
            }

            Text {
                objectName: "aiCsvExplorerTitle"
                visible: !root.sourceReady
                height: 34
                text: "Explore all rows"
                textFormat: Text.PlainText
                color: root.dim
                font.pixelSize: Satin.type.meta
                font.weight: Font.Medium
                verticalAlignment: Text.AlignVCenter
                Accessible.name: text
            }

            Text {
                objectName: "aiCsvExplorerCount"
                height: 34
                text: root.countText
                textFormat: Text.PlainText
                color: root.dim
                font.pixelSize: Satin.type.small
                verticalAlignment: Text.AlignVCenter
                Accessible.name: text
            }
        }

        Loader {
            id: bodyLoader
            objectName: "aiCsvExplorerBody"
            active: root.expanded && root.sourceReady
            visible: active
            width: parent.width
            sourceComponent: expandedContent
        }
    }

    Component {
        id: expandedContent

        Column {
            spacing: Satin.space.tip

            TextField {
                id: filterField
                objectName: "aiCsvExplorerFilter"
                width: Math.min(parent.width, 280)
                text: root._filter
                placeholderText: "Filter rows…"
                maximumLength: CsvPage.MAX_FILTER_CODEPOINTS
                selectByMouse: true
                activeFocusOnTab: true
                color: root.foreground
                placeholderTextColor: root.dim
                selectionColor: Qt.alpha(root.accent, 0.35)
                selectedTextColor: root.foreground
                font.pixelSize: Satin.type.meta
                Accessible.name: "Filter rows"
                Accessible.description: "Matches text anywhere in a row, ignoring case. Searches the whole file."
                onTextEdited: root._setFilter(text)
                background: Rectangle {
                    radius: Satin.radius.field
                    color: Qt.alpha(root.foreground, 0.04)
                    border.width: filterField.activeFocus ? 2 : 1
                    border.color: filterField.activeFocus ? root.accent : Qt.alpha(root.foreground, Satin.keyline.inner)
                }
            }

            Rectangle {
                id: frame
                objectName: "aiCsvExplorerFocusRing"
                width: parent.width
                height: root.rows.length > 0 ? gridColumn.height + 2 * Satin.space.base : 0
                visible: root.rows.length > 0
                radius: Satin.radius.chip
                color: root.background
                border.width: grid.activeFocus ? 2 : 1
                border.color: grid.activeFocus ? root.accent : Qt.alpha(root.foreground, Satin.keyline.hair)

                // The grid is declared before the headers so Tab reaches it first,
                // as in the CSV preview; the headers are drawn above it.
                Item {
                    id: gridColumn
                    x: Satin.space.base
                    y: Satin.space.base
                    width: parent.width - 2 * Satin.space.base
                    height: grid.headH + grid.height

                    ListView {
                        id: grid
                        objectName: "aiCsvExplorerViewport"
                        readonly property int colWidth: Math.max(120,
                            Math.floor(width / Math.max(1, root.columnCount)))
                        readonly property int rowH: 28
                        readonly property int headH: 30
                        readonly property int maxVisibleRows: 8
                        readonly property bool needsHorizontalBar: root.columnCount * colWidth > width
                        y: headH
                        width: parent.width
                        height: Math.min(root.rows.length, maxVisibleRows) * rowH + bottomMargin
                        bottomMargin: needsHorizontalBar ? 10 : 0
                        contentWidth: root.columnCount * colWidth
                        model: root.rows
                        clip: true
                        cacheBuffer: 0
                        reuseItems: false
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.AutoFlickDirection
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Pane
                        Accessible.name: "CSV rows. Arrow keys scroll. Page Up and Page Down scroll, then change page."

                        readonly property real maxX: Math.max(0, contentWidth - width)
                        readonly property real maxY: Math.max(0, contentHeight - height + bottomMargin)

                        function moveBy(dx, dy) {
                            contentX = Math.max(0, Math.min(maxX, contentX + dx))
                            contentY = Math.max(0, Math.min(maxY, contentY + dy))
                        }

                        function revealColumn(column) {
                            var left = column * colWidth
                            var next = contentX
                            if (left < contentX) next = left
                            else if (left + colWidth > contentX + width) next = left + colWidth - width
                            contentX = Math.max(0, Math.min(maxX, next))
                        }

                        Keys.onPressed: function(event) {
                            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                            switch (event.key) {
                            case Qt.Key_Left: moveBy(-colWidth, 0); break
                            case Qt.Key_Right: moveBy(colWidth, 0); break
                            case Qt.Key_Up: moveBy(0, -rowH); break
                            case Qt.Key_Down: moveBy(0, rowH); break
                            case Qt.Key_PageUp:
                                if (contentY <= 0 && root._page > 0) root.goToPage(root._page - 1)
                                else moveBy(0, -height)
                                break
                            case Qt.Key_PageDown:
                                if (contentY >= maxY && root._page < root.lastPage) root.goToPage(root._page + 1)
                                else moveBy(0, height)
                                break
                            case Qt.Key_Home:
                                if (ctrl) root.goToPage(0)
                                else { contentX = 0; contentY = 0 }
                                break
                            case Qt.Key_End:
                                if (ctrl) root.goToPage(root.lastPage)
                                else contentY = maxY
                                break
                            default: return
                            }
                            event.accepted = true
                        }
                        TapHandler { onTapped: grid.forceActiveFocus(Qt.MouseFocusReason) }

                        // A new page starts at its first row.
                        onModelChanged: contentY = 0

                        ScrollBar.horizontal: ScrollBar {
                            policy: ScrollBar.AsNeeded
                            contentItem: Rectangle {
                                implicitWidth: 32
                                implicitHeight: 6
                                radius: 3
                                color: Qt.alpha(root.foreground, 0.3)
                            }
                            background: Item {}
                        }
                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                            contentItem: Rectangle {
                                implicitWidth: 6
                                implicitHeight: 32
                                radius: 3
                                color: Qt.alpha(root.foreground, 0.3)
                            }
                            background: Item {}
                        }

                        delegate: Item {
                            id: rowItem
                            required property var modelData
                            required property int index
                            objectName: "aiCsvExplorerRow" + index
                            width: grid.contentWidth
                            height: grid.rowH

                            Rectangle {
                                anchors.fill: parent
                                color: rowItem.index % 2 === 1 ? Qt.alpha(root.foreground, 0.04) : "transparent"
                            }

                            Repeater {
                                model: root.columnCount
                                delegate: Text {
                                    id: cell
                                    required property int index
                                    objectName: "aiCsvExplorerCell"
                                    x: index * grid.colWidth
                                    width: grid.colWidth
                                    height: grid.rowH
                                    leftPadding: Satin.space.tip
                                    rightPadding: Satin.space.tip
                                    // A quoted field may hold CR/LF (or another line
                                    // separator); a Text would paint extra lines over the
                                    // neighbouring rows. Display only: one visible return
                                    // glyph per run, the data itself is never edited.
                                    text: rowItem.modelData && rowItem.modelData[index] !== undefined
                                        ? String(rowItem.modelData[index]).replace(/[\r\n\u000b\u000c\u0085\u2028\u2029]+/g, " \u23ce ") : ""
                                    textFormat: Text.PlainText
                                    wrapMode: Text.NoWrap
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    color: Qt.alpha(root.foreground, 0.86)
                                    font.pixelSize: Satin.type.small
                                    verticalAlignment: Text.AlignVCenter
                                    Accessible.name: text
                                }
                            }
                        }
                    }

                    Item {
                        id: headerClip
                        width: parent.width
                        height: grid.headH
                        clip: true

                        Rectangle {
                            x: -grid.contentX
                            width: grid.contentWidth
                            height: parent.height
                            color: Qt.alpha(root.foreground, 0.06)
                        }

                        Repeater {
                            objectName: "aiCsvExplorerHeaders"
                            model: root.columnCount
                            delegate: Button {
                                id: headerButton
                                required property int index
                                readonly property bool sorted: root._sort === index
                                readonly property bool numeric: root.numericColumn(index)
                                readonly property string hint: numeric
                                    ? "Sorts numerically. Empty cells come last."
                                    : "Sorts by character code, not by language order. Empty cells come last."
                                objectName: "aiCsvExplorerHeader" + index
                                x: index * grid.colWidth - grid.contentX
                                width: grid.colWidth
                                height: grid.headH
                                padding: 0
                                hoverEnabled: true
                                focusPolicy: Qt.StrongFocus
                                text: String(root.columns[index]) + (sorted ? (root._dir === 1 ? "  ↑" : "  ↓") : "")
                                Accessible.name: String(root.columns[index])
                                    + (sorted ? (root._dir === 1 ? ", sorted ascending" : ", sorted descending") : "")
                                Accessible.description: hint
                                ToolTip.visible: hovered
                                ToolTip.delay: 600
                                ToolTip.text: hint
                                onClicked: root._cycleSort(index)
                                Keys.onReturnPressed: clicked()
                                Keys.onEnterPressed: clicked()
                                onActiveFocusChanged: { if (activeFocus) grid.revealColumn(index) }
                                background: Rectangle {
                                    color: headerButton.hovered ? Qt.alpha(root.foreground, 0.08) : "transparent"
                                    border.width: headerButton.visualFocus ? 2 : 0
                                    border.color: root.accent
                                }
                                contentItem: Text {
                                    text: headerButton.text
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    leftPadding: Satin.space.tip
                                    rightPadding: Satin.space.tip
                                    color: headerButton.sorted ? root.accent : root.foreground
                                    font.pixelSize: Satin.type.small
                                    font.weight: Font.DemiBold
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }
                }
            }

            Text {
                objectName: "aiCsvExplorerEmpty"
                visible: root.rows.length === 0 && root.viewRowCount === 0
                width: parent.width
                text: "No rows match."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dim
                font.pixelSize: Satin.type.meta
                Accessible.name: text
            }

            Text {
                objectName: "aiCsvExplorerError"
                visible: root.source.error !== ""
                width: parent.width
                text: root.source.error
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.pixelSize: Satin.type.meta
                Accessible.name: text
            }

            AiButton {
                objectName: "aiCsvExplorerRetry"
                visible: root.source.error !== "" && root.source.retryable
                enabled: visible
                text: "Retry"
                foreground: root.foreground
                accent: root.accent
                focusPolicy: Qt.StrongFocus
                onClicked: root.retry()
            }

            Flow {
                objectName: "aiCsvExplorerFooter"
                width: parent.width
                spacing: Satin.space.tip

                AiButton {
                    objectName: "aiCsvExplorerFirst"
                    text: "First"
                    Accessible.name: "First page"
                    enabled: root.shownPage > 0
                    foreground: root.foreground
                    accent: root.accent
                    focusPolicy: Qt.StrongFocus
                    onClicked: root.goToPage(0)
                }
                AiButton {
                    objectName: "aiCsvExplorerPrev"
                    text: "Prev"
                    Accessible.name: "Previous page"
                    enabled: root.shownPage > 0
                    foreground: root.foreground
                    accent: root.accent
                    focusPolicy: Qt.StrongFocus
                    onClicked: root.goToPage(root._page - 1)
                }
                Text {
                    objectName: "aiCsvExplorerPage"
                    height: 34
                    text: CsvPage.pageLabel(root.shownPage, root.pageCount)
                    textFormat: Text.PlainText
                    color: root.dim
                    font.pixelSize: Satin.type.meta
                    verticalAlignment: Text.AlignVCenter
                    Accessible.name: text
                }
                AiButton {
                    objectName: "aiCsvExplorerNext"
                    text: "Next"
                    Accessible.name: "Next page"
                    enabled: root.shownPage < root.lastPage
                    foreground: root.foreground
                    accent: root.accent
                    focusPolicy: Qt.StrongFocus
                    onClicked: root.goToPage(root._page + 1)
                }
                AiButton {
                    objectName: "aiCsvExplorerLast"
                    text: "Last"
                    Accessible.name: "Last page"
                    enabled: root.shownPage < root.lastPage
                    foreground: root.foreground
                    accent: root.accent
                    focusPolicy: Qt.StrongFocus
                    onClicked: root.goToPage(root.lastPage)
                }
                Text {
                    objectName: "aiCsvExplorerRange"
                    height: 34
                    text: root.source.page ? CsvPage.rangeLabel(root.shownPage, root.rows.length, root.viewRowCount) : ""
                    textFormat: Text.PlainText
                    color: root.dim
                    font.pixelSize: Satin.type.small
                    verticalAlignment: Text.AlignVCenter
                    Accessible.name: text
                }
                Row {
                    spacing: Satin.space.tip
                    Text {
                        height: 34
                        text: "Go to row"
                        textFormat: Text.PlainText
                        color: root.dim
                        font.pixelSize: Satin.type.small
                        verticalAlignment: Text.AlignVCenter
                    }
                    TextField {
                        id: rowField
                        objectName: "aiCsvExplorerGoto"
                        width: 96
                        placeholderText: "Row #"
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,15}$/ }
                        activeFocusOnTab: true
                        color: root.foreground
                        placeholderTextColor: root.dim
                        selectionColor: Qt.alpha(root.accent, 0.35)
                        selectedTextColor: root.foreground
                        font.pixelSize: Satin.type.meta
                        Accessible.name: "Go to row"
                        onAccepted: {
                            if (text.length > 0) root.goToRow(Number(text))
                            text = ""
                        }
                        background: Rectangle {
                            radius: Satin.radius.field
                            color: Qt.alpha(root.foreground, 0.04)
                            border.width: rowField.activeFocus ? 2 : 1
                            border.color: rowField.activeFocus ? root.accent : Qt.alpha(root.foreground, Satin.keyline.inner)
                        }
                    }
                }
            }

            Text {
                objectName: "aiCsvExplorerClipNote"
                visible: !!root.source.page && root.source.page.cellsTruncated === true
                width: parent.width
                text: "Long values are clipped"
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dim
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }

            Text {
                objectName: "aiCsvExplorerSortNote"
                visible: root.sortNote !== ""
                width: parent.width
                text: root.sortNote
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.dim
                font.pixelSize: Satin.type.small
                Accessible.name: text
            }
        }
    }
}
