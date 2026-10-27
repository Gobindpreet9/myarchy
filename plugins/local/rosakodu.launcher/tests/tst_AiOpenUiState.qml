import QtQuick
import QtTest
import "../AiOpenUiState.js" as OpenUi

TestCase {
    name: "AiOpenUiState"
    function turn(id, code) {
        return {id: id, status: "done", blocks: [{type: "text", text: "A"},
            {type: "openui", title: "Tool", code: code || '$n = 1\nroot = Text($n)'}]};
    }
    function test_latestPreservesOriginalIndicesAcrossProseFollowups() {
        var turns = [turn(7), {id: 8, status: "done", blocks: []}];
        var item = OpenUi.latest(turns);
        compare(item.turnId, 7);
        compare(item.blockIndex, 1);
        turns.push(turn(9));
        compare(OpenUi.latest(turns).turnId, 9);
        turns[2].status = "working";
        compare(OpenUi.latest(turns).turnId, 7);
        turns[0].partial = true;
        compare(OpenUi.latest(turns), null);
    }
    function test_identityIsScopedToWorkspaceTurnBlockAndProgram() {
        var item = OpenUi.latest([turn(7)]);
        var key = OpenUi.identity("ws-one", item);
        verify(key !== OpenUi.identity("ws-two", item));
        verify(key !== OpenUi.identity("ws-one", OpenUi.latest([turn(8)])));
        verify(key !== OpenUi.identity("ws-one", OpenUi.latest([turn(7, 'root = Text("Other")')])));
        compare(OpenUi.identity("", item), "");
    }
    function test_contextKeepsOpaqueNamesAndDetachedExactValues() {
        var item = OpenUi.latest([turn(7)]);
        var values = {"7": {"openui:1": {"$n": 3, "$object": {artifactId: "af-user-data", steps: [false, null, 0]}}}};
        var result = OpenUi.context(item, values);
        compare(result.state.$n, 3);
        compare(result.state.$object.artifactId, "af-user-data");
        compare(result.state.$object.steps[1], null);
        result.state.$object.artifactId = "Changed";
        compare(values["7"]["openui:1"].$object.artifactId, "af-user-data");
        compare(OpenUi.saved(values, {turnId: 9, blockIndex: 1}), {});
    }
    function test_contextRefusesRatherThanTruncatingOrInventingValues() {
        var item = OpenUi.latest([turn(7)]);
        function context(value) { return OpenUi.context(item, {"7": {"openui:1": {"$n": value}}}); }
        compare(context("x".repeat(4097)), null);
        compare(context(9007199254740992), null);
    }
    function test_utf8AndCodeBoundsRejectMalformedOrOversizedPrograms() {
        compare(OpenUi.utf8Bytes("A\u00e9\ud83d\ude00"), 7);
        compare(OpenUi.utf8Bytes("\ud800"), Infinity);
        compare(OpenUi.target([turn(7, "\u00e9".repeat(17000))], 7, 1), null);
        compare(OpenUi.target([turn(7, "\ud800")], 7, 1), null);
    }
    function test_textProjectionUsesInertLabelsAndValuesNeverTheDsl() {
        var text = OpenUi.textTree({kind: "Col", props: {}, children: [
            {kind: "Slider", props: {label: "Length", value: 3.6, suffix: " m"}, children: []},
            {kind: "Title", props: {text: "48 positions"}, children: []},
            {kind: "Svg", props: {width: "100%"}, children: [
                {kind: "SvgText", props: {text: "3.6 m length"}, children: []}]}]});
        compare(text, "Length: 3.6 m\n48 positions\n3.6 m length");
    }
}
