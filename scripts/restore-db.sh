#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP="${1:-}"
ENV_FILE="/etc/vpnx7/control.env"
DATA_DIR="/var/lib/vpnx7"

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

# shellcheck disable=SC1090
source "${ENV_FILE}"
DB="${VPNX7_DATABASE:-${DATA_DIR}/vpnx7.db}"
TMP="$(mktemp)"
PRE="/var/backups/vpnx7/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).sqlite3.gz"
trap 'rm -f "${TMP}"' EXIT

gzip -dc "${BACKUP}" >"${TMP}"
python3 - "${TMP}" <<'PY'
import sqlite3, sys
path=sys.argv[1]
conn=sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    result=conn.execute("PRAGMA integrity_check").fetchone()
finally:
    conn.close()
if not result or result[0] != "ok":
    raise SystemExit(f"backup integrity check failed: {result}")
print("Backup integrity: ok")
PY

install -d -m 0700 /var/backups/vpnx7
if [ -f "${DB}" ]; then
  VPNX7_DATABASE="${DB}" VPNX7_BACKUP_DIR=/var/backups/vpnx7     /opt/vpnx7/.venv/bin/python /opt/vpnx7/scripts/backup-db.py >/dev/null
  LATEST="$(ls -1t /var/backups/vpnx7/vpnx7-*.sqlite3.gz | head -n1)"
  cp -a "${LATEST}" "${PRE}"
fi

BOT_WAS_ACTIVE=0
systemctl is-active --quiet vpnx7-bot.service && BOT_WAS_ACTIVE=1 || true
systemctl stop vpnx7-bot.service >/dev/null 2>&1 || true
systemctl stop vpnx7-control.service

install -o vpnx7 -g vpnx7 -m 0600 "${TMP}" "${DB}"
rm -f "${DB}-wal" "${DB}-shm"

systemctl start vpnx7-control.service
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    if [ "${BOT_WAS_ACTIVE}" -eq 1 ]; then
      systemctl start vpnx7-bot.service
    fi
    echo "Restore completed successfully."
    [ ! -f "${PRE}" ] || echo "Pre-restore backup: ${PRE}"
    exit 0
  fi
  sleep 1
done

echo "Restored database did not pass application health check." >&2
exit 10
