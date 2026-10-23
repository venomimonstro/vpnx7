#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${VPNX7_REPO_URL:-https://github.com/venomimonstro/vpnx7.git}"
INSTALL_DIR="${VPNX7_INSTALL_DIR:-/opt/vpnx7}"
ENV_DIR="/etc/vpnx7"
ENV_FILE="${ENV_DIR}/control.env"
DATA_DIR="/var/lib/vpnx7"
PUBLIC_URL="${1:-${VPNX7_PUBLIC_URL:-}}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash scripts/install-control.sh [PUBLIC_URL]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl git openssl python3 python3-venv

if ! id vpnx7 >/dev/null 2>&1; then
  useradd --system --home "${DATA_DIR}" --shell /usr/sbin/nologin vpnx7
fi

if [ ! -d "${INSTALL_DIR}/.git" ]; then
  git clone --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
else
  git -C "${INSTALL_DIR}" fetch --depth 1 origin main
  git -C "${INSTALL_DIR}" reset --hard origin/main
fi

python3 -m venv "${INSTALL_DIR}/.venv"
"${INSTALL_DIR}/.venv/bin/pip" install --disable-pip-version-check --no-cache-dir -r "${INSTALL_DIR}/requirements.txt"

install -d -m 0750 -o root -g vpnx7 "${ENV_DIR}"
install -d -m 0750 -o vpnx7 -g vpnx7 "${DATA_DIR}"

if [ -z "${PUBLIC_URL}" ]; then
  PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [ -z "${PUBLIC_IP}" ]; then
    PUBLIC_IP="$(hostname -I | awk '{print $1}')"
  fi
  PUBLIC_URL="http://${PUBLIC_IP}:8080"
fi

if [ ! -f "${ENV_FILE}" ]; then
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
  echo "Keeping existing ${ENV_FILE}; secrets were not rotated."
fi

cat >/etc/systemd/system/vpnx7-control.service <<EOF
[Unit]
Description=VPNX7 lightweight control plane
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vpnx7
Group=vpnx7
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080 --workers 1
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/vpnx7-bot.service <<EOF
[Unit]
Description=VPNX7 Telegram bot
After=network-online.target vpnx7-control.service
Wants=network-online.target

[Service]
Type=simple
User=vpnx7
Group=vpnx7
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/.venv/bin/python -m app.bot
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpnx7-control.service

sleep 2
curl -fsS http://127.0.0.1:8080/healthz >/dev/null

echo
echo "VPNX7 control plane is healthy."
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
  echo "WARNING: HTTP is acceptable only for the first private test."
  echo "Before selling access, put the control plane behind HTTPS and update VPNX7_PUBLIC_URL."
fi
