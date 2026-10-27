.pragma library

.import "AiFormula.js" as Formula
.import "AiCalc.js" as Calc
.import "AiCalcView.js" as CalcView
.import "AiCalcEdit.js" as CalcEdit
.import "AiCalcExport.js" as CalcExport
.import "CsvPage.js" as CsvPage

function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }

function mode(query) { return /^ai:/i.test(String(query || "")); }
// Canonical entry prefix. "ai: question" and "ai:question" both enter AI mode.
var prefix = "ai: ";
// Remove the hidden mode separator, not whitespace belonging to the draft.
// The canonical separator is "ai:" (3 characters); "ai:question" is accepted
// without a following space, while ":ai" remains ordinary search text.
function draft(query) { return mode(query) ? String(query).slice(3).replace(/^\s/, "") : ""; }
function prompt(query) { return mode(query) ? String(query).slice(3).trim() : ""; }
function agentName(agent) {
    return ({codex: "Codex", hermes: "Hermes", opencode: "OpenCode"})[agent] || String(agent || "No default agent");
}
// Saved workspaces are launcher-searchable; title matches rank above
// summary-only matches, and the active workspace is excluded.
function matchWorkspaces(index, query, limit, excludeId) {
    var text = String(query || "").trim().toLowerCase();
    if (!text) return [];
    var results = [];
    (index || []).forEach(function(entry) {
        if (!entry || !entry.id || (excludeId && String(entry.id) === String(excludeId))) return;
        var title = String(entry.title || "");
        var haystack = (title + " " + String(entry.summary || "")).toLowerCase();
        if (haystack.indexOf(text) < 0) return;
        results.push({kind: "workspace", id: String(entry.id),
            title: title || "Untitled workspace", updatedAt: String(entry.updatedAt || ""),
            rank: title.toLowerCase().indexOf(text) >= 0 ? 0 : 1});
    });
    results.sort(function(a, b) { return a.rank - b.rank; });
    return results.slice(0, limit > 0 ? limit : 4);
}
function workspaceSubtitle(updatedAt) {
    var match = /^(\d{4}-\d{2}-\d{2})/.exec(String(updatedAt || ""));
    return match ? "Workspace · " + match[1] : "Workspace";
}
// Explicit tool names are plain, bounded, single-line text. Keep this boundary
// in sync with the store's name validator; valid emoji pairs are allowed.
function workspaceName(value) {
    if (typeof value !== "string") return "";
    if (/[\x00-\x1f\x7f-\x9f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]/.test(value)) return "";
    var name = value.trim();
    if (!name || name.length > 96) return "";
    for (var i = 0; i < name.length; ++i) {
        var code = name.charCodeAt(i);
        if (code >= 0xd800 && code <= 0xdbff) {
            var next = name.charCodeAt(++i);
            if (!(next >= 0xdc00 && next <= 0xdfff)) return "";
        } else if (code >= 0xdc00 && code <= 0xdfff) return "";
    }
    return name;
}
function copyWorkspaceName(value) {
    var base = workspaceName(value) || "Untitled workspace";
    base = base.slice(0, 89);
    // Truncating at a UTF-16 boundary must not split an emoji.
    if (/[\ud800-\udbff]$/.test(base)) base = base.slice(0, -1);
    return base.trim() + " · Copy";
}
function answerTitle(turn) {
    if (!turn) return "";
    var visual = (turn.blocks || []).find(function(block) {
        return (block.type === "image" || block.type === "market" || block.type === "chart") && block.title;
    });
    var text = String(visual ? visual.title : turn.prompt || "Answer").trim();
    if (text.length > 96) text = text.slice(0, 93).trim() + "…";
    return text ? text[0].toUpperCase() + text.slice(1) : "Answer";
}
function supported(agent) { return agent === "codex" || agent === "hermes" || agent === "opencode"; }
// Provider the launcher will actually use. An explicit but unsupported default
// (for example claude) falls back to Codex so AI keeps working; an empty
// default stays unresolved so the person is told to choose an agent first.
function resolveAgent(agent, defaultAgent) {
    if (supported(agent)) return agent;
    if (supported(defaultAgent)) return defaultAgent;
    return defaultAgent ? "codex" : "";
}
// Disclosure whenever the provider in use differs from the person's default:
// either the launcher fell back because it does not support their default, or
// the conversation is pinned to a provider and the default changed since.
function agentFallbackNote(agent, defaultAgent) {
    var chosen = String(defaultAgent || "");
    if (!supported(agent) || !chosen || agent === chosen) return "";
    if (supported(chosen))
        return "This conversation uses " + agentName(agent) + "; your default is " + agentName(chosen)
            + ". Start a new chat to switch.";
    return "Answered by " + agentName(agent) + ": the launcher doesn't support " + chosen.slice(0, 32) + " yet.";
}
// The default-agent file is one word. Read only its first line like
// omarchy-default-agent does and accept a plain identifier, so a stray comment
// line or an invisible character cannot silently reroute the provider.
function parseDefaultAgent(text) {
    var first = String(text == null ? "" : text).split(/\r?\n/)[0].trim().toLowerCase();
    return /^[a-z0-9_-]{1,32}$/.test(first) ? first : "";
}
// Plain-language recovery guidance for a failed turn. Only exact, known broker
// messages are rewritten; anything else keeps the raw message as its detail so
// an unfamiliar failure is never hidden behind friendly copy.
function failureAdvice(message, attachment) {
    var text = String(message || "");
    // Definitive: the launcher found no provider sign-in at all.
    var signIn = /^Sign in to (Codex|OpenCode) before using launcher AI\.?$/.exec(text);
    if (signIn)
        return {headline: "Sign in to " + signIn[1],
                detail: signIn[1] === "Codex"
                    ? "The launcher has no Codex sign-in yet. Sign in from a terminal, then try again."
                    : "The launcher has no OpenCode sign-in yet. Run `opencode auth login` in a terminal, then try again.",
                retryLabel: "Try again", dropAttachment: false,
                signInAgent: signIn[1].toLowerCase(), signInPrimary: signIn[1] === "Codex"};
    // The broker raises this for ANY provider error event (sign-in, usage
    // limit, network), so it is offered as a likely cause, never asserted.
    var auth = /^(Codex|OpenCode|Hermes) could not complete the answer\. Check (?:authentication|sign-in) in the terminal\.?$/.exec(text);
    if (auth)
        return {headline: auth[1] + " couldn't complete the answer",
                detail: auth[1] === "Codex"
                    ? "It often needs a fresh sign-in, but it can also be a usage limit or a network problem."
                    : "Check its sign-in in a terminal, then try again.",
                retryLabel: "Try again", dropAttachment: false, signInAgent: auth[1].toLowerCase(), signInPrimary: false};
    if (/Attachment is unavailable or is a symbolic link\./.test(text))
        return {headline: "That file isn't available",
                detail: "It may have been moved or deleted. You can try again without it.",
                retryLabel: attachment ? "Try again without the file" : "Try again",
                dropAttachment: !!attachment, signInAgent: "", signInPrimary: false};
    return {headline: "Couldn't get an answer", detail: text, retryLabel: "Try again", dropAttachment: false, signInAgent: "", signInPrimary: false};
}
// Fixed-argv terminal command that signs a provider in. Codex only: the
// launcher copies ~/.codex/auth.json, so a normal `codex login` is enough.
// Hermes and OpenCode have no verified fixed sign-in command yet and get
// guidance only. No model, workspace or user text is ever interpolated.
// CODEX_HOME is unset so the login lands in ~/.codex, the only place the
// launcher copies from.
function signInCommand(agent) {
    return agent === "codex" ? ["omarchy-launch-terminal", "env", "-u", "CODEX_HOME", "codex", "login"] : [];
}
// Next-step hint shown beneath a CSV preview error. The static error text
// itself stays untouched (it is an allowlisted, test-pinned string); this only
// says what the person can do about it. Empty when the message already does.
function previewAdvice(error) {
    var text = String(error || "");
    if (/unavailable or is a symbolic link/.test(text))
        return "The file may have been moved or deleted. Restore it and retry, or remove the attachment.";
    if (/Retry to read the file again/.test(text)) return "";
    if (/columns|parsed|header row|empty|text file smaller/i.test(text))
        return "Fix the file and retry, or attach a different one.";
    return "";
}
// Test-only submitfile IPC uses this same guarded path. Callbacks belong to the
// launcher host, never model input; attachment validation remains reader-owned.
function submitFile(service, text, path, applyQuery, submitCurrent) {
    if (!service) return "no-service";
    if (service.busy || service.stopping || service.workspaceActionPending) return "busy";
    if (service.loadingLatest) return "loading";
    var question = String(text || "").trim();
    if (!question || question.length > 8000 || !String(path || "")) return "rejected";
    if (!resolveAgent(service.agent, service.defaultAgent)) return "rejected";
    var file = String(path || "");
    // Capture permission BEFORE assignment/query callbacks: readiness gained
    // during initial attachment must never turn review into an automatic send.
    var readyCurrent = service.attachment === file && !service.attachmentBlocked;
    service.attachment = file;
    applyQuery(prefix + question);
    if (/\.csv$/i.test(file) && !readyCurrent)
        return service.previewStatus === "error" ? "attachment-error" : "previewing";
    return submitCurrent();
}
function newTurn(prompt, attachment) {
    return {prompt: prompt, attachment: attachment || "", answer: "", blocks: [], suggestions: [],
            status: "working", error: "", warning: ""};
}
function updateTurn(turn, event) {
    var next = Object.assign({}, turn);
    if (event.type === "presentation" && event.partial === true) {
        // Future partial-turn seam (nothing emits it yet): `from === 0`
        // replaces, `from === blocks.length` appends, anything else is ignored
        // until the final event resyncs. Never touches answer/status except
        // to mark the turn partial; a settled turn ignores late partials.
        var have = Array.isArray(next.blocks) ? next.blocks.length : 0;
        if (next.status !== "working" || !Array.isArray(event.blocks)
                || typeof event.from !== "number" || event.from !== Math.floor(event.from)
                || (event.from !== 0 && event.from !== have)) return next;
        next.blocks = (event.from === 0 ? [] : next.blocks).concat(event.blocks).slice(0, 6);
        next.partial = true;
        return next;
    }
    if (event.type === "delta") next.answer = String(event.text || "").slice(0, 20000);
    if (event.type === "explain") {
        // Adaptive depth sidecar: prose only, never touches the answer or
        // the presented blocks.
        next.explanation = String(event.text || "").slice(0, 8000);
        next.status = "done";
    }
    if (event.type === "done" || event.type === "presentation") {
        next.answer = String(event.answer || "").slice(0, 20000);
        next.blocks = Array.isArray(event.blocks) ? event.blocks.slice(0, 6) : [];
        next.suggestions = Array.isArray(event.suggestions) ? event.suggestions.slice(0, 3) : [];
        next.warning = String(event.warning || "");
        next.status = event.type === "done" ? "done" : "working";
        delete next.partial;
    }
    if (event.type === "error") {
        next.error = String(event.message || "Unable to get an answer.").slice(0, 700);
        next.status = "error";
        delete next.partial;
    }
    if (event.type === "stopped") {
        next.status = "stopped";
        next.blocks = (next.blocks || []).map(function(block) {
            return block.loading ? Object.assign({}, block, {loading: false, error: "Visual loading stopped."}) : block;
        });
    }
    return next;
}

// Drop per-turn interaction state keyed by a block index the FINAL answer
// does not have (a streamed prefix that was shortened or replaced by the
// whole-answer fallback). Unknown key forms (`csv:<source>`) are left alone.
// The dynamic-vocabulary keys (`act:`, `compare:`, `plan:`) also go when the
// block now at that index has a different TYPE, judged only when the optional
// `blocks` list is passed. Returns the SAME object when nothing was removed.
var VOCAB_STATE_TYPES = {act: ["actions", "compare"], compare: ["compare"], plan: ["timeline"], openui: ["openui"]};
function pruneUiState(state, blockCount, blocks) {
    if (!state || typeof state !== "object" || Array.isArray(state)) return state;
    var count = typeof blockCount === "number" && isFinite(blockCount) ? Math.max(0, Math.floor(blockCount)) : 0;
    var typed = blocks && typeof blocks === "object" && typeof blocks.length === "number";
    var kept = {}, removed = false;
    for (var key in state) {
        if (!Object.prototype.hasOwnProperty.call(state, key)) continue;
        var match = /^(?:check|slider|calc|form|table|diagram|step|predict|image):(\d+)$/.exec(key)
            || /^gallery:(\d+):\d+$/.exec(key);
        if (match && parseInt(match[1], 10) >= count) { removed = true; continue; }
        var vocab = /^(act|compare|plan|openui):(\d+)$/.exec(key);
        if (vocab) {
            var at = parseInt(vocab[2], 10), held = null;
            if (typed && at < count) { try { held = blocks[at]; } catch (e) { held = null; } }
            if (at >= count || (typed && !(held && typeof held === "object"
                    && VOCAB_STATE_TYPES[vocab[1]].indexOf(held.type) >= 0))) { removed = true; continue; }
        }
        kept[key] = state[key];
    }
    return removed ? kept : state;
}

// ---- Honest waiting (pure). The provider returns the whole answer at the
// end, so the only truthful signals are the broker's real phase and elapsed
// time. Nothing here guesses a medium or invents progress.
var WORK_COUNTER_FROM = 3;      // seconds of waiting before the counter shows
var WORK_NAME_EVERY = 5;        // minimum seconds between accessible-name updates
function workSeconds(value) {
    var n = typeof value === "number" && isFinite(value) ? Math.floor(value) : 0;
    return Math.max(0, Math.min(86400, n));
}
function workPhase(activity) {
    var text = String(activity === undefined || activity === null ? "" : activity)
        .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\ufeff]+/g, " ")
        .replace(/\s+/g, " ").replace(/^ | $/g, "").replace(/(?:\u2026|\.{2,}) ?$/, "").slice(0, 40);
    return text.length ? text : "Thinking";
}
function workElapsedLabel(seconds) {
    var s = workSeconds(seconds), m = Math.floor(s / 60);
    return m ? m + " min" + (s % 60 ? " " + (s % 60) + " s" : "") : s + " s";
}
function workElapsedSpeech(seconds) {
    var s = workSeconds(seconds), m = Math.floor(s / 60), r = s % 60;
    function unit(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }
    return m ? unit(m, "minute") + (r ? " " + unit(r, "second") : "") : unit(r, "second");
}
// Visible line: the real phase, plus the elapsed counter from 3 s on.
function workingText(activity, seconds) {
    var s = workSeconds(seconds);
    return workPhase(activity) + "\u2026" + (s >= WORK_COUNTER_FROM ? " \u00b7 " + workElapsedLabel(s) : "");
}
// Throttled accessible name: returns `previous` unchanged while the phase is
// the same and less than 5 s have passed, so a screen reader hears one update
// per phase change or per 5 s, never the 1 Hz counter.
function workingAnnouncement(previous, activity, seconds) {
    var phase = workPhase(activity), s = workSeconds(seconds);
    if (previous && previous.phase === phase && s >= previous.seconds && s - previous.seconds < WORK_NAME_EVERY)
        return previous;
    return {phase: phase, seconds: s, name: "Working, "
        + (s >= WORK_COUNTER_FROM ? workElapsedSpeech(s) + ", " : "") + phase.toLowerCase()};
}

// ---- Local timing ring (memory only; never persisted or sent to a model).
// Every key of the broker's `timing` object is optional and untrusted.
var TIMING_MARKS = ["received", "spawn", "first_event", "first_text", "first_block", "final", "done"];
var TIMING_RING_MAX = 50;
var TIMING_MS_MAX = 600000;
function timingInt(value, maximum) {
    // Numbers only: strings, NaN, Infinity and negatives are dropped, never
    // coerced into a fast-looking zero.
    if (typeof value !== "number" || !isFinite(value) || value < 0) return null;
    return Math.min(maximum, Math.round(value));
}
function sanitizeTiming(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    var out = {marks: {}}, any = false;
    var source = raw.marks && typeof raw.marks === "object" && !Array.isArray(raw.marks) ? raw.marks : null;
    for (var i = 0; source && i < TIMING_MARKS.length; ++i) {
        var mark = calcOwn(source, TIMING_MARKS[i]) ? timingInt(source[TIMING_MARKS[i]], TIMING_MS_MAX) : null;
        if (mark !== null) { out.marks[TIMING_MARKS[i]] = mark; any = true; }
    }
    if (typeof raw.streamed === "boolean") { out.streamed = raw.streamed; any = true; }
    if (typeof raw.agent === "string" && /^[A-Za-z0-9_-]{1,32}$/.test(raw.agent)) { out.agent = raw.agent; any = true; }
    var counts = [["nBlocks", 100], ["bytesIn", 1073741824], ["bytesOut", 1073741824]];
    for (var c = 0; c < counts.length; ++c) {
        var count = calcOwn(raw, counts[c][0]) ? timingInt(raw[counts[c][0]], counts[c][1]) : null;
        if (count !== null) { out[counts[c][0]] = count; any = true; }
    }
    if (raw.usage && typeof raw.usage === "object" && !Array.isArray(raw.usage)) {
        var usage = {}, used = 0;
        for (var name in raw.usage) {
            if (!calcOwn(raw.usage, name) || used >= 8 || !/^[A-Za-z_]{1,32}$/.test(name)) continue;
            var amount = timingInt(raw.usage[name], 1000000000);
            if (amount !== null) { usage[name] = amount; ++used; }
        }
        if (used) { out.usage = usage; any = true; }
    }
    return any ? out : null;
}
// Duration from the turn's `received` mark (0 when absent) to `key`.
function timingSpan(entry, key) {
    var marks = entry && entry.marks;
    var end = marks && typeof marks[key] === "number" ? marks[key] : null;
    if (end === null) return null;
    var start = typeof marks.received === "number" ? marks.received : 0;
    return end >= start ? end - start : null;
}
// Nearest-rank percentile over a numeric list (an observed value, never an
// interpolated one); null for an empty list.
function percentile(values, fraction) {
    if (!values.length) return null;
    var sorted = values.slice().sort(function(a, b) { return a - b; });
    return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)];
}
function timingSummary(ring) {
    var entries = [];
    for (var i = 0; ring && i < ring.length; ++i) if (ring[i] && typeof ring[i] === "object") entries.push(ring[i]);
    function spans(keys) {
        var list = [];
        entries.forEach(function(entry) {
            for (var k = 0; k < keys.length; ++k) {
                var span = timingSpan(entry, keys[k]);
                if (span !== null) { list.push(span); return; }
            }
        });
        return list;
    }
    var done = spans(["done", "final"]);
    var flagged = entries.filter(function(entry) { return typeof entry.streamed === "boolean"; });
    var streamed = flagged.filter(function(entry) { return entry.streamed; }).length;
    return {n: entries.length,
        ttfTextP50: percentile(spans(["first_text"]), 0.5),
        ttfBlockP50: percentile(spans(["first_block"]), 0.5),
        doneP50: percentile(done, 0.5),
        doneP95: percentile(done, 0.95),
        streamedShare: flagged.length ? Math.round(100 * streamed / flagged.length) / 100 : null,
        note: entries.length < 20 ? "p95 is indicative (n < 20)" : ""};
}

// ---- Typed computation (`calc`) hooks. Everything here is pure and never
// throws: a hostile block (cycle, junk, too many inputs) degrades to text.
var CALC_MAX_INPUTS = 12;
function calcOwn(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }
// One plain-text line: control characters and line separators become spaces,
// so no authored field can forge a line or a markup run in the export/context.
function calcText(value, max) {
    return String(value === undefined || value === null ? "" : value)
        .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}
// QML hands blocks and state over as V4Sequence / V4ReferenceObject wrappers
// (Array.isArray is false all the way down, and the engine requires real
// arrays), so every entry point first takes a plain-JSON copy. Bounded: one
// block is small, and a copy that fails (cyclic, huge) simply yields null.
function calcPlain(value) {
    try { return JSON.parse(JSON.stringify(value)) } catch (e) { return null }
}

// Ordinary follow-up snapshot. This is an explicit-submit helper, never a
// binding: no transcript, provider calls or persisted state writes. Deliberately
// separate from the legacy calc text/depth helpers below.
function contextText(value, maximum, flags, whole) {
    if (typeof value !== "string") return "";
    var text = "";
    for (var i = 0; i < value.length; ++i) {
        var c = value.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
            var d = value.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) text += value[i] + value[++i];
            else text += "�";
        } else text += c >= 0xdc00 && c <= 0xdfff ? "�" : value[i];
    }
    text = text.replace(/[\x00-\x1f\x7f-\x9f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]+/g, " ")
        .replace(/\s+/g, " ").trim();
    if (text.length > maximum) {
        flags.truncated = true;
        if (whole) return ""; // Never a partial numeric display or formula.
        text = text.slice(0, maximum);
        if (/[\ud800-\udbff]$/.test(text)) text = text.slice(0, -1);
    }
    return text;
}
function contextExpression(value, flags) {
    // Bound the authored expression BEFORE cleaning. It is data, not executable
    // code, and a partial expression must never masquerade as the original.
    if (typeof value !== "string") return "";
    if (value.length > 256) { flags.truncated = true; return ""; }
    return contextText(value, 256, flags, true);
}
function contextLabel(raw, shown, nativeLimit, flags) {
    if (typeof raw === "string" && raw.length > nativeLimit) flags.truncated = true;
    return contextText(shown, 80, flags, false);
}
function contextNode(plan, result, id, flags) {
    var node = result.nodes[id];
    var error = node && node.err ? contextText(node.err.code, 24, flags, false) : "";
    var value = node && !node.err && (typeof node.value === "boolean" || CalcView.finite(node.value)) ? node.value : null;
    return {value: value, display: contextText(Calc.formatCell(plan.model, result, id), 160, flags, true), error: error};
}
function contextColumns(cols, flags) {
    // Reserve the first label column and formula columns, including a final
    // score beyond column six. Return the selected columns in authored order.
    var chosen = [], formulas = [], firstText = -1, i;
    for (i = 0; i < cols.length; ++i) {
        if (cols[i].kind === "text" && firstText < 0) firstText = i;
        if (cols[i].kind === "formula") formulas.push(i);
    }
    if (firstText >= 0) chosen.push(firstText);
    var room = 6 - chosen.length;
    if (formulas.length > room) {
        flags.truncated = true;
        // Keep the first formulas plus the last (usually the combined score).
        formulas = formulas.slice(0, room - 1).concat(formulas.slice(-1));
    }
    chosen = chosen.concat(formulas);
    for (i = 0; i < cols.length && chosen.length < 6; ++i)
        if (chosen.indexOf(i) < 0) chosen.push(i);
    if (chosen.length < cols.length) flags.truncated = true;
    return chosen.sort(function(a, b) { return a - b; });
}
// The authored block with the person's table edits applied (removed rows gone,
// added rows appended), index-parallel to plan.tables[i].rows. The plan was
// built from the same saved data, so replaying its dataKey cannot disagree;
// when the plan fell back to the authored rows (dataKey ""), so does this.
function contextBlock(plan, block) {
    try {
        if (!plan || !plan.dataKey) return block;
        var applied = CalcEdit.applyData(block, JSON.parse(plan.dataKey));
        return applied && applied.block && Array.isArray(applied.block.tables) ? applied.block : block;
    } catch (e) { return block; }
}
function contextCalc(block, entry, turnId, blockIndex) {
    var out = {turnId: turnId, blockIndex: blockIndex, title: "", inputs: [], outputs: [], tables: [],
        unavailable: false, truncated: false};
    out.title = contextText(block.title, 160, out, false);
    var run = CalcView.run(block, entry), plan = run.plan, result = run.result;
    if (!plan || !result) { out.unavailable = true; return out; }
    var i, j, r, effective = contextBlock(plan, block);
    // A unit is semantic, not a clippable label. Conservatively withhold the
    // calculation if any numeric record cannot retain its full native unit.
    var unitOverflow = false;
    for (i = 0; i < plan.inputs.length; ++i) if (plan.inputs[i].unit.length > 16) unitOverflow = true;
    for (i = 0; i < plan.cells.length; ++i) if (result.nodes[plan.cells[i].id].unit.length > 32) unitOverflow = true;
    for (i = 0; i < plan.tables.length; ++i)
        for (j = 0; j < plan.tables[i].cols.length; ++j)
            if (plan.tables[i].cols[j].unitText.length > 32) unitOverflow = true;
    if (unitOverflow) { out.unavailable = out.truncated = true; return out; }
    for (i = 0; i < plan.inputs.length; ++i) {
        var input = plan.inputs[i];
        out.inputs.push({id: contextText(input.id, 24, out, false),
            label: contextLabel(block.inputs[i].label, input.label, 120, out),
            value: calcNumber(run.current[input.id]), unit: contextText(input.unit, 16, out, false),
            basis: contextText(input.basis, 120, out, false), adjusted: run.current[input.id] !== input.value});
    }
    for (i = 0; i < plan.cells.length && i < 12; ++i) {
        var cell = plan.cells[i], data = contextNode(plan, result, cell.id, out);
        out.outputs.push({id: contextText(cell.id, 96, out, false),
            label: contextLabel(block.cells[i].label, cell.label, 120, out), value: data.value,
            unit: contextText(result.nodes[cell.id].unit, 32, out, false), display: data.display,
            error: data.error, expression: contextExpression(cell.expression, out)});
    }
    if (plan.cells.length > out.outputs.length) out.truncated = true;
    var remaining = 12;
    for (i = 0; i < plan.tables.length && i < 4; ++i) {
        var tb = plan.tables[i], authored = effective.tables[i], mt = plan.model.tables[i];
        var selected = contextColumns(tb.cols, out);
        if (!selected.length) { out.truncated = true; continue; }
        var table = {id: contextText(tb.id, 24, out, false),
            label: contextLabel(authored.label, tb.label, 120, out), columns: [], rows: []};
        for (j = 0; j < selected.length; ++j) {
            var colIndex = selected[j], col = tb.cols[colIndex];
            table.columns.push({id: contextText(col.id, 24, out, false),
                label: contextLabel(authored.columns[colIndex].label, col.label, 80, out), kind: col.kind,
                unit: contextText(col.unitText, 32, out, false),
                expression: contextExpression(mt.cols[colIndex].expr, out)});
        }
        var count = Math.min(6, tb.rows.length, Math.floor(remaining / selected.length));
        if (count < tb.rows.length) out.truncated = true;
        for (r = 0; r < count; ++r) {
            var row = [];
            for (j = 0; j < selected.length; ++j) {
                var c = selected[j], column = tb.cols[c], raw = tb.rows[r][c], item;
                var original = authored.rows[r][c];
                if (String(original === null || original === undefined ? "" : original).length > 200) out.truncated = true;
                if (column.kind === "formula") item = contextNode(plan, result, tb.id + "." + column.id + "#" + (r + 1), out);
                else if (column.kind === "text") {
                    var text = contextText(raw, 160, out, false);
                    item = {value: text, display: text, error: ""};
                } else {
                    // Use the engine's parsed cell/error, not a permissive
                    // Number("") coercion that would invent a zero.
                    var parsed = mt.cols[c].cells[r];
                    item = {value: parsed.empty || parsed.err ? null : calcNumber(Number(raw)),
                        display: contextText(raw, 160, out, true),
                        error: parsed.err ? contextText(parsed.err, 24, out, false) : ""};
                }
                row.push(item);
            }
            table.rows.push(row);
        }
        remaining -= count * selected.length;
        out.tables.push(table);
    }
    if (plan.tables.length > out.tables.length) out.truncated = true;
    return out;
}
function workspaceContext(turns, uiStates) {
    var list = calcPlain(turns), states = calcPlain(uiStates), previous = null, i;
    if (!Array.isArray(list)) return null;
    for (i = list.length - 1; i >= 0; --i) {
        var turn = list[i];
        if (turn && turn.status === "done" && CsvPage.isInt(turn.id, 0, CsvPage.MAX_SAFE)) { previous = turn; break; }
    }
    if (!previous) return null;
    var out = {version: 1, previous: {turnId: previous.id, prompt: "", answer: ""}, truncated: false};
    out.previous.prompt = contextText(previous.prompt, 512, out, false);
    out.previous.answer = contextText(previous.answer, 1024, out, false);
    var found = false;
    for (i = list.length - 1; i >= Math.max(0, list.length - 20) && !found; --i) {
        var candidate = list[i];
        if (!candidate || candidate.status !== "done" || !CsvPage.isInt(candidate.id, 0, CsvPage.MAX_SAFE)
                || !Array.isArray(candidate.blocks)) continue;
        for (var b = Math.min(63, candidate.blocks.length - 1); b >= 0; --b) {
            if (!candidate.blocks[b] || candidate.blocks[b].type !== "calc") continue;
            var turnState = states && typeof states === "object" && !Array.isArray(states) ? states[candidate.id] : null;
            var entry = turnState && typeof turnState === "object" && !Array.isArray(turnState) ? turnState["calc:" + b] : null;
            out.calc = contextCalc(candidate.blocks[b], entry, candidate.id, b);
            found = true;
            break;
        }
    }
    if (out.calc && out.calc.truncated) out.truncated = true;
    // Compact serialized UTF-8 is the actual envelope budget. Drop complete
    // records only; tables with oversized metadata can finally be omitted whole.
    while (CsvPage.utf8Bytes(JSON.stringify(out)) > 8192 && out.calc) {
        out.truncated = out.calc.truncated = true;
        var removed = false;
        for (i = out.calc.tables.length - 1; i >= 0; --i) {
            if (out.calc.tables[i].rows.length) { out.calc.tables[i].rows.pop(); removed = true; break; }
        }
        if (removed) continue;
        if (out.calc.outputs.length) out.calc.outputs.pop();
        else if (out.calc.inputs.length) out.calc.inputs.pop();
        else if (out.calc.tables.length) out.calc.tables.pop();
        else break; // Bounded previous + empty calc always fits.
    }
    return out;
}
function calcNumber(value) { return typeof value === "number" && isFinite(value) ? value : null; }
function calcNumberText(value) { return String(Number(value.toPrecision(15))); }
// ONE evaluation path for every consumer (copy text, trail, depth context):
// CalcView.run(block, entry), the very call the renderer and the follow-up
// snapshot make, so edited cells, added/removed rows and restore semantics
// (a stale or out-of-range stored input RESETS to its default, never clamps)
// are identical everywhere. A block that cannot compile has no plan: no inputs,
// model or result (it is "can't be shown" in the UI, so nothing is reported).
function calcNoRun() {
    return {inputs: [], model: null, result: null, plan: null, current: {}, entry: null, scenarios: [], reset: false,
        edited: {cells: 0, rowsAdded: 0, rowsRemoved: 0}};
}
function calcEditedCount(edited) {
    return edited ? (Number(edited.cells) || 0) + (Number(edited.rowsAdded) || 0) + (Number(edited.rowsRemoved) || 0) : 0;
}
// The block's inputs with their CURRENT (effective) value. `adjusted` is true
// only when that value differs from the authored default.
function calcInputs(block, entry) { return calcRun(block, entry).inputs }
// Compile + evaluate at the current inputs and effective data. model/result are
// null when the block cannot compile (or evaluation threw), never an exception.
function calcRun(block, entry) {
    try {
        var plainEntry = calcPlain(entry);
        var run = CalcView.run(calcPlain(block), plainEntry);
        if (!run || !run.plan || !run.result) return calcNoRun();
        var inputs = [];
        for (var i = 0; i < run.plan.inputs.length && inputs.length < CALC_MAX_INPUTS; ++i) {
            var input = run.plan.inputs[i], current = calcNumber(run.current[input.id]);
            inputs.push({rawId: input.id, id: calcText(input.id, 24), label: calcText(input.label, 80) || calcText(input.id, 24),
                unit: calcText(input.unit, 16), basis: calcText(input.basis, 120), value: current,
                adjusted: current !== calcNumber(input.value)});
        }
        return {inputs: inputs, model: run.plan.model, result: run.result, plan: run.plan, current: run.current,
            entry: plainEntry, scenarios: run.scenarios || [], reset: !!run.reset,
            edited: run.plan.edited || calcNoRun().edited};
    } catch (e) {
        return calcNoRun();
    }
}
// Markdown view of a run: marks are the effective cells carrying a saved edit;
// scenarios (when saved) compare every cell across Current + each scenario.
function calcExportView(block, run) {
    var plan = run.plan, marks = [], i, j, r;
    var data = plan.data && typeof plan.data === "object" ? plan.data : {};
    for (i = 0; i < plan.tables.length; ++i) {
        var tb = plan.tables[i], rec = data[tb.id];
        if (!rec || typeof rec !== "object" || !rec.e || typeof rec.e !== "object") continue;
        for (r = 0; r < tb.rows.length; ++r)
            for (j = 0; j < tb.cols.length; ++j)
                if (calcOwn(rec.e, String(tb.rowIds[r]) + "|" + tb.cols[j].id)) marks.push({table: tb.id, row: r, col: tb.cols[j].id});
    }
    var scenarios = null;
    if (run.scenarios.length) {
        var list = CalcView.scenarioResults(plan, run.entry, run.result), rows = [];
        for (i = 0; i < plan.cells.length; ++i) {
            var cell = plan.cells[i], node = run.result.nodes[cell.id], values = [], errors = [];
            for (j = 0; j < list.length; ++j) {
                var res = list[j].result, got = res && res.nodes ? res.nodes[cell.id] : null, text = "";
                if (got) { try { text = Calc.formatCell(plan.model, res, cell.id) } catch (e) { text = "" } }
                values.push(text);
                errors.push(!got ? "ERROR" : got.err ? got.err.code : null);
            }
            rows.push({label: plan.labels[cell.id] || cell.id, unit: node && node.unit ? node.unit : "", values: values, errors: errors});
        }
        scenarios = {names: list.map(function(item) { return item.name }), rows: rows};
    }
    return CalcExport.viewFromRun(block, plan, run.result, {values: run.current, edited: marks, scenarios: scenarios});
}
// Copied text for a calc block: the Markdown export of the CURRENT effective
// state. A block that cannot be built prints only its title and one notice.
function calcExport(block, entry) {
    block = calcPlain(block) || {};
    var title = typeof block.title === "string" ? calcText(block.title, 160) : "";
    var cant = "This calculation can't be shown.", view = null;
    try {
        var run = calcRun(block, entry);
        if (run.plan) view = calcExportView(block, run);
    } catch (e) { view = null }
    if (!view) return title ? title + "\n\n" + cant : cant;
    return CalcExport.markdown(block, view).replace(/\s+$/, "");
}
// Lines the follow-up (depth) context adds for a calc block, after "Subject:":
// effective inputs, an `edited:` line only when data was edited, `scenarios: N`
// when saved, and the first erroring cell.
function calcDepthLines(block, entry) {
    var lines = [];
    var run = calcRun(block, entry);
    if (!run.plan) return lines;
    var shown = run.inputs.filter(function(input) { return input.value !== null; }).map(function(input) {
        return input.id + "=" + calcNumberText(input.value) + (input.unit ? " " + input.unit : "");
    });
    if (shown.length) lines.push("Inputs: " + shown.join(", ").slice(0, 300));
    if (calcEditedCount(run.edited) > 0)
        lines.push("edited: cells=" + (Number(run.edited.cells) || 0) + " rowsAdded=" + (Number(run.edited.rowsAdded) || 0)
            + " rowsRemoved=" + (Number(run.edited.rowsRemoved) || 0));
    if (run.scenarios.length) lines.push("scenarios: " + run.scenarios.length);
    var ids = run.model.cellIds || [];
    for (var i = 0; i < ids.length; ++i) {
        var node = run.result.nodes[ids[i]];
        if (node && node.err) {
            lines.push("Calculation error in " + calcText(ids[i], 24) + ": " + calcText(node.err.code, 24))
            break
        }
    }
    return lines;
}
// ---- Forms (`form` block). Pure, never throw, JSON-copy their inputs first
// (turn blocks arrive as QML wrappers). State lives in `form:<blockIndex>` =
// {v: {<fieldId>: number|string}, sent: bool}: only values that passed the
// field's own rule, so a derived flag (validity, "all answered") is never stored.
// A restored value that is unknown, out of range or malformed is DROPPED (never
// clamped); the form then counts as not sent.
var FORM_PROMPT = "Answers to the form on the previous answer.";
var FORM_ID = /^[a-z][a-z0-9_]{0,23}$/;
var FORM_KINDS = ["number", "choice", "text", "toggle"];
var FORM_BOUND = 1000000000;
var FORM_TEXT_MAX = 200;
// The broker accepts 4096 compact UTF-8 bytes for the submitted form; leave a
// little room for float spelling differences between the two runtimes.
var FORM_WIRE_MAX = 4000;
function formLine(value, max) { return contextText(value, max, {}, false); }
function formBound(value) { return typeof value === "number" && isFinite(value) && Math.abs(value) <= FORM_BOUND; }
function formNumberText(value) {
    return typeof value === "number" && isFinite(value) ? String(Number(value.toPrecision(12))) : "";
}
function formRangeHint(field) {
    return formNumberText(field.min) + " to " + formNumberText(field.max) + (field.unit ? " " + field.unit : "");
}
// Same character policy as AiCalcEdit.parseCell(raw, "text") (it is the
// function's own regex/pair check) with the form's 200-character cap.
function formParseText(raw) {
    if (typeof raw !== "string") return {ok: false, text: "", msg: "Enter text."};
    var s = CalcEdit.trimAscii(raw);
    if (s.length > FORM_TEXT_MAX) return {ok: false, text: "", msg: "Too long. Use at most 200 characters."};
    if (CalcEdit.UNSAFE.test(s) || !CalcEdit.pairsOk(s))
        return {ok: false, text: "", msg: "Remove control or invisible characters."};
    return {ok: true, text: s, msg: ""};
}
// Typed number for a field: ok only inside [min, max]. `clamped` is what a
// commit would use for a valid number that is merely out of range (null when
// the text is not a number at all).
function formParseNumber(field, raw) {
    var p = CalcEdit.parseCell(raw, "number");
    if (!p.ok) return {ok: false, value: null, clamped: null, msg: p.msg};
    if (p.empty) return {ok: false, value: null, clamped: null, msg: "Enter a number."};
    if (p.value < field.min || p.value > field.max)
        return {ok: false, value: null, clamped: Math.min(field.max, Math.max(field.min, p.value)),
                msg: "Outside the allowed range of " + formRangeHint(field) + "."};
    return {ok: true, value: p.value, clamped: p.value, msg: ""};
}
// Plain, bounded model of a form block (<= 6 usable fields), or null.
function formNormalize(block) {
    var p = calcPlain(block);
    if (!p || typeof p !== "object" || Array.isArray(p) || p.type !== "form" || !Array.isArray(p.fields)) return null;
    var fields = [], seen = {};
    for (var i = 0; i < p.fields.length && fields.length < 6; ++i) {
        var f = p.fields[i];
        if (!f || typeof f !== "object" || Array.isArray(f)) continue;
        if (typeof f.id !== "string" || !FORM_ID.test(f.id) || calcOwn(seen, f.id)) continue;
        var label = formLine(f.label, 80);
        if (!label || FORM_KINDS.indexOf(f.kind) < 0) continue;
        var out = {id: f.id, label: label, kind: f.kind, unit: "", min: 0, max: 0, step: 0, value: 0,
                   options: [], placeholder: ""};
        if (f.kind === "number") {
            if (!formBound(f.min) || !formBound(f.max) || !(f.min < f.max)) continue;
            out.min = f.min;
            out.max = f.max;
            out.step = formBound(f.step) && f.step > 0 ? Math.min(f.step, f.max - f.min) : f.max - f.min;
            out.unit = formLine(f.unit, 16);
            out.value = Math.min(f.max, Math.max(f.min, formBound(f.value) ? f.value : f.min));
        } else if (f.kind === "choice") {
            if (!Array.isArray(f.options) || f.options.length < 2 || f.options.length > 6) continue;
            var options = [], names = {}, good = true;
            for (var k = 0; k < f.options.length; ++k) {
                var option = formLine(f.options[k], 48);
                if (!option || calcOwn(names, option)) { good = false; break; }
                names[option] = true;
                options.push(option);
            }
            if (!good) continue;
            out.options = options;
            var index = f.value;
            out.value = typeof index === "number" && index === Math.floor(index) && index >= 0 && index < options.length ? index : 0;
        } else if (f.kind === "toggle") {
            out.value = f.value === 1 ? 1 : 0;
        } else {
            out.value = "";
            out.placeholder = formLine(f.placeholder, 60);
        }
        seen[f.id] = true;
        fields.push(out);
    }
    if (!fields.length) return null;
    return {title: formLine(p.title, 160), note: formLine(p.note, 240),
            submitLabel: formLine(p.submitLabel, 32) || "Send", fields: fields};
}
// -> {form, values (EVERY field: draft or default), draft (the valid saved
// subset), sent, dropped}. `form` null means the block cannot be shown.
function formRestore(block, entry) { return formApply(formNormalize(block), entry); }
// The same restore over an already-normalized model (a renderer keeps that
// model per block, so a value edit never rebuilds its field list).
function formApply(form, entry) {
    var out = {form: form, values: {}, draft: {}, sent: false, dropped: 0};
    if (!form) return out;
    var byId = {}, i;
    for (i = 0; i < form.fields.length; ++i) {
        byId[form.fields[i].id] = form.fields[i];
        out.values[form.fields[i].id] = form.fields[i].value;
    }
    if (entry === undefined || entry === null) return out;
    var e = calcPlain(entry);
    if (!e || typeof e !== "object" || Array.isArray(e)) { out.dropped = 1; return out; }
    if (e.v !== undefined) {
        if (e.v === null || typeof e.v !== "object" || Array.isArray(e.v)) out.dropped++;
        else {
            var keys = Object.keys(e.v);
            if (keys.length > 64) out.dropped++;
            for (i = 0; i < keys.length && i < 64; ++i) {
                var id = keys[i], x = e.v[id], field = calcOwn(byId, id) ? byId[id] : null, good = null;
                if (field) {
                    if (field.kind === "number") {
                        if (typeof x === "number" && isFinite(x) && x >= field.min && x <= field.max) good = x;
                    } else if (field.kind === "choice") {
                        if (typeof x === "number" && x === Math.floor(x) && x >= 0 && x < field.options.length) good = x;
                    } else if (field.kind === "toggle") {
                        if (x === 0 || x === 1) good = x;
                    } else {
                        var checked = formParseText(x);
                        if (checked.ok) good = checked.text;
                    }
                }
                if (good === null) { out.dropped++; continue; }
                out.draft[id] = good;
                out.values[id] = good;
            }
        }
    }
    if (e.sent !== undefined && typeof e.sent !== "boolean") out.dropped++;
    out.sent = e.sent === true && out.dropped === 0;
    return out;
}
// What the form means as answers, one per field in order. `unit` is local
// (display only); formWire() strips it.
function formAnswersOf(restored) {
    var list = [];
    if (!restored || !restored.form) return list;
    for (var i = 0; i < restored.form.fields.length; ++i) {
        var f = restored.form.fields[i], raw = restored.values[f.id];
        var a = {id: f.id, label: f.label, kind: f.kind, value: raw, unit: ""};
        if (f.kind === "number") a.unit = f.unit;
        else if (f.kind === "choice") a.valueText = f.options[raw];
        else if (f.kind === "text") a.value = formLine(raw, FORM_TEXT_MAX);
        list.push(a);
    }
    return list;
}
function formAnswers(block, entry) {
    var restored = formRestore(block, entry);
    return restored.form ? formAnswersOf(restored) : null;
}
function formValueText(answer) {
    if (!answer) return "";
    if (answer.kind === "number") return formNumberText(answer.value) + (answer.unit ? " " + answer.unit : "");
    if (answer.kind === "choice") return String(answer.valueText === undefined ? answer.value : answer.valueText);
    if (answer.kind === "toggle") return answer.value === 1 ? "Yes" : "No";
    return String(answer.value) === "" ? "\u2014" : String(answer.value);
}
function formLines(answers) {
    var lines = [];
    for (var i = 0; i < answers.length && i < 6; ++i) lines.push(answers[i].label + ": " + formValueText(answers[i]));
    return lines;
}
// The turn's own record of what was sent (<= 6 rows) and a way back to its form.
function formRows(answers) {
    var rows = [];
    for (var i = 0; i < answers.length && i < 6; ++i)
        rows.push({label: answers[i].label, text: formLine(formValueText(answers[i]), 240)});
    return rows;
}
function formSentText(turn) {
    var rows = turn && typeof turn === "object" ? calcPlain(turn.formAnswers) : null;
    if (!Array.isArray(rows)) return "";
    var lines = [];
    for (var i = 0; i < rows.length && lines.length < 6; ++i) {
        var row = rows[i];
        if (!row || typeof row !== "object" || typeof row.label !== "string" || typeof row.text !== "string") continue;
        var label = formLine(row.label, 80);
        if (label) lines.push(label + ": " + formLine(row.text, 240));
    }
    return lines.join("\n");
}
function formRetryRef(turn) {
    var ref = turn && typeof turn === "object" ? calcPlain(turn.formRef) : null;
    if (!ref || typeof ref !== "object" || Array.isArray(ref)) return null;
    if (!CsvPage.isInt(ref.turnId, 0, CsvPage.MAX_SAFE) || !CsvPage.isInt(ref.blockIndex, 0, 5)) return null;
    return {turnId: ref.turnId, blockIndex: ref.blockIndex};
}
// The `workspaceContext.form` object (exact closed shape; the broker re-checks).
function formWire(restored, turnId, blockIndex) {
    var answers = formAnswersOf(restored).map(function(a) {
        var wire = {id: a.id, label: a.label, kind: a.kind, value: a.value};
        if (a.kind === "choice") wire.valueText = a.valueText;
        if (a.kind === "number" && a.unit) wire.unit = formLine(a.unit, 24);
        return wire;
    });
    return {turnId: turnId, blockIndex: blockIndex, title: restored && restored.form ? formLine(restored.form.title, 160) : "",
            answers: answers};
}
function formWireFits(wire) {
    try { return CsvPage.utf8Bytes(JSON.stringify(wire)) <= FORM_WIRE_MAX; } catch (e) { return false; }
}
// A follow-up (a form, a picked option) may be sent while its turn is the latest
// turn, or while every later turn is a failed/stopped response to that same
// follow-up (`refOf` reads that turn's link back: formRetryRef/choiceRetryRef).
function followUpOpen(turns, turnId, refOf) {
    if (!turns || typeof turns.length !== "number" || typeof turnId !== "number") return false;
    var at = -1, i;
    for (i = turns.length - 1; i >= 0; --i) {
        if (turns[i] && turns[i].id === turnId) { at = i; break; }
    }
    if (at < 0 || turns[at].status !== "done") return false;
    for (i = at + 1; i < turns.length; ++i) {
        var later = turns[i], ref = later ? refOf(later) : null;
        if (!later || (later.status !== "error" && later.status !== "stopped") || !ref || ref.turnId !== turnId) return false;
    }
    return true;
}
function formResendable(turns, turnId) { return followUpOpen(turns, turnId, formRetryRef); }
function formExport(block, entry) {
    var restored = formRestore(block, entry);
    if (!restored.form) {
        var p = calcPlain(block), title = p && typeof p === "object" && typeof p.title === "string" ? formLine(p.title, 160) : "";
        return title ? title + "\n\nThis form can't be shown." : "This form can't be shown.";
    }
    var lines = [];
    if (restored.form.title) lines.push(restored.form.title);
    lines = lines.concat(formLines(formAnswersOf(restored)));
    if (restored.sent) lines.push("Sent");
    if (restored.form.note) lines.push(restored.form.note);
    return lines.join("\n");
}

// ---- Dynamic vocabulary seams: `actions`, `compare` and `timeline` blocks.
// A block is untrusted data of any shape: every helper below is pure and
// returns an empty/null result instead of throwing. Persisted state keys are
// `act:<blockIndex>` {picked} (actions or compare; written by the service when
// an option is picked), `compare:<blockIndex>` and `plan:<blockIndex>` (the
// components' own local state; shapes belong to them). All carry the ORIGINAL
// block index, like every other state key.
var VOCAB_TYPES = ["actions", "compare", "timeline"];
var CHOICE_PROMPT = "Choice made on the previous answer.";
var CHOICE_KINDS = ["actions", "compare"];
var CHOICE_INDEX_MAX = 15;
var CHOICE_TITLE_MAX = 160;
var CHOICE_LABEL_MAX = 40;
// Mirrors the broker's FOCUS_KINDS; the broker's validator is the authority.
var FOCUS_KINDS = ["table", "gallery", "diagram", "steps", "chart", "calc", "compare", "timeline", "actions", "text"];
var FOCUS_INDEX_MAX = 63;
var FOCUS_LABEL_MAX = 80;
var FOCUS_DETAIL_MAX = 240;
var VOCAB_ITEMS_MAX = 64;
var VOCAB_LIST_MAX = 8;     // facts, pros and cons shown per compare option
function vocabText(value, max) {
    if (typeof value === "number" && isFinite(value)) value = String(value);
    return typeof value === "string" ? contextText(value, max, {}, false) : "";
}
function vocabArray(value, max) { return Array.isArray(value) ? value.slice(0, max) : []; }
function vocabObject(value) { return value && typeof value === "object" && !Array.isArray(value) ? value : null; }
// One display/export line per option or item (compare adds fact, '+' and '-'
// lines and a verdict line); the block title is NOT included. `maxLines` > 0
// bounds the result with a final "... N more" line.
function vocabLines(block, maxLines) {
    var lines = [];
    try {
        var plain = vocabObject(calcPlain(block));
        if (!plain) return lines;
        var i, j, entry;
        if (plain.type === "actions") {
            var options = vocabArray(plain.options, CHOICE_INDEX_MAX + 1);
            for (i = 0; i < options.length; ++i) {
                entry = vocabObject(options[i]);
                var label = entry ? vocabText(entry.label, 80) : "", hint = entry ? vocabText(entry.hint, 160) : "";
                if (label) lines.push("\u00b7 " + label + (hint ? " \u2014 " + hint : ""));
            }
        } else if (plain.type === "compare") {
            var cards = vocabArray(plain.options, CHOICE_INDEX_MAX + 1);
            for (i = 0; i < cards.length; ++i) {
                entry = vocabObject(cards[i]);
                var name = entry ? vocabText(entry.name, 80) : "";
                if (!name) continue;
                var summary = vocabText(entry.summary, 160);
                lines.push(name + (entry.recommended === true ? " (recommended)" : "") + (summary ? " \u2014 " + summary : ""));
                var facts = vocabArray(entry.facts, VOCAB_LIST_MAX);
                for (j = 0; j < facts.length; ++j) {
                    var fact = vocabObject(facts[j]), factLabel = fact ? vocabText(fact.label, 60) : "";
                    if (factLabel) lines.push(factLabel + ": " + vocabText(fact.value, 120));
                }
                var pros = vocabArray(entry.pros, VOCAB_LIST_MAX), cons = vocabArray(entry.cons, VOCAB_LIST_MAX);
                for (j = 0; j < pros.length + cons.length; ++j) {
                    var point = vocabText(j < pros.length ? pros[j] : cons[j - pros.length], 160);
                    if (point) lines.push((j < pros.length ? "+ " : "- ") + point);
                }
            }
            var verdict = vocabText(plain.verdict, 240);
            if (verdict) lines.push("Verdict: " + verdict);
        } else if (plain.type === "timeline") {
            var items = vocabArray(plain.items, VOCAB_ITEMS_MAX);
            for (i = 0; i < items.length; ++i) {
                entry = vocabObject(items[i]);
                var step = entry ? vocabText(entry.label, 80) : "";
                if (!step) continue;
                var when = vocabText(entry.when, 40);
                var minutes = typeof entry.minutes === "number" && isFinite(entry.minutes) && entry.minutes > 0
                    ? Math.round(entry.minutes) : 0;
                lines.push((when ? when + " - " : "") + step + (minutes ? " (" + minutes + " min)" : ""));
            }
        }
    } catch (e) { return []; }
    var bound = typeof maxLines === "number" && isFinite(maxLines) ? Math.floor(maxLines) : 0;
    if (bound > 1 && lines.length > bound) {
        var more = lines.length - (bound - 1);
        lines = lines.slice(0, bound - 1).concat(["\u2026 " + more + " more"]);
    }
    return lines;
}
function vocabOptionCount(block) {
    var plain = vocabObject(calcPlain(block));
    return plain ? vocabArray(plain.options, CHOICE_INDEX_MAX + 1).length : 0;
}
function vocabTitle(block) {
    var plain = vocabObject(calcPlain(block));
    return plain ? vocabText(plain.title, CHOICE_TITLE_MAX) : "";
}

// ---- Picked option (a follow-up like the form, but with ONE index).
function choiceRetryRef(turn) {
    var ref = turn && typeof turn === "object" ? calcPlain(turn.choiceRef) : null;
    if (!vocabObject(ref)) return null;
    if (!CsvPage.isInt(ref.turnId, 0, CsvPage.MAX_SAFE) || !CsvPage.isInt(ref.blockIndex, 0, 5)
            || CHOICE_KINDS.indexOf(ref.kind) < 0 || !CsvPage.isInt(ref.index, 0, CHOICE_INDEX_MAX)) return null;
    return {turnId: ref.turnId, blockIndex: ref.blockIndex, kind: ref.kind, index: ref.index};
}
function choiceResendable(turns, turnId) { return followUpOpen(turns, turnId, choiceRetryRef); }
// The visible turn text ("Picked: <label>") a choice turn carries.
function choiceSentText(turn) {
    return turn && typeof turn === "object" ? vocabText(turn.choiceText, 64) : "";
}
// The `workspaceContext.choice` object (exact closed shape; the broker re-checks)
// built from the PERSISTED block only: title and label are control-stripped and
// clamped, an unknown kind/index/unlabelled option gives null.
function choiceWire(block, turnId, blockIndex, kind, index) {
    try {
        if (CHOICE_KINDS.indexOf(kind) < 0 || !CsvPage.isInt(turnId, 0, CsvPage.MAX_SAFE)
                || !CsvPage.isInt(blockIndex, 0, 5) || !CsvPage.isInt(index, 0, CHOICE_INDEX_MAX)) return null;
        var plain = vocabObject(calcPlain(block));
        if (!plain || plain.type !== kind || !Array.isArray(plain.options)) return null;
        var option = vocabObject(plain.options[index]);
        var label = option ? vocabText(kind === "compare" ? option.name : option.label, CHOICE_LABEL_MAX) : "";
        if (!label) return null;
        return {turnId: turnId, blockIndex: blockIndex, kind: kind, index: index,
                title: vocabText(plain.title, CHOICE_TITLE_MAX), label: label};
    } catch (e) { return null; }
}
// The `workspaceContext.focus` object from a person-selected part of an answer,
// or null. Same cleaning/bounds as the choice; `index` -1 means the whole block.
function focusWire(raw) {
    try {
        var plain = vocabObject(calcPlain(raw));
        if (!plain || !CsvPage.isInt(plain.turnId, 0, CsvPage.MAX_SAFE) || !CsvPage.isInt(plain.blockIndex, 0, 5)
                || FOCUS_KINDS.indexOf(plain.kind) < 0 || !CsvPage.isInt(plain.index, -1, FOCUS_INDEX_MAX)) return null;
        var label = vocabText(plain.label, FOCUS_LABEL_MAX);
        if (!label) return null;
        return {turnId: plain.turnId, blockIndex: plain.blockIndex, kind: plain.kind, index: plain.index,
                label: label, detail: vocabText(plain.detail, FOCUS_DETAIL_MAX)};
    } catch (e) { return null; }
}

function textAnswer(turn, uiState, openUiText) {
    if (!turn) return "";
    var parts = [turn.answer || ""];
    if (turn.explanation) parts.push("Explanation: " + turn.explanation);
    (turn.blocks || []).forEach(function(block, blockIndex) {
        if (block && block.type === "openui") {
            if (block.title) parts.push(block.title);
            parts.push(openUiText && openUiText[blockIndex]
                || "Open this interactive tool to include its current labels, inputs and results.");
            return;
        }
        if (block && block.type === "form") {
            // A form: its title, the current answers, "Sent" and the note.
            var formState = uiState && typeof uiState === "object" ? uiState["form:" + blockIndex] : null;
            try { parts.push(formExport(block, formState)) } catch (e) { parts.push("This form can't be shown.") }
            return;
        }
        if (block && VOCAB_TYPES.indexOf(block.type) >= 0) {
            // Title, then one line per option/item (see vocabLines).
            var vocabHead = vocabTitle(block), vocabBody = vocabLines(block, 0);
            if (vocabHead) parts.push(vocabHead);
            if (vocabBody.length) parts.push(vocabBody.join("\n"));
            return;
        }
        if (block && block.type === "calc") {
            // Typed computation: current inputs and results, tables summarised.
            var calcState = uiState && typeof uiState === "object" ? uiState["calc:" + blockIndex] : null;
            try { parts.push(calcExport(block, calcState)) } catch (e) { parts.push("This calculation can't be shown.") }
            return;
        }
        if (block.title) parts.push(block.title);
        if (block.text) parts.push(block.type === "richtext" ? plainRichText(block.text) : block.text);
        if (block.question) parts.push(block.question);
        if (block.prompt) parts.push(block.prompt);
        if (block.steps) parts.push(block.steps.map(function(step, index) {
            return (index + 1) + ". " + step.label + (step.detail ? " — " + step.detail : "");
        }).join("\n"));
        if (block.options) parts.push(block.options.map(function(option) {
            return (option.correct ? "✓ " : "· ") + option.label + (option.feedback ? " — " + option.feedback : "");
        }).join("\n"));
        if (block.choices) parts.push(block.choices.map(function(choice) { return "· " + choice; }).join("\n"));
        if (block.parts) parts.push(block.parts.filter(function(part) {
            return part && (part.label || part.detail);
        }).map(function(part) {
            return (part.label || part.shape) + (part.detail ? " — " + part.detail : "");
        }).join("\n"));
        if (block.control) {
            var control = block.control;
            var sliderValue = Number(control.value);
            var step = Number(control.step) || 1;
            var display;
            if (control.labels && control.labels.length > 0) {
                var labelIndex = Math.round((sliderValue - Number(control.min)) / step);
                display = control.labels[labelIndex] || String(sliderValue);
            } else {
                display = String(sliderValue) + (control.unit ? " " + control.unit : "");
            }
            parts.push(String(control.label || "") + ": " + display);
            (block.readouts || []).forEach(function(readout) {
                var computed = Formula.evaluate(Formula.compile(String(readout.expression || "")), sliderValue);
                parts.push(String(readout.label || "") + ": " + Formula.formatValue(computed, String(readout.unit || "")));
            });
            if (block.note) parts.push(block.note);
        }
        if (block.reveal) parts.push(block.reveal);
        if (block.explanation) parts.push(block.explanation);
        if (block.items) parts.push(block.items.map(function(item) {
            return typeof item === "string" ? "• " + item : item.label + " · " + item.url;
        }).join("\n"));
        if (block.columns) parts.push(block.columns.join(" | "));
        if (block.rows) parts.push(block.rows.map(function(row) { return row.join(" | "); }).join("\n"));
        if (block.value !== undefined) parts.push(String(block.value));
        if (block.detail) parts.push(block.detail);
        if (block.type === "image") {
            parts.push(block.query || "");
            if (block.attribution) parts.push(block.attribution);
        }
        if (block.type === "gallery" && block.items) {
            block.items.forEach(function(item) {
                if (item.caption) parts.push(item.caption);
                if (item.attribution) parts.push(item.attribution);
            });
        }
        if (block.type === "market") {
            parts.push((block.symbol || "") + " · " + (block.range || "") + " · " + (block.unit || ""));
            if (block.points) parts.push(block.points.map(function(point) { return point.label + " · " + point.value; }).join("\n"));
        }
        if (block.type === "chart" && block.labels && block.values) {
            parts.push(block.labels.map(function(label, index) { return label + " · " + block.values[index]; }).join("\n"));
            if (block.unit) parts.push(block.unit);
        }
        if (block.asOf) parts.push("As of " + block.asOf);
        if (block.sourceUrl || block.source) parts.push(block.sourceUrl || block.source);
        if (block.error) parts.push(block.error);
    });
    return parts.filter(function(part) { return !!part; }).join("\n\n");
}
function sourceCommand(url) {
    if (typeof url !== "string" || url.length > 2048 || /[\\\s\x00-\x1f\x7f]/.test(url)) return [];
    var match = /^https:\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(?:[/?#].*)?$/.exec(url);
    if (!match) return [];
    if (match[2] && (Number(match[2]) < 1 || Number(match[2]) > 65535)) return [];
    var host = match[1].toLowerCase();
    if (host.indexOf(".") < 0 || /(?:^|\.)(?:localhost|local|internal|lan|home|test|invalid)$/.test(host)
            || /^[0-9.]+$/.test(host) || host.indexOf("..") >= 0 || /(^[.-]|[.-]$)/.test(host)) return [];
    return ["omarchy-launch-browser", url];
}
function plainRichText(text) {
    return String(text).replace(/<br\s*\/?\s*>|<\/(?:p|li|h[123]|pre)>/gi, "\n")
        .replace(/<[^>]*>/g, "")
        .replace(/&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-f]+);/gi, function(entity) {
            var named = {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'"};
            var lower = entity.toLowerCase();
            if (named[lower] !== undefined) return named[lower];
            var hex = lower.indexOf("&#x") === 0;
            var code = parseInt(lower.slice(hex ? 3 : 2, -1), hex ? 16 : 10);
            return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff)
                ? String.fromCodePoint(code) : "�";
        }).trim();
}
function handoffCommand(agent, sessionId, codexHome, stateRoot) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(String(sessionId || ""))) return [];
    if (agent === "hermes") return ["omarchy-launch-terminal", "hermes", "--resume", sessionId, "--no-restore-cwd"];
    if (agent !== "codex") return [];
    if (typeof codexHome !== "string" || codexHome.indexOf(stateRoot + "/") !== 0
            || codexHome.indexOf("/../") >= 0 || codexHome.indexOf("\0") >= 0) return [];
    return ["omarchy-launch-terminal", "env", "CODEX_HOME=" + codexHome,
            "codex", "--sandbox", "read-only", "resume", sessionId];
}

// Exploration trail: a short, honest record of what the user actually did
// with an answer, derived only from persisted interaction state. Labels, in
// order: Checked, Predicted, Stepped through, Scrubbed (slider/diagram),
// Adjusted (a `calc:<block>` input whose effective value differs from the authored
// default; restoring the default removes it), Edited data (any effective table
// edit: changed cells, added or removed rows), Scenarios (>= 1 saved scenario),
// all three judged by the same CalcView build/restore the renderer uses, Answered
// (a `form:<block>` entry that restores cleanly with `sent: true`), Chose (an
// `act:<block>` pick of a real option of an actions/compare block), Sorted,
// Filtered, "N examples replaced", Depth added. Unknown keys never invent an entry.
function trailSummary(turn, uiState) {
    if (!turn || !uiState || typeof uiState !== "object") return "";
    var checks = 0, predicts = 0, steps = 0, scrubs = 0, replaced = 0, sorted = 0, filtered = 0, adjusted = 0, editedData = 0, scenarios = 0, answered = 0, chose = 0;
    Object.keys(uiState).forEach(function(key) {
        var parts = String(key).split(":");
        var value = uiState[key];
        if (parts[0] === "check") {
            if (value && (value.checked || (Array.isArray(value.selected) && value.selected.length > 0))) checks++;
        } else if (parts[0] === "predict") {
            // A prediction stores the committed choice index (a number);
            // an uncommitted prompt has no entry at all.
            if (typeof value === "number" && value >= 0) predicts++;
        } else if (parts[0] === "step") {
            if (typeof value === "number" && value > 0) steps++;
        } else if (parts[0] === "slider" || parts[0] === "diagram") {
            scrubs++;
        } else if (parts[0] === "table") {
            if (value && typeof value === "object") {
                if (typeof value.sort === "number" && value.sort >= 0) sorted++;
                if (typeof value.filter === "string" && value.filter.length > 0) filtered++;
            }
        } else if (parts[0] === "gallery") {
            if (typeof value === "number" && value > 0) replaced++;
        } else if (parts[0] === "form") {
            // Only a real form block at that index whose saved entry restores
            // cleanly AND was sent counts.
            var formIndex = parts.length === 2 && /^[0-9]{1,4}$/.test(parts[1]) ? Number(parts[1]) : -1;
            var formList = turn.blocks && typeof turn.blocks.length === "number" ? turn.blocks : null;
            var formBlock = formIndex >= 0 && formList ? formList[formIndex] : null;
            if (formBlock && formBlock.type === "form" && value && typeof value === "object") {
                try { if (formRestore(formBlock, value).sent) answered++; } catch (e) { /* hostile: no label */ }
            }
        } else if (parts[0] === "act") {
            // Only a real actions/compare block at that index whose stored pick
            // is one of its options counts.
            var actIndex = parts.length === 2 && /^[0-9]{1,4}$/.test(parts[1]) ? Number(parts[1]) : -1;
            var actList = turn.blocks && typeof turn.blocks.length === "number" ? turn.blocks : null;
            var actBlock = actIndex >= 0 && actList ? actList[actIndex] : null;
            var actPick = value && typeof value === "object" ? value.picked : undefined;
            if (actBlock && CHOICE_KINDS.indexOf(actBlock.type) >= 0 && CsvPage.isInt(actPick, 0, CHOICE_INDEX_MAX)
                    && actPick < vocabOptionCount(actBlock)) chose++;
        } else if (parts[0] === "calc") {
            // Only an input of the real calc block at that index counts, and
            // only while its stored value still differs from the authored default.
            var blockIndex = parts.length === 2 && /^[0-9]{1,4}$/.test(parts[1]) ? Number(parts[1]) : -1;
            var list = turn.blocks && typeof turn.blocks.length === "number" ? turn.blocks : null;
            var block = blockIndex >= 0 && list ? list[blockIndex] : null;
            if (block && block.type === "calc" && value && typeof value === "object") {
                try {
                    // Same build + restore as the renderer (no evaluation needed).
                    var plan = CalcView.build(block, value), saved = plan ? CalcView.restore(plan, value) : null;
                    if (plan && saved) {
                        if (plan.inputs.some(function(input) { return saved.values[input.id] !== input.value; })) adjusted++;
                        if (calcEditedCount(plan.edited) > 0) editedData++;
                        if (saved.scenarios.length > 0) scenarios++;
                    }
                } catch (e) { /* hostile block: no label */ }
            }
        }
    });
    var bits = [];
    if (checks) bits.push("Checked");
    if (predicts) bits.push("Predicted");
    if (steps) bits.push("Stepped through");
    if (scrubs) bits.push("Scrubbed");
    if (adjusted) bits.push("Adjusted");
    if (editedData) bits.push("Edited data");
    if (scenarios) bits.push("Scenarios");
    if (answered) bits.push("Answered");
    if (chose) bits.push("Chose");
    if (sorted) bits.push("Sorted");
    if (filtered) bits.push("Filtered");
    if (replaced) bits.push(replaced === 1 ? "1 example replaced" : replaced + " examples replaced");
    if (turn.explanation) bits.push("Depth added");
    return bits.join(" · ");
}

// ---- "Ask about this" parts (focus seam). One descriptor per addressable part
// of a table / gallery / diagram / steps / chart block:
// {kind, index, label, detail} is exactly what AiService.setFocus takes (the
// service re-validates it against the latest finished answer). A block is
// untrusted data of any shape: every helper is pure and bounded, and a part
// without a usable label is null (no control is offered) rather than a throw.
// Row/item/step/node `index` is the position in the block's OWN list (the
// authored row order, never the sorted/filtered view). A chart point past
// FOCUS_INDEX_MAX is addressed as index -1 (its label and detail still name
// the point), so the broker's -1..63 bound always holds.
var ASK_KINDS = ["table", "gallery", "diagram", "steps", "chart"];
var ASK_PARTS_MAX = 120;      // chart observations; the other kinds have fewer
var ASK_CELL_MAX = 120;
var ASK_HEADER_MAX = 40;
function askDescriptor(kind, index, label, detail) {
    var cleanLabel = vocabText(label, FOCUS_LABEL_MAX);
    if (!cleanLabel) return null;
    var position = CsvPage.isInt(index, 0, FOCUS_INDEX_MAX) ? index : -1;
    return {kind: kind, index: position, label: cleanLabel, detail: vocabText(detail, FOCUS_DETAIL_MAX)};
}
// A table row: label = the first non-empty cell, detail = "Header: value; ...".
function askTableRow(plain, row) {
    var columns = vocabArray(plain.columns, 12), cells = vocabArray(row, 12);
    var label = "", pairs = [];
    for (var i = 0; i < cells.length; ++i) {
        var value = vocabText(cells[i], ASK_CELL_MAX);
        if (!value) continue;
        if (!label) label = value;
        var header = i < columns.length ? vocabText(columns[i], ASK_HEADER_MAX) : "";
        pairs.push((header || "Column " + (i + 1)) + ": " + value);
    }
    return {label: label, detail: pairs.join("; ")};
}
// Descriptors aligned with the block's parts (null where a part has no label or
// cannot be addressed); [] for any other block type or a hostile shape.
function askParts(block) {
    var result = [];
    try {
        var plain = vocabObject(calcPlain(block));
        if (!plain || ASK_KINDS.indexOf(plain.type) < 0) return result;
        var i, entry, item, list, title, count;
        if (plain.type === "table") {
            list = vocabArray(plain.rows, FOCUS_INDEX_MAX + 1);
            for (i = 0; i < list.length; ++i) {
                item = askTableRow(plain, list[i]);
                result.push(askDescriptor("table", i, item.label, item.detail));
            }
        } else if (plain.type === "gallery") {
            list = vocabArray(plain.items, FOCUS_INDEX_MAX + 1);
            for (i = 0; i < list.length; ++i) {
                entry = vocabObject(list[i]);
                var caption = entry ? vocabText(entry.caption, FOCUS_LABEL_MAX) : "";
                var query = entry ? vocabText(entry.query, FOCUS_LABEL_MAX) : "";
                var shows = caption && query && query !== caption ? ". Image of: " + query : "";
                result.push(askDescriptor("gallery", i, caption || query,
                    "Example " + (i + 1) + " of " + list.length + shows));
            }
        } else if (plain.type === "steps") {
            list = vocabArray(plain.steps, FOCUS_INDEX_MAX + 1);
            for (i = 0; i < list.length; ++i) {
                entry = vocabObject(list[i]);
                var note = entry ? vocabText(entry.detail, FOCUS_DETAIL_MAX) : "";
                result.push(askDescriptor("steps", i, entry ? entry.label : "",
                    "Step " + (i + 1) + " of " + list.length + (note ? ". " + note : "")));
            }
        } else if (plain.type === "diagram") {
            list = vocabArray(plain.parts, FOCUS_INDEX_MAX + 1);
            for (i = 0; i < list.length; ++i) {
                entry = vocabObject(list[i]);
                // A part without a detail is not selectable in the renderer either.
                var about = entry ? vocabText(entry.detail, FOCUS_DETAIL_MAX) : "";
                var name = entry ? vocabText(entry.label, FOCUS_LABEL_MAX) || vocabText(entry.shape, 16) : "";
                result.push(about ? askDescriptor("diagram", i, name, about) : null);
            }
        } else if (plain.type === "chart") {
            // Same normalisation as AiChart.normalizedPoints (finite values only).
            var labels = vocabArray(plain.labels, ASK_PARTS_MAX), values = vocabArray(plain.values, ASK_PARTS_MAX);
            var unit = vocabText(plain.unit, 32), chartTitle = vocabText(plain.title, 80) || "Chart";
            var points = [];
            for (i = 0; i < values.length; ++i) {
                if (typeof values[i] !== "number" || !isFinite(values[i])) continue;
                points.push({label: vocabText(labels[i], FOCUS_LABEL_MAX) || String(i + 1), value: values[i]});
            }
            for (i = 0; i < points.length; ++i) {
                var shown = String(Number(points[i].value.toPrecision(10))) + (unit ? " " + unit : "");
                result.push(askDescriptor("chart", i, points[i].label, chartTitle + ": " + points[i].label + " = "
                    + shown + ". Observation " + (i + 1) + " of " + points.length));
            }
        }
    } catch (e) { return []; }
    return result;
}
