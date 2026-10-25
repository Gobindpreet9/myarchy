.pragma library
/*
 * CalcCellCases.js - the table-cell CLASSIFICATION cases for editable calc data.
 *
 * Read by tests/tst_AiCalcEdit.qml (AiCalcEdit.parseCell must match, and for
 * kind "number" the JS engine must agree) and tests/test_ai_calc_cells.py (the
 * Python engine ai_calc.py must agree). Same file format as CalcGolden.js: line 1
 * the library pragma, this comment, the keyword var, the name CASES and an
 * equals sign on its OWN line, then ONE pure-JSON array (ASCII only, no comments,
 * no trailing semicolon).
 *
 * Case: tag, raw (the committed text), kind ("number" | "text"), ok, empty,
 * code (null | "TYPE" | "RANGE"). The engines are checked by putting raw in a
 * one-cell number column: TYPE and RANGE become that error code, an empty cell
 * is skipped, anything else is a number. Rules mirrored from the engine: ASCII
 * trim (space, tab, LF, CR, VT, FF only), then [+-]? digits with an optional
 * fraction ('.5' ok, '1.' not) or a leading-dot fraction and an optional
 * exponent ('1e3' ok); overflow to infinity is RANGE; NBSP and every other
 * non-ASCII character is TYPE. Text kind is a launcher rule (<= 64 UTF-16 units
 * after ASCII trim, no control/format characters, no unpaired surrogates), not an
 * engine rule. "engine": false marks a case the launcher refuses but the engine
 * would accept (the 64-character cap), so engine comparisons skip it.
 */
var CASES =
[
{"tag":"num-ok-int","raw":"1","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-neg-decimal","raw":"-1.5","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-decimal","raw":"0.25","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-plus-sign","raw":"+3","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-leading-dot","raw":".5","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-leading-zeros","raw":"007","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-exp-lower","raw":"1e3","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-exp-upper","raw":"1E3","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-exp-signed","raw":"1.5e-3","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-negative-zero","raw":"-0","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-ascii-spaces","raw":"  42  ","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-ascii-controls-trimmed","raw":"\t7\n","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-vt-ff-trimmed","raw":"\u000b5\f","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-twenty-digits","raw":"12345678901234567890","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-underflow-is-zero","raw":"1e-999","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-zero-padded-decimal","raw":"00.5","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-max-double","raw":"1.7976931348623157e308","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-ok-sixty-four-chars","raw":"1111111111111111111111111111111111111111111111111111111111111111","kind":"number","ok":true,"empty":false,"code":null},
{"tag":"num-empty-empty","raw":"","kind":"number","ok":true,"empty":true,"code":null},
{"tag":"num-empty-spaces","raw":"   ","kind":"number","ok":true,"empty":true,"code":null},
{"tag":"num-empty-tab-newline","raw":"\t\n","kind":"number","ok":true,"empty":true,"code":null},
{"tag":"num-empty-cr-lf-vt-ff","raw":" \r\n\u000b\f ","kind":"number","ok":true,"empty":true,"code":null},
{"tag":"num-type-decimal-comma","raw":"1,5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-thousands-space","raw":"1 500","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-currency-code-prefix","raw":"EUR5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-currency-code-suffix","raw":"5 EUR","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-accounting-brackets","raw":"(5)","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-hex","raw":"0x10","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-trailing-dot","raw":"1.","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-letters","raw":"abc","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-lone-minus","raw":"-","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-lone-plus","raw":"+","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-lone-dot","raw":".","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-double-dot","raw":"1..2","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-exp-no-digits","raw":"1e","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-exp-only","raw":"e5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-exp-sign-only","raw":"1e+","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-double-sign","raw":"--5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-trailing-sign","raw":"5-","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-nbsp-prefix","raw":"\u00a05","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-nbsp-suffix","raw":"5\u00a0","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-arabic-indic","raw":"\u0661\u0662","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-fullwidth-digit","raw":"\uff15","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-underscore","raw":"1_000","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-nan","raw":"NaN","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-infinity","raw":"Infinity","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-neg-infinity","raw":"-Infinity","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-fraction","raw":"1/2","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-percent","raw":"5%","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-dollar","raw":"$5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-two-dots","raw":"1.5.2","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-unicode-minus","raw":"\u22125","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-zero-width-space","raw":"5\u200b","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-fractional-exponent","raw":"1e5.5","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-binary","raw":"0b1","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-word","raw":"true","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-nel-not-trimmed","raw":"\u0085","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-em-space-not-trimmed","raw":"\u2003","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-type-em-space-around","raw":"\u20035\u2003","kind":"number","ok":false,"empty":false,"code":"TYPE"},
{"tag":"num-range-exp-overflow","raw":"1e999","kind":"number","ok":false,"empty":false,"code":"RANGE"},
{"tag":"num-range-neg-exp-overflow","raw":"-1e999","kind":"number","ok":false,"empty":false,"code":"RANGE"},
{"tag":"num-range-digits-overflow","raw":"99999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999","kind":"number","ok":false,"empty":false,"code":"RANGE"},
{"tag":"num-range-just-over-max","raw":"1.8e308","kind":"number","ok":false,"empty":false,"code":"RANGE"},
{"tag":"num-range-exp-309","raw":"1e309","kind":"number","ok":false,"empty":false,"code":"RANGE"},
{"tag":"num-launcher-cap-65-digits","raw":"11111111111111111111111111111111111111111111111111111111111111111","kind":"number","ok":false,"empty":false,"code":"RANGE","engine":false},
{"tag":"text-plain","raw":"Air 13","kind":"text","ok":true,"empty":false,"code":null},
{"tag":"text-accents","raw":"caf\u00e9 \u00fcber","kind":"text","ok":true,"empty":false,"code":null},
{"tag":"text-empty","raw":"","kind":"text","ok":true,"empty":true,"code":null},
{"tag":"text-spaces","raw":"   ","kind":"text","ok":true,"empty":true,"code":null},
{"tag":"text-sixty-four","raw":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","kind":"text","ok":true,"empty":false,"code":null},
{"tag":"text-sixty-five","raw":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","kind":"text","ok":false,"empty":false,"code":"RANGE"},
{"tag":"text-edge-controls-trimmed","raw":"\tAir\n","kind":"text","ok":true,"empty":false,"code":null},
{"tag":"text-inner-tab","raw":"a\tb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-nul","raw":"a\u0000b","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-newline-inside","raw":"a\nb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-del","raw":"a\u007fb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-zero-width","raw":"a\u200bb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-rtl-override","raw":"a\u202eb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-soft-hyphen","raw":"a\u00adb","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-bom","raw":"\ufeffa","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-lone-high-surrogate","raw":"a\ud800","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-lone-low-surrogate","raw":"\udc00a","kind":"text","ok":false,"empty":false,"code":"TYPE"},
{"tag":"text-emoji-pair","raw":"ok \ud83d\ude00","kind":"text","ok":true,"empty":false,"code":null},
{"tag":"text-nbsp-only","raw":"\u00a0","kind":"text","ok":true,"empty":false,"code":null}
]
