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
CURL_STATE="${TMP}/curl-state"
mkdir -p "${INSTALL}/.venv/bin" "${INSTALL}/scripts" "${DATA}" "${BACKUPS}" "${FAKEBIN}"

ln -s "$(command -v python3)" "${INSTALL}/.venv/bin/python"
cp "${ROOT}/scripts/backup-db.py" "${INSTALL}/scripts/backup-db.py"

make_db() {
  local path="$1"
  local value="$2"
  rm -f "${path}"
  python3 - "${path}" "${value}" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE proof(value TEXT NOT NULL)")
c.execute("INSERT INTO proof(value) VALUES(?)", (sys.argv[2],))
c.commit()
c.close()
PY
}

read_proof() {
  python3 - "$1" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
print(c.execute("SELECT value FROM proof").fetchone()[0])
c.close()
PY
}

make_archive() {
  local value="$1"
  local raw="${TMP}/replacement-${value}.db"
  local archive="${TMP}/replacement-${value}.sqlite3.gz"
  make_db "${raw}" "${value}"
  gzip -c "${raw}" >"${archive}"
  printf '%s\n' "${archive}"
}

cat >"${ENV_FILE}" <<EOF
VPNX7_DATABASE=${DATA}/vpnx7.db
VPNX7_PORT=18080
EOF

cat >"${FAKEBIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active)
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
set -u
case "${VPNX7_FAKE_CURL_MODE:-success}" in
  success)
    exit 0
    ;;
  fail-first)
    state="${VPNX7_FAKE_CURL_STATE:?}"
    n=0
    [ ! -f "${state}" ] || n="$(cat "${state}")"
    n=$((n + 1))
    printf '%s\n' "${n}" >"${state}"
    # With two configured health attempts this rejects the restored DB,
    # then succeeds on the first rollback-health probe.
    [ "${n}" -gt 2 ]
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod 0755 "${FAKEBIN}/systemctl" "${FAKEBIN}/curl"

common_env=(
  "PATH=${FAKEBIN}:${PATH}"
  "VPNX7_ENV_FILE=${ENV_FILE}"
  "VPNX7_DATA_DIR=${DATA}"
  "VPNX7_BACKUP_DIR=${BACKUPS}"
  "VPNX7_INSTALL_DIR=${INSTALL}"
  "VPNX7_HEALTH_ATTEMPTS=2"
  "VPNX7_HEALTH_SLEEP=0"
)

echo "restore selftest: successful restore"
make_db "${DATA}/vpnx7.db" "old"
GOOD_ARCHIVE="$(make_archive new)"
env "${common_env[@]}"   VPNX7_FAKE_CURL_MODE=success   bash "${ROOT}/scripts/restore-db.sh" "${GOOD_ARCHIVE}"
[ "$(read_proof "${DATA}/vpnx7.db")" = "new" ]
find "${BACKUPS}" -maxdepth 1 -name 'vpnx7-*.sqlite3.gz' -type f | grep -q .

echo "restore selftest: rejected restore rolls back previous database"
make_db "${DATA}/vpnx7.db" "rollback-old"
ROLLBACK_ARCHIVE="$(make_archive rollback-new)"
rm -f "${CURL_STATE}"

set +e
env "${common_env[@]}"   VPNX7_FAKE_CURL_MODE=fail-first   VPNX7_FAKE_CURL_STATE="${CURL_STATE}"   bash "${ROOT}/scripts/restore-db.sh" "${ROLLBACK_ARCHIVE}"
RC=$?
set -e

if [ "${RC}" -ne 12 ]; then
  echo "Expected restore rejection exit 12, got ${RC}" >&2
  exit 20
fi
if [ "$(read_proof "${DATA}/vpnx7.db")" != "rollback-old" ]; then
  echo "Pre-restore database was not recovered after failed health check." >&2
  exit 21
fi

echo "VPNX7 RESTORE SELFTEST PASS"
