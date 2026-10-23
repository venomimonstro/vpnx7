#!/usr/bin/env bash
set -Eeuo pipefail

CONTROL_URL="${CONTROL_URL:-${1:-}}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-${2:-}}"
NODE_NAME="${NODE_NAME:-${3:-node-$(hostname -s)}}"
NODE_GEO="${NODE_GEO:-${4:-Auto}}"
NODE_HOST="${NODE_HOST:-}"
PORT="${VPNX7_NODE_PORT:-443}"
SNI="${VPNX7_REALITY_SNI:-www.microsoft.com}"
XRAY_VERSION="${XRAY_VERSION:-v26.10.21}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi
if [ -z "${CONTROL_URL}" ] || [ -z "${BOOTSTRAP_TOKEN}" ]; then
  echo "Usage: sudo CONTROL_URL=https://control.example BOOTSTRAP_TOKEN=... NODE_GEO=DE bash install-node.sh" >&2
  exit 2
fi
CONTROL_URL="${CONTROL_URL%/}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl jq openssl unzip iproute2

if ss -ltnH "sport = :${PORT}" | grep -q . && ! systemctl is-active --quiet vpnx7-xray.service 2>/dev/null; then
  echo "TCP port ${PORT} is already in use. Refusing to replace another service." >&2
  ss -ltnp "sport = :${PORT}" || true
  exit 3
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  *) echo "Unsupported architecture: ${ARCH}" >&2; exit 4 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
curl -fL --retry 3 --connect-timeout 10   "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ASSET}"   -o "${TMP_DIR}/xray.zip"
unzip -q "${TMP_DIR}/xray.zip" -d "${TMP_DIR}/xray"
install -m 0755 "${TMP_DIR}/xray/xray" /usr/local/bin/xray
install -d -m 0755 /usr/local/share/xray
[ ! -f "${TMP_DIR}/xray/geoip.dat" ] || install -m 0644 "${TMP_DIR}/xray/geoip.dat" /usr/local/share/xray/geoip.dat
[ ! -f "${TMP_DIR}/xray/geosite.dat" ] || install -m 0644 "${TMP_DIR}/xray/geosite.dat" /usr/local/share/xray/geosite.dat

if ! id vpnx7-node >/dev/null 2>&1; then
  useradd --system --home /nonexistent --shell /usr/sbin/nologin vpnx7-node
fi
install -d -m 0750 -o root -g vpnx7-node /etc/vpnx7-node /etc/xray

KEYS="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "${KEYS}" | awk -F': *' 'tolower($1) ~ /^private ?key$/ || tolower($1) == "privatekey" {print $2; exit}')"
PUBLIC_KEY="$(printf '%s\n' "${KEYS}" | awk -F': *' 'tolower($1) ~ /publickey/ || tolower($1) ~ /^password/ {print $2; exit}')"
if [ -z "${PRIVATE_KEY}" ] || [ -z "${PUBLIC_KEY}" ]; then
  echo "Could not parse Reality keys from xray x25519." >&2
  printf '%s\n' "${KEYS}" >&2
  exit 5
fi
SHORT_ID="$(openssl rand -hex 8)"

if [ -z "${NODE_HOST}" ]; then
  NODE_HOST="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
fi
if [ -z "${NODE_HOST}" ]; then
  NODE_HOST="$(hostname -I | awk '{print $1}')"
fi

REGISTER_JSON="$(jq -n   --arg token "${BOOTSTRAP_TOKEN}"   --arg name "${NODE_NAME}"   --arg geo "${NODE_GEO}"   --arg host "${NODE_HOST}"   --arg sni "${SNI}"   --arg pk "${PUBLIC_KEY}"   --arg sid "${SHORT_ID}"   --argjson port "${PORT}"   '{bootstrap_token:$token,name:$name,geo:$geo,host:$host,port:$port,sni:$sni,public_key:$pk,short_id:$sid}')"

REGISTER_RESULT="$(curl -fsS --retry 3 --connect-timeout 10   -H 'Content-Type: application/json'   -d "${REGISTER_JSON}"   "${CONTROL_URL}/api/v1/nodes/register")"
NODE_ID="$(printf '%s' "${REGISTER_RESULT}" | jq -r '.node_id // empty')"
NODE_TOKEN="$(printf '%s' "${REGISTER_RESULT}" | jq -r '.node_token // empty')"
if [ -z "${NODE_ID}" ] || [ -z "${NODE_TOKEN}" ]; then
  echo "Control plane returned an invalid registration response." >&2
  printf '%s\n' "${REGISTER_RESULT}" >&2
  exit 6
fi

cat >/etc/vpnx7-node/node.env <<EOF
CONTROL_URL=${CONTROL_URL}
NODE_ID=${NODE_ID}
NODE_TOKEN=${NODE_TOKEN}
NODE_PORT=${PORT}
REALITY_SNI=${SNI}
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_SHORT_ID=${SHORT_ID}
EOF
chown root:root /etc/vpnx7-node/node.env
chmod 0600 /etc/vpnx7-node/node.env

cat >/usr/local/sbin/vpnx7-node-sync <<'SYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/vpnx7-node/node.env

TMP="$(mktemp)"
CFG="$(mktemp)"
trap 'rm -f "$TMP" "$CFG"' EXIT

curl -fsS --retry 2 --connect-timeout 8   -H "Authorization: Bearer $NODE_TOKEN"   "$CONTROL_URL/api/v1/nodes/$NODE_ID/desired" >"$TMP"

CLIENTS="$(jq -c '.clients' "$TMP")"
if [ "$CLIENTS" = "null" ]; then
  echo "Invalid desired state: clients missing" >&2
  exit 10
fi

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
        dest:($sni + ":443"),
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
      {type:"field",ip:["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"],outboundTag:"blocked"},
      {type:"field",protocol:["bittorrent"],outboundTag:"blocked"}
    ]
  }
}' >"$CFG"

/usr/local/bin/xray run -test -config "$CFG" >/dev/null

if [ ! -f /etc/xray/config.json ] || ! cmp -s "$CFG" /etc/xray/config.json; then
  install -o root -g vpnx7-node -m 0640 "$CFG" /etc/xray/config.json
  systemctl restart vpnx7-xray.service
fi
SYNC
chmod 0755 /usr/local/sbin/vpnx7-node-sync

cat >/etc/systemd/system/vpnx7-xray.service <<EOF
[Unit]
Description=VPNX7 Xray node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vpnx7-node
Group=vpnx7-node
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/xray /usr/local/share/xray

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/vpnx7-node-sync.service <<EOF
[Unit]
Description=VPNX7 node desired-state sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpnx7-node-sync
EOF

cat >/etc/systemd/system/vpnx7-node-sync.timer <<EOF
[Unit]
Description=VPNX7 node sync timer

[Timer]
OnBootSec=15s
OnUnitActiveSec=60s
RandomizedDelaySec=5s
Unit=vpnx7-node-sync.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable vpnx7-xray.service
systemctl enable --now vpnx7-node-sync.timer
systemctl start vpnx7-node-sync.service
systemctl enable --now vpnx7-xray.service

sleep 2
systemctl is-active --quiet vpnx7-xray.service
xray run -test -config /etc/xray/config.json >/dev/null

echo
echo "VPNX7 node is installed and healthy."
echo "Node: ${NODE_NAME} (${NODE_GEO})"
echo "Host: ${NODE_HOST}:${PORT}"
echo "Xray: $(xray version | head -n1)"
if [[ "${CONTROL_URL}" == http://* ]]; then
  echo "WARNING: control traffic uses HTTP. Move the control plane to HTTPS before commercial use."
fi
