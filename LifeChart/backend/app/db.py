"""SQLite storage.

Life chart records are stored as JSON blobs keyed by (kind, key). Every
accepted write gets a new value from a global, monotonically increasing
version counter, which is what clients use as their sync cursor.
"""

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path

KINDS = ("entries", "medications", "events", "flashcards", "goals", "wearables")

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS records (
    kind       TEXT    NOT NULL,
    key        TEXT    NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted    INTEGER NOT NULL DEFAULT 0,
    version    INTEGER NOT NULL,
    data       TEXT    NOT NULL,
    PRIMARY KEY (kind, key)
);
CREATE INDEX IF NOT EXISTS records_version ON records (kind, version);
CREATE TABLE IF NOT EXISTS conversations (
    id         TEXT PRIMARY KEY,
    title      TEXT    NOT NULL,
    mode       TEXT    NOT NULL DEFAULT 'talk',
    summary    TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT    NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    role            TEXT    NOT NULL,
    content         TEXT    NOT NULL,
    suggestions     TEXT    NOT NULL DEFAULT '[]',
    created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages (conversation_id, id);
"""


def now_ms() -> int:
    return int(time.time() * 1000)


class Database:
    def __init__(self, path: str | Path):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA journal_mode = WAL")
        # Deleted conversations and records should not linger in free pages.
        self._conn.execute("PRAGMA secure_delete = ON")
        # One connection is shared by all threads, so every access goes through this lock.
        self._lock = threading.RLock()
        with self._lock, self._conn:
            self._conn.executescript(SCHEMA)
            self._conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('version', '0')")

    # MARK: - Life chart records

    def current_version(self) -> int:
        with self._lock:
            row = self._conn.execute("SELECT value FROM meta WHERE key = 'version'").fetchone()
        return int(row["value"])

    def sync(self, changes: dict[str, list[tuple[str, int, bool, dict]]], cursor: int) -> dict:
        """Applies a client's changes and returns everything newer than its cursor, atomically."""
        with self._lock:
            for kind, records in changes.items():
                self.apply_changes(kind, records)
            snapshot = self.current_version()
            result = {kind: self.changes_since(kind, cursor, snapshot) for kind in KINDS}
        result["cursor"] = snapshot
        return result

    def apply_changes(self, kind: str, records: list[tuple[str, int, bool, dict]]) -> int:
        """Upsert (key, updated_at, deleted, data) tuples; last writer wins. Returns the number applied."""
        if kind not in KINDS:
            raise ValueError(f"unknown kind {kind}")
        applied = 0
        with self._lock, self._conn:
            version = self.current_version()
            for key, updated_at, deleted, data in records:
                existing = self._conn.execute(
                    "SELECT updated_at FROM records WHERE kind = ? AND key = ?", (kind, key)
                ).fetchone()
                if existing is not None and existing["updated_at"] >= updated_at:
                    continue
                version += 1
                self._conn.execute(
                    """
                    INSERT INTO records (kind, key, updated_at, deleted, version, data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (kind, key) DO UPDATE SET
                        updated_at = excluded.updated_at,
                        deleted    = excluded.deleted,
                        version    = excluded.version,
                        data       = excluded.data
                    """,
                    (kind, key, updated_at, int(deleted), version, json.dumps(data)),
                )
                applied += 1
            self._conn.execute(
                "UPDATE meta SET value = ? WHERE key = 'version'", (str(version),)
            )
        return applied

    def get_record(self, kind: str, key: str) -> dict | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT data FROM records WHERE kind = ? AND key = ?", (kind, key)
            ).fetchone()
        return json.loads(row["data"]) if row else None

    def changes_since(self, kind: str, cursor: int, upto: int | None = None) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT data FROM records WHERE kind = ? AND version > ? AND version <= ? "
                "ORDER BY version",
                (kind, cursor, upto if upto is not None else 2**62),
            ).fetchall()
        return [json.loads(r["data"]) for r in rows]

    def live_records(self, kind: str) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT data FROM records WHERE kind = ? AND deleted = 0 ORDER BY key", (kind,)
            ).fetchall()
        return [json.loads(r["data"]) for r in rows]

    def days_between(self, kind: str, start: str, end: str) -> list[dict]:
        """Live day-keyed records (entries or wearables) in an inclusive date range."""
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT data FROM records
                WHERE kind = ? AND deleted = 0 AND key BETWEEN ? AND ?
                ORDER BY key
                """,
                (kind, start, end),
            ).fetchall()
        return [json.loads(r["data"]) for r in rows]

    # MARK: - Profile

    def get_setting(self, key: str, default: str = "") -> str:
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM meta WHERE key = ?", (f"setting:{key}",)
            ).fetchone()
        return row["value"] if row else default

    def set_setting(self, key: str, value: str) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?) "
                "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                (f"setting:{key}", value),
            )

    # MARK: - Coach conversations

    def create_conversation(self, title: str, mode: str) -> str:
        conversation_id = str(uuid.uuid4())
        ts = now_ms()
        with self._lock, self._conn:
            self._conn.execute(
                "INSERT INTO conversations (id, title, mode, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                (conversation_id, title, mode, ts, ts),
            )
        return conversation_id

    def conversation_exists(self, conversation_id: str) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT 1 FROM conversations WHERE id = ?", (conversation_id,)
            ).fetchone()
        return row is not None

    def add_message(
        self, conversation_id: str, role: str, content: str, suggestions: list[dict] | None = None
    ) -> None:
        ts = now_ms()
        with self._lock, self._conn:
            self._conn.execute(
                "INSERT INTO messages (conversation_id, role, content, suggestions, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (conversation_id, role, content, json.dumps(suggestions or []), ts),
            )
            self._conn.execute(
                "UPDATE conversations SET updated_at = ? WHERE id = ?", (ts, conversation_id)
            )

    def list_conversations(self) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT id, title, mode, created_at, updated_at FROM conversations "
                "ORDER BY updated_at DESC"
            ).fetchall()
        return [
            {
                "id": r["id"],
                "title": r["title"],
                "mode": r["mode"],
                "createdAt": r["created_at"],
                "updatedAt": r["updated_at"],
            }
            for r in rows
        ]

    def get_conversation(self, conversation_id: str) -> dict | None:
        with self._lock:
            return self._get_conversation(conversation_id)

    def _get_conversation(self, conversation_id: str) -> dict | None:
        row = self._conn.execute(
            "SELECT id, title, mode, created_at, updated_at FROM conversations WHERE id = ?",
            (conversation_id,),
        ).fetchone()
        if row is None:
            return None
        messages = self._conn.execute(
            "SELECT role, content, suggestions, created_at FROM messages "
            "WHERE conversation_id = ? ORDER BY id",
            (conversation_id,),
        ).fetchall()
        return {
            "id": row["id"],
            "title": row["title"],
            "mode": row["mode"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "messages": [
                {
                    "role": m["role"],
                    "content": m["content"],
                    "suggestions": json.loads(m["suggestions"]),
                    "createdAt": m["created_at"],
                }
                for m in messages
            ],
        }

    def set_summary(self, conversation_id: str, summary: str) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                "UPDATE conversations SET summary = ? WHERE id = ?", (summary, conversation_id)
            )

    def get_summary(self, conversation_id: str) -> str:
        with self._lock:
            row = self._conn.execute(
                "SELECT summary FROM conversations WHERE id = ?", (conversation_id,)
            ).fetchone()
        return row["summary"] if row else ""

    def recent_summaries(self, exclude_id: str | None, limit: int = 12) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT id, mode, summary, updated_at FROM conversations
                WHERE summary != '' AND id IS NOT ?
                ORDER BY updated_at DESC LIMIT ?
                """,
                (exclude_id, limit),
            ).fetchall()
        return [
            {"mode": r["mode"], "summary": r["summary"], "updatedAt": r["updated_at"]}
            for r in reversed(rows)
        ]

    def delete_conversation(self, conversation_id: str) -> bool:
        with self._lock, self._conn:
            cur = self._conn.execute("DELETE FROM conversations WHERE id = ?", (conversation_id,))
        return cur.rowcount > 0
