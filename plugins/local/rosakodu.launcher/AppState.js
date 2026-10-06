// AppState.js — small, pure persistence helpers for the launcher.

.pragma library

function normalizeDesktopId(value) {
    var id = String(value == null ? "" : value).trim();
    if (id.slice(-8).toLowerCase() === ".desktop") id = id.slice(0, -8);
    return id;
}

function desktopLaunchCommand(value) {
    return desktopLaunchArgv(value).length > 0 ? ["uwsm-app", "--", "gtk-launch", desktopFileName(value)] : [];
}

// True desktop filename for a raw entry id (never strip: Quickshell entry
// ids are filenames minus the final ".desktop", so basenames may themselves
// end in ".desktop"). Returns "" for unsafe ids.
function desktopFileName(value) {
    var raw = String(value == null ? "" : value).trim();
    if (raw.slice(-4).toLowerCase() === ".exe") raw = raw.slice(0, -4);
    if (!raw || !/^[A-Za-z0-9._+@-]+$/.test(raw)) return "";
    return raw + ".desktop";
}

function desktopLaunchArgv(value) {
    var file = desktopFileName(value);
    if (!file) return [];
    return ["uwsm-app", "--", "gtk-launch", file];
}

function canLaunchEntry(entry, launching) {
    return launching !== true && !!entry && desktopLaunchCommand(entry.id).length === 4;
}

// Only focus an existing window on an exact desktop ID or StartupWMClass
// match. Fuzzy names can belong to unrelated apps and should still launch.
function matchesRunningApp(entry, appId) {
    var running = normalizeDesktopId(appId).toLowerCase();
    if (!running || !entry) return false;
    var id = normalizeDesktopId(entry.id).toLowerCase();
    var windowClass = normalizeDesktopId(entry.startupWMClass || entry.startupWmClass).toLowerCase();
    return (!!id && running === id) || (!!windowClass && running === windowClass);
}

function uniqueIds(values) {
    var input = Array.isArray(values) ? values : [];
    var seen = {};
    var result = [];
    for (var i = 0; i < input.length; i++) {
        var id = normalizeDesktopId(input[i]);
        var key = id.toLowerCase();
        if (!id || seen[key]) continue;
        seen[key] = true;
        result.push(id);
    }
    return result;
}

function parseRecentIds(raw) {
    var parsed = null;
    try { parsed = JSON.parse(String(raw == null ? "" : raw)); }
    catch (e) { return []; }
    return uniqueIds(Array.isArray(parsed) ? parsed : []);
}

function touchRecent(recentIds, desktopId, limit) {
    var id = normalizeDesktopId(desktopId);
    if (!id) return uniqueIds(recentIds);
    var existing = uniqueIds(recentIds);
    var result = [id];
    var needle = id.toLowerCase();
    for (var i = 0; i < existing.length; i++) {
        if (existing[i].toLowerCase() !== needle) result.push(existing[i]);
    }
    var cap = Math.max(1, Number(limit) || 8);
    return result.slice(0, cap);
}

function flattenPinned(raw) {
    var parsed = null;
    try { parsed = JSON.parse(String(raw == null ? "" : raw)); }
    catch (e) { return []; }
    var items = Array.isArray(parsed) ? parsed
        : (parsed && Array.isArray(parsed.pinned) ? parsed.pinned : []);
    var result = [];
    for (var i = 0; i < items.length; i++) {
        var item = items[i];
        if (typeof item === "string") result.push(item);
        else if (item && item.isStack && Array.isArray(item.apps)) {
            for (var a = 0; a < item.apps.length; a++) result.push(item.apps[a]);
        } else if (item && typeof item === "object") {
            result.push(item.appClass || item.id || item.exec || "");
        }
    }
    return uniqueIds(result);
}

function isPinned(raw, desktopId) {
    var needle = normalizeDesktopId(desktopId).toLowerCase();
    if (!needle) return false;
    var ids = flattenPinned(raw);
    for (var i = 0; i < ids.length; i++) {
        if (ids[i].toLowerCase() === needle) return true;
    }
    return false;
}

function serializeRecentIds(values) {
    return JSON.stringify(uniqueIds(values), null, 2);
}

// --- Launcher translucency --------------------------------------------------
// The dock owns the settings file; this plugin only reads its own percentage.
function normalizeTranslucency(value, fallback) {
    if (value === undefined || value === null || value === "") return fallback;
    var n = Number(value);
    return isFinite(n) ? Math.round(Math.max(0, Math.min(100, n))) : fallback;
}

function readLauncherTranslucency(rawText) {
    var parsed = null;
    try { parsed = JSON.parse(String(rawText == null ? "" : rawText)); }
    catch (e) { return 0; }
    if (!parsed || typeof parsed !== "object") return 0;
    // v2's single opacity is a fallback only; v3's launcher setting wins.
    var oldOpacity = Number(parsed.surfaceOpacity);
    var migrated = parsed.surfaceOpacity === undefined || parsed.surfaceOpacity === null || !isFinite(oldOpacity)
        ? 0 : Math.round((1 - Math.max(0, Math.min(1, oldOpacity))) * 100);
    return normalizeTranslucency(parsed.launcherTranslucency, migrated);
}

// --- Safe extra actions ----------------------------------------------------
// All extra actions use fixed dispatch paths. Query text is never executed
// as a shell command: URLs and search URLs are passed as a single argv
// element to uwsm-app/xdg-open, and calculator input is evaluated by a pure
// arithmetic parser below.

function trimQuery(value) {
    return String(value == null ? "" : value).trim();
}

function isUrlQuery(value) {
    return normalizeUrl(value) !== "";
}

function normalizeUrl(value) {
    var input = trimQuery(value);
    if (!input || input.length > 2048 || /\s/.test(input)) return "";
    var candidate = input;
    var lower = candidate.toLowerCase();
    if (lower.indexOf("http://") !== 0 && lower.indexOf("https://") !== 0) {
        candidate = "https://" + candidate;
    }
    // Conservative http(s) shape: host with a dot (or localhost), optional
    // port, optional path. No userinfo, no spaces, no backslashes.
    if (/\\/g.test(candidate)) return "";
    var match = candidate.match(/^https?:\/\/([A-Za-z0-9.-]+)(:[0-9]{1,5})?(\/[^\s]*)?$/);
    if (!match) return "";
    var host = match[1];
    if (host.toLowerCase() !== "localhost" && host.indexOf(".") === -1) return "";
    if (host.charAt(0) === "." || host.charAt(0) === "-" || host.slice(-1) === "." || host.slice(-1) === "-") return "";
    if (host.indexOf("..") !== -1) return "";
    var labels = host.split(".");
    for (var i = 0; i < labels.length; i++) {
        if (!/^[A-Za-z0-9-]+$/.test(labels[i]) || labels[i].length === 0 || labels[i].length > 63) return "";
    }
    return candidate;
}

function urlOpenCommand(value) {
    var url = normalizeUrl(value);
    if (!url) return [];
    return ["uwsm-app", "--", "xdg-open", url];
}

function webSearchUrl(value) {
    var query = trimQuery(value);
    if (!query || query.length > 200) return "";
    try {
        return "https://www.google.com/search?q=" + encodeURIComponent(query);
    } catch (e) {
        return "";
    }
}

function webSearchCommand(value) {
    var url = webSearchUrl(value);
    if (!url) return [];
    return ["uwsm-app", "--", "xdg-open", url];
}

function isMathQuery(value) {
    var input = trimQuery(value);
    if (!input || input.length > 64) return false;
    if (!/^[0-9+\-*/().\s%^]+$/.test(input)) return false;
    if (!/[0-9]/.test(input)) return false;
    if (!/[+\-*/%^()]/.test(input)) return false;
    var depth = 0;
    for (var i = 0; i < input.length; i++) {
        if (input[i] === "(") depth++;
        else if (input[i] === ")") { depth--; if (depth < 0) return false; }
    }
    return depth === 0;
}

function evaluateMath(value) {
    if (!isMathQuery(value)) return null;
    var input = trimQuery(value);
    var pos = 0;

    function peek() { return pos < input.length ? input[pos] : ""; }
    function consumeWhitespace() { while (pos < input.length && /\s/.test(input[pos])) pos++; }

    function parseExpression() {
        var result = parseTerm();
        while (true) {
            consumeWhitespace();
            var op = peek();
            if (op !== "+" && op !== "-") return result;
            pos++;
            var rhs = parseTerm();
            if (result === null || rhs === null) return null;
            result = op === "+" ? result + rhs : result - rhs;
        }
    }

    function parseTerm() {
        var result = parseFactor();
        while (true) {
            consumeWhitespace();
            var op = peek();
            if (op !== "*" && op !== "/" && op !== "%") return result;
            pos++;
            // Reject "**" (not part of the supported syntax).
            if (op === "*" && peek() === "*") return null;
            var rhs = parseFactor();
            if (result === null || rhs === null) return null;
            if (op === "*") result = result * rhs;
            else if (op === "%") { if (rhs === 0) return null; result = result % rhs; }
            else { if (rhs === 0) return null; result = result / rhs; }
        }
    }

    function parseFactor() {
        var base = parseUnary();
        consumeWhitespace();
        if (peek() === "^") {
            pos++;
            var exponent = parseFactor();
            if (base === null || exponent === null) return null;
            var powered = Math.pow(base, exponent);
            if (!isFinite(powered)) return null;
            return powered;
        }
        return base;
    }

    function parseUnary() {
        consumeWhitespace();
        var op = peek();
        if (op === "+" || op === "-") {
            pos++;
            var operand = parseUnary();
            if (operand === null) return null;
            return op === "-" ? -operand : operand;
        }
        return parsePrimary();
    }

    function parsePrimary() {
        consumeWhitespace();
        if (peek() === "(") {
            pos++;
            var inner = parseExpression();
            consumeWhitespace();
            if (peek() !== ")") return null;
            pos++;
            return inner;
        }
        var start = pos;
        var dots = 0;
        while (pos < input.length && (/[0-9]/.test(input[pos]) || input[pos] === ".")) {
            if (input[pos] === ".") dots++;
            pos++;
        }
        if (start === pos || dots > 1) return null;
        var number = Number(input.slice(start, pos));
        if (!isFinite(number)) return null;
        return number;
    }

    var result = parseExpression();
    consumeWhitespace();
    if (pos !== input.length) return null;
    if (result === null || !isFinite(result)) return null;
    return result;
}

function formatMathResult(value) {
    if (typeof value !== "number" || !isFinite(value)) return "";
    var rounded = Number(value.toFixed(6));
    if (!isFinite(rounded)) return "";
    return String(rounded);
}

function buildActionRows(query) {
    var input = trimQuery(query);
    if (!input) return [];
    var rows = [];
    // Ask AI is explicit discovery, not a hidden mode: it transfers the whole
    // query into the AI composer as an editable draft. Generation is never
    // started by selecting this row.
    rows.push({ kind: "askAi", query: input, title: "Ask AI about \u201C" + input + "\u201D" });
    var mathValue = evaluateMath(input);
    if (mathValue !== null) {
        var formatted = formatMathResult(mathValue);
        if (formatted) {
            rows.push({
                kind: "calc",
                expression: input,
                resultText: formatted,
                title: input + " = " + formatted
            });
        }
    }
    var url = normalizeUrl(input);
    if (url) {
        rows.push({ kind: "url", url: url, title: "Open " + url });
    }
    var searchUrl = webSearchUrl(input);
    if (searchUrl) {
        rows.push({ kind: "search", query: input, url: searchUrl, title: "Search web for \u201C" + input + "\u201D" });
    }
    return rows;
}
