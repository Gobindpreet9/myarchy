// LauncherSearch.js — pure DesktopEntries search/ranking fallback.

.pragma library

function text(value) {
    return String(value == null ? "" : value);
}

function entryName(entry) {
    return text((entry && entry.name) || (entry && entry.id) || "");
}

function entrySubtext(entry) {
    return text((entry && entry.genericName) || "");
}

function keywordText(entry) {
    try {
        if (entry && entry.keywords && typeof entry.keywords.join === "function")
            return entry.keywords.join(" ");
    } catch (e) { }
    return "";
}

function searchableText(entry) {
    if (!entry) return "";
    return [entry.name, entry.genericName, entry.comment, keywordText(entry), entry.id]
        .join(" ").toLowerCase();
}

function wordText(value) {
    return text(value)
        .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
        .replace(/[._:/\\-]+/g, " ")
        .toLowerCase();
}

function words(value) {
    var source = wordText(value).split(/[^a-z0-9]+/);
    var result = [];
    for (var i = 0; i < source.length; i++) if (source[i]) result.push(source[i]);
    return result;
}

function acronym(entry) {
    var values = words([entry && entry.name, entry && entry.genericName,
                        keywordText(entry), entry && entry.id].join(" "));
    var result = "";
    for (var i = 0; i < values.length; i++) result += values[i].charAt(0);
    return result;
}

function termMatches(entry, term) {
    if (!term) return true;
    var name = entryName(entry).toLowerCase();
    var id = text(entry && entry.id).toLowerCase();
    if (name.indexOf(term) >= 0 || id.indexOf(term) >= 0 || searchableText(entry).indexOf(term) >= 0)
        return true;
    return term.length <= 5 && acronym(entry).indexOf(term) >= 0;
}

function allTermsMatch(entry, query) {
    var terms = text(query).toLowerCase().trim().split(/\s+/);
    for (var i = 0; i < terms.length; i++) {
        if (terms[i] && !termMatches(entry, terms[i])) return false;
    }
    return true;
}

function score(entry, query) {
    var q = text(query).trim().toLowerCase();
    if (!q) return 0;
    if (!allTermsMatch(entry, q)) return -1;

    var name = entryName(entry).toLowerCase();
    var id = text(entry && entry.id).toLowerCase();
    var haystack = searchableText(entry);
    var nameIndex = name.indexOf(q);
    var idIndex = id.indexOf(q);

    if (name === q) return 12000 - name.length;
    if (id === q) return 11500 - id.length;
    if (nameIndex === 0) return 10000 - name.length;
    if (idIndex === 0) return 9500 - id.length;
    if (nameIndex > 0) return 8000 - nameIndex * 10 - name.length;
    if (idIndex > 0) return 7600 - idIndex * 10 - id.length;

    var hayIndex = haystack.indexOf(q);
    if (hayIndex >= 0) return 6000 - hayIndex;

    var shortName = acronym(entry);
    var acronymIndex = shortName.indexOf(q);
    if (acronymIndex === 0) return 5000 - shortName.length;
    if (acronymIndex > 0) return 4600 - acronymIndex * 10 - shortName.length;
    return 4000 - name.length;
}

function normalizeDesktopId(value) {
    var id = text(value).trim();
    if (id.slice(-8).toLowerCase() === ".desktop") id = id.slice(0, -8);
    return id.toLowerCase();
}

function bestMatch(rows, token) {
    var input = rows && typeof rows.length === "number" ? rows : [];
    var needle = normalizeDesktopId(token);
    if (!needle) return null;

    var exactName = null;
    var exactNameCount = 0;
    var prefix = null;
    var prefixCount = 0;

    for (var i = 0; i < input.length; i++) {
        var row = input[i];
        var entry = row && row.entry ? row.entry : null;
        if (!entry) continue;
        var id = normalizeDesktopId(entry.id);
        if (id === needle) return row;
    }

    for (var n = 0; n < input.length; n++) {
        var nameRow = input[n];
        var nameEntry = nameRow && nameRow.entry ? nameRow.entry : null;
        if (!nameEntry) continue;
        if (entryName(nameEntry).toLowerCase() === needle) {
            exactName = nameRow;
            exactNameCount++;
        }
    }
    if (exactNameCount === 1) return exactName;
    if (exactNameCount > 1) return null;

    for (var p = 0; p < input.length; p++) {
        var prefixRow = input[p];
        var prefixEntry = prefixRow && prefixRow.entry ? prefixRow.entry : null;
        if (!prefixEntry) continue;
        var prefixId = normalizeDesktopId(prefixEntry.id);
        var prefixName = entryName(prefixEntry).toLowerCase();
        if (prefixId.indexOf(needle) === 0 || prefixName.indexOf(needle) === 0) {
            prefix = prefixRow;
            prefixCount++;
        }
    }
    return prefixCount === 1 ? prefix : null;
}

function matchingToken(rows, tokens, entry) {
    var target = normalizeDesktopId(entry && entry.id);
    var input = tokens && typeof tokens.length === "number" ? tokens : [];
    if (!target) return "";
    for (var i = 0; i < input.length; i++) {
        var row = bestMatch(rows, input[i]);
        if (row && row.entry && normalizeDesktopId(row.entry.id) === target)
            return text(input[i]).trim();
    }
    return "";
}

// Precompute pinned-token lookups once per app-list/pin change instead of
// resolving the full list for every visible row. Returns a map of
// normalized entry id -> original pinned token.
function buildPinIndex(rows, tokens) {
    var index = ({});
    var input = tokens && typeof tokens.length === "number" ? tokens : [];
    for (var i = 0; i < input.length; i++) {
        var row = bestMatch(rows, input[i]);
        if (!row || !row.entry) continue;
        var key = normalizeDesktopId(row.entry.id);
        if (!key || index[key] !== undefined) continue;
        index[key] = text(input[i]).trim();
    }
    return index;
}

function pinTokenFromIndex(index, entry) {
    var target = normalizeDesktopId(entry && entry.id);
    if (!target || !index) return "";
    var token = index[target];
    return token === undefined ? "" : text(token);
}

function sortedEntries(values, query, hiddenCallback) {
    var input = values && typeof values.length === "number" ? values : [];
    var q = text(query).trim();
    var rows = [];
    for (var i = 0; i < input.length; i++) {
        var entry = input[i];
        if (!entry || entry.noDisplay || (hiddenCallback && hiddenCallback(entry))) continue;
        var name = entryName(entry);
        if (!name) continue;
        var value = score(entry, q);
        if (value < 0) continue;
        rows.push({ entry: entry, score: value, key: name.toLowerCase() });
    }
    rows.sort(function(a, b) {
        if (q && a.score !== b.score) return b.score - a.score;
        if (a.key < b.key) return -1;
        if (a.key > b.key) return 1;
        return 0;
    });
    return rows;
}
