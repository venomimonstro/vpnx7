# VPNX7 delivery plan

## Sprint 0 — working tunnel first

Status: implemented in the initial repository foundation.

- Control plane on FastAPI + SQLite.
- Admin token authentication.
- Automatic node bootstrap.
- Xray VLESS + XTLS Vision + REALITY on TCP/443.
- Per-node token after bootstrap.
- Pull-based desired-state sync every minute.
- Validate-before-reload safety.
- INCY-compatible subscription with all active geo nodes.
- Minimal connection page.
- Manual client creation in admin API/UI.
- Optional Telegram access bot.

**Acceptance test:** create one client, install one node, import the subscription in INCY, open an external IP check through the tunnel, reboot both servers independently, and confirm reconnection.

## Sprint 1 — operational stability

- HTTPS setup for the control plane.
- Automated SQLite backups and restore command.
- Admin node enable/disable controls.
- Health dashboard: last sync, Xray service status, latency probe.
- Expiry extension and revocation UI.
- Structured journal diagnostics command.
- Safe update command with rollback to previous Xray binary/config.

## Sprint 2 — two-node geo operation

- Install the second geo node.
- Verify subscription refresh adds both servers.
- Node maintenance/drain mode.
- Automated synthetic connection probe per geo.
- Alert if a node misses multiple sync intervals.

## Sprint 3 — sales path

- Real plans and prices.
- Payment provider integration.
- Idempotent payment webhook.
- Automatic activation/renewal.
- Telegram purchase/status buttons.
- Web customer cabinet.
- Receipts/legal pages as applicable.

## Sprint 4 — only if measurements require it

Do not add protocols just because they exist.

Possible fallback:

- AmneziaWG/WireGuard for networks where it is demonstrably better; or
- a second Xray transport if a target ISP blocks the primary path.

The fallback is added only after collecting failure data from the VLESS REALITY path.
