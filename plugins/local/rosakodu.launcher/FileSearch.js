.pragma library

function mode(query) {
    return /^f:/i.test(String(query || ""));
}

function terms(query) {
    return mode(query) ? String(query).slice(2).trim() : "";
}

function validPath(path) {
    return typeof path === "string" && path.charAt(0) === "/" && path.indexOf("\0") < 0;
}

function parseRows(raw) {
    var values = JSON.parse(raw);
    if (!Array.isArray(values)) throw new Error("Invalid file search response");
    return values.filter(function(row) {
        return row && row.kind === "file" && validPath(row.path)
            && typeof row.title === "string" && typeof row.parent === "string";
    }).slice(0, 100);
}

function command(row, reveal) {
    if (!row || row.kind !== "file" || !validPath(row.path)) return [];
    var target = reveal ? row.path.slice(0, row.path.lastIndexOf("/")) || "/" : row.path;
    return ["uwsm-app", "--", "xdg-open", target];
}

function displayParent(parent, home) {
    return parent === home ? "~" : parent.indexOf(home + "/") === 0
        ? "~" + parent.slice(home.length) : parent;
}
