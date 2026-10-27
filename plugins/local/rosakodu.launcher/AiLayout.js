.pragma library

// Layout only. All colors and surface tokens come from the launcher theme.
var composerHeight = 60;
var composerMaxHeight = 170; // six visible composing lines caps growth

// Presentation only: never reorder stored blocks or their interaction keys.
// A practical answer is a work area, not a document with its tool at the end.
function answerComposition(blocks) {
    // Carry the source and placement together. Separate QML bindings can update
    // in different orders when replacing one answer with a different shape.
    var result = {blocks: blocks || [], kind: "", title: "", primary: [], controls: [], support: [], sources: []};
    var priorities = ["openui", "calc", "compare", "form", "timeline", "diagram", "gallery", "chart", "market",
        "steps", "check", "predict", "table", "actions"];
    var count = blocks && typeof blocks.length === "number" ? blocks.length : 0;
    if (count > 64) return result; // Keep the legacy view, never silently drop a tail.
    var primary = -1, i, p;
    for (p = 0; p < priorities.length && primary < 0; ++p) {
        for (i = 0; i < count; ++i) {
            if (blocks[i] && blocks[i].type === priorities[p]) { primary = i; break; }
        }
    }
    if (primary < 0) return result;
    result.kind = blocks[primary].type;
    result.title = typeof blocks[primary].title === "string" ? blocks[primary].title.trim() : "";
    result.primary.push(primary);
    for (i = 0; i < count; ++i) {
        if (i === primary || !blocks[i]) continue;
        if (blocks[i].type === "sources") result.sources.push(i);
        else if (result.kind === "diagram" && blocks[i].type === "slider") result.controls.push(i);
        else result.support.push(i);
    }
    return result;
}

function blocksAt(blocks, indices) {
    var result = [];
    for (var i = 0; i < indices.length; ++i) result.push(blocks[indices[i]]);
    return result;
}

// An explicit disclosure always exposes the untouched full answer. End the
// orientation at a word boundary; never change stored prose or text export.
function orientationExcerpt(text, maximum) {
    if (text.length <= maximum) return text;
    var prefix = text.slice(0, maximum);
    var space = prefix.lastIndexOf(" ");
    if (space >= maximum * 0.6) prefix = prefix.slice(0, space);
    if (/[\ud800-\udbff]$/.test(prefix)) prefix = prefix.slice(0, -1);
    return prefix.trim() + "\u2026";
}

function idleCardHeight(attachment, composer, chrome) {
    // 20px insets + composer + one attachment row; grows with the draft.
    var extra = typeof chrome === "number" && isFinite(chrome) && chrome >= 0
        ? chrome : (attachment ? 48 : 0);
    return Math.ceil(40 + (composer > 0 ? composer : composerHeight) + extra);
}

function paneVisible(aiMode, service) {
    return !!aiMode && !!service && (service.turns.length > 0 || !!service.attachment || !!service.loadingLatest
        || !!service.workspaceName || !!service.linkedSourceId || !!service.workspaceActionError);
}

function detachedMinimumHeight(titleHeight, composerHeightArg, chromeHeight, reserveHeight) {
    // The detached window's 720x560 floor is a MINIMUM, not a fixed size:
    // full CSV-preview disclosures plus a capped long draft can exceed 560px,
    // and a clipped disclosure is unreachable. Track measured content instead.
    var title = typeof titleHeight === "number" && isFinite(titleHeight) && titleHeight > 0
        ? titleHeight : 0;
    var composer = typeof composerHeightArg === "number" && composerHeightArg > 0
        ? composerHeightArg : composerHeight;
    var chrome = typeof chromeHeight === "number" && isFinite(chromeHeight) && chromeHeight > 0
        ? chromeHeight : 0;
    var reserve = typeof reserveHeight === "number" && isFinite(reserveHeight) && reserveHeight > 0
        ? reserveHeight : 0;
    return Math.max(560, Math.ceil(2 * 20 + 2 * 14 + title + composer + chrome + reserve));
}

function answerHeight(responseHeight, chromeHeight, composerHeight, maxHeight) {
    // Match the host's 20px inset, composer and 14px inter-section spacing.
    var composer = composerHeight > 0 ? composerHeight : 60;
    var cap = maxHeight > 0 ? maxHeight : 720;
    return Math.min(cap, Math.max(260, Math.ceil(2 * 20 + composer + 14 + responseHeight + chromeHeight)));
}
