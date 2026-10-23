# VPNX7

Lightweight self-hosted VPN control plane and geo-node system **without Marzban**.

The project is intentionally designed for weak VPS instances and for failure containment: the main server manages access and subscriptions, while VPN traffic goes directly through independent geo nodes.

## Current architecture

- **Control plane:** FastAPI + SQLite WAL + one Uvicorn worker + systemd.
- **VPN nodes:** pinned Xray-core + systemd + a one-shot shell sync timer.
- **Protocol:** VLESS + XTLS Vision + REALITY over TCP/443.
- **Client:** INCY subscription URL; one subscription contains all active geo nodes.
- **Telegram:** optional lightweight bot for status/access delivery.
- **No Redis, no Kubernetes, no Marzban, no mandatory Docker.**

Xray is pinned to **v26.10.21** in the node installer.

## Why this shape

The control plane is not in the VPN data path. If the main server is temporarily unavailable, already configured nodes continue serving the last valid client list.

A node never blindly overwrites its live Xray configuration. It:

1. pulls desired clients;
2. builds a temporary config;
3. validates it with `xray run -test`;
4. replaces the live config only after validation;
5. restarts only when the generated config actually changed.

## 1. Install the control plane

On the main Debian/Ubuntu server:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/install-control.sh -o /tmp/vpnx7-control.sh
sudo bash /tmp/vpnx7-control.sh http://MAIN_SERVER_IP:8080
```

For the **first private test**, HTTP is allowed so the tunnel can be proven before spending time on domains/TLS. Before public sales, use an HTTPS public URL.

The installer prints:

- Admin URL
- Admin token
- Node bootstrap token

Keep both tokens private.

## 2. Install the first VPN node

On the geo server:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/install-node.sh -o /tmp/vpnx7-node.sh

sudo env \
  CONTROL_URL=http://MAIN_SERVER_IP:8080 \
  BOOTSTRAP_TOKEN='TOKEN_FROM_CONTROL_INSTALLER' \
  NODE_NAME='de-1' \
  NODE_GEO='Germany' \
  bash /tmp/vpnx7-node.sh
```

The node automatically:

- installs the pinned Xray build;
- generates its REALITY key pair and short ID;
- detects its public IP;
- registers itself in the control plane;
- receives a per-node token;
- creates systemd services/timer;
- pulls clients every minute;
- validates config before switching;
- starts Xray on TCP/443.

If TCP/443 is already occupied, the installer **refuses to destroy or replace** the existing service.

## 3. Create your own VPN access

Open:

```
http://MAIN_SERVER_IP:8080/admin
```

Enter the admin token, create a client, and open the returned `connect_url`.

The connection page provides an **Add to INCY** button plus the raw subscription URL.

INCY receives every active geo node from the same subscription, so adding a second country does not require issuing a new client key.

## 4. Add the second geo node

Run the same node installer on the second VPS with another name and geography, for example:

```bash
sudo env \
  CONTROL_URL=http://MAIN_SERVER_IP:8080 \
  BOOTSTRAP_TOKEN='TOKEN_FROM_CONTROL_INSTALLER' \
  NODE_NAME='nl-1' \
  NODE_GEO='Netherlands' \
  bash /tmp/vpnx7-node.sh
```

After the next subscription refresh, both locations are available in INCY.

## Diagnostics

Run on either control server or node:

```bash
sudo bash /opt/vpnx7/scripts/diagnose.sh
```

For a node installed directly from the remote script, download diagnostics when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/venomimonstro/vpnx7/main/scripts/diagnose.sh -o /tmp/vpnx7-diagnose.sh
sudo bash /tmp/vpnx7-diagnose.sh
```

## Telegram bot

Set `VPNX7_TELEGRAM_BOT_TOKEN` in `/etc/vpnx7/control.env`, then:

```bash
sudo systemctl enable --now vpnx7-bot
```

A client linked to a Telegram ID can use `/status` and `/access`.

## Current web purchase flow

The public site can create a pending order. Activation is currently manual by design: payment integration is intentionally postponed until the VPN tunnel itself passes real two-server testing. This avoids debugging payment logic and VPN transport at the same time.

## Next stages

See:

- `docs/ARCHITECTURE.md`
- `docs/SPRINTS.md`

The next mandatory stage after the first successful tunnel is HTTPS + backup/restore + health monitoring, then the second node, and only then automated payments/commercial UI.
