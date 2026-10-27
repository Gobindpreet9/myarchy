.pragma library

// Identity and bounded inert snapshots only. DSL evaluation belongs exclusively
// to the isolated real-core worker, never the shell's JavaScript engine.
var maxCodeBytes = 32768;
var maxContextBytes = 49152;
var maxContextStateBytes = 12288;

function utf8Bytes(text) {
    var bytes = 0;
    for (var i = 0; i < text.length; ++i) {
        var unit = text.charCodeAt(i);
        if (unit < 0x80) ++bytes;
        else if (unit < 0x800) bytes += 2;
        else if (unit >= 0xd800 && unit <= 0xdbff) {
            var next = text.charCodeAt(++i);
            if (!(next >= 0xdc00 && next <= 0xdfff)) return Infinity;
            bytes += 4;
        } else if (unit >= 0xdc00 && unit <= 0xdfff) return Infinity;
        else bytes += 3;
    }
    return bytes;
}

function target(turns, turnId, blockIndex) {
    if (typeof turnId !== "number" || typeof blockIndex !== "number"
            || blockIndex < 0 || blockIndex > 5 || blockIndex !== Math.floor(blockIndex)) return null;
    for (var i = 0; turns && i < turns.length; ++i) {
        var turn = turns[i];
        if (!turn || turn.id !== turnId || turn.status !== "done" || turn.partial === true) continue;
        var block = turn.blocks && turn.blocks[blockIndex];
        if (!block || block.type !== "openui" || typeof block.code !== "string"
                || !block.code.trim() || utf8Bytes(block.code) > maxCodeBytes) return null;
        return {turnId: turnId, blockIndex: blockIndex, code: block.code};
    }
    return null;
}

function latest(turns) {
    for (var i = turns ? turns.length - 1 : -1; i >= 0; --i) {
        var turn = turns[i], blocks = turn && turn.blocks;
        for (var j = 0; blocks && j < blocks.length && j < 6; ++j) {
            var result = target([turn], turn.id, j);
            if (result) return result;
        }
    }
    return null;
}

function identity(workspaceId, item) {
    if (!workspaceId || !item) return "";
    // Code fingerprint is routing identity, NOT an integrity/security boundary.
    var hash = 2166136261;
    for (var i = 0; i < item.code.length; ++i) hash = Math.imul(hash ^ item.code.charCodeAt(i), 16777619);
    return workspaceId + ":" + item.turnId + ":" + item.blockIndex + ":" + (hash >>> 0).toString(16);
}

function saved(uiStates, item) {
    var entry = item && uiStates && uiStates[String(item.turnId)];
    var value = entry && entry["openui:" + item.blockIndex];
    // QML wrappers are intentionally copied before array/object checks.
    try {
        var plain = JSON.parse(JSON.stringify(value === undefined ? {} : value));
        return plain && typeof plain === "object" && !Array.isArray(plain) ? plain : {};
    } catch (error) { return {}; }
}

function context(item, uiStates) {
    if (!item) return null;
    var state = saved(uiStates, item), count = 0;
    function valid(value, depth) {
        if (++count > 512 || depth > 8) return false;
        if (value === null || typeof value === "boolean") return true;
        if (typeof value === "number") return isFinite(value) && Math.abs(value) <= 9007199254740991;
        if (typeof value === "string") return utf8Bytes(value) <= 4096;
        if (!value || typeof value !== "object") return false;
        var keys = Object.keys(value);
        if (keys.length > (Array.isArray(value) ? 128 : 64)) return false;
        for (var i = 0; i < keys.length; ++i) {
            var key = keys[i];
            if (!key || utf8Bytes(key) > 64 || ["__proto__", "constructor", "prototype"].indexOf(key) >= 0
                    || !valid(value[key], depth + 1)) return false;
        }
        return true;
    }
    var result = {code: item.code, state: state};
    // Never send a truncated or silently reset state as if it were current.
    if (!valid(state, 0) || utf8Bytes(JSON.stringify(state)) > maxContextStateBytes
            || utf8Bytes(JSON.stringify(result)) > maxContextBytes) return null;
    return result;
}

function textTree(tree) {
    var lines = [], count = 0, bytes = 0;
    function append(text) {
        if (typeof text !== "string" || !text) return;
        var size = utf8Bytes(text) + 1;
        if (bytes + size <= 49152) { lines.push(text); bytes += size; }
    }
    function visit(node, depth) {
        if (!node || ++count > 512 || depth > 64) return;
        var p = node.props || {}, kind = node.kind;
        if (["Text", "Title", "Caption", "Label", "Badge", "SvgText"].indexOf(kind) >= 0) append(p.text);
        else if (["Input", "TextArea", "Slider", "Select", "SegmentedControl", "RadioGroup"].indexOf(kind) >= 0)
            append((p.label ? p.label + ": " : "") + (p.value === null ? "(empty)" : String(p.value)) + (p.suffix || ""));
        else if (kind === "Checkbox") append((p.checked ? "[x] " : "[ ] ") + (p.label || ""));
        (node.children || []).forEach(function(child) { visit(child, depth + 1); });
    }
    visit(tree, 0);
    return lines.join("\n");
}
