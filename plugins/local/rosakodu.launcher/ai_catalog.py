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

from ai_formula import FormulaError, compile_formula

MAX_RESPONSE_BYTES = 65536
MAX_FALLBACK_CHARS = 4096
SCHEMA_PATH = Path(__file__).with_name("ai-answer.schema.json")
ANSWER_SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
JSON_SCHEMA = ANSWER_SCHEMA

SYSTEM_INSTRUCTIONS = """Be concise and answer directly. Prefer a short answer and
one or two useful native blocks whenever structure helps; use more only when
the question needs them. Choose the interface automatically, without asking
the user to request a card: comparisons use a table, plans and packing lists
use an interactive checklist, quantities use metrics, and supplied completion
counts use progress. Keep greetings and simple factual replies text-only.
Choose an image automatically when a visual helps explain a place, landmark,
animal, or visual concept. Use a concrete encyclopedia subject as its query
(for example, "Eiffel Tower" or "Red panda"), not an image URL or HTML.
Images are contextual illustrations, never visual proof of a claim or event.
For a bare animal, landmark, or place topic, write a compact knowledge brief:
identify it, then add one or two useful distinguishing facts in two or three
short sentences. Avoid filler, repeated headings, or blocks added just to fill
space. Keep genuine simple questions and greetings brief.
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
Put the substantive structured content in blocks, not a prose list or a
Markdown table in the answer. The answer should be a brief useful takeaway.
For example, comparing three travel options needs a table; preparing for a
weekend trip needs a checklist; 7 of 10 tasks completed needs a progress block
with value 0.7. Do not fabricate live data or completion counts. If current
information is needed and hosted web search is available, use it before
answering. Cite verified sources in a sources block with short labels and
public HTTPS URLs for clickable citations, rather than raw URLs in text.
For events, use a table of confirmed events with date, venue, and useful
details, plus sources. Never invent listings. If search is unavailable, state
that briefly without implying you searched the web.
Do not add onboarding copy or repeat the answer inside blocks. Suggestions may
be empty. Choose the interface automatically from the subject; never wait for
the user to name a card type, and never settle for a plain paragraph when a
visual vehicle teaches better:
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
Never invent measurements, coordinates for real places, captions, or data; the
visuals are teaching schematics, not evidence. If an attached CSV snapshot is
marked truncated or notes that it is sampled, base any count, average or trend
on the sampled rows shown and say the answer reflects a sample, never the whole
file. Shortened header/cell values are incomplete; never use clipped values
for exact calculations or identifiers. A greeting, a simple fact, or a
short definition stays a short answer with no blocks. At most one of each of
slider, diagram, and gallery per answer; at most two contextual media blocks
(image, market, gallery combined); at most six blocks total.
Return exactly one JSON object matching the supplied schema:
answer is plain text: do not put Markdown links or citation URLs in it; citations
belong in sources blocks. blocks is at most six flat native blocks; suggestions is
at most three short follow-up questions (strings). Include all required fields
and no extra keys. Use text/richtext/code (type,title,text), checklist
(type,title,items), steps (type,title,steps of label,detail), check
(type,title,question,options of label,correct,feedback,explanation), predict
(type,title,prompt,choices,reveal,explanation), diagram
(type,title,caption,aspect,parts of shape,x,y,w,h,label,detail,tone,fill,rotation),
slider (type,title,control of label,min,max,step,value,unit,labels; readouts of
label,expression,unit; links of part,property x|y|w|h|rotation,expression; note),
table (type,title,columns,rows), metric
(type,title,value as string,detail), or progress
(type,title,value as a number from 0 to 1,detail), image (type,title,query),
gallery (type,title,items of query,caption),
market (type,title,symbol,range), sources (type,title,items of label,url), or
chart (type,title,unit,labels,values,source,asOf). Table rows must match the
column count. Rich text permits only b,strong,i,em,u,s,p,br,ul,ol,li,h1,h2,h3,
pre,code without attributes. Never include remote image URLs or image HTML,
resources, HTML links, styles, scripts, nested UI or blocks, commands to execute,
or tool calls in the final JSON. URLs belong only in sources or chart source.
You may use the provided hosted web search tool for live information; no
local command, file editing, or arbitrary filesystem tools are available.
This is an answer-and-inspect interface: never claim to have
inspected a file or system unless its contents were provided. There is no
tool for arbitrary commands. Suggestions are questions, not actions.
The authoritative bounded schema follows:
""" + json.dumps(ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":"))

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


def validate_response(response: dict) -> dict:
    """Return a detached, sanitized answer; raise ValueError for invalid contracts."""
    _validate(response, ANSWER_SCHEMA)
    result = copy.deepcopy(response)
    for block in result["blocks"]:
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
        if block["type"] == "chart":
            if len(block["labels"]) != len(block["values"]):
                raise ValueError("Chart labels and values must have matching lengths")
            if block["source"]:
                fragment = urlsplit(block["source"]).fragment
                block["source"] = _safe_public_https_url(block["source"]) + ("#" + fragment if fragment else "")
            elif block["asOf"] != "Provided data":
                raise ValueError("Unsourced chart must identify user-provided data")
    diagrams = [entry for entry in result["blocks"] if entry["type"] == "diagram"]
    sliders = [entry for entry in result["blocks"] if entry["type"] == "slider"]
    if len(diagrams) > 1 or len(sliders) > 1:
        raise ValueError("At most one diagram and one slider per answer")
    media = [entry for entry in result["blocks"] if entry["type"] in {"image", "market", "gallery"}]
    if len(media) > 2:
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
    _plain_answer_citations(result)
    _validate(result, ANSWER_SCHEMA)
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise ValueError("Response exceeds byte limit")
    return result


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


def normalize_response(raw: str | bytes) -> dict:
    """Decode bounded UTF-8 JSON, sanitize blocks, or return a plain-text fallback.

    Always returns answer, blocks, suggestions, warning; warning is empty on success.
    Only one whole-response ```json fence is accepted, not generic Markdown fences.
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
        result = validate_response(response)
    except (ValueError, RecursionError, OverflowError):
        answer = response.get("answer") if isinstance(response, dict) else None
        return _fallback(answer, "Response did not match the native answer schema.")
    result["warning"] = ""
    return result
