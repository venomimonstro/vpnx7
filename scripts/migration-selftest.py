from __future__ import annotations

import os
import sqlite3
import tempfile
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

root = Path(tempfile.mkdtemp(prefix="vpnx7-migration-"))
db_file = root / "legacy.db"
os.environ["VPNX7_DATABASE"] = str(db_file)

conn = sqlite3.connect(db_file)
conn.execute(
    "CREATE TABLE nodes (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, geo TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 443, sni TEXT NOT NULL, public_key TEXT NOT NULL, short_id TEXT NOT NULL, token_hash TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, last_seen TEXT)"
)
conn.execute(
    "CREATE TABLE orders (id TEXT PRIMARY KEY, email TEXT, telegram_id TEXT, plan TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, activated_client_id TEXT)"
)
conn.commit()
conn.close()

from app.db import init_db

init_db()

conn = sqlite3.connect(db_file)
node_columns = {row[1] for row in conn.execute("PRAGMA table_info(nodes)")}
order_columns = {row[1] for row in conn.execute("PRAGMA table_info(orders)")}
version = conn.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
conn.close()

required_node = {"last_sync_ok", "last_error", "xray_version"}
if not required_node <= node_columns:
    raise SystemExit(f"missing migrated node columns: {required_node - node_columns}")
if "request_ip" not in order_columns:
    raise SystemExit("missing migrated order column: request_ip")
if not version or version[0] != "2":
    raise SystemExit(f"unexpected schema version: {version}")

print("VPNX7 MIGRATION SELFTEST PASS")
