"""Prompt budgets and the compact schema signature.

Run with PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_ai_prompt_budget.py.

History of the full prompt: 16.1 KB before the calc block, 21.5 KB with it, 23.0 KB with the
form block (1.1 KB of that is the form's alternative in the schema dump). The full text is only
the unknown-agent fallback; Codex and Hermes get the variants below, and these budgets are what
a new block has to fit. The section table printed by test_sections_are_listed shows where the
bytes are and what each block type costs in each variant.

2026-10-09: the calc grammar gained "min and max take 2-6 plain values, never a column" (a
column-wide max()/min() used to normalise a score is an engine arity reject; with the softened
normalize_response contract the calculator is dropped, not the answer). The 91 B were paid for
by removing two duplicated sentences (greetings stay text-only is still said once near the end;
the whole-answer fallback warning no longer applies). Codex went 12,000 -> 11,980 B.

2026-10-10 (dynamic UI vocabulary): the actions, compare and timeline blocks. Increments, in bytes:
  codex   11,980 -> 12,694  (+714: 424 guide bullets, 227 caps-table lines, 24 head wording, 39 one-per-answer clause)
  hermes  13,500 -> 14,335  (+835: the same prose + 348 for the three full signature lines)
  full    23,020 -> 25,721  (+2,701: prose + field list + 2 KB of schema alternatives in the dump)
  ai-answer.schema.json (compact) 11,225 -> 13,238 (+2,013)
The guards were raised on purpose: the Codex de-dup (the catalogue travels once as
base_instructions, not once per request) freed about 5.4k tokens per request, so a block that
earns its place can be paid for out of that. A new block must still state its increment here;
`CODEX_OUTPUT_SCHEMA_BUDGET` is new because --output-schema is a second per-request cost that the
prompt budgets do not see.

2026-10-22 (task-first guidance, no schema or budget changes): native interactive objects
lead practical answers; 1-2 orientation sentences do not repeat the tool. Explicit routes
separate qualitative choices, numeric what-if, dense records, timed plans, unknown constraints
and visual exploration. Trimming redundant introduction/examples pays for the policy:
  codex   12,676 -> 12,716 (+40; 284 B spare under 13,000)
  hermes  14,317 -> 14,357 (+40; 643 B spare under 15,000)
  full    25,703 -> 25,743 (+40; 257 B spare under 26,000)
  compact schema unchanged at 13,238 (262 B spare under 13,500)
BLOCK_GUIDE: actions 136 B, compare 135 B, timeline 140 B; each still <= 140 B.
"""

import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ai_catalog_budget", ROOT / "ai_catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)

# Raised deliberately on 2026-10-10 for the actions/compare/timeline blocks (see the docstring):
FULL_BUDGET = 26000      # was 23,100; unknown agents only
CODEX_BUDGET = 13000     # was 12,000; prose + caps table; structure comes from --output-schema
HERMES_BUDGET = 15000    # was 14,000; prose + full compact signature; no structural schema
CODEX_OUTPUT_SCHEMA_BUDGET = 13500  # the compact ai-answer.schema.json Codex receives; was 11,225 B
GUIDE_LINE_BUDGET = 140  # one BLOCK_GUIDE use/not-for line


def size(text):
    return len(text.encode("utf-8"))


def alternatives():
    return catalog.ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"]


# --- an independent reader for the signature grammar ---------------------------------------

class Reader:
    NUMBER = re.compile(r"-?\d+(?:\.\d+)?(?:e\d+)?")
    IDENT = re.compile(r"[A-Za-z0-9_^=.-]+")

    def __init__(self, text):
        self.text, self.at = text, 0

    def peek(self, token):
        return self.text.startswith(token, self.at)

    def take(self, token):
        assert self.peek(token), (token, self.text[self.at:self.at + 30])
        self.at += len(token)

    def number(self):
        match = self.NUMBER.match(self.text, self.at)
        assert match, self.text[self.at:self.at + 30]
        self.at = match.end()
        return float(match.group())

    def integer(self):
        match = re.compile(r"\d+").match(self.text, self.at)
        assert match, self.text[self.at:self.at + 30]
        self.at = match.end()
        return int(match.group())

    def digit_next(self):
        return self.at < len(self.text) and self.text[self.at].isdigit()

    def ident(self):
        match = re.compile(r"[A-Za-z][A-Za-z0-9]*").match(self.text, self.at)
        assert match, self.text[self.at:self.at + 30]
        self.at = match.end()
        return match.group()

    def count(self):
        if self.peek("<="):
            self.take("<=")
            return 0, self.integer()
        low = self.integer()
        self.take("..")
        return low, self.integer()

    def spec(self):
        if self.peek("str") and not self.text[self.at + 3:self.at + 4].isalpha():
            self.take("str")
            low, high, pattern = 0, None, None
            if self.peek("<="):
                self.take("<=")
                high = self.integer()
            elif self.digit_next():
                low = self.integer()
                self.take("..")
                high = self.integer() if self.digit_next() else None
            if self.peek("/"):
                self.take("/")
                end = self.text.index("/", self.at)
                pattern, self.at = self.text[self.at:end], end + 1
            return ("str", low, high, pattern)
        for kind in ("num", "int"):
            if self.peek(kind + "[") or self.peek(kind + "("):
                self.take(kind)
                exclusive = self.peek("(")
                self.at += 1
                low = None if self.peek("..") else self.number()
                self.take("..")
                high = None if self.peek("]") else self.number()
                self.take("]")
                return (kind, low, high, exclusive)
        if self.peek("bool"):
            self.take("bool")
            return ("bool",)
        if self.peek("["):
            self.take("[")
            inner = None if self.peek("]") else self.spec()
            self.take("]")
            low, high = self.count()
            return ("arr", inner, low, high)
        if self.peek("{"):
            return self.obj()
        values = [self.IDENT.match(self.text, self.at)]
        assert values[0], self.text[self.at:self.at + 30]
        self.at = values[0].end()
        names = [values[0].group()]
        while self.peek("|"):
            self.take("|")
            match = self.IDENT.match(self.text, self.at)
            self.at = match.end()
            names.append(match.group())
        return ("enum", tuple(names))

    def obj(self):
        self.take("{")
        entries = []
        while not self.peek("}"):
            names = [self.ident()]
            while self.peek(","):
                self.take(",")
                names.append(self.ident())
            self.take(":")
            spec = self.spec()
            entries.extend((name, spec) for name in names)
            if self.peek(","):
                self.take(",")
        self.take("}")
        return ("obj", tuple(entries))


def parse_signature(text):
    lines = text.split("\n")
    header = lines.index("BLOCK is one of:")
    root = Reader(lines[header - 1])
    parsed_root = root.obj()
    assert root.at == len(root.text)
    blocks = []
    for line in lines[header + 1:]:
        reader = Reader(line)
        kinds = reader.spec()
        assert kinds[0] == "enum", line
        body = reader.obj() if reader.peek("{") else ("obj", ())
        assert reader.at == len(line), line
        blocks.append((kinds[1], body))
    return parsed_root, blocks


def constrained(node):
    """What the caps view must keep: anything with a size, a range, a choice or a non-empty rule."""
    if "enum" in node or node["type"] in ("number", "integer", "array"):
        return True
    if node["type"] == "string":
        return node.get("minLength", 0) > 0 and "pattern" not in node
    return node["type"] == "object" and any(constrained(child) for child in node["properties"].values())


def expected(node, caps):
    if "enum" in node:
        return ("enum", tuple(node["enum"]))
    kind = node["type"]
    if kind == "string":
        if caps:
            return ("str", 1 if node.get("minLength") else 0, None, None)
        return ("str", node.get("minLength", 0), node.get("maxLength"), node.get("pattern"))
    if kind in ("number", "integer"):
        exclusive = "exclusiveMinimum" in node
        low = node["exclusiveMinimum"] if exclusive else node.get("minimum")
        high = node.get("maximum")
        return ("num" if kind == "number" else "int", None if low is None else float(low),
                None if high is None else float(high), exclusive)
    if kind == "boolean":
        return ("bool",)
    if kind == "array":
        inner = node["items"]
        return ("arr", expected(inner, caps) if not caps or constrained(inner) else None,
                node.get("minItems", 0), node["maxItems"])
    entries = [(name, expected(child, caps)) for name, child in node["properties"].items()
               if not caps or constrained(child)]
    return ("obj", tuple(entries))


def normalize_numbers(value):
    """Both sides carry ints for counts and floats for ranges; compare ranges as floats."""
    if isinstance(value, tuple):
        if value and value[0] in ("num", "int"):
            return (value[0], None if value[1] is None else float(value[1]),
                    None if value[2] is None else float(value[2]), value[3])
        return tuple(normalize_numbers(item) for item in value)
    return value


class SignatureTests(unittest.TestCase):
    def check_mode(self, caps):
        text = catalog.compact_signature(caps=caps)
        root, blocks = parse_signature(text)
        schema = catalog.ANSWER_SCHEMA
        top = copy.deepcopy(schema["properties"])
        top["blocks"]["items"] = {"type": "string", "enum": ["BLOCK"]}
        self.assertEqual(normalize_numbers(root), normalize_numbers(
            expected({"type": "object", "properties": top}, caps)))
        self.assertEqual(len(blocks), len(alternatives()))
        for (kinds, body), alternative in zip(blocks, alternatives()):
            properties = dict(alternative["properties"])
            self.assertEqual(kinds, tuple(properties.pop("type")["enum"]))
            with self.subTest(block=kinds, caps=caps):
                self.assertEqual(normalize_numbers(body), normalize_numbers(
                    expected({"type": "object", "properties": properties}, caps)))
        return text

    def test_the_full_signature_carries_every_name_enum_and_limit(self):
        text = self.check_mode(caps=False)
        # Belt and braces next to the structural comparison: every property name and enum
        # value of every block type is literally present.
        def walk(node):
            if "enum" in node:
                for value in node["enum"]:
                    self.assertIn(value, text)
            for name, child in node.get("properties", {}).items():
                self.assertIn(name, text)
                walk(child)
            if "items" in node:
                walk(node["items"])
        for alternative in alternatives():
            walk(alternative)
        # Required fields: the schema says every property is required, and the legend says so.
        self.assertIn("every field is required, no extra keys", text)

    def test_the_caps_signature_carries_every_size_range_and_choice(self):
        text = self.check_mode(caps=True)
        self.assertNotIn("<=160", text, "caps leave out string lengths")
        self.assertNotIn("answer:", text)
        # Every block type is still named, even those with nothing to cap.
        for alternative in alternatives():
            for value in alternative["properties"]["type"]["enum"]:
                self.assertRegex(text, r"(?m)^(?:[a-z]+\|)*" + value + r"(?:\||\{|$)")

    def test_the_new_block_types_are_in_both_signatures_with_their_caps(self):
        caps = catalog.compact_signature(caps=True).split("\n")
        full = catalog.compact_signature().split("\n")
        wanted = {
            "actions": ("actions{title:str1..,options:[{label:str1..}]2..6}",
                        "actions{title:str1..160,options:[{label:str1..40,hint:str<=60}]2..6}"),
            "compare": ("compare{title:str1..,options:[{name:str1..,facts:[{label,value:str1..}]<=4,"
                        "pros,cons:[str1..]<=4}]2..4}",
                        "compare{title:str1..160,options:[{name:str1..48,summary:str<=120,"
                        "facts:[{label:str1..24,value:str1..40}]<=4,pros,cons:[str1..70]<=4,recommended:bool}]2..4,"
                        "verdict:str<=240}"),
            "timeline": ("timeline{title:str1..,items:[{label:str1..,minutes:int[0..1440]}]2..16}",
                         "timeline{title:str1..160,items:[{label:str1..80,when:str<=24,minutes:int[0..1440],"
                         "detail:str<=160}]2..16}"),
        }
        for kind, (short, long) in wanted.items():
            with self.subTest(kind=kind):
                self.assertIn(short, caps)
                self.assertIn(long, full)
                self.assertIn(short, catalog.CODEX_INSTRUCTIONS)
                self.assertIn(long, catalog.HERMES_INSTRUCTIONS)
        # The field list is the full prompt's own naming of every field.
        for entry in ("actions (type,title,options of label,hint)", "timeline (type,title,items of label,when,minutes,detail)"):
            self.assertIn(entry, catalog.SYSTEM_INSTRUCTIONS)
        flat = " ".join(catalog._FIELD_LIST.split())
        self.assertIn("compare (type,title,options of name,summary,facts of label,value; pros,cons,recommended; verdict)", flat)

    def test_signatures_are_deterministic_and_ascii(self):
        for caps in (False, True):
            first = catalog.compact_signature(caps=caps)
            self.assertEqual(first, catalog.compact_signature(caps=caps))
            self.assertEqual(first, first.encode("ascii").decode("ascii"))

    def test_the_parser_notices_a_dropped_limit(self):
        # Mutation check for the completeness test itself: a signature that lost one cap
        # (calc rows <= 40 rows) must not compare equal.
        text = catalog.compact_signature()
        damaged = text.replace("rows:[[str<=64]<=12]1..40", "rows:[[str<=64]<=12]1..39")
        self.assertNotEqual(text, damaged)
        _, blocks = parse_signature(damaged)
        calc = next(body for kinds, body in blocks if kinds == ("calc",))
        reference = next(alt for alt in alternatives() if alt["properties"]["type"]["enum"] == ["calc"])
        properties = {key: value for key, value in reference["properties"].items() if key != "type"}
        self.assertNotEqual(normalize_numbers(calc), normalize_numbers(
            expected({"type": "object", "properties": properties}, False)))

    def test_an_unknown_schema_keyword_is_refused_not_dropped(self):
        schema = copy.deepcopy(catalog.ANSWER_SCHEMA)
        schema["properties"]["answer"]["format"] = "uri"
        for caps in (False, True):
            with self.assertRaises(ValueError):
                catalog.compact_signature(schema, caps=caps)
        loose = copy.deepcopy(catalog.ANSWER_SCHEMA)
        del loose["properties"]["blocks"]["items"]["anyOf"][0]["required"][1]  # "title" no longer required
        with self.assertRaises(ValueError):
            catalog.compact_signature(loose)


class PromptVariantTests(unittest.TestCase):
    PINNED = ("answer-and-inspect", "no\ntool for arbitrary commands", "concrete encyclopedia subject",
              "never visual proof", "actual\nticker symbol", "Provided data", "rather than raw URLs in text",
              'Only when the request carries a "Full-source statistics" section',
              "Worked example: ", "At most one of each of",
              "min and max take 2-6 plain values, never a column:")

    def test_agent_selection(self):
        self.assertIs(catalog.system_instructions("codex"), catalog.CODEX_INSTRUCTIONS)
        self.assertIs(catalog.system_instructions("hermes"), catalog.HERMES_INSTRUCTIONS)
        for other in (None, "", "claude", "CODEX", "codex ", [], {}, 7):
            self.assertIs(catalog.system_instructions(other), catalog.SYSTEM_INSTRUCTIONS)
        self.assertIs(catalog.system_instructions(), catalog.SYSTEM_INSTRUCTIONS)

    def test_every_variant_keeps_the_prose_rules_and_the_calc_example(self):
        example = json.dumps(catalog.CALC_EXAMPLE, ensure_ascii=False, separators=(",", ":"))
        for name, text in (("full", catalog.SYSTEM_INSTRUCTIONS), ("codex", catalog.CODEX_INSTRUCTIONS),
                           ("hermes", catalog.HERMES_INSTRUCTIONS)):
            with self.subTest(variant=name):
                for phrase in self.PINNED:
                    self.assertIn(phrase, text)
                self.assertIn("Worked example: " + example, text)
                flat = " ".join(text.split())
                self.assertIn("-> one form block of 1-6 fields", flat)
                self.assertIn("calc (type,title,inputs,tables,cells,note)," if name == "full" else "calc", flat)
                self.assertNotIn("colstat", flat)

    def test_only_the_full_text_carries_the_schema_dump(self):
        dump = json.dumps(catalog.ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":"))
        self.assertIn(dump, catalog.SYSTEM_INSTRUCTIONS)
        for text in (catalog.CODEX_INSTRUCTIONS, catalog.HERMES_INSTRUCTIONS):
            self.assertNotIn('"additionalProperties"', text)
            self.assertNotIn("$schema", text)
            self.assertNotIn("The authoritative bounded schema", text)
        self.assertIn(catalog.compact_signature(), catalog.HERMES_INSTRUCTIONS)
        self.assertIn(catalog.compact_signature(caps=True), catalog.CODEX_INSTRUCTIONS)
        # The field list is the full text's duplicate of the structure; the variants replace it.
        for text in (catalog.CODEX_INSTRUCTIONS, catalog.HERMES_INSTRUCTIONS):
            self.assertNotIn("Use text/richtext/code (type,title,text)", text)

    def test_the_variants_do_not_drift_from_the_full_prose(self):
        # Same head, example and rules text in every variant: a rule is stated once.
        pieces = (catalog._INSTRUCTIONS_HEAD, catalog._CALC_EXAMPLE_JSON, catalog._INSTRUCTIONS_BODY.rstrip(" "),
                  catalog._INSTRUCTIONS_RULES)
        for text in (catalog.SYSTEM_INSTRUCTIONS, catalog.CODEX_INSTRUCTIONS, catalog.HERMES_INSTRUCTIONS):
            position = 0
            for piece in pieces:
                found = text.find(piece, position)
                self.assertGreaterEqual(found, position)
                position = found + len(piece)


class TaskFirstGuidanceTests(unittest.TestCase):
    """Pin decision boundaries and prose roles, not just the presence of block names.

    These are offline prompt-contract checks, not claims about provider output quality.
    """

    def variants(self):
        for name in ("codex", "hermes", "full"):
            yield name, " ".join(catalog.system_instructions(name).split())

    def test_practical_task_intents_lead_before_media_or_serialization(self):
        policy = ("For practical tasks, make the primary native interactive object the answer: "
                  "help the person decide, plan, calculate or explore. "
                  "Put it first in blocks; add only useful supporting blocks.")
        for name, text in self.variants():
            with self.subTest(variant=name):
                self.assertTrue(text.startswith("Design for the task, not a flat document. " + policy))
                self.assertLess(text.index(policy), text.index("Choose an image automatically"))
                self.assertLess(text.index(policy), text.index("Return exactly one JSON object"))
                self.assertNotIn("Prefer a short answer and one or two useful native blocks", text)

    def test_answer_orients_instead_of_duplicating_the_tool(self):
        orientation = ("Use answer for 1-2 sentences of orientation, not a second prose answer "
                       "repeating the tool's contents.")
        support = "Keep explanations and source notes terse and subordinate to the tool."
        structure = "Put structured content in blocks, not a prose list or Markdown table in the answer."
        for name, text in self.variants():
            with self.subTest(variant=name):
                for clause in (orientation, support, structure):
                    self.assertEqual(text.count(clause), 1, clause)
                self.assertNotIn("The answer should be a brief useful takeaway.", text)

    def test_qualitative_numeric_and_dense_comparisons_have_distinct_routes(self):
        routing = ("2-4 qualitative options -> one compare block with trade-offs; "
                   "editable numeric weights -> calc; dense many-record comparisons -> table.")
        numeric_only = ("Only numeric what-if or weighted calculations with meaningful editable inputs, "
                        "not qualitative choices -> one calc block: numeric inputs")
        self.assertEqual(catalog.BLOCK_GUIDE["compare"], routing)
        for name, text in self.variants():
            with self.subTest(variant=name):
                self.assertIn(routing, text)
                self.assertIn(numeric_only, text)
                self.assertNotIn("many rows or numbers: table", text)

    def test_timed_plans_precede_follow_up_actions_not_execution(self):
        plan = ("Schedule, itinerary, route or recipe -> one timeline (2-16 items) with clear "
                "when/duration and next step, not a checklist; processes: steps.")
        action = ("2-6 next steps after compare/timeline -> one actions block; a tap sends its label "
                  "as a follow-up, never executes it; typed values: form.")
        self.assertEqual(catalog.BLOCK_GUIDE["timeline"], plan)
        self.assertEqual(catalog.BLOCK_GUIDE["actions"], action)
        for name, text in self.variants():
            with self.subTest(variant=name):
                self.assertIn(plan, text)
                self.assertIn(action, text)

    def test_unknown_constraints_and_visual_exploration_are_not_calculators(self):
        constraints = ("Several typed answers to resolve unknown constraints for ONE follow-up "
                       "-> one form block of 1-6 fields")
        exploration = ("For visual exploration, choose a gallery or diagram, with a coupled slider "
                       "only when changing a number teaches something:")
        for name, text in self.variants():
            with self.subTest(variant=name):
                self.assertIn(constraints, text)
                self.assertIn("Not for numbers varied to see an effect (calc) or a quiz (check, predict).", text)
                self.assertIn(exploration, text)
                self.assertIn("Make the diagram respond by adding links on the slider:", text)

    def test_simple_answers_and_supported_controls_are_honest(self):
        simple = "A greeting, a simple fact, or a short definition stays a short answer with no blocks."
        supported = ("Use only supported controls and bindings; never imply they "
                     "change unrelated blocks or perform external actions.")
        data = ("Never invent metrics, scores, live data or completion counts "
                "to decorate an interface.")
        for name, text in self.variants():
            with self.subTest(variant=name):
                for clause in (simple, supported, data, "No arbitrary HTML/JS or executable layouts."):
                    self.assertIn(clause, text)


class BudgetTests(unittest.TestCase):
    def test_budgets(self):
        sizes = {"full": size(catalog.SYSTEM_INSTRUCTIONS), "codex": size(catalog.CODEX_INSTRUCTIONS),
                 "hermes": size(catalog.HERMES_INSTRUCTIONS),
                 "codexOutputSchema": size(json.dumps(catalog.ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":")))}
        self.assertLessEqual(sizes["codexOutputSchema"], CODEX_OUTPUT_SCHEMA_BUDGET, sizes)
        self.assertLessEqual(sizes["full"], FULL_BUDGET, sizes)
        self.assertLessEqual(sizes["codex"], CODEX_BUDGET, sizes)
        self.assertLessEqual(sizes["hermes"], HERMES_BUDGET, sizes)
        self.assertLess(sizes["codex"], sizes["hermes"])
        self.assertLess(sizes["hermes"], sizes["full"])

    def test_sections_are_listed(self):
        """Prints each section's size and each block type's increment (run with -v to read it)."""
        dump = json.dumps(catalog.ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":"))
        parts = [("head prose", size(catalog._INSTRUCTIONS_HEAD)),
                 ("calc worked example", size(catalog._CALC_EXAMPLE_JSON)),
                 ("block bullets + rules", size(catalog._INSTRUCTIONS_BODY)),
                 ("  of which BLOCK_GUIDE bullets", size(catalog._GUIDE_BULLETS)),
                 ("field list (full only)", size(catalog._FIELD_LIST)),
                 ("closing rules", size(catalog._INSTRUCTIONS_RULES)),
                 ("schema dump (full only)", size(dump)),
                 ("compact signature (hermes)", size(catalog.compact_signature())),
                 ("caps table (codex)", size(catalog.compact_signature(caps=True)))]
        lines = ["", "prompt sections (bytes)"] + ["  %-30s %6d" % item for item in parts]
        lines.append("  %-30s %6d  (budget %d)" % ("TOTAL full", size(catalog.SYSTEM_INSTRUCTIONS), FULL_BUDGET))
        lines.append("  %-30s %6d  (budget %d)" % ("TOTAL codex", size(catalog.CODEX_INSTRUCTIONS), CODEX_BUDGET))
        lines.append("  %-30s %6d  (budget %d)" % ("TOTAL hermes", size(catalog.HERMES_INSTRUCTIONS), HERMES_BUDGET))
        lines.append("  %-30s %6d  (budget %d)" % ("output schema (compact)", size(dump), CODEX_OUTPUT_SCHEMA_BUDGET))
        full_lines = catalog.compact_signature().split("\n")[3:]
        caps_lines = catalog.compact_signature(caps=True).split("\n")[3:]
        lines.append("per block type: dump / hermes line / codex line")
        for alternative, hermes, codex in zip(alternatives(), full_lines, caps_lines):
            lines.append("  %-18s %5d %5d %5d" % ("|".join(alternative["properties"]["type"]["enum"]),
                         size(json.dumps(alternative, ensure_ascii=False, separators=(",", ":"))) + 1,
                         size(hermes) + 1, size(codex) + 1))
        text = catalog.SYSTEM_INSTRUCTIONS
        form = text[text.index("- Several typed answers"):text.index(catalog._GUIDE_BULLETS)]
        listed = catalog._FIELD_LIST
        entry = listed[listed.index("form (type"):listed.index("submitLabel,note),") + len("submitLabel,note),\n")]
        lines.append("form catalog prose: %d bytes + %d in the full field list + %d for the one-form clause"
                     % (size(form), size(entry), size("at most one form; ")))
        for kind, line in catalog.BLOCK_GUIDE.items():
            lines.append("BLOCK_GUIDE %-9s %3d bytes (limit %d)" % (kind, size(line), GUIDE_LINE_BUDGET))
        print("\n".join(lines))
        self.assertTrue(all(value > 0 for _, value in parts))

    def test_block_guide_lines_are_short_ascii_and_all_in_every_prompt(self):
        self.assertEqual(list(catalog.BLOCK_GUIDE), ["actions", "compare", "timeline"])
        types = {value for alt in alternatives() for value in alt["properties"]["type"]["enum"]}
        for kind, line in catalog.BLOCK_GUIDE.items():
            with self.subTest(kind=kind):
                self.assertIn(kind, types)
                self.assertLessEqual(size(line), GUIDE_LINE_BUDGET)
                self.assertEqual(line, line.encode("ascii").decode("ascii"))
                self.assertNotIn("\n", line)
                self.assertIn("one %s" % ("timeline" if kind == "timeline" else kind + " block"), line)
                for text in (catalog.SYSTEM_INSTRUCTIONS, catalog.CODEX_INSTRUCTIONS, catalog.HERMES_INSTRUCTIONS):
                    self.assertIn("- " + line + "\n", text)


if __name__ == "__main__":
    unittest.main()
