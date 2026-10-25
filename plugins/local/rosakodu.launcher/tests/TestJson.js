.pragma library

// Exact equality for acyclic JSON-shaped test values. QVariant may reorder
// object properties, while QtTest.compare tolerates small numeric differences.
// Ignore only object key order; keep leaf types/values and array order exact.
function equal(actual, expected) {
    if (actual === expected) return true;
    if (actual === null || expected === null
            || typeof actual !== "object" || typeof expected !== "object") return false;
    var array = Array.isArray(actual);
    if (array !== Array.isArray(expected)) return false;
    if (array && actual.length !== expected.length) return false;
    var actualKeys = Object.keys(actual).sort();
    var expectedKeys = Object.keys(expected).sort();
    if (actualKeys.length !== expectedKeys.length) return false;
    for (var i = 0; i < actualKeys.length; ++i) {
        var key = actualKeys[i];
        if (key !== expectedKeys[i] || !equal(actual[key], expected[key])) return false;
    }
    return true;
}
