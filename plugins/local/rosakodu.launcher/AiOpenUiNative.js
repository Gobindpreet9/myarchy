.pragma library

// Presentation-only helpers. Programs, expressions, state and action plans never
// enter this module. Spacing follows SatinGlass's 4/8/12/16 native rhythm.
function number(value, fallback) {
    return typeof value === "number" && isFinite(value) ? value : fallback;
}
function text(value) { return value === null || value === undefined ? "" : String(value); }
// Keep slider values human-readable: binary floating noise must not become
// 0.30000000000000004 in a label, thousands get grouping, and currency units
// belong before the number.
function numberText(value) {
    if (typeof value !== "number" || !isFinite(value)) return "";
    if (value === 0) return "0";
    var clean = Number(value.toFixed(6));
    if (Math.abs(clean) >= 1e15 || Math.abs(clean) < 1e-6) return clean.toExponential(4);
    var source = String(clean), parts = source.split("."), signed = parts[0];
    var sign = signed.charAt(0) === "-" ? "-" : "";
    var digits = sign ? signed.slice(1) : signed;
    digits = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return sign + digits + (parts.length > 1 ? "." + parts[1] : "");
}
function quantity(value, unit) {
    var number = numberText(value), suffix = text(unit);
    return ["$", "€", "£", "¥", "₹", "₽", "₩"].indexOf(suffix) >= 0
        ? suffix + number : number + suffix;
}
function space(value, fallback) { return Math.max(0, number(value, fallback / 4)) * 4; }
function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity * color.a); }
function literalColor(value) {
    if (value && typeof value === "object" && typeof value.r === "number" && typeof value.g === "number"
            && typeof value.b === "number" && typeof value.a === "number") return value;
    if (typeof value !== "string") return null;
    if (/^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(value)) return value;
    return ["transparent", "black", "white", "red", "green", "blue", "yellow", "orange", "purple",
        "pink", "cyan", "magenta", "gray", "grey"].indexOf(value.toLowerCase()) >= 0 ? value : null;
}
function color(value, theme, fallback) {
    var name = text(value).trim();
    if (name === "none" || name === "transparent") return "transparent";
    if (name === "foreground" || name === "ink" || name === "currentColor") return theme.foreground;
    if (name === "accent" || name === "primary" || name === "info") return theme.accent;
    if (name === "background" || name === "canvas") return theme.background;
    if (name === "muted" || name === "faint") return alpha(theme.foreground, 0.80);
    if (name === "surface" || name === "surface-strong" || name === "neutral") return alpha(theme.foreground, 0.06);
    if (name === "border") return alpha(theme.foreground, 0.14);
    var paletteColor = theme.palette ? literalColor(theme.palette[name]) : null;
    if (paletteColor !== null) return paletteColor;
    var known = { success: "#70bd91", warning: "#e0b963", danger: "#e98b86", purple: "#b5a1df", pink: "#db97bf",
        chart1: theme.accent, chart2: "#70bd91", chart3: "#e0b963", chart4: "#b5a1df", chart5: "#db97bf", chart6: "#e98b86" };
    if (known[name]) return known[name];
    var literal = literalColor(name);
    return literal !== null ? literal : fallback;
}
function radius(value, fallback) {
    var named = { sm: 6, md: 9, lg: 12, xl: 20, full: 999 };
    return typeof value === "string" && named[value] !== undefined ? named[value] : Math.max(0, number(value, fallback));
}
function length(value, available, fallback) {
    if (typeof value === "number") return Math.max(0, number(value, fallback));
    if (typeof value !== "string") return fallback;
    var m = /^([0-9]+(?:\.[0-9]+)?)(px|%)?$/.exec(value.trim());
    return m ? Number(m[1]) * (m[2] === "%" ? available / 100 : 1) : fallback;
}
function options(value) {
    var result = [];
    if (!value || typeof value.length !== "number") return result;
    for (var i = 0; i < value.length; ++i) {
        var entry = value[i];
        if (Array.isArray(entry)) result = result.concat(options(entry));
        else if (typeof entry === "string") result.push({ value: entry, label: entry, description: "" });
        else if (entry && typeof entry.value === "string") result.push({ value: entry.value, label: text(entry.label), description: text(entry.description) });
    }
    return result;
}
// ListModel identity, rather than a JS-array Repeater, is what retains focus,
// caret, open controls and delegate instances across state acknowledgements.
function reconcile(model, nodes) {
    nodes = nodes || [];
    for (var i = 0; i < nodes.length; ++i) {
        var node = nodes[i];
        var id = text(node.id) + ":" + text(node.kind) + ":" + text(node.props && node.props._openuiHandle), encoded = JSON.stringify(node), found = -1;
        for (var j = i; j < model.count; ++j) {
            if (model.get(j).nodeId === id) { found = j; break; }
        }
        if (found < 0) model.insert(i, { nodeId: id, nodeSpec: encoded });
        else {
            if (found !== i) model.move(found, i, 1);
            if (model.get(i).nodeSpec !== encoded) model.setProperty(i, "nodeSpec", encoded);
        }
    }
    if (model.count > nodes.length) model.remove(nodes.length, model.count - nodes.length);
}
function viewBox(value) {
    var values = text(value).trim().split(/[\s,]+/).map(Number);
    return values.length === 4 && values.every(isFinite) && values[2] > 0 && values[3] > 0 ? values : [0, 0, 100, 100];
}
// A bounded SVG attribute grammar, NOT OpenUI/program parsing. Unknown syntax
// is ignored. No URLs, scripts, CSS, resources or arbitrary evaluation.
function transform(value) {
    var source = text(value), out = [1, 0, 0, 1, 0, 0];
    if (!source || source.length > 500) return matrix(out);
    var re = /\s*([A-Za-z]+)\(([^()]*)\)\s*/g, match, end = 0;
    while ((match = re.exec(source)) !== null) {
        if (match.index !== end) return matrix([1, 0, 0, 1, 0, 0]);
        end = re.lastIndex;
        var a = match[2].trim().split(/[\s,]+/).map(Number), t = [1, 0, 0, 1, 0, 0];
        if (!a.every(isFinite)) return matrix([1, 0, 0, 1, 0, 0]);
        var name = match[1], angle = a[0] * Math.PI / 180;
        if (name === "translate" && (a.length === 1 || a.length === 2)) t = [1, 0, 0, 1, a[0], a.length === 2 ? a[1] : 0];
        else if (name === "scale" && (a.length === 1 || a.length === 2)) t = [a[0], 0, 0, a.length === 2 ? a[1] : a[0], 0, 0];
        else if (name === "rotate" && (a.length === 1 || a.length === 3)) {
            var c = Math.cos(angle), s = Math.sin(angle), x = a.length === 3 ? a[1] : 0, y = a.length === 3 ? a[2] : 0;
            t = [c, s, -s, c, x - c * x + s * y, y - s * x - c * y];
        } else if (name === "skewX" && a.length === 1) t[2] = Math.tan(angle);
        else if (name === "skewY" && a.length === 1) t[1] = Math.tan(angle);
        else if (name === "matrix" && a.length === 6) t = a;
        else return matrix([1, 0, 0, 1, 0, 0]);
        out = multiply(out, t);
    }
    return matrix(end === source.length ? out : [1, 0, 0, 1, 0, 0]);
}
function multiply(a, b) {
    return [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1], a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
        a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]];
}
function matrix(a) { return Qt.matrix4x4(a[0], a[2], 0, a[4], a[1], a[3], 0, a[5], 0, 0, 1, 0, 0, 0, 0, 1); }
function shapePath(kind, p) {
    var n = function(key) { return number(p[key], 0); };
    if (kind === "Path") return typeof p.d === "string" && p.d.length < 20000 && /^[MmLlHhVvCcSsQqTtAaZz\d\s,.eE+-]*$/.test(p.d) ? p.d : "";
    if (kind === "Polyline" || kind === "Polygon") {
        if (typeof p.points !== "string" || p.points.length >= 20000 || !/^[\d\s,.eE+-]*$/.test(p.points)) return "";
        var points = p.points.trim().split(/[\s,]+/).map(Number);
        if (points.length < 4 || points.length % 2 || !points.every(isFinite)) return "";
        return "M " + points[0] + " " + points[1] + " L " + points.slice(2).join(" ") + (kind === "Polygon" ? " Z" : "");
    }
    if (kind === "Line") return "M " + n("x1") + " " + n("y1") + " L " + n("x2") + " " + n("y2");
    if (kind === "Circle" || kind === "Ellipse") {
        var cx = n("cx"), cy = n("cy"), rx = Math.max(0, n(kind === "Circle" ? "r" : "rx")), ry = Math.max(0, n(kind === "Circle" ? "r" : "ry"));
        if (!rx || !ry) return "";
        return "M " + (cx-rx) + " " + cy + " a " + rx + " " + ry + " 0 1 0 " + (2*rx) + " 0 a " + rx + " " + ry + " 0 1 0 " + (-2*rx) + " 0 Z";
    }
    if (kind === "Rect") {
        var x = n("x"), y = n("y"), w = Math.max(0, n("width")), h = Math.max(0, n("height")), r = Math.max(0, Math.min(n("rx"), w/2, h/2));
        return "M " + (x+r) + " " + y + " H " + (x+w-r) + " Q " + (x+w) + " " + y + " " + (x+w) + " " + (y+r)
            + " V " + (y+h-r) + " Q " + (x+w) + " " + (y+h) + " " + (x+w-r) + " " + (y+h)
            + " H " + (x+r) + " Q " + x + " " + (y+h) + " " + x + " " + (y+h-r)
            + " V " + (y+r) + " Q " + x + " " + y + " " + (x+r) + " " + y + " Z";
    }
    return "";
}
function filled(kind, p) { return ["Circle", "Ellipse", "Rect", "Polygon"].indexOf(kind) >= 0 || kind === "Path" && p.fill !== undefined; }
function fill(kind, p, theme) { return p.fill !== undefined ? color(p.fill, theme, "transparent") : filled(kind, p) && p.stroke === undefined ? theme.foreground : "transparent"; }
function stroke(kind, p, theme) { return p.stroke !== undefined ? color(p.stroke, theme, "transparent") : filled(kind, p) ? "transparent" : theme.foreground; }
// Small local glyph vocabulary. Names are never treated as image paths, URLs,
// font markup or QML source. Unknown names are omitted rather than leaking a
// raw "[lucide-name]" into the interface; Accessible.name keeps the meaning.
function glyph(name) {
    var glyphs = { plus: "+", minus: "−", check: "✓", x: "×", "chevron-left": "‹", "chevron-right": "›",
        "chevron-up": "⌃", "chevron-down": "⌄", "chevrons-left": "«", "chevrons-right": "»",
        "arrow-left": "←", "arrow-right": "→", "arrow-up": "↑", "arrow-down": "↓", "arrow-down-up": "⇅",
        info: "ⓘ", "circle-help": "?", "help-circle": "?", "rotate-ccw": "↶",
        "rotate-cw": "↷", refresh: "↻", play: "▷", pause: "Ⅱ", clock: "◷", timer: "◷",
        calendar: "▦", "calendar-days": "▦", "calendar-clock": "▦", sun: "☼",
        heart: "♡", star: "☆", sparkles: "✦", settings: "⚙", zap: "⚡", bolt: "⚡", copy: "⧉",
        check_circle: "✓", "circle-check": "✓", "circle-check-big": "✓", "check-circle-2": "✓", circle: "○",
        map: "⌖", "map-pin": "⌖", route: "↝", target: "◎", flag: "⚑",
        activity: "∿", gauge: "◔", wallet: "▤", "wallet-minimal": "▤", "piggy-bank": "◎",
        banknote: "▤", "credit-card": "▭", receipt: "▤", calculator: "▦",
        "circle-dollar-sign": "$", dollar: "$", percent: "%",
        "trending-up": "↗", "trending-down": "↘",
        search: "⌕", trash: "⌫", download: "⇩", upload: "⇧", external_link: "↗",
        "external-link": "↗", lock: "⌑", home: "⌂", menu: "≡" };
    return glyphs[text(name).trim().toLowerCase()] || "";
}
