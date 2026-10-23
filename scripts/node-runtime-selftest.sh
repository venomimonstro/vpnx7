#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local rc="$?"
  echo "NODE RUNTIME SELFTEST FAILED: rc=${rc} line=${BASH_LINENO[0]:-unknown} command=${BASH_COMMAND}" >&2
  exit "${rc}"
}
trap on_error ERR

if [ "${EUID}" -ne 0 ]; then
  echo "node-runtime-selftest must run as root" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}" /etc/vpnx7-node /etc/xray' EXIT

XRAY_VERSION="v26.10.21"
XRAY_SHA256="0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978"

curl -fL --retry 3 --connect-timeout 10 --max-time 180   "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"   -o "${TMP}/xray.zip"
printf '%s  %s\n' "${XRAY_SHA256}" "${TMP}/xray.zip" | sha256sum -c -
echo "selftest: unzip Xray"
unzip -q "${TMP}/xray.zip" -d "${TMP}/xray"
echo "selftest: install Xray"
install -m 0755 "${TMP}/xray/xray" /usr/local/bin/xray

if ! getent group vpnx7-node >/dev/null; then
  groupadd --system vpnx7-node
fi
install -d -m 0750 -o root -g vpnx7-node /etc/vpnx7-node /etc/xray

echo "selftest: generate REALITY key"
KEYS="$(/usr/local/bin/xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "${KEYS}" | awk -F': *' 'tolower($1) ~ /^private ?key$/ || tolower($1) == "privatekey" {print $2; exit}')"
[ -n "${PRIVATE_KEY}" ]

cat >/etc/vpnx7-node/node.env <<EOF
CONTROL_URL=https://control.invalid
NODE_ID=11111111-1111-4111-8111-111111111111
NODE_TOKEN=test-node-token
NODE_NAME=test-node
NODE_GEO=Test
NODE_HOST=203.0.113.10
NODE_PORT=443
REALITY_SNI=www.microsoft.com
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=unused-in-runtime
REALITY_SHORT_ID=0011223344556677
EOF
chmod 0600 /etc/vpnx7-node/node.env

echo "selftest: extract node runtime"
awk '
  /cat >"\$\{SYNC_STAGE\}" <<'\''SYNC'\''/ { capture=1; next }
  capture && /^SYNC$/ { exit }
  capture { print }
' "${INSTALLER}" >"${TMP}/node-sync.sh"

[ -s "${TMP}/node-sync.sh" ]
bash -n "${TMP}/node-sync.sh"
shellcheck -e SC1090,SC1091 "${TMP}/node-sync.sh"

mkdir -p "${TMP}/fakebin"

cat >"${TMP}/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -e
for arg in "$@"; do
  case "$arg" in
    */desired)
      cat <<'JSON'
{"node":{"id":"11111111-1111-4111-8111-111111111111","name":"test-node","geo":"Test","host":"203.0.113.10","port":443,"sni":"www.microsoft.com","enabled":true},"clients":[{"id":"c1","name":"test","uuid":"22222222-2222-4222-8222-222222222222","email":"vpnx7-test","flow":"xtls-rprx-vision"}]}
JSON
      exit 0
      ;;
    */report)
      printf '{"status":"ok"}\n'
      exit 0
      ;;
  esac
done
exit 1
EOF

cat >"${TMP}/fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  restart) exit 0 ;;
  is-active) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat >"${TMP}/fakebin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'
EOF

chmod 0755 "${TMP}/fakebin/"*

PATH="${TMP}/fakebin:${PATH}" bash -x "${TMP}/node-sync.sh"

/usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null
jq -e '
  .inbounds[0].protocol == "vless" and
  .inbounds[0].port == 443 and
  .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision" and
  .inbounds[0].streamSettings.security == "reality" and
  .inbounds[0].streamSettings.realitySettings.target == "www.microsoft.com:443" and
  .inbounds[0].streamSettings.realitySettings.shortIds[0] == "0011223344556677"
' /etc/xray/config.json >/dev/null

echo "VPNX7 NODE RUNTIME SELFTEST PASS"
