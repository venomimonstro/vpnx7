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
  CONTROL_PORT=8080
  if [ -f /etc/vpnx7/control.env ]; then
    P="$(grep '^VPNX7_PORT=' /etc/vpnx7/control.env | cut -d= -f2- || true)"
    [ -z "$P" ] || CONTROL_PORT="$P"
  fi

  if systemctl is-active --quiet vpnx7-control.service; then
    pass "control service active"
  else
    fail "control service inactive"
  fi

  HEALTH_TMP="$(mktemp)"
  if curl -fsS --max-time 5 "http://127.0.0.1:$CONTROL_PORT/healthz" >"$HEALTH_TMP" 2>/dev/null; then
    pass "local /healthz"
    cat "$HEALTH_TMP"
    echo
  else
    fail "local /healthz failed"
  fi
  rm -f "$HEALTH_TMP"

  if systemctl is-active --quiet vpnx7-backup.timer; then
    pass "backup timer active"
  else
    fail "backup timer inactive"
  fi

  LATEST_BACKUP="$(find /var/backups/vpnx7 -maxdepth 1 -type f -name 'vpnx7-*.sqlite3.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    AGE="$(( $(date +%s) - $(stat -c %Y "$LATEST_BACKUP") ))"
    if [ "$AGE" -le 93600 ]; then
      pass "recent database backup exists: $LATEST_BACKUP"
    else
      fail "latest database backup is older than 26 hours: $LATEST_BACKUP"
    fi
    if gzip -t "$LATEST_BACKUP" >/dev/null 2>&1; then
      pass "latest backup gzip integrity"
    else
      fail "latest backup gzip is corrupt"
    fi
  else
    fail "no database backup found"
  fi

  systemctl --no-pager --full status vpnx7-control.service 2>/dev/null | tail -n 15 || true
  echo
fi

if systemctl cat vpnx7-xray.service >/dev/null 2>&1; then
  echo "--- VPN node ---"
  if systemctl is-active --quiet vpnx7-xray.service; then
    pass "xray service active"
  else
    fail "xray service inactive"
  fi
  if systemctl is-active --quiet vpnx7-node-sync.timer; then
    pass "sync timer active"
  else
    fail "sync timer inactive"
  fi

  SYNC_RESULT="$(systemctl show vpnx7-node-sync.service -p Result --value 2>/dev/null || true)"
  if [ "$SYNC_RESULT" = "success" ]; then
    pass "last node sync service result: success"
  elif [ -n "$SYNC_RESULT" ]; then
    fail "last node sync service result: $SYNC_RESULT"
  else
    warn "node sync has not reported a result yet"
  fi

  if [ -x /usr/local/bin/xray ] && [ -f /etc/xray/config.json ]; then
    if /usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null 2>&1; then
      pass "xray config validates"
    else
      fail "xray config validation failed"
    fi
    XVER="$(/usr/local/bin/xray version 2>/dev/null | head -n1 || true)"
    [ -z "$XVER" ] || echo "Xray: $XVER"
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

    DESIRED_TMP="$(mktemp)"
    if curl -fsS --max-time 8       -H "Authorization: Bearer $NODE_TOKEN"       "$CONTROL_URL/api/v1/nodes/$NODE_ID/desired" >"$DESIRED_TMP" 2>/dev/null; then
      COUNT="$(jq -r '.clients | length' "$DESIRED_TMP" 2>/dev/null || echo '?')"
      pass "node authenticated to control plane; active clients=$COUNT"
    else
      fail "node cannot pull desired state from control plane"
    fi
    rm -f "$DESIRED_TMP"
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

DISK_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -ge 90 ]; then
  fail "root filesystem usage is ${DISK_PCT}%"
fi
echo

if [ "$FAILURES" -eq 0 ]; then
  echo "[PASS] VPNX7 diagnostics completed without detected failures."
  exit 0
fi

echo "[FAIL] VPNX7 diagnostics detected $FAILURES problem(s)."
exit 1
