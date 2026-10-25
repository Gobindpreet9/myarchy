import QtTest
import "TestJson.js" as TestJson

TestCase {
    name: "TestJson"

    function test_ignoresOnlyNestedObjectKeyOrder() {
        verify(TestJson.equal({v: {budget: 1800, style: 2}, sent: false},
            {sent: false, v: {style: 2, budget: 1800}}))
    }
    function test_numericLeavesAreExact() {
        verify(!TestJson.equal({wq: {v: 4.000001, u: ""}}, {wq: {v: 4, u: ""}}))
        verify(!TestJson.equal({v: [1e-12]}, {v: [0]}))
        verify(TestJson.equal({wq: {v: 4, u: ""}}, {wq: {u: "", v: 4}}))
    }
    function test_leafTypesAreExact() {
        verify(!TestJson.equal({v: "4"}, {v: 4}))
        verify(!TestJson.equal({v: false}, {v: 0}))
        verify(!TestJson.equal({v: null}, {v: undefined}))
        verify(!TestJson.equal(null, {}))
    }
    function test_missingAndExtraKeysAreRejected() {
        verify(!TestJson.equal({v: 4, u: ""}, {v: 4}))
        verify(!TestJson.equal({v: 4}, {v: 4, u: ""}))
        verify(!TestJson.equal({v: undefined}, {}))
        verify(!TestJson.equal({a: null}, {b: null}))
    }
    function test_arraysKeepOrderAndShape() {
        verify(TestJson.equal([{v: 4, u: ""}, 2], [{u: "", v: 4}, 2]))
        verify(!TestJson.equal([1, 2], [2, 1]))
        verify(!TestJson.equal([1], [1, 2]))
        verify(!TestJson.equal([], {}))
        verify(!TestJson.equal(new Array(1), []))
    }
    function test_doesNotMutateInputs() {
        var actual = {z: [2, 1], a: {v: 4, u: ""}}
        var expected = {a: {u: "", v: 4}, z: [2, 1]}
        var beforeActual = JSON.stringify(actual), beforeExpected = JSON.stringify(expected)
        verify(TestJson.equal(actual, expected))
        compare(JSON.stringify(actual), beforeActual)
        compare(JSON.stringify(expected), beforeExpected)
    }
}
