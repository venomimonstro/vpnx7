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
case "${VPNX7_SELFTEST_CURL_MODE:-success}" in
  success)
    exit 0
    ;;
  fail_then_pass)
    counter="${VPNX7_SELFTEST_CURL_COUNTER:?}"
    n=0
    [ ! -f "${counter}" ] || n="$(cat "${counter}")"
    n=$((n + 1))
    printf '%s\n' "${n}" >"${counter}"
    if [ "${n}" -le "${VPNX7_SELFTEST_FAIL_COUNT:-2}" ]; then
      exit 22
    fi
    exit 0
    ;;
esac
exit 1
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

echo "selftest: failed restored health triggers database rollback"
python3 - "${DATA}/vpnx7.db" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM proof")
c.execute("INSERT INTO proof(value) VALUES('old-before-failed-restore')")
c.commit()
c.close()
PY

COUNTER="${TMP}/curl-counter"
rm -f "${COUNTER}"
set +e
PATH="${FAKEBIN}:${PATH}" \
VPNX7_SELFTEST_CURL_MODE=fail_then_pass \
VPNX7_SELFTEST_CURL_COUNTER="${COUNTER}" \
VPNX7_SELFTEST_FAIL_COUNT=2 \
VPNX7_ENV_FILE="${ENV_FILE}" \
VPNX7_DATA_DIR="${DATA}" \
VPNX7_BACKUP_DIR="${BACKUPS}" \
VPNX7_INSTALL_DIR="${INSTALL}" \
VPNX7_HEALTH_ATTEMPTS=2 \
VPNX7_HEALTH_SLEEP=0 \
bash "${ROOT}/scripts/restore-db.sh" "${TMP}/replacement.sqlite3.gz"
RC=$?
set -e
[ "${RC}" -eq 12 ]

VALUE="$(python3 - "${DATA}/vpnx7.db" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
print(c.execute("SELECT value FROM proof").fetchone()[0])
c.close()
PY
)"
[ "${VALUE}" = "old-before-failed-restore" ]

echo "VPNX7 RESTORE SELFTEST PASS"
