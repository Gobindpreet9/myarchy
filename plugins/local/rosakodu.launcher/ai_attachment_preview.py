"""One-shot, credential-free CSV preview using the broker's guarded sampler.

Read one UTF-8 JSON line {token, path}; write one JSON line {token, ok,
preview?, error?}. Tokens are JavaScript-safe nonnegative integers. Invalid or
unrecoverable tokens are returned as null. No provider or broker main is run.
"""
import json
import re
import sys

from ai_broker import attachment_snapshot

MAX_REQUEST_BYTES = 8192
MAX_RESPONSE_BYTES = 32 * 1024
MAX_TOKEN = 2 ** 53 - 1
PREVIEW_ROWS = 10

# Only known sampler messages may cross this boundary. In particular, never
# expose a filesystem exception, filename, or arbitrary ValueError text.
_SNAPSHOT_ERRORS = frozenset({
    "Choose a text file inside your home directory.",
    "Attachment must be inside your home directory.",
    "Invalid attachment path.",
    "Credential and secret files cannot be attached.",
    "Attachment must be a text file smaller than 64 KiB.",
    "Attachment is unavailable or is a symbolic link.",
    "Attachment is too large or is binary.",
    "Attachment must be UTF-8 text.",
    "Attachment is binary.",
    "CSV attachment is empty.",
    "CSV header could not be parsed.",
    "CSV header exceeds the read window.",
    "CSV attachment has no header row.",
})
_CSV_ERROR = re.compile(
    r"(?:CSV could not be parsed near line [0-9]{1,10} "
    r"\(invalid quotes or oversized field\)\.|"
    r"CSV line [0-9]{1,10} has [0-9]{1,10} columns; the header has [0-9]{1,10}\.)"
)


def _error(token, message):
    return {"token": token, "ok": False, "error": message}


def run(request, home=None):
    """Return a preview response; home is a scratch-home injection for tests.

    All snapshot metadata stays unchanged. Only rows are reduced to a display
    prefix; previewRows is its size, while sampleRows remains the sampler size.
    Thus hiding rows for display does not change the sampler's truncated flag.
    """
    if not isinstance(request, dict):
        return _error(None, "Preview request must be an object.")
    token = request.get("token")
    if type(token) is not int or not 0 <= token <= MAX_TOKEN:
        return _error(None, "Preview token must be a nonnegative safe integer.")
    path = request.get("path")
    if not isinstance(path, str) or not path or len(path) > 4096:
        return _error(token, "Choose a CSV file inside your home directory.")
    if not path.lower().endswith(".csv"):
        return _error(token, "Only explicit .csv files can be previewed.")
    try:
        snapshot = attachment_snapshot(path, home=home)
        if not isinstance(snapshot, dict) or snapshot.get("kind") != "csv":
            return _error(token, "Only explicit .csv files can be previewed.")
        preview = dict(snapshot)
        preview["rows"] = snapshot["rows"][:PREVIEW_ROWS]
        preview["previewRows"] = len(preview["rows"])
        return {"token": token, "ok": True, "preview": preview}
    except ValueError as exc:
        message = str(exc)
        if len(message) <= 256 and (message in _SNAPSHOT_ERRORS or _CSV_ERROR.fullmatch(message)):
            return _error(token, message)
        return _error(token, "CSV preview is unavailable.")
    except Exception:
        return _error(token, "CSV preview is unavailable.")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate key")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError("Invalid JSON constant")


def main(stdin=None, stdout=None, home=None):
    """Serve exactly one bounded line, accepting EOF without a final newline.

    Streams are binary; byte limits include the terminating newline. Exit 0
    means success, 1 means an in-band error. No later input lines are processed.
    """
    source = sys.stdin.buffer if stdin is None else stdin
    out = sys.stdout.buffer if stdout is None else stdout
    try:
        line = source.readline(MAX_REQUEST_BYTES + 1)
        if len(line) > MAX_REQUEST_BYTES:
            result = _error(None, "Preview request is too large.")
        elif not line.strip():
            result = _error(None, "Preview request is missing.")
        else:
            try:
                request = json.loads(line.decode("utf-8"), object_pairs_hook=_unique_object,
                                     parse_constant=_invalid_constant)
            except (ValueError, RecursionError):
                result = _error(None, "Preview request must be valid UTF-8 JSON.")
            else:
                result = run(request, home=home)
    except Exception:
        result = _error(None, "Preview request could not be read.")
    try:
        data = json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if len(data) + 1 > MAX_RESPONSE_BYTES:
            result = _error(result["token"], "CSV preview response is too large.")
            data = json.dumps(result).encode("utf-8")
    except (ValueError, TypeError, UnicodeError, RecursionError):
        result = _error(result["token"], "CSV preview is unavailable.")
        data = json.dumps(result).encode("utf-8")
    out.write(data + b"\n")
    out.flush()
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
