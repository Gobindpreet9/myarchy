import QtQuick
import QtTest
import "../CsvPage.js" as CsvPage

// Pure-function tests for the CSV source protocol validators and label
// helpers. No file, process or worker is involved.
TestCase {
    name: "CsvPage"

    function stat(name, extra) {
        var s = {name: name, nonEmpty: 4, empty: 1, typeCounts: {number: 4, date: 0, text: 0, unsure: 0},
            inferredType: "number", min: 1, max: 9, sum: 20, mean: 5, distinct: 4, distinctExact: true,
            minLength: 1, maxLength: 1}
        for (var key in extra) s[key] = extra[key]
        return s
    }
    function meta(extra) {
        var m = {id: 1, ok: true, sourceId: "src-0123456789abcdef", rows: 5, columnCount: 2,
            columns: ["a", "b"], bytes: 40, stats: [stat("a"), stat("b")]}
        for (var key in extra) m[key] = extra[key]
        return m
    }
    function pageResp(extra) {
        var p = {id: 2, ok: true, gen: 3, page: 0, pageSize: 25, pageCount: 1, viewRows: 2, firstRow: 1,
            rows: [["1", "x"], ["2", "y"]], cellsTruncated: false}
        for (var key in extra) p[key] = extra[key]
        return p
    }
    function emptyRows(count, width) {
        var rows = []
        for (var r = 0; r < count; ++r) {
            var row = []
            for (var c = 0; c < width; ++c) row.push("v")
            rows.push(row)
        }
        return rows
    }

    function test_codepoints_data() {
        return [
            {tag: "ascii", text: "abc", count: 3},
            {tag: "empty", text: "", count: 0},
            {tag: "astral pair counts once", text: "a💡b", count: 3},
            {tag: "lone high", text: "x\ud800", count: -1},
            {tag: "lone low", text: "\udc00", count: -1},
            {tag: "reversed pair", text: "\udc00\ud800", count: -1},
            {tag: "high then ascii", text: "\ud800a", count: -1}
        ]
    }
    function test_codepoints(data) { compare(CsvPage.codepoints(data.text), data.count) }

    function test_validText_boundaries() {
        verify(CsvPage.validText("x".repeat(80), 80))
        verify(!CsvPage.validText("x".repeat(81), 80))
        verify(CsvPage.validText("💡".repeat(80), 80), "80 emoji codepoints fit in 160 units")
        verify(!CsvPage.validText("💡".repeat(81), 80))
        verify(!CsvPage.validText(42, 80))
        verify(!CsvPage.validText(null, 80))
        verify(!CsvPage.validText("a\ud800", 80))
    }

    function test_sourceId_data() {
        return [
            {tag: "good", id: "src-0123456789abcdef", ok: true},
            {tag: "uppercase", id: "src-0123456789ABCDEF", ok: false},
            {tag: "short", id: "src-0123456789abcde", ok: false},
            {tag: "long", id: "src-0123456789abcdef0", ok: false},
            {tag: "wrong prefix", id: "doc-0123456789abcdef", ok: false},
            {tag: "traversal", id: "src-../../etc/passwd", ok: false},
            {tag: "trailing newline", id: "src-0123456789abcdef\n", ok: false},
            {tag: "number", id: 5, ok: false},
            {tag: "null", id: null, ok: false}
        ]
    }
    function test_sourceId(data) { compare(CsvPage.validSourceId(data.id), data.ok) }

    function test_parseResponse() {
        verify(CsvPage.parseResponse("{\"id\":4,\"ok\":true}").response !== null)
        compare(CsvPage.parseResponse("{not json").response, null)
        compare(CsvPage.parseResponse("[1,2]").response, null)
        compare(CsvPage.parseResponse("42").response, null)
        compare(CsvPage.parseResponse("{\"ok\":true}").response, null, "id is required")
        compare(CsvPage.parseResponse("{\"id\":\"4\",\"ok\":true}").response, null, "id must be an integer")
        compare(CsvPage.parseResponse("{\"id\":1.5,\"ok\":true}").response, null)
        compare(CsvPage.parseResponse("{\"id\":-1,\"ok\":true}").response, null)
        compare(CsvPage.parseResponse(undefined).response, null)
        var limit = "{\"id\":1,\"x\":\"" + "y".repeat(CsvPage.MAX_RESPONSE_BYTES - 20) + "\"}"
        verify(CsvPage.parseResponse(limit).response !== null, "just under 256 KiB parses")
        compare(CsvPage.parseResponse(limit + "yyyyyyyyyyyyyyyyyyyyyy").response, null, "over 256 KiB is refused")
        // Multi-byte text counts in UTF-8 bytes, not UTF-16 units.
        var wide = "{\"id\":1,\"x\":\"" + "€".repeat(90000) + "\"}"
        compare(CsvPage.parseResponse(wide).response, null, "270,000 UTF-8 bytes in 90,000 units is refused")
    }

    function test_requestLine() {
        compare(CsvPage.requestLine(7, "page", {sourceId: "src-0123456789abcdef", page: 2, gen: 4}),
            "{\"id\":7,\"op\":\"page\",\"sourceId\":\"src-0123456789abcdef\",\"page\":2,\"gen\":4}\n")
        compare(CsvPage.requestLine(1, "register", {path: "/scratch/a/" + "x".repeat(8300)}), null, "over 8 KiB is refused")
        verify(CsvPage.requestLine(1, "register", {path: "/scratch/a/" + "x".repeat(4000)}) !== null)
    }

    function test_validPath() {
        verify(CsvPage.validPath("/scratch/a/b.csv"))
        verify(!CsvPage.validPath(""))
        verify(!CsvPage.validPath(5))
        verify(!CsvPage.validPath("a\0b"))
        verify(CsvPage.validPath("/" + "x".repeat(4095)))
        verify(!CsvPage.validPath("/" + "x".repeat(4096)))
    }

    function test_cleanFilter() {
        compare(CsvPage.cleanFilter("rome"), "rome")
        compare(CsvPage.cleanFilter(5), "")
        compare(CsvPage.cleanFilter("a\ud800b"), "ab", "lone surrogates are dropped")
        compare(CsvPage.cleanFilter("a\udc00b"), "ab")
        compare(CsvPage.cleanFilter("x".repeat(300)).length, 200)
        compare(CsvPage.cleanFilter("💡".repeat(300)).length, 400, "200 whole astral codepoints, never half a pair")
        compare(CsvPage.cleanFilter("x".repeat(199) + "💡"), "x".repeat(199) + "💡")
    }

    function test_safeError() {
        compare(CsvPage.safeError("Superseded."), "Superseded.")
        compare(CsvPage.safeError("Invalid source id."), "Invalid source id.")
        compare(CsvPage.safeError("Stale view."), "Stale view.")
        compare(CsvPage.safeError("Unknown source."), "CSV source is unavailable.", "only the worker's own strings pass")
        compare(CsvPage.safeError("Attachment is unavailable or is a symbolic link."), "Attachment is unavailable or is a symbolic link.")
        compare(CsvPage.safeError("CSV line 2 has 3 columns; the header has 2."), "CSV line 2 has 3 columns; the header has 2.")
        compare(CsvPage.safeError("CSV could not be parsed near line 9 (invalid quotes or oversized field)."),
            "CSV could not be parsed near line 9 (invalid quotes or oversized field).")
        var generic = "CSV source is unavailable."
        compare(CsvPage.safeError("Traceback (most recent call last): /scratch/private/secret.csv"), generic)
        compare(CsvPage.safeError("CSV line 2 has 3 columns; the header has 2. /scratch/private"), generic, "anchored match only")
        compare(CsvPage.safeError("CSV line x has 3 columns; the header has 2."), generic)
        compare(CsvPage.safeError("x".repeat(300)), generic)
        compare(CsvPage.safeError(undefined), generic)
        compare(CsvPage.safeError({toString: function() { return "Superseded." }}), generic, "only real strings pass")
    }

    function test_retryable() {
        verify(CsvPage.isRetryable(CsvPage.ERR.timeout))
        verify(CsvPage.isRetryable(CsvPage.ERR.stopped))
        verify(CsvPage.isRetryable(CsvPage.ERR.invalid))
        verify(CsvPage.isRetryable("Stale view."))
        verify(!CsvPage.isRetryable(CsvPage.ERR.path))
        verify(!CsvPage.isRetryable("Attachment is binary."))
    }

    function test_progress() {
        verify(CsvPage.validProgress({id: 1, event: "progress", rows: 0}))
        verify(CsvPage.validProgress({id: 1, event: "progress", rows: 100000}))
        verify(!CsvPage.validProgress({id: 1, event: "progress", rows: -1}))
        verify(!CsvPage.validProgress({id: 1, event: "progress", rows: "5"}))
        verify(!CsvPage.validProgress({id: 1, event: "progress"}))
        verify(!CsvPage.validProgress({id: 1, event: "other", rows: 5}))
        verify(!CsvPage.validProgress(null))
    }

    function test_validateMeta_accepts() {
        var m = CsvPage.validateMeta(meta())
        verify(m !== null)
        compare(m.sourceId, "src-0123456789abcdef")
        compare(m.rows, 5)
        compare(m.columns, ["a", "b"])
        compare(m.columnsTruncated, false)
        compare(m.stats.length, 2)
        compare(m.stats[0].typeCounts, {number: 4, date: 0, text: 0, unsure: 0})
        // Unknown worker fields never survive.
        var extra = CsvPage.validateMeta(meta({extraPath: "/scratch/x", stats: [stat("a", {leak: 1}), stat("b")]}))
        verify(extra !== null)
        compare(extra.secret, undefined)
        compare(extra.stats[0].leak, undefined)
    }

    function test_validateMeta_wide_source() {
        var columns = []
        var stats = []
        for (var c = 0; c < 20; ++c) { columns.push("c" + c); stats.push(stat("c" + c)) }
        var m = CsvPage.validateMeta(meta({columnCount: 25, columns: columns, stats: stats}))
        verify(m !== null)
        compare(m.columnsTruncated, true)
        compare(CsvPage.validateMeta(meta({columnCount: 20, columns: columns, stats: stats})).columnsTruncated, false)
        compare(CsvPage.validateMeta(meta({columnCount: 19, columns: columns, stats: stats})), null, "columns exceed the count")
        compare(CsvPage.validateMeta(meta({columnCount: 25, columns: columns.slice(0, 19), stats: stats.slice(0, 19)})), null,
            "a wide source must show exactly 20 columns")
        columns.push("c20"); stats.push(stat("c20"))
        compare(CsvPage.validateMeta(meta({columnCount: 30, columns: columns, stats: stats})), null, "21 displayed columns")
    }

    // The worker accepts columnCount up to 2 ** 31; a tighter client bound once
    // rejected the reply of a copy that was already registered (orphaned).
    function test_validateMeta_columnCount_matches_worker_bound() {
        var columns = []
        var stats = []
        for (var c = 0; c < 20; ++c) { columns.push("c" + c); stats.push(stat("c" + c)) }
        var wide = CsvPage.validateMeta(meta({columnCount: 150000, columns: columns, stats: stats}))
        verify(wide !== null, "a 150,000-column source the worker registered must be accepted")
        compare(wide.columnCount, 150000)
        compare(wide.columnsTruncated, true)
        verify(CsvPage.validateMeta(meta({columnCount: 2147483648, columns: columns, stats: stats})) !== null)
        compare(CsvPage.validateMeta(meta({columnCount: 2147483649, columns: columns, stats: stats})), null)
    }

    function test_validateMeta_rejects_data() {
        return [
            {tag: "not ok", patch: {ok: false}},
            {tag: "bad source id", patch: {sourceId: "src-xyz"}},
            {tag: "negative rows", patch: {rows: -1}},
            {tag: "fractional rows", patch: {rows: 1.5}},
            {tag: "string rows", patch: {rows: "5"}},
            {tag: "zero columnCount", patch: {columnCount: 0}},
            {tag: "negative bytes", patch: {bytes: -5}},
            {tag: "columns not array", patch: {columns: "ab"}},
            {tag: "no columns", patch: {columnCount: 1, columns: [], stats: []}},
            {tag: "column not string", patch: {columns: ["a", 5]}},
            {tag: "lone surrogate column", patch: {columns: ["a", "b\ud800"]}},
            {tag: "oversized column", patch: {columns: ["a", "b".repeat(81)]}},
            {tag: "stats too short", patch: {stats: [{name: "a"}]}},
            {tag: "stats missing", patch: {stats: undefined}},
            {tag: "stats row missing fields", patch: {stats: [stat("a"), {name: "b"}]}},
            {tag: "stats not an object", patch: {stats: [stat("a"), 5]}}
        ]
    }
    function test_validateMeta_rejects(data) { compare(CsvPage.validateMeta(meta(data.patch)), null) }

    function test_stat_validation_data() {
        return [
            {tag: "nullable numbers", patch: {min: null, max: null, sum: null, mean: null, distinct: null, minLength: null, maxLength: null}, ok: true},
            {tag: "text min/max", patch: {inferredType: "text", min: "apple", max: "pear", sum: null, mean: null}, ok: true},
            {tag: "empty type", patch: {inferredType: "empty", nonEmpty: 0, empty: 5, min: null, max: null}, ok: true},
            {tag: "unknown inferred type", patch: {inferredType: "boolean"}, ok: false},
            {tag: "nonEmpty+empty over rows", patch: {nonEmpty: 5, empty: 1}, ok: false},
            {tag: "negative count", patch: {empty: -1}, ok: false},
            {tag: "NaN sum", patch: {sum: NaN}, ok: false},
            {tag: "infinite mean", patch: {mean: Infinity}, ok: false},
            {tag: "string sum", patch: {sum: "20"}, ok: false},
            {tag: "lone surrogate min", patch: {min: "a\ud800"}, ok: false},
            {tag: "oversized max", patch: {max: "m".repeat(81)}, ok: false},
            {tag: "object max", patch: {max: {v: 1}}, ok: false},
            {tag: "distinctExact not boolean", patch: {distinctExact: 1}, ok: false},
            {tag: "fractional distinct", patch: {distinct: 1.5}, ok: false},
            {tag: "minLength above maxLength", patch: {minLength: 5, maxLength: 2}, ok: false},
            {tag: "typeCounts missing key", patch: {typeCounts: {number: 4, date: 0, text: 0}}, ok: false},
            {tag: "typeCounts negative", patch: {typeCounts: {number: -1, date: 0, text: 0, unsure: 0}}, ok: false},
            {tag: "typeCounts array", patch: {typeCounts: [4, 0, 0, 0]}, ok: false},
            {tag: "oversized name", patch: {name: "n".repeat(81)}, ok: false}
        ]
    }
    function test_stat_validation(data) {
        var m = CsvPage.validateMeta(meta({stats: [stat("a", data.patch), stat("b")]}))
        compare(m !== null, data.ok)
    }

    function test_validateVerify() {
        compare(CsvPage.validateVerify({id: 1, ok: true, state: "ready"}), {state: "ready"})
        compare(CsvPage.validateVerify({id: 1, ok: true, state: "originChanged"}), {state: "originChanged"})
        compare(CsvPage.validateVerify({id: 1, ok: true, state: "originMissing"}), {state: "originMissing"})
        compare(CsvPage.validateVerify({id: 1, ok: true, state: "copyMissing"}), {state: "copyMissing"})
        compare(CsvPage.validateVerify({id: 1, ok: true, state: "gone"}), null)
        compare(CsvPage.validateVerify({id: 1, ok: true}), null)
        compare(CsvPage.validateVerify({id: 1, ok: false, state: "ready"}), null)
    }

    function test_validateView() {
        compare(CsvPage.validateView({id: 1, ok: true, gen: 3, viewRows: 9}), {gen: 3, viewRows: 9})
        compare(CsvPage.validateView({id: 1, ok: true, gen: 0, viewRows: 0}), {gen: 0, viewRows: 0})
        compare(CsvPage.validateView({id: 1, ok: true, gen: -1, viewRows: 9}), null)
        compare(CsvPage.validateView({id: 1, ok: true, gen: 1.5, viewRows: 9}), null)
        compare(CsvPage.validateView({id: 1, ok: true, gen: 1, viewRows: -2}), null)
        compare(CsvPage.validateView({id: 1, ok: true, gen: "1", viewRows: 2}), null)
        compare(CsvPage.validateView({id: 1, ok: true, gen: 1}), null)
        compare(CsvPage.validateView({id: 1, ok: false, gen: 1, viewRows: 2}), null)
    }

    function test_validatePage_accepts() {
        var p = CsvPage.validatePage(pageResp(), {columnCount: 2, viewRows: 2})
        verify(p !== null)
        compare(p.rows, [["1", "x"], ["2", "y"]])
        compare(p.firstRow, 1)
        compare(p.pageSize, 25)
        compare(p.cellsTruncated, false)
        verify(CsvPage.validatePage(pageResp()) !== null, "expectations are optional")
        var full = CsvPage.validatePage(pageResp({rows: emptyRows(25, 20), viewRows: 60, pageCount: 3}), {columnCount: 20, viewRows: 60})
        verify(full !== null, "25 x 20 is the maximum page")
        var last = CsvPage.validatePage(pageResp({rows: emptyRows(10, 3), page: 2, viewRows: 60, pageCount: 3, firstRow: 51}))
        verify(last !== null, "a short last page")
        verify(CsvPage.validatePage(pageResp({rows: [], viewRows: 0, pageCount: 0, firstRow: 0})) !== null, "empty view")
        verify(CsvPage.validatePage(pageResp({rows: [], viewRows: 0, pageCount: 1, firstRow: 0})) !== null, "empty view with one blank page")
        verify(CsvPage.validatePage(pageResp({rows: [["💡".repeat(80), ""], ["a", "b"]]})) !== null, "80 emoji cell and empty cell")
        // The returned rows are a copy, never the worker's arrays.
        var source = pageResp()
        var copy = CsvPage.validatePage(source)
        source.rows[0][0] = "changed"
        compare(copy.rows[0][0], "1")
    }

    function test_validatePage_rejects_data() {
        return [
            {tag: "not ok", patch: {ok: false}},
            {tag: "missing gen", patch: {gen: undefined}},
            {tag: "negative gen", patch: {gen: -1}},
            {tag: "fractional page", patch: {page: 0.5}},
            {tag: "negative page", patch: {page: -1}},
            {tag: "wrong pageSize", patch: {pageSize: 50}},
            {tag: "pageCount mismatch", patch: {pageCount: 4}},
            {tag: "viewRows string", patch: {viewRows: "2"}},
            {tag: "firstRow zero with rows", patch: {firstRow: 0}},
            {tag: "cellsTruncated not boolean", patch: {cellsTruncated: 0}},
            {tag: "rows not array", patch: {rows: "ab"}},
            {tag: "26 rows", patch: {rows: emptyRows(26, 2), viewRows: 26, pageCount: 2}},
            {tag: "row count short of the view", patch: {rows: [["1", "x"]]}},
            {tag: "row count over the view", patch: {rows: [["1", "x"], ["2", "y"], ["3", "z"]]}},
            {tag: "row not array", patch: {rows: [["1", "x"], "2y"]}},
            {tag: "ragged row (short)", patch: {rows: [["1", "x"], ["2"]]}},
            {tag: "ragged row (long)", patch: {rows: [["1", "x"], ["2", "y", "z"]]}},
            {tag: "21 columns", patch: {rows: emptyRows(2, 21)}},
            {tag: "zero columns", patch: {rows: [[], []]}},
            {tag: "non-string cell", patch: {rows: [["1", 2], ["2", "y"]]}},
            {tag: "null cell", patch: {rows: [["1", null], ["2", "y"]]}},
            {tag: "lone high surrogate", patch: {rows: [["1", "x\ud800"], ["2", "y"]]}},
            {tag: "lone low surrogate", patch: {rows: [["1", "\udc00x"], ["2", "y"]]}},
            {tag: "81 codepoint cell", patch: {rows: [["1", "x".repeat(81)], ["2", "y"]]}},
            {tag: "81 emoji cell", patch: {rows: [["1", "💡".repeat(81)], ["2", "y"]]}},
            {tag: "page beyond the view", patch: {rows: [], page: 3, pageCount: 1, firstRow: 0}},
            {tag: "empty page with data in the view", patch: {rows: [], firstRow: 0}}
        ]
    }
    function test_validatePage_rejects(data) { compare(CsvPage.validatePage(pageResp(data.patch)), null) }

    function test_validatePage_expectations() {
        compare(CsvPage.validatePage(pageResp(), {columnCount: 3}), null, "width must match the displayed columns")
        compare(CsvPage.validatePage(pageResp(), {viewRows: 9}), null, "viewRows must match the current view")
        verify(CsvPage.validatePage(pageResp(), {columnCount: 2, viewRows: 2}) !== null)
    }

    function test_pageMath() {
        compare(CsvPage.pageCountFor(0), 0)
        compare(CsvPage.pageCountFor(1), 1)
        compare(CsvPage.pageCountFor(25), 1)
        compare(CsvPage.pageCountFor(26), 2)
        compare(CsvPage.pageCountFor(100000), 4000)
        compare(CsvPage.pageCountFor(-1), 0)
        compare(CsvPage.pageCountFor(null), 0)
        compare(CsvPage.clampPage(5, 3), 2)
        compare(CsvPage.clampPage(1, 3), 1)
        compare(CsvPage.clampPage(0, 0), 0)
        compare(CsvPage.clampPage(-4, 3), 0)
        compare(CsvPage.clampPage(1.5, 3), 0)
    }

    function test_rowCountLabel_data() {
        return [
            {tag: "exact", args: [8, 8, false, false], text: "8 rows"},
            {tag: "exact singular", args: [1, 1, false, false], text: "1 row"},
            {tag: "exact zero", args: [0, 0, false, false], text: "0 rows"},
            {tag: "exact grouped", args: [100000, 100000, false, false], text: "100,000 rows"},
            {tag: "counting nothing yet", args: [0, -1, true, false], text: "Counting…"},
            {tag: "counting so far", args: [12345, -1, true, false], text: "Counting… 12,345 rows so far"},
            {tag: "counting never claims exact", args: [8, 8, true, true], text: "Counting… 8 rows so far"},
            {tag: "filtered", args: [8, 3, false, true], text: "3 of 8 rows"},
            {tag: "filtered none", args: [8, 0, false, true], text: "0 of 8 rows"},
            {tag: "filtered grouped", args: [100000, 1234, false, true], text: "1,234 of 100,000 rows"},
            {tag: "filtered of one", args: [1, 0, false, true], text: "0 of 1 row"},
            {tag: "filter flag without view rows", args: [8, -1, false, true], text: "8 rows"},
            {tag: "unknown total", args: [null, null, false, false], text: ""}
        ]
    }
    function test_rowCountLabel(data) {
        compare(CsvPage.rowCountLabel(data.args[0], data.args[1], data.args[2], data.args[3]), data.text)
    }

    function test_pageLabels() {
        compare(CsvPage.pageLabel(0, 3), "Page 1 of 3")
        compare(CsvPage.pageLabel(2, 3), "Page 3 of 3")
        compare(CsvPage.pageLabel(9, 3), "Page 3 of 3", "an out-of-range page reads as the last one")
        compare(CsvPage.pageLabel(0, 4000), "Page 1 of 4,000")
        compare(CsvPage.pageLabel(0, 0), "No rows")
        compare(CsvPage.pageLabel(-1, 3), "No rows")
        compare(CsvPage.rangeLabel(0, 25, 1000), "Rows 1–25 of 1,000")
        compare(CsvPage.rangeLabel(1, 25, 1000), "Rows 26–50 of 1,000")
        compare(CsvPage.rangeLabel(2, 10, 60), "Rows 51–60 of 60")
        compare(CsvPage.rangeLabel(0, 0, 0), "No rows")
        compare(CsvPage.rangeLabel(0, 26, 100), "No rows")
    }
}
