#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP="${1:-}"
ENV_FILE="/etc/vpnx7/control.env"
DATA_DIR="/var/lib/vpnx7"
BACKUP_DIR="/var/backups/vpnx7"
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi
if [ -z "${BACKUP}" ] || [ ! -f "${BACKUP}" ]; then
  echo "Usage: sudo bash restore-db.sh /var/backups/vpnx7/vpnx7-....sqlite3.gz" >&2
  exit 2
fi
if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 3
fi
if [ ! -x "${RUNTIME_PYTHON}" ] || [ ! -f "${BACKUP_SCRIPT}" ]; then
  echo "VPNX7 runtime is incomplete under ${ROOT}." >&2
  exit 3
fi

DB="$(grep '^VPNX7_DATABASE=' "${ENV_FILE}" | cut -d= -f2- || true)"
DB="${DB:-${DATA_DIR}/vpnx7.db}"
CONTROL_PORT="$(grep '^VPNX7_PORT=' "${ENV_FILE}" | cut -d= -f2- || true)"
CONTROL_PORT="${CONTROL_PORT:-8080}"
TMP="$(mktemp)"
ROLLBACK_TMP="$(mktemp)"
trap 'rm -f "${TMP}" "${ROLLBACK_TMP}"' EXIT

validate_db() {
  python3 - "$1" <<'PY'
import sqlite3, sys
path=sys.argv[1]
conn=sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    result=conn.execute("PRAGMA integrity_check").fetchone()
finally:
    conn.close()
if not result or result[0] != "ok":
    raise SystemExit(f"database integrity check failed: {result}")
PY
}

gzip -dc "${BACKUP}" >"${TMP}"
validate_db "${TMP}"
echo "Requested backup integrity: ok"

install -d -m 0700 "${BACKUP_DIR}"
PRE_BACKUP=""
if [ -f "${DB}" ]; then
  PRE_BACKUP="$(
    VPNX7_DATABASE="${DB}"     VPNX7_BACKUP_DIR="${BACKUP_DIR}"     VPNX7_BACKUP_RETENTION=14       "${INSTALL_DIR}/.venv/bin/python" "${INSTALL_DIR}/scripts/backup-db.py"
  )"
  [ -f "${PRE_BACKUP}" ] || {
    echo "Could not create pre-restore backup." >&2
    exit 4
  }
  echo "Pre-restore backup: ${PRE_BACKUP}"
fi

BOT_WAS_ACTIVE=0
systemctl is-active --quiet vpnx7-bot.service && BOT_WAS_ACTIVE=1 || true
systemctl stop vpnx7-bot.service >/dev/null 2>&1 || true
systemctl stop vpnx7-control.service

install -o vpnx7 -g vpnx7 -m 0600 "${TMP}" "${DB}"
rm -f "${DB}-wal" "${DB}-shm"

if systemctl start vpnx7-control.service; then
  RESTORE_OK=0
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${CONTROL_PORT}/healthz" >/dev/null 2>&1; then
      RESTORE_OK=1
      break
    fi
    sleep 1
  done
else
  RESTORE_OK=0
fi

if [ "${RESTORE_OK}" -eq 1 ]; then
  if [ "${BOT_WAS_ACTIVE}" -eq 1 ]; then
    systemctl start vpnx7-bot.service
  fi
  echo "Restore completed successfully."
  exit 0
fi

echo "Restored database failed application health. Rolling back the database." >&2
systemctl stop vpnx7-control.service >/dev/null 2>&1 || true

if [ -z "${PRE_BACKUP}" ] || [ ! -f "${PRE_BACKUP}" ]; then
  echo "No pre-restore database exists; automatic rollback is impossible." >&2
  exit 10
fi

gzip -dc "${PRE_BACKUP}" >"${ROLLBACK_TMP}"
validate_db "${ROLLBACK_TMP}"
install -o vpnx7 -g vpnx7 -m 0600 "${ROLLBACK_TMP}" "${DB}"
rm -f "${DB}-wal" "${DB}-shm"
systemctl start vpnx7-control.service

ROLLBACK_OK=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${CONTROL_PORT}/healthz" >/dev/null 2>&1; then
    ROLLBACK_OK=1
    break
  fi
  sleep 1
done

if [ "${ROLLBACK_OK}" -ne 1 ]; then
  echo "CRITICAL: pre-restore database rollback also failed health validation." >&2
  exit 11
fi

if [ "${BOT_WAS_ACTIVE}" -eq 1 ]; then
  systemctl start vpnx7-bot.service
fi

echo "Restore was rejected; the pre-restore database was restored successfully." >&2
exit 12
