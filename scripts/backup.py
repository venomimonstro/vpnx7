from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import os
import sqlite3


DB_PATH = Path(os.environ.get("VPNX7_DATABASE", "/var/lib/vpnx7/vpnx7.db"))
BACKUP_DIR = Path(os.environ.get("VPNX7_BACKUP_DIR", "/var/backups/vpnx7"))
KEEP = max(3, int(os.environ.get("VPNX7_BACKUP_KEEP", "14")))


def integrity(path: Path) -> None:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    try:
        result = conn.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise RuntimeError(f"SQLite integrity_check failed: {result!r}")
    finally:
        conn.close()


def main() -> None:
    if not DB_PATH.exists():
        raise SystemExit(f"database not found: {DB_PATH}")

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    final = BACKUP_DIR / f"vpnx7-{stamp}.sqlite3"
    temp = BACKUP_DIR / f".{final.name}.tmp"

    source = sqlite3.connect(DB_PATH, timeout=30)
    target = sqlite3.connect(temp, timeout=30)
    try:
        source.execute("PRAGMA busy_timeout=30000")
        source.backup(target)
        target.commit()
    finally:
        target.close()
        source.close()

    integrity(temp)
    os.chmod(temp, 0o600)
    os.replace(temp, final)

    backups = sorted(BACKUP_DIR.glob("vpnx7-*.sqlite3"), reverse=True)
    for old in backups[KEEP:]:
        old.unlink(missing_ok=True)

    print(final)


if __name__ == "__main__":
    main()
