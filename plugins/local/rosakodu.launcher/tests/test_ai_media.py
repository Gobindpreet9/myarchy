"""Offline tests for trusted contextual media; no keys or live requests."""
import io
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
import time
import unittest
from unittest.mock import patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ai_media as m


def chart(timestamps=None, closes=None):
    return {"chart": {"result": [{"meta": {"currency": "USD"},
        "timestamp": timestamps or [1704067200, 1704240000, 1704672000],
        "indicators": {"quote": [{"close": closes or [100, None, 103]}]}}]}}


def image_bytes(size=(20, 10), fmt="PNG"):
    try:
        from PIL import Image
    except ImportError:
        raise unittest.SkipTest("Optional Pillow image decoder is unavailable") from None
    stream = io.BytesIO()
    Image.new("RGB", size, "red").save(stream, format=fmt)
    return stream.getvalue()


class Response(io.BytesIO):
    status = 200

    def __init__(self, data, url, **headers):
        super().__init__(data)
        self.url = url
        self.headers = headers

    def geturl(self):
        return self.url


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "state"

    def enrich(self, blocks):
        return m.enrich_response({"answer": "Answer", "blocks": blocks,
                                  "suggestions": ["Next"], "warning": "Notice"}, self.root)

    def test_chart_actual_closes_irregular_dates_and_asof(self):
        with patch.object(m, "_json", return_value=chart()) as provider:
            out = self.enrich([{"type": "market", "title": "Apple", "symbol": "AAPL", "range": "1mo"}])
        block = out["blocks"][0]
        self.assertEqual(block["points"], [{"label": "2024-01-01", "value": 100},
                                            {"label": "2024-01-08", "value": 103}])
        self.assertEqual(block["asOf"], "2024-01-08T00:00:00Z")
        self.assertEqual(block["unit"], "USD")
        self.assertEqual(block["sourceUrl"], "https://finance.yahoo.com/quote/AAPL/")
        self.assertEqual(block["error"], "")
        self.assertIn("interval=1d", provider.call_args.args[0])
        self.assertEqual((out["answer"], out["suggestions"], out["warning"]), ("Answer", ["Next"], "Notice"))

    def test_decoded_cache_strips_icc_exif_and_other_provider_metadata(self):
        from PIL import Image
        output = io.BytesIO()
        exif = Image.Exif()
        exif[270] = "Untrusted provider metadata"
        Image.new("RGB", (20, 10), "red").save(output, format="PNG", exif=exif, icc_profile=b"untrusted ICC bytes")
        with Image.open(io.BytesIO(output.getvalue())) as original:
            self.assertIn("icc_profile", original.info)
            self.assertIn("exif", original.info)
        url = m._store_image(output.getvalue(), self.root)
        with Image.open(Path(url.removeprefix("file://"))) as clean:
            self.assertEqual(clean.info, {})
            self.assertEqual(clean.mode, "RGB")
            self.assertEqual(clean.size, (20, 10))

    def test_chart_finite_sorted_deduplicated_bounded(self):
        timestamps = [1704067200 + i * 86400 for i in range(260)]
        closes = list(range(260))
        timestamps += [timestamps[0], timestamps[1], timestamps[2], timestamps[3]]
        closes += [True, float("nan"), float("inf"), None]
        with patch.object(m, "_json", return_value=chart(timestamps[::-1], closes[::-1])):
            block = self.enrich([{"type": "market", "symbol": "^GSPC", "range": "1y"}])["blocks"][0]
        self.assertEqual(len(block["points"]), 120)
        self.assertEqual(block["points"][0]["value"], 0)
        self.assertEqual(block["points"][-1]["value"], 259)
        self.assertEqual(block["points"], sorted(block["points"], key=lambda p: p["label"]))
        self.assertTrue(all(math.isfinite(p["value"]) for p in block["points"]))
        self.assertIn("%5EGSPC", block["sourceUrl"])

    def test_invalid_requests_and_forged_enrichment(self):
        for symbol, period in [("http://localhost", "1mo"), ("AAPL/../../", "1mo"),
                               ("A" * 25, "1mo"), ("AAPL", "5d"), ("AAPL\n", "1y")]:
            with self.subTest(symbol=symbol), patch.object(m, "_fetch") as fetch:
                block = self.enrich([{"type": "market", "symbol": symbol, "range": period,
                                      "points": [{"label": "fake", "value": 99}], "sourceUrl": "file:///etc/passwd"}])["blocks"][0]
                self.assertTrue(block["error"])
                self.assertEqual(block["points"], [])
                self.assertEqual(block["sourceUrl"], "")
                fetch.assert_not_called()

    def test_provider_failure_never_invents_data(self):
        with patch.object(m, "_json", side_effect=RuntimeError("secret provider body")):
            block = self.enrich([{"type": "market", "symbol": "AAPL", "range": "3mo"}])["blocks"][0]
        self.assertEqual(block["points"], [])
        self.assertEqual(block["asOf"], "")
        self.assertIn("finance.yahoo.com", block["sourceUrl"])
        self.assertNotIn("secret", block["error"])

    def test_total_budget_and_detachment(self):
        response = {"answer": "A", "blocks": [{"type": "image", "title": "T", "query": "Mars",
            "imageUrl": "https://evil.invalid/a.png"}] * 3, "suggestions": ["S"]}
        with patch.object(m, "_image", side_effect=m.MediaError("Unavailable")) as image:
            result = m.enrich_response(response, self.root)
        self.assertEqual(image.call_count, 2)
        self.assertIn("two", result["blocks"][2]["error"])
        self.assertTrue(all(b["imageUrl"] == "" for b in result["blocks"]))
        result["suggestions"].append("New")
        self.assertEqual(response["suggestions"], ["S"])
        self.assertTrue(response["blocks"][0]["imageUrl"].startswith("https:"))

    def test_image_local_reencoded_attributed(self):
        wiki = {"query": {"pages": [{"title": "Mars", "pageimage": "Mars.jpg"}]}}
        commons = {"query": {"pages": [{"imageinfo": [{
            "thumburl": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/Mars.jpg/960px-Mars.jpg?utm_source=commons",
            "extmetadata": {"Artist": {"value": "<a href='x'>NASA</a>"},
                            "LicenseShortName": {"value": "Public domain"}}}]}]}}
        with patch.object(m, "_json", side_effect=[wiki, commons]), patch.object(m, "_fetch", return_value=image_bytes()) as fetch:
            block = self.enrich([{"type": "image", "title": "Mars", "query": "planet Mars"}])["blocks"][0]
        self.assertEqual(fetch.call_args.args[0], "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/Mars.jpg/960px-Mars.jpg")
        self.assertEqual(block["error"], "")
        self.assertEqual(block["attribution"], "NASA · Public domain · Wikimedia Commons")
        self.assertEqual(block["sourceUrl"], "https://commons.wikimedia.org/wiki/File%3AMars.jpg")
        from urllib.parse import urlsplit, unquote
        path = Path(unquote(urlsplit(block["imageUrl"]).path))
        self.assertEqual(path.parent, self.root / "media")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(path.read_bytes().startswith(b"\x89PNG"))
        self.assertTrue(block["fetchedAt"].endswith("Z"))

    def test_image_provider_url_cannot_escape_allowlist(self):
        wiki = {"query": {"pages": [{"pageimage": "Mars.jpg"}]}}
        for url in ["https://localhost/a.jpg", "https://upload.wikimedia.org.evil.invalid/a.jpg",
                    "https://user@" + "upload.wikimedia.org/wikipedia/a.jpg", "http://upload.wikimedia.org/wikipedia/a.jpg"]:
            commons = {"query": {"pages": [{"imageinfo": [{"thumburl": url}]}]}}
            with self.subTest(url=url), patch.object(m, "_json", side_effect=[wiki, commons]), patch.object(m, "_fetch") as fetch:
                block = self.enrich([{"type": "image", "query": "Mars"}])["blocks"][0]
            self.assertTrue(block["error"])
            self.assertEqual(block["imageUrl"], "")
            fetch.assert_not_called()

    def test_image_offers_bounded_distinct_alternatives(self):
        pages = [{"index": 1, "pageimage": "First.jpg"}, {"index": 2, "pageimage": "Second.jpg"},
                 {"index": 3, "pageimage": "First.jpg"}, {"index": 4, "pageimage": "Third.jpg"}]

        def provider(url, kind):
            if "gsrsearch" in url:
                return {"query": {"pages": pages}}
            name = "Second" if "Second" in url else "Third" if "Third" in url else "First"
            return {"query": {"pages": [{"imageinfo": [{
                "thumburl": "https://thumb.wikimedia.org/wikipedia/commons/%s.jpg/960px.jpg" % name,
                "extmetadata": {"Artist": {"value": name + " author"},
                                "LicenseShortName": {"value": "CC BY 4.0"}}}]}]}}

        def fetch(url, kind, limit):
            # Distinct bytes per candidate so the cache files differ.
            size = (24, 10) if "Third" in url else (22, 10) if "Second" in url else (20, 10)
            return image_bytes(size=size)

        with patch.object(m, "_json", side_effect=provider), \
                patch.object(m, "_fetch", side_effect=fetch):
            block = self.enrich([{"type": "image", "title": "Mars", "query": "planet Mars"}])["blocks"][0]
        self.assertEqual(block["error"], "")
        self.assertEqual(len(block["alternatives"]), 2, "duplicate candidates collapse")
        self.assertIn("First author", block["attribution"])
        self.assertEqual(len(set([block["imageUrl"], block["alternatives"][0]["imageUrl"],
                                  block["alternatives"][1]["imageUrl"]])), 3)
        self.assertTrue(block["alternatives"][1]["sourceUrl"].endswith("File%3AThird.jpg"))

    def test_gallery_resolves_items_and_isolates_failures(self):
        wiki_ok = {"query": {"pages": [{"index": 1, "pageimage": "Gothic.jpg"}]}}
        commons_ok = {"query": {"pages": [{"imageinfo": [{
            "thumburl": "https://upload.wikimedia.org/wikipedia/commons/Gothic.jpg",
            "extmetadata": {"Artist": {"value": "Author"}, "LicenseShortName": {"value": "CC0"}}}]}]}}

        def provider(url, kind):
            if "gsrsearch" in url:
                if "Romanesque" in url:
                    raise m.MediaError("provider down")
                return wiki_ok
            return commons_ok

        with patch.object(m, "_json", side_effect=provider), \
                patch.object(m, "_fetch", return_value=image_bytes()):
            block = self.enrich([{"type": "gallery", "title": "Styles", "items": [
                {"query": "Gothic", "caption": "Pointed arches"},
                {"query": "Romanesque", "caption": "Round arches"}]}])["blocks"][0]
        self.assertEqual(block["error"], "")
        self.assertEqual(block["items"][0]["caption"], "Pointed arches")
        self.assertTrue(block["items"][0]["imageUrl"].startswith("file://"))
        self.assertEqual(block["items"][0]["error"], "")
        self.assertTrue(block["items"][1]["error"], "one failed item never fails its siblings")
        self.assertEqual(block["items"][1]["imageUrl"], "")

    def test_gallery_items_offer_replacement_candidates(self):
        """Each gallery item resolves with one alternative so a single example
        can be replaced without resetting the rest of the comparison."""
        def provider(url, kind):
            if "gsrsearch" in url:
                return {"query": {"pages": [{"index": 1, "pageimage": "First.jpg"},
                                            {"index": 2, "pageimage": "Second.jpg"}]}}
            name = "Second" if "Second" in url else "First"
            return {"query": {"pages": [{"imageinfo": [{
                "thumburl": "https://thumb.wikimedia.org/wikipedia/commons/%s.jpg/960px.jpg" % name,
                "extmetadata": {"Artist": {"value": name + " author"},
                                "LicenseShortName": {"value": "CC BY 4.0"}}}]}]}}

        def fetch(url, kind, limit):
            return image_bytes(size=(22, 10) if "Second" in url else (20, 10))

        with patch.object(m, "_json", side_effect=provider), \
                patch.object(m, "_fetch", side_effect=fetch):
            block = self.enrich([{"type": "gallery", "title": "Styles", "items": [
                {"query": "Gothic", "caption": "Pointed arches"}]}])["blocks"][0]
        item = block["items"][0]
        self.assertEqual(item["error"], "")
        self.assertTrue(item["imageUrl"].startswith("file://"))
        self.assertEqual(len(item["alternatives"]), 1)
        self.assertNotEqual(item["alternatives"][0]["imageUrl"], item["imageUrl"])
        self.assertIn("Second author", item["alternatives"][0]["attribution"])

    def test_media_asset_budget_bounds_gallery_downloads(self):
        wiki = {"query": {"pages": [{"index": 1, "pageimage": "One.jpg"}]}}
        commons = {"query": {"pages": [{"imageinfo": [{
            "thumburl": "https://upload.wikimedia.org/wikipedia/commons/One.jpg",
            "extmetadata": {"Artist": {"value": "Author"}, "LicenseShortName": {"value": "CC0"}}}]}]}}
        with patch.object(m, "MAX_MEDIA_ASSETS", 2), \
                patch.object(m, "_json", side_effect=lambda url, kind: wiki if "gsrsearch" in url else commons), \
                patch.object(m, "_fetch", return_value=image_bytes()):
            block = self.enrich([{"type": "gallery", "title": "Styles", "items": [
                {"query": "A", "caption": "a"}, {"query": "B", "caption": "b"},
                {"query": "C", "caption": "c"}]}])["blocks"][0]
        self.assertTrue(block["items"][2]["error"].lower().find("budget") >= 0)
        self.assertEqual(block["items"][0]["error"], "", "the first item still resolves with its candidate")

    def enrich_budget_candidates(self, blocks, fail_downloads=False, single_queries=()):
        """Exercise real candidate resolution/decoding with distinct offline assets."""
        raw = [image_bytes(size=(20 + i, 10)) for i in range(m.MAX_MEDIA_ASSETS + 5)]
        names = {}

        def provider(url, kind):
            from urllib.parse import parse_qs, urlsplit
            params = parse_qs(urlsplit(url).query)
            if kind == "wiki":
                query = params["gsrsearch"][0]
                return {"query": {"pages": [
                    {"index": i + 1, "pageimage": query + str(i) + ".jpg"}
                    for i in range(1 if query in single_queries else 5)]}}
            name = params["titles"][0].removeprefix("File:")
            names[name] = len(names)
            return {"query": {"pages": [{"imageinfo": [{
                "thumburl": "https://upload.wikimedia.org/wikipedia/commons/" + name,
                "extmetadata": {"Artist": {"value": name}}}]}]}}

        def fetch(url, kind, limit):
            if fail_downloads:
                raise m.MediaError("Image download failed")
            return raw[names[url.rsplit("/", 1)[1]]]

        with patch.object(m, "_json", side_effect=provider) as metadata, \
                patch.object(m, "_fetch", side_effect=fetch) as download, \
                patch.object(m, "_store_image", wraps=m._store_image) as store:
            out = self.enrich(blocks)
        rendered = []
        for block in out["blocks"]:
            items = block.get("items", []) if block["type"] == "gallery" else [block]
            for item in items:
                if item.get("imageUrl"):
                    rendered.append(item["imageUrl"])
                    rendered.extend(candidate["imageUrl"] for candidate in item.get("alternatives", []))
        return out, metadata, download, store, rendered

    def assert_asset_budget(self, metadata, download, store, rendered, expected):
        self.assertEqual(download.call_count, expected)
        self.assertEqual(store.call_count, expected)
        self.assertEqual(len(rendered), expected)
        self.assertEqual(len(set(rendered)), expected)
        self.assertEqual(len(list((self.root / "media").glob("ai-*.png"))), expected)
        self.assertEqual(sum(call.args[1] == "commons" for call in metadata.call_args_list), expected)
        self.assertLessEqual(download.call_count, m.MAX_MEDIA_ASSETS)

    def test_gallery_then_image_respects_shared_asset_budget(self):
        gallery = {"type": "gallery", "items": [
            {"query": "Gallery" + str(i), "caption": str(i)} for i in range(6)]}
        out, metadata, download, store, rendered = self.enrich_budget_candidates([
            gallery, {"type": "image", "query": "Standalone"},
            {"type": "image", "query": "Third"}])
        self.assert_asset_budget(metadata, download, store, rendered, 12)
        self.assertEqual([len(item["alternatives"]) for item in out["blocks"][0]["items"]], [1] * 6)
        self.assertEqual(out["blocks"][1]["imageUrl"], "")
        self.assertIn("budget", out["blocks"][1]["error"].lower())
        self.assertIn("two contextual", out["blocks"][2]["error"])
        self.assertEqual(sum(call.args[1] == "wiki" for call in metadata.call_args_list), 6)

    def test_image_then_gallery_caps_last_item_to_remaining_capacity(self):
        gallery = {"type": "gallery", "items": [
            {"query": "Gallery" + str(i), "caption": str(i)} for i in range(6)]}
        out, metadata, download, store, rendered = self.enrich_budget_candidates([
            {"type": "image", "query": "Standalone"}, gallery])
        self.assert_asset_budget(metadata, download, store, rendered, 12)
        self.assertEqual(len(out["blocks"][0]["alternatives"]), 2)
        items = out["blocks"][1]["items"]
        self.assertEqual([len(item.get("alternatives", [])) for item in items], [1, 1, 1, 1, 0, 0])
        self.assertTrue(items[4]["imageUrl"])
        self.assertEqual(items[4]["error"], "")
        self.assertEqual(items[5]["imageUrl"], "")
        self.assertIn("budget", items[5]["error"].lower())
        self.assertEqual(sum(call.args[1] == "wiki" for call in metadata.call_args_list), 6)

    def test_gallery_leaves_one_slot_for_standalone_primary(self):
        gallery = {"type": "gallery", "items": [
            {"query": "Gallery" + str(i), "caption": str(i)} for i in range(6)]}
        out, metadata, download, store, rendered = self.enrich_budget_candidates([
            gallery, {"type": "image", "query": "Standalone"}], single_queries=("Gallery5",))
        self.assert_asset_budget(metadata, download, store, rendered, 12)
        self.assertEqual([len(item["alternatives"]) for item in out["blocks"][0]["items"]], [1] * 5 + [0])
        image = out["blocks"][1]
        self.assertTrue(image["imageUrl"])
        self.assertEqual(image["alternatives"], [])
        self.assertEqual(image["error"], "")
        self.assertTrue(image["fetchedAt"])
        self.assertEqual(sum(call.args[1] == "wiki" for call in metadata.call_args_list), 7)

    def test_partial_capacity_caps_primary_and_alternatives_before_download(self):
        for kind in ("gallery", "image"):
            for capacity in (0, 1, 2):
                with self.subTest(kind=kind, capacity=capacity), \
                        tempfile.TemporaryDirectory(dir=self.temp.name) as scratch, \
                        patch.object(self, "root", Path(scratch) / "state"), \
                        patch.object(m, "MAX_MEDIA_ASSETS", capacity):
                    block = ({"type": "gallery", "items": [{"query": "First"}, {"query": "Second"}]}
                             if kind == "gallery" else {"type": "image", "query": "First"})
                    out, metadata, download, store, rendered = self.enrich_budget_candidates([
                        block, {"type": "image", "query": "Later"}])
                    self.assert_asset_budget(metadata, download, store, rendered, capacity)
                    first = out["blocks"][0]["items"][0] if kind == "gallery" else out["blocks"][0]
                    self.assertEqual(len(first.get("alternatives", [])), max(0, capacity - 1))
                    self.assertEqual(bool(first["imageUrl"]), capacity > 0)
                    if not capacity:
                        self.assertIn("budget", first["error"].lower())
                        metadata.assert_not_called()
                    self.assertIn("budget", out["blocks"][1]["error"].lower())

    def test_failed_downloads_cannot_exceed_finite_asset_budget(self):
        with patch.object(m, "MAX_MEDIA_ASSETS", 2):
            out, metadata, download, store, rendered = self.enrich_budget_candidates([
                {"type": "gallery", "items": [{"query": "First"}, {"query": "Second"}]},
                {"type": "image", "query": "Later"}], fail_downloads=True)
        self.assertEqual(download.call_count, 2)
        store.assert_not_called()
        self.assertEqual(rendered, [])
        self.assertFalse((self.root / "media").exists())
        self.assertEqual(sum(call.args[1] == "wiki" for call in metadata.call_args_list), 1)
        self.assertEqual(sum(call.args[1] == "commons" for call in metadata.call_args_list), 2)
        for item in out["blocks"][0]["items"]:
            self.assertIn("budget", item["error"].lower())
        self.assertIn("budget", out["blocks"][1]["error"].lower())

    def test_mixed_media_shares_budget(self):
        with patch.object(m, "_image"), patch.object(m, "_market") as market:
            result = self.enrich([{"type": "image", "query": "Mars"},
                {"type": "market", "symbol": "AAPL", "range": "1mo"},
                {"type": "market", "symbol": "MSFT", "range": "1mo"}])
        self.assertEqual(market.call_count, 1)
        self.assertTrue(result["blocks"][2]["error"])

    def test_market_bounds_empty_currency_and_missing_data(self):
        fixtures = [chart([1704067200], [10]), chart([1704067200] * 1001, [10] * 1001),
                    {"chart": {"result": None}}]
        no_currency = chart()
        no_currency["chart"]["result"][0]["meta"] = {}
        fixtures.append(no_currency)
        for fixture in fixtures:
            with self.subTest(fixture=str(fixture)[:80]), patch.object(m, "_json", return_value=fixture):
                block = self.enrich([{"type": "market", "symbol": "AAPL", "range": "1mo"}])["blocks"][0]
            self.assertTrue(block["error"])
            self.assertEqual(block["points"], [])

    def test_cache_concurrent_writes_and_size_cap(self):
        raw = image_bytes()
        with ThreadPoolExecutor(max_workers=4) as pool:
            urls = list(pool.map(lambda _: m._store_image(raw, self.root), range(8)))
        self.assertEqual(len(set(urls)), 1)
        self.assertFalse(list((self.root / "media").glob("*.tmp")))
        fd, path = m._cache_dir(self.root)
        try:
            for i in range(3):
                file = path / ("ai-" + str(i) * 64 + ".png")
                file.write_bytes(b"x" * 100)
            with patch.object(m, "MAX_CACHE", 150):
                m._prune(fd, "")
            self.assertLessEqual(sum(p.stat().st_size for p in path.glob("ai-*.png")), 150)
        finally:
            os.close(fd)

    def test_symlink_cache_and_ancestor_rejected(self):
        other = Path(self.temp.name) / "other"
        other.mkdir()
        self.root.symlink_to(other, target_is_directory=True)
        with self.assertRaises(OSError):
            m._store_image(image_bytes(), self.root)
        self.assertEqual(list(other.iterdir()), [])
        self.root.unlink()
        self.root.mkdir()
        (self.root / "media").symlink_to(other, target_is_directory=True)
        with self.assertRaises(OSError):
            m._store_image(image_bytes(), self.root)

    def test_raster_format_and_dimension_limits(self):
        for data in [b"<svg xmlns='x'/>", image_bytes(fmt="GIF"), image_bytes((4097, 1))]:
            with self.subTest(size=len(data)), self.assertRaises(Exception):
                m._store_image(data, self.root)
        with self.assertRaises(m.MediaError):
            m._store_image(b"a" * (m.MAX_IMAGE + 1), self.root)

    def test_cache_prune_only_own_hash_files(self):
        fd, path = m._cache_dir(self.root)
        try:
            old = path / ("ai-" + "0" * 64 + ".png")
            old.write_bytes(b"old")
            os.utime(old, (1, 1))
            unrelated = path / "user.png"
            unrelated.write_bytes(b"mine")
            leftover = path / (".ai-" + "a" * 32 + ".tmp")
            leftover.write_bytes(b"interrupted write")
            link = path / ("ai-" + "1" * 64 + ".png")
            link.symlink_to(unrelated)
            m._prune(fd, "")
            self.assertFalse(old.exists())
            self.assertFalse(leftover.exists())
            self.assertTrue(link.is_symlink())
            self.assertEqual(unrelated.read_bytes(), b"mine")
        finally:
            os.close(fd)

    def test_network_allowlist_rejects_ssrf_before_open(self):
        urls = [("http://upload.wikimedia.org/wikipedia/a.png", "image"),
                ("https://localhost/w/api.php", "wiki"),
                ("https://en.wikipedia.org.evil.invalid/w/api.php", "wiki"),
                ("https://user@" + "en.wikipedia.org/w/api.php", "wiki"),
                ("https://en.wikipedia.org:443/w/api.php", "wiki"),
                ("https://en.wikipedia.org/other", "wiki"),
                ("https://upload.wikimedia.org/wikipedia/a.svg", "image"),
                ("https://upload.wikimedia.org/wikipedia/a.gif", "image"),
                ("https://query1.finance.yahoo.com/v8/finance/chart/%2Fetc", "market")]
        with patch.object(m.urllib.request, "build_opener") as opener:
            for url, kind in urls:
                with self.subTest(url=url), self.assertRaises(m.MediaError):
                    m._fetch(url, kind, 100)
            opener.assert_not_called()

    def test_no_redirects_or_proxy_environment(self):
        handler = m._NoRedirect()
        for destination in ["http://127.0.0.1/", "https://en.wikipedia.org/w/api.php"]:
            with self.assertRaises(m.MediaError):
                handler.redirect_request(None, None, 302, "", {}, destination)
        url = "https://en.wikipedia.org/w/api.php?format=json"
        with patch.object(m.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response(b"{}", url)
            with patch.dict(os.environ, {"HTTPS_PROXY": "http://localhost:9"}):
                self.assertEqual(m._fetch(url, "wiki", 100), b"{}")
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertIsInstance(build.call_args.args[1], m._NoRedirect)

    def test_rate_limit_is_safe_explicit_error(self):
        with patch.object(m.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = urllib.error.HTTPError(
                "https://query1.finance.yahoo.com/v8/finance/chart/AAPL", 429,
                "private upstream text", {}, io.BytesIO(b"secret body"))
            block = self.enrich([{"type": "market", "symbol": "AAPL", "range": "1mo"}])["blocks"][0]
        self.assertIn("rate limited", block["error"])
        self.assertNotIn("private", block["error"])
        self.assertEqual(block["points"], [])
        self.assertEqual(block["sourceUrl"], "https://finance.yahoo.com/quote/AAPL/")

    def test_network_body_mime_encoding_and_redirect_limits(self):
        url = "https://upload.wikimedia.org/wikipedia/a.png"
        for data, final, headers in [
            (b"abcd", url, {"Content-Type": "image/png"}),
            (b"a", url, {"Content-Length": "999", "Content-Type": "image/png"}),
            (b"a", url, {"Content-Type": "image/svg+xml"}),
            (b"a", url, {"Content-Type": "image/png", "Content-Encoding": "gzip"}),
            (b"a", "https://localhost/a.png", {"Content-Type": "image/png"}),
        ]:
            with self.subTest(headers=headers), patch.object(m.urllib.request, "build_opener") as build:
                build.return_value.open.return_value = Response(data, final, **headers)
                with self.assertRaises(m.MediaError):
                    m._fetch(url, "image", 3)


if __name__ == "__main__":
    unittest.main()
