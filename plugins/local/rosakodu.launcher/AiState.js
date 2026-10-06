.pragma library

.import "AiFormula.js" as Formula

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
    return ({codex: "Codex", hermes: "Hermes"})[agent] || String(agent || "No default agent");
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
function answerTitle(turn) {
    if (!turn) return "";
    var visual = (turn.blocks || []).find(function(block) {
        return (block.type === "image" || block.type === "market" || block.type === "chart") && block.title;
    });
    var text = String(visual ? visual.title : turn.prompt || "Answer").trim();
    if (text.length > 96) text = text.slice(0, 93).trim() + "…";
    return text ? text[0].toUpperCase() + text.slice(1) : "Answer";
}
function supported(agent) { return agent === "codex" || agent === "hermes"; }
function newTurn(prompt, attachment) {
    return {prompt: prompt, attachment: attachment || "", answer: "", blocks: [], suggestions: [],
            status: "working", error: "", warning: ""};
}
function updateTurn(turn, event) {
    var next = Object.assign({}, turn);
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
    }
    if (event.type === "error") {
        next.error = String(event.message || "Unable to get an answer.").slice(0, 700);
        next.status = "error";
    }
    if (event.type === "stopped") {
        next.status = "stopped";
        next.blocks = (next.blocks || []).map(function(block) {
            return block.loading ? Object.assign({}, block, {loading: false, error: "Visual loading stopped."}) : block;
        });
    }
    return next;
}
function textAnswer(turn) {
    if (!turn) return "";
    var parts = [turn.answer || ""];
    if (turn.explanation) parts.push("Explanation: " + turn.explanation);
    (turn.blocks || []).forEach(function(block) {
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
// with an answer, derived only from persisted interaction state.
function trailSummary(turn, uiState) {
    if (!turn || !uiState || typeof uiState !== "object") return "";
    var checks = 0, predicts = 0, steps = 0, scrubs = 0, replaced = 0, sorted = 0, filtered = 0;
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
        }
    });
    var bits = [];
    if (checks) bits.push("Checked");
    if (predicts) bits.push("Predicted");
    if (steps) bits.push("Stepped through");
    if (scrubs) bits.push("Scrubbed");
    if (sorted) bits.push("Sorted");
    if (filtered) bits.push("Filtered");
    if (replaced) bits.push(replaced === 1 ? "1 example replaced" : replaced + " examples replaced");
    if (turn.explanation) bits.push("Depth added");
    return bits.join(" · ");
}
