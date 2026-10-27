"""Bounded, dependency-free native answer validation. All non-rich text is plain text."""

import copy
import html
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import re
import unicodedata
from urllib.parse import unquote, urlsplit

import ai_calc
from ai_formula import FormulaError, compile_formula

MAX_RESPONSE_BYTES = 65536
MAX_FALLBACK_CHARS = 4096
OPENUI_CODE_LIMIT = 32 * 1024  # UTF-8 bytes, NOT the schema's character bound
OPENUI_COMPONENT_PROMPT_LIMIT = 40 * 1024
OPENUI_INSTRUCTIONS_LIMIT = 56 * 1024  # separate optional profile; native budgets stay unchanged
OPENUI_PROMPT_PATH = Path(__file__).with_name("openui") / "native-system-prompt.txt"
OPENUI_PROMPT_ERROR = "Native OpenUI support is unavailable. Install its matching native runtime and prompt, or use native answers."
SCHEMA_PATH = Path(__file__).with_name("ai-answer.schema.json")
OPENUI_ANSWER_SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
# The installed file describes the optional superset. Native providers, prompts
# and validation still see the EXACT previous schema, not an ungated new type.
ANSWER_SCHEMA = copy.deepcopy(OPENUI_ANSWER_SCHEMA)
ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"] = [
    block for block in ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"]
    if block["properties"]["type"]["enum"] != ["openui"]]
JSON_SCHEMA = ANSWER_SCHEMA


def answer_schema(response_mode="native"):
    if response_mode == "native":
        return ANSWER_SCHEMA
    if response_mode == "openui":
        return OPENUI_ANSWER_SCHEMA
    raise ValueError("Unknown response profile")

# The one worked example shown to the model (and pinned by tests/test_ai_catalog.py).
# HAND-VERIFIED, not engine-derived: with weights 5/3/2 (total 10) each laptop is
# (5*speed/10 + 3*battery/20 + 2*clamp(1 - price/2000, 0, 1)) / 10 * 100:
#   Air 13   (5*7/10 + 3*15/20 + 2*(1-1100/2000)) = 3.5 + 2.25 + 0.9   = 6.65 -> 66.5
#   Pro 14   (5*9/10 + 3*11/20 + 2*(1-1800/2000)) = 4.5 + 1.65 + 0.2   = 6.35 -> 63.5
#   Budget 15 (5*5/10 + 3*8/20  + 2*(1-650/2000)) = 2.5 + 1.2  + 1.35  = 5.05 -> 50.5
# mean score = 180.5 / 3 = 60.1667 -> "60.2"; mean price = 3550 / 3 = 1183.33 EUR
# -> "1183 EUR". The same numbers were recomputed in exact Fraction arithmetic
# outside the engine. At all weights 0 the guard gives 0; at all weights 10 the
# scores are 63.33, 51.67 and 52.50.
CALC_EXAMPLE = {
    "type": "calc", "title": "Laptop score",
    "inputs": [
        {"id": "w_perf", "label": "Speed weight", "unit": "", "min": 0, "max": 10, "step": 1,
         "value": 5, "basis": "assumption"},
        {"id": "w_batt", "label": "Battery weight", "unit": "", "min": 0, "max": 10, "step": 1,
         "value": 3, "basis": "assumption"},
        {"id": "w_price", "label": "Price weight", "unit": "", "min": 0, "max": 10, "step": 1,
         "value": 2, "basis": "assumption"}],
    "tables": [{"id": "laptops", "label": "Laptops", "columns": [
        {"id": "name", "label": "Laptop", "unit": "", "kind": "text", "expression": ""},
        {"id": "perf", "label": "Speed (0-10)", "unit": "", "kind": "number", "expression": ""},
        {"id": "batt", "label": "Battery", "unit": "h", "kind": "number", "expression": ""},
        {"id": "price", "label": "Price", "unit": "EUR", "kind": "number", "expression": ""},
        {"id": "score", "label": "Score", "unit": "", "kind": "formula",
         "expression": "if(wsum==0,0,(w_perf*perf/10+w_batt*batt/20[h]"
                       "+w_price*clamp(1-price/2000[EUR],0,1))/wsum*100)"}],
        "rows": [["Air 13", "7", "15", "1100", ""],
                 ["Pro 14", "9", "11", "1800", ""],
                 ["Budget 15", "5", "8", "650", ""]]}],
    "cells": [
        {"id": "wsum", "label": "Total weight", "expression": "w_perf+w_batt+w_price",
         "unit": "", "decimals": 0, "note": ""},
        {"id": "mean_score", "label": "Average score", "expression": "mean(laptops.score)",
         "unit": "", "decimals": 1, "note": ""},
        {"id": "avg_price", "label": "Average price", "expression": "mean(laptops.price)",
         "unit": "EUR", "decimals": 0, "note": ""}],
    "note": "Illustrative data. Speed is scaled to 10, battery to 20 h, price to 2000 EUR."}

_INSTRUCTIONS_HEAD = """Design for the task, not a flat document. For practical tasks, make the primary
native interactive object the answer: help the person decide, plan, calculate
or explore. Put it first in blocks; add only useful supporting blocks.
Use answer for 1-2 sentences of orientation, not a second prose answer
repeating the tool's contents. Keep explanations and source notes terse and
subordinate to the tool. Choose automatically, without asking the user to
request a card. Use only supported controls and bindings; never imply they
change unrelated blocks or perform external actions.
Choose an image automatically when a visual helps explain a place, landmark,
animal, or visual concept. Use a concrete encyclopedia subject as its query,
not an image URL or HTML.
Images are contextual illustrations, never visual proof of a claim or event.
For a bare animal, landmark, or place topic, identify it and add one or two
distinguishing facts in two or three short sentences; no filler blocks.
For stock, index, and ETF questions, choose a market block with the actual
ticker symbol (for example, AAPL, ^GSPC, or SPY); default range is 1mo unless
the question needs 3mo or 1y. The trusted market resolver adds sourced actual
data outside the model. Never invent numeric prices or market history, and
never add data, URLs, or other resolved fields to raw image or market blocks.
Do not assert a numerical trend from resolver-only data you have not seen;
keep the market introduction neutral unless independently verified by search.
Market charts show dated historical/delayed data, not a real-time quote feed.
Use a generic chart ONLY for an explicit user-supplied dataset or verified
sourced values. Labels and values must have equal lengths; title, unit, source,
and asOf must honestly describe the data. For verified values source is a
public HTTPS citation URL and asOf states its actual date or period. For
user-supplied data use source "" and asOf exactly "Provided data". Never
invent chart values, provenance, or timestamps.
Packing lists use an interactive checklist; quantities use metrics, and supplied
completion counts use progress. Never invent metrics, scores, live data or
completion counts to decorate an interface. Put structured content in blocks,
not a prose list or Markdown table in the answer. Omit onboarding copy and
repeated headings; suggestions may be empty. If current information is needed
and hosted web search is available, use it before answering. Cite verified
sources in a sources block with short labels and public HTTPS URLs for clickable
citations, rather than raw URLs in text. For events, use a table of confirmed
events with date, venue, useful details, plus sources. Never invent listings.
If search is unavailable, state that briefly without implying you searched the web.
For visual exploration, choose a gallery or diagram, with a coupled slider
only when changing a number teaches something:
- How something works, a mechanism, geometry, or relationships -> one diagram:
  a schematic on a percentage grid (x/y/w/h are 0-100 of the canvas; for
  line/arrow they are start point plus offsets, so negatives turn the line;
  keep parts inside the canvas), with circle/rect/line/arrow/text parts. Give
  selectable parts a short label and a detail explaining their role; leave
  detail empty for decoration. tone picks accent/foreground/muted; keep fill
  sparingly; label schematic and not-to-scale geometry as such in the caption or
  a text part.
- One number that changes the picture (month, angle, distance, rate, budget) ->
  one slider: control with label/min/max/step/value/unit and optional labels for
  named steps, plus 1-4 readouts whose expressions use only x, arithmetic
  (+ - * / % ^), pi/e, and sin cos tan asin acos atan sind cosd tand sqrt abs
  floor ceil round min max clamp. Readouts must be honest approximations; put
  any simplification in the note. Make the diagram respond by adding links on
  the slider: part (0-based index into the diagram's parts), property
  (x y w h rotation), expression in the same grammar driven by x; keep results
  inside -100..100 for x/y/w/h. Remember x/y grow right and DOWN.
- Only numeric what-if or weighted calculations with meaningful editable inputs,
  not qualitative choices -> one calc block: numeric inputs, optional tables of literal
  rows with formula columns, and cells with formulas. The launcher computes
  every cell, so never type a computed number as text. State every formula with
  its unit. Money units are ISO-4217 codes (EUR, USD); a
  conversion between currencies needs an explicit rate input whose basis is
  assumption or sourced, with a sources block for sourced. Never present an
  assumed number as a fact, and put every simplification in the note. Guard
  divisions with if(), as in if(n==0,0[EUR],a/n); both branches need the same
  unit, and every cell must evaluate without error at the minimum, midpoint and
  maximum of all inputs or the calculator is dropped. Grammar:
  + - * / % ^ and or not == != < <= > >= (no chained comparisons); numbers are
  plain decimals with an optional unit as in 12.5[kg], never 1e3; the only
  functions are abs min max clamp floor ceil sqrt round(x,n) if(c,a,b)
  iferror(a,b) to(q,[u]) num(q,[u]) sum mean median count sumproduct; Table.col
  only inside sum/mean/median/count/sumproduct, while a formula column names its
  own row's columns directly. min and max take 2-6 plain values, never a column:
  scale against fixed bounds, as in the example. Units: mm cm m km in ft mi g kg lb oz s min h d wk B kB MB
  GB TB KiB MiB GiB TiB J Wh kWh W kW Hz GHz px % and ISO-4217 codes. Ids match
  [a-z][a-z0-9_]{0,23} and must not equal a function, and/or/not or a unit
  symbol such as s, h, m, d, g, in, min. Number-column cells are plain numbers
  or empty; formula-column cells are empty strings. Worked example: """
_CALC_EXAMPLE_JSON = json.dumps(CALC_EXAMPLE, ensure_ascii=False, separators=(",", ":"))
# One use/not-for line per NEW block type, spliced into the prompt as bullets (each <= 140 B,
# pinned by tests/test_ai_prompt_budget.py). The older blocks keep their hand-written bullets.
BLOCK_GUIDE = {
    "actions": "2-6 next steps after compare/timeline -> one actions block; a tap sends its label "
               "as a follow-up, never executes it; typed values: form.",
    "compare": "2-4 qualitative options -> one compare block with trade-offs; editable numeric weights "
               "-> calc; dense many-record comparisons -> table.",
    "timeline": "Schedule, itinerary, route or recipe -> one timeline (2-16 items) with clear "
                "when/duration and next step, not a checklist; processes: steps.",
}
_GUIDE_BULLETS = "".join("- " + line + "\n" for line in BLOCK_GUIDE.values())
_BODY_BLOCKS = """
- A process, lifecycle, or procedure -> one steps block (2-8 labelled stages).
- Understanding benefits from a quick self-test -> one check block with 2-6
  options, at least one correct, honest per-option feedback and an explanation.
- A surprising or predictable outcome worth committing to -> one predict block
  (2-4 choices, then a reveal and explanation).
- Comparing several concrete things you can show (buildings, species, designs,
  artworks, products, styles) -> one gallery with 2-6 labelled photos, each a
  specific image query and a caption naming its role, rather than one hero
  image. When the user wants to RECOGNISE or IDENTIFY something visual (styles,
  species, designs, landmarks), prefer the gallery so they can actually see the
  differences; use a table only as a supplement or when images cannot help.
  Captions describe what the item is meant to show, never invented
  details.
- A single subject that reads better as one picture -> one image block.
- Several typed answers to resolve unknown constraints for ONE follow-up ->
  one form block of 1-6 fields: number (min, max, step, unit), choice (2-6
  options, value = default index), text (placeholder) or toggle (value 0 or 1);
  unused values are "" or 0; strings are one plain line. Not for numbers varied
  to see an effect (calc) or a quiz (check, predict).
"""
_BODY_RULES = """Never invent measurements, coordinates for real places, captions, or data; the
visuals are teaching schematics, not evidence. If an attached CSV snapshot is
marked truncated or notes that it is sampled, base any count, average or trend
on the sampled rows shown and say the answer reflects a sample, never the whole
file. Only when the request carries a "Full-source statistics" section may you
quote the count, empty count, min, max, sum and mean of the columns it lists as
whole-file values; every other aggregate, trend or category claim (median,
quantile, correlation, group-by) stays sample-bound or must be declined or
deferred to the local explorer. Without that section a prefix sample never
supports a whole-file claim. Shortened header/cell values are incomplete; never use clipped values
for exact calculations or identifiers. A greeting, a simple fact, or a
short definition stays a short answer with no blocks. At most one of each of
slider, diagram, gallery, and calc per answer; at most one each of form, actions,
compare and timeline; at most two contextual media blocks (image, market,
gallery combined); at most six blocks total.
Return exactly one JSON object matching the supplied schema:
answer is plain text: do not put Markdown links or citation URLs in it; citations
belong in sources blocks. blocks is at most six flat native blocks; suggestions is
at most three short follow-up questions (strings). Include all required fields
and no extra keys. """
_INSTRUCTIONS_BODY = _BODY_BLOCKS + _GUIDE_BULLETS + _BODY_RULES
_FIELD_LIST = """Use text/richtext/code (type,title,text), checklist
(type,title,items), steps (type,title,steps of label,detail), check
(type,title,question,options of label,correct,feedback,explanation), predict
(type,title,prompt,choices,reveal,explanation), diagram
(type,title,caption,aspect,parts of shape,x,y,w,h,label,detail,tone,fill,rotation),
slider (type,title,control of label,min,max,step,value,unit,labels; readouts of
label,expression,unit; links of part,property x|y|w|h|rotation,expression; note),
calc (type,title,inputs,tables,cells,note),
form (type,title,fields of id,label,kind,unit,min,max,step,value,options,
placeholder; submitLabel,note),
actions (type,title,options of label,hint),
compare (type,title,options of name,summary,facts of label,value; pros,cons,recommended; verdict),
timeline (type,title,items of label,when,minutes,detail),
table (type,title,columns,rows), metric
(type,title,value as string,detail), or progress
(type,title,value as a number from 0 to 1,detail), image (type,title,query),
gallery (type,title,items of query,caption),
market (type,title,symbol,range), sources (type,title,items of label,url), or
chart (type,title,unit,labels,values,source,asOf). """
_INSTRUCTIONS_RULES = """Table rows must match the
column count. Rich text permits only b,strong,i,em,u,s,p,br,ul,ol,li,h1,h2,h3,
pre,code without attributes. No arbitrary HTML/JS or executable layouts.
Never include remote image URLs or image HTML,
resources, HTML links, styles, scripts, nested UI or blocks, commands to execute,
or tool calls in the final JSON. URLs belong only in sources or chart source.
You may use the provided hosted web search tool for live information; no
local command, file editing, or arbitrary filesystem tools are available.
This is an answer-and-inspect interface: never claim to have
inspected a file or system unless its contents were provided. There is no
tool for arbitrary commands. Suggestions are questions, not actions.
"""
_SCHEMA_DUMP = json.dumps(ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":"))


def _sig_number(value):
    """A schema limit as short as exact: 1000000000 -> 1e9, 0.8 -> 0.8."""
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, int) and abs(value) >= 1000000:
        digits = str(abs(value))
        if digits == "1" + "0" * (len(digits) - 1):
            return ("-" if value < 0 else "") + "1e" + str(len(digits) - 1)
    return str(value)


_SIG_KEYWORDS = frozenset((
    "type", "properties", "required", "additionalProperties", "items", "enum", "minLength", "maxLength",
    "pattern", "minimum", "maximum", "exclusiveMinimum", "minItems", "maxItems"))


def _sig_constrained(node):
    """True when a node carries something the caps view must show (anything but free text)."""
    kind = node.get("type")
    if "enum" in node or kind in ("number", "integer", "array"):
        return True
    if kind == "string":
        return bool(node.get("minLength")) and "pattern" not in node
    return kind == "object" and any(_sig_constrained(child) for child in node["properties"].values())


def _sig_node(node, caps):
    unknown = set(node) - _SIG_KEYWORDS
    if unknown:  # a new schema keyword must be taught to the signature, never silently dropped
        raise ValueError("Unsupported schema keyword " + ", ".join(sorted(unknown)))
    if "enum" in node:
        return "|".join(node["enum"])
    kind = node["type"]
    if kind == "string":
        low, high = node.get("minLength", 0), node.get("maxLength")
        if caps:
            return "str1.." if low else "str"
        text = "str"
        if high is not None:
            text += "%d..%d" % (low, high) if low else "<=%d" % high
        elif low:
            text += "%d.." % low
        return text + ("/" + node["pattern"] + "/" if "pattern" in node else "")
    if kind in ("number", "integer"):
        low, high = node.get("minimum"), node.get("maximum")
        opened = "["
        if "exclusiveMinimum" in node:
            low, opened = node["exclusiveMinimum"], "("
        return ("num" if kind == "number" else "int") + opened + (
            "" if low is None else _sig_number(low)) + ".." + ("" if high is None else _sig_number(high)) + "]"
    if kind == "boolean":
        return "bool"
    if kind == "array":
        low, high = node.get("minItems", 0), node["maxItems"]
        item = node["items"]
        inner = _sig_node(item, caps)  # always rendered, so an unknown keyword is refused even when unshown
        if caps and not _sig_constrained(item):
            inner = ""
        return "[" + inner + "]" + ("%d..%d" % (low, high) if low else "<=%d" % high)
    if kind == "object":
        if node.get("additionalProperties") is not False or set(node["required"]) != set(node["properties"]):
            raise ValueError("Signature needs closed objects with every field required")
        groups = []  # adjacent fields with the same shape share one spec: x,y,w,h:num[-100..100]
        for key, value in node["properties"].items():
            spec = _sig_node(value, caps)
            if not caps or _sig_constrained(value):
                if groups and groups[-1][1] == spec:
                    groups[-1][0].append(key)
                else:
                    groups.append(([key], spec))
        return "{" + ",".join(",".join(keys) + ":" + spec for keys, spec in groups) + "}"
    raise ValueError("Unsupported schema type")


def compact_signature(schema=None, caps=False):
    """A deterministic, compact rendering of the answer schema for prompts.

    ANSWER_SCHEMA stays the single source of truth: block types, every field
    name in order, enums, array sizes, numeric ranges, string limits and
    patterns are all derived from it, and a schema keyword this renderer does
    not know raises rather than vanishing. The full form serves agents that get
    no structural schema (Hermes). The caps form (Codex, whose --output-schema
    already enforces names, types and structure) keeps only what can make a
    block be rejected or clamped: array sizes, numeric ranges, enums and
    non-empty strings; free text and string lengths are left out.
    """
    schema = ANSWER_SCHEMA if schema is None else schema
    alternatives = schema["properties"]["blocks"]["items"]["anyOf"]
    root = {key: value for key, value in schema.items() if key != "$schema"}
    root = dict(root, properties=dict(schema["properties"], blocks=dict(
        schema["properties"]["blocks"], items={"type": "string", "enum": ["BLOCK"]})))
    if caps:
        legend = "Limits (all fields required; str1.. non-empty, num(a..b] excludes a):"
    else:
        legend = ("Answer shape: every field is required, no extra keys. "
                  "str<=N is text of at most N characters, str1..N at least one; "
                  "num[a..b] and int[a..b] are numbers in that closed range, num(a..b] excludes a; "
                  "[T]a..b or [T]<=b is an array of that many T; x|y is one of those exact strings; "
                  "/re/ is a full-match pattern. A BLOCK line is its type value(s), then its fields in braces.")
    lines = [legend, _sig_node(root, caps), "BLOCK is one of:"]
    for alternative in alternatives:  # every block type is listed; a caps line may be a bare name
        properties = dict(alternative["properties"])
        kinds = "|".join(properties.pop("type")["enum"])
        body = _sig_node(dict(alternative, properties=properties,
                              required=[key for key in alternative["required"] if key != "type"]), caps)
        lines.append(kinds + ("" if caps and body == "{}" else body))
    return "\n".join(lines)


# One prompt per provider, all built from the same pieces so a rule is stated once.
#   full   (unknown agents, back-compat): prose + field list + the whole schema dump.
#   codex  : prose + a caps-only table. Codex receives the structure through
#            --output-schema (names, types, nesting), so the field list and the
#            10 KB dump are redundant there; what stays is what the model should
#            plan for: array sizes, numeric ranges, enums and non-empty strings.
#   hermes : prose + the full compact signature (it has no structural schema).
_SCHEMA_INTRO = "The authoritative bounded schema follows:\n"
SYSTEM_INSTRUCTIONS = (_INSTRUCTIONS_HEAD + _CALC_EXAMPLE_JSON + _INSTRUCTIONS_BODY + _FIELD_LIST
                       + _INSTRUCTIONS_RULES + _SCHEMA_INTRO + _SCHEMA_DUMP)
CODEX_INSTRUCTIONS = (_INSTRUCTIONS_HEAD + _CALC_EXAMPLE_JSON + _INSTRUCTIONS_BODY.rstrip(" ") + "\n"
                      + compact_signature(caps=True) + "\n" + _INSTRUCTIONS_RULES)
HERMES_INSTRUCTIONS = (_INSTRUCTIONS_HEAD + _CALC_EXAMPLE_JSON + _INSTRUCTIONS_BODY.rstrip(" ") + "\n"
                       + compact_signature() + "\n" + _INSTRUCTIONS_RULES)
# OpenCode has no structural output schema flag either, so it gets the same
# compact signature as Hermes. The catalogue still travels in each request.
OPENCODE_INSTRUCTIONS = HERMES_INSTRUCTIONS


def system_instructions(agent=None) -> str:
    """The system prompt for one provider agent: 'codex', 'hermes', 'opencode', anything else gets the full text."""
    if agent == "codex":
        return CODEX_INSTRUCTIONS
    if agent == "hermes":
        return HERMES_INSTRUCTIONS
    if agent == "opencode":
        return OPENCODE_INSTRUCTIONS
    return SYSTEM_INSTRUCTIONS


def openui_instructions(agent=None):
    """Read only the fixed installed native-library prompt, then scope it to code.

    The core's generic output-only directives describe a DSL program, not our
    provider reply. They are explicitly subordinate to the JSON envelope below.
    This is NOT the React prototype's system prompt or a request-selected path.
    """
    import os
    import stat
    try:
        fd = os.open(OPENUI_PROMPT_PATH, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > OPENUI_COMPONENT_PROMPT_LIMIT:
                raise ValueError()
            data = stream.read(OPENUI_COMPONENT_PROMPT_LIMIT + 1)
        if not data or len(data) > OPENUI_COMPONENT_PROMPT_LIMIT:
            raise ValueError()
        component = data.decode("utf-8", "strict").strip()
        if not component or "\0" in component:
            raise ValueError()
    except (OSError, ValueError):
        raise ValueError(OPENUI_PROMPT_ERROR) from None
    scope = (
        "\n\nOPTIONAL NATIVE OPENUI PROFILE. All previous native blocks, especially calc, remain valid. "
        "For a useful custom interactive task, PREFER ONE openui block over static native presentation. "
        "When the user asks to understand, explore, simulate, compare or configure a system with "
        "multiple states, use OpenUI whenever a small interactive control (slider, input, segmented "
        "control, step-through, toggle) would make the answer clearer. A static diagram, check or "
        "checklist alone is not enough for those tasks; use one only when a fixed picture is genuinely "
        "better. Simple facts, short definitions and validated numeric calculations stay native. "
        "The openui block has exactly "
        "{type:\"openui\",title:string,code:string}. Title is at most 160 characters; code is a non-empty "
        "OpenUI DSL program of at most 32768 UTF-8 bytes. The usual six-block and 65536-byte answer "
        "limits still apply. This is the sole exception to the earlier ban on nested UI: inert DSL "
        "text INSIDE blocks[].code, never HTML, JavaScript, QML, scripts or provider tool calls. "
        "Every argument must match the reference's type, position and arity exactly; never pass "
        "a label where a boolean or number is expected, and omit optional arguments rather than "
        "guessing. A program the native runtime rejects is not shown.\n"
        "The following generated native-library reference governs ONLY that code string. Its "
        "examples are programs, NOT complete replies. Any instruction in it to return only DSL, "
        "omit JSON, or emit a raw program applies only when authoring blocks[].code.\n"
        "BEGIN CODE-STRING-ONLY NATIVE LIBRARY REFERENCE\n"
    )
    closing = (
        "\nEND CODE-STRING-ONLY NATIVE LIBRARY REFERENCE\n"
        "FINAL RESPONSE CONTRACT (overrides generic output-only directions in the reference): "
        "Return exactly ONE JSON object with exactly answer, blocks and suggestions, matching the "
        + ("bounded answer shape above. " if agent == "opencode" else "supplied output schema. ") +
        "Never return a raw DSL program or a Markdown fence. Escape the "
        "complete DSL as a JSON string in blocks[].code; at most one openui block. Use answer for "
        "brief orientation. Keep the existing strict native calc block for unit-aware, provenance-"
        "bearing or validated numeric calculations. Generic OpenUI arithmetic is illustrative only; "
        "it NEVER inherits the typed calculation engine's validation, units or provenance guarantees. "
        "Never claim live data, verified facts, external actions or saved edits without evidence. "
        "No new provider tools are available."
    )
    text = (OPENCODE_INSTRUCTIONS if agent == "opencode" else CODEX_INSTRUCTIONS) + scope + component + closing
    if len(text.encode("utf-8")) > OPENUI_INSTRUCTIONS_LIMIT:
        raise ValueError(OPENUI_PROMPT_ERROR)
    return text


_ALLOWED = frozenset("b strong i em u s p br ul ol li h1 h2 h3 pre code".split())
_VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
_ANSWER_LINK = re.compile(r"\[([^\]\n]{1,160})\]\((https?://(?:[^\s()]|\([^()\s]*\)){1,2048})\)", re.IGNORECASE)


def _plain_answer_citations(result):
    """Move Markdown citations out of the plain answer into native source links."""
    found = []

    def extract(match, wrapped=False):
        label, url = match.group(1), match.group(2)
        try:
            canonical = _safe_public_https_url(url)
            fragment = urlsplit(url).fragment
            canonical += "#" + fragment if fragment else ""
        except ValueError:
            return label
        found.append({"label": label, "url": canonical})
        return "" if wrapped else label

    # A standalone parenthesized citation is supporting metadata, not prose.
    text = re.sub(r"\(\s*(" + _ANSWER_LINK.pattern + r")\s*\)",
                  lambda match: extract(_ANSWER_LINK.fullmatch(match.group(1)), True), result["answer"], flags=re.IGNORECASE)
    text = _ANSWER_LINK.sub(extract, text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    result["answer"] = re.sub(r"[ \t]+(?=[.,;:!?]|$)", "", text).strip()
    if not found:
        return
    source_block = next((block for block in result["blocks"] if block["type"] == "sources"), None)
    if source_block is None and len(result["blocks"]) < 6:
        source_block = {"type": "sources", "title": "Sources", "items": []}
        result["blocks"].append(source_block)
    if source_block is None:
        return
    existing = {_safe_public_https_url(item["url"]) for item in source_block["items"]}
    for item in found:
        key = _safe_public_https_url(item["url"])
        if key not in existing and len(source_block["items"]) < 6:
            source_block["items"].append(item)
            existing.add(key)


class _RichTextParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.open_tags = []
        self.dropped = []

    def handle_starttag(self, tag, attrs):
        if self.dropped:
            if tag not in _VOID:
                self.dropped.append(tag)
        elif tag in _ALLOWED:
            self.parts.append("<" + tag + ">")
            if tag != "br":
                self.open_tags.append(tag)
        elif tag not in _VOID:
            self.dropped.append(tag)

    def handle_startendtag(self, tag, attrs):
        if not self.dropped and tag in _ALLOWED:
            self.parts.append("<br>" if tag == "br" else "<" + tag + "></" + tag + ">")

    def handle_endtag(self, tag):
        if self.dropped:
            if tag in self.dropped:
                index = len(self.dropped) - 1 - self.dropped[::-1].index(tag)
                del self.dropped[index:]
        elif tag in self.open_tags:
            while self.open_tags:
                opened = self.open_tags.pop()
                self.parts.append("</" + opened + ">")
                if opened == tag:
                    break

    def handle_data(self, data):
        if not self.dropped:
            self.parts.append(html.escape(data, quote=False))


def sanitize_richtext(text: str) -> str:
    """Remove attributes and all unsupported elements, including their content."""
    parser = _RichTextParser()
    parser.feed(text)
    parser.close()
    return "".join(parser.parts) + "".join("</" + tag + ">" for tag in reversed(parser.open_tags))


def _validate(value, schema):
    if "anyOf" in schema:
        for alternative in schema["anyOf"]:
            try:
                _validate(value, alternative)
                return
            except ValueError:
                pass
        raise ValueError("Unknown or invalid block")
    kind = schema["type"]
    if kind == "object":
        if type(value) is not dict or set(value) != set(schema["required"]):
            raise ValueError("Unexpected or missing fields")
        for key, subschema in schema["properties"].items():
            _validate(value[key], subschema)
    elif kind == "array":
        if type(value) is not list or not schema.get("minItems", 0) <= len(value) <= schema["maxItems"]:
            raise ValueError("Invalid array or array limit")
        for item in value:
            _validate(item, schema["items"])
    elif kind == "string":
        if (type(value) is not str
                or not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", MAX_RESPONSE_BYTES)):
            raise ValueError("Invalid string or string limit")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeError as exc:
            raise ValueError("Invalid UTF-8 string") from exc
        if "enum" in schema and value not in schema["enum"]:
            raise ValueError("Unknown block type")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            raise ValueError("Invalid string pattern")
    elif kind == "boolean":
        if type(value) is not bool:
            raise ValueError("Invalid boolean")
    elif kind == "integer":
        minimum = schema.get("minimum", float("-inf"))
        maximum = schema.get("maximum", float("inf"))
        if type(value) is not int or not minimum <= value <= maximum:
            raise ValueError("Invalid integer value")
    elif kind == "number":
        minimum = schema.get("minimum", float("-inf"))
        maximum = schema.get("maximum", float("inf"))
        if (type(value) not in (int, float)
                or not minimum <= value <= maximum
                or (type(value) is float and not math.isfinite(value))):
            raise ValueError("Invalid numeric value")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            raise ValueError("Invalid numeric value")
    else:
        raise ValueError("Unsupported schema type")


def _safe_public_https_url(url: str) -> str:
    """Validate syntax only, without DNS/network; return a canonical duplicate key.

    Public-looking hostnames can still resolve privately. Any future fetcher must
    separately check resolved addresses and redirects before making requests.
    """
    if (not url or len(url) > 2048 or "\\" in url
            or any(char.isspace() or unicodedata.category(char).startswith("C") for char in url)
            or re.search(r"%(?![0-9a-fA-F]{2})", url)
            or re.search(r"%(?:25|5c|7f|0[0-9a-f]|1[0-9a-f])", url, re.IGNORECASE)):
        raise ValueError("Unsafe source URL")
    try:
        decoded = unquote(url, errors="strict")
        if any(unicodedata.category(char).startswith("C") for char in decoded):
            raise ValueError("Unsafe encoded source URL")
        parts = urlsplit(url)
        if (parts.scheme != "https" or not parts.netloc or parts.username is not None
                or parts.password is not None or "%" in parts.netloc
                or "[" in parts.netloc or "]" in parts.netloc):
            raise ValueError("Source URL must use public HTTPS without credentials")
        host = (parts.hostname or "").encode("idna").decode("ascii").lower()
        port = parts.port
        if port is not None and not 1 <= port <= 65535:
            raise ValueError("Invalid source URL port")
        # A trailing colon is not a port, even though urlsplit accepts it.
        if parts.netloc.endswith(":"):
            raise ValueError("Invalid source URL port")
        labels = host.split(".")
        if (len(host) > 253 or len(labels) < 2
                or any(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) is None for label in labels)
                or re.fullmatch(r"(?:[a-z]{2,63}|xn--[a-z0-9-]+)", labels[-1]) is None
                or labels[-1] in {"localhost", "local", "internal", "lan", "home", "test", "invalid", "example"}):
            raise ValueError("Source URL must have a public hostname, not an IP literal")
        # Check punycode labels too; Python's IDNA encoder passes ASCII through.
        for label in labels:
            if label.startswith("xn--"):
                if label.encode("ascii").decode("idna").encode("idna").decode("ascii") != label:
                    raise ValueError("Invalid IDNA hostname")
    except (UnicodeError, ValueError) as exc:
        raise ValueError("Unsafe source URL") from exc
    authority = host + (":" + str(port) if port not in (None, 443) else "")
    query = "&".join(part for part in parts.query.split("&")
                     if not unquote(part.partition("=")[0]).lower().startswith("utm_")
                     and unquote(part.partition("=")[0]).lower() not in {"fbclid", "gclid"})
    return "https://" + authority + (parts.path or "/") + ("?" + query if query else "")


_CALC_NUMBER_CELL = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)", re.ASCII)
_CALC_CELL_SPACE = " \t\r\n\f\v"


def _clean_line(text):
    """One plain line: control, format (bidi), surrogate, private-use and line/paragraph
    separator characters become a space, whitespace runs collapse, the ends are trimmed."""
    return " ".join("".join(
        " " if unicodedata.category(char).startswith("C") or unicodedata.category(char) in ("Zl", "Zp")
        else char for char in text).split())


# Blocks whose every string is one display line (no ids, no enums): all of them are cleaned.
_LINE_BLOCKS = ("actions", "compare", "timeline")


def _clean_lines(node, depth=0):
    """Clean every string below a detached block to one plain line, in place.

    Descends four levels (block > options > facts > strings is the deepest shape); anything
    deeper cannot be valid and is left for the schema check to reject. Only a block whose raw
    type is exactly one of _LINE_BLOCKS gets here, so a type spelled "actions " stays an unknown block.
    """
    for key, value in list(node.items() if type(node) is dict else enumerate(node)):
        if type(value) is str:
            node[key] = _clean_line(value)
        elif type(value) in (dict, list) and depth < 4:
            _clean_lines(value, depth + 1)


def _sanitize_block_strings(block):
    """Clean a detached block's display strings in place, before the schema caps apply.

    Tolerant of any shape: whatever is not a form/actions/compare/timeline block, or not a
    string, is left for the schema check to judge. Cleaning only ever shortens, so a string
    within its cap stays within it and one that is over only because of padding now fits.
    """
    if type(block) is dict and block.get("type") in _LINE_BLOCKS:
        _clean_lines(block)
        return
    if type(block) is not dict or block.get("type") != "form":
        return
    for key in ("title", "submitLabel", "note"):
        if type(block.get(key)) is str:
            block[key] = _clean_line(block[key])
    if type(block.get("fields")) is list:
        for field in block["fields"]:
            if type(field) is not dict:
                continue
            for key in ("label", "unit", "placeholder"):
                if type(field.get(key)) is str:
                    field[key] = _clean_line(field[key])
            if type(field.get("options")) is list:
                field["options"] = [_clean_line(option) if type(option) is str else option
                                    for option in field["options"]]


def _check_form(block):
    """Normalize one form block in place; raise ValueError if unusable.

    The display strings were already cleaned to one plain line by
    _sanitize_block_strings (a label or option that is empty AFTER cleaning is
    rejected here). A field uses only what its kind needs: values the kind
    ignores are reset to the empty convention ("" / 0 / []) rather than
    rejected, so one canonical shape reaches the renderer.
    """
    seen = set()
    for field in block["fields"]:
        if field["id"] in seen:
            raise ValueError("Form field ids must be unique")
        seen.add(field["id"])
        if not field["label"]:
            raise ValueError("A form field needs a label")
        kind = field["kind"]
        if kind != "number":
            field["unit"] = ""
        if kind != "text":
            field["placeholder"] = ""
        if kind != "choice":
            field["options"] = []
        if kind == "number":
            if field["min"] >= field["max"]:
                raise ValueError("Form number range must increase")
            if field["step"] <= 0:
                raise ValueError("Form number step must be positive")
            field["value"] = min(field["max"], max(field["min"], field["value"]))
            field["step"] = min(field["step"], field["max"] - field["min"])
            continue
        field["min"] = field["max"] = field["step"] = 0
        if kind == "choice":
            options = field["options"]
            if not 2 <= len(options) <= 6 or any(not option for option in options):
                raise ValueError("A form choice needs 2 to 6 non-empty options")
            if len(set(options)) != len(options):
                raise ValueError("Form choice options must differ")
            if field["value"] != int(field["value"]):
                raise ValueError("A form choice value is an option index")
            field["value"] = min(len(options) - 1, max(0, int(field["value"])))
        elif kind == "toggle":
            if field["value"] not in (0, 1):
                raise ValueError("A form toggle value is 0 or 1")
            field["value"] = int(field["value"])
        else:  # text: the person types it, so a default is never carried
            field["value"] = 0


def _fold(text):
    """A comparison key for 'the same name': compatibility-normalised and case-folded."""
    return unicodedata.normalize("NFKC", text).casefold()


def _check_distinct(entries, key, message):
    """Reject two entries whose cleaned `key` reads the same (case and compatibility forms aside)."""
    folded = [_fold(entry[key]) for entry in entries]
    if len(set(folded)) != len(folded):
        raise ValueError(message)


def _check_calc(block):
    """Clamp, compile and dry-run one calc block in place; raise ValueError if unusable.

    A rejected block is never repaired: validate_response raises, and
    normalize_response drops just this block (the rest of the answer is shown
    with a generic warning). The message never carries the engine's reject slug
    and nothing is logged.
    """
    for entry in block["inputs"]:
        if entry["min"] >= entry["max"]:
            raise ValueError("Calc input range must increase")
        entry["value"] = min(entry["max"], max(entry["min"], entry["value"]))
        if entry["step"] > entry["max"] - entry["min"]:
            entry["step"] = entry["max"] - entry["min"]
    for table in block["tables"]:
        kinds = [column["kind"] for column in table["columns"]]
        for column in table["columns"]:
            if column["kind"] != "formula" and column["expression"]:
                raise ValueError("Only a formula column has an expression")
            if column["kind"] == "text":
                column["unit"] = ""
        for row in table["rows"]:
            if len(row) != len(kinds):
                raise ValueError("Calc row width must match columns")
            for index, kind in enumerate(kinds):
                if kind == "formula":
                    row[index] = ""
                elif kind == "number":
                    text = row[index].strip(_CALC_CELL_SPACE)
                    if text and (_CALC_NUMBER_CELL.fullmatch(text) is None or not math.isfinite(float(text))):
                        raise ValueError("A number column holds plain numbers")
    spec = {key: block[key] for key in ("inputs", "tables", "cells")}
    try:
        model = ai_calc.compile_spec(spec)
        inputs = block["inputs"]
        passes = [None,
                  {entry["id"]: entry["min"] for entry in inputs},
                  {entry["id"]: entry["max"] for entry in inputs},
                  {entry["id"]: (entry["min"] + entry["max"]) / 2 for entry in inputs}]
        for values in passes:
            if any(node.err is not None for node in ai_calc.evaluate(model, values).nodes.values()):
                raise ValueError("Calc block errors")
    except Exception:  # CalcError is a ValueError; anything else fails closed too, never crashing the pipeline
        raise ValueError("Calc block is invalid") from None


_BLOCK_SCHEMA = ANSWER_SCHEMA["properties"]["blocks"]["items"]


def _finish_block(block):
    """The per-block rules beyond the schema, applied in place to a detached block.

    One copy of this code serves every pass: a partial or streaming check calls
    validate_block directly and the final answer goes through validate_response,
    which calls validate_block for each block, so the two can never disagree.
    """
    if block["type"] == "table" and any(len(row) != len(block["columns"]) for row in block["rows"]):
        raise ValueError("Table row width must match columns")
    if block["type"] == "richtext":
        block["text"] = sanitize_richtext(block["text"])
    if block["type"] == "image" and not block["query"].strip():
        raise ValueError("Image query must name a subject")
    if block["type"] == "sources":
        seen = set()
        for item in block["items"]:
            key = _safe_public_https_url(item["url"])
            if key in seen:
                raise ValueError("Duplicate source URL")
            seen.add(key)
            fragment = urlsplit(item["url"]).fragment
            item["url"] = key + ("#" + fragment if fragment else "")
    if block["type"] == "check":
        if not any(option["correct"] is True for option in block["options"]):
            raise ValueError("A check block needs at least one correct option")
    if block["type"] == "slider":
        control = block["control"]
        if control["min"] >= control["max"]:
            raise ValueError("Slider range must increase")
        control["value"] = min(control["max"], max(control["min"], control["value"]))
        if control["step"] > control["max"] - control["min"]:
            control["step"] = control["max"] - control["min"]
        for readout in block["readouts"]:
            try:
                compile_formula(readout["expression"])
            except FormulaError as exc:
                raise ValueError("Slider expression is invalid: " + str(exc)) from None
        for link in block["links"]:
            try:
                compile_formula(link["expression"])
            except FormulaError as exc:
                raise ValueError("Slider link expression is invalid: " + str(exc)) from None
    if block["type"] == "calc":
        _check_calc(block)
    if block["type"] == "form":
        _check_form(block)
    if block["type"] == "actions":  # the cleaned label IS the follow-up a tap sends, so two must differ
        _check_distinct(block["options"], "label", "Action labels must differ")
    if block["type"] == "compare":
        _check_distinct(block["options"], "name", "Compared option names must differ")
        chosen = False  # more than one recommendation is a sloppy answer, not a broken block: keep the first
        for option in block["options"]:
            option["recommended"], chosen = option["recommended"] and not chosen, chosen or option["recommended"]
    if block["type"] == "chart":
        if len(block["labels"]) != len(block["values"]):
            raise ValueError("Chart labels and values must have matching lengths")
        if block["source"]:
            fragment = urlsplit(block["source"]).fragment
            block["source"] = _safe_public_https_url(block["source"]) + ("#" + fragment if fragment else "")
        elif block["asOf"] != "Provided data":
            raise ValueError("Unsourced chart must identify user-provided data")


def validate_block(block: dict, response_mode="native") -> dict:
    """Return one detached, sanitized block; raise ValueError if it is not a valid block.

    Checks the block against its schema alternative, then applies every per-block
    rule (sanitizing, canonical URLs, clamping, formulas, the calc dry run). The
    input is never mutated. Rules that span blocks (one diagram, link targets,
    the media budget, citations, the byte cap) live in _check_across_blocks and
    _complete, shared by validate_response and normalize_response.
    """
    result = copy.deepcopy(block)
    _sanitize_block_strings(result)
    _validate(result, answer_schema(response_mode)["properties"]["blocks"]["items"])
    if result["type"] == "openui":
        # Bounds only. The isolated Node core parser MUST validate new AND
        # restored programs before native rendering. No regex pretends to parse DSL.
        if len(result["code"].encode("utf-8")) > OPENUI_CODE_LIMIT or not result["code"].strip():
            raise ValueError("OpenUI code exceeds its bounds")
    _finish_block(result)
    return result


class _ByteLimit(ValueError):
    """The finished answer is over the response cap (dropping later blocks may still fit it)."""


# One diagram, slider, calc, form, gallery, actions, compare and timeline per answer; at most two contextual media blocks
# (image, market and gallery together). Both validate_response (raises) and
# normalize_response (drops the later offender) read these, so the rules cannot drift.
_UNIQUE_BLOCKS = ("diagram", "slider", "calc", "form", "gallery", "actions", "compare", "timeline", "openui")
_MEDIA_BLOCKS = ("image", "market", "gallery")
_MAX_MEDIA = 2
_MAX_BLOCKS = ANSWER_SCHEMA["properties"]["blocks"]["maxItems"]
DROPPED_WARNING = "Some parts of this answer could not be shown."


def _check_across_blocks(blocks):
    """The rules that span blocks, over already validated blocks; raise ValueError if broken."""
    diagrams = [entry for entry in blocks if entry["type"] == "diagram"]
    sliders = [entry for entry in blocks if entry["type"] == "slider"]
    if len(diagrams) > 1 or len(sliders) > 1:
        raise ValueError("At most one diagram and one slider per answer")
    if sum(1 for entry in blocks if entry["type"] == "calc") > 1:
        raise ValueError("At most one calc block per answer")
    if sum(1 for entry in blocks if entry["type"] == "form") > 1:
        raise ValueError("At most one form per answer")
    for kind in ("actions", "compare", "timeline", "openui"):
        if sum(1 for entry in blocks if entry["type"] == kind) > 1:
            raise ValueError("At most one %s block per answer" % kind)
    media = [entry for entry in blocks if entry["type"] in _MEDIA_BLOCKS]
    if len(media) > _MAX_MEDIA:
        raise ValueError("At most two contextual media blocks per answer")
    if sum(1 for entry in media if entry["type"] == "gallery") > 1:
        raise ValueError("At most one gallery per answer")
    if sliders and sliders[0]["links"]:
        if not diagrams:
            raise ValueError("Slider links need a diagram to drive")
        part_count = len(diagrams[0]["parts"])
        for link in sliders[0]["links"]:
            if link["part"] >= part_count:
                raise ValueError("Slider link references a missing diagram part")


def _complete(result, response_mode="native"):
    """Cross-block rules, citations and the byte cap over a result whose blocks are validated."""
    _check_across_blocks(result["blocks"])
    _plain_answer_citations(result)
    _validate(result, answer_schema(response_mode))
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise _ByteLimit("Response exceeds byte limit")
    return result


def validate_response(response: dict, response_mode="native") -> dict:
    """Return a detached, sanitized answer; raise ValueError for invalid contracts.

    Strict: ONE bad block, or one broken cross-block rule, rejects the whole answer.
    normalize_response uses _lenient_response instead and shows the rest.
    """
    result = copy.deepcopy(response)
    if type(result) is dict and type(result.get("blocks")) is list:
        for block in result["blocks"]:
            _sanitize_block_strings(block)  # before the caps, exactly as validate_block does
    _validate(result, answer_schema(response_mode))
    result["blocks"] = [validate_block(block, response_mode) for block in result["blocks"]]
    return _complete(result, response_mode)


def _lenient_response(response, response_mode="native"):
    """Return (detached answer, number of dropped blocks); raise ValueError for a bad envelope.

    The envelope (exactly answer, blocks, suggestions; the answer and suggestions within
    their caps; blocks a list) must be valid, or the whole answer is refused like
    validate_response does. Past that, a block that fails validate_block is DROPPED, never
    repaired, and the cross-block rules drop the LATER offender (the first slider, diagram,
    calc, form, gallery, actions, compare or timeline wins; the first two media blocks win; the first six blocks win).
    A slider whose links have no diagram part to drive is dropped too. Citations and the
    byte cap then run over the survivors, shedding trailing blocks until the answer fits.
    The result is exactly what validate_response returns for the surviving blocks alone.
    """
    if type(response) is not dict or type(response.get("blocks")) is not list:
        raise ValueError("Unexpected or missing fields")
    _validate({**response, "blocks": []}, answer_schema(response_mode))
    kept, kinds, media, dropped = [], set(), 0, 0
    for block in response["blocks"]:
        if len(kept) >= _MAX_BLOCKS:
            dropped += 1
            continue
        try:
            clean = validate_block(block, response_mode)
        except (ValueError, RecursionError, OverflowError):
            dropped += 1
            continue
        kind = clean["type"]
        if (kind in _UNIQUE_BLOCKS and kind in kinds) or (kind in _MEDIA_BLOCKS and media >= _MAX_MEDIA):
            dropped += 1
            continue
        kinds.add(kind)
        media += kind in _MEDIA_BLOCKS
        kept.append(clean)
    slider = next((entry for entry in kept if entry["type"] == "slider"), None)
    if slider is not None and slider["links"]:
        diagram = next((entry for entry in kept if entry["type"] == "diagram"), None)
        if diagram is None or any(link["part"] >= len(diagram["parts"]) for link in slider["links"]):
            kept = [entry for entry in kept if entry is not slider]
            dropped += 1
    for count in range(len(kept), -1, -1):
        candidate = {"answer": response["answer"], "blocks": copy.deepcopy(kept[:count]),
                     "suggestions": list(response["suggestions"])}
        try:
            return _complete(candidate, response_mode), dropped + len(kept) - count
        except _ByteLimit:
            if count == 0:
                raise


def _fallback(answer, warning):
    if not isinstance(answer, str):
        answer = "The response could not be displayed safely."
    answer = answer.encode("utf-8", errors="replace").decode("utf-8")
    if len(answer) > MAX_FALLBACK_CHARS:
        answer = answer[:MAX_FALLBACK_CHARS] + "…"
    return {"answer": answer, "blocks": [], "suggestions": [], "warning": warning}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON fields")
        result[key] = value
    return result


def normalize_response(raw: str | bytes, response_mode="native") -> dict:
    """Decode bounded UTF-8 JSON, sanitize blocks, or return a plain-text fallback.

    Always returns answer, blocks, suggestions, warning; warning is empty on success.
    Only one whole-response ```json fence is accepted, not generic Markdown fences.

    Whole-answer plain text is the fallback ONLY for unparseable JSON, a bad envelope
    (top-level shape, answer, suggestions) or an answer that cannot meet the byte cap even
    without blocks. A block that fails validation, or breaks a cross-block rule, is dropped
    on its own: the answer text, suggestions and every valid block stay, and `warning`
    says generically that something could not be shown. validate_response stays strict.
    """
    if not isinstance(raw, (str, bytes)):
        return _fallback(None, "Expected a UTF-8 response.")
    try:
        if isinstance(raw, bytes):
            if len(raw) > MAX_RESPONSE_BYTES:
                return _fallback(None, "Response exceeds byte limit.")
            raw = raw.decode("utf-8", errors="strict")
        if len(raw) > MAX_RESPONSE_BYTES or len(raw.encode("utf-8", errors="strict")) > MAX_RESPONSE_BYTES:
            return _fallback(None, "Response exceeds byte limit.")
    except UnicodeError:
        return _fallback(None, "Response is not valid UTF-8.")
    text = raw.strip()
    fence = re.fullmatch(r"```json[^\S\n]*\n(.*?)\n```", text, flags=re.DOTALL | re.IGNORECASE)
    if fence:
        text = fence.group(1).strip()
    try:
        response = json.loads(text, object_pairs_hook=_unique_object)
    except (ValueError, RecursionError):
        # Never reflect an entire malformed JSON envelope or huge payload to the UI.
        fallback = None if text.startswith(("{", "[", "```")) else text
        return _fallback(fallback, "Response was not valid JSON; showing plain text.")
    try:
        result, dropped = _lenient_response(response, response_mode)
    except (ValueError, RecursionError, OverflowError):
        answer = response.get("answer") if isinstance(response, dict) else None
        return _fallback(answer, "Response did not match the native answer schema.")
    # Generic on purpose: never the model's text or the internal reason.
    result["warning"] = DROPPED_WARNING if dropped else ""
    return result
