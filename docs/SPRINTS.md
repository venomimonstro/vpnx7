# VPNX7 delivery / acceptance state

## Core transport and control — implemented

- FastAPI + SQLite WAL control plane.
- Admin bearer authentication.
- Automatic first-time node enrollment.
- Individual node credentials.
- VLESS + XTLS Vision + REALITY on TCP/443.
- Pull desired-state sync every minute.
- Validate-before-reload.
- Runtime rollback of bad Xray config.
- Candidate Xray binary rollback.
- Pinned Xray version and SHA-256.
- Healthy-node filtering in subscriptions.
- INCY-compatible subscription and deep link.
- Client creation/revocation/expiry.
- Telegram access/status bot.
- Minimal public request flow.
- Duplicate enrollment protection.

## Operational safety — implemented

- Exact top-level Python dependency pins.
- Python compile gate.
- Shell syntax + ShellCheck gate.
- Legacy database migration self-test.
- Control API lifecycle self-test.
- Staged control release.
- Automatic control release rollback.
- Online SQLite backup with integrity check.
- Daily persistent backup timer.
- Mandatory pre-deploy backup.
- Restore integrity validation.
- Automatic database rollback after failed restore.
- Diagnostics for services, node sync, config, port, backup and disk.
- CI on every main push.
- Real pinned-Xray runtime/config CI test.

## Physical two-server acceptance — required before calling the deployed instance stable

This cannot be proven inside repository CI because it depends on the actual VPS providers, firewalls, routes and client network.

Acceptance requires:

1. install control on the main VPS;
2. enroll the main VPS and the second VPS as nodes;
3. create one real client;
4. import the subscription into INCY;
5. connect through each geo and verify the external IP;
6. transfer sustained traffic through each node;
7. reboot each VPN node independently;
8. reboot the control server;
9. stop the control service while an existing tunnel is active and confirm the tunnel remains usable;
10. introduce a deliberately invalid candidate config in a controlled test and confirm rollback;
11. confirm client revocation disappears from both nodes after sync;
12. confirm a stopped node ages out of a refreshed subscription;
13. run `diagnose.sh` on all hosts and require zero failures.

Only after all thirteen checks pass should the concrete deployed pair be called accepted.

## Before public sales

Not part of the private-working-VPN acceptance gate:

- trusted HTTPS for control/subscription;
- real payment provider and idempotent webhooks;
- legal/fiscal pages/receipts as applicable;
- customer cabinet;
- abuse/traffic policy;
- external monitoring from independent networks.

These are commercial requirements, not reasons to delay validating the core VPN for personal work.
