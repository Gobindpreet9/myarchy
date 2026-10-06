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
    return {"answer": "Readable answer ✓", "blocks": blocks or [], "suggestions": ["Explain more?"]}


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

    def assert_invalid(self, value):
        result = self.normalize(value)
        self.assertTrue(result["warning"])
        self.assertEqual(result["blocks"], [])
        self.assertEqual(result["suggestions"], [])
        self.assertEqual(result["answer"], value.get("answer", "The response could not be displayed safely."))

    def test_shared_schema_and_strict_objects(self):
        self.assertEqual(catalog.ANSWER_SCHEMA, json.loads((ROOT / "ai-answer.schema.json").read_text()))
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
        self.assert_invalid(answer([block]))

    def test_check_correct_must_be_boolean_and_steps_bounded(self):
        block = self.learning_blocks()[1]
        block["options"][0]["correct"] = "yes"
        self.assert_invalid(answer([block]))
        self.assert_invalid(answer([{"type": "steps", "title": "Too short", "steps": [
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
        self.assert_invalid(answer([block]))
        block = self.diagram_block()
        block["parts"][1]["x"] = 140
        self.assert_invalid(answer([block]))
        block = self.diagram_block()
        block["parts"] = [dict(block["parts"][0]) for _ in range(25)]
        self.assert_invalid(answer([block]))
        block = self.diagram_block()
        del block["parts"][0]["tone"]
        self.assert_invalid(answer([block]))

    def slider_block(self):
        return {"type": "slider", "title": "Noon sun angle", "note": "Approximate; ignores refraction.",
                "control": {"label": "Month", "min": 0, "max": 11, "step": 1, "value": 5, "unit": "",
                            "labels": ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]},
                "readouts": [
                    {"label": "Noon angle at 49N", "expression": "90 - abs(x - 5.5) * 8", "unit": "°"},
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
        self.assert_invalid(answer([block]))
        block = self.slider_block()
        block["readouts"][0]["expression"] = "x.__class__"
        self.assert_invalid(answer([block]))
        block = self.slider_block()
        block["readouts"][0]["expression"] = "import(x)"
        self.assert_invalid(answer([block]))
        block = self.slider_block()
        block["control"]["step"] = 0
        self.assert_invalid(answer([block]))

    def test_gallery_bounds_and_media_budget(self):
        gallery = {"type": "gallery", "title": "Styles", "items": [
            {"query": "Gothic", "caption": "Pointed arches"},
            {"query": "Romanesque", "caption": "Round arches"}]}
        result = catalog.validate_response(answer([gallery]))
        self.assertEqual(result["blocks"][0]["type"], "gallery")
        self.assert_invalid(answer([gallery, gallery]))
        self.assert_invalid(answer([gallery, {"type": "image", "title": "x", "query": "y"},
                                   {"type": "market", "title": "z", "symbol": "AAPL", "range": "1mo"}]))
        self.assert_invalid(answer([{"type": "gallery", "title": "One",
                                     "items": [{"query": "a", "caption": "b"}]}]))

    def test_slider_links_pair_with_the_diagram(self):
        block = self.slider_block()
        block["links"] = [{"part": 1, "property": "rotation", "expression": "x*15"}]
        # A link without a paired diagram is meaningless: rejected.
        self.assert_invalid(answer([block]))
        result = catalog.validate_response(answer([self.diagram_block(), block]))
        self.assertEqual(result["blocks"][1]["links"][0]["expression"], "x*15")
        # Out-of-range part: rejected.
        block = self.slider_block()
        block["links"] = [{"part": 9, "property": "x", "expression": "x"}]
        self.assert_invalid(answer([self.diagram_block(), block]))
        # Unknown property and non-arithmetic expression: rejected.
        block = self.slider_block()
        block["links"] = [{"part": 0, "property": "opacity", "expression": "x"}]
        self.assert_invalid(answer([self.diagram_block(), block]))
        block = self.slider_block()
        block["links"] = [{"part": 0, "property": "x", "expression": "window.x"}]
        self.assert_invalid(answer([self.diagram_block(), block]))
        # One slider and one diagram per answer keeps the pairing unambiguous.
        self.assert_invalid(answer([self.slider_block(), self.slider_block()]))
        self.assert_invalid(answer([self.diagram_block(), self.diagram_block()]))

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
        self.assert_invalid(answer(blocks))

    def test_plain_text_and_code_preserved(self):
        text = '<script>alert("x")</script>\n<&> é'
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
            self.assert_invalid(answer([block]))
        for key in ("$schema", "$ref", "tools", "warning"):
            value = answer()
            value[key] = {"nested": {"command": "rm -rf /"}}
            self.assert_invalid(value)
        for key in answer():
            value = answer()
            del value[key]
            self.assert_invalid(value)

    def test_progress_numbers(self):
        for value in (0, 1, 0.25):
            self.assertEqual(self.normalize(answer([{"type": "progress", "title": "", "value": value, "detail": ""}]))["warning"], "")
        for value in (True, False, -0.1, 1.1, "0.5", None, float("nan"), float("inf"), -float("inf")):
            self.assert_invalid(answer([{"type": "progress", "title": "", "value": value, "detail": ""}]))

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
                    self.assert_invalid(answer([missing]))
            for key in ("url", "imageUrl", "data", "valuesResolved", "status", "blocks"):
                extra = copy.deepcopy(block)
                extra[key] = "untrusted"
                self.assert_invalid(answer([extra]))
        for item in ({"label": "Site"}, {"url": "https://example.com"},
                     {"label": "Site", "url": "https://example.com", "onclick": "bad"}):
            self.assert_invalid(answer([{"type": "sources", "title": "", "items": [item]}]))

    def test_image_query_bounds(self):
        for query in ("x", "x" * 200, "東京タワー"):
            self.assertEqual(self.normalize(answer([{"type": "image", "title": "", "query": query}]))["warning"], "")
        for query in ("", " ", "\n\t", "x" * 201, None, []):
            self.assert_invalid(answer([{"type": "image", "title": "", "query": query}]))

    def test_market_symbols_and_ranges(self):
        for symbol in ("AAPL", "^GSPC", "BRK-B", "BRK.B", "EURUSD=X", "0700.HK", "a" * 24):
            for period in ("1mo", "3mo", "1y"):
                self.assertEqual(self.normalize(answer([{"type": "market", "title": "", "symbol": symbol, "range": period}]))["warning"], "")
        for symbol in ("", "a" * 25, "AAPL\n", " AAPL", "AAPL/USD", "AAPL?x", "ÅAPL", "a_b", None):
            self.assert_invalid(answer([{"type": "market", "title": "", "symbol": symbol, "range": "1mo"}]))
        for period in ("", "1d", "5y", "1MO", 1):
            self.assert_invalid(answer([{"type": "market", "title": "", "symbol": "AAPL", "range": period}]))

    def test_chart_numeric_and_array_contract(self):
        for values in ([0, 0], [-1e15, 1e15], [-1, 0.125]):
            block = chart()
            block["values"] = values
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for value in (True, False, "2", None, float("nan"), float("inf"), -float("inf"), -1e15 - 1, 1e15 + 1):
            block = chart()
            block["values"][0] = value
            self.assert_invalid(answer([block]))
        for count in (2, 120):
            block = chart()
            block["labels"], block["values"] = ["x"] * count, [1] * count
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for count in (0, 1, 121):
            block = chart()
            block["labels"], block["values"] = ["x"] * count, [1] * count
            self.assert_invalid(answer([block]))
        block = chart()
        block["values"].append(4)
        self.assert_invalid(answer([block]))
        block = chart()
        block["source"], block["asOf"] = "", "Provided data"
        self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for as_of in ("", "2026", "provided data"):
            block["asOf"] = as_of
            self.assert_invalid(answer([block]))

    def test_sources_count_duplicates_and_string_bounds(self):
        for count in (1, 6):
            block = {"type": "sources", "title": "", "items": [{"label": "Source", "url": f"https://example.com/{i}"} for i in range(count)]}
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
        for count in (0, 7):
            self.assert_invalid(answer([{"type": "sources", "title": "", "items": [{"label": "", "url": f"https://example.com/{i}"} for i in range(count)]}]))
        for duplicate in ("https://example.com/", "https://EXAMPLE.com:443", "https://example.com/#section"):
            self.assert_invalid(answer([{"type": "sources", "title": "", "items": [
                {"label": "First", "url": "https://example.com"}, {"label": "Again", "url": duplicate}]}]))
        for field, limit in (("label", 160), ("url", 2048)):
            item = {"label": "", "url": "https://example.com/"}
            item[field] = "x" * limit if field == "label" else "https://example.com/" + "x" * (limit - 20)
            self.assertEqual(self.normalize(answer([{"type": "sources", "title": "", "items": [item]}]))["warning"], "")
            item[field] += "x"
            self.assert_invalid(answer([{"type": "sources", "title": "", "items": [item]}]))

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
            self.assert_invalid(answer([block]))

    def test_public_https_url_syntax_without_network(self):
        accepted = ["https://example.com", "HTTPS://Example.COM:443/path?q=one#section",
                    "https://en.wikipedia.org/wiki/Red_panda", "https://例え.jp/資料",
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
                                "https://例え.jp/資料": "https://xn--r8jz45g.jp/資料",
                            }.get(url, url)
                            if expected["type"] == "sources":
                                expected["items"][0]["url"] = canonical
                            else:
                                expected["source"] = canonical
                            self.assertEqual(catalog.validate_response(answer([block]))["blocks"], [expected])
                        else:
                            self.assert_invalid(answer([block]))

    def test_array_limits_and_table_width(self):
        cases = [
            ({"type": "checklist", "title": "", "items": ["x"] * 20}, "items", 20),
            ({"type": "table", "title": "", "columns": ["x"] * 5, "rows": []}, "columns", 5),
            ({"type": "table", "title": "", "columns": ["x"], "rows": [["x"]] * 24}, "rows", 24),
        ]
        for block, key, limit in cases:
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            block[key].append(copy.deepcopy(block[key][0]))
            self.assert_invalid(answer([block]))
        self.assert_invalid(answer([{"type": "table", "title": "", "columns": ["x"], "rows": [["x", "y"]]}]))
        self.assert_invalid(answer([{"type": "table", "title": "", "columns": [], "rows": []}]))
        self.assert_invalid({"answer": "x", "blocks": [], "suggestions": ["x"] * 4})

    def test_string_limits(self):
        for field, limit in (("title", 160), ("text", 16384)):
            block = {"type": "text", "title": "", "text": ""}
            block[field] = "x" * limit
            self.assertEqual(self.normalize(answer([block]))["warning"], "")
            block[field] += "x"
            self.assert_invalid(answer([block]))
        self.assertTrue(self.normalize({"answer": "x" * 16385, "blocks": [], "suggestions": []})["warning"])
        self.assert_invalid({"answer": "x", "blocks": [], "suggestions": ["x" * 257]})

    def test_json_fences_only(self):
        raw = json.dumps(answer())
        for wrapped in (raw, "```json\n" + raw + "\n```", "  ```JSON\n" + raw + "\n```  "):
            self.assertEqual(catalog.normalize_response(wrapped)["warning"], "")
        for wrapped in ("```\n" + raw + "\n```", "```python\n" + raw + "\n```", "```json\n```json\n" + raw + "\n```\n```", "prefix " + raw):
            self.assertTrue(catalog.normalize_response(wrapped)["warning"])

    def test_fallbacks_are_bounded_and_readable(self):
        result = catalog.normalize_response("A plain answer ✓")
        self.assertEqual(result["answer"], "A plain answer ✓")
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
        for raw in (b"\xff", "\ud800", "é" * 40000, b"x" * 65537, None, {}, 42):
            result = catalog.normalize_response(raw)
            self.assertTrue(result["warning"])
            self.assertLess(len(result["answer"]), 100)
        escaped = json.dumps(answer([{"type": "text", "title": "", "text": "\ud800"}]))
        self.assertEqual(catalog.normalize_response(escaped)["answer"], "Readable answer ✓")
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
            self.assert_invalid(answer([block]))

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


if __name__ == "__main__":
    unittest.main()
