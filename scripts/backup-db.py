from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import gzip
import os
import shutil
import sqlite3
import tempfile


db_path = Path(os.environ.get("VPNX7_DATABASE", "/var/lib/vpnx7/vpnx7.db"))
backup_dir = Path(os.environ.get("VPNX7_BACKUP_DIR", "/var/backups/vpnx7"))
retention = int(os.environ.get("VPNX7_BACKUP_RETENTION", "14"))

if not db_path.is_file():
    raise SystemExit(f"database not found: {db_path}")

backup_dir.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
target = backup_dir / f"vpnx7-{stamp}.sqlite3.gz"

with tempfile.TemporaryDirectory(prefix="vpnx7-backup-") as tmp:
    raw = Path(tmp) / "backup.sqlite3"
    source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
    destination = sqlite3.connect(raw)
    try:
        source.backup(destination)
        result = destination.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise RuntimeError(f"backup integrity check failed: {result}")
    finally:
        destination.close()
        source.close()

    with raw.open("rb") as src, gzip.open(target, "wb", compresslevel=6) as dst:
        shutil.copyfileobj(src, dst)

os.chmod(target, 0o600)

backups = sorted(backup_dir.glob("vpnx7-*.sqlite3.gz"), reverse=True)
for old in backups[max(retention, 1):]:
    old.unlink(missing_ok=True)

print(target)
