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
    last_seen TEXT
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

CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    email TEXT,
    telegram_id TEXT,
    plan TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    activated_client_id TEXT,
    FOREIGN KEY(activated_client_id) REFERENCES clients(id)
);
"""


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def init_db() -> None:
    directory = os.path.dirname(settings.database_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with sqlite3.connect(settings.database_path) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.executescript(SCHEMA)


@contextmanager
def db():
    conn = sqlite3.connect(settings.database_path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()
