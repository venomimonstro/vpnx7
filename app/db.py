from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import os
import sqlite3

from app.settings import settings


SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    geo TEXT NOT NULL,
    host TEXT NOT NULL,
    port INTEGER NOT NULL DEFAULT 443,
    sni TEXT NOT NULL,
    public_key TEXT NOT NULL,
    short_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    last_seen TEXT,
    last_sync_ok TEXT,
    last_error TEXT,
    xray_version TEXT
);

CREATE TABLE IF NOT EXISTS clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    telegram_id TEXT,
    uuid TEXT NOT NULL UNIQUE,
    subscription_token TEXT NOT NULL UNIQUE,
    enabled INTEGER NOT NULL DEFAULT 1,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_clients_subscription_token
ON clients(subscription_token);

CREATE INDEX IF NOT EXISTS idx_clients_telegram_id
ON clients(telegram_id);

CREATE INDEX IF NOT EXISTS idx_nodes_last_sync_ok
ON nodes(last_sync_ok);

CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    email TEXT,
    telegram_id TEXT,
    plan TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    activated_client_id TEXT,
    request_ip TEXT,
    FOREIGN KEY(activated_client_id) REFERENCES clients(id)
);

CREATE INDEX IF NOT EXISTS idx_orders_status_created
ON orders(status, created_at);

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


MIGRATION_COLUMNS = {
    "nodes": {
        "last_sync_ok": "TEXT",
        "last_error": "TEXT",
        "xray_version": "TEXT",
    },
    "orders": {
        "request_ip": "TEXT",
    },
}


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _ensure_columns(conn: sqlite3.Connection) -> None:
    for table, columns in MIGRATION_COLUMNS.items():
        existing = {
            row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
        }
        for name, ddl in columns.items():
            if name not in existing:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}")


def _configure(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA synchronous=FULL")


def init_db() -> None:
    directory = os.path.dirname(settings.database_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with sqlite3.connect(settings.database_path, timeout=10) as conn:
        _configure(conn)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        _ensure_columns(conn)
        conn.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES('schema_version', '2')"
        )


@contextmanager
def db(*, immediate: bool = False):
    conn = sqlite3.connect(settings.database_path, timeout=10)
    conn.row_factory = sqlite3.Row
    _configure(conn)
    try:
        if immediate:
            conn.execute("BEGIN IMMEDIATE")
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
