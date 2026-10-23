#!/usr/bin/env bash
set -u

pass(){ printf '[PASS] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
fail(){ printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

echo "=== VPNX7 diagnostics ==="
date -Is
echo

if systemctl cat vpnx7-control.service >/dev/null 2>&1; then
  echo "--- control plane ---"
  if systemctl is-active --quiet vpnx7-control.service; then pass "control service active"; else fail "control service inactive"; fi
  if curl -fsS --max-time 5 http://127.0.0.1:8080/healthz >/tmp/vpnx7-health.$$ 2>/dev/null; then
    pass "local /healthz"
    cat /tmp/vpnx7-health.$$
    echo
  else
    fail "local /healthz failed"
  fi
  rm -f /tmp/vpnx7-health.$$ 2>/dev/null || true
  systemctl --no-pager --full status vpnx7-control.service 2>/dev/null | tail -n 15 || true
  echo
fi

if systemctl cat vpnx7-xray.service >/dev/null 2>&1; then
  echo "--- VPN node ---"
  if systemctl is-active --quiet vpnx7-xray.service; then pass "xray service active"; else fail "xray service inactive"; fi
  if systemctl is-active --quiet vpnx7-node-sync.timer; then pass "sync timer active"; else fail "sync timer inactive"; fi

  if [ -x /usr/local/bin/xray ] && [ -f /etc/xray/config.json ]; then
    if /usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null 2>&1; then
      pass "xray config validates"
    else
      fail "xray config validation failed"
    fi
  else
    fail "xray binary or config missing"
  fi

  if [ -f /etc/vpnx7-node/node.env ]; then
    # shellcheck disable=SC1091
    source /etc/vpnx7-node/node.env
    if ss -ltnH "sport = :${NODE_PORT:-443}" | grep -q .; then
      pass "TCP port ${NODE_PORT:-443} is listening"
    else
      fail "TCP port ${NODE_PORT:-443} is not listening"
    fi

    if curl -fsS --max-time 8 -H "Authorization: Bearer $NODE_TOKEN"       "$CONTROL_URL/api/v1/nodes/$NODE_ID/desired" >/tmp/vpnx7-desired.$$ 2>/dev/null; then
      COUNT="$(jq -r '.clients | length' /tmp/vpnx7-desired.$$ 2>/dev/null || echo '?')"
      pass "node can authenticate to control plane; active clients=$COUNT"
    else
      fail "node cannot pull desired state from control plane"
    fi
    rm -f /tmp/vpnx7-desired.$$ 2>/dev/null || true
  else
    fail "/etc/vpnx7-node/node.env missing"
  fi

  systemctl --no-pager --full status vpnx7-xray.service 2>/dev/null | tail -n 15 || true
  systemctl --no-pager --full status vpnx7-node-sync.service 2>/dev/null | tail -n 15 || true
  echo
fi

echo "--- resources ---"
df -h /
free -h 2>/dev/null || true
echo

if [ "$FAILURES" -eq 0 ]; then
  echo "[PASS] VPNX7 diagnostics completed without detected failures."
  exit 0
fi

echo "[FAIL] VPNX7 diagnostics detected $FAILURES problem(s)."
exit 1
