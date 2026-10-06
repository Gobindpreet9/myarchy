"""Synchronous, credential-free enrichment of declarative media requests.

No model-supplied URLs are fetched. HTTPS endpoints are fixed, proxies/cookies
are disabled, and redirects fail closed. Pillow is optional: without it images
fail safely rather than passing unvalidated bytes to the native renderer.
"""
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import warnings

MAX_IMAGE = 3 * 1024 * 1024
MAX_JSON = 1024 * 1024
MAX_PIXELS = 4_000_000
MAX_CACHE = 32 * 1024 * 1024
CACHE_TTL = 7 * 86400
# Per-answer download budget across all media blocks (alternatives included).
MAX_MEDIA_ASSETS = 12
TIMEOUT = 8
SYMBOL = re.compile(r"[A-Za-z0-9^=.-]{1,24}\Z")
CACHE_NAME = re.compile(r"ai-[a-f0-9]{64}\.png\Z")
TEMP_NAME = re.compile(r"\.ai-[a-f0-9]{32}\.tmp\Z")


class MediaError(Exception):
    pass


class _MediaBudget:
    """Shared download capacity, including alternatives and failed attempts."""

    def __init__(self):
        self.remaining = MAX_MEDIA_ASSETS

    def reserve(self):
        if self.remaining <= 0:
            raise MediaError("Media budget for this answer is exhausted")
        self.remaining -= 1


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MediaError("Provider redirects are not allowed")


def _safe_url(url, kind):
    p = urllib.parse.urlsplit(url)
    if (p.scheme != "https" or p.username or p.password or p.port is not None
            or p.fragment or "\\" in url or any(ord(c) < 33 for c in url)):
        raise MediaError("Unsafe provider URL")
    allowed = {
        "wiki": ("en.wikipedia.org", "/w/api.php"),
        "commons": ("commons.wikimedia.org", "/w/api.php"),
        "market": ("query1.finance.yahoo.com", "/v8/finance/chart/"),
        "image": ("upload.wikimedia.org", "/wikipedia/"),
    }
    host, path = allowed[kind]
    hosts = {"upload.wikimedia.org", "thumb.wikimedia.org"} if kind == "image" else {host}
    if p.netloc not in hosts or (p.path != path if kind in {"wiki", "commons"}
                             else not p.path.startswith(path)):
        raise MediaError("Unsafe provider URL")
    if kind == "market":
        symbol = urllib.parse.unquote(p.path[len(path):])
        if not SYMBOL.fullmatch(symbol):
            raise MediaError("Unsafe market symbol")
    if kind == "image" and (p.query or not p.path.lower().endswith((".jpg", ".jpeg", ".png"))):
        raise MediaError("Only Wikimedia JPEG/PNG thumbnails are allowed")
    return url


def _fetch(url, kind, limit):
    _safe_url(url, kind)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    req = urllib.request.Request(url, headers={
        "User-Agent": "RosakoduLauncher/1.0 (public contextual media)",
        "Accept": "image/png,image/jpeg" if kind == "image" else "application/json",
        "Accept-Encoding": "identity",
    })
    try:
        opened = opener.open(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        if code == 429:
            raise MediaError("Media provider rate limited this request; try again later") from None
        raise MediaError("Media provider unavailable (HTTP " + str(code) + ")") from None
    with opened as response:
        if response.status != 200 or response.geturl() != url:
            raise MediaError("Unexpected provider response")
        length = response.headers.get("Content-Length")
        if length and (not length.isdigit() or int(length) > limit):
            raise MediaError("Provider response is too large")
        if response.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise MediaError("Compressed provider response is not allowed")
        mime = response.headers.get("Content-Type", "").split(";", 1)[0].lower()
        if kind == "image" and mime not in {"image/png", "image/jpeg"}:
            raise MediaError("Provider did not return a raster image")
        body = response.read(limit + 1)
        if len(body) > limit:
            raise MediaError("Provider response is too large")
        return body


def _json(url, kind):
    value = json.loads(_fetch(url, kind, MAX_JSON))
    if not isinstance(value, dict):
        raise MediaError("Invalid provider data")
    return value


def _api(host, **params):
    return "https://" + host + "/w/api.php?" + urllib.parse.urlencode(
        {"format": "json", "formatversion": 2, **params})


def _iso(timestamp=None):
    return datetime.fromtimestamp(time.time() if timestamp is None else timestamp,
                                  timezone.utc).isoformat().replace("+00:00", "Z")


def _text(value, limit=300):
    return html.unescape(re.sub(r"<[^>]*>", "", str(value)))[:limit]


def _cache_dir(state_root):
    """Traverse with directory descriptors: never follow any symlink component."""
    root = Path(os.path.abspath(os.fspath(state_root)))
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in (*root.parts[1:], "media"):
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new
        info = os.fstat(fd)
        if info.st_uid != os.getuid():
            raise MediaError("Media cache is not owned by this user")
        os.fchmod(fd, 0o700)
        return fd, root / "media"
    except Exception:
        os.close(fd)
        raise


def _prune(fd, keep):
    files = []
    now = time.time()
    for name in os.listdir(fd):
        temporary = bool(TEMP_NAME.fullmatch(name))
        if not CACHE_NAME.fullmatch(name) and not temporary:
            continue
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            continue
        # Under the exclusive lock, any leftover temporary file belongs to an
        # interrupted earlier write; no active writer can still be using it.
        if temporary or (now - info.st_mtime > CACHE_TTL and name != keep):
            os.unlink(name, dir_fd=fd)
        else:
            files.append((info.st_mtime, name, info.st_size))
    total = sum(row[2] for row in files)
    for _, name, size in sorted(files):
        if total <= MAX_CACHE:
            break
        if name != keep:
            os.unlink(name, dir_fd=fd)
            total -= size


def _store_image(data, state_root):
    try:
        from PIL import Image
    except ImportError as exc:
        raise MediaError("Safe image decoder is unavailable") from exc
    if len(data) > MAX_IMAGE:
        raise MediaError("Image is too large")
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        with Image.open(io.BytesIO(data)) as image:
            width, height = image.size
            if (image.format not in {"PNG", "JPEG"} or getattr(image, "n_frames", 1) != 1
                    or width < 1 or height < 1 or width > 4096 or height > 4096
                    or width * height > MAX_PIXELS):
                raise MediaError("Unsupported image format or dimensions")
            image.load()
            image = image.convert("RGB")
            image.thumbnail((960, 960))
            # Keep pixels only: Pillow otherwise propagates ICC/EXIF metadata.
            clean = Image.new("RGB", image.size)
            clean.paste(image)
            output = io.BytesIO()
            clean.save(output, format="PNG")
    data = output.getvalue()
    if len(data) > MAX_IMAGE:
        raise MediaError("Decoded image is too large")
    name = "ai-" + hashlib.sha256(data).hexdigest() + ".png"
    fd, directory = _cache_dir(state_root)
    lock = None
    temporary = ".ai-" + os.urandom(16).hex() + ".tmp"
    try:
        lock = os.open(".ai-cache.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise MediaError("Unsafe cache lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        _prune(fd, name)
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(out, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        _prune(fd, name)
        return (directory / name).as_uri()
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass
        if lock is not None:
            os.close(lock)
        os.close(fd)


def _image_candidates(query, limit, state_root, budget):
    """Resolve up to `limit` distinct Wikipedia lead images for a query.

    Returns a list of {imageUrl, attribution, sourceUrl}; individual candidate
    failures are skipped so one bad asset never fails the whole request.
    """
    limit = min(limit, budget.remaining)
    if limit <= 0:
        raise MediaError("Media budget for this answer is exhausted")
    if not isinstance(query, str) or not query.strip() or len(query) > 200:
        raise MediaError("Image query must contain 1–200 characters")
    data = _json(_api("en.wikipedia.org", action="query", generator="search",
                     gsrsearch=query, gsrlimit=min(limit + 2, 6), prop="pageimages|info", piprop="name",
                     inprop="url"), "wiki")
    pages = data.get("query", {}).get("pages", [])
    # MediaWiki returns pages in page-ID order, not relevance order.
    pages = sorted(pages[:limit + 2], key=lambda p: p.get("index", 999))
    results, seen = [], set()
    for page in pages:
        if len(results) >= limit or budget.remaining <= 0:
            break
        name = page.get("pageimage")
        if not isinstance(name, str) or not name or len(name) > 300 or name in seen:
            continue
        seen.add(name)
        try:
            results.append(_resolve_candidate(name, state_root, budget))
        except (MediaError, OSError, ValueError, KeyError, TypeError):
            continue
    if not results:
        if budget.remaining <= 0:
            raise MediaError("Media budget for this answer is exhausted")
        raise MediaError("No contextual Wikipedia image found")
    return results


def _resolve_candidate(name, state_root, budget):
    source = "https://commons.wikimedia.org/wiki/" + urllib.parse.quote("File:" + name, safe="")
    detail = _json(_api("commons.wikimedia.org", action="query", titles="File:" + name,
                       prop="imageinfo", iiprop="url|extmetadata", iiurlwidth=960), "commons")
    info = detail["query"]["pages"][0]["imageinfo"][0]
    metadata = info.get("extmetadata", {})
    artist = _text(metadata.get("Artist", {}).get("value", ""))
    license_name = _text(metadata.get("LicenseShortName", {}).get("value", ""), 100)
    thumbnail = urllib.parse.urlsplit(info["thumburl"])
    # Preserve the official thumbnail service selected by Wikimedia's API.
    # Rewriting thumb.wikimedia.org to upload breaks current thumbnails.
    if (thumbnail.scheme != "https" or thumbnail.netloc not in {
            "upload.wikimedia.org", "thumb.wikimedia.org"} or thumbnail.fragment):
        raise MediaError("Unsafe provider URL")
    thumbnail_url = "https://" + thumbnail.netloc + thumbnail.path
    # Reserve before fetching: failed downloads/decodes spend capacity too, and
    # a completed asset is never downloaded then discarded for lack of budget.
    budget.reserve()
    return {
        "imageUrl": _store_image(_fetch(thumbnail_url, "image", MAX_IMAGE), state_root),
        "attribution": " · ".join(filter(None, (artist, license_name, "Wikimedia Commons"))),
        "sourceUrl": source
    }


def _image(block, state_root, budget):
    query = block.get("query")
    if not isinstance(query, str) or not query.strip() or len(query) > 200:
        raise MediaError("Image query must contain 1–200 characters")
    block["sourceUrl"] = "https://en.wikipedia.org/w/index.php?" + urllib.parse.urlencode({"search": query})
    candidates = _image_candidates(query, 3, state_root, budget)
    primary = candidates[0]
    block["imageUrl"] = primary["imageUrl"]
    block["attribution"] = primary["attribution"]
    block["sourceUrl"] = primary["sourceUrl"]
    block["alternatives"] = candidates[1:]
    block["fetchedAt"] = _iso()


def _market(block):
    symbol, period = block.get("symbol"), block.get("range")
    if not isinstance(symbol, str) or not SYMBOL.fullmatch(symbol):
        raise MediaError("Invalid market symbol")
    if period not in {"1mo", "3mo", "1y"}:
        raise MediaError("Market range must be 1mo, 3mo, or 1y")
    encoded = urllib.parse.quote(symbol, safe="")
    block["sourceUrl"] = "https://finance.yahoo.com/quote/" + encoded + "/"
    url = "https://query1.finance.yahoo.com/v8/finance/chart/" + encoded + "?" + urllib.parse.urlencode(
        {"range": period, "interval": "1d"})
    result = _json(url, "market")["chart"]["result"][0]
    timestamps = result.get("timestamp", [])
    closes = result["indicators"]["quote"][0].get("close", [])
    if not isinstance(timestamps, list) or not isinstance(closes, list) or len(timestamps) > 1000 or len(closes) > 1000:
        raise MediaError("Market series exceeds bounds")
    values = {}
    for timestamp, close in zip(timestamps, closes):
        if (isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool)
                and math.isfinite(timestamp) and 0 < timestamp <= time.time() + 86400
                and isinstance(close, (int, float)) and not isinstance(close, bool)
                and math.isfinite(close)):
            values[timestamp] = close
    rows = sorted(values.items())
    if len(rows) < 2:
        raise MediaError("Not enough actual market closes")
    if len(rows) > 120:
        rows = [rows[round(i * (len(rows) - 1) / 119)] for i in range(120)]
    currency = result.get("meta", {}).get("currency", "")
    if not isinstance(currency, str) or not re.fullmatch(r"[A-Za-z]{3,8}", currency):
        raise MediaError("Provider currency is unavailable")
    block.update(points=[{"label": _iso(ts)[:10], "value": price} for ts, price in rows],
                 unit=currency, asOf=_iso(rows[-1][0]), fetchedAt=_iso())


def enrich_response(response, state_root):
    """Detach a normalized response and resolve at most two media blocks total.

    Media blocks are rebuilt from request fields so supplied URL/data fields can
    never impersonate trusted enrichment. Non-media content is left unchanged.
    """
    result = copy.deepcopy(response)
    resolved = 0
    budget = _MediaBudget()
    for index, original in enumerate(result.get("blocks", [])):
        if not isinstance(original, dict) or original.get("type") not in {"image", "market", "gallery"}:
            continue
        kind = original["type"]
        if kind == "image":
            fields = ("type", "title", "query")
        elif kind == "market":
            fields = ("type", "title", "symbol", "range")
        else:
            fields = ("type", "title", "items")
        block = {key: original[key] for key in fields if key in original}
        if kind == "gallery":
            # Items are rebuilt too: captions stay editorial, assets stay ours.
            block["items"] = [
                {"query": item.get("query", ""), "caption": item.get("caption", ""),
                 "imageUrl": "", "attribution": "", "sourceUrl": "", "error": "", "fetchedAt": ""}
                for item in original.get("items", []) if isinstance(item, dict)
            ]
            block.update(error="", fetchedAt="", sourceUrl="")
        else:
            block.update(error="", fetchedAt="", sourceUrl="")
            if kind == "image":
                block.update(imageUrl="", attribution="")
            else:
                block.update(points=[], unit="", asOf="")
        result["blocks"][index] = block
        if resolved >= 2:
            block["error"] = "Only two contextual media blocks can be resolved per answer"
            continue
        resolved += 1
        try:
            if kind == "image":
                _image(block, state_root, budget)
            elif kind == "market":
                _market(block)
            else:
                for item in block["items"]:
                    try:
                        # Two candidates per item so "Show another" can replace
                        # one example without resetting the comparison.
                        candidates = _image_candidates(item.get("query", ""), 2, state_root, budget)
                        item.update(candidates[0])
                        item["alternatives"] = candidates[1:]
                        item["fetchedAt"] = _iso()
                    except Exception as exc:
                        item["error"] = str(exc) if isinstance(exc, MediaError) else "Media provider unavailable or returned invalid data"
        except Exception as exc:
            # Provider errors can contain URLs, headers, or unbounded response
            # text; expose only our own safe diagnostics to the UI.
            block["error"] = str(exc) if isinstance(exc, MediaError) else "Media provider unavailable or returned invalid data"
    return result


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3 or sys.argv[1] != "--resolve":
        raise SystemExit(2)
    raw = sys.stdin.buffer.read(128 * 1024 + 1)
    if len(raw) > 128 * 1024:
        raise SystemExit(2)
    response = json.loads(raw)
    if not isinstance(response, dict) or not isinstance(response.get("blocks"), list):
        raise SystemExit(2)
    output = json.dumps(enrich_response(response, sys.argv[2]), ensure_ascii=False).encode()
    if len(output) > 128 * 1024:
        raise SystemExit(2)
    sys.stdout.buffer.write(output)
