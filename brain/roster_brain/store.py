"""SQLite store for conversations and messages. One connection, used from the
event loop thread only; every write commits at once (WAL), so a crash loses at
most the text of an answer still streaming, which stays marked partial."""

import json
import os
import sqlite3
import time
import uuid

SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT,
    model TEXT NOT NULL,
    system TEXT,
    cwd TEXT,
    claude_session TEXT,
    created REAL NOT NULL,
    updated REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    state TEXT NOT NULL,
    model TEXT,
    route TEXT,
    meta TEXT,
    created REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation, created);
"""


def new_id():
    return uuid.uuid4().hex[:12]


class Store:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)
        # Answers that were streaming when the service last stopped.
        self.db.execute("UPDATE messages SET state = 'partial' WHERE state = 'streaming'")

    def create_conversation(self, kind, model, title=None, system=None, cwd=None):
        now = time.time()
        cid = new_id()
        self.db.execute(
            "INSERT INTO conversations (id, kind, title, model, system, cwd, created, updated)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", (cid, kind, title, model, system, cwd, now, now))
        return self.conversation(cid)

    def conversation(self, cid):
        row = self.db.execute("SELECT * FROM conversations WHERE id = ?", (cid,)).fetchone()
        return dict(row) if row else None

    def conversations(self, kind=None, limit=50):
        q, args = "SELECT * FROM conversations", []
        if kind:
            q, args = q + " WHERE kind = ?", [kind]
        rows = self.db.execute(q + " ORDER BY updated DESC LIMIT ?", args + [limit])
        return [dict(r) for r in rows]

    def update_conversation(self, cid, **fields):
        fields["updated"] = time.time()
        sets = ", ".join("%s = ?" % k for k in fields)
        self.db.execute("UPDATE conversations SET %s WHERE id = ?" % sets, list(fields.values()) + [cid])

    def delete_conversation(self, cid):
        self.db.execute("DELETE FROM conversations WHERE id = ?", (cid,))

    def add_message(self, cid, role, content, state="done", model=None, route=None, meta=None):
        mid = new_id()
        self.db.execute(
            "INSERT INTO messages (id, conversation, role, content, state, model, route, meta, created)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (mid, cid, role, content, state, model, route, json.dumps(meta) if meta else None, time.time()))
        self.update_conversation(cid)
        return mid

    def finish_message(self, mid, content, state="done", model=None, meta=None):
        self.db.execute(
            "UPDATE messages SET content = ?, state = ?, model = COALESCE(?, model),"
            " meta = COALESCE(?, meta) WHERE id = ?",
            (content, state, model, json.dumps(meta) if meta else None, mid))

    def messages(self, cid, limit=None):
        q = "SELECT * FROM messages WHERE conversation = ? ORDER BY created"
        rows = [dict(r) for r in self.db.execute(q, (cid,))]
        for r in rows:
            r["meta"] = json.loads(r["meta"]) if r["meta"] else None
        return rows[-limit:] if limit else rows
