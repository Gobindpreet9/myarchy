"""Persistent AI workspace store: one SQLite file behind a line-oriented CLI.

Phase 1 of AI_WORKSPACE_PLAN.md, section 4.2 (State and persistence model).

Entry point: `python3 ai_workspace_store.py --root <state_root_dir> <command>`
with command in save/load/list/rename/duplicate/delete/prune. The payload is one JSON object on
stdin (at most 4 MiB) and the result is one JSON object on stdout.

Worker mode: `python3 ai_workspace_store.py --root <state_root_dir> --serve`
keeps one connection and dispatch loop across many JSON-line requests, writing
one JSON result line per request. The worker exits 0 on stdin EOF (parent
closed the pipe or exited) and exits when idle with no input for
WORKER_IDLE_SECONDS, so no helper persists after its last needed operation.

Rules this module keeps:
- It is a transactional store, not a validator: answer blocks are stored as-is
  after a bounded structural check, and nothing here is ever executed or
  fetched. There is deliberately no network use anywhere in this module.
- Every write is a single BEGIN IMMEDIATE transaction, so a failed save leaves
  prior state intact. WAL mode plus a 3000 ms busy timeout keep concurrent
  launcher/service handles safe.
- Error messages are static strings owned by this module; payloads and raw
  exceptions are never echoed back to the caller.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import select
import sqlite3
import stat
import sys
import time
import uuid

SCHEMA_VERSION = 1
DB_NAME = "workspace.db"
MAX_PAYLOAD = 4 * 1024 * 1024
# One artifact for each of the launcher's twenty retained turns.
MAX_ARTIFACTS = 20
MAX_BLOCKS = 64
MAX_BLOCK_BYTES = 128 * 1024
MAX_INTERACTION_KEYS = 64
MAX_INTERACTION_VALUE = 256 * 1024
MAX_REVISIONS = 256
PRUNE_DAYS = 30
PRUNE_KEEP = 20
BUSY_TIMEOUT_MS = 3000
SOURCE_COMMANDS = ("source_link", "source_unlink", "source_list")
COMMANDS = ("save", "load", "list", "rename", "duplicate", "delete", "prune") + SOURCE_COMMANDS
USAGE = "usage: python3 ai_workspace_store.py --root <state_root_dir> " \
        "<save|load|list|rename|duplicate|delete|prune|source_link|source_unlink|source_list>\n" \
        "       python3 ai_workspace_store.py --root <state_root_dir> --serve\n"
BACKUP_NAME = DB_NAME + ".pre-sources"
SOURCES_DIR = "sources"
SOURCE_ID = re.compile(r"src-[0-9a-f]{16}")
WORKSPACE_ID = re.compile(r"ws-[0-9a-f]{16}")
TURN_KEY = re.compile(r"turn:(0|[1-9][0-9]*)")
NAME_FORBIDDEN = re.compile(
    r"[\x00-\x1f\x7f-\x9f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e"
    r"\u2060-\u206f\ufeff\ufff9-\ufffb]")
STALE_TEMP = re.compile(r"\.tmp-[A-Za-z0-9._-]{1,64}")
STALE_TEMP_SECONDS = 3600
MAX_SOURCE_LIST = 200
MAX_SOURCE_COUNT = 1 << 40
# Worker idle exit guard (contract: helpers leave within 30 s of their last
# needed operation). The environment override exists for offline tests only.
WORKER_IDLE_SECONDS = float(os.environ.get("LAUNCHER_STORE_IDLE", "30") or 30)


class InputError(Exception):
    """Invalid payload, selector, or root path; the CLI reports exit code 3."""


class StoreError(Exception):
    """Storage-level failure; the CLI reports exit code 4."""


def _iso(epoch=None):
    """ISO-8601 UTC timestamp with millisecond precision and a Z suffix."""
    stamp = round((time.time() if epoch is None else epoch) * 1000)
    seconds, millis = divmod(stamp, 1000)
    moment = time.gmtime(seconds)
    return (f"{moment.tm_year:04d}-{moment.tm_mon:02d}-{moment.tm_mday:02d}T"
            f"{moment.tm_hour:02d}:{moment.tm_min:02d}:{moment.tm_sec:02d}.{millis:03d}Z")


def _reject_constant(name):
    raise ValueError("non-finite JSON constants are not allowed")


def _canonical(value):
    """Deterministic JSON text used for storage and revision comparison."""
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        raise InputError("Value cannot be stored as JSON") from None


def _parse_payload(raw):
    """Decode the stdin payload once; reject oversize or invalid JSON."""
    if not isinstance(raw, (bytes, bytearray)):
        raise InputError("Payload could not be read")
    raw = bytes(raw)
    if len(raw) > MAX_PAYLOAD:
        raise InputError("Payload exceeds the 4 MiB input limit")
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except (ValueError, RecursionError):
        raise InputError("Payload must be valid JSON") from None


def _require_text(value, message):
    if not isinstance(value, str) or not value:
        raise InputError(message)
    return value


def _optional_text(value, message):
    """Absent or null optional strings fall back to the schema default ''."""
    if value is None:
        return ""
    if not isinstance(value, str):
        raise InputError(message)
    return value


def _workspace_title(value):
    """Names use QML's UTF-16 length, not Python's Unicode codepoint count."""
    message = "Title must be a non-empty single-line name of at most 96 UTF-16 units"
    if not isinstance(value, str) or NAME_FORBIDDEN.search(value):
        raise InputError(message)
    try:
        # JSON normally combines pairs; direct callers may supply UTF-16 pairs.
        value = value.encode("utf-16-le", "surrogatepass").decode("utf-16-le")
    except UnicodeError:
        raise InputError(message) from None
    title = value.strip()
    if not title or len(title.encode("utf-16-le")) // 2 > 96:
        raise InputError(message)
    return title


def _open_root(root):
    """Walk without following links and retain the private directory handle."""
    if not isinstance(root, str) or not root.strip():
        raise InputError("Workspace root must be a directory path")
    path = Path(root)
    if not path.is_absolute():
        raise InputError("Workspace root must be an absolute path")
    if any(part == ".." for part in path.parts):
        raise InputError("Workspace root must not contain '..'")
    if not path.parts[1:]:
        raise InputError("Workspace root must be a private directory")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        components = path.parts[1:]
        for index, part in enumerate(components):
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except OSError:
                raise InputError("Workspace root components must be real directories") from None
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            if info.st_uid not in (0, os.getuid()):
                raise InputError("Workspace root components must have trusted owners")
            if index < len(components) - 1 and info.st_mode & 0o022:
                # The root-owned sticky /tmp is safe; an ordinary shared
                # writable parent could redirect SQLite after validation.
                if info.st_uid != 0 or not info.st_mode & stat.S_ISVTX:
                    raise InputError("Workspace root parents must not be shared writable directories")
        if os.fstat(fd).st_uid != os.getuid():
            raise InputError("Workspace root must be owned by the current user")
        os.fchmod(fd, 0o700)
        return fd
    except OSError:
        os.close(fd)
        raise StoreError("Workspace root could not be created") from None
    except BaseException:
        os.close(fd)
        raise


def _private_file(directory, name, create=False):
    """SQLite inherits the database mode for newly created WAL/SHM files."""
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
    if create:
        flags |= os.O_CREAT
    try:
        fd = os.open(name, flags, 0o600, dir_fd=directory)
    except FileNotFoundError:
        if not create:
            return
        raise
    except OSError:
        raise InputError("Workspace database files must be private regular files") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise InputError("Workspace database files must be owned regular files without links")
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


class _StoreConnection(sqlite3.Connection):
    """Keep SQLite's /proc/self/fd directory anchor valid until close."""
    root_fd = None

    def close(self):
        try:
            super().close()
        finally:
            if self.root_fd is not None:
                os.close(self.root_fd)
                self.root_fd = None


def _create_tables(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        schema_version INTEGER NOT NULL DEFAULT 1,
        title TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        agent TEXT NOT NULL DEFAULT '',
        session_ref TEXT NOT NULL DEFAULT '',
        draft TEXT NOT NULL DEFAULT '',
        attachment TEXT NOT NULL DEFAULT '',
        active_artifact_id TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS artifacts (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'answer',
        presentation_version INTEGER NOT NULL DEFAULT 1,
        blocks TEXT NOT NULL DEFAULT '[]',
        base_revision TEXT NULL,
        updated_at TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_artifacts_workspace_id ON artifacts(workspace_id)")
    conn.execute("""CREATE TABLE IF NOT EXISTS interaction_state (
        workspace_id TEXT,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(workspace_id, key))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS revisions (
        id TEXT PRIMARY KEY,
        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
        parent_revision TEXT NULL,
        checkpoint TEXT NOT NULL,
        reason TEXT NOT NULL DEFAULT '',
        prompt TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_revisions_artifact_created ON revisions(artifact_id, created_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        target TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('running','done','error','stopped')),
        token TEXT NOT NULL DEFAULT '',
        error TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL)""")
    # Ownership and size registry for copied CSV sources. The table is added
    # WITHOUT a schema bump: older code ignores it and its workspace deletes
    # still cascade these rows. meta.json in the source directory owns content.
    conn.execute("""CREATE TABLE IF NOT EXISTS sources (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        bytes INTEGER NOT NULL,
        rows INTEGER NOT NULL,
        created_at TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sources_workspace_id ON sources(workspace_id)")


@contextlib.contextmanager
def _transaction(conn):
    """One atomic write: BEGIN IMMEDIATE ... COMMIT, or ROLLBACK on failure."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.rollback()
        raise
    conn.commit()


def _has_table(conn, name):
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                        (name,)).fetchone() is not None


def _backup_before_sources(conn, directory):
    """Take one private SQLite copy before the first open that adds `sources`.

    Skipped for fresh or empty databases (nothing to protect) and whenever the
    copy already exists; the copy is never deleted automatically.
    """
    if (directory is None or not _has_table(conn, "workspaces")
            or conn.execute("SELECT 1 FROM meta WHERE key = 'sources_backup'").fetchone()
            or conn.execute("SELECT 1 FROM workspaces LIMIT 1").fetchone() is None):
        return
    try:
        os.stat(BACKUP_NAME, dir_fd=directory, follow_symlinks=False)
        return
    except FileNotFoundError:
        pass
    except OSError:
        raise StoreError("Workspace database backup could not be created") from None
    temp = f"{BACKUP_NAME}.{uuid.uuid4().hex[:12]}.tmp"
    try:
        os.close(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                         dir_fd=directory))
        target = sqlite3.connect(f"/proc/self/fd/{directory}/{temp}")
        try:
            conn.backup(target)
        finally:
            target.close()
        # link() never replaces an existing copy; a racing first open loses quietly.
        with contextlib.suppress(FileExistsError):
            os.link(temp, BACKUP_NAME, src_dir_fd=directory, dst_dir_fd=directory)
    except (OSError, sqlite3.Error):
        raise StoreError("Workspace database backup could not be created") from None
    finally:
        with contextlib.suppress(OSError):
            os.unlink(temp, dir_fd=directory)


def _ensure_schema(conn, directory=None):
    """Create or verify the schema, failing closed on other schema versions."""
    with _transaction(conn):
        conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    row = conn.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
    if row is not None:
        try:
            version = int(row[0])
        except (TypeError, ValueError):
            raise InputError("Workspace schema version metadata is invalid") from None
        if version != SCHEMA_VERSION:
            if version > SCHEMA_VERSION:
                raise InputError(f"Workspace schema is newer than this app (v{version})")
            raise InputError(f"Workspace schema is not supported by this app (v{version})")
    # The copy is taken outside the write transaction (a backup from a
    # connection that holds the write lock never finishes) and before the
    # table exists, so it is exactly the previous plugin's database.
    first_sources = row is not None and not _has_table(conn, "sources")
    if first_sources:
        _backup_before_sources(conn, directory)
    with _transaction(conn):
        _create_tables(conn)
        if first_sources:
            conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('sources_backup', ?)", (_iso(),))
        if row is None:
            # INSERT OR IGNORE: two processes may race on first open; either way
            # the version row ends up correct.
            conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?)",
                         (str(SCHEMA_VERSION),))


def _connect(db_path, directory=None):
    try:
        conn = sqlite3.connect(db_path, timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None,
                               factory=_StoreConnection)
    except (sqlite3.Error, OSError, ValueError):
        raise StoreError("Workspace database could not be opened") from None
    # A concurrent fresh init can hold the exclusive lock needed for the WAL
    # conversion; retry the setup before failing.
    last_error = None
    for attempt in range(4):
        try:
            conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute("PRAGMA journal_mode = WAL")
            _ensure_schema(conn, directory)
            return conn
        except sqlite3.OperationalError as exc:
            last_error = exc
            if "locked" not in str(exc).lower() or attempt == 3:
                break
            time.sleep(0.15 * (attempt + 1))
        except sqlite3.Error as exc:
            last_error = exc
            break
        except BaseException:
            conn.close()
            raise
    conn.close()
    detail = str(last_error).strip()[:120] if last_error else ""
    raise StoreError("Workspace database could not be initialized"
                     + (" (" + detail + ")" if detail else "")) from None


def open_store(root):
    """Open (creating if needed) the workspace database below `root`."""
    directory = _open_root(root)
    try:
        _private_file(directory, DB_NAME, create=True)
        for suffix in ("-wal", "-shm", "-journal"):
            _private_file(directory, DB_NAME + suffix)
        # The held handle prevents a renamed/replaced parent from redirecting
        # SQLite or its sidecars after the no-follow walk.
        conn = _connect(f"/proc/self/fd/{directory}/{DB_NAME}", directory)
        conn.root_fd = directory
        return conn
    except BaseException:
        os.close(directory)
        raise


def _upsert_workspace(conn, workspace_id, fields, active, pinned, now):
    """Full-row upsert; created_at is deliberately absent from the update set."""
    conn.execute("""INSERT INTO workspaces
        (id, schema_version, title, summary, agent, session_ref, draft, attachment,
         active_artifact_id, created_at, updated_at, pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            schema_version = excluded.schema_version,
            title = excluded.title, summary = excluded.summary,
            agent = excluded.agent, session_ref = excluded.session_ref,
            draft = excluded.draft, attachment = excluded.attachment,
            active_artifact_id = excluded.active_artifact_id,
            updated_at = excluded.updated_at, pinned = excluded.pinned""",
        (workspace_id, SCHEMA_VERSION, fields["title"], fields["summary"], fields["agent"],
         fields["sessionRef"], fields["draft"], fields["attachment"], active, now, now, pinned))


def _validate_artifact(entry):
    """Bounded structural check only: block content stays untouched."""
    if not isinstance(entry, dict):
        raise InputError("Each artifact must be a JSON object")
    artifact_id = _require_text(entry.get("id"), "Artifact id must be a non-empty string")
    kind = entry.get("kind")
    if kind is None:
        kind = "answer"
    elif not isinstance(kind, str) or not kind:
        raise InputError("Artifact kind must be a non-empty string")
    version = entry.get("presentationVersion", 1)
    if version is None:
        version = 1
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        raise InputError("Artifact presentationVersion must be a positive integer")
    blocks = entry.get("blocks", [])
    if not isinstance(blocks, list):
        raise InputError("Artifact blocks must be a list")
    if len(blocks) > MAX_BLOCKS:
        raise InputError("Artifact exceeds the 64 block limit")
    for block in blocks:
        if not isinstance(block, dict):
            raise InputError("Each block must be a JSON object")
        block_type = block.get("type")
        if not isinstance(block_type, str) or not block_type:
            raise InputError("Each block requires a string type")
        if len(_canonical(block).encode("utf-8")) > MAX_BLOCK_BYTES:
            raise InputError("Block exceeds the 128 KiB limit")
    reason = entry.get("reason")
    prompt = entry.get("prompt")
    if reason is not None and not isinstance(reason, str):
        raise InputError("Artifact reason must be a string")
    if prompt is not None and not isinstance(prompt, str):
        raise InputError("Artifact prompt must be a string")
    return (artifact_id, kind, version, _canonical(blocks), reason or "", prompt or "")


def _upsert_artifact(conn, workspace_id, artifact, now):
    """Upsert one artifact; insert a revision only when blocks content changed.

    The revision's parent is the artifact's previous base_revision, and the
    artifact's base_revision then points at the new revision. The newest 256
    revisions per artifact are kept.
    """
    artifact_id, kind, version, blocks_text, reason, prompt = artifact
    row = conn.execute("SELECT workspace_id, blocks, base_revision FROM artifacts WHERE id = ?",
                       (artifact_id,)).fetchone()
    if row is not None and row[0] != workspace_id:
        raise InputError("Artifact already belongs to another workspace")
    parent = row[2] if row is not None else None
    changed = row is None or row[1] != blocks_text
    if row is None:
        conn.execute("""INSERT INTO artifacts
            (id, workspace_id, kind, presentation_version, blocks, base_revision, updated_at)
            VALUES (?, ?, ?, ?, ?, NULL, ?)""",
            (artifact_id, workspace_id, kind, version, blocks_text, now))
    else:
        conn.execute("""UPDATE artifacts
            SET kind = ?, presentation_version = ?, blocks = ?, updated_at = ?
            WHERE id = ?""", (kind, version, blocks_text, now, artifact_id))
    if not changed:
        return 0
    revision_id = "rv-" + uuid.uuid4().hex
    conn.execute("""INSERT INTO revisions
        (id, artifact_id, parent_revision, checkpoint, reason, prompt, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (revision_id, artifact_id, parent, blocks_text, reason, prompt, now))
    conn.execute("""DELETE FROM revisions WHERE artifact_id = ? AND id NOT IN
        (SELECT id FROM revisions WHERE artifact_id = ?
         ORDER BY created_at DESC, rowid DESC LIMIT ?)""",
        (artifact_id, artifact_id, MAX_REVISIONS))
    conn.execute("UPDATE artifacts SET base_revision = ? WHERE id = ?", (revision_id, artifact_id))
    return 1


def _upsert_interaction(conn, workspace_id, rows, now):
    """Per-key upsert: keys absent from this save keep their stored value."""
    statement = """INSERT INTO interaction_state (workspace_id, key, value, updated_at)
        VALUES (?, ?, ?, ?) ON CONFLICT(workspace_id, key) DO UPDATE SET
        value = excluded.value, updated_at = excluded.updated_at"""
    conn.executemany(statement, [(workspace_id, key, text, now) for key, text in rows])


def cmd_save(conn, payload):
    if not isinstance(payload, dict):
        raise InputError("Save payload must be a JSON object")
    workspace = payload.get("workspace")
    if not isinstance(workspace, dict):
        raise InputError("Save payload requires a workspace object")
    workspace_id = _require_text(workspace.get("id"), "Workspace id must be a non-empty string")
    # The launcher always sends the complete, small workspace field set; the
    # coalescing contract lives in the content: omitted artifacts/interaction
    # are preserved, never deleted (see test_partial_save_preserves_stored_content).
    fields = {}
    for name in ("title", "summary", "agent", "sessionRef", "draft", "attachment"):
        fields[name] = _optional_text(workspace.get(name), f"Workspace {name} must be a string")
    active = workspace.get("activeArtifactId")
    if active is not None and not isinstance(active, str):
        raise InputError("Workspace activeArtifactId must be a string or null")
    pinned = workspace.get("pinned", 0)
    if isinstance(pinned, bool):
        pinned = 1 if pinned else 0
    elif isinstance(pinned, int) and pinned in (0, 1):
        pass
    else:
        raise InputError("Workspace pinned must be a boolean")
    entries = payload.get("artifacts", [])
    if not isinstance(entries, list):
        raise InputError("Save artifacts must be a list")
    if len(entries) > MAX_ARTIFACTS:
        raise InputError("Save payload exceeds 20 artifacts")
    artifacts = [_validate_artifact(entry) for entry in entries]
    interaction = payload.get("interaction", {})
    if not isinstance(interaction, dict):
        raise InputError("Save interaction must be a JSON object")
    if len(interaction) > MAX_INTERACTION_KEYS:
        raise InputError("Save payload exceeds 64 interaction keys")
    rows = []
    for key, value in interaction.items():
        if not isinstance(key, str):
            raise InputError("Interaction keys must be strings")
        text = _canonical(value)
        if len(text.encode("utf-8")) > MAX_INTERACTION_VALUE:
            raise InputError("Interaction value exceeds the 256 KiB limit")
        rows.append((key, text))
    authoritative = payload.get("authoritativeContent", False)
    if not isinstance(authoritative, bool):
        raise InputError("authoritativeContent must be a boolean")
    now = _iso()
    with _transaction(conn):
        _upsert_workspace(conn, workspace_id, fields, active, pinned, now)
        saved_revisions = 0
        for artifact in artifacts:
            saved_revisions += _upsert_artifact(conn, workspace_id, artifact, now)
        _upsert_interaction(conn, workspace_id, rows, now)
        if authoritative:
            # Thin saves omit content deliberately. Only complete snapshots
            # may delete turns/artifacts that fell out of the retained window.
            artifact_ids = [entry[0] for entry in artifacts]
            keys = [entry[0] for entry in rows]
            conn.execute("DELETE FROM artifacts WHERE workspace_id = ? AND id NOT IN ("
                         + ",".join("?" for _ in artifact_ids) + ")", [workspace_id, *artifact_ids])
            conn.execute("DELETE FROM interaction_state WHERE workspace_id = ? AND key NOT IN ("
                         + ",".join("?" for _ in keys) + ")", [workspace_id, *keys])
    return {"ok": True, "workspaceId": workspace_id, "savedArtifacts": len(artifacts),
            "savedRevisions": saved_revisions, "updatedAt": now}


def _stored_blocks(text):
    try:
        blocks = json.loads(text)
    except ValueError:
        raise StoreError("Stored workspace data is unreadable") from None
    if not isinstance(blocks, list):
        raise StoreError("Stored workspace data is unreadable")
    return blocks


def cmd_load(conn, payload):
    if not isinstance(payload, dict):
        raise InputError("Load payload must be a JSON object")
    workspace_id = payload.get("workspaceId")
    if workspace_id is not None:
        _require_text(workspace_id, "workspaceId must be a non-empty string")
        if payload.get("latest") is True:
            raise InputError("Specify either workspaceId or latest, not both")
    elif payload.get("latest") is True:
        row = conn.execute("SELECT id FROM workspaces ORDER BY updated_at DESC, rowid DESC LIMIT 1").fetchone()
        if row is None:
            return {"ok": True, "workspace": None}
        workspace_id = row[0]
    else:
        raise InputError("Load requires workspaceId or latest=true")
    row = conn.execute("""SELECT id, title, summary, agent, session_ref, draft, attachment,
        active_artifact_id, created_at, updated_at, pinned FROM workspaces WHERE id = ?""",
        (workspace_id,)).fetchone()
    if row is None:
        return {"ok": True, "workspace": None}
    workspace = {"id": row[0], "title": row[1], "summary": row[2], "agent": row[3],
                 "sessionRef": row[4], "draft": row[5], "attachment": row[6],
                 "activeArtifactId": row[7], "createdAt": row[8], "updatedAt": row[9],
                 "pinned": bool(row[10])}
    artifacts = []
    for artifact in conn.execute("""SELECT id, kind, presentation_version, blocks, base_revision, updated_at
        FROM artifacts WHERE workspace_id = ? ORDER BY rowid""", (workspace_id,)):
        artifacts.append({"id": artifact[0], "kind": artifact[1], "presentationVersion": artifact[2],
                          "blocks": _stored_blocks(artifact[3]), "baseRevision": artifact[4],
                          "updatedAt": artifact[5]})
    interaction = {}
    for state in conn.execute("SELECT key, value FROM interaction_state WHERE workspace_id = ? ORDER BY key",
                              (workspace_id,)):
        try:
            interaction[state[0]] = json.loads(state[1])
        except ValueError:
            # Corruption-tolerant: the store only ever wrote valid JSON itself,
            # so an unparseable value can only be disk damage; drop the key.
            continue
    return {"ok": True, "workspace": workspace, "artifacts": artifacts, "interaction": interaction}


def cmd_list(conn, payload):
    if not isinstance(payload, dict):
        raise InputError("List payload must be a JSON object")
    limit = payload.get("limit", 20)
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise InputError("limit must be an integer between 1 and 50")
    rows = conn.execute("""SELECT w.id, w.title, w.summary, w.updated_at, w.pinned,
        (SELECT COUNT(*) FROM artifacts a WHERE a.workspace_id = w.id)
        FROM workspaces w ORDER BY w.pinned DESC, w.updated_at DESC LIMIT ?""", (limit,)).fetchall()
    return {"ok": True, "workspaces": [{"id": row[0], "title": row[1], "summary": row[2],
                                        "updatedAt": row[3], "pinned": bool(row[4]),
                                         "artifactCount": row[5]} for row in rows]}


def cmd_rename(conn, payload):
    """Rename metadata only; workspaceName keeps subsequent UI saves named."""
    if not isinstance(payload, dict):
        raise InputError("Rename payload must be a JSON object")
    workspace_id = _require_text(payload.get("workspaceId"), "workspaceId must be a non-empty string")
    title = _workspace_title(payload.get("title"))
    with _transaction(conn):
        now = _iso()
        if conn.execute("UPDATE workspaces SET title = ?, updated_at = ? WHERE id = ?",
                        (title, now, workspace_id)).rowcount != 1:
            raise InputError("Workspace does not exist")
        _upsert_interaction(conn, workspace_id, [("workspaceName", _canonical(title))], now)
    return {"ok": True, "workspaceId": workspace_id, "title": title}


def _duplicate_json(text):
    """Unlike load's tolerant display path, copying must never drop bad data."""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    try:
        value = json.loads(text, parse_constant=_reject_constant, object_pairs_hook=unique_object)
        _canonical(value).encode("utf-8")
        return value
    except (TypeError, ValueError, RecursionError, InputError):
        raise StoreError("Stored workspace data cannot be duplicated") from None


def _remap_artifact_refs(value, mapping):
    """Remap identity fields and legacy checklist keys, never turn-state keys."""
    if isinstance(value, list):
        return [_remap_artifact_refs(entry, mapping) for entry in value]
    if not isinstance(value, dict):
        return value
    result = {}
    for key, entry in value.items():
        new_key = key
        if key.startswith("checklist:"):
            new_key = "checklist:" + mapping.get(key[10:], key[10:])
        if key in ("artifactId", "activeArtifactId") and isinstance(entry, str):
            entry = mapping.get(entry, entry)
        if new_key in result:
            raise StoreError("Stored workspace data cannot be duplicated")
        # Generated UI state is user data, not workspace/artifact metadata.
        # A user's object may legitimately contain artifactId/checklist keys.
        result[new_key] = entry if key.startswith("openui:") else _remap_artifact_refs(entry, mapping)
    return result


def cmd_duplicate(conn, payload):
    """Insert an independent snapshot, without provider sessions or CSV ownership.

    Retains every stored artifact/interaction (no retention pass). Turn-backed
    IDs match AiService.artifactIdFor; other artifacts receive fresh IDs. Each
    artifact starts with one parentless checkpoint, not the source history.
    """
    if not isinstance(payload, dict):
        raise InputError("Duplicate payload must be a JSON object")
    workspace_id = _require_text(payload.get("workspaceId"), "workspaceId must be a non-empty string")
    destination = payload.get("newWorkspaceId")
    if not isinstance(destination, str) or not WORKSPACE_ID.fullmatch(destination):
        raise InputError("newWorkspaceId must look like ws-<16 lowercase hex>")
    title = _workspace_title(payload.get("title"))
    with _transaction(conn):
        source = conn.execute("""SELECT schema_version, summary, agent, draft, attachment,
            active_artifact_id FROM workspaces WHERE id = ?""", (workspace_id,)).fetchone()
        if source is None:
            raise InputError("Workspace does not exist")
        if conn.execute("SELECT 1 FROM workspaces WHERE id = ?", (destination,)).fetchone():
            raise InputError("Destination workspace already exists")
        interaction = {key: _duplicate_json(text) for key, text in conn.execute(
            "SELECT key, value FROM interaction_state WHERE workspace_id = ? ORDER BY key",
            (workspace_id,))}
        mapping = {}
        for key, turn in interaction.items():
            if not key.startswith("turn:"):
                continue
            match = TURN_KEY.fullmatch(key)
            if (match is None or not isinstance(turn, dict)
                    or isinstance(turn.get("id"), bool) or not isinstance(turn.get("id"), int)
                    or str(turn["id"]) != match[1]):
                raise StoreError("Stored workspace turns cannot be duplicated")
            if "blocks" in turn:
                try:
                    _validate_artifact({"id": "inline", "blocks": turn["blocks"]})
                except InputError:
                    raise StoreError("Stored workspace turns cannot be duplicated") from None
            old_id = turn.get("artifactId")
            if old_id is None or old_id == "":
                continue  # Legacy inline-only turns have no artifact reference.
            if not isinstance(old_id, str) or old_id in mapping:
                raise StoreError("Stored workspace turns cannot be duplicated")
            mapping[old_id] = "af-" + destination[3:] + "-t" + match[1]
        artifacts = conn.execute("""SELECT id, kind, presentation_version, blocks
            FROM artifacts WHERE workspace_id = ? ORDER BY rowid""", (workspace_id,)).fetchall()
        for old_id, _, _, _ in artifacts:
            if old_id not in mapping:
                mapping[old_id] = "af-" + destination[3:] + "-a" + uuid.uuid4().hex
        if source[5] not in (None, "") and source[5] not in mapping:
            raise StoreError("Stored workspace data cannot be duplicated")
        if len(set(mapping.values())) != len(mapping):
            raise StoreError("Stored workspace data cannot be duplicated")
        for new_id in mapping.values():
            if conn.execute("SELECT 1 FROM artifacts WHERE id = ?", (new_id,)).fetchone():
                raise InputError("Destination artifact already exists")
        now = _iso()
        conn.execute("""INSERT INTO workspaces (id, schema_version, title, summary, agent,
            session_ref, draft, attachment, active_artifact_id, created_at, updated_at, pinned)
            VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, ?, ?, 0)""",
            (destination, source[0], title, source[1], source[2], source[3], source[4],
             mapping.get(source[5], source[5]), now, now))
        for old_id, kind, version, text in artifacts:
            copied_blocks = _remap_artifact_refs(_duplicate_json(text), mapping)
            try:
                validated = _validate_artifact({"id": mapping[old_id], "kind": kind,
                    "presentationVersion": version, "blocks": copied_blocks})
            except InputError:
                raise StoreError("Stored workspace data cannot be duplicated") from None
            new_id, kind, version, checkpoint, _, _ = validated
            revision_id = "rv-" + uuid.uuid4().hex
            conn.execute("""INSERT INTO artifacts (id, workspace_id, kind,
                presentation_version, blocks, base_revision, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (new_id, destination, kind, version, checkpoint, revision_id, now))
            conn.execute("""INSERT INTO revisions (id, artifact_id, parent_revision,
                checkpoint, reason, prompt, created_at) VALUES (?, ?, NULL, ?, '', '', ?)""",
                (revision_id, new_id, checkpoint, now))
        interaction.pop("handoffHome", None)
        interaction.pop("csvSource", None)
        interaction["workspaceName"] = title
        copied = _remap_artifact_refs(interaction, mapping)
        conn.executemany("""INSERT INTO interaction_state (workspace_id, key, value, updated_at)
            VALUES (?, ?, ?, ?)""",
            [(destination, key, _canonical(value), now) for key, value in copied.items()])
    return {"ok": True, "workspaceId": destination, "title": title}


def _delete_workspaces(conn, workspace_ids):
    """Remove workspaces and their interaction rows; FKs cascade the rest.

    Returns (deleted count, source ids whose rows the cascade removes), read
    BEFORE the delete so the caller can remove the copies after the commit.
    """
    deleted = 0
    source_ids = []
    for workspace_id in workspace_ids:
        source_ids += [row[0] for row in conn.execute(
            "SELECT id FROM sources WHERE workspace_id = ? ORDER BY rowid", (workspace_id,))]
        conn.execute("DELETE FROM interaction_state WHERE workspace_id = ?", (workspace_id,))
        deleted += conn.execute("DELETE FROM workspaces WHERE id = ?", (workspace_id,)).rowcount
    return deleted, source_ids


def _open_sources(root_fd):
    """The sources directory handle, or None when absent, linked or foreign."""
    if root_fd is None:
        return None
    try:
        fd = os.open(SOURCES_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
    except OSError:
        return None
    if os.fstat(fd).st_uid != os.getuid():
        os.close(fd)
        return None
    return fd


def _remove_tree(parent_fd, name, depth=0):
    """Remove one directory below `parent_fd`: regular files and real dirs only.

    Nothing is followed; a link, special file or over-deep tree stops the walk
    (the directory then stays, which is harmless).
    """
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        for entry in os.listdir(fd):
            mode = os.stat(entry, dir_fd=fd, follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode) and depth < 4:
                _remove_tree(fd, entry, depth + 1)
            elif stat.S_ISREG(mode):
                os.unlink(entry, dir_fd=fd)
            else:
                raise OSError("unexpected entry in a source directory")
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent_fd)


def _newest_mtime(parent_fd, name):
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    newest = info.st_mtime
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        for entry in os.listdir(fd):
            newest = max(newest, os.stat(entry, dir_fd=fd, follow_symlinks=False).st_mtime)
    finally:
        os.close(fd)
    return newest


def _cleanup_sources(root_fd, source_ids):
    """Best-effort file cleanup AFTER the database commit; never raises.

    Removes only the named src-* directories, plus stale `.tmp-*` directories
    (older than an hour). A complete src-* directory without a row is never
    touched here: a restored older database must not make real copies look
    orphaned. Returns (src directories removed, stale temp directories removed).
    """
    removed = stale = 0
    try:
        sources = _open_sources(root_fd)
        if sources is None:
            return 0, 0
        try:
            for source_id in source_ids:
                if not SOURCE_ID.fullmatch(source_id):
                    continue
                try:
                    _remove_tree(sources, source_id)
                    removed += 1
                except OSError:
                    continue
            cutoff = time.time() - STALE_TEMP_SECONDS
            for name in os.listdir(sources):
                if not STALE_TEMP.fullmatch(name):
                    continue
                try:
                    if (stat.S_ISDIR(os.stat(name, dir_fd=sources, follow_symlinks=False).st_mode)
                            and _newest_mtime(sources, name) < cutoff):
                        _remove_tree(sources, name)
                        stale += 1
                except OSError:
                    continue
        finally:
            os.close(sources)
    except OSError:
        pass
    return removed, stale


def _cleanup_extras(root_fd, source_ids):
    """Result fields for a cleanup; absent when nothing was owed or done."""
    removed, stale = _cleanup_sources(root_fd, source_ids)
    extras = {}
    if source_ids:
        extras["sourcesRemoved"] = removed
    if stale:
        extras["staleTempRemoved"] = stale
    return extras


def cmd_delete(conn, payload):
    if not isinstance(payload, dict):
        raise InputError("Delete payload must be a JSON object")
    workspace_id = _require_text(payload.get("workspaceId"), "workspaceId must be a non-empty string")
    with _transaction(conn):
        deleted, source_ids = _delete_workspaces(conn, [workspace_id])
    result = {"ok": True, "deleted": deleted > 0}
    result.update(_cleanup_extras(conn.root_fd, source_ids))
    return result


def cmd_prune(conn, payload):
    if not isinstance(payload, dict):
        raise InputError("Prune payload must be a JSON object")
    preserve = payload.get("preserveWorkspaces", False)
    if not isinstance(preserve, bool):
        raise InputError("preserveWorkspaces must be a boolean")
    source_ids = []
    with _transaction(conn):
        # Automatic launcher maintenance preserves saved conversations. The
        # legacy retention policy remains available only to explicit prune calls.
        pruned_workspaces = 0
        if not preserve:
            cutoff = _iso(time.time() - PRUNE_DAYS * 86400)
            unpinned = conn.execute("""SELECT id, updated_at FROM workspaces WHERE pinned = 0
                ORDER BY updated_at DESC, rowid DESC""").fetchall()
            keep = {row[0] for row in unpinned[:PRUNE_KEEP]}
            ids = [row[0] for row in unpinned if row[0] not in keep or row[1] < cutoff]
            pruned_workspaces, source_ids = _delete_workspaces(conn, ids)
        cursor = conn.execute("DELETE FROM artifacts WHERE workspace_id NOT IN (SELECT id FROM workspaces)")
        pruned_artifacts = max(cursor.rowcount, 0)
    result = {"ok": True, "prunedWorkspaces": pruned_workspaces, "prunedArtifacts": pruned_artifacts}
    result.update(_cleanup_extras(conn.root_fd, source_ids))
    return result


def _source_id(payload):
    source_id = payload.get("sourceId")
    if not isinstance(source_id, str) or not SOURCE_ID.fullmatch(source_id):
        raise InputError("sourceId must look like src-<16 lowercase hex>")
    return source_id


def _source_count(payload, name):
    value = payload.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_SOURCE_COUNT:
        raise InputError(f"{name} must be a non-negative integer")
    return value


def cmd_source_link(conn, payload):
    """Record that a workspace owns a copied source; idempotent for the same owner."""
    if not isinstance(payload, dict):
        raise InputError("Source link payload must be a JSON object")
    workspace_id = _require_text(payload.get("workspaceId"), "workspaceId must be a non-empty string")
    source_id = _source_id(payload)
    size, rows = _source_count(payload, "bytes"), _source_count(payload, "rows")
    with _transaction(conn):
        if conn.execute("SELECT 1 FROM workspaces WHERE id = ?", (workspace_id,)).fetchone() is None:
            raise InputError("Workspace does not exist")
        owner = conn.execute("SELECT workspace_id FROM sources WHERE id = ?", (source_id,)).fetchone()
        if owner is not None and owner[0] != workspace_id:
            raise InputError("Source already belongs to another workspace")
        conn.execute("""INSERT INTO sources (id, workspace_id, bytes, rows, created_at)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET bytes = excluded.bytes,
            rows = excluded.rows""", (source_id, workspace_id, size, rows, _iso()))
    return {"ok": True, "sourceId": source_id}


def cmd_source_unlink(conn, payload):
    """Drop the registry row; with `removeDir: true` also remove the copy.

    The directory goes only AFTER the commit, through the same no-follow,
    best-effort helper the delete cascades use (it never raises; a directory
    that cannot be removed simply stays). `sourcesRemoved` reports 0 or 1.
    """
    if not isinstance(payload, dict):
        raise InputError("Source unlink payload must be a JSON object")
    source_id = _source_id(payload)
    remove_dir = payload.get("removeDir", False)
    if not isinstance(remove_dir, bool):
        raise InputError("removeDir must be a boolean")
    with _transaction(conn):
        removed = conn.execute("DELETE FROM sources WHERE id = ?", (source_id,)).rowcount
    result = {"ok": True, "unlinked": removed > 0}
    if remove_dir:
        result.update(_cleanup_extras(conn.root_fd, [source_id]))
    return result


def cmd_source_list(conn, payload):
    """Registered sources (at most 200, oldest first) plus whole-registry totals."""
    if not isinstance(payload, dict):
        raise InputError("Source list payload must be a JSON object")
    workspace_id = payload.get("workspaceId")
    if workspace_id is not None:
        _require_text(workspace_id, "workspaceId must be a non-empty string")
    rows = conn.execute("""SELECT id, workspace_id, bytes, rows, created_at FROM sources
        WHERE (?1 IS NULL OR workspace_id = ?1) ORDER BY created_at, rowid LIMIT ?2""",
        (workspace_id, MAX_SOURCE_LIST + 1)).fetchall()
    count, total = conn.execute("SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM sources").fetchone()
    return {"ok": True, "totalBytes": total, "count": count, "truncated": len(rows) > MAX_SOURCE_LIST,
            "sources": [{"id": row[0], "workspaceId": row[1], "bytes": row[2], "rows": row[3],
                         "createdAt": row[4]} for row in rows[:MAX_SOURCE_LIST]]}


def dispatch(conn, command, payload):
    handler = {"save": cmd_save, "load": cmd_load, "list": cmd_list,
               "rename": cmd_rename, "duplicate": cmd_duplicate,
               "delete": cmd_delete, "prune": cmd_prune, "source_link": cmd_source_link,
               "source_unlink": cmd_source_unlink, "source_list": cmd_source_list}.get(command)
    if handler is None:
        raise InputError("Unknown command")
    return handler(conn, payload)


def serve(root, out, idle=WORKER_IDLE_SECONDS, fd=0):
    """One connection across many requests; idle-exits after `idle` seconds.

    `out` is a binary stream; `fd` is the process's real stdin (after Python's
    stdio layer has re-attached it), made non-blocking so idle selection can
    work without busy loops. Tests inject a real pipe fd and a driver thread.
    """

    def read_line(pending, in_idle):
        """Yield (status, line, pending) for one complete line.

        A persistent `pending` buffer keeps lines that shared a transport
        chunk; EOF is only reported after the buffer is exhausted.
        """
        while True:
            index = pending.find(b"\n")
            if index >= 0:
                line, pending = pending[:index], pending[index + 1:]
                if len(line) > MAX_PAYLOAD:
                    return ("oversize", "", pending)
                return ("line", line, pending)
            try:
                readable, _, _ = select.select([fd], [], [], in_idle)
            except (OSError, ValueError):
                return ("eof", "", pending)
            if not readable:
                if pending:
                    return ("line", pending, b"")
                return ("idle", "", pending)
            chunk = os.read(fd, 65536)
            if not chunk:
                try:
                    sys.stderr.write("worker saw EOF\n")
                    sys.stderr.flush()
                except Exception:
                    pass
                return ("eof", "", pending)
            pending += chunk

    try:
        os.set_blocking(fd, False)
        conn = open_store(root)
    except (StoreError, OSError) as exc:
        out.write(json.dumps({"ok": False, "error": "Workspace storage error"},
                             ensure_ascii=False).encode("utf-8") + b"\n")
        out.flush()
        return 4
    try:
        sys.stderr.write("worker ready\n")
        sys.stderr.flush()
    except Exception:
        pass

    pending = b""
    try:
        while True:
            status, line, pending = read_line(pending, max(0.1, idle))
            if status in ("eof", "idle"):
                return 0
            if status == "oversize":
                result = {"ok": False, "error": "Payload too large"}
            else:
                try:
                    payload = _parse_payload(line)
                    # Serve transport: {op, payload} where payload is the same
                    # command body the one-shot CLI reads from stdin.
                    op = payload.get("op") if isinstance(payload, dict) else None
                    body = payload.get("payload") if isinstance(payload, dict) else None
                    result = dispatch(conn, op, body)
                except InputError as exc:
                    result = {"ok": False, "error": str(exc)}
                except StoreError as exc:
                    result = {"ok": False, "error": str(exc)}
                except Exception:
                    result = {"ok": False, "error": "Workspace storage error"}
            out.write(json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n")
            out.flush()
    except (OSError, BrokenPipeError):
        return 0
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main(argv=None, stdin=None, stdout=None, stderr=None):
    """CLI entry: exit 0 ok, 2 usage, 3 invalid input/schema, 4 storage failure.

    `stdin`/`stdout`/`stderr` are injectable byte streams so tests can drive the
    exact CLI contract in-process; the real process uses sys.stdin.buffer etc.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    source = sys.stdin.buffer if stdin is None else stdin
    out = sys.stdout.buffer if stdout is None else stdout
    err = sys.stderr.buffer if stderr is None else stderr

    def report(code, message):
        out.write(json.dumps({"ok": False, "error": message}, ensure_ascii=False).encode("utf-8") + b"\n")
        return code

    if len(argv) == 3 and argv[0] == "--root" and argv[2] == "--serve":
        try:
            return serve(argv[1], out)
        except (StoreError, OSError) as exc:
            return report(4, "Workspace storage error")
    if len(argv) != 3 or argv[0] != "--root" or argv[2] not in COMMANDS:
        err.write(USAGE.encode("utf-8"))
        return 2
    command = argv[2]
    try:
        # One JSON document on a single stdin line (the Quickshell JSON-line
        # transport never emits literal newlines inside a payload). A missing
        # trailing newline is accepted for direct/test invocation.
        payload = _parse_payload(source.readline(MAX_PAYLOAD + 1))
        conn = open_store(argv[1])
    except InputError as exc:
        return report(3, str(exc))
    except StoreError as exc:
        return report(4, str(exc))
    try:
        result = dispatch(conn, command, payload)
    except InputError as exc:
        return report(3, str(exc))
    except StoreError as exc:
        return report(4, str(exc))
    except Exception:
        return report(4, "Workspace storage error")
    finally:
        conn.close()
    out.write(json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
