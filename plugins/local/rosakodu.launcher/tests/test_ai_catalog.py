"""Run with PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p test_ai_catalog.py."""

import copy
from html.parser import HTMLParser
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ai_catalog", ROOT / "ai_catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def answer(blocks=None):
    return {"answer": "Readable answer \u2713", "blocks": blocks or [], "suggestions": ["Explain more?"]}


def chart():
    return {"type": "chart", "title": "Measured counts", "unit": "items",
            "labels": ["Monday", "Tuesday"], "values": [2, 3.5],
            "source": "https://example.com/dataset", "asOf": "2026-10-03"}


class CatalogTests(unittest.TestCase):
    def test_markdown_citations_become_native_sources_not_answer_noise(self):
        raw = answer([{"type": "image", "title": "Blue whale", "query": "Blue whale"}])
        raw["answer"] = "The blue whale can grow to about 110 feet long. ([fisheries.noaa.gov](https://www.fisheries.noaa.gov/species/blue-whale?page=1&utm_source=openai))"
        result = catalog.validate_response(raw)
        self.assertEqual(result["answer"], "The blue whale can grow to about 110 feet long.")
        self.assertEqual(result["blocks"][-1]["type"], "sources")
        self.assertEqual(result["blocks"][-1]["items"][0]["label"], "fisheries.noaa.gov")
        self.assertIn("https://www.fisheries.noaa.gov/", result["blocks"][-1]["items"][0]["url"])
        self.assertNotIn("utm_source", result["blocks"][-1]["items"][0]["url"])
        self.assertIn("[fisheries.noaa.gov]", raw["answer"])

    def test_existing_sources_are_not_duplicated_by_answer_citations(self):
        raw = answer([{"type": "sources", "title": "Sources", "items": [{"label": "Reference", "url": "https://example.com/data"}]}])
        raw["answer"] = "Read [the reference](https://example.com/data?utm_source=openai)."
        result = catalog.validate_response(raw)
        self.assertEqual(result["answer"], "Read the reference.")
        self.assertEqual(len(result["blocks"]), 1)
        self.assertEqual(len(result["blocks"][0]["items"]), 1)

    def test_unsafe_markdown_citation_is_never_turned_into_a_button(self):
        raw = answer([])
        raw["answer"] = "Read [reference](https://localhost/private)."
        result = catalog.validate_response(raw)
        self.assertEqual(result["answer"], "Read reference.")
        self.assertEqual(result["blocks"], [])

    def normalize(self, value):
        return catalog.normalize_response(json.dumps(value, ensure_ascii=False))

    def assert_whole_fallback(self, value):
        """The envelope itself is broken (extra/missing top-level keys, answer or suggestion
        caps): this is still the whole-answer plain-text fallback."""
        result = self.normalize(value)
        self.assertEqual(result["warning"], "Response did not match the native answer schema.")
        self.assertEqual(result["blocks"], [])
        self.assertEqual(result["suggestions"], [])
        self.assertEqual(result["answer"], value.get("answer", "The response could not be displayed safely."))

    def assert_block_dropped(self, value):
        """Softened contract (2026-10-09): the only block is invalid, so normalize_response drops
        it and keeps the answer text and suggestions with the generic warning, while the strict
        validate_response still raises for the very same input."""
        result = self.normalize(value)
        self.assertEqual(result, {"answer": value["answer"], "blocks": [],
                                  "suggestions": value["suggestions"], "warning": catalog.DROPPED_WARNING})
        with self.assertRaises(ValueError):
            catalog.validate_response(value)

    def test_shared_schema_and_strict_objects(self):
        disk = json.loads((ROOT / "ai-answer.schema.json").read_text())
        self.assertEqual(catalog.OPENUI_ANSWER_SCHEMA, disk)
        native = {**disk, "properties": {**disk["properties"], "blocks": {
            **disk["properties"]["blocks"], "items": {"anyOf": [
                item for item in disk["properties"]["blocks"]["items"]["anyOf"]
                if item["properties"]["type"]["enum"] != ["openui"]]}}}}
        self.assertEqual(catalog.ANSWER_SCHEMA, native)
        self.assertIs(catalog.JSON_SCHEMA, catalog.ANSWER_SCHEMA)

        def walk(node):
            if isinstance(node, dict):
                if node.get("type") == "object":
                    self.assertIs(node["additionalProperties"], False)
                    self.assertEqual(set(node["required"]), set(node["properties"]))
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(catalog.ANSWER_SCHEMA)
        walk(catalog.OPENUI_ANSWER_SCHEMA)

    def learning_blocks(self):
        return [
            {"type": "steps", "title": "Season cycle", "steps": [
                {"label": "Earth orbits the Sun", "detail": "One orbit takes a year."},
                {"label": "The axis stays tilted", "detail": ""},
                {"label": "Light angle shifts", "detail": "Seasons follow the angle."}]},
            {"type": "check", "title": "Quick check", "question": "Why is June warm in the north?",
             "options": [
                 {"label": "The north leans toward the Sun", "correct": True, "feedback": "Right: the tilt, not distance."},
                 {"label": "Earth is closest to the Sun", "correct": False, "feedback": "Distance is not the cause."}],
             "explanation": "Axial tilt changes the sunlight angle."},
            {"type": "predict", "title": "Predict", "prompt": "Which hemisphere is warmer in January?",
             "choices": ["Northern", "Southern"], "reveal": "The Southern Hemisphere.",
             "explanation": "January is southern summer."}
        ]

    def test_learning_blocks_validate_and_round_trip(self):
        raw = answer(self.learning_blocks())
        result = catalog.validate_response(raw)
        self.assertEqual([block["type"] for block in result["blocks"]], ["steps", "check", "predict"])
        self.assertEqual(result["blocks"][0]["steps"][1]["detail"], "")
        self.assertTrue(result["blocks"][1]["options"][0]["correct"])

    def test_check_requires_a_correct_option(self):
        block = self.learning_blocks()[1]
        for option in block["options"]:
            option["correct"] = False
        self.assert_block_dropped(answer([block]))

    def test_check_correct_must_be_boolean_and_steps_bounded(self):
        block = self.learning_blocks()[1]
        block["options"][0]["correct"] = "yes"
        self.assert_block_dropped(answer([block]))
        self.assert_block_dropped(answer([{"type": "steps", "title": "Too short", "steps": [
            {"label": "Only one", "detail": ""}]}]))

    def diagram_block(self):
        return {"type": "diagram", "title": "Seasons schematic", "caption": "Schematic, not to scale.",
                "aspect": 1.6, "parts": [
                    {"shape": "circle", "x": 18, "y": 38, "w": 22, "h": 22, "label": "Sun",
                     "detail": "The Sun is the light source.", "tone": "accent", "fill": True, "rotation": 0},
                    {"shape": "circle", "x": 62, "y": 36, "w": 12, "h": 12, "label": "Earth",
                     "detail": "Its axis stays tilted through the orbit.", "tone": "foreground", "fill": False, "rotation": 0},
                    {"shape": "line", "x": 66, "y": 42, "w": -4, "h": 16, "label": "Axis", "detail": "",
                     "tone": "muted", "fill": False, "rotation": 0},
                    {"shape": "arrow", "x": 40, "y": 49, "w": 20, "h": -6, "label": "", "detail": "",
                     "tone": "accent", "fill": False, "rotation": 0},
                    {"shape": "text", "x": 6, "y": 6, "w": 40, "h": 7, "label": "June: the north leans sunward",
                     "detail": "", "tone": "foreground", "fill": False, "rotation": 0}]}

    def test_diagram_validates_with_selectable_parts(self):
        result = catalog.validate_response(answer([self.diagram_block()]))
        self.assertEqual(result["blocks"][0]["type"], "diagram")
        self.assertEqual(len(result["blocks"][0]["parts"]), 5)
        self.assertTrue(result["blocks"][0]["parts"][0]["fill"])

    def test_diagram_rejects_unknown_shapes_and_out_of_range_parts(self):
        block = self.diagram_block()
        block["parts"][0]["shape"] = "sparkle"
        self.assert_block_dropped(answer([block]))
        block = self.diagram_block()
        block["parts"][1]["x"] = 140
        self.assert_block_dropped(answer([block]))
        block = self.diagram_block()
        block["parts"] = [dict(block["parts"][0]) for _ in range(25)]
        self.assert_block_dropped(answer([block]))
        block = self.diagram_block()
        del block["parts"][0]["tone"]
        self.assert_block_dropped(answer([block]))

    def slider_block(self):
        return {"type": "slider", "title": "Noon sun angle", "note": "Approximate; ignores refraction.",
                "control": {"label": "Month", "min": 0, "max": 11, "step": 1, "value": 5, "unit": "",
                            "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]},
                "readouts": [
                    {"label": "Noon angle at 49N", "expression": "90 - abs(x - 5.5) * 8", "unit": "\u00b0"},
                    {"label": "Daylight shared", "expression": "clamp(0.5 + (x - 5.5) * 0.085, 0.25, 0.75) * 24", "unit": "h"}],
                "links": []}

    def test_slider_validates_clamps_and_rejects_bad_formulas(self):
        result = catalog.validate_response(answer([self.slider_block()]))
        self.assertEqual(result["blocks"][0]["type"], "slider")
        self.assertEqual(result["blocks"][0]["control"]["value"], 5)
        block = self.slider_block()
        block["control"]["value"] = 99
        result = catalog.validate_response(answer([block]))
        self.assertEqual(result["blocks"][0]["control"]["value"], 11, "values clamp into range")
        block = self.slider_block()
        block["control"]["min"] = 12
        self.assert_block_dropped(answer([block]))
        block = self.slider_block()
        block["readouts"][0]["expression"] = "x.__class__"
        self.assert_block_dropped(answer([block]))
        block = self.slider_block()
        block["readouts"][0]["expression"] = "import(x)"
        self.assert_block_dropped(answer([block]))
        block = self.slider_block()
        block["control"]["step"] = 0
        self.assert_block_dropped(answer([block]))

    def test_gallery_bounds_and_media_budget(self):
        gallery = {"type": "gallery", "title": "Styles", "items": [
            {"query": "Gothic", "caption": "Pointed arches"},
            {"query": "Romanesque", "caption": "Round arches"}]}
        result = catalog.validate_response(answer([gallery]))
        self.assertEqual(result["blocks"][0]["type"], "gallery")
        image = {"type": "image", "title": "x", "query": "y"}
        market = {"type": "market", "title": "z", "symbol": "AAPL", "range": "1mo"}
        # Softened contract: the strict validator still raises for a second gallery or a third
        # media block, while normalize_response keeps the first and drops only the later extra.
        for extras in ([gallery, gallery], [gallery, image, market]):
            with self.assertRaises(ValueError):
                catalog.validate_response(answer(extras))
        result = self.normalize(answer([gallery, gallery]))
        self.assertEqual((result["blocks"], result["warning"]), ([gallery], catalog.DROPPED_WARNING))
        result = self.normalize(answer([gallery, image, market]))
        self.assertEqual((result["blocks"], result["warning"]), ([gallery, image], catalog.DROPPED_WARNING))
        self.assert_block_dropped(answer([{"type": "gallery", "title": "One",
                                     "items": [{"query": "a", "caption": "b"}]}]))

    def test_slider_links_pair_with_the_diagram(self):
        diagram = self.diagram_block()

        def kept(*blocks):
            """Softened contract: the strict validator raises, normalize_response drops only the
            offender; this returns the surviving blocks of a lenient run (after checking both)."""
            value = answer(list(blocks))
            with self.assertRaises(ValueError):
                catalog.validate_response(value)
            result = self.normalize(value)
            self.assertEqual((result["answer"], result["suggestions"], result["warning"]),
                             (value["answer"], value["suggestions"], catalog.DROPPED_WARNING))
            return result["blocks"]

        block = self.slider_block()
        block["links"] = [{"part": 1, "property": "rotation", "expression": "x*15"}]
        # A link without a paired diagram is meaningless: the slider is dropped.
        self.assertEqual(kept(block), [])
        self.assertEqual(kept(block, {"type": "text", "title": "", "text": "after"}),
                         [{"type": "text", "title": "", "text": "after"}])
        result = catalog.validate_response(answer([diagram, block]))
        self.assertEqual(result["blocks"][1]["links"][0]["expression"], "x*15")
        # Out-of-range part: the slider is dropped, the diagram stays.
        block = self.slider_block()
        block["links"] = [{"part": 9, "property": "x", "expression": "x"}]
        self.assertEqual(kept(diagram, block), [diagram])
        # Unknown property and non-arithmetic expression: each is an invalid block of its own.
        block = self.slider_block()
        block["links"] = [{"part": 0, "property": "opacity", "expression": "x"}]
        self.assertEqual(kept(diagram, block), [diagram])
        block = self.slider_block()
        block["links"] = [{"part": 0, "property": "x", "expression": "window.x"}]
        self.assertEqual(kept(diagram, block), [diagram])
        # One slider and one diagram per answer keeps the pairing unambiguous: the first wins.
        other = self.slider_block()
        other["title"] = "Second slider"
        self.assertEqual(kept(self.slider_block(), other), [self.slider_block()])
        second = self.diagram_block()
        second["title"] = "Second diagram"
        self.assertEqual(kept(diagram, second), [diagram])
        # An invalid diagram takes its slider's links with it (nothing to drive), the slider
        # is not repaired by stripping the links.
        broken = self.diagram_block()
        broken["parts"][0]["shape"] = "sparkle"
        linked = self.slider_block()
        linked["links"] = [{"part": 0, "property": "rotation", "expression": "x*15"}]
        self.assertEqual(kept(broken, linked), [])

    def test_every_block_kind(self):
        blocks = [
            {"type": kind, "title": "Title", "text": "<b>text</b>"}
            for kind in ("text", "richtext", "code")
        ] + [
            {"type": "checklist", "title": "Tasks", "items": ["One", "Two"]},
            {"type": "table", "title": "Table", "columns": ["A", "B"], "rows": [["1", "2"]]},
            {"type": "metric", "title": "Count", "value": "12", "detail": "items"},
            {"type": "progress", "title": "Progress", "value": 0.5, "detail": "Half"},
            {"type": "image", "title": "Red panda", "query": "Red panda"},
            {"type": "market", "title": "S&P 500", "symbol": "^GSPC", "range": "1mo"},
            {"type": "sources", "title": "Sources", "items": [{"label": "Dataset", "url": "https://example.com/dataset"}]},
            chart(),
        ]
        for block in blocks:
            with self.subTest(kind=block["type"]):
                result = self.normalize(answer([block]))
                self.assertEqual(result["warning"], "")
                self.assertEqual(result["blocks"], [block])
        self.assertEqual(self.normalize(answer(blocks[:6]))["warning"], "")
        # Softened contract: twelve blocks break the six-block cap. Strict validation raises;
        # normalize_response keeps the first six in order and drops the later ones.
        with self.assertRaises(ValueError):
            catalog.validate_response(answer(blocks))
        result = self.normalize(answer(blocks))
        self.assertEqual(result["blocks"], blocks[:6])
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)

    def test_plain_text_and_code_preserved(self):
        text = '<script>alert("x")</script>\n<&> \u00e9'
        for kind in ("text", "code"):
            result = self.normalize(answer([{"type": kind, "title": "", "text": text}]))
            self.assertEqual(result["blocks"][0]["text"], text)

    def test_allowed_html_attribute_stripping(self):
        tags = "b strong i em u s p ul ol li h1 h2 h3 pre code".split()
        for tag in tags:
            self.assertEqual(catalog.sanitize_richtext(f'<{tag} style="background:url(https://bad)" onclick="bad()">ok</{tag}>'), f"<{tag}>ok</{tag}>")
        self.assertEqual(catalog.sanitize_richtext('<br class="x"/>'), "<br>")

    def test_resource_injection_removed_with_content(self):
        payload = ('<p>safe<img src="file:///secret"><script>bad()</script>'
                   '<style>@import "https://bad";</style><svg><image href="https://bad"/></svg>'
                   '<iframe src="https://bad">secret</iframe><object data="file:///x">secret</object>'
                   '<a href="https://bad">link</a><video><source src="x">secret</video>'
                   '<math><mi>secret</mi></math><template>secret</template>'
                   '<link rel="stylesheet" href="x"><!-- secret -->end</p>')
        block = {"type": "richtext", "title": "", "text": payload}
        result = self.normalize(answer([block]))
        self.assertEqual(result["warning"], "")
        self.assertEqual(result["blocks"][0]["text"], "<p>safeend</p>")

    def test_encoded_html_remains_text_and_bad_nesting_is_safe(self):
        payloads = ['&lt;img src=x onerror=bad()&gt;', '<b><i>x</b></i>',
                    '<svg><script>x</svg><img src=x><p onclick=bad()>ok',
                    '<SCRIPT>x', '<![CDATA[<img src=x>]]>', '<p>&#60;script&#62;x</p>']

        class Audit(HTMLParser):
            def handle_starttag(self, tag, attrs):
                if tag not in catalog._ALLOWED or attrs:
                    raise AssertionError((tag, attrs))

        for payload in payloads:
            clean = catalog.sanitize_richtext(payload)
            Audit().feed(clean)
            self.assertEqual(catalog.sanitize_richtext(clean), clean)

    def test_unknown_and_nested_fields(self):
        for block in [
            {"type": "html", "title": "", "text": "x"},
            {"type": "text", "title": "", "text": "x", "onclick": "x"},
            {"type": "text", "title": "", "text": {"$ref": "file:///etc/passwd"}},
            {"type": "checklist", "title": "", "items": [{"type": "text", "text": "x"}]},
            {"type": "table", "title": "", "columns": ["x"], "rows": [[{"$schema": "https://bad"}]]},
        ]:
            self.assert_block_dropped(answer([block]))
        for key in ("$schema", "$ref", "tools", "warning"):
            value = answer()
            value[key] = {"nested": {"command": "rm -rf /"}}
            self.assert_whole_fallback(value)
        for key in answer():
            value = answer()
            del value[key]
            self.assert_whole_fallback(value)

    def test_progress_numbers(self):
        for value in (0, 1, 0.25):
            self.assertEqual(self.normalize(answer([{"type": "progress", "title": "", "value": value, "detail": ""}]))["warning"], "")
        for value in (True, False, -0.1, 1.1, "0.5", None, float("nan"), float("inf"), -float("inf")):
            self.assert_block_dropped(answer([{"type": "progress", "title": "", "value": value, "detail": ""}]))

    def test_new_blocks_exact_required_keys_and_no_enrichment(self):
        blocks = [
            {"type": "image", "title": "Place", "query": "Eiffel Tower"},
            {"type": "market", "title": "Stock", "symbol": "AAPL", "range": "1mo"},
            {"type": "sources", "title": "Sources", "items": [{"label": "Site", "url": "https://example.com"}]},
            chart(),
        ]
        for block in blocks:
            for key in block:
                with self.subTest(kind=block["type"], missing=key):
                    missing = copy.deepcopy(block)
                    del missing[key]
                    self.assert_block_dropped(answer([missing]))
            for key in ("url", "imageUrl", "data", "valuesResolved", "status", "blocks"):
                extra = copy.deepcopy(block)
                extra[key] = "untrusted"
                self.assert_block_dropped(answer([extra]))
        for item in ({"label": "Site"}, {"url": "https://example.com"},
                     {"label": "Site", "url": "https://example.com", "onclick": "bad"}):
            self.assert_block_dropped(answer([{"type": "sources", "title": "", "items": [item]}]))

    def test_image_query_bounds(self):
        for query in ("x", "x" * 200, "\u6771\u4eac\u30bf\u30ef\u30fc"):
            self.assertEqual(self.normalize(answer([{"type": "image", "title": "", "query": query}]))["warning"], "")
        for query in ("", " ", "\n\t", "x" * 201, None, []):
            self.assert_block_dropped(answer([{"type": "image", "title": "", "query": query}]))

    def test_market_symbols_and_ranges(self):
        for symbol in ("AAPL", "^GSPC", "BRK-B", "BRK.B", "EURUSD=X", "0700.HK", "a" * 24):
            for period in ("1mo", "3mo", "1y"):
                self.assertEqual(self.normalize(answer([{"type": "market", "title": "", "symbol": symbol, "range": period}]))["warning"], "")
        for symbol in ("", "a" * 25, "AAPL\n", " AAPL", "AAPL/USD", "AAPL?x", "\u00c5APL", "a_b", None):
            self.assert_block_dropped(answer([{"type": "market", "title": "", "symbol": symbol, "range": "1mo"}]))
        for period in ("", "1d", "5y", "1MO", 1):
            self.assert_block_dropped(answer([{"type": "market", "title": "", "symbol": "AAPL", "range": period}]))

    def test_chart_numeric_and_array_contract(self):
        for values in ([0, 0], [-1e15, 1e15], [-1, 0.125]):
            block = chart()
            block["values"] = values
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for value in (True, False, "2", None, float("nan"), float("inf"), -float("inf"), -1e15 - 1, 1e15 + 1):
            block = chart()
            block["values"][0] = value
            self.assert_block_dropped(answer([block]))
        for count in (2, 120):
            block = chart()
            block["labels"], block["values"] = ["x"] * count, [1] * count
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for count in (0, 1, 121):
            block = chart()
            block["labels"], block["values"] = ["x"] * count, [1] * count
            self.assert_block_dropped(answer([block]))
        block = chart()
        block["values"].append(4)
        self.assert_block_dropped(answer([block]))
        block = chart()
        block["source"], block["asOf"] = "", "Provided data"
        self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for as_of in ("", "2026", "provided data"):
            block["asOf"] = as_of
            self.assert_block_dropped(answer([block]))

    def test_sources_count_duplicates_and_string_bounds(self):
        for count in (1, 6):
            block = {"type": "sources", "title": "", "items": [{"label": "Source", "url": f"https://example.com/{i}"} for i in range(count)]}
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for count in (0, 7):
            self.assert_block_dropped(answer([{"type": "sources", "title": "", "items": [{"label": "", "url": f"https://example.com/{i}"} for i in range(count)]}]))
        for duplicate in ("https://example.com/", "https://EXAMPLE.com:443", "https://example.com/#section"):
            self.assert_block_dropped(answer([{"type": "sources", "title": "", "items": [
                {"label": "First", "url": "https://example.com"}, {"label": "Again", "url": duplicate}]}]))
        for field, limit in (("label", 160), ("url", 2048)):
            item = {"label": "", "url": "https://example.com/"}
            item[field] = "x" * limit if field == "label" else "https://example.com/" + "x" * (limit - 20)
            self.assertEqual(self.normalize(answer([{"type": "sources", "title": "", "items": [item]}]))["warning"], "")
            item[field] += "x"
            self.assert_block_dropped(answer([{"type": "sources", "title": "", "items": [item]}]))

    def test_chart_string_bounds(self):
        for field, limit in (("title", 160), ("unit", 32), ("labels", 80), ("asOf", 80), ("source", 2048)):
            block = chart()
            value = "x" * limit if field != "source" else "https://example.com/" + "x" * (limit - 20)
            if field == "labels":
                block[field][0] = value
            else:
                block[field] = value
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            if field == "labels":
                block[field][0] += "x"
            else:
                block[field] += "x"
            self.assert_block_dropped(answer([block]))

    def test_public_https_url_syntax_without_network(self):
        accepted = ["https://example.com", "HTTPS://Example.COM:443/path?q=one#section",
                    "https://en.wikipedia.org/wiki/Red_panda", "https://\u4f8b\u3048.jp/\u8cc7\u6599",
                    "https://xn--r8jz45g.jp/", "https://example.com/a%20b", "https://example.com/%C3%A9"]
        rejected = ["", "http://example.com", "file:///etc/passwd", "javascript:alert(1)",
                    "//example.com", "https://user@" + "example.com", "https://user:pw@" + "example.com",
                    "https://@example.com", "https://localhost", "https://x.localhost",
                    "https://x.local", "https://x.internal", "https://127.0.0.1", "https://8.8.8.8",
                    "https://[::1]", "https://[2606:4700:4700::1111]", "https://2130706433",
                    "https://0x7f000001", "https://0177.0.0.1", "https://example.com.",
                    "https://example.com:0", "https://example.com:65536", "https://example.com:",
                    "https://example.com:no", "https://-example.com", "https://a..com",
                    "https://xn--a.com", "https://exam_ple.com", "https://example.com\\@localhost/",
                    " https://example.com", "https://example.com/\n", "https://example.com/\x00",
                    "https://example.com/\u200b", "https://example.com/a b", "https://example.com/%",
                    "https://example.com/%GG", "https://example.com/%00", "https://example.com/%0a",
                    "https://example.com/%5C", "https://example.com/%7f", "https://example.com/%250a",
                    "https://example.com/%FF", "https://example.com/%C2%85", "https://%65xample.com"]
        with mock.patch("socket.getaddrinfo", side_effect=AssertionError("No DNS allowed")), \
                mock.patch("urllib.request.urlopen", side_effect=AssertionError("No network allowed")):
            for url in accepted + rejected:
                with self.subTest(url=url):
                    blocks = [{"type": "sources", "title": "", "items": [{"label": "Source", "url": url}]}]
                    sourced_chart = chart()
                    sourced_chart["source"] = url
                    for block in (blocks[0], sourced_chart):
                        if url in accepted:
                            self.assertEqual(self.normalize(answer([block]))["warning"], "")
                            expected = copy.deepcopy(block)
                            canonical = {
                                "https://example.com": "https://example.com/",
                                "HTTPS://Example.COM:443/path?q=one#section": "https://example.com/path?q=one#section",
                                "https://\u4f8b\u3048.jp/\u8cc7\u6599": "https://xn--r8jz45g.jp/\u8cc7\u6599",
                            }.get(url, url)
                            if expected["type"] == "sources":
                                expected["items"][0]["url"] = canonical
                            else:
                                expected["source"] = canonical
                            self.assertEqual(catalog.validate_response(answer([block]))["blocks"], [expected])
                        else:
                            self.assert_block_dropped(answer([block]))

    def test_array_limits_and_table_width(self):
        cases = [
            ({"type": "checklist", "title": "", "items": ["x"] * 20}, "items", 20),
            ({"type": "table", "title": "", "columns": ["x"] * 5, "rows": []}, "columns", 5),
            ({"type": "table", "title": "", "columns": ["x"], "rows": [["x"]] * 24}, "rows", 24),
        ]
        for block, key, limit in cases:
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            block[key].append(copy.deepcopy(block[key][0]))
            self.assert_block_dropped(answer([block]))
        self.assert_block_dropped(answer([{"type": "table", "title": "", "columns": ["x"], "rows": [["x", "y"]]}]))
        self.assert_block_dropped(answer([{"type": "table", "title": "", "columns": [], "rows": []}]))
        self.assert_whole_fallback({"answer": "x", "blocks": [], "suggestions": ["x"] * 4})

    def test_string_limits(self):
        for field, limit in (("title", 160), ("text", 16384)):
            block = {"type": "text", "title": "", "text": ""}
            block[field] = "x" * limit
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            block[field] += "x"
            self.assert_block_dropped(answer([block]))
        self.assertTrue(self.normalize({"answer": "x" * 16385, "blocks": [], "suggestions": []})["warning"])
        self.assert_whole_fallback({"answer": "x", "blocks": [], "suggestions": ["x" * 257]})

    def test_json_fences_only(self):
        raw = json.dumps(answer())
        for wrapped in (raw, "```json\n" + raw + "\n```", "  ```JSON\n" + raw + "\n```  "):
            self.assertEqual(catalog.normalize_response(wrapped)["warning"], "")
        for wrapped in ("```\n" + raw + "\n```", "```python\n" + raw + "\n```", "```json\n```json\n" + raw + "\n```\n```", "prefix " + raw):
            self.assertTrue(catalog.normalize_response(wrapped)["warning"])

    def test_fallbacks_are_bounded_and_readable(self):
        result = catalog.normalize_response("A plain answer \u2713")
        self.assertEqual(result["answer"], "A plain answer \u2713")
        self.assertTrue(result["warning"])
        for raw in ('{"answer": "broken",', '{"data":"' + "secret" * 1000, "[broken", "" ):
            result = catalog.normalize_response(raw)
            self.assertLessEqual(len(result["answer"]), catalog.MAX_FALLBACK_CHARS + 1)
            self.assertNotIn("secret", result["answer"])
        result = self.normalize({"answer": "Keep this", "blocks": [{"type": "bad"}], "suggestions": []})
        self.assertEqual(result["answer"], "Keep this")
        self.assertTrue(result["warning"])
        self.assertLessEqual(len(catalog.normalize_response("x" * 5000)["answer"]), 4097)

    def test_utf8_byte_limits_and_invalid_input(self):
        self.assertEqual(catalog.normalize_response(json.dumps(answer(), ensure_ascii=False).encode())["warning"], "")
        for raw in (b"\xff", "\ud800", "\u00e9" * 40000, b"x" * 65537, None, {}, 42):
            result = catalog.normalize_response(raw)
            self.assertTrue(result["warning"])
            self.assertLess(len(result["answer"]), 100)
        escaped = json.dumps(answer([{"type": "text", "title": "", "text": "\ud800"}]))
        self.assertEqual(catalog.normalize_response(escaped)["answer"], "Readable answer \u2713")
        self.assertTrue(catalog.normalize_response(escaped)["warning"])

    def test_every_schema_string_bound(self):
        blocks = [
            ({"type": "checklist", "title": "", "items": [""]}, "items", 1024),
            ({"type": "table", "title": "", "columns": [""], "rows": []}, "columns", 160),
            ({"type": "table", "title": "", "columns": ["x"], "rows": [[""]]}, "rows", 1024),
            ({"type": "metric", "title": "", "value": "", "detail": ""}, "value", 160),
            ({"type": "metric", "title": "", "value": "", "detail": ""}, "detail", 1024),
        ]
        for block, field, limit in blocks:
            def put(text):
                if field == "rows":
                    block[field][0][0] = text
                elif field in ("items", "columns"):
                    block[field][0] = text
                else:
                    block[field] = text
            put("x" * limit)
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            put("x" * (limit + 1))
            self.assert_block_dropped(answer([block]))

    def test_combined_response_byte_limit(self):
        blocks = [{"type": "code", "title": "", "text": "x" * 16384} for _ in range(4)]
        self.assertTrue(self.normalize(answer(blocks))["warning"])
        with self.assertRaises(ValueError):
            catalog.validate_response(answer(blocks))

    def test_duplicate_fields_and_deep_json(self):
        for raw in ('{"answer":"one","answer":"two","blocks":[],"suggestions":[]}', '[' * 2000 + '0' + ']' * 2000):
            self.assertTrue(catalog.normalize_response(raw)["warning"])

    def test_validator_detaches_and_raises(self):
        value = answer([{"type": "richtext", "title": "", "text": '<b id="x">ok</b>'}])
        clean = catalog.validate_response(value)
        self.assertEqual(clean["blocks"][0]["text"], "<b>ok</b>")
        self.assertNotEqual(clean, value)
        clean["suggestions"].append("Other?")
        self.assertEqual(len(value["suggestions"]), 1)
        with self.assertRaises(ValueError):
            catalog.validate_response({"answer": "x"})

    def test_instructions_limit_authority(self):
        self.assertIn("answer-and-inspect", catalog.SYSTEM_INSTRUCTIONS)
        self.assertIn("no\ntool for arbitrary commands", catalog.SYSTEM_INSTRUCTIONS)
        self.assertNotIn("grant", catalog.SYSTEM_INSTRUCTIONS.lower())
        self.assertIn(json.dumps(catalog.ANSWER_SCHEMA, ensure_ascii=False, separators=(",", ":")), catalog.SYSTEM_INSTRUCTIONS)
        for phrase in ("concrete encyclopedia subject", "never visual proof", "actual\nticker symbol",
                       "default range is 1mo", "Never invent numeric prices", "explicit user-supplied dataset",
                       "Provided data", "sources block", "rather than raw URLs in text", "nested UI"):
            self.assertIn(phrase, catalog.SYSTEM_INSTRUCTIONS)

    def test_csv_rule_allows_full_source_quotes_only_for_listed_aggregates(self):
        text = catalog.SYSTEM_INSTRUCTIONS
        # Unchanged: prefix samples never support whole-file claims.
        self.assertIn("If an attached CSV snapshot is\nmarked truncated or notes that it is sampled, base any count, average or trend\n"
                      "on the sampled rows shown and say the answer reflects a sample, never the whole\nfile.", text)
        self.assertIn('Only when the request carries a "Full-source statistics" section may you\n'
                      "quote the count, empty count, min, max, sum and mean of the columns it lists as\n"
                      "whole-file values; every other aggregate, trend or category claim (median,\n"
                      "quantile, correlation, group-by) stays sample-bound or must be declined or\n"
                      "deferred to the local explorer. Without that section a prefix sample never\n"
                      "supports a whole-file claim.", text)
        self.assertEqual(text.count("Full-source statistics"), 1)


def loan_block():
    return {"type": "calc", "title": "Loan payment", "note": "Fixed rate, monthly compounding; no fees.",
            "inputs": [
                {"id": "principal", "label": "Amount", "unit": "EUR", "min": 1000, "max": 50000,
                 "step": 500, "value": 20000, "basis": "provided"},
                {"id": "rate", "label": "Yearly rate", "unit": "%", "min": 0, "max": 15,
                 "step": 0.25, "value": 5, "basis": "assumption"},
                {"id": "years", "label": "Years", "unit": "", "min": 1, "max": 10,
                 "step": 1, "value": 4, "basis": "provided"}],
            "tables": [],
            "cells": [
                {"id": "payment", "label": "Monthly payment", "unit": "EUR", "decimals": 2, "note": "",
                 "expression": "if(rate==0,principal/(years*12),principal*(rate/12)/(1-(1+rate/12)^(-years*12)))"},
                {"id": "total", "label": "Total paid", "expression": "payment*years*12",
                 "unit": "EUR", "decimals": 2, "note": "Uses the unrounded payment."},
                {"id": "interest", "label": "Interest", "expression": "total-principal",
                 "unit": "EUR", "decimals": 2, "note": ""}]}


def small_calc(inputs=1, cells=1, tables=0, columns=2, rows=2):
    """A valid block of chosen shape: input ids x1.., a number table per t1.., cells c1.. summing x1."""
    block = {"type": "calc", "title": "Shape", "note": "", "inputs": [], "tables": [], "cells": []}
    for i in range(1, inputs + 1):
        block["inputs"].append({"id": "x%d" % i, "label": "X", "unit": "", "min": 0, "max": 100,
                                "step": 1, "value": 5, "basis": "assumption"})
    for t in range(1, tables + 1):
        block["tables"].append({
            "id": "t%d" % t, "label": "Table",
            "columns": [{"id": "n%d" % c, "label": "N", "unit": "", "kind": "number", "expression": ""}
                        for c in range(columns)],
            "rows": [["1"] * columns for _ in range(rows)]})
    for c in range(1, cells + 1):
        block["cells"].append({"id": "c%d" % c, "label": "Cell", "expression": "x1+%d" % c,
                               "unit": "", "decimals": 2, "note": ""})
    return block


def laptop_block(score=None):
    """The shape a live three-laptop prompt asks for (price EUR, battery h, weight kg, three
    weights, a score per laptop), scaled against FIXED bounds like the prompt's worked example.
    Hand-verified at weights 5/5/5 (total 15): A = 100*(5*0.4+5*0.7+5*0.44)/15 = 51.33,
    B = 100*(5*0.55+5*0.45+5*0.28)/15 = 42.67, C = 100*(5*0.25+5*0.9+5*0.52)/15 = 55.67."""
    weights = [{"id": name, "label": label, "unit": "", "min": 0, "max": 10, "step": 1, "value": 5,
                "basis": "assumption"}
               for name, label in (("w_price", "Price weight"), ("w_batt", "Battery weight"), ("w_mass", "Weight weight"))]
    guard = ("if(wsum==0,0,100*(w_price*clamp(1-price/2000[EUR],0,1)+w_batt*clamp(batt/20[h],0,1)"
             "+w_mass*clamp(1-mass/2.5[kg],0,1))/wsum)")
    return {"type": "calc", "title": "Laptop score", "note": "Illustrative scales: 2000 EUR, 20 h, 2.5 kg.",
            "inputs": weights,
            "tables": [{"id": "laptops", "label": "Laptops", "columns": [
                {"id": "name", "label": "Laptop", "unit": "", "kind": "text", "expression": ""},
                {"id": "price", "label": "Price", "unit": "EUR", "kind": "number", "expression": ""},
                {"id": "batt", "label": "Battery", "unit": "h", "kind": "number", "expression": ""},
                {"id": "mass", "label": "Weight", "unit": "kg", "kind": "number", "expression": ""},
                {"id": "score", "label": "Score", "unit": "", "kind": "formula", "expression": score or guard}],
                "rows": [["Laptop A", "1200", "14", "1.4", ""], ["Laptop B", "900", "9", "1.8", ""],
                         ["Laptop C", "1500", "18", "1.2", ""]]}],
            "cells": [{"id": "wsum", "label": "Total weight", "expression": "w_price+w_batt+w_mass",
                       "unit": "", "decimals": 0, "note": ""}]}


class CalcBlockTests(unittest.TestCase):
    def normalize(self, value):
        return catalog.normalize_response(json.dumps(value, ensure_ascii=False))

    def ok(self, *blocks):
        result = self.normalize(answer(list(blocks)))
        self.assertEqual(result["warning"], "", result)
        return result

    def dropped(self, *blocks):
        """Softened contract (2026-10-09): every given block is invalid, so each is dropped on
        its own; the answer text and suggestions stay with the generic warning, and the strict
        validate_response still raises for the same input."""
        value = answer(list(blocks))
        self.assertEqual(self.normalize(value), {"answer": "Readable answer \u2713", "blocks": [],
                                                  "suggestions": ["Explain more?"], "warning": catalog.DROPPED_WARNING})
        with self.assertRaises(ValueError):
            catalog.validate_response(value)

    def mutated(self, mutate, base=loan_block):
        block = base()
        mutate(block)
        return block

    def evaluate(self, block, values=None):
        calc = catalog.ai_calc
        model = calc.compile_spec({key: block[key] for key in ("inputs", "tables", "cells")})
        result = calc.evaluate(model, values)
        return model, result, {node: calc.format_cell(model, result, node) for node in model.order}

    # -- valid shapes
    def test_valid_shapes_pass_and_round_trip(self):
        shapes = [loan_block(), small_calc(), small_calc(inputs=12, cells=24, tables=2, columns=12, rows=40),
                  self.mutated(lambda b: b["tables"].append(small_calc(tables=1)["tables"][0]), small_calc)]
        for block in shapes:
            with self.subTest(title=block["title"], tables=len(block["tables"])):
                result = self.ok(block)
                self.assertEqual(result["blocks"], [block])
        mixed = [{"type": "sources", "title": "Rates", "items": [{"label": "ECB", "url": "https://example.com/rates"}]},
                 CatalogTests.diagram_block(None), loan_block()]
        self.assertEqual(self.ok(*mixed)["blocks"][2], loan_block())

    def test_loan_numbers_match_an_independent_decimal_computation(self):
        # Verified outside the engine with 50-digit Decimal arithmetic:
        # r = 0.05/12, n = 48, payment = 20000 r / (1 - (1+r)^-48) = 460.5858714...,
        # total = 48 payment = 22108.1218278..., interest = 2108.1218278...
        _, _, text = self.evaluate(loan_block())
        self.assertEqual((text["payment"], text["total"], text["interest"]),
                         ("460.59 EUR", "22108.12 EUR", "2108.12 EUR"))
        # Minimum corner (rate 0 takes the guarded branch): 1000 EUR over 12 months.
        _, _, text = self.evaluate(loan_block(), {"principal": 1000, "rate": 0, "years": 1})
        self.assertEqual((text["payment"], text["total"], text["interest"]),
                         ("83.33 EUR", "1000.00 EUR", "0.00 EUR"))

    def test_worked_example_in_the_prompt_validates_and_evaluates_to_hand_numbers(self):
        # The numbers below were derived by hand (see the comment on CALC_EXAMPLE)
        # and re-checked with exact Fraction arithmetic outside the engine.
        example = catalog.CALC_EXAMPLE
        compact = json.dumps(example, ensure_ascii=False, separators=(",", ":"))
        self.assertIn("Worked example: " + compact, catalog.SYSTEM_INSTRUCTIONS)
        self.assertEqual(self.ok(example)["blocks"], [example])
        _, _, text = self.evaluate(example)
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["66.50", "63.50", "50.50"])
        self.assertEqual((text["wsum"], text["mean_score"], text["avg_price"]), ("10", "60.2", "1183 EUR"))
        _, _, text = self.evaluate(example, {"w_perf": 0, "w_batt": 0, "w_price": 0})
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["0.00"] * 3, "the guard")
        _, _, text = self.evaluate(example, {"w_perf": 10, "w_batt": 10, "w_price": 10})
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["63.33", "51.67", "52.50"])
        self.assertEqual(text["mean_score"], "55.8")
        _, _, text = self.evaluate(example, {"w_perf": 0, "w_batt": 0, "w_price": 10})
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["45.00", "10.00", "67.50"])

    # -- system prompt and schema
    def test_prompt_pins_the_calc_rules_and_stays_small(self):
        text = " ".join(catalog.SYSTEM_INSTRUCTIONS.split())
        for sentence in (
                "-> one calc block: numeric inputs, optional tables of literal rows with formula columns, and cells with formulas.",
                "The launcher computes every cell, so never type a computed number as text.",
                "State every formula with its unit.",
                "Money units are ISO-4217 codes (EUR, USD); a conversion between currencies needs an explicit rate input "
                "whose basis is assumption or sourced, with a sources block for sourced.",
                "Never present an assumed number as a fact, and put every simplification in the note.",
                "Guard divisions with if(), as in if(n==0,0[EUR],a/n); both branches need the same unit,",
                "every cell must evaluate without error at the minimum, midpoint and maximum of all inputs "
                "or the calculator is dropped.",
                "min and max take 2-6 plain values, never a column: scale against fixed bounds, as in the example.",
                "numbers are plain decimals with an optional unit as in 12.5[kg], never 1e3;",
                "the only functions are abs min max clamp floor ceil sqrt round(x,n) if(c,a,b) iferror(a,b) "
                "to(q,[u]) num(q,[u]) sum mean median count sumproduct;",
                "Table.col only inside sum/mean/median/count/sumproduct,",
                "Ids match [a-z][a-z0-9_]{0,23} and must not equal a function, and/or/not or a unit symbol "
                "such as s, h, m, d, g, in, min.",
                "Number-column cells are plain numbers or empty; formula-column cells are empty strings.",
                "At most one of each of slider, diagram, gallery, and calc per answer;",
                "calc (type,title,inputs,tables,cells,note),"):
            self.assertIn(sentence, text)
        self.assertNotIn("colstat", text, "no source gating yet: the model is not told about colstat")
        # Growth guard: 16,100 bytes before the calc block (schema 7,764 B); 21.5 KB after;
        # 23,034 B with the form block (+1.1 KB of it is the form's schema alternative in
        # the dump); 25.7 KB with actions/compare/timeline (2 KB of that is their schema
        # alternatives). The full text is only the unknown-agent fallback now; the prompts that
        # are actually sent (codex, hermes) have their own budgets in test_ai_prompt_budget.py.
        self.assertLessEqual(len(catalog.SYSTEM_INSTRUCTIONS.encode()), 26000)
        self.assertLess(len(json.dumps(catalog.CALC_EXAMPLE).encode()), catalog.MAX_RESPONSE_BYTES // 20)

    def test_three_laptop_weighted_score_shape_validates_and_evaluates_to_hand_numbers(self):
        """Regression for the live 2026-10-09 three-laptop prompt: every shape the validator
        requires of a weighted-score calculator, once corrected, passes (and a wrong one is
        dropped as a block, never the whole answer)."""
        block = laptop_block()
        self.assertEqual(self.ok(block)["blocks"], [block])
        _, _, text = self.evaluate(block)
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["51.33", "42.67", "55.67"])
        _, _, text = self.evaluate(block, {"w_price": 0, "w_batt": 0, "w_mass": 0})
        self.assertEqual([text["laptops.score#%d" % i] for i in (1, 2, 3)], ["0.00"] * 3, "the guard")
        # What the validator requires, one corner at a time (each wrong shape is dropped):
        unguarded = ("100*(w_price*clamp(1-price/2000[EUR],0,1)+w_batt*clamp(batt/20[h],0,1)"
                     "+w_mass*clamp(1-mass/2.5[kg],0,1))/wsum")
        self.dropped(laptop_block(unguarded))  # DIV0 at the all-minimum corner (every weight 0)
        fixed = laptop_block(unguarded)
        for entry in fixed["inputs"]:
            entry["min"] = 1  # the validator's other accepted repair: no zero total is reachable
        self.ok(fixed)
        self.dropped(laptop_block("if(wsum==0,0,100*(w_price*(1-price/2000)+w_batt*batt/20[h]"
                                  "+w_mass*(1-mass/2.5[kg]))/wsum)"))  # a bare 2000 beside EUR is a unit mix
        self.dropped(laptop_block("if(wsum==0,0,100*(w_price*(max(laptops.price)-price)/"
                                  "(max(laptops.price)-min(laptops.price)))/wsum)"))  # min/max are not column aggregates
        self.ok(laptop_block("if(wsum==0,0,100*(w_price*(1500[EUR]-price)/(1500[EUR]-900[EUR])"
                             "+w_batt*(batt-9[h])/(18[h]-9[h])+w_mass*(1.8[kg]-mass)/(1.8[kg]-1.2[kg]))/wsum)"))
        for cell in ("1200 EUR", "1,200", "1200\u20ac"):
            wrong = laptop_block()
            wrong["tables"][0]["rows"][0][1] = cell  # units live in the column, cells are plain numbers
            self.dropped(wrong)
        text_kind = laptop_block()
        text_kind["tables"][0]["columns"][1]["kind"] = "text"  # a text column cannot feed arithmetic
        self.dropped(text_kind)
        for reserved in ("h", "kg", "min"):  # a column or weight id that is a unit symbol
            clash = laptop_block()
            clash["tables"][0]["columns"][2]["id"] = reserved
            self.dropped(clash)

    def test_schema_bounds_match_the_engine_limits(self):
        calc = next(alt for alt in catalog.ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"]
                    if alt["properties"]["type"].get("enum") == ["calc"])
        engine = catalog.ai_calc
        props = calc["properties"]
        table = props["tables"]["items"]["properties"]
        self.assertEqual(props["inputs"]["maxItems"], engine.max_inputs)
        self.assertEqual(props["tables"]["maxItems"], engine.max_tables)
        self.assertEqual(props["cells"]["maxItems"], engine.max_cells)
        self.assertEqual(table["columns"]["maxItems"], engine.max_columns)
        self.assertEqual(table["rows"]["maxItems"], engine.max_rows)
        self.assertEqual(table["rows"]["items"]["maxItems"], engine.max_columns)
        self.assertEqual(table["rows"]["items"]["items"]["maxLength"], 64)
        self.assertEqual(props["cells"]["items"]["properties"]["expression"]["maxLength"], engine.max_expression_chars)
        self.assertEqual(table["columns"]["items"]["properties"]["expression"]["maxLength"], engine.max_expression_chars)
        self.assertEqual(props["inputs"]["items"]["properties"]["id"]["maxLength"], engine.max_id_chars)
        self.assertEqual(set(props["inputs"]["items"]["properties"]["basis"]["enum"]),
                         {"assumption", "provided", "sourced"})
        self.assertEqual(props["cells"]["items"]["properties"]["decimals"], {"type": "integer", "minimum": 0, "maximum": 6})

    # -- bounds, each at the limit and one past it
    def test_array_and_row_bounds(self):
        cases = [("inputs", dict(inputs=12), dict(inputs=13)), ("inputs min", dict(inputs=1), dict(inputs=0)),
                 ("cells", dict(cells=24), dict(cells=25)), ("cells min", dict(cells=1), dict(cells=0)),
                 ("tables", dict(tables=2), dict(tables=3)),
                 ("columns", dict(tables=1, columns=12), dict(tables=1, columns=13)),
                 ("columns min", dict(tables=1, columns=1), dict(tables=1, columns=0)),
                 ("rows", dict(tables=1, rows=40), dict(tables=1, rows=41)),
                 ("rows min", dict(tables=1, rows=1), dict(tables=1, rows=0))]
        for name, good, over in cases:
            with self.subTest(name=name):
                self.ok(small_calc(**good))
                self.dropped(small_calc(**over))

    def test_string_length_bounds(self):
        def put(path, text):
            def apply(block):
                target = block
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = text
            return apply
        wide = dict(tables=1, rows=1, columns=1)
        cases = [(("title",), 160, small_calc), (("note",), 300, small_calc),
                 (("inputs", 0, "label"), 80, small_calc), (("cells", 0, "label"), 80, small_calc),
                 (("cells", 0, "note"), 200, small_calc),
                 (("tables", 0, "label"), 80, lambda: small_calc(**wide)),
                 (("tables", 0, "columns", 0, "label"), 80, lambda: small_calc(**wide)),
                 (("cells", 0, "id"), 24, small_calc), (("inputs", 0, "id"), 24, small_calc),
                 (("tables", 0, "id"), 24, lambda: small_calc(**wide)),
                 (("tables", 0, "columns", 0, "id"), 24, lambda: small_calc(**wide))]
        for path, limit, base in cases:
            with self.subTest(path=path):
                filler = "a" * limit if path[-1] == "id" else "x" * limit
                extra = "a" if path[-1] == "id" else "x"

                def apply(text, path=path, base=base):
                    block = self.mutated(put(path, text), base)
                    if path[:2] == ("inputs", 0) and path[-1] == "id":
                        block["cells"][0]["expression"] = text + "+1"  # keep the reference valid
                    return block
                self.ok(apply(filler))
                self.dropped(apply(filler + extra))
        # Expressions: 200 characters pass (padding is blank), 201 do not.
        for target in ("cell", "column"):
            def pad(extra):
                def apply(block):
                    expr = "x1" + " " * (198 + extra)
                    if target == "cell":
                        block["cells"][0]["expression"] = expr
                    else:
                        block["tables"][0]["columns"][0].update(kind="formula", expression=expr)
                        block["tables"][0]["rows"] = [[""]]
                return apply
            base = (lambda: small_calc(**wide))
            self.ok(self.mutated(pad(0), base))
            self.dropped(self.mutated(pad(1), base))
        # Table cells: 64 characters pass in a text column, 65 do not.
        def cell(text):
            def apply(block):
                block["tables"][0]["columns"][0]["kind"] = "text"
                block["tables"][0]["rows"] = [[text]]
            return apply
        self.ok(self.mutated(cell("\u00e9" * 64), lambda: small_calc(**wide)))
        self.dropped(self.mutated(cell("\u00e9" * 65), lambda: small_calc(**wide)))
        # The unit text: 24 characters (a valid compound unit) pass, 25 do not.
        unit24 = "km" + "*m" * 11
        self.assertEqual(len(unit24), 24)
        def with_unit(unit):
            def apply(block):
                block["inputs"][0]["unit"] = unit
                block["cells"][0]["expression"] = "x1"
            return apply
        self.ok(self.mutated(with_unit(unit24), small_calc))
        self.dropped(self.mutated(with_unit(unit24 + "*"), small_calc))

    def test_numeric_bounds_and_decimals(self):
        nan = float("nan")
        for update, good in (({"min": -1e9}, True), ({"min": -1e9 - 1}, False), ({"min": None}, False),
                             ({"max": 1e9}, True), ({"max": 1e9 + 1}, False),
                             ({"step": 1e9}, True), ({"step": 1e9 + 1}, False), ({"step": 0}, False), ({"step": -1}, False),
                             ({"value": 1e9}, True), ({"value": -1e9}, True), ({"value": 1e9 + 1}, False),
                             ({"value": -1e9 - 1}, False), ({"value": True}, False), ({"value": "5"}, False),
                             ({"value": nan}, False), ({"value": float("inf")}, False)):
            with self.subTest(update=update):
                block = small_calc()
                block["inputs"][0].update(update)
                (self.ok if good else self.dropped)(block)
        for decimals, good in ((0, True), (6, True), (-1, False), (7, False), (True, False), (2.0, False), ("2", False)):
            with self.subTest(decimals=decimals):
                block = small_calc()
                block["cells"][0]["decimals"] = decimals
                (self.ok if good else self.dropped)(block)

    def test_basis_is_an_enum(self):
        for basis in ("assumption", "provided", "sourced"):
            self.ok(self.mutated(lambda b: b["inputs"][0].update(basis=basis), small_calc))
        for basis in ("Assumption", "fact", "", None, 1):
            self.dropped(self.mutated(lambda b: b["inputs"][0].update(basis=basis), small_calc))

    def test_exact_keys_everywhere(self):
        paths = [(), ("inputs", 0), ("tables", 0), ("tables", 0, "columns", 0), ("cells", 0)]
        for path in paths:
            def at(block):
                for key in path:
                    block = block[key]
                return block
            base = lambda: small_calc(tables=1, columns=1, rows=1)
            for key in list(at(base())):
                with self.subTest(path=path, missing=key):
                    block = base()
                    del at(block)[key]
                    self.dropped(block)
            with self.subTest(path=path, extra=True):
                block = base()
                at(block)["extra"] = "x"
                self.dropped(block)

    # -- clamping and normalisation
    def test_initial_value_and_step_are_clamped(self):
        for given, expected in ((999, 100), (-7, 0), (50, 50)):
            block = small_calc()
            block["inputs"][0]["value"] = given
            self.assertEqual(self.ok(block)["blocks"][0]["inputs"][0]["value"], expected)
        block = small_calc()
        block["inputs"][0]["step"] = 500
        self.assertEqual(self.ok(block)["blocks"][0]["inputs"][0]["step"], 100)
        for low, high in ((5, 5), (6, 5)):
            block = small_calc()
            block["inputs"][0].update(min=low, max=high, value=5)
            self.dropped(block)

    def test_ignored_fields_are_cleared_and_stray_expressions_rejected(self):
        block = small_calc(tables=1, columns=2, rows=2)
        block["tables"][0]["columns"][0].update(kind="text", unit="kg")
        block["tables"][0]["columns"][1].update(kind="formula", expression="1+1")
        block["tables"][0]["rows"] = [["a", "junk"], ["b", "42"]]
        table = self.ok(block)["blocks"][0]["tables"][0]
        self.assertEqual(table["columns"][0]["unit"], "")
        self.assertEqual(table["rows"], [["a", ""], ["b", ""]])
        block = small_calc(tables=1)
        block["tables"][0]["columns"][0]["expression"] = "1+1"
        self.dropped(block)

    # -- rejections that fall out of the engine
    def test_engine_rejections_drop_only_the_calc_block(self):
        x = lambda expr: self.mutated(lambda b: b["cells"][0].update(expression=expr), small_calc)
        cases = {
            "unknown function": x("foo(x1)"), "builtin lookalike": x("eval(x1)"), "scientific literal": x("1e3+x1"),
            "unknown name": x("x1+nothing"), "empty": x(" "), "bare unit": x("x1+[kg]"),
            "colstat": x("colstat(1,sum)"), "unit mismatch in sum": x("5[kg]+2[m]"),
            "text as number": x("1+'a'"), "chained comparison": x("if(1<2<3,1,2)"),
            "non-ascii digit": x("x1+\u0661\u0662"), "fullwidth digit": x("x1+\uff11"),
            "cyrillic lookalike": x("x1+\u0430"), "control character": x("x1+\x00"),
            "member access": x("x1.__class__"), "too long": x("x1" + "+x1" * 80),
        }
        for name, block in cases.items():
            with self.subTest(name=name):
                self.dropped(block)
        # A declared unit that does not fit the result, for a cell and for a formula column.
        self.dropped(self.mutated(lambda b: b["cells"][0].update(expression="5[kg]", unit="m"), small_calc))
        self.dropped(self.mutated(lambda b: b["cells"][0].update(expression="5", unit="kg"), small_calc))
        self.dropped(self.mutated(lambda b: b["cells"][0].update(unit="month"), small_calc))
        block = small_calc(tables=1, columns=2, rows=2)
        block["tables"][0]["columns"][1].update(kind="formula", expression="n0*2[EUR]", unit="kg")
        block["tables"][0]["rows"] = [["1", ""], ["2", ""]]
        self.dropped(block)

    def test_ids_cycles_and_duplicates(self):
        for reserved in ("s", "h", "m", "d", "in", "min", "max", "sum", "if", "and", "kg", "px"):
            with self.subTest(reserved=reserved):
                self.dropped(self.mutated(lambda b: b["cells"][0].update(id=reserved), small_calc))
                self.dropped(self.mutated(lambda b: b["inputs"][0].update(id=reserved), small_calc))
        for bad_id in ("X1", "1x", "a-b", "_a", "a" * 25, "", "x\u0663", "\u0430bc", "a b", "a\n"):
            with self.subTest(bad_id=bad_id):
                self.dropped(self.mutated(lambda b: b["cells"][0].update(id=bad_id), small_calc))
        dup = small_calc(cells=2)
        dup["cells"][1]["id"] = "c1"
        self.dropped(dup)
        dup = small_calc()
        dup["cells"][0]["id"] = "x1"
        self.dropped(dup)
        cycle = small_calc(cells=2)
        cycle["cells"][0]["expression"] = "c2+1"
        cycle["cells"][1]["expression"] = "c1+1"
        self.dropped(cycle)
        self.dropped(self.mutated(lambda b: b["cells"][0].update(expression="c1+1"), small_calc))
        # A formula column in a table that feeds a cell which feeds the column back.
        loop = small_calc(tables=1, columns=2, rows=2)
        loop["tables"][0]["columns"][1].update(kind="formula", expression="n0+c1")
        loop["tables"][0]["rows"] = [["1", ""], ["2", ""]]
        loop["cells"][0]["expression"] = "sum(t1.n1)"
        self.dropped(loop)

    def test_number_columns_hold_plain_numbers(self):
        def with_cell(text):
            block = small_calc(tables=1, columns=1, rows=2)
            block["tables"][0]["rows"] = [[text], ["1"]]
            return block
        for text in ("", " ", "0", "-3.5", "+2", ".5", " 12 ", "9" * 64):
            with self.subTest(text=text):
                self.ok(with_cell(text))
        for text in ("1e3", "1,000", "\u20ac5", "NaN", "inf", "0x10", "1.", "\u0661\u0662", "\uff11\uff12", "12abc", "1 2", "--1"):
            with self.subTest(text=text):
                self.dropped(with_cell(text))
        block = small_calc(tables=1, columns=1, rows=1)
        block["tables"][0]["columns"][0]["kind"] = "text"
        block["tables"][0]["rows"] = [['<script>alert("x")</script> \u0661']]
        self.assertEqual(self.ok(block)["blocks"][0]["tables"][0]["rows"], [['<script>alert("x")</script> \u0661']])

    def test_every_corner_must_evaluate_without_error(self):
        guard = loan_block()
        self.ok(guard)
        # Unguarded division: fine at the start, DIV0 once rate or years reach the minimum.
        unguarded = self.mutated(lambda b: b["cells"][0].update(expression="principal/(years-1)"))
        self.dropped(unguarded)
        self.ok(self.mutated(lambda b: b["cells"][0].update(expression="if(years==1,0[EUR],principal/(years-1))")))
        # Division by zero only at the all-min corner.
        at_min = small_calc()
        at_min["cells"][0]["expression"] = "10/x1"
        self.dropped(at_min)
        at_min["inputs"][0].update(min=1, value=5)
        self.ok(at_min)
        # Error only at the all-max corner (init, min and midpoint are fine).
        at_max = small_calc()
        at_max["cells"][0]["expression"] = "if(x1>=100,1/0,1)"
        self.dropped(at_max)
        at_max["cells"][0]["expression"] = "if(x1>=99,1/0,1)"
        self.dropped(at_max)
        # Error only at the midpoint.
        at_mid = small_calc()
        at_mid["cells"][0]["expression"] = "if(x1==50,1/0,1)"
        self.dropped(at_mid)
        # An unguarded branch carrying a bare 0 where the other branch has a unit.
        plain_zero = self.mutated(lambda b: b["cells"][0].update(expression="if(rate==0,0,principal)"))
        self.dropped(plain_zero)
        # A column row that errors only at a corner, under an aggregate.
        row = small_calc(tables=1, columns=2, rows=2)
        row["tables"][0]["columns"][1].update(kind="formula", expression="1/(n0-x1)")
        row["tables"][0]["rows"] = [["5", ""], ["6", ""]]
        row["cells"][0]["expression"] = "sum(t1.n1)"
        self.dropped(row)
        row["tables"][0]["columns"][1]["expression"] = "iferror(1/(n0-x1),0)"
        self.ok(row)

    def test_colstat_is_rejected_until_sources_are_gated(self):
        # The engine raises SRC at evaluation because validation passes no source
        # statistics, so any colstat cell is rejected at the initial pass. Revisit
        # when the broker supplies env stats.
        block = small_calc()
        block["cells"][0]["expression"] = "colstat(1,sum)"
        self.dropped(block)
        model = catalog.ai_calc.compile_spec({key: block[key] for key in ("inputs", "tables", "cells")})
        result = catalog.ai_calc.evaluate(model, None)
        self.assertEqual(result.nodes["c1"].err["code"], "SRC")
        guarded = small_calc()
        guarded["cells"][0]["expression"] = "iferror(colstat(1,sum),0)"
        self.ok(guarded)  # iferror hides SRC; the cell then honestly shows 0

    # -- answer-level rules and the fallback contract
    def test_one_calc_block_per_answer_keeps_the_first_and_drops_the_extra(self):
        # Softened contract (2026-10-09): a second calc breaks the one-calc rule. The strict
        # validator raises; normalize_response keeps the FIRST calc and drops the later one.
        for extra in (small_calc(), loan_block()):
            with self.assertRaises(ValueError):
                catalog.validate_response(answer([loan_block(), extra]))
            result = self.normalize(answer([loan_block(), extra]))
            self.assertEqual((result["blocks"], result["warning"]), ([loan_block()], catalog.DROPPED_WARNING))
        result = self.normalize(answer([small_calc(), loan_block(), small_calc()]))
        self.assertEqual((result["blocks"], result["warning"]), ([small_calc()], catalog.DROPPED_WARNING))
        slider = CatalogTests.slider_block(None)
        diagram = CatalogTests.diagram_block(None)
        result = self.ok(loan_block(), slider, diagram)
        self.assertEqual([b["type"] for b in result["blocks"]], ["calc", "slider", "diagram"])
        self.assertEqual(self.normalize(answer([loan_block()] + [{"type": "text", "title": "", "text": "x"}] * 5))["warning"], "")
        # Seven blocks break the six-block cap: the first six stay, the seventh is dropped.
        texts = [{"type": "text", "title": "", "text": "x%d" % index} for index in range(6)]
        result = self.normalize(answer([loan_block()] + texts))
        self.assertEqual(result["blocks"], [loan_block()] + texts[:5])
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)

    def test_a_rejected_calc_and_an_invalid_slider_are_dropped_the_same_way(self):
        calc = self.mutated(lambda b: b["cells"][0].update(expression="nothing+1"))
        slider = CatalogTests.slider_block(None)
        slider["readouts"][0]["expression"] = "import(x)"
        good = {"type": "text", "title": "", "text": "kept?"}
        results = []
        for block in (calc, slider):
            value = answer([good, block])
            value["suggestions"] = ["Ask more?"]
            results.append(self.normalize(value))
        self.assertEqual(results[0], results[1])
        # Softened contract (2026-10-09): only the bad block goes; the good text block, the answer
        # and the suggestions stay, and the warning is the generic one (no model text, no reason).
        self.assertEqual(results[0], {"answer": "Readable answer \u2713", "blocks": [good],
                                      "suggestions": ["Ask more?"], "warning": catalog.DROPPED_WARNING})
        self.assertEqual(catalog.DROPPED_WARNING, "Some parts of this answer could not be shown.")
        # The block is never repaired: validate_response still raises, with no engine slug in it.
        for block, slug in ((calc, "unknown-name"), (self.mutated(lambda b: b["cells"][0].update(expression="1e3")), "scientific-literal"),
                            (self.mutated(lambda b: b["cells"][0].update(unit="s")), "UNIT")):
            with self.assertRaises(ValueError) as caught:
                catalog.validate_response(answer([block]))
            self.assertEqual(str(caught.exception), "Calc block is invalid")
            self.assertNotIn(slug, str(caught.exception))
            self.assertIsNone(caught.exception.__cause__)

    def test_validation_detaches_and_does_not_mutate_the_input(self):
        block = loan_block()
        block["inputs"][0]["value"] = 10 ** 9
        before = copy.deepcopy(block)
        result = catalog.validate_response(answer([block]))
        self.assertEqual(block, before)
        self.assertEqual(result["blocks"][0]["inputs"][0]["value"], 50000)

    def test_largest_table_fits_the_response_cap_two_do_not(self):
        big = small_calc(tables=1, columns=12, rows=40)
        big["tables"][0]["rows"] = [["9" * 64] * 12 for _ in range(40)]
        self.assertLess(len(json.dumps(answer([big]), ensure_ascii=False).encode()), catalog.MAX_RESPONSE_BYTES)
        self.ok(big)
        both = small_calc(tables=2, columns=12, rows=40)
        for table in both["tables"]:
            table["rows"] = [["9" * 64] * 12 for _ in range(40)]
        raw = json.dumps(answer([both]), ensure_ascii=False)
        self.assertGreater(len(raw.encode()), catalog.MAX_RESPONSE_BYTES)
        result = catalog.normalize_response(raw)
        self.assertEqual((result["warning"], result["blocks"]), ("Response exceeds byte limit.", []))



def form_field(kind="number", **update):
    """A valid field of the given kind in the canonical (unused = "" / 0 / []) shape."""
    base = {"id": "f1", "label": "Field", "kind": kind, "unit": "", "min": 0, "max": 0, "step": 0,
            "value": 0, "options": [], "placeholder": ""}
    if kind == "number":
        base.update(unit="EUR", min=0, max=5000, step=50, value=1000)
    elif kind == "choice":
        base.update(options=["Train", "Bus", "Car"], value=1)
    elif kind == "text":
        base.update(placeholder="Lisbon")
    elif kind == "toggle":
        base.update(value=1)
    base.update(update)
    return base


def form_block(*fields, **update):
    block = {"type": "form", "title": "Plan the trip", "fields": list(fields) or [form_field()],
             "submitLabel": "Plan it", "note": "Nothing is sent until you submit."}
    block.update(update)
    return block


def fields_of(count):
    return [form_field("number", id="f%d" % index) for index in range(1, count + 1)]


class FormBlockTests(unittest.TestCase):
    def normalize(self, value):
        return catalog.normalize_response(json.dumps(value, ensure_ascii=False))

    def ok(self, *blocks):
        result = self.normalize(answer(list(blocks)))
        self.assertEqual(result["warning"], "", result)
        return result["blocks"]

    def dropped(self, *blocks):
        """Softened contract (2026-10-09): see CalcBlockTests.dropped. Strict validation still raises."""
        value = answer(list(blocks))
        self.assertEqual(self.normalize(value), {"answer": "Readable answer \u2713", "blocks": [],
                                                  "suggestions": ["Explain more?"], "warning": catalog.DROPPED_WARNING})
        with self.assertRaises(ValueError):
            catalog.validate_response(value)

    def with_field(self, kind="number", **update):
        return form_block(form_field(kind, **update))

    # -- shapes
    def test_every_kind_validates_and_round_trips(self):
        block = form_block(form_field("number", id="budget"), form_field("choice", id="mode"),
                           form_field("text", id="city"), form_field("toggle", id="pets"))
        self.assertEqual(self.ok(block), [block])
        self.assertEqual(self.ok(form_block(*fields_of(6)))[0]["fields"], fields_of(6))
        # Empty title, submit label and note are allowed (the renderer supplies a default label).
        self.ok(form_block(title="", submitLabel="", note=""))

    def test_catalog_prose_is_present_and_small(self):
        text = " ".join(catalog.SYSTEM_INSTRUCTIONS.split())
        self.assertIn("-> one form block of 1-6 fields", text)
        self.assertIn("Not for numbers varied to see an effect (calc) or a quiz (check, predict).", text)
        self.assertIn("at most one each of form, actions, compare and timeline;", text)
        start = catalog.SYSTEM_INSTRUCTIONS.index("- Several typed answers")
        end = catalog.SYSTEM_INSTRUCTIONS.index(catalog._GUIDE_BULLETS)
        self.assertLessEqual(len(catalog.SYSTEM_INSTRUCTIONS[start:end].encode()), 450)

    def test_exact_keys(self):
        for level, keys in (("block", list(form_block())), ("field", list(form_field()))):
            for key in keys:
                with self.subTest(level=level, missing=key):
                    block = form_block()
                    target = block if level == "block" else block["fields"][0]
                    del target[key]
                    self.dropped(block)
            with self.subTest(level=level, extra=True):
                block = form_block()
                (block if level == "block" else block["fields"][0])["extra"] = "x"
                self.dropped(block)

    # -- caps, each at the limit and one past it
    def test_array_caps(self):
        self.ok(form_block(*fields_of(1)))
        self.ok(form_block(*fields_of(6)))
        self.dropped(form_block(*fields_of(7)))
        self.dropped(form_block(fields=[]))
        for count, good in ((1, False), (2, True), (6, True), (7, False), (0, False)):
            with self.subTest(options=count):
                options = ["Option %d" % index for index in range(count)]
                (self.ok if good else self.dropped)(self.with_field("choice", options=options, value=0))

    def test_string_caps(self):
        cases = [("block", "title", 160), ("block", "submitLabel", 32), ("block", "note", 240),
                 ("field", "label", 80), ("field", "unit", 16), ("field", "placeholder", 60),
                 ("field", "id", 24)]
        for level, key, limit in cases:
            def build(text, level=level, key=key):
                kind = "text" if key == "placeholder" else "number"
                if level == "block":
                    return form_block(**{key: text})
                return form_block(form_field(kind, **{key: text}))
            filler = "a" * limit if key == "id" else "x" * limit
            with self.subTest(level=level, key=key):
                result = self.ok(build(filler))
                self.assertEqual((result[0] if level == "block" else result[0]["fields"][0])[key], filler)
                self.dropped(build(filler + "a"))
        with self.subTest(option=48):
            self.ok(self.with_field("choice", options=["\u00e9" * 48, "b"]))
            self.dropped(self.with_field("choice", options=["\u00e9" * 49, "b"]))
        with self.subTest(label_blank=True):
            for label in ("", " ", "  "):
                self.dropped(self.with_field("number", label=label))

    def test_numeric_caps(self):
        for update, good in (({"min": -1e9, "max": 0}, True), ({"min": -1e9 - 1}, False), ({"min": None}, False),
                             ({"max": 1e9}, True), ({"max": 1e9 + 1}, False),
                             ({"step": 1e9}, True), ({"step": 1e9 + 1}, False),
                             ({"step": 0}, False), ({"step": -1}, False),
                             ({"value": 1e9}, True), ({"value": -1e9}, True),
                             ({"value": 1e9 + 1}, False), ({"value": -1e9 - 1}, False),
                             ({"value": True}, False), ({"value": "5"}, False),
                             ({"value": float("nan")}, False), ({"step": float("inf")}, False)):
            with self.subTest(update=update):
                block = self.with_field("number", **update)
                (self.ok if good else self.dropped)(block)  # a value outside min..max is clamped, not rejected
        # The schema range itself, independent of the clamp.
        block = self.with_field("number", min=-1e9, max=1e9, step=1e9, value=-1e9)
        self.assertEqual(self.ok(block)[0]["fields"][0]["value"], -1e9)

    # -- normalization, per kind
    def test_number_clamps_value_and_step_and_needs_an_increasing_range(self):
        for given, expected in ((9999, 5000), (-7, 0), (1234, 1234)):
            self.assertEqual(self.ok(self.with_field("number", value=given))[0]["fields"][0]["value"], expected)
        self.assertEqual(self.ok(self.with_field("number", step=9000))[0]["fields"][0]["step"], 5000)
        for low, high in ((5, 5), (6, 5)):
            self.dropped(self.with_field("number", min=low, max=high, value=5))

    def test_choice_value_is_a_clamped_index_and_options_are_distinct(self):
        for given, expected in ((0, 0), (2, 2), (3, 2), (99, 2), (-4, 0), (1.0, 1)):
            result = self.ok(self.with_field("choice", value=given))[0]["fields"][0]
            self.assertEqual((result["value"], type(result["value"])), (expected, int))
        self.dropped(self.with_field("choice", value=0.5))
        self.dropped(self.with_field("choice", options=["Same", "Same"]))
        for options in (["A", ""], ["A", " "], ["A", "\u00a0\u00a0"]):
            self.dropped(self.with_field("choice", options=options, value=0))

    def test_toggle_is_zero_or_one_and_text_ignores_its_value(self):
        for given in (0, 1, 1.0, 0.0):
            self.assertEqual(self.ok(self.with_field("toggle", value=given))[0]["fields"][0]["value"], int(given))
        for given in (2, -1, 0.5):
            self.dropped(self.with_field("toggle", value=given))
        self.assertEqual(self.ok(self.with_field("text", value=7))[0]["fields"][0]["value"], 0)

    def test_values_a_kind_ignores_are_reset(self):
        messy = {"unit": "kg", "min": 3, "max": 9, "step": 2, "placeholder": "hint", "options": ["a", "b"], "value": 1}
        for kind in ("choice", "text", "toggle"):
            with self.subTest(kind=kind):
                field = self.ok(self.with_field(kind, **messy))[0]["fields"][0]
                self.assertEqual((field["unit"], field["min"], field["max"], field["step"]), ("", 0, 0, 0))
                self.assertEqual(field["options"], ["a", "b"] if kind == "choice" else [])
                self.assertEqual(field["placeholder"], "hint" if kind == "text" else "")
        field = self.ok(self.with_field("number", placeholder="hint", options=["a"]))[0]["fields"][0]
        self.assertEqual((field["placeholder"], field["options"], field["unit"]), ("", [], "EUR"))

    def test_validation_detaches_and_never_mutates(self):
        block = self.with_field("number", value=10 ** 9 - 1)
        block["fields"][0]["max"] = 100
        before = copy.deepcopy(block)
        result = catalog.validate_block(block)
        self.assertEqual(block, before)
        self.assertEqual(result["fields"][0]["value"], 100)
        result["fields"][0]["label"] = "changed"
        self.assertEqual(block, before)

    # -- ids, counts
    def test_ids_are_unique_and_well_formed(self):
        self.dropped(form_block(form_field("number", id="a"), form_field("toggle", id="a")))
        self.ok(form_block(form_field("number", id="a"), form_field("toggle", id="b")))
        for bad_id in ("X1", "1x", "a-b", "_a", "a" * 25, "", "x\u0663", "\u0430bc", "a b", "a\n"):
            with self.subTest(bad_id=bad_id):
                self.dropped(self.with_field("number", id=bad_id))
        for good in ("a", "a_1", "z" * 24):
            self.ok(self.with_field("number", id=good))

    def test_one_form_per_answer(self):
        # Softened contract (2026-10-09): the strict validator raises for a second form,
        # normalize_response keeps the first and drops the later one.
        with self.assertRaises(ValueError):
            catalog.validate_response(answer([form_block(), form_block()]))
        second = form_block(form_field("toggle", id="other"), title="Second form")
        result = self.normalize(answer([form_block(), second]))
        self.assertEqual((result["blocks"], result["warning"]), ([form_block()], catalog.DROPPED_WARNING))
        result = self.ok(form_block(), loan_block(), CatalogTests.slider_block(None))
        self.assertEqual([block["type"] for block in result], ["form", "calc", "slider"])
        self.assertEqual(self.normalize(answer([form_block()] + [{"type": "text", "title": "", "text": "x"}] * 5))["warning"], "")
        texts = [{"type": "text", "title": "", "text": "x%d" % index} for index in range(6)]
        result = self.normalize(answer([form_block()] + texts))
        self.assertEqual(result["blocks"], [form_block()] + texts[:5])
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)

    # -- hostile strings: cleaned to one plain line, then judged
    HOSTILE = ["a\nb", "a\tb", "a\rb", "a\x00b", "a\x1bb", "a\x7fb", "a\x85b", "a\u2028b", "a\u2029b",
               "a\u200bb", "a\u200fb", "a\u202eb", "a\u2066b", "a\u2069b", "a\ufeffb", "a\u00adb",
               "a\ue000b", "a\u200db", "a\n\r\t  b", "a\u202e\u2066b"]
    SLOTS = [("title",), ("submitLabel",), ("note",), ("fields", 0, "label"), ("fields", 0, "unit"),
             ("fields", 1, "placeholder"), ("fields", 2, "options", 0), ("fields", 2, "options", 1)]

    def dirty_block(self, slot, text):
        block = form_block(form_field("number", id="n"), form_field("text", id="t"), form_field("choice", id="c"))
        target = block
        for key in slot[:-1]:
            target = target[key]
        target[slot[-1]] = text
        return block

    @staticmethod
    def at(block, slot):
        for key in slot:
            block = block[key]
        return block

    def test_control_format_and_separator_characters_become_a_space(self):
        for slot in self.SLOTS:
            for text in self.HOSTILE:
                with self.subTest(slot=slot, text=text):
                    result = self.ok(self.dirty_block(slot, text))[0]
                    self.assertEqual(self.at(result, slot), "a b")

    def test_padding_is_trimmed_and_runs_collapse(self):
        for slot in self.SLOTS:
            for text, expected in (("  \n lead and trail \t ", "lead and trail"), ("a    b", "a b"),
                                   ("\u200b\u202ea", "a"), ("a\u00a0\u00a0 b", "a b")):
                with self.subTest(slot=slot, text=text):
                    self.assertEqual(self.at(self.ok(self.dirty_block(slot, text))[0], slot), expected)

    def test_caps_apply_after_cleaning(self):
        for slot, limit in ((("title",), 160), (("submitLabel",), 32), (("note",), 240), (("fields", 0, "label"), 80),
                            (("fields", 0, "unit"), 16), (("fields", 1, "placeholder"), 60),
                            (("fields", 2, "options", 0), 48)):
            with self.subTest(slot=slot):
                padded = "\n " + "x" * limit + " \u200b\t"
                self.assertEqual(self.at(self.ok(self.dirty_block(slot, padded))[0], slot), "x" * limit)
                self.dropped(self.dirty_block(slot, "x" * (limit + 1)))
                self.dropped(self.dirty_block(slot, "x\n" * limit))  # 2 * limit raw, but "x x x ..." is still too long

    def test_empty_after_cleaning_is_rejected_where_content_is_required(self):
        junk = "\n\u200b\u202e\t \ue000"
        self.dropped(self.dirty_block(("fields", 0, "label"), junk))
        self.dropped(self.dirty_block(("fields", 2, "options", 0), junk))
        self.dropped(form_block(form_field("choice", options=["a b", "a\nb"])))  # distinct only before cleaning
        # Display strings that may be empty stay valid, and the field keeps its other content.
        result = self.ok(self.dirty_block(("note",), junk))[0]
        self.assertEqual((result["note"], result["fields"][0]["label"]), ("", "Field"))

    def test_lone_surrogates_are_cleaned_too(self):
        raw = json.dumps(answer([form_block(note="x")])).replace('"x"', '"p\\ud800q"')
        result = catalog.normalize_response(raw)
        self.assertEqual(result["warning"], "")
        self.assertEqual(result["blocks"][0]["note"], "p q")

    def test_markup_is_plain_text_and_ordinary_unicode_passes(self):
        words = ['<script>alert("x")</script>', "<b>bold</b> & more", "[click](https://evil.example/x)",
                 "javascript:alert(1)", "{{template}}", "\u00e9\u00e8 \u6771\u4eac \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u2615"]
        for text in words:
            with self.subTest(text=text):
                block = form_block(form_field("number", label=text), form_field("choice", id="c", options=[text, "Other"]),
                                   form_field("text", id="t", placeholder=text), title=text, note=text, submitLabel=text[:32])
                result = self.ok(block)[0]
                self.assertEqual(result["title"], text)
                self.assertEqual(result["fields"][0]["label"], text)
                self.assertEqual(result["fields"][1]["options"][0], text)
                self.assertEqual(result["fields"][2]["placeholder"], text)

    def test_cleaning_does_not_touch_the_input(self):
        block = self.dirty_block(("fields", 0, "label"), " a\nb ")
        before = copy.deepcopy(block)
        self.assertEqual(catalog.validate_block(block)["fields"][0]["label"], "a b")
        self.assertEqual(block, before)

    # -- schema and validator agree
    def test_schema_and_validator_agree_on_the_limits(self):
        form = next(alt for alt in catalog.ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"]
                    if alt["properties"]["type"].get("enum") == ["form"])
        props = form["properties"]
        field = props["fields"]["items"]["properties"]
        self.assertEqual(list(props), ["type", "title", "fields", "submitLabel", "note"])
        self.assertEqual((props["fields"]["minItems"], props["fields"]["maxItems"]), (1, 6))
        self.assertEqual(list(field), ["id", "label", "kind", "unit", "min", "max", "step", "value", "options", "placeholder"])
        self.assertEqual(field["kind"]["enum"], ["number", "choice", "text", "toggle"])
        self.assertEqual((props["title"]["maxLength"], props["submitLabel"]["maxLength"], props["note"]["maxLength"]),
                         (160, 32, 240))
        self.assertEqual((field["label"]["maxLength"], field["unit"]["maxLength"], field["placeholder"]["maxLength"],
                          field["options"]["maxItems"], field["options"]["items"]["maxLength"]), (80, 16, 60, 6, 48))
        for key in ("min", "max", "value"):
            self.assertEqual((field[key]["minimum"], field[key]["maximum"]), (-1e9, 1e9))
        self.assertEqual((field["step"]["minimum"], field["step"]["maximum"]), (0, 1e9))
        self.assertEqual(field["id"]["pattern"], "^[a-z][a-z0-9_]{0,23}$")
        # The schema alone accepts what only the validator can reject (the schema cannot say "min < max").
        loose = self.with_field("number", min=5, max=5, value=5)
        catalog._validate(loose, catalog._BLOCK_SCHEMA)
        with self.assertRaises(ValueError):
            catalog.validate_block(loose)


def action(label="Lisbon", hint="Sunny and walkable"):
    return {"label": label, "hint": hint}


def actions_block(**update):
    block = {"type": "actions", "title": "Pick a destination",
             "options": [action("Lisbon", "Sunny and walkable"), action("Porto", ""), action("Seville", "Hot in summer")]}
    block.update(update)
    return block


def compare_fact(label="Screen", value="6.3 in"):
    return {"label": label, "value": value}


def compare_option(name="Pixel 11", **update):
    option = {"name": name, "summary": "Clean software and a strong camera.", "facts": [compare_fact()],
              "pros": ["Camera", "Updates"], "cons": ["Slower charging"], "recommended": False}
    option.update(update)
    return option


def compare_block(**update):
    block = {"type": "compare", "title": "iPhone 17 or Pixel 11",
             "options": [compare_option("iPhone 17", recommended=True), compare_option("Pixel 11")],
             "verdict": "Pick the iPhone if you already use a Mac."}
    block.update(update)
    return block


def timeline_item(label="Preheat the oven", **update):
    item = {"label": label, "when": "16:00", "minutes": 15, "detail": "220 C, fan on."}
    item.update(update)
    return item


def timeline_block(**update):
    block = {"type": "timeline", "title": "Roast chicken dinner",
             "items": [timeline_item(), timeline_item("Season the chicken", when="16:15", minutes=10, detail=""),
                       timeline_item("Roast", when="16:30", minutes=75)]}
    block.update(update)
    return block


class DynamicUiBlockTests(unittest.TestCase):
    """actions, compare and timeline: the dynamic UI vocabulary (2026-10-10).

    Same machinery as the form: every string is cleaned to one plain line, THEN the schema caps
    judge it; only a structural failure drops the block (never repaired), and a dropped block
    costs the answer nothing but the generic warning. Ids are not needed here.
    """
    BUILDERS = {"actions": actions_block, "compare": compare_block, "timeline": timeline_block}

    def normalize(self, value):
        return catalog.normalize_response(json.dumps(value, ensure_ascii=False))

    def ok(self, *blocks):
        result = self.normalize(answer(list(blocks)))
        self.assertEqual(result["warning"], "", result)
        return result["blocks"]

    def dropped(self, *blocks):
        value = answer(list(blocks))
        self.assertEqual(self.normalize(value), {"answer": "Readable answer \u2713", "blocks": [],
                                                  "suggestions": ["Explain more?"], "warning": catalog.DROPPED_WARNING})
        with self.assertRaises(ValueError):
            catalog.validate_response(value)
        with self.assertRaises(ValueError):
            catalog.validate_block(blocks[0])

    @staticmethod
    def at(block, slot):
        for key in slot:
            block = block[key]
        return block

    @staticmethod
    def put(block, slot, value):
        target = block
        for key in slot[:-1]:
            target = target[key]
        target[slot[-1]] = value
        return block

    @staticmethod
    def string_slots(node, prefix=()):
        """Every path to a string leaf below the block's own type, read from a valid sample."""
        if isinstance(node, dict):
            return [slot for key, value in node.items() if prefix or key != "type"
                    for slot in DynamicUiBlockTests.string_slots(value, prefix + (key,))]
        if isinstance(node, list):
            return [slot for index, value in enumerate(node)
                    for slot in DynamicUiBlockTests.string_slots(value, prefix + (index,))]
        return [prefix] if isinstance(node, str) else []

    # slot -> (maximum, minimum) characters, as the brief states them
    CAPS = {
        "actions": {("title",): (160, 1), ("options", 0, "label"): (40, 1), ("options", 0, "hint"): (60, 0)},
        "compare": {("title",): (160, 1), ("verdict",): (240, 0), ("options", 0, "name"): (48, 1),
                    ("options", 0, "summary"): (120, 0), ("options", 0, "facts", 0, "label"): (24, 1),
                    ("options", 0, "facts", 0, "value"): (40, 1), ("options", 0, "pros", 0): (70, 1),
                    ("options", 0, "cons", 0): (70, 1)},
        "timeline": {("title",): (160, 1), ("items", 0, "label"): (80, 1), ("items", 0, "when"): (24, 0),
                     ("items", 0, "detail"): (160, 0)},
    }

    # -- shapes
    def test_valid_blocks_round_trip_exactly(self):
        for kind, build in self.BUILDERS.items():
            with self.subTest(kind=kind):
                self.assertEqual(self.ok(build()), [build()])
        # The smallest legal shapes: empty hints, summaries, facts, pros, cons, verdict, when, detail.
        bare = [actions_block(options=[action("A", ""), action("B", "")]),
                compare_block(options=[compare_option("A", summary="", facts=[], pros=[], cons=[]),
                                       compare_option("B", summary="", facts=[], pros=[], cons=[])], verdict=""),
                timeline_block(items=[timeline_item("A", when="", minutes=0, detail=""),
                                      timeline_item("B", when="", minutes=0, detail="")])]
        for block in bare:
            with self.subTest(bare=block["type"]):
                self.assertEqual(self.ok(block), [block])
        # The largest: at every array cap and every string cap at once.
        full = {
            "actions": actions_block(options=[action("\u00e9" * 40, "\u00e9" * 60) | {"label": "\u00e9" * 39 + str(i)}
                                              for i in range(6)]),
            "compare": compare_block(title="t" * 160, verdict="v" * 240, options=[
                compare_option("n" * 47 + str(i), summary="s" * 120,
                               facts=[compare_fact("l" * 24, "v" * 40) for _ in range(4)],
                               pros=["p" * 70] * 4, cons=["c" * 70] * 4, recommended=i == 2) for i in range(4)]),
            "timeline": timeline_block(items=[timeline_item("l" * 80, when="w" * 24, minutes=1440, detail="d" * 160)
                                              | {"label": "l" * 79 + chr(97 + i)} for i in range(16)]),
        }
        for kind, block in full.items():
            with self.subTest(full=kind):
                self.assertEqual(self.ok(block), [block])
                self.assertLess(len(json.dumps(block).encode()), 16384)

    def test_exact_keys_at_every_level_and_no_score_fields(self):
        paths = {"actions": [(), ("options", 0)], "compare": [(), ("options", 0), ("options", 0, "facts", 0)],
                 "timeline": [(), ("items", 0)]}
        for kind, build in self.BUILDERS.items():
            for path in paths[kind]:
                for key in list(self.at(build(), path)):
                    with self.subTest(kind=kind, path=path, missing=key):
                        block = build()
                        del self.at(block, path)[key]
                        self.dropped(block)
                for extra in ("extra", "id", "score", "rating", "recommendedScore"):
                    with self.subTest(kind=kind, path=path, extra=extra):
                        block = build()
                        self.at(block, path)[extra] = 5
                        self.dropped(block)

    def test_array_caps_each_at_the_limit_and_one_past_it(self):
        def options(count):
            return [action("Option %d" % index, "") for index in range(count)]

        def compared(count):
            return [compare_option("Option %d" % index, recommended=False) for index in range(count)]

        def items(count):
            return [timeline_item("Item %d" % index) for index in range(count)]
        cases = [(lambda n: actions_block(options=options(n)), (0, 1, 2, 6, 7), (2, 6)),
                 (lambda n: compare_block(options=compared(n)), (0, 1, 2, 4, 5), (2, 4)),
                 (lambda n: timeline_block(items=items(n)), (0, 1, 2, 16, 17), (2, 16))]
        for build, counts, allowed in cases:
            for count in counts:
                with self.subTest(kind=build(2)["type"], count=count):
                    (self.ok if count in allowed else self.dropped)(build(count))
        for key in ("facts", "pros", "cons"):
            for count in (0, 4, 5):
                filler = [compare_fact("L%d" % i, "v") for i in range(count)] if key == "facts" else ["x%d" % i for i in range(count)]
                with self.subTest(key=key, count=count):
                    block = compare_block(options=[compare_option("A", **{key: filler}), compare_option("B")])
                    (self.ok if count <= 4 else self.dropped)(block)

    def test_string_caps_each_at_the_limit_and_one_past_it(self):
        for kind, slots in self.CAPS.items():
            for slot, (high, low) in slots.items():
                build = self.BUILDERS[kind]
                with self.subTest(kind=kind, slot=slot, high=high):
                    for filler in ("x" * high, "\u00e9" * high, "\U0001f600" * high):
                        self.assertEqual(self.at(self.ok(self.put(build(), slot, filler))[0], slot), filler)
                    self.dropped(self.put(build(), slot, "x" * (high + 1)))
                with self.subTest(kind=kind, slot=slot, low=low):
                    for junk in ("", " ", " \n\t ", "\u200b\u202e", "\ue000"):
                        if low:
                            self.dropped(self.put(build(), slot, junk))
                        else:
                            self.assertEqual(self.at(self.ok(self.put(build(), slot, junk))[0], slot), "")

    def test_the_schema_says_what_the_brief_says(self):
        types = {alt["properties"]["type"]["enum"][0]: alt["properties"]
                 for alt in catalog.ANSWER_SCHEMA["properties"]["blocks"]["items"]["anyOf"]
                 if alt["properties"]["type"]["enum"][0] in self.BUILDERS}
        self.assertEqual(set(types), set(self.BUILDERS))
        self.assertEqual(list(types["actions"]), ["type", "title", "options"])
        self.assertEqual(list(types["compare"]), ["type", "title", "options", "verdict"])
        self.assertEqual(list(types["timeline"]), ["type", "title", "items"])
        actions = types["actions"]["options"]
        self.assertEqual((actions["minItems"], actions["maxItems"]), (2, 6))
        self.assertEqual(list(actions["items"]["properties"]), ["label", "hint"])
        compare = types["compare"]["options"]
        option = compare["items"]["properties"]
        self.assertEqual((compare["minItems"], compare["maxItems"]), (2, 4))
        self.assertEqual(list(option), ["name", "summary", "facts", "pros", "cons", "recommended"])
        self.assertEqual(option["recommended"], {"type": "boolean"})
        self.assertEqual((option["facts"].get("minItems", 0), option["facts"]["maxItems"]), (0, 4))
        self.assertEqual(list(option["facts"]["items"]["properties"]), ["label", "value"])
        for key in ("pros", "cons"):
            self.assertEqual((option[key].get("minItems", 0), option[key]["maxItems"]), (0, 4))
            self.assertEqual((option[key]["items"]["minLength"], option[key]["items"]["maxLength"]), (1, 70))
        timeline = types["timeline"]["items"]
        item = timeline["items"]["properties"]
        self.assertEqual((timeline["minItems"], timeline["maxItems"]), (2, 16))
        self.assertEqual(list(item), ["label", "when", "minutes", "detail"])
        self.assertEqual(item["minutes"], {"type": "integer", "minimum": 0, "maximum": 1440})
        # Every string cap in CAPS is the schema's own: walk the schema, not a second list.
        for kind, slots in self.CAPS.items():
            for slot, (high, low) in slots.items():
                node = types[kind][slot[0]]
                for key in slot[1:]:
                    node = node["items"] if isinstance(key, int) else node["properties"][key]
                self.assertEqual((node.get("minLength", 0), node["maxLength"]), (low, high), (kind, slot))

    # -- actions
    def test_action_labels_are_distinct_after_cleaning_ignoring_case(self):
        self.ok(actions_block(options=[action("Lisbon", "same hint"), action("Porto", "same hint")]))
        self.ok(actions_block(options=[action("Lisbon", ""), action("Lisbon 2", "")]))
        for pair in (("Lisbon", "lisbon"), ("Lisbon", "LISBON "), ("Lisbon", "\u200bLisbon"), ("Li\nsbon", "Li sbon"),
                     ("Stra\u00dfe", "STRASSE"), ("\uff21\uff22", "ab"), ("e\u0301", "\u00e9")):
            with self.subTest(pair=pair):
                self.dropped(actions_block(options=[action(pair[0]), action(pair[1])]))
        self.dropped(actions_block(options=[action("A"), action("B"), action("C"), action("a")]))

    # -- compare
    def test_compare_names_are_distinct_after_cleaning_ignoring_case(self):
        self.ok(compare_block(options=[compare_option("A"), compare_option("B"), compare_option("C")]))
        for pair in (("Pixel 11", "pixel 11"), ("Pixel\n11", "Pixel 11 "), ("iPhone", "IPHONE")):
            with self.subTest(pair=pair):
                self.dropped(compare_block(options=[compare_option(pair[0]), compare_option(pair[1])]))

    def test_at_most_one_option_is_recommended_and_the_first_one_wins(self):
        def flags(*values):
            block = compare_block(options=[compare_option("Option %d" % index, recommended=value)
                                           for index, value in enumerate(values)])
            return [option["recommended"] for option in self.ok(block)[0]["options"]]
        self.assertEqual(flags(False, False), [False, False])
        self.assertEqual(flags(True, False), [True, False])
        self.assertEqual(flags(False, True), [False, True])
        self.assertEqual(flags(True, True), [True, False])
        self.assertEqual(flags(False, True, True, True), [False, True, False, False])
        self.assertEqual(flags(True, True, True, True), [True, False, False, False])
        # Sanitising never rejects, and the strict pass agrees with the soft one.
        block = compare_block(options=[compare_option("A", recommended=True), compare_option("B", recommended=True)])
        strict = catalog.validate_response(answer([block]))["blocks"][0]
        self.assertEqual([option["recommended"] for option in strict["options"]], [True, False])
        self.assertEqual([option["recommended"] for option in block["options"]], [True, True])  # input untouched
        for value in ("true", 1, None, "yes"):
            with self.subTest(value=value):
                self.dropped(compare_block(options=[compare_option("A", recommended=value), compare_option("B")]))

    # -- timeline
    def test_minutes_are_whole_numbers_in_range(self):
        for good in (0, 1, 75, 1440):
            self.assertEqual(self.ok(timeline_block(items=[timeline_item("A", minutes=good), timeline_item("B")]))[0]
                             ["items"][0]["minutes"], good)
        # Nothing is clamped or rounded: a wrong value is a dropped block. A float is refused
        # even when whole (30.0), exactly like every other integer field in the schema.
        for bad in (-1, 1441, 10 ** 6, 1.5, 0.5, 30.0, 1439.999, True, False, "30", None, [30], float("nan"),
                    float("inf")):
            with self.subTest(minutes=bad):
                self.dropped(timeline_block(items=[timeline_item("A", minutes=bad), timeline_item("B")]))

    def test_authored_order_is_kept_never_sorted_by_when(self):
        items = [timeline_item("Dessert", when="21:00", minutes=30), timeline_item("Prep", when="09:00", minutes=5),
                 timeline_item("Late", when="Day 2", minutes=1440), timeline_item("Start", when="", minutes=0),
                 timeline_item("Evening", when="18:00", minutes=45), timeline_item("Same", when="18:00", minutes=45)]
        result = self.ok(timeline_block(items=items))[0]["items"]
        self.assertEqual([item["label"] for item in result], [item["label"] for item in items])
        self.assertEqual(result, items)

    # -- one per answer, soft failure, cross-block caps
    def test_one_of_each_per_answer_first_wins_and_the_strict_pass_raises(self):
        for kind, build in self.BUILDERS.items():
            with self.subTest(kind=kind):
                second = build(title="Second one")
                with self.assertRaises(ValueError):
                    catalog.validate_response(answer([build(), second]))
                result = self.normalize(answer([build(), second, text_block("t")]))
                self.assertEqual((result["blocks"], result["warning"]), ([build(), text_block("t")], catalog.DROPPED_WARNING))
                # Two valid blocks are each fine on their own: the one-per-answer rule is the answer's.
                catalog.validate_block(second)
        # Different types coexist, with the older unique blocks, inside the six-block cap.
        blocks = [actions_block(), compare_block(), timeline_block(), form_block(), loan_block(), CatalogTests.slider_block(None)]
        self.assertEqual([block["type"] for block in self.ok(*blocks)],
                         ["actions", "compare", "timeline", "form", "calc", "slider"])
        result = self.normalize(answer(blocks + [text_block("seventh")]))
        self.assertEqual(len(result["blocks"]), 6)
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)

    def test_a_bad_block_costs_only_itself(self):
        for kind, build in self.BUILDERS.items():
            broken = build()
            broken["title"] = "\u200b"  # empty once cleaned, and a title is required
            result = self.normalize(answer([text_block("before"), broken, chart(), build(title="Fine")]))
            with self.subTest(kind=kind):
                self.assertEqual([block["type"] for block in result["blocks"]], ["text", "chart", kind])
                self.assertEqual(result["blocks"][-1]["title"], "Fine")
                self.assertEqual((result["answer"], result["suggestions"], result["warning"]),
                                 ("Readable answer \u2713", ["Explain more?"], catalog.DROPPED_WARNING))
        leaking = actions_block(title="<script>alert(1)</script> SECRET-MODEL-TEXT", options=[action("Only")])
        result = self.normalize(answer([leaking]))
        self.assertEqual((result["blocks"], result["warning"]), ([], catalog.DROPPED_WARNING))
        self.assertNotIn("SECRET", json.dumps(result))

    def test_an_unknown_type_is_never_cleaned_into_a_known_one(self):
        for kind, build in self.BUILDERS.items():
            for spelled in (kind + "\n", " " + kind, kind.upper(), kind + "\u200b"):
                with self.subTest(kind=kind, spelled=spelled):
                    self.dropped(build(type=spelled))
        deep = []
        for _ in range(300):
            deep = [deep]
        for block in (actions_block(options=deep), compare_block(options=[compare_option("A", facts=deep), compare_option("B")]),
                      timeline_block(items=deep)):
            self.dropped(block)

    # -- hostile strings
    HOSTILE = FormBlockTests.HOSTILE

    def test_every_string_slot_is_cleaned_to_one_plain_line(self):
        for kind, build in self.BUILDERS.items():
            slots = self.string_slots(build())
            self.assertGreaterEqual(len(slots), 8 if kind == "compare" else 4, (kind, slots))
            for slot in slots:
                for text in self.HOSTILE:
                    with self.subTest(kind=kind, slot=slot, text=text):
                        block = self.put(build(), slot, text)
                        before = copy.deepcopy(block)
                        result = self.ok(block)[0]
                        self.assertEqual(self.at(result, slot), "a b")
                        self.assertEqual(block, before, "the input is never mutated")
                for text, expected in (("  \n lead and trail \t ", "lead and trail"), ("a    b", "a b"),
                                       ("\u200b\u202ea", "a"), ("a\u00a0\u00a0 b", "a b")):
                    with self.subTest(kind=kind, slot=slot, padded=text):
                        self.assertEqual(self.at(self.ok(self.put(build(), slot, text))[0], slot), expected)

    def test_caps_apply_after_cleaning(self):
        for kind, slots in self.CAPS.items():
            for slot, (high, _) in slots.items():
                build = self.BUILDERS[kind]
                with self.subTest(kind=kind, slot=slot):
                    padded = "\n " + "x" * high + " \u200b\t"
                    self.assertEqual(self.at(self.ok(self.put(build(), slot, padded))[0], slot), "x" * high)
                    self.dropped(self.put(build(), slot, "x\n" * high))  # 2 * high raw, "x x x ..." is too long

    def test_markup_is_plain_text_and_ordinary_unicode_passes(self):
        words = ['<script>alert("x")</script>', "<b>bold</b> & more", "[click](https://evil.example/x)",
                 "javascript:alert(1)", "{{template}}", "\u00e9\u00e8 \u6771\u4eac \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u2615"]
        for text in words:
            with self.subTest(text=text):
                short = text[:20]
                block = actions_block(title=text, options=[action(short, text[:60]), action("Other", "")])
                result = self.ok(block)[0]
                self.assertEqual((result["title"], result["options"][0]["label"], result["options"][0]["hint"]),
                                 (text, short, text[:60]))
                block = compare_block(title=text, verdict=text, options=[
                    compare_option(short, summary=text, facts=[compare_fact(text[:24], text[:40])], pros=[text[:70]],
                                   cons=[text[:70]]), compare_option("Other")])
                result = self.ok(block)[0]
                self.assertEqual((result["title"], result["verdict"], result["options"][0]["summary"],
                                  result["options"][0]["pros"], result["options"][0]["facts"][0]["value"]),
                                 (text, text, text, [text[:70]], text[:40]))
                block = timeline_block(title=text, items=[timeline_item(text[:80], when=text[:24], detail=text),
                                                          timeline_item("Next")])
                result = self.ok(block)[0]
                self.assertEqual((result["title"], result["items"][0]["label"], result["items"][0]["detail"]),
                                 (text, text[:80], text))

    def test_lone_surrogates_are_cleaned_too(self):
        raw = json.dumps(answer([actions_block()])).replace('"Pick a destination"', '"p\\ud800q"')
        result = catalog.normalize_response(raw)
        self.assertEqual(result["warning"], "")
        self.assertEqual(result["blocks"][0]["title"], "p q")

    # -- parity with the strict pass
    def test_validate_block_matches_validate_response(self):
        for build in self.BUILDERS.values():
            block = build()
            for slot in self.string_slots(block):
                self.put(block, slot, "  " + self.at(block, slot) + "\u202e\n")
            final = catalog.validate_response(answer([block]))["blocks"][0]
            self.assertEqual(catalog.validate_block(block), final)
            self.assertEqual(final, build())


# Every block of every fixture answer below must come out of validate_block exactly as
# validate_response produced it. Mutation check (done once, on a /tmp copy, not committed):
# replacing validate_block's `_finish_block(result)` with a no-op while validate_response kept
# its own strict per-block path made test_blocks_match_the_final_pass fail on the richtext
# sanitizer, the slider/calc/form clamps and the source URL canonicalization; restoring it
# made them pass again. A divergence between a streaming pass and the final pass fails here.
def parity_answers():
    """(name, blocks) pairs: each is one valid answer, so the cross-block rules hold too."""
    slider, diagram = CatalogTests.slider_block(None), CatalogTests.diagram_block(None)
    linked = copy.deepcopy(slider)
    linked["links"] = [{"part": 1, "property": "rotation", "expression": "x*15"}]
    clamped_slider = copy.deepcopy(slider)
    clamped_slider["control"].update(value=99, step=500)
    clamped_calc = loan_block()
    clamped_calc["inputs"][0]["value"] = 10 ** 9
    clamped_calc["inputs"][1]["step"] = 500
    messy_form = form_block(form_field("number", value=10 ** 6, step=10 ** 7), form_field("choice", id="c", value=99),
                            form_field("text", id="t", value=5, unit="kg"), form_field("toggle", id="g"))
    dirty_form = form_block(form_field("number", id="n", label="  Budget\n(EUR)\u202e ", unit="\u200bEUR"),
                            form_field("choice", id="c", options=["Tr\nain", "Bus\t", " Car"]),
                            form_field("text", id="t", placeholder="Ci\u2028ty"),
                            title="Plan\r\nthe trip", note="x" * 240 + "\n  ", submitLabel="\ufeffGo")
    steps, check, predict = CatalogTests.learning_blocks(None)
    return [
        ("learning", [diagram, linked, steps, check, predict]),
        ("exploration", [
            {"type": "gallery", "title": "Styles", "items": [
                {"query": "Gothic", "caption": "Pointed arches"}, {"query": "Romanesque", "caption": "Round arches"}]},
            {"type": "table", "title": "Compare", "columns": ["Style", "Era"], "rows": [["Gothic", "12th c."]]},
            {"type": "sources", "title": "Sources", "items": [
                {"label": "A", "url": "HTTPS://Example.COM:443/a?utm_source=x#top"}]}]),
        ("mini-app", [loan_block(), {"type": "sources", "title": "Rates", "items": [
            {"label": "ECB", "url": "https://example.com/rates"}]}, {"type": "checklist", "title": "Tasks", "items": ["a", "b"]}]),
        ("calc-example", [catalog.CALC_EXAMPLE]),
        ("calc-shape", [small_calc(inputs=12, cells=24, tables=2, columns=12, rows=40)]),
        ("form", [form_block(), loan_block()]),
        ("form-messy", [messy_form]),
        ("form-dirty", [dirty_form]),
        ("form-full", [form_block(*fields_of(6))]),
        ("actions", [actions_block(), timeline_block()]),
        ("compare-messy", [compare_block(options=[
            compare_option("  Pixel\n11 ", recommended=True, pros=["Fast\u202e"]), compare_option("iPhone", recommended=True)])]),
        ("timeline-dirty", [timeline_block(title="Roast\tchicken", items=[
            timeline_item("Oven\u200b on", when=" 16:00 "), timeline_item("Roast", minutes=75)])]),
        ("simple", [{"type": "text", "title": "", "text": "<b>kept</b>"}]),
        ("mixed", [{"type": "richtext", "title": "", "text": '<p onclick="x">ok<script>bad()</script></p>'},
                   {"type": "metric", "title": "Count", "value": "12", "detail": "items"},
                   {"type": "progress", "title": "Done", "value": 0.7, "detail": ""},
                   {"type": "code", "title": "", "text": "x < y"}]),
        ("market", [{"type": "market", "title": "S&P", "symbol": "^GSPC", "range": "1mo"},
                    dict(chart(), source="HTTPS://Example.COM/dataset?utm_source=x"),
                    {"type": "image", "title": "Red panda", "query": "Red panda"}]),
        ("clamps", [clamped_slider, clamped_calc]),
    ]


class ParityTests(unittest.TestCase):
    def test_blocks_match_the_final_pass(self):
        checked = 0
        for name, blocks in parity_answers():
            final = catalog.validate_response(answer(blocks))["blocks"]
            for index, block in enumerate(blocks):
                with self.subTest(answer=name, block=index, kind=block["type"]):
                    self.assertEqual(catalog.validate_block(block), final[index])
                    checked += 1
        self.assertGreaterEqual(checked, 28)

    def test_the_fixtures_exercise_the_per_block_rules(self):
        # If these stopped changing anything the parity test above would prove nothing.
        by_name = dict(parity_answers())
        changed = 0
        for name, blocks in by_name.items():
            for block in blocks:
                if catalog.validate_block(block) != block:
                    changed += 1
        self.assertGreaterEqual(changed, 8)
        self.assertEqual(catalog.validate_block(by_name["mixed"][0])["text"], "<p>ok</p>")
        self.assertEqual(catalog.validate_block(by_name["clamps"][0])["control"]["value"], 11)
        self.assertEqual(catalog.validate_block(by_name["form-messy"][0])["fields"][1]["value"], 2)
        compare = catalog.validate_block(by_name["compare-messy"][0])["options"]
        self.assertEqual([option["recommended"] for option in compare], [True, False])
        self.assertEqual((compare[0]["name"], compare[0]["pros"]), ("Pixel 11", ["Fast"]))
        self.assertEqual(catalog.validate_block(by_name["timeline-dirty"][0])["items"][0]["when"], "16:00")
        cleaned = catalog.validate_block(by_name["form-dirty"][0])
        self.assertEqual((cleaned["title"], cleaned["submitLabel"], cleaned["note"]), ("Plan the trip", "Go", "x" * 240))
        self.assertEqual(cleaned["fields"][0]["label"], "Budget (EUR)")
        self.assertEqual(cleaned["fields"][1]["options"], ["Tr ain", "Bus", "Car"])
        self.assertEqual(catalog.validate_block(by_name["exploration"][2])["items"][0]["url"], "https://example.com/a#top")

    def test_rejections_agree(self):
        broken = [
            {"type": "table", "title": "", "columns": ["a"], "rows": [["1", "2"]]},
            {"type": "image", "title": "", "query": " "},
            {"type": "check", "title": "", "question": "?", "options": [
                {"label": "a", "correct": False, "feedback": ""}, {"label": "b", "correct": False, "feedback": ""}],
             "explanation": ""},
            {"type": "chart", "title": "", "unit": "", "labels": ["a", "b"], "values": [1, 2], "source": "",
             "asOf": "2026"},
            {"type": "sources", "title": "", "items": [{"label": "", "url": "https://localhost/x"}]},
            {"type": "sources", "title": "", "items": [{"label": "", "url": "https://example.com/"},
                                                        {"label": "", "url": "https://example.com"}]},
            {"type": "html", "title": "", "text": "x"},
            self_made_slider(min=5, max=5), self_made_slider(step=0),
            small_calc(inputs=0), loan_block() | {"cells": [dict(loan_block()["cells"][0], expression="nothing+1")]},
            form_block(fields=[]), form_block(form_field("number", min=1, max=1)),
            form_block(form_field("choice", options=["a"])), form_block(form_field("text", label="\n\u200b")),
            form_block(form_field("number", id="a"), form_field("number", id="a")),
            actions_block(options=[action("Same"), action(" same\n")]), actions_block(title="\u200b"),
            compare_block(options=[compare_option("A"), compare_option("a")]),
            timeline_block(items=[timeline_item("a", minutes=1.5), timeline_item("b")]),
        ]
        for index, block in enumerate(broken):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    catalog.validate_block(block)
                with self.assertRaises(ValueError):
                    catalog.validate_response(answer([block]))

    def test_non_dict_and_cross_block_rules_are_not_block_rules(self):
        for value in (None, [], "x", 3, {"type": "text"}):
            with self.assertRaises(ValueError):
                catalog.validate_block(value)
        # Two forms are each a valid block; only the answer breaks the one-form rule.
        catalog.validate_block(form_block())
        with self.assertRaises(ValueError):
            catalog.validate_response(answer([form_block(), form_block()]))


def text_block(label="x"):
    return {"type": "text", "title": "", "text": label}


class LenientNormalizationTests(unittest.TestCase):
    """normalize_response drops only the blocks that cannot be shown.

    Owner decision 2026-10-09 (live evidence: a three-laptop calculator answer fell back to
    plain text as a whole): when the JSON, `answer` and `suggestions` are valid but SOME blocks
    fail, the answer text, the suggestions and every valid block stay, in order, and `warning`
    is one generic sentence. Whole-answer plain text remains for an unparseable response, a
    broken envelope, or an answer that cannot meet the byte cap even without blocks.
    validate_response is unchanged and strict.
    """
    MARKUP = "<script>alert(1)</script> SECRET-MODEL-TEXT"

    def normalize(self, value):
        return catalog.normalize_response(json.dumps(value, ensure_ascii=False))

    @staticmethod
    def broken_table():
        return {"type": "table", "title": "", "columns": ["a"], "rows": [["1", "2"]]}

    @staticmethod
    def broken_calc():
        block = loan_block()
        block["cells"][0]["expression"] = "nothing+1"
        return block

    @staticmethod
    def broken_slider():
        block = CatalogTests.slider_block(None)
        block["readouts"][0]["expression"] = "import(x)"
        return block

    def test_one_bad_block_among_good_ones_keeps_the_good_ones_in_order(self):
        good = [text_block("first"), chart(), {"type": "metric", "title": "Count", "value": "12", "detail": ""}]
        for position in range(4):
            blocks = list(good)
            blocks.insert(position, self.broken_calc())
            with self.subTest(position=position):
                result = self.normalize(answer(blocks))
                self.assertEqual(result, {"answer": "Readable answer \u2713", "blocks": good,
                                          "suggestions": ["Explain more?"], "warning": catalog.DROPPED_WARNING})

    def test_two_bad_blocks_are_both_dropped_and_the_rest_keeps_its_order(self):
        blocks = [self.broken_table(), text_block("a"), self.broken_slider(), chart(), text_block("b")]
        result = self.normalize(answer(blocks))
        self.assertEqual(result["blocks"], [text_block("a"), chart(), text_block("b")])
        self.assertEqual((result["warning"], result["suggestions"]), (catalog.DROPPED_WARNING, ["Explain more?"]))

    def test_all_bad_blocks_keep_the_answer_and_show_no_blocks(self):
        result = self.normalize(answer([self.broken_table(), self.broken_calc(), {"type": "html"}, 7, None, "x"]))
        self.assertEqual(result, {"answer": "Readable answer \u2713", "blocks": [],
                                  "suggestions": ["Explain more?"], "warning": catalog.DROPPED_WARNING})

    def test_the_warning_is_generic_never_model_text_or_the_reason(self):
        block = self.broken_table()
        block["title"] = self.MARKUP
        value = answer([block, text_block("kept")])
        value["answer"] = "A fine answer"
        result = self.normalize(value)
        self.assertEqual(result["warning"], "Some parts of this answer could not be shown.")
        self.assertNotIn("SECRET", result["warning"])
        self.assertNotIn("width", result["warning"].lower())
        self.assertEqual(result["answer"], "A fine answer")

    def test_a_clean_answer_has_no_warning_and_equals_the_strict_result(self):
        for name, blocks in parity_answers():
            with self.subTest(answer=name):
                strict = catalog.validate_response(answer(blocks))
                result = self.normalize(answer(blocks))
                self.assertEqual(result, dict(strict, warning=""))

    def test_cross_block_extras_drop_the_later_offender_and_keep_the_first(self):
        slider, other_slider = CatalogTests.slider_block(None), CatalogTests.slider_block(None)
        other_slider["title"] = "Second slider"
        diagram, other_diagram = CatalogTests.diagram_block(None), CatalogTests.diagram_block(None)
        other_diagram["title"] = "Second diagram"
        gallery = {"type": "gallery", "title": "Styles", "items": [
            {"query": "Gothic", "caption": "Arches"}, {"query": "Romanesque", "caption": "Round"}]}
        other_gallery = dict(gallery, title="More styles")
        image, market = {"type": "image", "title": "I", "query": "Red panda"}, \
            {"type": "market", "title": "M", "symbol": "AAPL", "range": "1mo"}
        third_media = {"type": "image", "title": "J", "query": "Eiffel Tower"}
        second_form = form_block(form_field("toggle", id="other"), title="Second form")
        cases = [
            ("second slider", [slider, text_block("t"), other_slider], [slider, text_block("t")]),
            ("second diagram", [diagram, other_diagram], [diagram]),
            ("second calc", [loan_block(), small_calc()], [loan_block()]),
            ("second form", [form_block(), second_form, text_block("t")], [form_block(), text_block("t")]),
            ("second gallery", [gallery, other_gallery], [gallery]),
            ("media cap", [image, market, third_media], [image, market]),
            ("gallery counts as media", [image, gallery, market], [image, gallery]),
            ("a dropped gallery frees no media slot for a later one", [gallery, other_gallery, image, market], [gallery, image]),
            ("six-block cap", [text_block(str(i)) for i in range(8)], [text_block(str(i)) for i in range(6)]),
        ]
        for name, blocks, survivors in cases:
            with self.subTest(case=name):
                with self.assertRaises(ValueError):
                    catalog.validate_response(answer(blocks))
                result = self.normalize(answer(blocks))
                self.assertEqual(result["blocks"], survivors)
                self.assertEqual(result["warning"], catalog.DROPPED_WARNING)
                # The survivors are exactly what strict validation returns for the subset alone.
                strict = catalog.validate_response(answer(survivors))
                self.assertEqual(result, dict(strict, warning=catalog.DROPPED_WARNING))

    def test_survivors_equal_strict_validation_of_the_surviving_subset(self):
        slider, diagram = CatalogTests.slider_block(None), CatalogTests.diagram_block(None)
        linked = dict(slider, links=[{"part": 1, "property": "rotation", "expression": "x*15"}])
        dirty = {"type": "richtext", "title": "", "text": '<p onclick="x">ok<script>bad()</script></p>'}
        messy_form = form_block(form_field("number", value=10 ** 6, step=10 ** 7), form_field("choice", id="c", value=99))
        cited = answer([self.broken_table(), {"type": "sources", "title": "S", "items": [
            {"label": "Own", "url": "HTTPS://Example.COM:443/own?utm_source=x"}]}, dirty, chart()])
        cited["answer"] = "See [the data](https://example.org/data) for more."
        cases = [
            ("mixed", answer([self.broken_calc(), dirty, messy_form, diagram, linked, self.broken_slider(), chart()]),
             [1, 2, 3, 4, 6]),
            ("citations over survivors", cited, [1, 2, 3]),
            ("links lost their diagram", answer([text_block("a"), linked, self.broken_table()]), [0]),
        ]
        for name, value, survivor_indexes in cases:
            with self.subTest(case=name):
                subset = dict(value, blocks=[value["blocks"][i] for i in survivor_indexes])
                strict = catalog.validate_response(subset)
                result = self.normalize(value)
                self.assertEqual(result, dict(strict, warning=catalog.DROPPED_WARNING))
        # Citations are re-run over the survivors: the link in the answer became a native source
        # item appended to the surviving sources block, and the text lost the Markdown link.
        result = self.normalize(cited)
        self.assertEqual(result["answer"], "See the data for more.")
        sources = next(block for block in result["blocks"] if block["type"] == "sources")
        self.assertEqual([item["url"] for item in sources["items"]],
                         ["https://example.com/own", "https://example.org/data"])

    def test_a_bad_sources_block_does_not_stop_answer_citations_from_becoming_sources(self):
        duplicate = {"type": "sources", "title": "", "items": [
            {"label": "a", "url": "https://example.com/"}, {"label": "b", "url": "https://example.com"}]}
        value = answer([duplicate, text_block("kept")])
        value["answer"] = "Read [the page](https://example.com/page)."
        result = self.normalize(value)
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)
        self.assertEqual([block["type"] for block in result["blocks"]], ["text", "sources"])
        self.assertEqual(result["blocks"][1]["items"], [{"label": "the page", "url": "https://example.com/page"}])

    def test_the_byte_cap_sheds_trailing_blocks_and_only_gives_up_when_none_can_help(self):
        # A compact raw answer just under the input cap grows past it when validation re-serialises
        # it with spaces (and a Markdown citation adds a source item), so the last block is shed.
        blocks = [{"type": "code", "title": str(index), "text": "x" * 16384} for index in range(4)]
        def compact(value):
            return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        blocks[3]["text"] = "x" * (16384 - (len(compact(answer(blocks)).encode()) - catalog.MAX_RESPONSE_BYTES) - 4)
        raw = compact(answer(blocks))
        self.assertLessEqual(len(raw.encode()), catalog.MAX_RESPONSE_BYTES, "the raw answer is under the input cap")
        self.assertGreater(len(json.dumps(answer(blocks), ensure_ascii=False).encode()), catalog.MAX_RESPONSE_BYTES)
        with self.assertRaises(ValueError):
            catalog.validate_response(answer(blocks))
        result = catalog.normalize_response(raw)
        self.assertEqual([block["title"] for block in result["blocks"]], ["0", "1", "2"])
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)
        self.assertLessEqual(len(json.dumps(result["blocks"], ensure_ascii=False).encode()), catalog.MAX_RESPONSE_BYTES)
        # A cap that even the bare answer cannot meet: whole-answer fallback, nothing shed helps.
        with mock.patch.object(catalog, "MAX_RESPONSE_BYTES", 400):
            tight = answer([text_block("y" * 60)])
            tight["answer"] = "z" * 360
            result = self.normalize(tight)
        self.assertEqual(result["blocks"], [])
        self.assertEqual(result["warning"], "Response exceeds byte limit.")

    def test_hostile_envelopes_and_json_still_fall_back_whole(self):
        def whole(raw, warning):
            result = catalog.normalize_response(raw)
            self.assertEqual((result["blocks"], result["suggestions"], result["warning"]), ([], [], warning))
            return result
        schema = "Response did not match the native answer schema."
        good_block = text_block("never shown on a bad envelope")
        # Unparseable and structurally hostile JSON.
        whole('{"answer":"one","answer":"two","blocks":[],"suggestions":[]}', "Response was not valid JSON; showing plain text.")
        deep = catalog.normalize_response("[" * 2000 + "0" + "]" * 2000)  # a parse error or a non-object, never blocks
        self.assertEqual((deep["blocks"], deep["suggestions"]), ([], []))
        self.assertTrue(deep["warning"])
        whole('{"answer": "broken",', "Response was not valid JSON; showing plain text.")
        # A valid JSON value whose top-level shape is wrong.
        for value in ([], "text", 3, None, {"blocks": []}, dict(answer(), extra=1), dict(answer(), warning="x"),
                      {"answer": "x", "blocks": "no", "suggestions": []}, {"answer": "x", "blocks": {}, "suggestions": []},
                      {"answer": 7, "blocks": [good_block], "suggestions": []},
                      {"answer": "x" * 16385, "blocks": [good_block], "suggestions": []},
                      {"answer": "x", "blocks": [good_block], "suggestions": ["x"] * 4},
                      {"answer": "x", "blocks": [good_block], "suggestions": ["x" * 257]},
                      {"answer": "x", "blocks": [good_block], "suggestions": [1]},
                      {"answer": "x", "blocks": [good_block], "suggestions": "no"},
                      {"answer": "lone \ud800 surrogate", "blocks": [good_block], "suggestions": []}):
            with self.subTest(value=repr(value)[:60]):
                whole(json.dumps(value), schema)
        # Raw size and encoding limits are unchanged.
        whole("x" * (catalog.MAX_RESPONSE_BYTES + 1), "Response exceeds byte limit.")
        whole(b"\xff", "Response is not valid UTF-8.")

    def test_a_hostile_block_is_dropped_while_the_envelope_survives(self):
        deep = {"type": "text", "title": "", "text": "x"}
        for _ in range(500):
            deep = {"type": "checklist", "title": "", "items": [deep]}
        raw = json.dumps(answer([deep, text_block("kept")]))
        result = catalog.normalize_response(raw)
        self.assertEqual(result["blocks"], [text_block("kept")])
        self.assertEqual(result["warning"], catalog.DROPPED_WARNING)
        hostile = [{"type": "text", "title": "", "text": "x", "tools": [{"name": "rm"}]},
                   {"$schema": "https://bad", "type": "text"}, {"type": "text", "title": "", "text": {"$ref": "file:///x"}},
                   {"type": "sources", "title": "", "items": [{"label": "x", "url": "file:///etc/passwd"}]}]
        result = self.normalize(answer(hostile + [text_block("kept")]))
        self.assertEqual((result["blocks"], result["warning"]), ([text_block("kept")], catalog.DROPPED_WARNING))


def self_made_slider(**control):
    block = CatalogTests.slider_block(None)
    block["control"].update(control)
    return block


if __name__ == "__main__":
    unittest.main()
