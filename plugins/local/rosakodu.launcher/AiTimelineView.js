.pragma library
.import "AiState.js" as AiState

// Pure helpers for the `timeline` block renderer (AiTimeline.qml). Nothing here
// touches the scene: every function takes plain data and returns a fresh
// bounded value, so the layout and state rules are unit-testable and a hostile
// block or a stale saved entry can never throw.
//
// Saved state (`plan:<blockIndex>`): {done: [itemIndex, ...]} - the AUTHORED item
// indexes the person checked off, deduped and sorted ascending. Entries that no
// longer name a usable item are ignored (never an error), and the renderer
// always emits the complete next object, so the stored entry is <= ~100 B for
// 16 items (the contract is <= 300 B).

var MAX_ITEMS = 16;
var LABEL_MAX = 80;
var WHEN_MAX = 24;
var DETAIL_MAX = 160;
var TITLE_MAX = 160;
var MINUTES_MAX = 1440;
// At most this many `done` entries of a saved object are even looked at.
var DONE_SCAN_MAX = 64;
// A duration bar is never thinner than this, so 1 minute stays visible.
var MIN_BAR = 6;
var STATE_BYTES_MAX = 300;

function plain(value) {
    try { return JSON.parse(JSON.stringify(value)); } catch (e) { return null; }
}
function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}
// Model text is data: strings (and finite numbers) only, control / bidi /
// zero-width characters turned into spaces, whitespace collapsed, clipped.
function text(value, max) {
    if (typeof value === "number" && isFinite(value)) value = String(value);
    return typeof value === "string" ? AiState.contextText(value, max, {}, false) : "";
}

// Minutes as the renderer shows them: a finite number rounded half up to a
// whole minute and clamped to 0..1440; anything else (strings, NaN, negative,
// 0.4) is 0 = unspecified.
function cleanMinutes(value) {
    if (typeof value !== "number" || !isFinite(value)) return 0;
    return Math.min(MINUTES_MAX, Math.max(0, Math.round(value)));
}

// '45 min', '1 h', '1 h 30 min'. Rounds to the nearest whole minute (half up),
// never shows seconds, "" for 0 / unspecified. Not clamped: the total of 16
// items can exceed a day ('24 h', '384 h').
function durationText(minutes) {
    if (typeof minutes !== "number" || !isFinite(minutes)) return "";
    var m = Math.round(minutes);
    if (m <= 0) return "";
    var h = Math.floor(m / 60), r = m % 60;
    if (h === 0) return r + " min";
    return r === 0 ? h + " h" : h + " h " + r + " min";
}

// The block as the renderer draws it: {title, items:[{i, label, when, minutes,
// detail, duration}]} in authored order, `i` the item's AUTHORED index (an
// unusable entry is skipped, never renumbered). null when no item is usable.
function normalize(block) {
    var b = plain(block);
    if (!isObject(b) || !Array.isArray(b.items)) return null;
    var items = [];
    for (var i = 0; i < b.items.length && i < MAX_ITEMS; ++i) {
        var entry = b.items[i];
        if (!isObject(entry)) continue;
        var label = text(entry.label, LABEL_MAX);
        if (label === "") continue;
        var minutes = cleanMinutes(entry.minutes);
        items.push({i: i, label: label, when: text(entry.when, WHEN_MAX), minutes: minutes,
            detail: text(entry.detail, DETAIL_MAX), duration: durationText(minutes)});
    }
    return items.length > 0 ? {title: text(b.title, TITLE_MAX), items: items} : null;
}

// Bar length as a fraction of the LONGEST item (0 for an unspecified item).
function barFractions(items) {
    var longest = 0, i;
    for (i = 0; i < items.length; ++i) longest = Math.max(longest, items[i].minutes);
    var out = [];
    for (i = 0; i < items.length; ++i) out.push(longest > 0 && items[i].minutes > 0 ? items[i].minutes / longest : 0);
    return out;
}
// Pixels for one bar: 0 when unspecified, else proportional but at least
// MIN_BAR and never longer than the room.
function barWidth(fraction, minutes, available) {
    if (!(minutes > 0)) return 0;
    var room = typeof available === "number" && isFinite(available) ? Math.max(0, available) : 0;
    var f = typeof fraction === "number" && isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0;
    return Math.min(room, Math.max(MIN_BAR, Math.round(f * room)));
}

// Sum of the items that state a duration; only worth showing for two or more.
function totalMinutes(items) {
    var sum = 0;
    for (var i = 0; i < items.length; ++i) sum += items[i].minutes > 0 ? items[i].minutes : 0;
    return sum;
}
function totalText(items) {
    var counted = 0;
    for (var i = 0; i < items.length; ++i) if (items[i].minutes > 0) ++counted;
    if (counted < 2) return "";
    return "Total: " + durationText(totalMinutes(items));
}

// The persisted done list that still names a usable item: integers only,
// deduped, ascending. Anything else in `saved` is ignored.
function restoreDone(items, saved) {
    var s = plain(saved);
    if (!isObject(s) || !Array.isArray(s.done)) return [];
    var valid = {}, i;
    for (i = 0; i < items.length; ++i) valid[items[i].i] = true;
    var seen = {}, out = [];
    for (i = 0; i < s.done.length && i < DONE_SCAN_MAX; ++i) {
        var v = s.done[i];
        if (typeof v !== "number" || v !== Math.floor(v) || valid[v] !== true || seen[v] === true) continue;
        seen[v] = true;
        out.push(v);
    }
    return out.sort(function(a, b) { return a - b; });
}
// The first unfinished DISPLAY row, in authored order. Done entries always name
// authored indexes, not display positions: invalid authored items leave gaps.
// -1 means there is no unfinished usable item. Derived only; never saved.
function nextUnfinished(items, saved) {
    var done = restoreDone(items, saved);
    for (var row = 0; row < items.length; ++row)
        if (done.indexOf(items[row].i) < 0) return row;
    return -1;
}
// The done list after flipping one item, computed from the PERSISTED entry.
// null when `index` is not a usable item.
function toggled(items, saved, index) {
    var usable = false, i;
    for (i = 0; i < items.length; ++i) if (items[i].i === index) usable = true;
    if (!usable) return null;
    var list = restoreDone(items, saved), at = list.indexOf(index);
    if (at >= 0) list.splice(at, 1); else list.push(index);
    return list.sort(function(a, b) { return a - b; });
}
function stateBytes(state) {
    try { return JSON.stringify(state).length; } catch (e) { return -1; }
}

// What a `?` on a row asks about (the shared focus seam): {index: AUTHORED
// item index, label (<= 80), detail (<= 240)}; detail is '<when>; <duration>;
// <detail>' with empty parts skipped. The seam's own bounds are FOCUS_LABEL_MAX
// 80 and FOCUS_DETAIL_MAX 240 (AiState.js).
var ASK_DETAIL_MAX = 240;
function askPart(item) {
    var parts = [];
    if (item.when !== "") parts.push(item.when);
    if (item.duration !== "") parts.push(item.duration);
    if (item.detail !== "") parts.push(item.detail);
    var detail = parts.join("; ");
    if (detail.length > ASK_DETAIL_MAX) {
        detail = detail.slice(0, ASK_DETAIL_MAX);
        if (/[\ud800-\udbff]$/.test(detail)) detail = detail.slice(0, -1);
    }
    return {index: item.i, label: item.label, detail: detail};
}

function progressText(done, count) {
    return done + " of " + count + " done";
}
// Accessible name of one row: 'when, label, duration, done|not done'.
function rowName(item, done) {
    var parts = [];
    if (item.when !== "") parts.push(item.when);
    parts.push(item.label);
    if (item.duration !== "") parts.push(item.duration);
    parts.push(done ? "done" : "not done");
    return parts.join(", ");
}
