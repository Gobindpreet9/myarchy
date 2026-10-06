// SatinGlass.js — shared design-token system for the Omarchy Dock + Launcher.
//
// One source of truth for radii, spacing, typography, elevation, keylines,
// state sizing and motion so the shelf, tooltip, folder card, window chooser,
// actions menu, settings and the companion launcher read as one material family.
//
// Pure numeric tokens only. Colours are NOT defined here — they always come
// from the Omarchy theme tokens (qs.Commons Color.*) composed with Util.alpha,
// so every theme stays correct. This module never hardcodes a palette.
//
// Direction: opaque matte surfaces (no compositor blur needed):
// a matte gradient body, a 1px hairline keyline, a restrained top specular
// highlight and a soft drop shadow. Launcher translucency is its own optional
// alpha-only control, independent of the dock's background translucency.

.pragma library

// --- Radii (px) ---
var radius = {
    shelf: 22,     // the floating dock shelf
    card: 20,      // folder card, window chooser, launcher surface
    field: 12,     // launcher search field
    row: 12,       // launcher result rows
    icon: 13,      // app icon squircle
    iconSm: 11,    // small icon in result rows
    tip: 9,        // tooltip
    badge: 9,      // status pill / notification badge
    chip: 6        // keybind chips, tags
};

// --- Spacing (px) — 4px base grid ---
var space = {
    base: 4,
    slot: 64,        // app slot pitch (hit target stays stationary & generous)
    icon: 52,        // icon plate — optically normalised box
    gutter: 12,      // shelf horizontal padding
    shelfPad: 12,
    sep: 10,         // separator inset
    section: 16,     // launcher section gap
    row: 11,         // launcher result row padding-y
    tip: 8           // tooltip gap above icon
};

// --- Typography (px) ---
var type = {
    search: 22,
    result: 16,
    name: 15,
    meta: 13,
    tip: 13,
    label: 11,
    header: 11,     // uppercase, letter-spaced section headers
    small: 12,      // AI surface scale (added for the answer/composer surfaces)
    body: 14,
    subtitle: 17,
    prompt: 20,
    display: 29
};

// --- Elevation (drop shadow: offsetY, blur, spread, alpha) ---
var elev = {
    shelf: { y: 18, blur: 44, spread: 0, alpha: 0.46 },
    card:  { y: 34, blur: 80, spread: 0, alpha: 0.55 },
    tip:   { y: 8,  blur: 20, spread: 0, alpha: 0.40 },
    icon:  { y: 2,  blur: 5,  spread: 0, alpha: 0.35 }
};

// --- Keyline (specular top highlight + hairline border, alpha of fg) ---
var keyline = {
    hair: 0.14,       // outer hairline border
    specTop: 0.12,    // top specular highlight
    specBottom: 0.22, // bottom inner shade
    inner: 0.08       // faint inner ring
};

// --- Motion (ms + easing names resolved in QML) ---
var motion = {
    hover: 160,
    state: 140,
    shelf: 220,
    reveal: 180,       // slide-in
    dismiss: 300,      // slide-out (InCubic)
    click: 150,
    tipDelay: 300,
    chooserDelay: 300,
    // Easing names: OutCubic / OutQuint / InCubic
    ease: "OutCubic",
    easeOut: "OutQuint",
    easeIn: "InCubic"
};

// --- Interaction states (magnitudes, not animations) ---
var state = {
    hoverMax: 1.08,    // cursor-proximity growth cap (hit target never moves)
    press: 0.93,
    drag: 1.16,
    edit: 0.82,
    proximityLift: 4   // max optical lift toward the cursor (px)
};

// --- Status rail: ONE place for running/active/minimized/urgent/multi-window ---
var rail = {
    height: 3,
    seg: 6,            // default segment width
    segRun: 14,        // running
    segActive: 16,     // active / focused window
    segMin: 6,         // minimized (hollow)
    gap: 3,
    radius: 2
};

// --- Window chooser / preview strip ---
var chooser = {
    previewW: 180,
    previewH: 144,
    gap: 12,
    maxVisible: 4,
    edgeMargin: 8
};

// --- Launcher surface ---
var launcher = {
    width: 660,
    height: 520,
    searchPad: 20,
    openMs: 230,
    closeMs: 165,
    enterScale: 0.94,
    keyboardEnterOffset: -28,
    keyboardDimLid: 0.86,
    dockOpenMs: 310,
    dockCloseMs: 210,
    dockEnterScale: 0.16,
    dockDimBloom: 0.92
};

// --- Helpers ---------------------------------------------------------------

// Clamp a value into [lo, hi].
function clamp(v, lo, hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Sizing scale used to derive icon/slot from a base. Returns px.
function iconSize(scale) { return Math.round(space.icon * (scale || 1)); }

// Resolve an easing name to a Qt easing type int is done in QML (needs QtQuick).
// Here we just validate/rename for consistency.
function easingName(name) {
    return name === "OutQuint" ? "OutQuint" : (name === "InCubic" ? "InCubic" : "OutCubic");
}

// Build a layered shadow spec string components (y, blur, spread, alpha).
function shadow(level) {
    var e = elev[level] || elev.shelf;
    return { y: e.y, blur: e.blur, spread: e.spread, alpha: e.alpha };
}
