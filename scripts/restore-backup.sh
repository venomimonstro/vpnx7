#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/vpnx7/control.env"
BACKUP_DIR="/var/backups/vpnx7"
BACKUP="${1:-}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi
if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 2
fi

DB_PATH="$(grep '^VPNX7_DATABASE=' "${ENV_FILE}" | cut -d= -f2-)"
if [ -z "${DB_PATH}" ]; then
  echo "VPNX7_DATABASE is missing from ${ENV_FILE}" >&2
  exit 2
fi

if [ -z "${BACKUP}" ]; then
  BACKUP="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'vpnx7-*.sqlite3' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
fi
if [ -z "${BACKUP}" ] || [ ! -f "${BACKUP}" ]; then
  echo "Backup not found." >&2
  exit 3
fi

python3 - "${BACKUP}" <<'PY'
import sqlite3, sys
p=sys.argv[1]
c=sqlite3.connect(f"file:{p}?mode=ro", uri=True)
try:
    r=c.execute("PRAGMA integrity_check").fetchone()
    if not r or r[0] != "ok":
        raise SystemExit(f"backup integrity check failed: {r!r}")
finally:
    c.close()
print("Backup integrity: ok")
PY

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREVIOUS="${DB_PATH}.pre-restore-${STAMP}"

echo "Stopping control plane..."
systemctl stop vpnx7-bot.service >/dev/null 2>&1 || true
systemctl stop vpnx7-control.service

if [ -f "${DB_PATH}" ]; then
  cp -a "${DB_PATH}" "${PREVIOUS}"
fi
rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"

restore_previous() {
  echo "Restore failed; putting previous database back." >&2
  systemctl stop vpnx7-control.service >/dev/null 2>&1 || true
  if [ -f "${PREVIOUS}" ]; then
    install -o vpnx7 -g vpnx7 -m 0600 "${PREVIOUS}" "${DB_PATH}"
  fi
  rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"
  systemctl start vpnx7-control.service || true
}
trap restore_previous ERR

install -o vpnx7 -g vpnx7 -m 0600 "${BACKUP}" "${DB_PATH}"
systemctl start vpnx7-control.service

for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    trap - ERR
    BOT_TOKEN="$(grep '^VPNX7_TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" | cut -d= -f2- || true)"
    if [ -n "${BOT_TOKEN}" ]; then
      systemctl start vpnx7-bot.service
    fi
    echo "Restore complete: ${BACKUP}"
    echo "Pre-restore database kept at: ${PREVIOUS}"
    exit 0
  fi
  sleep 1
done

false
