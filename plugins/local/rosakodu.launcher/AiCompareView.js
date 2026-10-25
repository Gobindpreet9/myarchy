.pragma library

.import "AiState.js" as AiState

// Pure view helpers for AiCompare.qml (the `compare` block renderer). A block is
// untrusted data of any shape: every function returns an empty/neutral result
// instead of throwing. Option indices are ALWAYS the raw indices into
// `block.options` (the host forwards them to submitChoice/choiceWire), so an
// option without a usable name is skipped but never renumbers its neighbours.
//
// View state (`compare:<blockIndex>`) is {pin: index|-1, hide: [index...]}: the
// only things a person may change. There is no scoring and no sorting; the
// authored order stands except that a pinned option is shown first.

var MATRIX_MIN_WIDTH = 560;   // two visible options; each extra column needs 200px
var MATRIX_COLUMN_MIN = 200;
var MATRIX_MAX_OPTIONS = 4;   // more options than this always use shortlist/detail
var MAX_STATE_BYTES = 400;
var DASH = "\u2014";          // a fact the option does not state

function plain(value) { return AiState.calcPlain(value); }
function isIndex(value) { return typeof value === "number" && isFinite(value) && value === Math.floor(value) && value >= 0; }
function utf8Length(text) {
    var n = 0;
    for (var i = 0; i < text.length; ++i) {
        var c = text.charCodeAt(i);
        if (c < 0x80) n += 1;
        else if (c < 0x800) n += 2;
        else if (c >= 0xd800 && c <= 0xdbff) { n += 4; ++i; }
        else n += 3;
    }
    return n;
}

// The usable options of a block: {options: [{index, name, summary, facts:[{label,
// value}], pros, cons, recommended}], verdict}. Text is cleaned and bounded like
// the text export (AiState.vocabLines). Only the FIRST recommended option keeps
// its badge, as the catalogue does.
function model(block) {
    var result = {options: [], verdict: ""};
    var data = AiState.vocabObject(plain(block));
    if (!data || data.type !== "compare") return result;
    var raw = AiState.vocabArray(data.options, AiState.CHOICE_INDEX_MAX + 1);
    var recommended = false;
    for (var i = 0; i < raw.length; ++i) {
        var entry = AiState.vocabObject(raw[i]);
        var name = entry ? AiState.vocabText(entry.name, 80) : "";
        if (!name) continue;
        var option = {index: i, name: name, summary: AiState.vocabText(entry.summary, 160),
            facts: [], pros: [], cons: [], recommended: false};
        var facts = AiState.vocabArray(entry.facts, AiState.VOCAB_LIST_MAX);
        for (var f = 0; f < facts.length; ++f) {
            var fact = AiState.vocabObject(facts[f]);
            var label = fact ? AiState.vocabText(fact.label, 60) : "";
            if (label) option.facts.push({label: label, value: AiState.vocabText(fact.value, 120)});
        }
        var lists = [["pros", entry.pros], ["cons", entry.cons]];
        for (var k = 0; k < lists.length; ++k) {
            var points = AiState.vocabArray(lists[k][1], AiState.VOCAB_LIST_MAX);
            for (var p = 0; p < points.length; ++p) {
                var point = AiState.vocabText(points[p], 160);
                if (point) option[lists[k][0]].push(point);
            }
        }
        if (entry.recommended === true && !recommended) { option.recommended = true; recommended = true; }
        result.options.push(option);
    }
    result.verdict = AiState.vocabText(data.verdict, 240);
    return result;
}

// "matrix" (one column per option) or the historical "stacked" mode name
// (a shortlist plus one inspected detail card).
function composition(width, optionCount) {
    return typeof width === "number" && isFinite(width)
        && width >= MATRIX_MIN_WIDTH + Math.max(0, optionCount - 2) * MATRIX_COLUMN_MIN && optionCount >= 2
        && optionCount <= MATRIX_MAX_OPTIONS ? "matrix" : "stacked";
}

// A closed, valid state for the options that exist (`indices` = their raw
// indices). Stale indices (no such option) are dropped; a pin on a hidden option
// is dropped; hiding every option is impossible, so the lowest hidden index is
// restored until one is visible.
function sanitizeState(value, indices) {
    var out = {pin: -1, hide: []};
    var raw = AiState.vocabObject(plain(value));
    var valid = Array.isArray(indices) ? indices : [];
    if (!raw || valid.length === 0) return out;
    var hide = [], list = AiState.vocabArray(raw.hide, AiState.CHOICE_INDEX_MAX + 1);
    for (var i = 0; i < list.length; ++i) {
        if (isIndex(list[i]) && valid.indexOf(list[i]) >= 0 && hide.indexOf(list[i]) < 0) hide.push(list[i]);
    }
    hide.sort(function (a, b) { return a - b; });
    if (hide.length >= valid.length) hide.shift();
    out.hide = hide;
    if (isIndex(raw.pin) && valid.indexOf(raw.pin) >= 0 && hide.indexOf(raw.pin) < 0) out.pin = raw.pin;
    return out;
}

function stateBytes(state) { return utf8Length(JSON.stringify(state)); }

// Display order: {visible: pinned first then authored order, hidden: authored}.
function arrange(options, state) {
    var visible = [], hidden = [], pinned = null;
    var hide = state && Array.isArray(state.hide) ? state.hide : [];
    var list = Array.isArray(options) ? options : [];
    for (var i = 0; i < list.length; ++i) {
        if (hide.indexOf(list[i].index) >= 0) hidden.push(list[i]);
        else if (state && list[i].index === state.pin) pinned = list[i];
        else visible.push(list[i]);
    }
    if (pinned) visible.unshift(pinned);
    return {visible: visible, hidden: hidden};
}

// The next state after toggling the pin / the hidden flag of option `index`, or
// null when the change is refused (unknown option, pinning a hidden one, hiding
// the last visible one). `state` must come from sanitizeState.
function togglePin(state, index, indices) {
    if (!isIndex(index) || indices.indexOf(index) < 0 || state.hide.indexOf(index) >= 0) return null;
    return {pin: state.pin === index ? -1 : index, hide: state.hide.slice()};
}
function toggleHide(state, index, indices) {
    if (!isIndex(index) || indices.indexOf(index) < 0) return null;
    var at = state.hide.indexOf(index);
    if (at >= 0) {
        var shown = state.hide.slice();
        shown.splice(at, 1);
        return {pin: state.pin, hide: shown};
    }
    if (state.hide.length + 1 >= indices.length) return null; // the last visible option stays
    var hide = state.hide.concat([index]).sort(function (a, b) { return a - b; });
    return {pin: state.pin === index ? -1 : state.pin, hide: hide};
}

// Fact rows over the shown options (given in DISPLAY order): labels are unioned
// in first-seen order scanning the options in AUTHORED order, so pinning never
// reshuffles the rows. A label is matched case-insensitively; an option that
// repeats a label fills a further row (nothing is dropped). `values` is aligned
// with `shown`; null = this option does not state the fact.
function factRows(shown) {
    var list = Array.isArray(shown) ? shown : [];
    var authored = list.slice().sort(function (a, b) { return a.index - b.index; });
    var rows = [], byKey = {};
    for (var i = 0; i < authored.length; ++i) {
        var seen = {};
        var facts = authored[i].facts || [];
        for (var f = 0; f < facts.length; ++f) {
            var base = facts[f].label.toLowerCase();
            var n = seen[base] = (seen[base] || 0) + 1;
            var key = base + "\u0000" + n;
            var row = byKey[key];
            if (!row) {
                row = byKey[key] = {label: facts[f].label, values: list.map(function () { return null; })};
                rows.push(row);
            }
            row.values[list.indexOf(authored[i])] = facts[f].value;
        }
    }
    return rows;
}

// The accessible name of one option: "Name, recommended, chosen, pinned".
function optionName(option, picked, pinned) {
    var parts = [option.name];
    if (option.recommended) parts.push("recommended");
    if (option.index === picked) parts.push("chosen");
    if (pinned) parts.push("pinned");
    return parts.join(", ");
}

// Scroll the nearest scrollable ancestor of `start` (anything with a
// `contentItem` and a numeric `contentY`) just far enough to show `item`; an item
// taller than the viewport lines its top up instead. False when there is none.
function reveal(item, start) {
    var flick = start;
    while (flick && !(flick.contentItem && typeof flick.contentY === "number")) flick = flick.parent;
    if (!item || !flick) return false;
    var top = item.mapToItem(flick.contentItem, 0, 0).y, bottom = top + item.height, y = flick.contentY;
    if (top < y || item.height > flick.height) y = top;
    else if (bottom > y + flick.height) y = bottom - flick.height;
    flick.contentY = Math.max(0, Math.min(y, Math.max(0, flick.contentHeight - flick.height)));
    return true;
}

// The focus descriptor for "ask about this option" ({index, label, detail}, the
// raw option index): label = the name, detail = "<summary>; Facts: l: v, ...;
// Pros: ...; Cons: ..." with empty parts skipped. Cleaning and the 80/240 clamps
// are AiState.askDescriptor's; null when there is no option.
function askAbout(option) {
    if (!option || typeof option.name !== "string") return null;
    var parts = [];
    if (option.summary) parts.push(option.summary);
    var facts = (option.facts || []).map(function (fact) { return fact.value ? fact.label + ": " + fact.value : fact.label; });
    if (facts.length > 0) parts.push("Facts: " + facts.join(", "));
    if ((option.pros || []).length > 0) parts.push("Pros: " + option.pros.join(", "));
    if ((option.cons || []).length > 0) parts.push("Cons: " + option.cons.join(", "));
    var ask = AiState.askDescriptor("compare", option.index, option.name, parts.join("; "));
    return ask ? {index: ask.index, label: ask.label, detail: ask.detail} : null;
}
