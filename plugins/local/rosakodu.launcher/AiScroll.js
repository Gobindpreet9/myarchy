.pragma library

// Roving keyboard cursors keep actual focus on one control. Reveal their new
// row/cell explicitly: a focus-change handler cannot observe cursor movement.
function reveal(item, x, y, width, height) {
    for (var parent = item.parent; parent; parent = parent.parent) {
        if (!parent.contentItem || typeof parent.contentY !== "number"
                || typeof parent.contentHeight !== "number") continue;
        var point = item.mapToItem(parent.contentItem, x, y);
        var next = parent.contentY;
        if (point.y < next) next = point.y;
        else if (point.y + height > next + parent.height) next = point.y + height - parent.height;
        parent.contentY = Math.max(0, Math.min(Math.max(0, parent.contentHeight - parent.height), next));
    }
}
