import QtQuick
import QtTest
import "../AiState.js" as AiState

TestCase {
    name: "AiState"
    function test_sourcesUseExplicitSafeBrowserArguments() {
        var url = "https://example.com/article?q=hello%20world&x=1"
        compare(AiState.sourceCommand(url), ["omarchy-launch-browser", url]);
        compare(AiState.sourceCommand("https://xn--r8jz45g.jp/資料").length, 2)
        compare(AiState.sourceCommand("https://example.com:8443/path").length, 2);
        ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@" + "example.com", "https://localhost/x",
         "https://127.0.0.1/", "https://192.168.1.1/", "https://thing.local/", "https://host.test/",
         "https://example.com\\@localhost/", "https://example.com/\n--private", "--private"].forEach(function(value) {
            compare(AiState.sourceCommand(value).length, 0)
        })
    }
    function test_stoppingVisualLoadingRetainsCompletedContent() {
        var original = AiState.newTurn("Visual request", "")
        var presented = AiState.updateTurn(original, {type: "presentation", answer: "Full answer ".repeat(1000),
            blocks: [{type: "market", title: "Chart", symbol: "FIX", range: "1mo", loading: true, error: "Loading visual…"},
                     {type: "sources", title: "Sources", items: [{label: "Example", url: "https://example.com/"}]}],
            suggestions: [], warning: ""})
        compare(presented.status, "working")
        verify(presented.answer.length > 8192)
        var stopped = AiState.updateTurn(presented, {type: "stopped"})
        compare(stopped.answer, presented.answer)
        compare(stopped.blocks.length, 2)
        compare(stopped.blocks[0].error, "Visual loading stopped.")
        compare(stopped.blocks[0].loading, false)
        compare(presented.blocks[0].loading, true)
    }
    function test_visualFallbackRetainsDataAndSources() {
        var text = AiState.textAnswer({answer: "Summary", blocks: [
            {type: "sources", title: "Sources", items: [{label: "Example", url: "https://example.com"}]},
            {type: "market", title: "Illustrative fixture", symbol: "FIX", range: "1mo", unit: "USD",
             points: [{label: "2026-01-01", value: 12}], asOf: "2026-01-01", sourceUrl: "https://example.com/data"},
            {type: "image", title: "Image", query: "Fixture", attribution: "Example author", error: "Image unavailable"},
            {type: "chart", title: "Provided data", labels: ["A", "B"], values: [1, 2], unit: "count", source: ""}
        ]})
        verify(text.indexOf("Example · https://example.com") >= 0)
        verify(text.indexOf("2026-01-01 · 12") >= 0)
        verify(text.indexOf("Image unavailable") >= 0)
        verify(text.indexOf("B · 2") >= 0)
    }
    function test_trailSummaryRecordsExploration() {
        // The exploration trail is derived only from persisted state.
        compare(AiState.trailSummary({blocks: []}, {}), "", "no interactions, no trail")
        compare(AiState.trailSummary({blocks: []}, {"check:0": {selected: [1], checked: true}}), "Checked")
        compare(AiState.trailSummary({blocks: []}, {"check:0": {selected: [1], checked: false}}), "Checked",
            "an attempted selection counts as exploration; clearing it removes the entry")
        compare(AiState.trailSummary({blocks: []}, {"check:0": {selected: [], checked: false}}), "",
            "a cleared selection is not part of the trail")
        compare(AiState.trailSummary({blocks: []}, {"predict:1": 0}), "Predicted",
            "a committed prediction index counts")
        compare(AiState.trailSummary({blocks: []}, {"step:0": 0}), "",
            "being on the first stage is not 'stepped through'")
        compare(AiState.trailSummary({blocks: []}, {"step:0": 3}), "Stepped through")
        compare(AiState.trailSummary({blocks: []}, {"slider:0": 7, "diagram:0": {selectedIndex: 2}}),
            "Scrubbed", "scrubbing and selecting collapse into one honest entry")
        compare(AiState.trailSummary({blocks: []}, {"table:0": {sort: 1, dir: 1, filter: ""}}), "Sorted")
        compare(AiState.trailSummary({blocks: []}, {"table:0": {sort: -1, dir: 1, filter: "a"}}), "Filtered")
        compare(AiState.trailSummary({blocks: []}, {"table:0": {sort: 2, dir: -1, filter: "a"}}),
            "Sorted · Filtered")
        compare(AiState.trailSummary({blocks: []}, {"gallery:0:1": 1}), "1 example replaced")
        compare(AiState.trailSummary({blocks: []}, {"gallery:0:1": 1, "gallery:0:3": 1}),
            "2 examples replaced")
        compare(AiState.trailSummary({explanation: "Simpler text"}, {"step:0": 2}),
            "Stepped through · Depth added")
        compare(AiState.trailSummary({blocks: []}, {"unknown:0": {}}), "",
            "unknown state keys never invent a trail entry")
    }

    function test_learningBlocksHaveReadableTextFallbacks() {
        var text = AiState.textAnswer({answer: "Seasons", blocks: [
            {type: "steps", title: "Season cycle", steps: [
                {label: "Orbit the Sun", detail: "One orbit takes a year."},
                {label: "Keep the tilt", detail: ""}]},
            {type: "check", title: "Quick check", question: "Why is June warm in the north?",
             options: [
                 {label: "The north leans sunward", correct: true, feedback: "The tilt, not distance."},
                 {label: "Earth is closest", correct: false, feedback: "Distance is not the cause."}],
             explanation: "Axial tilt decides the angle."},
            {type: "predict", title: "Predict", prompt: "Warmer in January?",
             choices: ["Northern", "Southern"], reveal: "The Southern Hemisphere.",
             explanation: "January is southern summer."},
            {type: "slider", title: "Noon angle", note: "Approximate.",
             control: {label: "Month", min: 0, max: 11, step: 1, value: 5, unit: "",
                       labels: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]},
             readouts: [{label: "Angle at 49N", expression: "90 - abs(x - 5.5) * 8", unit: "°"}]}
        ]})
        verify(text.indexOf("1. Orbit the Sun — One orbit takes a year.") >= 0)
        verify(text.indexOf("2. Keep the tilt") >= 0)
        verify(text.indexOf("Why is June warm in the north?") >= 0)
        verify(text.indexOf("✓ The north leans sunward") >= 0)
        verify(text.indexOf("· Earth is closest — Distance is not the cause.") >= 0)
        verify(text.indexOf("Warmer in January?") >= 0)
        verify(text.indexOf("The Southern Hemisphere.") >= 0)
        verify(text.indexOf("January is southern summer.") >= 0)
        verify(text.indexOf("Month: Jun") >= 0, "the slider value shows its label")
        verify(text.indexOf("Angle at 49N: 86 °") >= 0, "readouts are evaluated locally for the text fallback")
        verify(text.indexOf("Approximate.") >= 0)
    }
    function test_prefixIsExplicit() {
        verify(AiState.mode("ai:"))
        verify(AiState.mode("ai: question"))
        verify(AiState.mode("AI:question"))
        verify(!AiState.mode("model:rocket prices"))
        verify(!AiState.mode(":ai"))
        verify(!AiState.mode("email ai: is a common string"))
        compare(AiState.prompt("ai:  hello  "), "hello")
        compare(AiState.prompt("ai:hello"), "hello")
    }
    function test_answerTitleUsesTopicWithoutInventingMetadata() {
        compare(AiState.answerTitle({prompt: "giraffe", blocks: [{type: "image", title: "Giraffe", query: "Giraffe"}]}), "Giraffe")
        compare(AiState.answerTitle({prompt: "price", blocks: [{type: "market", title: "Apple · AAPL", symbol: "AAPL"}]}), "Apple · AAPL")
        compare(AiState.answerTitle({prompt: "explain this", blocks: []}), "Explain this")
        verify(AiState.answerTitle({prompt: "word ".repeat(100), blocks: []}).length <= 96)
    }
    function test_matchWorkspacesRanksTitlesAndExcludesActive() {
        var index = [
            {id: "ws-1", title: "Vancouver trip", summary: "stuff to do", updatedAt: "2026-10-04T18:41:31.838Z"},
            {id: "ws-2", title: "Laptop decision", summary: "vancouver notes in summary", updatedAt: "2026-10-03T00:00:00Z"},
            {id: "ws-3", title: "Other", summary: "", updatedAt: "2026-01-01T00:00:00Z"}
        ]
        var rows = AiState.matchWorkspaces(index, "vancouver", 4, "")
        compare(rows.length, 2)
        compare(rows[0].id, "ws-1", "title matches rank above summary matches")
        compare(rows[1].id, "ws-2")
        compare(rows[0].kind, "workspace")
        compare(AiState.matchWorkspaces(index, "vancouver", 4, "ws-1").length, 1, "the active workspace is excluded")
        compare(AiState.matchWorkspaces(index, "VANCOUVER", 4, "").length, 2, "matching is case-insensitive")
        compare(AiState.matchWorkspaces(index, "  ", 4, "").length, 0, "an empty query matches nothing")
        compare(AiState.matchWorkspaces(index, "laptop", 1, "").length, 1, "the result limit is honoured")
        compare(AiState.matchWorkspaces([], "vancouver", 4, "").length, 0)
        compare(AiState.workspaceSubtitle("2026-10-04T18:41:31.838Z"), "Workspace · 2026-10-04")
        compare(AiState.workspaceSubtitle(""), "Workspace")
    }
    function test_editableDraftRemovesOnlyTheModeSeparator() {
        compare(AiState.draft("ai:   Indented draft  "), "  Indented draft  ", "Only the separator space is consumed; draft whitespace is not")
        compare(AiState.draft("AI:\t\tIndented draft\t"), "\tIndented draft\t")
        compare(AiState.draft("ai: "), "")
        compare(AiState.draft("ai:"), "")
        compare(AiState.draft("ai:question"), "question", "ai:question is accepted without a separator space")
        compare(AiState.draft("application search"), "")
        compare(AiState.draft("app search: term"), "", "Any other prefix: form stays ordinary search text")
        compare(AiState.draft(":ai   Indented draft  "), "", "The legacy prefix is ordinary search text, not AI mode")
        compare(AiState.prompt("ai:   Indented draft  "), "Indented draft", "Only submitted prompts are trimmed")
    }
    function test_turnUpdatesAreImmutable() {
        var original = AiState.newTurn("hello", "/fixtures/test-home/a.txt")
        var done = AiState.updateTurn(original, {type: "done", answer: "Hi", blocks: [], suggestions: []})
        compare(original.status, "working")
        compare(done.status, "done")
        compare(done.answer, "Hi")
        compare(AiState.updateTurn(original, {type: "stopped"}).status, "stopped")
    }
    function test_handoffNeverExecutesText() {
        compare(AiState.handoffCommand("codex", "$(touch nope)", "/state/codex", "/state").length, 0)
        compare(AiState.handoffCommand("codex", "valid-id", "/fixtures/test-home/.codex", "/state").length, 0)
        compare(AiState.handoffCommand("codex", "valid-id", "/state/../secret", "/state").length, 0)
        compare(AiState.handoffCommand("codex", "valid-id", "/state/codex", "/state")[2], "CODEX_HOME=/state/codex")
        compare(AiState.handoffCommand("hermes", "valid-id", "", "/state")[2], "--resume")
        compare(AiState.handoffCommand("unknown", "valid-id", "", "/state").length, 0)
    }
    function test_textFallbackIncludesNativeData() {
        var text = AiState.textAnswer({answer: "Summary", blocks: [{type: "checklist", title: "List", items: ["One", "Two"]}]})
        verify(text.indexOf("Summary") >= 0)
        verify(text.indexOf("• One") >= 0)
        compare(AiState.plainRichText("<p>A &amp; B</p><p>&lt;text&gt;</p>"), "A & B\n<text>")
    }
}
