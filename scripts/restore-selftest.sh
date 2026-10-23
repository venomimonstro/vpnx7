#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "restore-selftest must run as root" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

INSTALL="${TMP}/install"
DATA="${TMP}/data"
BACKUPS="${TMP}/backups"
FAKEBIN="${TMP}/fakebin"
ENV_FILE="${TMP}/control.env"
mkdir -p "${INSTALL}/.venv/bin" "${INSTALL}/scripts" "${DATA}" "${BACKUPS}" "${FAKEBIN}"

ln -s "$(command -v python3)" "${INSTALL}/.venv/bin/python"
cp "${ROOT}/scripts/backup-db.py" "${INSTALL}/scripts/backup-db.py"

python3 - "${DATA}/vpnx7.db" "${TMP}/replacement.db" <<'PY'
import sqlite3, sys
for path, value in [(sys.argv[1], "old"), (sys.argv[2], "new")]:
    c=sqlite3.connect(path)
    c.execute("CREATE TABLE proof(value TEXT NOT NULL)")
    c.execute("INSERT INTO proof(value) VALUES(?)", (value,))
    c.commit()
    c.close()
PY
gzip -c "${TMP}/replacement.db" >"${TMP}/replacement.sqlite3.gz"

cat >"${ENV_FILE}" <<EOF
VPNX7_DATABASE=${DATA}/vpnx7.db
VPNX7_PORT=18080
EOF

cat >"${FAKEBIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active)
    # Treat optional bot as inactive; all other explicit status probes as active.
    [ "${2:-}" != "vpnx7-bot.service" ]
    ;;
  stop|start|restart|enable|disable)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat >"${FAKEBIN}/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${FAKEBIN}/systemctl" "${FAKEBIN}/curl"

PATH="${FAKEBIN}:${PATH}" VPNX7_ENV_FILE="${ENV_FILE}" VPNX7_DATA_DIR="${DATA}" VPNX7_BACKUP_DIR="${BACKUPS}" VPNX7_INSTALL_DIR="${INSTALL}" VPNX7_HEALTH_ATTEMPTS=2 VPNX7_HEALTH_SLEEP=0 bash "${ROOT}/scripts/restore-db.sh" "${TMP}/replacement.sqlite3.gz"

VALUE="$(python3 - "${DATA}/vpnx7.db" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
print(c.execute("SELECT value FROM proof").fetchone()[0])
c.close()
PY
)"
[ "${VALUE}" = "new" ]

find "${BACKUPS}" -maxdepth 1 -name 'vpnx7-*.sqlite3.gz' -type f | grep -q .

echo "VPNX7 RESTORE SELFTEST PASS"
