from __future__ import annotations

import gzip
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="vpnx7-backup-test-") as tmp:
    root = Path(tmp)
    db = root / "source.db"
    backup_dir = root / "backups"

    conn = sqlite3.connect(db)
    conn.execute("CREATE TABLE proof (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
    conn.execute("INSERT INTO proof(value) VALUES('vpnx7-backup-proof')")
    conn.commit()
    conn.close()

    env = os.environ.copy()
    env["VPNX7_DATABASE"] = str(db)
    env["VPNX7_BACKUP_DIR"] = str(backup_dir)
    env["VPNX7_BACKUP_RETENTION"] = "3"

    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "backup-db.py")],
        check=True,
        text=True,
        capture_output=True,
        env=env,
    )
    archive = Path(result.stdout.strip())
    if not archive.is_file():
        raise SystemExit(f"backup was not created: {archive}")

    restored = root / "restored.db"
    with gzip.open(archive, "rb") as src, restored.open("wb") as dst:
        while chunk := src.read(1024 * 1024):
            dst.write(chunk)

    conn = sqlite3.connect(f"file:{restored}?mode=ro", uri=True)
    try:
        integrity = conn.execute("PRAGMA integrity_check").fetchone()
        proof = conn.execute("SELECT value FROM proof").fetchone()
    finally:
        conn.close()

    if not integrity or integrity[0] != "ok":
        raise SystemExit(f"backup integrity failed: {integrity!r}")
    if not proof or proof[0] != "vpnx7-backup-proof":
        raise SystemExit(f"backup data mismatch: {proof!r}")

print("VPNX7 BACKUP SELFTEST PASS")
