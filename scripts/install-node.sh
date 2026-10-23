#!/usr/bin/env bash
set -Eeuo pipefail

ARG_CONTROL_URL="${CONTROL_URL:-${1:-}}"
ARG_BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-${2:-}}"
ARG_NODE_NAME="${NODE_NAME:-${3:-}}"
ARG_NODE_GEO="${NODE_GEO:-${4:-}}"
ARG_NODE_HOST="${NODE_HOST:-}"
ARG_PORT="${VPNX7_NODE_PORT:-}"
ARG_SNI="${VPNX7_REALITY_SNI:-}"
ALLOW_HTTP="${VPNX7_ALLOW_HTTP:-0}"

XRAY_VERSION="v26.10.21"
ENV_DIR="/etc/vpnx7-node"
ENV_FILE="${ENV_DIR}/node.env"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"

if [ "${EUID}" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

if [ -z "${ARG_CONTROL_URL}" ]; then
  echo "CONTROL_URL is required." >&2
  exit 2
fi
ARG_CONTROL_URL="${ARG_CONTROL_URL%/}"

if [[ "${ARG_CONTROL_URL}" == http://* ]] && [ "${ALLOW_HTTP}" != "1" ]; then
  echo "Refusing plaintext control traffic by default." >&2
  echo "For a private first test only, explicitly add VPNX7_ALLOW_HTTP=1." >&2
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends   ca-certificates curl jq openssl unzip iproute2

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64)
    ASSET="Xray-linux-64.zip"
    XRAY_SHA256="0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978"
    ;;
  aarch64|arm64)
    ASSET="Xray-linux-arm64-v8a.zip"
    XRAY_SHA256="d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 3
    ;;
esac

TMP_DIR="$(mktemp -d)"
UNIT_STAGE_DIR="${TMP_DIR}/units"
LOCAL_ROLLBACK_DIR="${TMP_DIR}/rollback"
SYNC_STAGE="${TMP_DIR}/vpnx7-node-sync"
mkdir -p "${UNIT_STAGE_DIR}" "${LOCAL_ROLLBACK_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

backup_path() {
  local src="$1"
  local key="$2"
  if [ -e "${src}" ]; then
    cp -a "${src}" "${LOCAL_ROLLBACK_DIR}/${key}"
  else
    : >"${LOCAL_ROLLBACK_DIR}/${key}.missing"
  fi
}

restore_path() {
  local dst="$1"
  local key="$2"
  if [ -f "${LOCAL_ROLLBACK_DIR}/${key}.missing" ]; then
    rm -f "${dst}"
  elif [ -e "${LOCAL_ROLLBACK_DIR}/${key}" ]; then
    cp -a "${LOCAL_ROLLBACK_DIR}/${key}" "${dst}"
  fi
}

XRAY_WAS_ACTIVE=0
TIMER_WAS_ACTIVE=0

backup_existing_runtime() {
  [ "${EXISTING:-0}" -eq 1 ] || return 0
  systemctl is-active --quiet vpnx7-xray.service && XRAY_WAS_ACTIVE=1 || true
  systemctl is-active --quiet vpnx7-node-sync.timer && TIMER_WAS_ACTIVE=1 || true
  backup_path "${ENV_FILE}" node.env
  backup_path /usr/local/sbin/vpnx7-node-sync node-sync
  backup_path /etc/systemd/system/vpnx7-xray.service xray.service
  backup_path /etc/systemd/system/vpnx7-node-sync.service sync.service
  backup_path /etc/systemd/system/vpnx7-node-sync.timer sync.timer
  backup_path "${XRAY_BIN}" xray.bin
  backup_path "${CONFIG_FILE}" xray.config
}

rollback_existing_runtime() {
  [ "${EXISTING:-0}" -eq 1 ] || return 0
  echo "Restoring previous VPNX7 node runtime." >&2
  systemctl stop vpnx7-node-sync.timer >/dev/null 2>&1 || true
  systemctl stop vpnx7-xray.service >/dev/null 2>&1 || true

  restore_path "${ENV_FILE}" node.env
  restore_path /usr/local/sbin/vpnx7-node-sync node-sync
  restore_path /etc/systemd/system/vpnx7-xray.service xray.service
  restore_path /etc/systemd/system/vpnx7-node-sync.service sync.service
  restore_path /etc/systemd/system/vpnx7-node-sync.timer sync.timer
  restore_path "${XRAY_BIN}" xray.bin
  restore_path "${CONFIG_FILE}" xray.config

  systemctl daemon-reload || true

  if [ "${TIMER_WAS_ACTIVE}" -eq 1 ]; then
    systemctl enable --now vpnx7-node-sync.timer >/dev/null 2>&1 || true
  else
    systemctl disable --now vpnx7-node-sync.timer >/dev/null 2>&1 || true
  fi

  if [ "${XRAY_WAS_ACTIVE}" -eq 1 ]; then
    systemctl restart vpnx7-xray.service >/dev/null 2>&1 || true
  else
    systemctl stop vpnx7-xray.service >/dev/null 2>&1 || true
  fi
}

abort_node_install() {
  local code="${1:-12}"
  if [ "${EXISTING:-0}" -eq 1 ]; then
    rollback_existing_runtime
  else
    systemctl disable --now vpnx7-node-sync.timer >/dev/null 2>&1 || true
    systemctl disable --now vpnx7-xray.service >/dev/null 2>&1 || true
  fi
  exit "${code}"
}

echo "[1/8] Downloading pinned Xray ${XRAY_VERSION}..."
curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 180   "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"   -o "${TMP_DIR}/xray.zip"

printf '%s  %s\n' "${XRAY_SHA256}" "${TMP_DIR}/xray.zip" | sha256sum -c -
unzip -q "${TMP_DIR}/xray.zip" -d "${TMP_DIR}/xray"
CANDIDATE="${TMP_DIR}/xray/xray"
chmod 0755 "${CANDIDATE}"
"${CANDIDATE}" version | head -n1

if ! id vpnx7-node >/dev/null 2>&1; then
  useradd --system --home /nonexistent --shell /usr/sbin/nologin vpnx7-node
fi
install -d -m 0750 -o root -g vpnx7-node "${ENV_DIR}" "${CONFIG_DIR}"

EXISTING=0
if [ -s "${ENV_FILE}" ]; then
  EXISTING=1
  # shellcheck disable=SC1090
  source "${ENV_FILE}"

  if [ "${ARG_CONTROL_URL}" != "${CONTROL_URL}" ]; then
    echo "Existing node belongs to ${CONTROL_URL}; refusing silent control-plane migration." >&2
    exit 4
  fi

  if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_SHORT_ID:-}" ] || \
     [ -z "${NODE_ID:-}" ] || [ -z "${NODE_TOKEN:-}" ]; then
    echo "Existing node state is incomplete. Refusing to rotate identity automatically." >&2
    exit 5
  fi

  PREVIOUS_DESIRED="$(curl -fsS --connect-timeout 8 --max-time 20 \
    -H "Authorization: Bearer ${NODE_TOKEN}" \
    "${CONTROL_URL}/api/v1/nodes/${NODE_ID}/desired")" || {
      echo "Stored node credentials are no longer accepted." >&2
      echo "No identity/key rotation was attempted." >&2
      exit 11
    }

  CONTROL_NODE_NAME="$(printf '%s' "${PREVIOUS_DESIRED}" | jq -r '.node.name // empty')"
  CONTROL_NODE_GEO="$(printf '%s' "${PREVIOUS_DESIRED}" | jq -r '.node.geo // empty')"
  CONTROL_NODE_HOST="$(printf '%s' "${PREVIOUS_DESIRED}" | jq -r '.node.host // empty')"
  CONTROL_NODE_PORT="$(printf '%s' "${PREVIOUS_DESIRED}" | jq -r '.node.port // 443')"
  CONTROL_NODE_SNI="$(printf '%s' "${PREVIOUS_DESIRED}" | jq -r '.node.sni // empty')"

  if [ -z "${CONTROL_NODE_NAME}" ] || [ -z "${CONTROL_NODE_GEO}" ] || \
     [ -z "${CONTROL_NODE_HOST}" ] || [ -z "${CONTROL_NODE_SNI}" ]; then
    echo "Control plane returned incomplete node metadata." >&2
    exit 11
  fi

  if [ -n "${ARG_NODE_NAME}" ] && [ "${ARG_NODE_NAME}" != "${CONTROL_NODE_NAME}" ]; then
    echo "Renaming an enrolled node during runtime update is blocked." >&2
    exit 4
  fi
  if [ -n "${ARG_NODE_GEO}" ] && [ "${ARG_NODE_GEO}" != "${CONTROL_NODE_GEO}" ]; then
    echo "Changing node geography during runtime update is blocked." >&2
    exit 4
  fi
  if [ -n "${ARG_NODE_HOST}" ] && [ "${ARG_NODE_HOST}" != "${CONTROL_NODE_HOST}" ]; then
    echo "Changing node host during runtime update is blocked." >&2
    exit 4
  fi
  if [ -n "${ARG_PORT}" ] && [ "${ARG_PORT}" != "${CONTROL_NODE_PORT}" ]; then
    echo "Changing node port during runtime update is blocked." >&2
    exit 4
  fi
  if [ -n "${ARG_SNI}" ] && [ "${ARG_SNI}" != "${CONTROL_NODE_SNI}" ]; then
    echo "Changing REALITY SNI during runtime update is blocked." >&2
    exit 4
  fi

  NODE_NAME="${CONTROL_NODE_NAME}"
  NODE_GEO="${CONTROL_NODE_GEO}"
  NODE_HOST="${CONTROL_NODE_HOST}"
  NODE_PORT="${CONTROL_NODE_PORT}"
  REALITY_SNI="${CONTROL_NODE_SNI}"

  KEY_INFO="$("${CANDIDATE}" x25519 -i "${REALITY_PRIVATE_KEY}")"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${KEY_INFO}" | awk -F': *' 'tolower($1) ~ /publickey/ || tolower($1) ~ /^password/ {print $2; exit}')"
  if [ -z "${REALITY_PUBLIC_KEY}" ]; then
    echo "Could not derive REALITY public key from the stored private key." >&2
    exit 5
  fi
else
  CONTROL_URL="${ARG_CONTROL_URL}"
  if [ -z "${ARG_BOOTSTRAP_TOKEN}" ]; then
    echo "BOOTSTRAP_TOKEN is required for the first installation." >&2
    exit 2
  fi
  NODE_NAME="${ARG_NODE_NAME:-node-$(hostname -s)}"
  NODE_GEO="${ARG_NODE_GEO:-Auto}"
  NODE_HOST="${ARG_NODE_HOST}"
  NODE_PORT="${ARG_PORT:-443}"
  REALITY_SNI="${ARG_SNI:-www.microsoft.com}"

  KEY_INFO="$("${CANDIDATE}" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${KEY_INFO}" | awk -F': *' 'tolower($1) ~ /^private ?key$/ || tolower($1) == "privatekey" {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${KEY_INFO}" | awk -F': *' 'tolower($1) ~ /publickey/ || tolower($1) ~ /^password/ {print $2; exit}')"
  if [ -z "${REALITY_PRIVATE_KEY}" ] || [ -z "${REALITY_PUBLIC_KEY}" ]; then
    echo "Could not parse REALITY key pair." >&2
    printf '%s\n' "${KEY_INFO}" >&2
    exit 5
  fi
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
fi

echo "[2/8] Checking port and REALITY target..."
if ss -ltnH "sport = :${NODE_PORT}" | grep -q . &&    ! systemctl is-active --quiet vpnx7-xray.service 2>/dev/null; then
  echo "TCP port ${NODE_PORT} is already in use by another service." >&2
  ss -ltnp "sport = :${NODE_PORT}" || true
  exit 6
fi

TLS_PING_OUTPUT="$(timeout 20 "${CANDIDATE}" tls ping "${REALITY_SNI}" 2>&1)" || {
  echo "REALITY target ${REALITY_SNI} could not be reached by Xray TLS preflight." >&2
  printf '%s\n' "${TLS_PING_OUTPUT}" >&2
  exit 7
}
if ! printf '%s\n' "${TLS_PING_OUTPUT}" | awk '
  /Pinging with SNI/ { in_sni=1; next }
  in_sni && /Handshake succeeded/ { ok=1 }
  END { exit(ok ? 0 : 1) }
'; then
  echo "REALITY target ${REALITY_SNI} did not complete a TLS handshake with SNI." >&2
  printf '%s\n' "${TLS_PING_OUTPUT}" >&2
  echo "Choose another VPNX7_REALITY_SNI." >&2
  exit 7
fi

if [ -z "${NODE_HOST}" ]; then
  NODE_HOST="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
fi
if [ -z "${NODE_HOST}" ]; then
  NODE_HOST="$(curl -4fsS --max-time 8 https://ifconfig.me/ip || true)"
fi
if [ -z "${NODE_HOST}" ]; then
  echo "Could not determine the public node address. Set NODE_HOST explicitly." >&2
  exit 8
fi

if [ -f "${CONFIG_FILE}" ]; then
  if ! "${CANDIDATE}" run -test -config "${CONFIG_FILE}" >/dev/null; then
    echo "The pinned Xray binary cannot validate the current live config. No files were changed." >&2
    exit 9
  fi
fi

echo "[3/8] Registering or verifying node identity..."
if [ "${EXISTING}" -eq 0 ]; then
  REGISTER_JSON="$(jq -n     --arg token "${ARG_BOOTSTRAP_TOKEN}"     --arg name "${NODE_NAME}"     --arg geo "${NODE_GEO}"     --arg host "${NODE_HOST}"     --arg sni "${REALITY_SNI}"     --arg pk "${REALITY_PUBLIC_KEY}"     --arg sid "${REALITY_SHORT_ID}"     --argjson port "${NODE_PORT}"     '{bootstrap_token:$token,name:$name,geo:$geo,host:$host,port:$port,sni:$sni,public_key:$pk,short_id:$sid}')"

  REGISTER_RESULT="$(curl -fsS --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30     -H 'Content-Type: application/json'     -d "${REGISTER_JSON}"     "${CONTROL_URL}/api/v1/nodes/register")"

  NODE_ID="$(printf '%s' "${REGISTER_RESULT}" | jq -r '.node_id // empty')"
  NODE_TOKEN="$(printf '%s' "${REGISTER_RESULT}" | jq -r '.node_token // empty')"
  if [ -z "${NODE_ID}" ] || [ -z "${NODE_TOKEN}" ]; then
    echo "Control plane returned an invalid registration response." >&2
    exit 10
  fi
else
  echo "Existing node credentials verified; preserving enrolled network identity."
fi

backup_existing_runtime

{
  printf 'CONTROL_URL=%q\n' "${CONTROL_URL}"
  printf 'NODE_ID=%q\n' "${NODE_ID}"
  printf 'NODE_TOKEN=%q\n' "${NODE_TOKEN}"
  printf 'NODE_NAME=%q\n' "${NODE_NAME}"
  printf 'NODE_GEO=%q\n' "${NODE_GEO}"
  printf 'NODE_HOST=%q\n' "${NODE_HOST}"
  printf 'NODE_PORT=%q\n' "${NODE_PORT}"
  printf 'REALITY_SNI=%q\n' "${REALITY_SNI}"
  printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY}"
  printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY}"
  printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID}"
} >"${ENV_FILE}.new"
chown root:root "${ENV_FILE}.new"
chmod 0600 "${ENV_FILE}.new"
mv "${ENV_FILE}.new" "${ENV_FILE}"

echo "[4/8] Installing fail-safe node sync..."
cat >"${SYNC_STAGE}" <<'SYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/vpnx7-node/node.env

TMP="$(mktemp)"
CFG="$(mktemp --suffix=.json)"
BACKUP="$(mktemp)"
XRAY_TEST_LOG="$(mktemp)"
trap 'rm -f "$TMP" "$CFG" "$BACKUP" "$XRAY_TEST_LOG"' EXIT

report_failure() {
  local code="$?"
  trap - ERR
  local msg="node sync failed at line ${BASH_LINENO[0]:-unknown}, exit=${code}"
  local xver
  xver="$(/usr/local/bin/xray version 2>/dev/null | head -n1 || true)"
  curl -fsS --connect-timeout 3 --max-time 6     -H "Authorization: Bearer $NODE_TOKEN"     -H 'Content-Type: application/json'     -d "$(jq -n --arg e "$msg" --arg v "$xver" '{ok:false,error:$e,xray_version:$v}')"     "$CONTROL_URL/api/v1/nodes/$NODE_ID/report" >/dev/null 2>&1 || true
  exit "$code"
}
trap report_failure ERR

curl -fsS --retry 2 --retry-all-errors --connect-timeout 8 --max-time 25   -H "Authorization: Bearer $NODE_TOKEN"   "$CONTROL_URL/api/v1/nodes/$NODE_ID/desired" >"$TMP"

DESIRED_ENABLED="$(jq -er '.node.enabled | if . == true then "true" elif . == false then "false" else error("node.enabled missing") end' "$TMP")"
CLIENTS="$(jq -ce '.clients | if type=="array" then . else error("clients must be array") end' "$TMP")"

if [ "$DESIRED_ENABLED" != "true" ]; then
  systemctl disable --now vpnx7-xray.service >/dev/null 2>&1 || true
  XVER="$(/usr/local/bin/xray version | head -n1)"
  curl -fsS --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $NODE_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg v "$XVER" '{ok:true,xray_version:$v}')" \
    "$CONTROL_URL/api/v1/nodes/$NODE_ID/report" >/dev/null
  echo "VPNX7 node is administratively disabled; Xray stopped."
  exit 0
fi

systemctl enable vpnx7-xray.service >/dev/null

jq -n   --argjson port "$NODE_PORT"   --arg sni "$REALITY_SNI"   --arg privateKey "$REALITY_PRIVATE_KEY"   --arg shortId "$REALITY_SHORT_ID"   --argjson clients "$CLIENTS" '{
  log:{loglevel:"warning"},
  inbounds:[{
    listen:"0.0.0.0",
    port:$port,
    protocol:"vless",
    settings:{
      clients:($clients | map({id:.uuid,flow:.flow,email:.email})),
      decryption:"none"
    },
    streamSettings:{
      network:"tcp",
      security:"reality",
      realitySettings:{
        show:false,
        target:($sni + ":443"),
        xver:0,
        serverNames:[$sni],
        privateKey:$privateKey,
        shortIds:[$shortId]
      }
    },
    sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}
  }],
  outbounds:[
    {protocol:"freedom",tag:"direct"},
    {protocol:"blackhole",tag:"blocked"}
  ],
  routing:{
    domainStrategy:"IPIfNonMatch",
    rules:[
      {type:"field",ip:["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","224.0.0.0/4","255.255.255.255/32","::1/128","fc00::/7","fe80::/10"],outboundTag:"blocked"},
      {type:"field",protocol:["bittorrent"],outboundTag:"blocked"}
    ]
  }
}' >"$CFG"

if ! /usr/local/bin/xray run -test -config "$CFG" >"$XRAY_TEST_LOG" 2>&1; then
  echo "Generated Xray config failed validation:" >&2
  cat "$XRAY_TEST_LOG" >&2
  false
fi

CHANGED=0
HAD_PREVIOUS=0
if [ ! -f /etc/xray/config.json ] || ! cmp -s "$CFG" /etc/xray/config.json; then
  CHANGED=1
  if [ -f /etc/xray/config.json ]; then
    HAD_PREVIOUS=1
    cp -a /etc/xray/config.json "$BACKUP"
  fi
  install -o root -g vpnx7-node -m 0640 "$CFG" /etc/xray/config.json
fi

restart_and_verify() {
  systemctl restart vpnx7-xray.service
  sleep 2
  systemctl is-active --quiet vpnx7-xray.service
  if ! /usr/local/bin/xray run -test -config /etc/xray/config.json >"$XRAY_TEST_LOG" 2>&1; then
    cat "$XRAY_TEST_LOG" >&2
    return 1
  fi
  ss -ltnH "sport = :$NODE_PORT" | grep -q .
}

if [ "$CHANGED" -eq 1 ]; then
  if ! restart_and_verify; then
    if [ "$HAD_PREVIOUS" -eq 1 ] && [ -s "$BACKUP" ]; then
      echo "New Xray config failed runtime validation; restoring previous config." >&2
      install -o root -g vpnx7-node -m 0640 "$BACKUP" /etc/xray/config.json
      if ! restart_and_verify; then
        echo "Previous Xray config also failed after rollback." >&2
      fi
    fi
    false
  fi
elif ! systemctl is-active --quiet vpnx7-xray.service; then
  restart_and_verify
else
  if ! /usr/local/bin/xray run -test -config /etc/xray/config.json >"$XRAY_TEST_LOG" 2>&1; then
    cat "$XRAY_TEST_LOG" >&2
    false
  fi
  ss -ltnH "sport = :$NODE_PORT" | grep -q .
fi

XVER="$(/usr/local/bin/xray version | head -n1)"
curl -fsS --connect-timeout 5 --max-time 10   -H "Authorization: Bearer $NODE_TOKEN"   -H 'Content-Type: application/json'   -d "$(jq -n --arg v "$XVER" '{ok:true,xray_version:$v}')"   "$CONTROL_URL/api/v1/nodes/$NODE_ID/report" >/dev/null

echo "VPNX7 node sync OK; changed=$CHANGED; clients=$(printf '%s' "$CLIENTS" | jq 'length')"
SYNC
chmod 0755 "${SYNC_STAGE}"

echo "[5/8] Installing systemd units..."
cat >"${UNIT_STAGE_DIR}/vpnx7-xray.service" <<EOF
[Unit]
Description=VPNX7 Xray node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=vpnx7-node
Group=vpnx7-node
ExecStartPre=/usr/local/bin/xray run -test -config /etc/xray/config.json
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=2
TimeoutStopSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/xray /usr/local/share/xray
LockPersonality=true
RestrictSUIDSGID=true
TasksMax=256

[Install]
WantedBy=multi-user.target
EOF

cat >"${UNIT_STAGE_DIR}/vpnx7-node-sync.service" <<EOF
[Unit]
Description=VPNX7 node desired-state sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpnx7-node-sync
TimeoutStartSec=45
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
EOF

cat >"${UNIT_STAGE_DIR}/vpnx7-node-sync.timer" <<EOF
[Unit]
Description=VPNX7 node sync timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=60s
RandomizedDelaySec=5s
Persistent=true
Unit=vpnx7-node-sync.service

[Install]
WantedBy=timers.target
EOF

echo "[6/8] Installing staged node runtime..."
if ! install -m 0755 "${SYNC_STAGE}" /usr/local/sbin/vpnx7-node-sync; then
  abort_node_install 12
fi
if ! install -m 0644 "${UNIT_STAGE_DIR}/vpnx7-xray.service" /etc/systemd/system/vpnx7-xray.service || \
   ! install -m 0644 "${UNIT_STAGE_DIR}/vpnx7-node-sync.service" /etc/systemd/system/vpnx7-node-sync.service || \
   ! install -m 0644 "${UNIT_STAGE_DIR}/vpnx7-node-sync.timer" /etc/systemd/system/vpnx7-node-sync.timer; then
  abort_node_install 12
fi
if ! install -m 0755 "${CANDIDATE}" "${XRAY_BIN}"; then
  abort_node_install 12
fi

install -d -m 0755 /usr/local/share/xray
[ ! -f "${TMP_DIR}/xray/geoip.dat" ] || install -m 0644 "${TMP_DIR}/xray/geoip.dat" /usr/local/share/xray/geoip.dat
[ ! -f "${TMP_DIR}/xray/geosite.dat" ] || install -m 0644 "${TMP_DIR}/xray/geosite.dat" /usr/local/share/xray/geosite.dat

if ! systemctl daemon-reload; then
  abort_node_install 12
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify \
      /etc/systemd/system/vpnx7-xray.service \
      /etc/systemd/system/vpnx7-node-sync.service \
      /etc/systemd/system/vpnx7-node-sync.timer; then
    echo "New node systemd units failed verification." >&2
    abort_node_install 12
  fi
fi

if ! systemctl enable --now vpnx7-node-sync.timer >/dev/null; then
  abort_node_install 12
fi

echo "[7/8] Applying desired state..."
if ! systemctl start vpnx7-node-sync.service; then
  echo "Node sync failed; restoring the previous runtime when available." >&2
  abort_node_install 12
fi

echo "[8/8] Final node verification..."
systemctl is-active --quiet vpnx7-node-sync.timer
FINAL_DESIRED="$(curl -fsS --connect-timeout 5 --max-time 10 \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  "${CONTROL_URL}/api/v1/nodes/${NODE_ID}/desired")"
FINAL_ENABLED="$(printf '%s' "${FINAL_DESIRED}" | jq -r '.node.enabled')"

if [ "${FINAL_ENABLED}" = "true" ]; then
  systemctl is-active --quiet vpnx7-xray.service
  "${XRAY_BIN}" run -test -config "${CONFIG_FILE}" >/dev/null
  ss -ltnH "sport = :${NODE_PORT}" | grep -q .
  STATUS_TEXT="healthy and serving"
else
  if systemctl is-active --quiet vpnx7-xray.service; then
    echo "Disabled node unexpectedly has Xray running." >&2
    exit 13
  fi
  STATUS_TEXT="healthy, administratively disabled"
fi

echo
echo "VPNX7 node is ${STATUS_TEXT}."
echo "Node:    ${NODE_NAME} (${NODE_GEO})"
echo "Host:    ${NODE_HOST}:${NODE_PORT}"
echo "Xray:    $("${XRAY_BIN}" version | head -n1)"
echo "Control: ${CONTROL_URL}"
