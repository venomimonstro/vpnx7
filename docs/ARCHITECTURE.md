# VPNX7 architecture

## Reliability model

VPNX7 separates the **control plane** from the **data plane**.

The control plane may be unavailable without terminating already configured VPN traffic. Each node keeps its last validated Xray configuration and never needs the control server in the packet path.

### Control plane

One small FastAPI process on the main server:

- SQLite in WAL mode with `synchronous=FULL`;
- one Uvicorn worker;
- admin/API/web subscription endpoints;
- node desired-state API;
- recent node-health state;
- optional Telegram bot as a separate process;
- online SQLite backups.

Important writes use immediate SQLite transactions. Application updates are prepared in a staged directory and are switched only after compile/syntax/self-tests. A failed live health check automatically restores the previous application release.

### VPN node

Each geo server runs:

1. pinned Xray-core;
2. one hardened systemd Xray service;
3. one root one-shot sync service;
4. one systemd timer.

The node has no long-running Python agent.

On each sync the node:

1. authenticates with its individual token;
2. pulls active UUIDs;
3. builds a temporary Xray config;
4. validates it with real Xray;
5. keeps a copy of the previous config;
6. restarts Xray only when the config changed;
7. checks that Xray remains active and TCP port is listening;
8. restores the previous config if runtime validation fails;
9. reports success/failure to the control plane.

A node enters client subscriptions only when its last successful report is recent.

## Protocol

The intentionally narrow initial protocol set is:

- VLESS;
- XTLS Vision;
- REALITY;
- TCP/443.

The node installer validates the configured REALITY target and pins Xray to a known release plus SHA-256.

Adding more protocols is not considered a stability improvement by itself. A fallback is introduced only when real network measurements show that the primary path is insufficient.

## Identity and secrets

- Admin token: control plane + administrator only.
- Bootstrap token: used only to enroll a new node.
- Per-node token: generated after enrollment; only its SHA-256 hash is stored centrally.
- REALITY private key: node only.
- REALITY public key/short ID: control plane.
- Client subscription token: opaque random token separate from VLESS UUID.

Reinstalling an enrolled node reuses its identity. Duplicate node names are refused instead of silently replacing an existing enrollment.

## Failure behavior

| Failure | Expected behavior |
| --- | --- |
| Control plane temporarily unavailable | Existing Xray tunnels continue using the last valid node config |
| Node cannot pull desired state | Live Xray config is not overwritten |
| Desired state produces invalid Xray config | Validation fails before replacement |
| Xray fails after a changed config is installed | Previous config is restored and Xray is restarted |
| Candidate Xray binary breaks the node update | Previous binary is restored |
| Node stops successful sync reports | Node ages out of newly refreshed subscriptions |
| One geo node fails | Other healthy geo nodes remain in the subscription |
| Duplicate node enrollment | HTTP 409; existing node identity is untouched |
| SQLite write contention | WAL + busy timeout + serialized critical writes |
| Control release fails self-test | Working release is never switched |
| Control release fails live health | Previous release is restored |
| Database restore fails live health | Pre-restore database is restored |
| Corrupt Xray download | SHA-256 validation aborts before installation |

## Resource strategy

The design intentionally avoids Redis, containers, message brokers and multi-process application servers. This reduces RAM, disk and operational dependencies on small VPS instances.

## Commercial boundary

The VPN core can be validated independently of billing. Before public sales, the control/subscription endpoint needs trusted HTTPS and the payment/fiscal flow needs its own idempotent implementation and testing. Those concerns are not allowed to weaken or complicate the VPN data plane.
