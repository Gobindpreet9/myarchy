pragma ComponentBehavior: Bound

import QtQuick
import "SatinGlass.js" as Satin

// A small labelled set of contextual photographs: variants, examples, styles.
// Each cell reuses AiImage, so per-item loading, errors, credits, replacement
// and the enlarged viewer behave exactly like a single answer image.
Column {
    id: gallery
    objectName: "aiGallery"

    property var block: ({})
    property int blockIndex: 0
    property var uiState: null
    property string mediaRoot: ""
    required property color foreground
    required property color background
    required property color accent
    signal uiStateEdited(string key, var value)
    signal openUrl(string url)

    readonly property var items: {
        var result = [], source = block ? block.items : null;
        for (var i = 0; source && i < source.length; ++i) result.push(source[i]);
        return result;
    }
    readonly property int columns: Math.max(1, Math.min(items.length, width >= 900 ? 3 : width >= 600 ? 2 : 1))
    readonly property real cellWidth: columns > 0
        ? Math.max(0, (width - (columns - 1) * Satin.space.gutter) / columns) : width
    readonly property var rows: {
        var result = [];
        for (var i = 0; i < gallery.items.length; i += gallery.columns) {
            var row = [];
            for (var j = i; j < i + gallery.columns && j < gallery.items.length; ++j) {
                row.push({item: gallery.items[j], index: j, isLast: j === gallery.items.length - 1});
            }
            result.push(row);
        }
        return result;
    }
    function alternativeIndex(itemIndex) {
        var value = gallery.uiState ? gallery.uiState["gallery:" + gallery.blockIndex + ":" + itemIndex] : undefined;
        return typeof value === "number" && value >= 0 ? value : 0;
    }

    spacing: Satin.space.gutter

    Repeater {
        model: gallery.rows
        delegate: Row {
            id: galleryRow
            required property var modelData
            required property int index
            width: gallery.width
            spacing: Satin.space.gutter

            Repeater {
                model: galleryRow.modelData
                delegate: Column {
                    id: galleryCell
                    required property var modelData
                    width: gallery.cellWidth
                    spacing: Satin.space.tip

                    AiImage {
                        width: parent.width
                        maxFigureWidth: gallery.cellWidth
                        maxFigureHeight: Math.max(160, Math.min(300, gallery.cellWidth * 0.75))
                        comparisonFrameHeight: Math.max(180, Math.min(280, gallery.cellWidth * 0.7))
                        block: galleryCell.modelData.item
                        mediaRoot: gallery.mediaRoot || defaultMediaRoot
                        alternativeIndex: gallery.alternativeIndex(galleryCell.modelData.index)
                        foreground: gallery.foreground
                        background: gallery.background
                        accent: gallery.accent
                        onOpenUrl: url => gallery.openUrl(url)
                        onAlternativeChanged: function(index) {
                            gallery.uiStateEdited("gallery:" + gallery.blockIndex + ":" + galleryCell.modelData.index, index)
                        }
                    }
                    Text {
                        objectName: "aiGalleryCaption_" + gallery.blockIndex + "_" + galleryCell.modelData.index
                        width: parent.width
                        text: String(galleryCell.modelData.item.caption || "")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: gallery.alpha(gallery.foreground, 0.75)
                        font.pixelSize: Satin.type.meta
                        Accessible.name: text
                    }
                }
            }
        }
    }

    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
}
