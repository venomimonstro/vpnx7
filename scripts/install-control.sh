#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VPNX7_REPO_URL:-https://github.com/venomimonstro/vpnx7.git}"
REPO_REF="${VPNX7_REPO_REF:-stable}"
INSTALL_DIR="${VPNX7_INSTALL_DIR:-/opt/vpnx7}"
ROLLBACK_DIR="${INSTALL_DIR}.rollback"
STAGE_DIR="${INSTALL_DIR}.stage.$$"
FAILED_DIR="${INSTALL_DIR}.failed.$$"
ENV_DIR="/etc/vpnx7"
ENV_FILE="${ENV_DIR}/control.env"
DATA_DIR="/var/lib/vpnx7"
BACKUP_DIR="/var/backups/vpnx7"
PUBLIC_URL="${1:-${VPNX7_PUBLIC_URL:-}}"
UNIT_STAGE_DIR="$(mktemp -d)"
UNIT_BACKUP_DIR="$(mktemp -d)"
SYSTEMD_DIR="/etc/systemd/system"

UNITS=(
  vpnx7-control.service
  vpnx7-bot.service
  vpnx7-backup.service
  vpnx7-backup.timer
)

cleanup() {
  [ ! -d "${STAGE_DIR}" ] || rm -rf "${STAGE_DIR}"
  rm -rf "${UNIT_STAGE_DIR}" "${UNIT_BACKUP_DIR}"
}
trap cleanup EXIT

restore_units() {
  local unit
  for unit in "${UNITS[@]}"; do
    if [ -f "${UNIT_BACKUP_DIR}/${unit}.missing" ]; then
      rm -f "${SYSTEMD_DIR}/${unit}"
    elif [ -f "${UNIT_BACKUP_DIR}/${unit}" ]; then
      install -m 0644 "${UNIT_BACKUP_DIR}/${unit}" "${SYSTEMD_DIR}/${unit}"
    fi
  done
  systemctl daemon-reload
}

backup_units() {
  local unit
  for unit in "${UNITS[@]}"; do
    if [ -f "${SYSTEMD_DIR}/${unit}" ]; then
      cp -a "${SYSTEMD_DIR}/${unit}" "${UNIT_BACKUP_DIR}/${unit}"
    else
      : >"${UNIT_BACKUP_DIR}/${unit}.missing"
    fi
  done
}

install_staged_units() {
  local unit
  for unit in "${UNITS[@]}"; do
    install -m 0644 "${UNIT_STAGE_DIR}/${unit}" "${SYSTEMD_DIR}/${unit}" || return 1
  done
  systemctl daemon-reload || return 1
}

rollback_release() {
  echo "Rolling back control-plane code and systemd units." >&2
  systemctl stop vpnx7-backup.timer >/dev/null 2>&1 || true
  systemctl stop vpnx7-bot.service >/dev/null 2>&1 || true
  systemctl stop vpnx7-control.service >/dev/null 2>&1 || true

  rm -rf "${FAILED_DIR}"
  if [ -d "${INSTALL_DIR}" ]; then
    mv "${INSTALL_DIR}" "${FAILED_DIR}"
  fi

  if [ "${HAD_OLD:-0}" -eq 1 ] && [ -d "${ROLLBACK_DIR}" ]; then
    mv "${ROLLBACK_DIR}" "${INSTALL_DIR}"
  fi

  restore_units

  if [ "${HAD_OLD:-0}" -eq 1 ] && [ -d "${INSTALL_DIR}" ]; then
    systemctl restart vpnx7-control.service || true

    if [ "${BOT_WAS_ENABLED_BEFORE:-0}" -eq 1 ]; then
      systemctl enable vpnx7-bot.service >/dev/null 2>&1 || true
    else
      systemctl disable vpnx7-bot.service >/dev/null 2>&1 || true
    fi
    if [ "${BOT_WAS_ACTIVE_BEFORE:-0}" -eq 1 ]; then
      systemctl restart vpnx7-bot.service || true
    else
      systemctl stop vpnx7-bot.service >/dev/null 2>&1 || true
    fi

    if [ "${BACKUP_TIMER_WAS_ENABLED_BEFORE:-0}" -eq 1 ]; then
      systemctl enable vpnx7-backup.timer >/dev/null 2>&1 || true
    else
      systemctl disable vpnx7-backup.timer >/dev/null 2>&1 || true
    fi
    if [ "${BACKUP_TIMER_WAS_ACTIVE_BEFORE:-0}" -eq 1 ]; then
      systemctl start vpnx7-backup.timer >/dev/null 2>&1 || true
    else
      systemctl stop vpnx7-backup.timer >/dev/null 2>&1 || true
    fi
  else
    systemctl disable vpnx7-control.service vpnx7-bot.service vpnx7-backup.timer >/dev/null 2>&1 || true
  fi

  echo "Failed release preserved at ${FAILED_DIR}" >&2
}

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash install-control.sh [PUBLIC_URL]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends   ca-certificates curl git gzip openssl python3 python3-venv util-linux

exec 9>/run/lock/vpnx7-control-install.lock
if ! flock -n 9; then
  echo "Another VPNX7 control install/update is already running." >&2
  exit 20
fi

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "VPNX7 control plane requires Python >= 3.10." >&2
  echo "Use Debian 12+ or Ubuntu 22.04+ (or another host with Python >= 3.10)." >&2
  exit 3
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "VPNX7 requires systemd/systemctl." >&2
  exit 3
fi

if ! getent group vpnx7 >/dev/null 2>&1; then
  groupadd --system vpnx7
fi
if ! id vpnx7 >/dev/null 2>&1; then
  useradd --system --gid vpnx7 --home "${DATA_DIR}" --shell /usr/sbin/nologin vpnx7
fi

install -d -m 0750 -o root -g vpnx7 "${ENV_DIR}"
install -d -m 0750 -o vpnx7 -g vpnx7 "${DATA_DIR}"
install -d -m 0700 "${BACKUP_DIR}"

if [ ! -f "${ENV_FILE}" ]; then
  if [ -z "${PUBLIC_URL}" ]; then
    PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
    if [ -z "${PUBLIC_IP}" ]; then
      echo "Could not detect a public IPv4 address. Pass PUBLIC_URL explicitly." >&2
      exit 2
    fi
    PUBLIC_URL="http://${PUBLIC_IP}:8080"
  fi

  ADMIN_TOKEN="$(openssl rand -hex 32)"
  BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
  cat >"${ENV_FILE}" <<EOF
VPNX7_BIND=0.0.0.0
VPNX7_PORT=8080
VPNX7_DATABASE=${DATA_DIR}/vpnx7.db
VPNX7_PUBLIC_URL=${PUBLIC_URL}
VPNX7_ADMIN_TOKEN=${ADMIN_TOKEN}
VPNX7_NODE_BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
VPNX7_PROVIDER_NAME=VPNX7
VPNX7_SUPPORT_URL=
VPNX7_TELEGRAM_BOT_TOKEN=
EOF
  chown root:vpnx7 "${ENV_FILE}"
  chmod 0640 "${ENV_FILE}"
else
  echo "Keeping existing ${ENV_FILE}; secrets and public URL were not changed."
fi

CONTROL_PORT="$(grep '^VPNX7_PORT=' "${ENV_FILE}" | cut -d= -f2- || true)"
CONTROL_PORT="${CONTROL_PORT:-8080}"

echo "[1/8] Building a clean staged release..."
rm -rf "${STAGE_DIR}"
git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${STAGE_DIR}"

python3 -m venv "${STAGE_DIR}/.venv"
"${STAGE_DIR}/.venv/bin/python" -m pip install   --disable-pip-version-check --no-cache-dir   -r "${STAGE_DIR}/requirements.lock"
"${STAGE_DIR}/.venv/bin/python" -m pip check

echo "[2/8] Static validation..."
"${STAGE_DIR}/.venv/bin/python" -m compileall -q   "${STAGE_DIR}/app" "${STAGE_DIR}/scripts"
for script in "${STAGE_DIR}"/scripts/*.sh; do
  bash -n "${script}"
done

echo "[3/8] Isolated application and migration self-tests..."
(
  cd "${STAGE_DIR}"
  "${STAGE_DIR}/.venv/bin/python" scripts/migration-selftest.py
  "${STAGE_DIR}/.venv/bin/python" scripts/selftest.py
  "${STAGE_DIR}/.venv/bin/python" scripts/backup-selftest.py
  bash scripts/restore-selftest.sh
)

echo "[4/8] Staging systemd units..."
cat >"${UNIT_STAGE_DIR}/vpnx7-control.service" <<EOF
[Unit]
Description=VPNX7 lightweight control plane
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=vpnx7
Group=vpnx7
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=${INSTALL_DIR}/.venv/bin/python -m uvicorn app.main:app --host \${VPNX7_BIND} --port \${VPNX7_PORT} --workers 1 --no-access-log
Restart=always
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGINT
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
LockPersonality=true
RestrictSUIDSGID=true
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF

cat >"${UNIT_STAGE_DIR}/vpnx7-bot.service" <<EOF
[Unit]
Description=VPNX7 Telegram bot
After=network-online.target vpnx7-control.service
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=vpnx7
Group=vpnx7
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/.venv/bin/python -m app.bot
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
LockPersonality=true
RestrictSUIDSGID=true
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF

cat >"${UNIT_STAGE_DIR}/vpnx7-backup.service" <<EOF
[Unit]
Description=VPNX7 consistent SQLite backup
After=vpnx7-control.service

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
Environment=VPNX7_BACKUP_DIR=${BACKUP_DIR}
Environment=VPNX7_BACKUP_RETENTION=14
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/scripts/backup-db.py
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${BACKUP_DIR}
EOF

cat >"${UNIT_STAGE_DIR}/vpnx7-backup.timer" <<EOF
[Unit]
Description=Daily VPNX7 database backup

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=20m
Persistent=true
Unit=vpnx7-backup.service

[Install]
WantedBy=timers.target
EOF

echo "[5/8] Creating mandatory pre-deploy database backup..."
LIVE_DB="$(grep '^VPNX7_DATABASE=' "${ENV_FILE}" | cut -d= -f2- || true)"
LIVE_DB="${LIVE_DB:-${DATA_DIR}/vpnx7.db}"
if [ -f "${LIVE_DB}" ]; then
  VPNX7_DATABASE="${LIVE_DB}"   VPNX7_BACKUP_DIR="${BACKUP_DIR}"   VPNX7_BACKUP_RETENTION=14     "${STAGE_DIR}/.venv/bin/python" "${STAGE_DIR}/scripts/backup-db.py"
fi

echo "[6/8] Switching code and unit files..."
HAD_OLD=0
BOT_WAS_ACTIVE_BEFORE=0
BOT_WAS_ENABLED_BEFORE=0
BACKUP_TIMER_WAS_ACTIVE_BEFORE=0
BACKUP_TIMER_WAS_ENABLED_BEFORE=0
systemctl is-active --quiet vpnx7-bot.service && BOT_WAS_ACTIVE_BEFORE=1 || true
systemctl is-enabled --quiet vpnx7-bot.service && BOT_WAS_ENABLED_BEFORE=1 || true
systemctl is-active --quiet vpnx7-backup.timer && BACKUP_TIMER_WAS_ACTIVE_BEFORE=1 || true
systemctl is-enabled --quiet vpnx7-backup.timer && BACKUP_TIMER_WAS_ENABLED_BEFORE=1 || true

# Do not allow a scheduled backup process to start while the release directory
# and its Python runtime are being atomically replaced.
systemctl stop vpnx7-backup.timer >/dev/null 2>&1 || true
systemctl stop vpnx7-backup.service >/dev/null 2>&1 || true

backup_units

if [ -d "${INSTALL_DIR}" ]; then
  HAD_OLD=1
  rm -rf "${ROLLBACK_DIR}"
  mv "${INSTALL_DIR}" "${ROLLBACK_DIR}"
fi

if ! mv "${STAGE_DIR}" "${INSTALL_DIR}"; then
  echo "Could not switch staged application into place." >&2
  if [ "${HAD_OLD}" -eq 1 ] && [ -d "${ROLLBACK_DIR}" ]; then
    mv "${ROLLBACK_DIR}" "${INSTALL_DIR}"
  fi
  exit 8
fi

if ! install_staged_units; then
  echo "Could not install new systemd unit set." >&2
  rollback_release
  exit 9
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify     "${SYSTEMD_DIR}/vpnx7-control.service"     "${SYSTEMD_DIR}/vpnx7-bot.service"     "${SYSTEMD_DIR}/vpnx7-backup.service"     "${SYSTEMD_DIR}/vpnx7-backup.timer"; then
    echo "New systemd units failed verification." >&2
    rollback_release
    exit 9
  fi
fi

if ! systemctl enable vpnx7-control.service >/dev/null; then
  echo "Could not enable new control service." >&2
  rollback_release
  exit 9
fi

echo "[7/8] Restarting and checking live health..."
HEALTH_OK=0
if systemctl restart vpnx7-control.service; then
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${CONTROL_PORT}/healthz" >/dev/null 2>&1; then
      HEALTH_OK=1
      break
    fi
    sleep 1
  done
fi

if [ "${HEALTH_OK}" -ne 1 ]; then
  echo "New control-plane release failed live health validation." >&2
  rollback_release
  exit 10
fi

BOT_TOKEN="$(grep '^VPNX7_TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" | cut -d= -f2- || true)"
POST_HEALTH_OK=1
if [ -n "${BOT_TOKEN}" ]; then
  systemctl enable vpnx7-bot.service >/dev/null || POST_HEALTH_OK=0
  systemctl restart vpnx7-bot.service || POST_HEALTH_OK=0
else
  systemctl disable --now vpnx7-bot.service >/dev/null 2>&1 || true
fi

systemctl enable --now vpnx7-backup.timer >/dev/null || POST_HEALTH_OK=0
systemctl start vpnx7-backup.service || POST_HEALTH_OK=0
systemctl is-active --quiet vpnx7-backup.timer || POST_HEALTH_OK=0

if [ "${POST_HEALTH_OK}" -ne 1 ]; then
  echo "Post-health service activation failed." >&2
  rollback_release
  exit 11
fi

echo "[8/8] Final verification..."
curl -fsS --max-time 3 "http://127.0.0.1:${CONTROL_PORT}/healthz"
echo
systemctl is-active --quiet vpnx7-control.service
systemctl is-active --quiet vpnx7-backup.timer

echo
echo "VPNX7 control plane is healthy."
echo "Release:    $(git -C "${INSTALL_DIR}" rev-parse --short HEAD)"
echo "Release ref: ${REPO_REF}"
echo "Public URL: $(grep '^VPNX7_PUBLIC_URL=' "${ENV_FILE}" | cut -d= -f2-)"
echo "Admin:      $(grep '^VPNX7_PUBLIC_URL=' "${ENV_FILE}" | cut -d= -f2-)/admin"
echo
echo "Admin token:"
grep '^VPNX7_ADMIN_TOKEN=' "${ENV_FILE}" | cut -d= -f2-
echo
echo "Node bootstrap token:"
grep '^VPNX7_NODE_BOOTSTRAP_TOKEN=' "${ENV_FILE}" | cut -d= -f2-
echo
if [[ "$(grep '^VPNX7_PUBLIC_URL=' "${ENV_FILE}" | cut -d= -f2-)" == http://* ]]; then
  echo "SECURITY WARNING: control/subscription traffic is HTTP."
  echo "Use it only for the first private tunnel test; HTTPS is required before public sales."
fi
