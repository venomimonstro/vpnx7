#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VPNX7_REPO_URL:-https://github.com/venomimonstro/vpnx7.git}"
INSTALL_DIR="${VPNX7_INSTALL_DIR:-/opt/vpnx7}"
ROLLBACK_DIR="${INSTALL_DIR}.rollback"
STAGE_DIR="${INSTALL_DIR}.stage.$$"
FAILED_DIR="${INSTALL_DIR}.failed.$$"
ENV_DIR="/etc/vpnx7"
ENV_FILE="${ENV_DIR}/control.env"
DATA_DIR="/var/lib/vpnx7"
PUBLIC_URL="${1:-${VPNX7_PUBLIC_URL:-}}"

cleanup() {
  [ ! -d "${STAGE_DIR}" ] || rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash install-control.sh [PUBLIC_URL]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends   ca-certificates curl git gzip openssl python3 python3-venv

if ! id vpnx7 >/dev/null 2>&1; then
  useradd --system --home "${DATA_DIR}" --shell /usr/sbin/nologin vpnx7
fi

install -d -m 0750 -o root -g vpnx7 "${ENV_DIR}"
install -d -m 0750 -o vpnx7 -g vpnx7 "${DATA_DIR}"

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
install -d -m 0700 /var/backups/vpnx7

echo "[1/6] Building a clean staged release..."
rm -rf "${STAGE_DIR}"
git clone --depth 1 --branch main "${REPO_URL}" "${STAGE_DIR}"

python3 -m venv "${STAGE_DIR}/.venv"
"${STAGE_DIR}/.venv/bin/python" -m pip install   --disable-pip-version-check --no-cache-dir   -r "${STAGE_DIR}/requirements.txt"

echo "[2/6] Static validation..."
"${STAGE_DIR}/.venv/bin/python" -m compileall -q "${STAGE_DIR}/app" "${STAGE_DIR}/scripts"
for script in "${STAGE_DIR}"/scripts/*.sh; do
  bash -n "${script}"
done

echo "[3/6] Isolated application and migration self-tests..."
(
  cd "${STAGE_DIR}"
  "${STAGE_DIR}/.venv/bin/python" scripts/migration-selftest.py
  "${STAGE_DIR}/.venv/bin/python" scripts/selftest.py
)

cat >/etc/systemd/system/vpnx7-control.service <<EOF
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
ExecStart=${INSTALL_DIR}/.venv/bin/python -m uvicorn app.main:app --host \${VPNX7_BIND} --port \${VPNX7_PORT} --workers 1
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

cat >/etc/systemd/system/vpnx7-bot.service <<EOF
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


cat >/etc/systemd/system/vpnx7-backup.service <<EOF
[Unit]
Description=VPNX7 consistent SQLite backup
After=vpnx7-control.service

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
Environment=VPNX7_BACKUP_DIR=/var/backups/vpnx7
Environment=VPNX7_BACKUP_RETENTION=14
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/scripts/backup-db.py
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/backups/vpnx7
EOF

cat >/etc/systemd/system/vpnx7-backup.timer <<EOF
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

echo "[4/6] Switching release atomically..."
HAD_OLD=0
if [ -d "${INSTALL_DIR}" ]; then
  HAD_OLD=1
  rm -rf "${ROLLBACK_DIR}"
  mv "${INSTALL_DIR}" "${ROLLBACK_DIR}"
fi
mv "${STAGE_DIR}" "${INSTALL_DIR}"

systemctl daemon-reload
systemctl enable vpnx7-control.service >/dev/null

echo "[5/6] Restarting and checking health..."
if ! systemctl restart vpnx7-control.service; then
  HEALTH_OK=0
else
  HEALTH_OK=0
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 http://127.0.0.1:${CONTROL_PORT}/healthz >/dev/null 2>&1; then
      HEALTH_OK=1
      break
    fi
    sleep 1
  done
fi

if [ "${HEALTH_OK}" -ne 1 ]; then
  echo "New control-plane release failed health validation. Rolling back." >&2
  systemctl stop vpnx7-control.service >/dev/null 2>&1 || true
  rm -rf "${FAILED_DIR}"
  mv "${INSTALL_DIR}" "${FAILED_DIR}"
  if [ "${HAD_OLD}" -eq 1 ] && [ -d "${ROLLBACK_DIR}" ]; then
    mv "${ROLLBACK_DIR}" "${INSTALL_DIR}"
    systemctl daemon-reload
    systemctl restart vpnx7-control.service || true
  fi
  echo "Failed release preserved at ${FAILED_DIR}" >&2
  exit 10
fi

BOT_TOKEN="$(grep '^VPNX7_TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" | cut -d= -f2- || true)"
if [ -n "${BOT_TOKEN}" ]; then
  systemctl enable vpnx7-bot.service >/dev/null
  systemctl restart vpnx7-bot.service
else
  systemctl disable --now vpnx7-bot.service >/dev/null 2>&1 || true
fi

systemctl enable --now vpnx7-backup.timer >/dev/null
systemctl start vpnx7-backup.service
systemctl is-active --quiet vpnx7-backup.timer

echo "[6/6] Final verification..."
curl -fsS --max-time 3 http://127.0.0.1:${CONTROL_PORT}/healthz
echo
systemctl is-active --quiet vpnx7-control.service

echo
echo "VPNX7 control plane is healthy."
echo "Release:    $(git -C "${INSTALL_DIR}" rev-parse --short HEAD)"
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
