.pragma library

// Local, deterministic column-type inference for the bounded CSV preview.
//
// Scope and honesty: this looks ONLY at the preview rows the person can see
// (at most 10 rows x 20 columns of already-validated, already-clipped cells).
// It is not a whole-file or whole-dataset inference and never reads a file.
// It is locale-honest: a plain decimal point is the only decimal convention it
// accepts; thousands separators, spaces, apostrophes and currency symbols are
// never guessed, they make a column "unsure". Day/month order is read only from
// evidence in the sample (a part above 12); otherwise "unsure".
//
// Correctable types are the enum TYPES. "unsure" and "empty" are inference-only
// outcomes and can never be sent as a correction.

var TYPES = ["number", "date", "text"];
var MAX_COLUMNS = 20;
var MAX_ROWS = 10;
// Cells are validated to <= 160 UTF-16 units upstream; anything longer here is
// text by definition and must not reach a regular expression.
var MAX_CELL_UNITS = 160;
// Integers wider than this lose precision as doubles: treat as identifiers.
var MAX_SAFE_DIGITS = 15;

var LABELS = {number: "Number", date: "Date", text: "Text", unsure: "Unsure", empty: "Empty"};
var SHORT = {number: "123", date: "date", text: "abc", unsure: "?", empty: "—"};

var CUR = "[$€£¥₹₩₽¢₪₺฿₫₴₦]";
var PLAIN_NUMBER = /^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$/;
var PERCENT = /^[+-]?(?:\d+(?:\.\d+)?|\.\d+)%$/;
// Anything number-shaped that is not a plain number: grouping, spaces,
// apostrophes, comma decimals, currency symbols/codes, accounting brackets.
var AMBIGUOUS_NUMBER = new RegExp("^\\(?[+-]?(?:(?:" + CUR + "|[A-Z]{3})\\s?)?\\d[\\d.,  '’ ]*"
    + "(?:\\s?(?:" + CUR + "|[A-Z]{3}))?%?\\)?$");
var ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;
var PARTS_DATE = /^(\d{1,2})([\/.\-])(\d{1,2})\2(\d{2}|\d{4})$/;
var YEAR_FIRST_DATE = /^(\d{4})([\/.])(\d{1,2})\2(\d{1,2})$/;

function isType(value) {
    return typeof value === "string" && TYPES.indexOf(value) >= 0;
}

function leap(year) {
    return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

// year === null means an unknown (two-digit) year: allow the leap day.
function daysIn(month, year) {
    if (month === 2) return year === null || leap(year) ? 29 : 28;
    return [4, 6, 9, 11].indexOf(month) >= 0 ? 30 : 31;
}

function validDay(day, month, year) {
    return month >= 1 && month <= 12 && day >= 1 && day <= daysIn(month, year);
}

function classifyDate(s) {
    var m = ISO_DATE.exec(s)
    if (m) {
        var y = Number(m[1]), mo = Number(m[2]), d = Number(m[3])
        if (y < 1 || !validDay(d, mo, y)) return "text"
        if (m[4] !== undefined && (Number(m[4]) > 23 || Number(m[5]) > 59
                || (m[6] !== undefined && Number(m[6]) > 59))) return "text"
        return "iso"
    }
    m = YEAR_FIRST_DATE.exec(s)
    if (m) return validDay(Number(m[4]), Number(m[3]), Number(m[1])) ? "iso" : "text"
    m = PARTS_DATE.exec(s)
    if (!m) return ""
    var a = Number(m[1]), b = Number(m[3])
    var year = m[4].length === 4 ? Number(m[4]) : null
    if (a === 0 || b === 0 || a > 31 || b > 31) return "text"
    if (a === b && a <= 12) return "either"
    if (a > 12 && b <= 12) return validDay(a, b, year) ? "dmy" : "text"
    if (b > 12 && a <= 12) return validDay(b, a, year) ? "mdy" : "text"
    if (a <= 12 && b <= 12) return "amb"
    return "text"
}

// One cell -> a kind used only by inferColumn. Whitespace is ignored for
// classification; the cell itself is never altered or sent anywhere.
function classifyCell(cell) {
    if (typeof cell !== "string") return "text"
    if (cell.length > MAX_CELL_UNITS) return "text"
    var s = cell.trim()
    if (s.length === 0) return "empty"
    if (PLAIN_NUMBER.test(s)) {
        var digits = s.replace(/^[+-]/, "")
        var integer = /^\d+$/.test(digits)
        // Leading zeros (postcodes, ids) and over-wide integers are codes.
        if (/^0\d/.test(digits)) return "code"
        if (integer && digits.length > MAX_SAFE_DIGITS) return "code"
        return isFinite(Number(s)) ? "number" : "text"
    }
    if (PERCENT.test(s)) return "percent"
    var date = classifyDate(s)
    if (date) return date
    if (AMBIGUOUS_NUMBER.test(s)) return "ambNumber"
    return "text"
}

function result(type, guess, reason, nonEmpty, empty) {
    return {type: type, guess: guess, reason: reason, nonEmpty: nonEmpty, empty: empty}
}

// Infer one column from its sampled cells (an array of strings).
function inferCells(cells) {
    var list = Array.isArray(cells) ? cells.slice(0, MAX_ROWS) : []
    var counts = {empty: 0, number: 0, percent: 0, code: 0, ambNumber: 0, iso: 0,
        dmy: 0, mdy: 0, amb: 0, either: 0, text: 0}
    for (var i = 0; i < list.length; ++i) counts[classifyCell(list[i])] += 1
    var nonEmpty = list.length - counts.empty
    var empty = counts.empty
    if (nonEmpty === 0) return result("empty", "", "No values in the rows shown.", 0, empty)
    var dates = counts.iso + counts.dmy + counts.mdy + counts.amb + counts.either
    var numeric = counts.number + counts.percent + counts.ambNumber
    if (counts.text > 0) {
        return result("text", "", dates + numeric + counts.code > 0
            ? "Mixed values in the rows shown." : "Words or other text.", nonEmpty, empty)
    }
    if (counts.code > 0) {
        return result("text", "", "Leading zeros or very long digit strings are kept as text (codes, postcodes, ids).",
            nonEmpty, empty)
    }
    if (numeric > 0 && dates > 0) return result("text", "", "Mixed numbers and dates.", nonEmpty, empty)
    if (numeric > 0) {
        if (counts.ambNumber > 0) {
            return result("unsure", "number", "Separators, spaces or currency make the number format unclear; "
                + "the preview does not guess a decimal or thousands convention.", nonEmpty, empty)
        }
        if (counts.percent > 0 && counts.number > 0) {
            return result("unsure", "number", "Percent signs appear on only some values.", nonEmpty, empty)
        }
        return result("number", "", counts.percent > 0 ? "Percentages, kept as written." : "Plain numbers.",
            nonEmpty, empty)
    }
    if (counts.dmy > 0 && counts.mdy > 0) {
        return result("unsure", "date", "Day/month order differs between rows.", nonEmpty, empty)
    }
    if (counts.dmy > 0) return result("date", "", "Dates, day first (a day above 12 was seen).", nonEmpty, empty)
    if (counts.mdy > 0) return result("date", "", "Dates, month first (a day above 12 was seen).", nonEmpty, empty)
    if (counts.amb > 0) {
        return result("unsure", "date", "Day/month order is unclear (for example 01/02/03).", nonEmpty, empty)
    }
    return result("date", "", "Dates.", nonEmpty, empty)
}

// Infer every displayed column. Bounded: at most 20 columns and 10 rows are
// ever examined, whatever the caller passes.
function inferColumns(columns, rows) {
    var count = Array.isArray(columns) ? Math.min(MAX_COLUMNS, columns.length) : 0
    var shown = Array.isArray(rows) ? rows.slice(0, MAX_ROWS) : []
    var out = []
    for (var c = 0; c < count; ++c) {
        var cells = []
        for (var r = 0; r < shown.length; ++r) {
            var row = shown[r]
            cells.push(Array.isArray(row) && row[c] !== undefined ? String(row[c]) : "")
        }
        out.push(inferCells(cells))
    }
    return out
}

// A fixed-length list of "" or an enum value; anything else becomes "".
function normalizeOverrides(list, count) {
    var n = Math.max(0, Math.min(MAX_COLUMNS, Math.floor(Number(count) || 0)))
    var out = []
    for (var i = 0; i < n; ++i) out.push(Array.isArray(list) && isType(list[i]) ? list[i] : "")
    return out
}

function effectiveType(inference, override) {
    return isType(override) ? override : (inference ? inference.type : "text")
}

// Replace one column's correction without mutating the input. An unknown
// column or type leaves the list unchanged; "" clears the correction.
function setOverride(list, count, column, type) {
    var next = normalizeOverrides(list, count)
    if (typeof column !== "number" || Math.floor(column) !== column || column < 0 || column >= next.length) return next
    if (type === "" || isType(type)) next[column] = type
    return next
}

function correctedCount(list) {
    var total = 0
    for (var i = 0; Array.isArray(list) && i < Math.min(list.length, MAX_COLUMNS); ++i)
        if (isType(list[i])) total += 1
    return total
}

// The request payload: null when nothing is corrected, else one entry per
// displayed column that is either an enum value or null.
function requestTypes(list, count) {
    var normalized = normalizeOverrides(list, count)
    var any = false
    var out = normalized.map(function(type) {
        if (type === "") return null
        any = true
        return type
    })
    return any ? out : null
}

function label(type) { return LABELS[type] || LABELS.text }
function shortLabel(type) { return SHORT[type] || SHORT.text }

// Accessible/tooltip sentence for one header. Static strings plus a count; the
// column name is passed through by the caller, never interpolated here.
function describe(inference, override) {
    var inferred = inference ? inference.type : "text"
    var basis = inference && inference.nonEmpty > 0
        ? "from " + inference.nonEmpty + " non-empty value" + (inference.nonEmpty === 1 ? "" : "s")
            + " in the rows shown" + (inference.empty > 0 ? " (" + inference.empty + " empty)" : "")
        : "from the rows shown"
    if (isType(override)) {
        return label(override) + ", corrected by you. Inferred " + basis + ": "
            + label(inferred).toLowerCase() + "."
    }
    return label(inferred) + ", inferred " + basis + ". " + (inference ? inference.reason : "")
}
