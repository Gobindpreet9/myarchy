pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtCore
import "SatinGlass.js" as Satin
import "AiState.js" as AiState

Column {
    id: root
    objectName: "aiImage"
    property var block: ({})
    required property color foreground
    required property color background
    required property color accent
    // Trusted host configuration, never a field supplied by the answer schema.
    readonly property string defaultMediaRoot: decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.GenericStateLocation))
        .replace(/^file:\/\//, "")) + "/omarchy/launcher-ai/media"
    property string mediaRoot: defaultMediaRoot
    property real maxFigureWidth: 620
    property real maxFigureHeight: 340
    // Comparison galleries reserve an equal frame without hiding the subject.
    property real comparisonFrameHeight: 0
    // Alternative candidates resolved by the media worker; cycling is local.
    property int alternativeIndex: 0
    signal openUrl(string url)
    signal alternativeChanged(int index)
    readonly property var alternatives: block.alternatives || []
    readonly property var current: alternativeIndex > 0 && alternativeIndex <= alternatives.length
        ? alternatives[alternativeIndex - 1] : block
    readonly property string safeSource: validatedSource(current.imageUrl)
    readonly property int imageStatus: picture.status
    readonly property bool imageReady: picture.status === Image.Ready && !current.error
    readonly property real imageAspect: picture.implicitHeight > 0 ? picture.implicitWidth / picture.implicitHeight : 1
    // Fit the whole subject, not a fixed-width letterbox. Left alignment also
    // keeps the credit attached to the figure at both launcher widths.
    readonly property real frameWidth: comparisonFrameHeight > 0 ? Math.max(0, Math.min(width, maxFigureWidth)) : imageReady
        ? Math.max(0, Math.min(width, maxFigureWidth, maxFigureHeight * imageAspect)) : Math.max(0, Math.min(width, maxFigureWidth))
    readonly property real frameHeight: comparisonFrameHeight > 0 ? comparisonFrameHeight : imageReady
        ? frameWidth / Math.max(0.001, imageAspect) : Math.max(0, Math.min(240, maxFigureHeight, frameWidth * 0.56))
    readonly property string sourceUrl: String(current.sourceUrl || "")
    readonly property bool sourceAllowed: AiState.sourceCommand(sourceUrl).length > 0
    readonly property string attributionText: String(current.attribution || qsTr("Attribution was not provided for this image."))
        .replace(/\n[ \t]*\n(?:[ \t]*\n)+/g, "\n\n")
    readonly property string statusText: current.error ? String(current.error)
        : !safeSource ? (current.imageUrl ? qsTr("Image unavailable: not a trusted local image.") : qsTr("Looking for an image…"))
        : picture.status === Image.Error ? qsTr("The cached image could not be loaded.")
        : picture.status !== Image.Ready ? qsTr("Loading cached image…") : ""
    spacing: Satin.space.tip

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    function validatedSource(value) {
        var url = String(value || "");
        if (!url.startsWith("file:///")) return "";
        var path;
        try { path = decodeURIComponent(url.slice(7)); } catch (e) { return ""; }
        var base = mediaRoot.replace(/\/+$/, "");
        if (!base.startsWith("/") || !path.startsWith(base + "/")) return "";
        if (/[?#\u0000-\u001f\\]/.test(path) || path.split("/").some(function(p) { return p === ".." || p === "."; })) return "";
        // The resolver owns file creation and verifies bytes; QML only reads its
        // cache. Restrict to raster formats, never active SVG or arbitrary URLs.
        if (!/\.(png|jpe?g|webp)$/i.test(path)) return "";
        return url;
    }

    Rectangle {
        id: figureFrame
        objectName: "aiImageFrame"
        width: root.frameWidth
        height: root.frameHeight
        radius: Satin.radius.field
        color: root.imageReady && root.comparisonFrameHeight <= 0 ? "transparent" : root.alpha(root.foreground, 0.025)
        border.width: root.imageReady && !activeFocus ? 0 : 1
        border.color: activeFocus ? root.accent : root.alpha(root.foreground, Satin.keyline.inner)
        // Focusable even while loading or errored: a keyboard user must be
        // able to reach the cell (and its status text); the viewer keys stay
        // guarded on imageReady.
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: root.imageReady
            ? qsTr("Enlarge image: ") + String(root.block.caption || root.block.query || root.block.title || qsTr("Image"))
            : root.statusText
        Keys.onSpacePressed: if (root.imageReady) viewer.open()
        Keys.onReturnPressed: if (root.imageReady) viewer.open()
        Image {
            id: picture
            objectName: "aiImageRaster"
            anchors.fill: parent
            source: root.safeSource
            sourceSize.width: 960
            // A single decode bound preserves the source's real aspect ratio.
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            visible: root.imageReady
            // Keep the raster unlayered: no shader/mask resources surviving a
            // retained panel reload or a fractional device-pixel-ratio change.
            Accessible.role: Accessible.Graphic
            Accessible.name: String(root.block.query || root.block.title || qsTr("Answer image"))
        }
        MouseArea {
            objectName: "aiImageZoomArea"
            anchors.fill: parent
            enabled: root.imageReady
            cursorShape: Qt.PointingHandCursor
            onClicked: viewer.open()
            Accessible.name: qsTr("Enlarge image")
        }
        Text {
            objectName: "aiImageStatus"
            anchors.centerIn: parent
            width: Math.max(0, parent.width - Satin.space.section * 2)
            text: root.statusText
            visible: text.length > 0
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            color: root.alpha(root.foreground, 0.76)
            font.pixelSize: Satin.type.meta
            Accessible.name: text
        }
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: Satin.radius.field
            border.width: figureFrame.activeFocus ? 2 : 0
            border.color: root.accent
        }
    }
    Flow {
        width: root.frameWidth
        spacing: Satin.space.base
        Button {
            id: credit
            objectName: "aiImageSource"
            width: Math.min(root.frameWidth, contentItem.implicitWidth + 2 * padding)
            visible: !!root.current.attribution || root.sourceUrl.length > 0
            text: qsTr("Photo details")
            enabled: root.sourceUrl.length > 0 ? root.sourceAllowed : !!root.current.attribution
            activeFocusOnTab: true
            padding: Satin.space.base
            implicitHeight: Math.max(32, contentItem.implicitHeight + 2 * padding)
            onClicked: if (enabled) creditPopup.open()
            Accessible.name: qsTr("Photo details: ") + root.attributionText
            contentItem: Text {
                text: credit.text
                textFormat: Text.PlainText
                maximumLineCount: 1
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: Satin.type.meta
                color: root.alpha(root.foreground, credit.enabled ? 0.76 : 0.5)
            }
            background: Rectangle {
                radius: Satin.radius.chip
                color: credit.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                border.width: credit.visualFocus ? 2 : 0
                border.color: root.accent
            }
        }
        Button {
            id: nextImage
            objectName: "aiImageNext"
            visible: root.alternatives.length > 0
            width: Math.min(root.frameWidth, contentItem.implicitWidth + 2 * padding)
            text: qsTr("Show another") + " · " + (root.alternativeIndex + 1) + "/" + (root.alternatives.length + 1)
            activeFocusOnTab: true
            padding: Satin.space.base
            implicitHeight: Math.max(32, contentItem.implicitHeight + 2 * padding)
            onClicked: root.alternativeChanged((root.alternativeIndex + 1) % (root.alternatives.length + 1))
            Accessible.name: qsTr("Show another image for this subject, option ")
                + (root.alternativeIndex + 1) + qsTr(" of ") + (root.alternatives.length + 1)
            contentItem: Text {
                text: nextImage.text
                textFormat: Text.PlainText
                maximumLineCount: 1
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: Satin.type.meta
                color: root.alpha(root.foreground, nextImage.hovered || nextImage.visualFocus ? 0.85 : 0.6)
            }
            background: Rectangle {
                radius: Satin.radius.chip
                color: nextImage.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                border.width: nextImage.visualFocus ? 2 : 0
                border.color: root.accent
            }
        }
    }

    Popup {
        id: creditPopup
        objectName: "aiImageCreditPopup"
        parent: Overlay.overlay
        width: Math.max(0, Math.min(400, parent ? parent.width - 2 * Satin.space.section : 400))
        x: parent ? (parent.width - width) / 2 : 0
        y: parent ? Math.max(Satin.space.tip, (parent.height - height) / 2) : 0
        padding: Satin.space.section
        modal: true
        dim: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: closeCredit.forceActiveFocus(Qt.PopupFocusReason)
        onClosed: {
            if (credit.visible && credit.enabled) credit.forceActiveFocus(Qt.PopupFocusReason)
        }
        background: Rectangle {
            radius: Satin.radius.field
            color: root.background
            border.width: 1
            border.color: root.alpha(root.foreground, Satin.keyline.hair)
        }
        contentItem: Column {
            spacing: Satin.space.gutter
            Accessible.role: Accessible.Dialog
            Accessible.name: qsTr("Photo credit")
            Row {
                width: parent.width
                Text {
                    objectName: "aiImageCreditTitle"
                    width: parent.width - closeCredit.width
                    height: closeCredit.height
                    text: qsTr("Photo credit")
                    textFormat: Text.PlainText
                    verticalAlignment: Text.AlignVCenter
                    color: root.foreground
                    font.pixelSize: Satin.type.name
                    font.weight: Font.DemiBold
                    Accessible.role: Accessible.Heading
                }
                Button {
                    id: closeCredit
                    objectName: "aiImageCreditClose"
                    width: 32
                    height: 32
                    text: "×"
                    activeFocusOnTab: true
                    onClicked: creditPopup.close()
                    Accessible.name: qsTr("Close photo credit")
                    contentItem: Text {
                        text: closeCredit.text
                        color: root.alpha(root.foreground, 0.76)
                        font.pixelSize: Satin.type.search
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: Satin.radius.chip
                        color: closeCredit.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                        border.width: closeCredit.visualFocus ? 2 : 0
                        border.color: root.accent
                    }
                }
            }
            ScrollView {
                id: creditScroll
                objectName: "aiImageCreditScroll"
                width: parent.width
                height: Math.max(0, Math.min(260, creditDisclosure.implicitHeight,
                    creditPopup.parent ? creditPopup.parent.height - 160 : 260))
                contentWidth: availableWidth
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                Text {
                    id: creditDisclosure
                    objectName: "aiImageCreditText"
                    width: creditScroll.availableWidth
                    text: root.attributionText + (root.sourceUrl ? "\n\n" + root.sourceUrl : "")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.alpha(root.foreground, 0.82)
                    font.pixelSize: Satin.type.meta
                    lineHeight: 1.25
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }
            Button {
                id: viewSource
                objectName: "aiImageViewSource"
                text: qsTr("View source")
                enabled: root.sourceAllowed
                activeFocusOnTab: true
                padding: Satin.space.tip
                implicitHeight: Math.max(36, contentItem.implicitHeight + 2 * padding)
                onClicked: {
                    // Revalidate at the explicit navigation action, not at the
                    // credit disclosure or while loading the local raster.
                    if (AiState.sourceCommand(root.sourceUrl).length > 0) {
                        root.openUrl(root.sourceUrl)
                        creditPopup.close()
                    }
                }
                Accessible.name: qsTr("View image source: ") + root.sourceUrl
                contentItem: Text {
                    text: viewSource.text + " ↗"
                    textFormat: Text.PlainText
                    font.pixelSize: Satin.type.meta
                    color: root.alpha(root.foreground, viewSource.enabled ? 0.82 : 0.5)
                }
                background: Rectangle {
                    radius: Satin.radius.chip
                    color: root.alpha(root.foreground, viewSource.hovered ? 0.08 : 0.04)
                    border.width: viewSource.visualFocus ? 2 : 0
                    border.color: root.accent
                }
            }
        }
    }

    // Enlarged viewer: fit at 1x, 2x zoom with drag panning; Esc returns
    // focus to the figure. Local cached raster only, same trust rules.
    Popup {
        id: viewer
        objectName: "aiImageViewer"
        parent: Overlay.overlay
        width: parent ? Math.max(0, Math.min(parent.width - 2 * Satin.space.section, 1080)) : 800
        height: parent ? Math.max(0, parent.height - 2 * Satin.space.section) : 640
        x: parent ? (parent.width - width) / 2 : 0
        y: parent ? (parent.height - height) / 2 : 0
        modal: true
        dim: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        readonly property real zoom: zoomed ? 2 : 1
        property bool zoomed: false
        onZoomedChanged: Qt.callLater(viewerPan.centerImage)
        onOpened: closeViewer.forceActiveFocus(Qt.PopupFocusReason)
        onClosed: {
            viewer.zoomed = false
            if (root.imageReady) figureFrame.forceActiveFocus(Qt.PopupFocusReason)
        }
        background: Rectangle {
            radius: Satin.radius.field
            color: root.background
            border.width: 1
            border.color: root.alpha(root.foreground, Satin.keyline.hair)
        }
        contentItem: Column {
            spacing: Satin.space.tip
            Accessible.role: Accessible.Dialog
            Accessible.name: qsTr("Image viewer")
            Row {
                id: viewerHeader
                width: parent.width
                spacing: Satin.space.base
                Text {
                    width: Math.max(0, parent.width - viewerTools.width - parent.spacing)
                    height: viewerTools.height
                    verticalAlignment: Text.AlignVCenter
                    text: String(root.block.query || root.block.title || qsTr("Image"))
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.foreground
                    font.pixelSize: Satin.type.name
                    font.weight: Font.DemiBold
                }
                Row {
                    id: viewerTools
                    spacing: Satin.space.base
                    Button {
                        id: zoomButton
                        objectName: "aiImageViewerZoom"
                        text: viewer.zoomed ? qsTr("Fit") : qsTr("200%")
                        activeFocusOnTab: true
                        padding: Satin.space.tip
                        implicitHeight: Math.max(32, contentItem.implicitHeight + 2 * padding)
                        onClicked: viewer.zoomed = !viewer.zoomed
                        Accessible.name: viewer.zoomed ? qsTr("Fit image to window") : qsTr("Zoom image to 200 percent")
                        contentItem: Text {
                            text: zoomButton.text
                            textFormat: Text.PlainText
                            color: root.alpha(root.foreground, 0.8)
                            font.pixelSize: Satin.type.meta
                        }
                        background: Rectangle {
                            radius: Satin.radius.chip
                            color: root.alpha(root.foreground, zoomButton.hovered ? 0.08 : 0.04)
                            border.width: zoomButton.visualFocus ? 2 : 0
                            border.color: root.accent
                        }
                    }
                    Button {
                        id: closeViewer
                        objectName: "aiImageViewerClose"
                        text: "×"
                        width: 32
                        height: 32
                        activeFocusOnTab: true
                        onClicked: viewer.close()
                        Accessible.name: qsTr("Close the image viewer")
                        contentItem: Text {
                            text: closeViewer.text
                            color: root.alpha(root.foreground, 0.76)
                            font.pixelSize: Satin.type.search
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: Satin.radius.chip
                            color: closeViewer.hovered ? root.alpha(root.foreground, 0.045) : "transparent"
                            border.width: closeViewer.visualFocus ? 2 : 0
                            border.color: root.accent
                        }
                    }
                }
            }
            Flickable {
                id: viewerPan
                objectName: "aiImageViewerPan"
                width: parent.width
                height: Math.max(0, viewer.availableHeight - viewerHeader.height - viewerCredit.implicitHeight - 2 * parent.spacing)
                clip: true
                contentWidth: Math.max(width, viewerPicture.width)
                contentHeight: Math.max(height, viewerPicture.height)
                boundsBehavior: Flickable.StopAtBounds
                activeFocusOnTab: viewer.zoomed
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Zoomed image. Drag or use arrow keys to pan.")
                function centerImage() {
                    contentX = Math.max(0, (contentWidth - width) / 2);
                    contentY = Math.max(0, (contentHeight - height) / 2);
                }
                function pan(dx, dy) {
                    contentX = Math.max(0, Math.min(contentWidth - width, contentX + dx));
                    contentY = Math.max(0, Math.min(contentHeight - height, contentY + dy));
                }
                Keys.onLeftPressed: pan(-40, 0)
                Keys.onRightPressed: pan(40, 0)
                Keys.onUpPressed: pan(0, -40)
                Keys.onDownPressed: pan(0, 40)
                readonly property real fitScale: viewerPicture.implicitWidth > 0 && viewerPicture.implicitHeight > 0
                    ? Math.min(width / viewerPicture.implicitWidth, height / viewerPicture.implicitHeight) : 1
                readonly property real baseWidth: fitScale * viewerPicture.implicitWidth
                readonly property real baseHeight: fitScale * viewerPicture.implicitHeight
                Image {
                    id: viewerPicture
                    objectName: "aiImageViewerImage"
                    // The hidden popup must not eagerly decode a second raster.
                    source: viewer.visible ? root.safeSource : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    width: Math.round(viewerPan.baseWidth * viewer.zoom)
                    height: Math.round(viewerPan.baseHeight * viewer.zoom)
                    x: Math.max(0, (viewerPan.width - width) / 2)
                    y: Math.max(0, (viewerPan.height - height) / 2)
                    Accessible.role: Accessible.Graphic
                    Accessible.name: String(root.block.query || root.block.title || qsTr("Image"))
                }
            }
            Text {
                id: viewerCredit
                width: parent.width
                visible: text.length > 0
                text: root.attributionText
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: root.alpha(root.foreground, 0.76)
                font.pixelSize: Satin.type.label
            }
        }
    }
}
