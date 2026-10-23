# VPNX7

Lightweight self-hosted VPN control plane and geo-node system **without Marzban**.

VPNX7 is deliberately small and designed for weak VPS instances. The control plane manages access and subscriptions; user VPN traffic goes directly through independent Xray nodes.

## Stable core

- **Control plane:** FastAPI + SQLite WAL + one Uvicorn worker + systemd.
- **VPN nodes:** pinned Xray-core + systemd + one-shot desired-state sync.
- **Protocol:** VLESS + XTLS Vision + REALITY over TCP/443.
- **Client:** INCY-compatible plain-text subscription containing every healthy geo node.
- **Telegram:** optional polling bot for access/status delivery.
- **No Redis, Kubernetes, Marzban or mandatory Docker.**
- **Release safety:** staged control update + compile + shell validation + migration/API self-tests + health check + automatic rollback.
- **Node safety:** pinned Xray v26.10.21 + SHA-256 verification + config validation + runtime validation + config/binary rollback.
- **Data safety:** SQLite online backups with integrity check, daily timer and restore rollback.
- **Health safety:** a node is included in subscriptions only after a recent successful sync/runtime report.

The control plane is not in the VPN data path. If it is temporarily unavailable, nodes continue serving their last validated Xray configuration.

## Ports

For the first private two-server test:

- control plane: TCP/8080;
- every VPN node: TCP/443.

The main VPS can run both the control plane on 8080 and the first Xray node on 443. The second VPS can be the second geo node.

## 1. Install or safely update the control plane

On Debian/Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/install-control.sh -o /tmp/vpnx7-control.sh
sudo bash /tmp/vpnx7-control.sh http://MAIN_SERVER_IP:8080
```

The same command is also the safe update path. Before switching code it:

1. creates a clean staged checkout;
2. installs pinned Python dependencies;
3. compiles Python;
4. checks every shell script;
5. runs legacy-schema migration and control API self-tests;
6. creates a pre-deploy database backup;
7. switches the release;
8. checks live health;
9. automatically restores the previous release if health fails.

On first install it prints the admin token and node bootstrap token. Keep both private.

### HTTP safety

Plain HTTP is allowed only for the initial private tunnel test. It exposes bearer credentials to anyone able to intercept that network path.

Before any public/commercial use, the public control/subscription endpoint must use trusted HTTPS.

## 2. Install the first node

For an HTTP-only private test, the insecure choice must be explicit:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/install-node.sh -o /tmp/vpnx7-node.sh

sudo env \
  CONTROL_URL=http://MAIN_SERVER_IP:8080 \
  VPNX7_ALLOW_HTTP=1 \
  BOOTSTRAP_TOKEN='TOKEN_FROM_CONTROL_INSTALLER' \
  NODE_NAME='de-1' \
  NODE_GEO='Germany' \
  bash /tmp/vpnx7-node.sh
```

With an HTTPS control URL, omit `VPNX7_ALLOW_HTTP=1`.

The installer:

- downloads exactly Xray **v26.10.21**;
- verifies the release SHA-256 before installing;
- checks that TCP/443 is not owned by another service;
- tests the REALITY target;
- generates REALITY identity only on first enrollment;
- detects the public node IPv4 or fails instead of silently publishing a private address;
- registers the node and stores an individual node token;
- generates and validates the Xray config before use;
- starts systemd services/timer;
- verifies service state, config and listening port;
- reports healthy state to the control plane.

### Safe reinstall/update of a node

Run the same installer again with the same `CONTROL_URL`.

An enrolled node **does not regenerate its REALITY identity or silently rotate its token**. It verifies the stored credentials first. A control-plane migration or node rename is refused instead of guessed.

If a new generated config fails after Xray restart, the previous config is restored. If the candidate Xray binary causes the sync to fail, the previous binary is restored.

## 3. Create access and connect through INCY

Open:

```
http://MAIN_SERVER_IP:8080/admin
```

Enter the admin token and create a client. Open the returned `connect_url`.

The page contains an **Add to INCY** deep link and the raw subscription URL. One subscription carries all currently healthy geo nodes; adding another geo does not require issuing another user UUID.

## 4. Add the second node

Run the same node installer on the second VPS with a unique node name/geography:

```bash
sudo env \
  CONTROL_URL=http://MAIN_SERVER_IP:8080 \
  VPNX7_ALLOW_HTTP=1 \
  BOOTSTRAP_TOKEN='TOKEN_FROM_CONTROL_INSTALLER' \
  NODE_NAME='nl-1' \
  NODE_GEO='Netherlands' \
  bash /tmp/vpnx7-node.sh
```

Update the control plane **before** updating already enrolled nodes.

## Diagnostics

On the control server:

```bash
sudo bash /opt/vpnx7/scripts/diagnose.sh
```

On a standalone node:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/diagnose.sh -o /tmp/vpnx7-diagnose.sh
sudo bash /tmp/vpnx7-diagnose.sh
```

Diagnostics check the control service, local health endpoint, backup timer/recency, Xray service, node sync result, Xray config, listening port, node authentication, disk usage and basic resources.

## Backups and restore

Consistent SQLite backups run daily and are stored under:

```
/var/backups/vpnx7/
```

A backup is also required immediately before a control release switch.

Restore:

```bash
sudo bash /opt/vpnx7/scripts/restore-db.sh /var/backups/vpnx7/vpnx7-YYYYMMDDTHHMMSSZ.sqlite3.gz
```

The restore verifies SQLite integrity first. If the restored database does not pass the application health check, VPNX7 automatically restores the pre-restore database.

## Telegram bot

Set `VPNX7_TELEGRAM_BOT_TOKEN` in `/etc/vpnx7/control.env`, then rerun the control installer or enable the unit:

```bash
sudo systemctl enable --now vpnx7-bot
```

A client linked to the real Telegram user ID can use `/status` and `/access`.

## CI safety gate

Every push to `main` runs on a clean Ubuntu runner:

- pinned dependency installation;
- Python compilation;
- `bash -n`;
- ShellCheck;
- migration from the legacy database schema;
- FastAPI/API lifecycle self-test;
- real pinned-Xray node runtime/config self-test.

A red CI run is treated as a release blocker.

## Commercial boundary

The current public web form creates a pending access request; **automatic payment is intentionally not presented as working**. Real payments, fiscal/legal requirements and trusted HTTPS are a separate commercial layer and must not be mixed into the first VPN transport acceptance test.

The first production-quality acceptance gate for the VPN core is documented in `docs/AUDIT.md`.
