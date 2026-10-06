.pragma library

// Layout only. All colors and surface tokens come from the launcher theme.
var composerHeight = 60;
var composerMaxHeight = 170; // six visible composing lines caps growth

function idleCardHeight(attachment, composer, chrome) {
    // 20px insets + composer + one attachment row; grows with the draft.
    var extra = typeof chrome === "number" && isFinite(chrome) && chrome >= 0
        ? chrome : (attachment ? 48 : 0);
    return Math.ceil(40 + (composer > 0 ? composer : composerHeight) + extra);
}

function paneVisible(aiMode, service) {
    return !!aiMode && !!service && (service.turns.length > 0 || !!service.attachment || !!service.loadingLatest);
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
