.pragma library

// Decides how the launcher surface should move when it opens.
//
//   source "dock"     — a dock Apps click: emerge from that glyph. The dock
//                       sends the glyph position as fractions of the output
//                       (layer surfaces have no reliable global coordinates).
//   source "keyboard" — bare Super: a deliberate spotlight descent from the
//                       upper focus line, independent of any dock geometry.
//
// intent "toggle" — the opener is a pointer toggle: a second dock click
//                   should animate the launcher closed instead of re-opening.
function openContext(payloadJson) {
    var fallback = {
        intent: "",
        source: "keyboard",
        hasOrigin: false,
        originFX: 0.5,
        originFY: 0.5,
        edge: ""
    }
    var payload = null
    try { payload = JSON.parse(String(payloadJson || "{}")) }
    catch (e) { return fallback }
    if (!payload || typeof payload !== "object") return fallback

    var context = {
        intent: payload.intent === "toggle" ? "toggle" : "",
        source: "keyboard",
        hasOrigin: false,
        originFX: 0.5,
        originFY: 0.5,
        edge: ""
    }
    if (payload.source !== "dock") return context

    var fx = Number(payload.originFX)
    var fy = Number(payload.originFY)
    if (!isFinite(fx) || !isFinite(fy) || fx < 0 || fx > 1 || fy < 0 || fy > 1) return context

    context.source = "dock"
    context.hasOrigin = true
    context.originFX = fx
    context.originFY = fy
    context.edge = ["top", "bottom", "left", "right"].indexOf(String(payload.edge || "")) >= 0
        ? String(payload.edge) : ""
    return context
}
