.pragma library

// Pure validators and helpers for the durable CSV source worker protocol
// (`ai_csv_source.py --serve`): one JSON object per line, ids echoed back.
//
// Nothing here reads a file or starts a process. Every validator returns a
// freshly built, bounded object (never the worker's own object) or null, and
// worker-supplied error text is NEVER displayed: `safeError` maps anything not
// on the allowlist to one generic static string.

var PAGE_SIZE = 25;
var MAX_COLUMNS = 20;
var MAX_CELL_CODEPOINTS = 80;
var MAX_FILTER_CODEPOINTS = 200;
var MAX_REQUEST_BYTES = 8192;
var MAX_RESPONSE_BYTES = 262144;
var MAX_PATH_UNITS = 4096;
var MAX_SAFE = 9007199254740991;
var MAX_ID = 2147483647;
// ai_csv_source.py validate_meta accepts columnCount up to 2 ** 31; a tighter
// client bound would reject a reply for a copy the worker already registered.
var MAX_COLUMN_COUNT = 2147483648;

var SOURCE_ID = /^src-[0-9a-f]{16}$/;
var STATES = ["ready", "originChanged", "originMissing", "copyMissing"];
var TYPES = ["number", "date", "text", "unsure", "empty"];
var TYPE_COUNTS = ["number", "date", "text", "unsure"];

// Static texts the QML object itself raises (never worker supplied).
var ERR = {
    invalid: "CSV source returned an invalid response.",
    unavailable: "CSV source is unavailable.",
    stopped: "CSV source stopped. Try again.",
    timeout: "CSV source timed out. Try again.",
    start: "CSV source could not start. Try again.",
    path: "Choose a CSV file inside your home directory.",
    superseded: "Superseded."
};

// Worker-supplied strings that may be shown verbatim (the real worker's static
// refusals). Everything else is replaced by ERR.unavailable. Keep this list
// exact-match; the two parse messages below carry bounded integers only.
var KNOWN_ERRORS = [
    ERR.path, ERR.superseded, ERR.unavailable, ERR.invalid,
    "Choose a text file inside your home directory.", "Attachment must be inside your home directory.",
    "Invalid attachment path.", "Credential and secret files cannot be attached.",
    "Attachment is unavailable or is a symbolic link.", "Only explicit .csv files can be copied.",
    "Only regular files can be copied.", "File changed while reading; try again.",
    "CSV is larger than 64 MiB.", "CSV has more than 500,000 rows.", "CSV has a line longer than 1 MiB.",
    "Attachment is binary.", "Attachment must be UTF-8 text.", "CSV attachment is empty.",
    "CSV header could not be parsed.", "CSV attachment has no header row.",
    "Choose a CSV file with a shorter path.", "Could not store the CSV copy.", "Invalid source id.",
    "Source copy is missing.", "Source copy is damaged.", "Source storage is unsafe.", "Stale view.",
    "Too many rows to sort; filter first.", "Response is too large.", "Request is too large.",
    "Request needs an integer id.", "Unknown operation.", "Invalid view request.", "Invalid page request.",
    "Invalid sort column.", "Invalid sort direction.", "Invalid filter."
];
var PARSE_ERROR = /^(?:CSV could not be parsed near line [0-9]{1,10} \(invalid quotes or oversized field\)\.|CSV line [0-9]{1,10} has [0-9]{1,10} columns; the header has [0-9]{1,10}\.)$/;
var RETRYABLE = [ERR.invalid, ERR.stopped, ERR.timeout, ERR.start, ERR.superseded, ERR.unavailable,
    "Stale view.", "File changed while reading; try again."];

function isInt(value, minimum, maximum) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value
        && value >= minimum && value <= maximum;
}

// Codepoint count of a string, or -1 when it holds a lone surrogate.
function codepoints(value) {
    var count = 0;
    for (var k = 0; k < value.length; ++k) {
        var c = value.charCodeAt(k);
        if (c >= 0xd800 && c <= 0xdbff) {
            if (k + 1 >= value.length) return -1;
            var d = value.charCodeAt(k + 1);
            if (d < 0xdc00 || d > 0xdfff) return -1;
            ++k;
        } else if (c >= 0xdc00 && c <= 0xdfff) return -1;
        ++count;
    }
    return count;
}

// A string of well-formed Unicode with at most `maximum` codepoints.
function validText(value, maximum) {
    if (typeof value !== "string" || value.length > maximum * 2) return false;
    var count = codepoints(value);
    return count >= 0 && count <= maximum;
}

function utf8Bytes(text) {
    var bytes = 0;
    for (var k = 0; k < text.length; ++k) {
        var c = text.charCodeAt(k);
        if (c < 0x80) bytes += 1;
        else if (c < 0x800) bytes += 2;
        else if (c >= 0xd800 && c <= 0xdbff && k + 1 < text.length
                 && text.charCodeAt(k + 1) >= 0xdc00 && text.charCodeAt(k + 1) <= 0xdfff) { bytes += 4; ++k; }
        else bytes += 3;
    }
    return bytes;
}

function validSourceId(value) {
    return typeof value === "string" && SOURCE_ID.test(value);
}

// A path the request budget can carry; the worker still does the real check.
function validPath(path) {
    return typeof path === "string" && path.length > 0 && path.length <= MAX_PATH_UNITS && path.indexOf("\0") < 0;
}

// Filter text as the worker will receive it: well-formed, at most 200 codepoints.
function cleanFilter(text) {
    if (typeof text !== "string") return "";
    var out = "";
    var count = 0;
    for (var k = 0; k < text.length && count < MAX_FILTER_CODEPOINTS; ++k) {
        var c = text.charCodeAt(k);
        if (c >= 0xd800 && c <= 0xdbff) {
            var d = k + 1 < text.length ? text.charCodeAt(k + 1) : 0;
            if (d >= 0xdc00 && d <= 0xdfff) { out += text.charAt(k) + text.charAt(k + 1); ++k; ++count; }
        } else if (c < 0xdc00 || c > 0xdfff) { out += text.charAt(k); ++count; }
    }
    return out;
}

// One request line (with newline) or null when it exceeds the 8 KiB budget.
function requestLine(id, op, fields) {
    var request = {id: id, op: op};
    for (var key in fields) request[key] = fields[key];
    var line = JSON.stringify(request) + "\n";
    return utf8Bytes(line) > MAX_REQUEST_BYTES ? null : line;
}

// {response: object} for one well-formed response line, else {response: null}.
// A malformed or oversized line desynchronises the strict-order stream.
function parseResponse(line) {
    if (typeof line !== "string" || line.length + 1 > MAX_RESPONSE_BYTES
            || utf8Bytes(line) + 1 > MAX_RESPONSE_BYTES) return {response: null};
    var parsed;
    try { parsed = JSON.parse(line); } catch (_) { return {response: null}; }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
            || !isInt(parsed.id, 0, MAX_ID)) return {response: null};
    return {response: parsed};
}

function safeError(message) {
    if (typeof message !== "string" || message.length > 256) return ERR.unavailable;
    if (KNOWN_ERRORS.indexOf(message) >= 0 || PARSE_ERROR.test(message)) return message;
    return ERR.unavailable;
}

function isRetryable(text) { return RETRYABLE.indexOf(text) >= 0; }

function validProgress(response) {
    return response && response.event === "progress" && isInt(response.rows, 0, MAX_SAFE);
}

function nullableNumber(value) {
    return value === null || (typeof value === "number" && isFinite(value));
}

function nullableInt(value, maximum) {
    return value === null || isInt(value, 0, maximum);
}

function validStat(stat, rows) {
    if (!stat || typeof stat !== "object" || Array.isArray(stat)) return null;
    if (!validText(stat.name, MAX_CELL_CODEPOINTS)
            || !isInt(stat.nonEmpty, 0, MAX_SAFE) || !isInt(stat.empty, 0, MAX_SAFE)
            || stat.nonEmpty + stat.empty > rows
            || TYPES.indexOf(stat.inferredType) < 0
            || !stat.typeCounts || typeof stat.typeCounts !== "object" || Array.isArray(stat.typeCounts)
            || !nullableNumber(stat.sum) || !nullableNumber(stat.mean)
            || !(stat.min === null || nullableNumber(stat.min) || validText(stat.min, MAX_CELL_CODEPOINTS))
            || !(stat.max === null || nullableNumber(stat.max) || validText(stat.max, MAX_CELL_CODEPOINTS))
            || !nullableInt(stat.distinct, MAX_SAFE) || !(stat.distinctExact === null || typeof stat.distinctExact === "boolean")
            || !nullableInt(stat.minLength, MAX_SAFE) || !nullableInt(stat.maxLength, MAX_SAFE)
            || (stat.minLength !== null && stat.maxLength !== null && stat.minLength > stat.maxLength))
        return null;
    var counts = {};
    for (var k = 0; k < TYPE_COUNTS.length; ++k) {
        var count = stat.typeCounts[TYPE_COUNTS[k]];
        if (!isInt(count, 0, MAX_SAFE)) return null;
        counts[TYPE_COUNTS[k]] = count;
    }
    return {name: stat.name, nonEmpty: stat.nonEmpty, empty: stat.empty, typeCounts: counts,
        inferredType: stat.inferredType, min: stat.min, max: stat.max, sum: stat.sum, mean: stat.mean,
        distinct: stat.distinct, distinctExact: stat.distinctExact,
        minLength: stat.minLength, maxLength: stat.maxLength};
}

// Shared by the register and open responses; null when any field is out of range.
function validateMeta(response) {
    if (!response || response.ok !== true || !validSourceId(response.sourceId)
            || !isInt(response.rows, 0, MAX_SAFE) || !isInt(response.columnCount, 1, MAX_COLUMN_COUNT)
            || !isInt(response.bytes, 0, MAX_SAFE)
            || !Array.isArray(response.columns) || !Array.isArray(response.stats)
            || response.columns.length < 1 || response.columns.length > MAX_COLUMNS
            || response.columns.length !== Math.min(MAX_COLUMNS, response.columnCount)
            || response.stats.length !== response.columns.length) return null;
    var columns = [];
    var stats = [];
    for (var c = 0; c < response.columns.length; ++c) {
        if (!validText(response.columns[c], MAX_CELL_CODEPOINTS)) return null;
        columns.push(response.columns[c]);
        var stat = validStat(response.stats[c], response.rows);
        if (!stat) return null;
        stats.push(stat);
    }
    return {sourceId: response.sourceId, rows: response.rows, columnCount: response.columnCount,
        columnsTruncated: response.columnCount > MAX_COLUMNS, columns: columns, bytes: response.bytes,
        stats: stats};
}

function validateVerify(response) {
    if (!response || response.ok !== true || STATES.indexOf(response.state) < 0) return null;
    return {state: response.state};
}

function validateView(response) {
    if (!response || response.ok !== true || !isInt(response.gen, 0, MAX_ID)
            || !isInt(response.viewRows, 0, MAX_SAFE)) return null;
    return {gen: response.gen, viewRows: response.viewRows};
}

function pageCountFor(viewRows) {
    return isInt(viewRows, 0, MAX_SAFE) ? Math.ceil(viewRows / PAGE_SIZE) : 0;
}

function clampPage(page, pageCount) {
    if (!isInt(page, 0, MAX_SAFE) || pageCount < 1) return 0;
    return Math.min(page, pageCount - 1);
}

// `expect` is optional: {columnCount: displayed columns, viewRows: current view}.
function validatePage(response, expect) {
    if (!response || response.ok !== true || !isInt(response.gen, 0, MAX_ID)
            || !isInt(response.page, 0, MAX_SAFE) || response.pageSize !== PAGE_SIZE
            || !isInt(response.pageCount, 0, MAX_SAFE) || !isInt(response.viewRows, 0, MAX_SAFE)
            || !isInt(response.firstRow, 0, MAX_SAFE) || typeof response.cellsTruncated !== "boolean"
            || !Array.isArray(response.rows) || response.rows.length > PAGE_SIZE) return null;
    var count = pageCountFor(response.viewRows);
    // An empty view may report one blank page or none at all.
    if (response.pageCount !== count && !(response.viewRows === 0 && response.pageCount === 1)) return null;
    var remaining = Math.max(0, response.viewRows - response.page * PAGE_SIZE);
    if (response.rows.length !== Math.min(PAGE_SIZE, remaining)
            || (response.rows.length > 0 && response.firstRow < 1)) return null;
    if (response.rows.length === 0 && response.page > 0 && response.page >= count) return null;
    if (expect && expect.viewRows !== undefined && expect.viewRows !== response.viewRows) return null;
    var width = response.rows.length ? (Array.isArray(response.rows[0]) ? response.rows[0].length : -1) : 0;
    if (response.rows.length && (width < 1 || width > MAX_COLUMNS)) return null;
    if (expect && expect.columnCount !== undefined && response.rows.length && width !== expect.columnCount) return null;
    var rows = [];
    for (var r = 0; r < response.rows.length; ++r) {
        var row = response.rows[r];
        if (!Array.isArray(row) || row.length !== width) return null;
        for (var c = 0; c < row.length; ++c) if (!validText(row[c], MAX_CELL_CODEPOINTS)) return null;
        rows.push(row.slice());
    }
    return {gen: response.gen, page: response.page, pageSize: PAGE_SIZE, pageCount: response.pageCount,
        viewRows: response.viewRows, firstRow: response.firstRow, rows: rows,
        cellsTruncated: response.cellsTruncated};
}

// ---- display helpers -------------------------------------------------------

// Thousands grouping with a plain comma; counts only, never parsed back.
function groupDigits(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// Honest row-count text. While `counting`, `totalRows` is only what has been
// seen so far; when `filtered`, `viewRows` of the exact total match.
function rowCountLabel(totalRows, viewRows, counting, filtered) {
    var known = isInt(totalRows, 0, MAX_SAFE);
    if (counting) return known && totalRows > 0 ? "Counting… " + groupDigits(totalRows) + " rows so far" : "Counting…";
    if (!known) return "";
    var noun = totalRows === 1 ? " row" : " rows";
    if (filtered && isInt(viewRows, 0, MAX_SAFE))
        return groupDigits(viewRows) + " of " + groupDigits(totalRows) + noun;
    return groupDigits(totalRows) + noun;
}

// 1-based "Page 3 of 40"; empty views say so instead of "Page 1 of 0".
function pageLabel(page, pageCount) {
    if (!isInt(pageCount, 1, MAX_SAFE) || !isInt(page, 0, MAX_SAFE)) return "No rows";
    return "Page " + groupDigits(Math.min(page, pageCount - 1) + 1) + " of " + groupDigits(pageCount);
}

// Position of the visible slice inside the current view: "Rows 26–50 of 1,000".
function rangeLabel(page, rowsOnPage, viewRows) {
    if (!isInt(rowsOnPage, 1, PAGE_SIZE) || !isInt(page, 0, MAX_SAFE) || !isInt(viewRows, 1, MAX_SAFE)) return "No rows";
    var first = page * PAGE_SIZE + 1;
    return "Rows " + groupDigits(first) + "–" + groupDigits(first + rowsOnPage - 1) + " of " + groupDigits(viewRows);
}
